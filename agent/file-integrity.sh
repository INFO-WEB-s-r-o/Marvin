#!/usr/bin/env bash
# =============================================================================
# Marvin — File Integrity Monitoring
# =============================================================================
# Maintains SHA-256 checksums for critical system and agent files.
# On first run, creates a baseline. On subsequent runs, compares against
# the baseline and alerts on any unexpected changes.
#
# Baseline is refreshed when Marvin intentionally modifies files (via
# self-enhance, morning-check git pull, etc.) by calling:
#   agent/file-integrity.sh --update
#
# Cron: Runs as part of security-scan.sh (daily at 04:00 UTC)
#       Can also run standalone: agent/file-integrity.sh [--update]
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

SECURITY_DIR="${DATA_DIR}/security"
BASELINE_FILE="${SECURITY_DIR}/file-integrity-baseline.json"
REPORT_FILE="${SECURITY_DIR}/file-integrity-${TODAY}.json"

mkdir -p "$SECURITY_DIR"

# ─── Files to monitor ────────────────────────────────────────────────────────
# Critical system configs, agent scripts, and security-sensitive files.
# Directories are expanded into their files at scan time.

MONITORED_PATHS=(
    # SSH
    /etc/ssh/sshd_config
    # Firewall
    /etc/ufw/user.rules
    /etc/ufw/user6.rules
    # Fail2ban
    /etc/fail2ban/jail.local
    # Nginx
    /etc/nginx/nginx.conf
    # Cron
    /etc/cron.d/marvin
    # PAM (auth stack)
    /etc/pam.d/sshd
    # Sudoers
    /etc/sudoers
    # Name resolution
    /etc/hosts
    /etc/resolv.conf
    # Marvin agent scripts
    "${MARVIN_DIR}/agent/common.sh"
    "${MARVIN_DIR}/agent/health-monitor.sh"
    "${MARVIN_DIR}/agent/morning-check.sh"
    "${MARVIN_DIR}/agent/self-enhance.sh"
    "${MARVIN_DIR}/agent/log-export.sh"
    "${MARVIN_DIR}/agent/security-scan.sh"
    "${MARVIN_DIR}/agent/self-test.sh"
    "${MARVIN_DIR}/agent/lib/github.sh"
)

