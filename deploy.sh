#!/bin/bash

# ------------------------------------------------------------------
# deploy script: component_deploy
#
# Description:
#   Deploys application components and optional plugins from the
#   build server to the local Tomcat installation. Handles copying
#   WAR files, updating symlinks, optional backups for plugins, and
#   running a post-deploy health check. Produces a timestamped log
#   and an HTML report emailed to the deployment mailing list.
#
# Usage:
#   ./deploy.sh <branch-suffix-or-trunk> <single component-or-ALL>
#
#   Examples:
#     # Deploy all components from trunk
#     ./deploy.sh trunk ALL
#
#     # Deploy specific components for branch suffix 'p62'
#     ./deploy.sh p62 componentA,componentB
#
# Execution help:
#   - The script writes a timestamped log to the path configured in
#     `LOGFILE` (see CONFIGURATION section). Run it from the project
#     root or with absolute path. It requires two positional args:
#       1) branch suffix or the literal `trunk`
#       2) a single component name, a comma-separated list, or `ALL`
#   - Run interactively to follow progress; the script exits with code
#     0 on success or non-zero when any component deployment failed.
#    - it also sends an HTML email report summarizing the deployment to give email IDs
#  
#
# Notes:
#   - This script expects certain paths and utilities to exist
#     (configured below in the CONFIGURATION section).
#   - Do not store sensitive keys in this file; SSH keys and
#     related configuration should be managed externally (e.g. via
#     ~/.ssh, ssh-agent, or an external secrets manager).
# ------------------------------------------------------------------

usage() {
cat <<'USAGE'
Usage: ./deploy.sh <trunk or p62 > <lobbyapi-or-ALL>

Positional arguments:
    <branch-suffix-or-trunk>   Branch suffix (e.g. p62) or the literal "trunk"
    <component-or-ALL>         Single component name, a comma-separated list, or the word ALL

Options:
    -h, --help                 Show this help message and exit

Examples:
    ./deploy.sh trunk ALL
    ./deploy.sh p62 lobbyapi,webservices

Notes:
    - This script performs real deployments (scp, symlink updates, chown,
        and a health check). Review the CONFIGURATION section at the top of
        the file before running in production.
    - SSH keys and other sensitive configuration must be managed externally
        
USAGE
}

# Print help and exit if requested
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
fi

set -euo pipefail

############################################
# CONFIGURATION
############################################
LOGFILE="/var/log/deployment/component_deploy_$(date +%d%m%y%H%M).log"
exec > >(tee -a "$LOGFILE") 2>&1

BRANCH_INPUT="$1"
COMPONENT_INPUT="$2"

SCP_KEY="$HOME/.ssh/javabuild_dsa"
JENKINS_HOST="javabuild04"
WAR_BASE="/usr/local/tomcat/wars"
DEPLOY_BASE="/usr/local/sbin/component_deploy"
LIST_FILE="/usr/local/sbin/component_and_plugin_list"
SERVER_HOST=$(hostname -s)

PLUGIN_DIR="$WAR_BASE/deposit_plugins"
BACKUP_DIR="/var/tmp/deposit_plugins_$(date +%Y%m%d%H%M)"

# Colors for CLI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------
# Global configuration (centralized)
# Move email/report/health variables here so they're easy to find.
# ------------------------------------------------------------------
# Email / report
MAIL_TO="anil.pedavelli@boydinteractive.com"
MAIL_FROM="deployment@boydinteractive.com"
# Template used to build the final MAIL_SUBJECT at runtime. Tokens: {BRANCH}, {HOST}, {DATE}
MAIL_SUBJECT_TEMPLATE="Deployment Report | Branch: {BRANCH} | Host: {HOST} | {DATE}"
FINAL_REPORT="/tmp/deployment_report_final.html"

# Health check files & credentials
STATUS_FILE="/var/tmp/tomcat_status"
SUMMARY_FILE="/var/tmp/tomcat_summary.log"
TUPWD="test"

