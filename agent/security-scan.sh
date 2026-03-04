#!/usr/bin/env bash
# =============================================================================
# Marvin — Daily Security Scan
# =============================================================================
# Runs rkhunter and chkrootkit to detect rootkits, backdoors, and local
# exploits. Results are saved as JSON for the dashboard and logged.
#
# Cron: 04:00 UTC daily (before morning-check)
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

SECURITY_DIR="${DATA_DIR}/security"
REPORT_FILE="${SECURITY_DIR}/scan-${TODAY}.json"

mkdir -p "$SECURITY_DIR"

marvin_log "INFO" "=== DAILY SECURITY SCAN STARTING ==="

rkhunter_status="skipped"
rkhunter_warnings=0
rkhunter_infected=0
rkhunter_summary=""

chkrootkit_status="skipped"
chkrootkit_infected=0
chkrootkit_summary=""

# ─── 1. rkhunter scan ───────────────────────────────────────────────────────

if command -v rkhunter &>/dev/null; then
    marvin_log "INFO" "Running rkhunter scan..."

    # Update file properties database first (suppresses false positives from updates)
    rkhunter --propupd --quiet 2>/dev/null || true

    RKHUNTER_LOG="/var/log/rkhunter-marvin-${TODAY}.log"

    # Run the scan (--skip-keypress avoids interactive prompts)
    # --report-warnings-only keeps output concise
    if rkhunter --check --skip-keypress --report-warnings-only \
        --logfile "$RKHUNTER_LOG" --no-colors 2>&1; then
        rkhunter_status="clean"
        marvin_log "INFO" "rkhunter: no warnings"
    else
        rkhunter_status="warnings"
        marvin_log "WARN" "rkhunter: warnings detected — check ${RKHUNTER_LOG}"
    fi

    # Parse the log for summary
    if [[ -f "$RKHUNTER_LOG" ]]; then
        rkhunter_warnings=$(grep -c '\[ Warning \]' "$RKHUNTER_LOG" 2>/dev/null | tr -d '[:space:]' || echo 0)
        rkhunter_infected=$(grep -c '\[ Infected \]' "$RKHUNTER_LOG" 2>/dev/null | tr -d '[:space:]' || echo 0)
        rkhunter_summary=$(grep -E '\[ Warning \]|\[ Infected \]' "$RKHUNTER_LOG" 2>/dev/null | head -20 || echo "")

        if [[ "$rkhunter_infected" -gt 0 ]]; then
            rkhunter_status="infected"
            marvin_log "CRITICAL" "rkhunter found ${rkhunter_infected} infected file(s)!"
        fi
    fi

    # Clean up old scan logs (keep 7 days)
    find /var/log -name 'rkhunter-marvin-*.log' -mtime +7 -delete 2>/dev/null || true
else
    marvin_log "WARN" "rkhunter not installed — skipping"
fi

# ─── 2. chkrootkit scan ─────────────────────────────────────────────────────

if command -v chkrootkit &>/dev/null; then
    marvin_log "INFO" "Running chkrootkit scan..."

    CHKROOTKIT_OUTPUT=$(chkrootkit 2>&1) || true

    # chkrootkit reports "INFECTED" for actual findings
    chkrootkit_infected=$(echo "$CHKROOTKIT_OUTPUT" | grep -c "INFECTED" 2>/dev/null | tr -d '[:space:]' || echo 0)
    chkrootkit_summary=$(echo "$CHKROOTKIT_OUTPUT" | grep "INFECTED" 2>/dev/null | head -20 || echo "")

    if [[ "$chkrootkit_infected" -gt 0 ]]; then
        chkrootkit_status="infected"
        marvin_log "CRITICAL" "chkrootkit found ${chkrootkit_infected} infected item(s)!"
    else
        chkrootkit_status="clean"
        marvin_log "INFO" "chkrootkit: clean"
    fi
else
    marvin_log "WARN" "chkrootkit not installed — skipping"
fi

# ─── 3. Additional security checks ──────────────────────────────────────────

# Check for world-writable files in sensitive locations
world_writable=$(find /etc /usr/bin /usr/sbin -type f -perm -o+w 2>/dev/null | head -20 || echo "")
world_writable_count=0
if [[ -n "$world_writable" ]]; then
    world_writable_count=$(echo "$world_writable" | wc -l)
    marvin_log "WARN" "Found ${world_writable_count} world-writable files in sensitive paths"
fi

# Check for SUID/SGID binaries (just count — changes from last scan are interesting)
suid_count=$(find /usr/bin /usr/sbin /usr/local/bin -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | wc -l || echo 0)

# Check for unauthorized listening ports (capture once, reuse below)
ss_output=$(ss -tlnp 2>/dev/null || echo "")
listening_ports=$(echo "$ss_output" | tail -n +2)
port_count=0