# Also include all nginx site configs
for f in /etc/nginx/sites-enabled/*; do
    [[ -f "$f" ]] && MONITORED_PATHS+=("$f")
done

# And all fail2ban jail configs
for f in /etc/fail2ban/jail.d/*.conf; do
    [[ -f "$f" ]] && MONITORED_PATHS+=("$f")
done

# ─── Compute checksums ───────────────────────────────────────────────────────

compute_checksums() {
    local result="{"
    local first=true

    for filepath in "${MONITORED_PATHS[@]}"; do
        [[ -f "$filepath" ]] || continue

        local hash
        hash=$(sha256sum "$filepath" 2>/dev/null | awk '{print $1}')
        local size
        size=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
        local mtime
        mtime=$(stat -c%Y "$filepath" 2>/dev/null || echo 0)

        if [[ "$first" == "true" ]]; then
            first=false
        else
            result+=","
        fi

        # Escape the filepath for JSON
        local escaped_path
        escaped_path=$(printf '%s' "$filepath" | sed 's/"/\\"/g')

        result+="\"${escaped_path}\":{\"sha256\":\"${hash}\",\"size\":${size},\"mtime\":${mtime}}"
    done

    result+="}"
    echo "$result" | jq '.'
}

# ─── Mode: Update baseline ───────────────────────────────────────────────────

if [[ "${1:-}" == "--update" ]]; then
    marvin_log "INFO" "File integrity: updating baseline"
    checksums=$(compute_checksums)
    jq -n --argjson files "$checksums" --arg ts "$NOW" \
        '{created: $ts, files: $files}' > "$BASELINE_FILE"
    chmod 600 "$BASELINE_FILE"
    marvin_log "INFO" "File integrity baseline updated: $(echo "$checksums" | jq 'keys | length') files"
    exit 0
fi

# ─── Mode: Check against baseline ────────────────────────────────────────────

marvin_log "INFO" "File integrity check starting"

# If no baseline exists, create one and exit clean
if [[ ! -f "$BASELINE_FILE" ]]; then
    marvin_log "INFO" "No baseline found — creating initial baseline"
    checksums=$(compute_checksums)
    jq -n --argjson files "$checksums" --arg ts "$NOW" \
        '{created: $ts, files: $files}' > "$BASELINE_FILE"
    chmod 600 "$BASELINE_FILE"

    # Report: baseline created, no changes to report
    cat > "$REPORT_FILE" << EOF
{
  "timestamp": "${NOW}",
  "status": "baseline_created",
  "files_monitored": $(echo "$checksums" | jq 'keys | length'),
  "changes": [],
  "new_files": [],
  "missing_files": []
}
EOF
    chmod 644 "$REPORT_FILE"
    marvin_log "INFO" "File integrity baseline created with $(echo "$checksums" | jq 'keys | length') files"
    exit 0
fi

# Compute current checksums
current=$(compute_checksums)
baseline_files=$(jq '.files' "$BASELINE_FILE")
baseline_ts=$(jq -r '.created' "$BASELINE_FILE")

CHANGED=()
NEW_FILES=()
MISSING=()

# Check each file in baseline
while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue

    baseline_hash=$(echo "$baseline_files" | jq -r --arg f "$filepath" '.[$f].sha256 // ""')
    current_hash=$(echo "$current" | jq -r --arg f "$filepath" '.[$f].sha256 // ""')

    if [[ -z "$current_hash" ]]; then
        # File no longer exists or not in current scan
        if [[ ! -f "$filepath" ]]; then
            MISSING+=("$filepath")
            marvin_log "WARN" "File integrity: MISSING — ${filepath}"
        fi
    elif [[ "$baseline_hash" != "$current_hash" ]]; then
        CHANGED+=("$filepath")
        marvin_log "WARN" "File integrity: CHANGED — ${filepath}"
    fi
done < <(echo "$baseline_files" | jq -r 'keys[]')

# Check for new files in current scan that weren't in baseline
while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue
    baseline_hash=$(echo "$baseline_files" | jq -r --arg f "$filepath" '.[$f].sha256 // ""')
    if [[ -z "$baseline_hash" ]]; then
        NEW_FILES+=("$filepath")
        marvin_log "INFO" "File integrity: NEW — ${filepath}"
    fi
done < <(echo "$current" | jq -r 'keys[]')

# Determine status
status="clean"
if [[ ${#CHANGED[@]} -gt 0 || ${#MISSING[@]} -gt 0 ]]; then
    status="alert"
fi

# Build JSON arrays
changed_json="[]"
if [[ ${#CHANGED[@]} -gt 0 ]]; then
    changed_json=$(printf '%s\n' "${CHANGED[@]}" | jq -R . | jq -s .)
fi

missing_json="[]"
if [[ ${#MISSING[@]} -gt 0 ]]; then
    missing_json=$(printf '%s\n' "${MISSING[@]}" | jq -R . | jq -s .)
fi

new_json="[]"
if [[ ${#NEW_FILES[@]} -gt 0 ]]; then
    new_json=$(printf '%s\n' "${NEW_FILES[@]}" | jq -R . | jq -s .)
fi

# Write report
cat > "$REPORT_FILE" << EOF
{
  "timestamp": "${NOW}",
  "status": "${status}",
  "baseline_created": "${baseline_ts}",
  "files_monitored": $(echo "$current" | jq 'keys | length'),
  "changes": ${changed_json},
  "new_files": ${new_json},
  "missing_files": ${missing_json}
}
EOF
chmod 644 "$REPORT_FILE"

# Also maintain a latest pointer
cp "$REPORT_FILE" "${SECURITY_DIR}/file-integrity-latest.json"

total_changes=$((${#CHANGED[@]} + ${#MISSING[@]}))
marvin_log "INFO" "File integrity check complete: ${status} (${total_changes} change(s), ${#NEW_FILES[@]} new)"

# If changes detected, this is notable
if [[ "$status" == "alert" ]]; then
    marvin_log "WARN" "File integrity ALERT: ${#CHANGED[@]} changed, ${#MISSING[@]} missing since baseline (${baseline_ts})"
fi