# Tomcat wait configuration
# TOTAL_TIMEOUT: total seconds to wait for Tomcat to begin listening on port 8080
# SLEEP_INTERVAL: seconds between checks
TOTAL_TIMEOUT=420   # 7 minutes
SLEEP_INTERVAL=5


timestamp() { date '+%F %T'; }

############################################
# BRANCH LOGIC
############################################
if [[ "$BRANCH_INPUT" == "trunk" ]]; then
    BRANCH="pala"
else
    BRANCH="pala-$BRANCH_INPUT"
fi

echo "$(timestamp): BRANCH = $BRANCH"
echo "$(timestamp): COMPONENT INPUT = $COMPONENT_INPUT"

############################################
# LOAD COMPONENTS + PLUGIN PATTERNS
############################################
COMPONENT_LIST=()
PLUGIN_PATTERNS=()

if [[ ! -f "$LIST_FILE" ]]; then
    echo "$(timestamp): ERROR: List file not found: $LIST_FILE"
    health_check=false
    exit 1
fi

while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
        PLUGIN_PATTERNS+=("${BASH_REMATCH[1]}")
    else
        COMPONENT_LIST+=("$line")
    fi
done < "$LIST_FILE"

echo "$(timestamp): Components from file: ${COMPONENT_LIST[*]}"
echo "$(timestamp): Plugin patterns: ${PLUGIN_PATTERNS[*]}"

############################################
# FILTER COMPONENT LIST IF NOT ALL
############################################
if [[ "$COMPONENT_INPUT" != "ALL" ]]; then
    IFS=',' read -ra REQ_COMPONENTS <<< "$COMPONENT_INPUT"

    FILTERED=()
    for req in "${REQ_COMPONENTS[@]}"; do
        if printf '%s\n' "${COMPONENT_LIST[@]}" | grep -qx "$req"; then
            FILTERED+=("$req")
        else
            echo "$(timestamp): WARNING: Component '$req' not found in components allowed list file $LIST_FILE"
        fi
    done

    COMPONENT_LIST=("${FILTERED[@]}")
fi