# Expected ports baseline — alert on anything not in this list
# Update this list when installing new services to avoid false-positive warnings.
# 22=SSH, 25=SMTP, 53=DNS(systemd-resolved), 80=HTTP, 443=HTTPS,
# 465=SMTPS, 587=STARTTLS, 631=CUPS(system dependency, localhost only), 993=IMAPS, 3000=Next.js,
# 6379=Redis(local), 8043=alt-HTTPS, 11332-11334=Rspamd(local)
EXPECTED_PORTS="22 25 53 80 443 465 587 631 993 3000 6379 8043 11332 11333 11334"

# Extract unique port numbers from listening sockets
active_ports=$(echo "$listening_ports" | awk '{print $4}' | grep -oP '\d+$' | sort -un)
# Count from deduplicated list to stay consistent with active_ports (avoids IPv4+IPv6 double-counting)
port_count=$(echo "$active_ports" | grep -c '[0-9]' 2>/dev/null || echo 0)
unexpected_ports=""
unexpected_count=0
unexpected_details_json="[]"

# Ports expected only on localhost — alert if bound to 0.0.0.0 or [::]
LOCALHOST_ONLY_PORTS="631 6379 11332 11333 11334"

for port in $active_ports; do
    if ! echo "$EXPECTED_PORTS" | grep -qw "$port"; then
        unexpected_ports="${unexpected_ports}${unexpected_ports:+, }${port}"
        unexpected_count=$((unexpected_count + 1))
        # Log the process listening on this unexpected port (reuse captured ss output)
        proc_info=$(echo "$ss_output" | grep ":${port} " | awk '{print $6}' | head -1)
        marvin_log "WARN" "Unexpected listener on port ${port}: ${proc_info}"
        # Accumulate details for JSON
        unexpected_details_json=$(echo "$unexpected_details_json" | jq --arg p "$port" --arg proc "$proc_info" '. + [{"port": ($p | tonumber), "process": $proc}]' 2>/dev/null || echo "$unexpected_details_json")
    fi
done

# Verify localhost-only ports are not bound to public interfaces
for port in $LOCALHOST_ONLY_PORTS; do
    if echo "$listening_ports" | grep -qP "(\*|0\.0\.0\.0|\[::\]):${port}\b"; then
        marvin_log "WARN" "Port ${port} expected localhost-only but bound to public interface"
    fi
done

if [[ "$unexpected_count" -gt 0 ]]; then
    marvin_log "WARN" "Found ${unexpected_count} unexpected listening port(s): ${unexpected_ports}"
fi

# Save port inventory for trending
PORT_INVENTORY="${SECURITY_DIR}/port-inventory.json"
port_list_json=$(echo "$active_ports" | jq -Rn '[inputs | select(. != "") | tonumber]' 2>/dev/null || echo "[]")
cat > "$PORT_INVENTORY" << PORTEOF
{
  "timestamp": "${NOW}",
  "total_ports": ${port_count},
  "unexpected_count": ${unexpected_count},
  "unexpected_ports": "${unexpected_ports}",
  "unexpected_port_details": ${unexpected_details_json},
  "expected_ports": "${EXPECTED_PORTS}",
  "active_ports": ${port_list_json}
}
PORTEOF
chmod 644 "$PORT_INVENTORY"

# ─── 4. File integrity monitoring ─────────────────────────────────────────────

FIM_SCRIPT="$(dirname "$0")/file-integrity.sh"
fim_status="skipped"
fim_changes=0
fim_missing=0

if [[ -x "$FIM_SCRIPT" ]]; then
    marvin_log "INFO" "Running file integrity check..."
    "$FIM_SCRIPT" 2>&1 || true

    FIM_REPORT="${SECURITY_DIR}/file-integrity-latest.json"
    if [[ -f "$FIM_REPORT" ]]; then
        fim_status=$(jq -r '.status // "unknown"' "$FIM_REPORT" 2>/dev/null || echo "unknown")
        fim_changes=$(jq '.changes | length' "$FIM_REPORT" 2>/dev/null || echo 0)
        fim_missing=$(jq '.missing_files | length' "$FIM_REPORT" 2>/dev/null || echo 0)

        if [[ "$fim_status" == "alert" ]]; then
            marvin_log "WARN" "File integrity alert: ${fim_changes} changed, ${fim_missing} missing"
        else
            marvin_log "INFO" "File integrity: ${fim_status}"
        fi
    fi
else
    marvin_log "WARN" "file-integrity.sh not found — skipping"
fi

# ─── 5. CVE / package vulnerability monitoring ──────────────────────────────

marvin_log "INFO" "Checking for security-relevant package updates..."

# Refresh package lists (quiet, non-interactive)
apt-get update -qq 2>/dev/null || true

# Check for upgradable packages and identify security updates
upgradable_all=0
upgradable_security=0
upgradable_list=""
security_list=""