# Guard for empty component list
if [[ ${#COMPONENT_LIST[@]} -eq 0 ]]; then
    echo "$(timestamp): No valid components found — skipping deployment and health check."
    exit 0
fi

echo "$(timestamp): Final component list: ${COMPONENT_LIST[*]}"



############################################
# PLUGIN DEPLOYMENT (ALL ONLY)
############################################
if [[ "$COMPONENT_INPUT" == "ALL" && ${#PLUGIN_PATTERNS[@]} -gt 0 ]]; then
    echo -e "${BLUE}>>> Starting plugin deployment...${NC}"
    mkdir -p "$PLUGIN_DIR" || true

    if [[ -n "$(ls -A "$PLUGIN_DIR" 2>/dev/null)" ]]; then
        echo -e "${YELLOW}>>> Backing up plugins to $BACKUP_DIR${NC}"
        mkdir -p "$BACKUP_DIR" || true
        mv "$PLUGIN_DIR"/* "$BACKUP_DIR"/ 2>/dev/null || true
    else
        echo -e "${YELLOW}>>> Plugin directory is empty — nothing to backup${NC}"
    fi

    for pattern in "${PLUGIN_PATTERNS[@]}"; do
        echo -e "${BLUE}  - Processing plugin pattern: $pattern${NC}"
        SRC_PATH="/usr/local/hudson/jobs/$BRANCH/lastStable/archive/$pattern/target/*.jar"

        if ! scp -o StrictHostKeyChecking=yes -i "$SCP_KEY" \
            root@"$JENKINS_HOST":"$SRC_PATH" "$PLUGIN_DIR/" 2>/tmp/plugin_copy_error.log || true; then
            echo -e "${YELLOW}    WARNING: No JAR found for $pattern${NC}"
        else
            echo -e "${GREEN}    OK: Copied plugin(s) for $pattern${NC}"
        fi
    done
else
    echo -e "${BLUE}>>> Plugin deployment skipped (component_input != ALL)${NC}"
fi

############################################
# DEPLOY COMPONENTS
############################################
restart_needed=false
failed_components=()
skipped_components=()
deployed_components=()

for API in "${COMPONENT_LIST[@]}"; do
    echo
    echo -e "${BLUE}********** Deploying Component: $API *********${NC}"
    echo "$(timestamp): Component = $API"
    echo "$(timestamp): Branch    = $BRANCH"

    WAR_DIR="$WAR_BASE/$API"
    mkdir -p "$WAR_DIR" || true
    BUILD_DIR="/usr/local/hudson/jobs/$BRANCH/lastStable/archive/$API/target"

    ########################################
    # AdminEdgeV2 special handling
    ########################################
    if [[ "$API" == "AdminEdgeV2" ]]; then
        echo "$(timestamp): Special case — running AdminEdge deploy logic"
        WAR_DIR="$WAR_BASE/AdminEdge"
        REMOTE_WAR=$(ssh -i "$SCP_KEY" root@$JENKINS_HOST \
            "ls -1 /usr/local/hudson/jobs/$BRANCH/lastStable/archive/AdminEdgeRoot/AdminEdgeV2/build/libs/AdminEdgeV2-*.war 2>/dev/null | sort -V | tail -n1" || true)

        if [[ -z "$REMOTE_WAR" ]]; then
            echo -e "${YELLOW}$(timestamp): WARNING: AdminEdgeV2 WAR not found — skipping${NC}"
            skipped_components+=("$API")
            continue
        fi

        WAR_FILE=$(basename "$REMOTE_WAR")
        NEW_VERSION="${WAR_FILE%.war}"
        NEW_VERSION="${NEW_VERSION/-SNAPSHOT/}"
        TARGET_DIR="$WAR_DIR/$NEW_VERSION"

        CURRENT_LINK=$(readlink "$WAR_DIR/AdminEdge" 2>/dev/null || true)

        echo "$(timestamp): New Version = $NEW_VERSION"
        echo "$(timestamp): Current Version = ${CURRENT_LINK:-NONE}"

        if [[ "$NEW_VERSION" == "$CURRENT_LINK" ]]; then
            echo -e "${YELLOW}$(timestamp): AdminEdge already at version $NEW_VERSION — skipping${NC}"
            skipped_components+=("$API")
            continue
        fi

        mkdir -p "$TARGET_DIR" || true
        scp -C -i "$SCP_KEY" root@$JENKINS_HOST:"$REMOTE_WAR" "$TARGET_DIR/AdminEdge.war" 2>/dev/null || true
        ln -nfs "$NEW_VERSION" "$WAR_DIR/AdminEdge" || true
        [[ -n "$CURRENT_LINK" ]] && ln -nfs "$CURRENT_LINK" "$WAR_DIR/AdminEdge-previous" || true
        chown -R tomcat:services "$WAR_DIR" || true

        echo "$(timestamp): AdminEdge deployment complete."
        deployed_components+=("$API")
        restart_needed=true
        continue
    fi

    ########################################
    # DepositEngine special handling
    ########################################
    if [[ "$API" == "depositengine" ]]; then
        SPECIAL_BUILD_DIR="/usr/local/hudson/jobs/$BRANCH/lastStable/archive/DepositEngine/target"
        REMOTE_WAR=$(ssh -i "$SCP_KEY" root@$JENKINS_HOST \
            "ls -1 $SPECIAL_BUILD_DIR/depositengine-*.war 2>/dev/null | sort -V | tail -n1" || true)

        if [[ -z "$REMOTE_WAR" ]]; then
            echo -e "${YELLOW}$(timestamp): WARNING: DepositEngine WAR not found — skipping${NC}"
            skipped_components+=("$API")
            continue
        fi

        WAR_FILE=$(basename "$REMOTE_WAR")
        NEW_VERSION="${WAR_FILE%.war}"
        NEW_VERSION="${NEW_VERSION/-SNAPSHOT/}"
        TARGET_DIR="$WAR_DIR/$NEW_VERSION"

        CURRENT_LINK=$(readlink "$WAR_DIR/depositengine" 2>/dev/null || true)

        echo "$(timestamp): New Version = $NEW_VERSION"
        echo "$(timestamp): Current Version = ${CURRENT_LINK:-NONE}"

        if [[ "$NEW_VERSION" == "$CURRENT_LINK" ]]; then
            echo -e "${YELLOW}$(timestamp): DepositEngine already at version $NEW_VERSION — skipping${NC}"
            skipped_components+=("$API")
            continue
        fi

        mkdir -p "$TARGET_DIR" || true
        scp -C -i "$SCP_KEY" root@$JENKINS_HOST:"$REMOTE_WAR" "$TARGET_DIR/depositengine.war" 2>/dev/null || true
        ln -nfs "$NEW_VERSION" "$WAR_DIR/depositengine" || true
        [[ -n "$CURRENT_LINK" ]] && ln -nfs "$CURRENT_LINK" "$WAR_DIR/depositengine-previous" || true
        chown -R tomcat:services "$WAR_DIR" || true

        echo "$(timestamp): DepositEngine deployment complete."
        deployed_components+=("$API")
        restart_needed=true
        continue
    fi

    ########################################
    # Normal component deployment
    ########################################
    if [[ ! -d "$WAR_DIR" ]]; then
        echo -e "${RED}$(timestamp): ERROR: Missing directory: $WAR_DIR${NC}"
        failed_components+=("$API")
        continue
    fi

    REMOTE_WAR=$(ssh -i "$SCP_KEY" root@$JENKINS_HOST \
        "ls -1 $BUILD_DIR/${API}-*.war 2>/dev/null | sort -V | tail -n1" 2>/dev/null || true)

    if [[ -z "$REMOTE_WAR" ]]; then
        echo -e "${YELLOW}$(timestamp): WARNING: No WAR found remotely for $API — skipping${NC}"
        skipped_components+=("$API")
        continue
    fi

    WAR_FILE=$(basename "$REMOTE_WAR")
    NEW_VERSION="${WAR_FILE%.war}"
    NEW_VERSION="${NEW_VERSION/-SNAPSHOT/}"
    TARGET_DIR="$WAR_DIR/$NEW_VERSION"

    CURRENT_LINK=$(readlink "$WAR_DIR/$API" 2>/dev/null || true)

    echo "$(timestamp): New Version = $NEW_VERSION"
    echo "$(timestamp): Current Version = ${CURRENT_LINK:-NONE}"

    if [[ "$NEW_VERSION" == "$CURRENT_LINK" ]]; then
        echo -e "${YELLOW}$(timestamp): $API already on version $NEW_VERSION — skipping${NC}"
        skipped_components+=("$API")
        continue
    fi

    mkdir -p "$TARGET_DIR" || true
    scp -C -i "$SCP_KEY" root@$JENKINS_HOST:"$REMOTE_WAR" "$TARGET_DIR/$API.war" 2>/dev/null || true
    ln -nfs "$NEW_VERSION" "$WAR_DIR/$API" || true
    [[ -n "$CURRENT_LINK" ]] && ln -nfs "$CURRENT_LINK" "$WAR_DIR/$API-previous" || true

    chown -R tomcat:services "$WAR_DIR" || true
    chown -R tomcat:services "$PLUGIN_DIR" || true

    echo "$(timestamp): Cleaning Tomcat cache for $API"
    rm -rf "$WAR_BASE/work/Catalina/localhost/$API" 2>/dev/null || true
    rm -rf "$WAR_BASE/webapp/$API" 2>/dev/null || true

    echo "$WAR_FILE" > "$WAR_BASE/$API.current_version" 2>/dev/null || true

    echo "$(timestamp): Deployment of $API complete."
    deployed_components+=("$API")
    restart_needed=true
done



############################################
# TOMCAT RESTART
############################################
echo "===== Tomcat Restart Section ====="
if $restart_needed; then
    echo "===== Tomcat Restart Initiated =====" | tee -a "$LOGFILE" || true
    /sbin/service tomcat stop || true
    sleep 5 || true
    TOMCAT_PID=$(ps -ef | grep tomcat | grep java | awk '{print $2}' || true)
    [[ -n "$TOMCAT_PID" ]] && kill -9 $TOMCAT_PID || true
    sleep 2 || true
    rm -rf /usr/local/tomcat/work/Catalina/localhost/* || true
    # /sbin/service tomcat start || true
    echo "Not restarting Tomcat (testing mode)" | tee -a "$LOGFILE" || true
    sleep 5 || true
else
    echo ">>> Tomcat restart not required" | tee -a "$LOGFILE" || true
fi

############################################
# WAIT FOR TOMCAT PORT
############################################
echo "Waiting for Tomcat (port 8080) to become available..." | tee -a "$LOGFILE" || true
TIME_WAITED=0
FOUND=0
while true; do
    if command -v ss >/dev/null 2>&1; then
        if ss -tnlp 2>/dev/null | grep -q ':8080'; then
            FOUND=1; break
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tnlp 2>/dev/null | grep -q ':8080'; then
            FOUND=1; break
        fi
    else
        # As a last resort try curl to localhost:8080 root (may 404 but will connect)
        if curl --max-time 5 -sS http://127.0.0.1:8080/ >/dev/null 2>&1; then
            FOUND=1; break
        fi
    fi

    if (( TIME_WAITED >= TOTAL_TIMEOUT )); then
        echo "ERROR: Tomcat did not start listening on port 8080 within ${TOTAL_TIMEOUT}s." | tee -a "$LOGFILE" || true
        break
    fi
    sleep "$SLEEP_INTERVAL"
    TIME_WAITED=$((TIME_WAITED + SLEEP_INTERVAL))
done

if [[ $FOUND -eq 1 ]]; then
    echo "Tomcat is now listening on port 8080 (waited ${TIME_WAITED}s)." | tee -a "$LOGFILE" || true
else
    echo "Continuing to health checks even though Tomcat did not appear to listen on port 8080." | tee -a "$LOGFILE" || true
fi

############################################
# TOMCAT HEALTH CHECK
############################################
echo "===== Running Tomcat Application Health Check =====" | tee -a "$LOGFILE" || true
> "$STATUS_FILE" || true
> "$SUMMARY_FILE" || true

declare -A HEALTHCHECK_DIR_MAP
for app in "${COMPONENT_LIST[@]}"; do
    case "$app" in
        AdminEdgeV2)
            CURRENT_LINK=$(readlink "$WAR_BASE/AdminEdge/AdminEdge" || true)
            if [[ -n "$CURRENT_LINK" ]]; then
                HEALTHCHECK_DIR_MAP[$app]="$WAR_BASE/AdminEdge/"
            else
                CURRENT_VERSION=$(cat "$WAR_BASE/AdminEdge/AdminEdge.current_version" 2>/dev/null || "")
                HEALTHCHECK_DIR_MAP[$app]="$WAR_BASE/AdminEdge/$CURRENT_VERSION"
            fi
            ;;
        depositengine|DepositEngineV3)
            CURRENT_LINK=$(readlink "$WAR_BASE/depositengine/depositengine" || true)
            if [[ -n "$CURRENT_LINK" ]]; then
                HEALTHCHECK_DIR_MAP[$app]="$WAR_BASE/depositengine/"
            else
                CURRENT_VERSION=$(cat "$WAR_BASE/depositengine/depositengine.current_version" 2>/dev/null || "")
                HEALTHCHECK_DIR_MAP[$app]="$WAR_BASE/depositengine/$CURRENT_VERSION"
            fi
            ;;
        GeoIPIntegration)
            CURRENT_LINK=$(readlink "$WAR_BASE/geoIPIntegration/geoIPIntegration" || true)
            HEALTHCHECK_DIR_MAP[$app]="${CURRENT_LINK:-$WAR_BASE/geoIPIntegration}" ;;
        birt-viewer)
            HEALTHCHECK_DIR_MAP[$app]="$WAR_BASE/webapps/birt-viewer" ;;
        *)
            HEALTHCHECK_DIR_MAP[$app]="$WAR_BASE/$app" ;;
    esac
done



FAILED_HEALTH_CHECKS=()
SKIPPED_HEALTH_CHECKS=()
PASSED_HEALTH_CHECKS=()

for app in "${COMPONENT_LIST[@]}"; do
    APP_DIR="${HEALTHCHECK_DIR_MAP[$app]}"
    > "$STATUS_FILE" || true

    if [[ ! -d "$APP_DIR" ]]; then
        echo "Skipping health check for $app — directory $APP_DIR not present" | tee -a "$LOGFILE" || true
        SKIPPED_HEALTH_CHECKS+=("$app")
        echo "$app: SKIPPED" >> "$SUMMARY_FILE" || true
        continue
    fi

    echo "Checking $app status" | tee -a "$LOGFILE" || true
    /usr/lib64/nagios/plugins/check_TomcatApplication.sh \
        -u tadmin -p "$tupwd" --host localhost -P 8080 -a "$app" >> "$STATUS_FILE" 2>&1 || true

    if grep -qi "CRITICAL" "$STATUS_FILE"; then
        echo -e "$app: ${RED}FAILED${NC}" | tee -a "$LOGFILE" || true
        FAILED_HEALTH_CHECKS+=("$app")
        echo "$app: FAILED" >> "$SUMMARY_FILE" || true
    else
        echo -e "$app: ${GREEN}OK${NC}" | tee -a "$LOGFILE" || true
        PASSED_HEALTH_CHECKS+=("$app")
        echo "$app: OK" >> "$SUMMARY_FILE" || true
    fi
done


############################################
# DEPLOYMENT SUMMARY
############################################
echo ""
echo "===== Deployment Summary =====" | tee -a "$LOGFILE" || true
echo "Components attempted: ${COMPONENT_LIST[*]:-None}" | tee -a "$LOGFILE" || true
echo -n "Deployed successfully: " | tee -a "$LOGFILE" || true
[[ ${#deployed_components[@]} -gt 0 ]] && echo "${deployed_components[*]}" | tee -a "$LOGFILE" || echo "None" | tee -a "$LOGFILE"
echo -n "Skipped (deployment): " | tee -a "$LOGFILE" || true
[[ ${#skipped_components[@]} -gt 0 ]] && echo "${skipped_components[*]}" | tee -a "$LOGFILE" || echo "None" | tee -a "$LOGFILE"
echo -n "Failed deployments: " | tee -a "$LOGFILE" || true
[[ ${#failed_components[@]} -gt 0 ]] && echo "${failed_components[*]}" | tee -a "$LOGFILE" || echo "None" | tee -a "$LOGFILE"

############################################
# HEALTH CHECK SUMMARY
############################################
echo ""
echo "===== Health Check Summary =====" | tee -a "$LOGFILE" || true
echo -n "Health check passed: " | tee -a "$LOGFILE" || true
[[ ${#PASSED_HEALTH_CHECKS[@]} -gt 0 ]] && echo "${PASSED_HEALTH_CHECKS[*]}" | tee -a "$LOGFILE" || echo "None" | tee -a "$LOGFILE"
echo -n "Health check skipped: " | tee -a "$LOGFILE" || true
[[ ${#SKIPPED_HEALTH_CHECKS[@]} -gt 0 ]] && echo "${SKIPPED_HEALTH_CHECKS[*]}" | tee -a "$LOGFILE" || echo "None" | tee -a "$LOGFILE"
echo -n "Health check failed: " | tee -a "$LOGFILE" || true
[[ ${#FAILED_HEALTH_CHECKS[@]} -gt 0 ]] && echo "${FAILED_HEALTH_CHECKS[*]}" | tee -a "$LOGFILE" || echo "None" | tee -a "$LOGFILE"



############################################
# EXIT CODE
############################################
exit_code=0
[[ ${#failed_components[@]} -gt 0 ]] && exit_code=1

############################################
# HTML REPORT & EMAIL
############################################
# `MAIL_TO`, `MAIL_FROM`, `MAIL_SUBJECT_TEMPLATE`, and `FINAL_REPORT`
# are defined in the top-level configuration. Build the runtime subject
# by substituting tokens in the template.
MAIL_SUBJECT="${MAIL_SUBJECT_TEMPLATE//\{BRANCH\}/$BRANCH}"
MAIL_SUBJECT="${MAIL_SUBJECT//\{HOST\}/$SERVER_HOST}"
MAIL_SUBJECT="${MAIL_SUBJECT//\{DATE\}/$(date '+%F %T')}"

declare -A HEALTH_MAP
declare -A VERSION_MAP

for app in "${COMPONENT_LIST[@]}"; do
    status_line=$(grep "^$app:" "$SUMMARY_FILE" || true)
    status=$(echo "$status_line" | awk -F: '{print $2}' | xargs)
    color_status="red"
    [[ "$status" == "OK" ]] && color_status="green"
    HEALTH_MAP["$app"]="<span style='color:$color_status;font-weight:bold;'>${status:-UNKNOWN}</span>"

    if [[ "$app" == "AdminEdgeV2" ]]; then
        version_file="$WAR_BASE/AdminEdge/AdminEdge.current_version"
    else
        version_file="$WAR_BASE/$app.current_version"
    fi

    VERSION_MAP["$app"]="$(cat "$version_file" 2>/dev/null || echo "N/A")"
done

{
echo "<html><body style='font-family: Arial, sans-serif;'>"
echo "<h2>🖥️ Deployment Report</h2>"
echo "<p><strong>Server:</strong> $SERVER_HOST<br>"
echo "<strong>Branch:</strong> $BRANCH<br>"
echo "<strong>Date:</strong> $(date '+%F %T')<br>"
echo "<strong>Log file:</strong> $SERVER_HOST:$LOGFILE</p>"

echo "<h3>Component Summary</h3>"
echo "<ul>"
echo "<li><strong>Attempted:</strong> ${COMPONENT_LIST[*]}</li>"
echo "<li><strong>Deployed:</strong> ${deployed_components[*]:-None}</li>"
echo "<li><strong>Skipped:</strong> ${skipped_components[*]:-None}</li>"
echo "<li><strong style='color:red;'>Failed:</strong> ${failed_components[*]:-None}</li>"
echo "</ul>"

echo "<h3>Tomcat Health Status</h3>"
echo "<table style='border-collapse: collapse; width: 70%;'>"
echo "<tr><th style='border: 1px solid #ddd; padding: 8px; text-align:left;'>Application</th>"
echo "<th style='border: 1px solid #ddd; padding: 8px;'>Status</th>"
echo "<th style='border: 1px solid #ddd; padding: 8px;'>Version</th></tr>"

for app in "${COMPONENT_LIST[@]}"; do
    echo "<tr>"
    echo "<td style='border: 1px solid #ddd; padding: 8px;'>$app</td>"
    echo "<td style='border: 1px solid #ddd; padding: 8px;'>${HEALTH_MAP[$app]}</td>"
    echo "<td style='border: 1px solid #ddd; padding: 8px;'>${VERSION_MAP[$app]}</td>"
    echo "</tr>"
done
echo "</table>"

if [[ ${#failed_components[@]} -ne 0 ]]; then
    echo "<p style='color:red;font-weight:bold;'>❌ Deployment completed with errors</p>"
else
    echo "<p style='color:green;font-weight:bold;'>✅ Deployment completed successfully</p>"
fi

echo "<h3>Notes</h3>"
echo "<ul>"
echo "<li>Skipped components were already on the latest version or not present on this server.</li>"
echo "<li>For full details, check the log file listed above.</li>"
echo "</ul>"
echo "</body></html>"
} > "$FINAL_REPORT"

{
    echo "Subject: $MAIL_SUBJECT"
    echo "From: $MAIL_FROM"
    echo "To: $MAIL_TO"
    echo "Content-Type: text/html"
    echo
    cat "$FINAL_REPORT"
} | /usr/sbin/sendmail -t || true

exit $exit_code