if upgradable_raw=$(apt list --upgradable 2>/dev/null | tail -n +2); then
    upgradable_all=$(echo "$upgradable_raw" | grep -c '[a-z]' || true)
    # Security updates come from *-security repositories
    security_raw=$(echo "$upgradable_raw" | grep -i 'security' 2>/dev/null || echo "")
    if [[ -n "$security_raw" ]]; then
        upgradable_security=$(echo "$security_raw" | wc -l | tr -d ' ')
        security_list=$(echo "$security_raw" | head -20)
        marvin_log "WARN" "Found ${upgradable_security} pending security update(s)"
    fi
    upgradable_list=$(echo "$upgradable_raw" | head -30)
fi

# Check for packages with known CVEs using ubuntu-security-status (if available)
esm_infra=0
esm_apps=0
cve_status="unknown"
if command -v ubuntu-security-status &>/dev/null; then
    uss_output=$(ubuntu-security-status 2>/dev/null || echo "")
    esm_infra=$(echo "$uss_output" | grep -oP '\d+(?= packages from Ubuntu Main)' 2>/dev/null || echo 0)
    esm_apps=$(echo "$uss_output" | grep -oP '\d+(?= packages from Ubuntu Universe)' 2>/dev/null || echo 0)
    cve_status="checked"
fi

# Parse recent unattended-upgrades activity (all-time from current log)
auto_patched=0
if [[ -f /var/log/unattended-upgrades/unattended-upgrades.log ]]; then
    auto_patched=$(grep -c "Packages that will be upgraded" \
        /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null || true)
    # Ensure numeric value (grep -c may return empty on error)
    auto_patched=${auto_patched:-0}
fi

# Write CVE report
CVE_REPORT="${SECURITY_DIR}/cve-status.json"
cat > "$CVE_REPORT" << CVEEOF
{
  "timestamp": "${NOW}",
  "upgradable_total": ${upgradable_all},
  "upgradable_security": ${upgradable_security},
  "security_packages": $(echo "$security_list" | jq -R -s 'split("\n") | map(select(. != ""))' 2>/dev/null || echo "[]"),
  "all_upgradable": $(echo "$upgradable_list" | jq -R -s 'split("\n") | map(select(. != ""))' 2>/dev/null || echo "[]"),
  "auto_patches_applied": ${auto_patched},
  "esm_main_packages": ${esm_infra},
  "esm_universe_packages": ${esm_apps},
  "cve_check_status": "${cve_status}"
}
CVEEOF
chmod 644 "$CVE_REPORT"

marvin_log "INFO" "CVE status: ${upgradable_all} upgradable (${upgradable_security} security), ${auto_patched} auto-patched"

# ─── 6. Generate report ─────────────────────────────────────────────────────

# Determine overall status
overall_status="clean"
if [[ "$rkhunter_status" == "infected" || "$chkrootkit_status" == "infected" ]]; then
    overall_status="infected"
elif [[ "$fim_status" == "alert" ]]; then
    overall_status="alert"
elif [[ "$rkhunter_status" == "warnings" || "$world_writable_count" -gt 0 || "$upgradable_security" -gt 0 || "$unexpected_count" -gt 0 ]]; then
    overall_status="warnings"
fi

cat > "$REPORT_FILE" << EOF
{
  "timestamp": "${NOW}",
  "overall_status": "${overall_status}",
  "rkhunter": {
    "status": "${rkhunter_status}",
    "warnings": ${rkhunter_warnings},
    "infected": ${rkhunter_infected},
    "summary": $(echo "$rkhunter_summary" | jq -Rs '.' 2>/dev/null || echo '""')
  },
  "chkrootkit": {
    "status": "${chkrootkit_status}",
    "infected": ${chkrootkit_infected},
    "summary": $(echo "$chkrootkit_summary" | jq -Rs '.' 2>/dev/null || echo '""')
  },
  "file_integrity": {
    "status": "${fim_status}",
    "changes": ${fim_changes},
    "missing": ${fim_missing},
    "world_writable_count": ${world_writable_count},
    "suid_sgid_count": ${suid_count}
  },
  "cve_monitoring": {
    "upgradable_total": ${upgradable_all},
    "upgradable_security": ${upgradable_security},
    "auto_patches_applied": ${auto_patched}
  },
  "network": {
    "listening_ports": ${port_count},
    "unexpected_ports": ${unexpected_count},
    "unexpected_port_list": "${unexpected_ports}",
    "unexpected_port_details": ${unexpected_details_json}
  }
}
EOF

# Also maintain a latest scan pointer for the dashboard
cp "$REPORT_FILE" "${SECURITY_DIR}/latest-scan.json"
chmod 644 "${SECURITY_DIR}/latest-scan.json"

# Clean up old scan reports (keep 30 days)
find "$SECURITY_DIR" -name 'scan-*.json' -mtime +30 -delete 2>/dev/null || true

marvin_log "INFO" "Security scan report: ${REPORT_FILE}"
marvin_log "INFO" "Overall status: ${overall_status} (rkhunter: ${rkhunter_status}, chkrootkit: ${chkrootkit_status})"
marvin_log "INFO" "=== DAILY SECURITY SCAN COMPLETE ==="
