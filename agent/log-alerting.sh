#!/usr/bin/env bash
# =============================================================================
# Marvin — Log-Based Alerting
# =============================================================================
# Scans Marvin's logs for repeated errors, critical events, and error rate
# spikes. Maintains an active alert file for dashboard consumption.
# Auto-resolves alerts when conditions clear.
#
# No Claude API call — pure log analysis with jq.
#
# Cron: hourly at :50 (after hourly-check at :35)
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

ALERTS_DIR="${DATA_DIR}/alerts"
ALERTS_FILE="${ALERTS_DIR}/active-alerts.json"
ALERT_HISTORY="${ALERTS_DIR}/alert-history-${TODAY}.jsonl"

mkdir -p "$ALERTS_DIR"

marvin_log "INFO" "Log alerting scan starting"

LOG_FILE="${LOGS_DIR}/${TODAY}.log"
if [[ ! -f "$LOG_FILE" ]]; then
    marvin_log "INFO" "No log file for ${TODAY} — skipping"
    exit 0
fi

# Load existing alerts (or start fresh)
if [[ -f "$ALERTS_FILE" ]]; then
    existing_alerts=$(jq '.' "$ALERTS_FILE" 2>/dev/null || echo '{"alerts":[]}')
else
    existing_alerts='{"alerts":[]}'
fi

NEW_ALERTS=()

# ─── Helper: create alert JSON ──────────────────────────────────────────────
_make_alert() {
    local id="$1" severity="$2" title="$3" detail="$4" count="$5"
    jq -nc \
        --arg id "$id" \
        --arg sev "$severity" \
        --arg title "$title" \
        --arg detail "$detail" \
        --argjson count "$count" \
        --arg first "$NOW" \
        --arg last "$NOW" \
        '{id: $id, severity: $sev, title: $title, detail: $detail, count: $count, first_seen: $first, last_seen: $last, resolved: false}'
}

# ─── 1. Detect repeated errors (same message > 3 times in today's log) ──────
# Group errors by message (stripped of timestamp), flag repeats

_error_lines=$(grep -E '\[(CRITICAL|ERROR)\]' "$LOG_FILE" 2>/dev/null || true)
if [[ -n "$_error_lines" ]]; then
    # Strip timestamp, deduplicate, count occurrences
    while IFS= read -r line; do
        count=$(echo "$line" | awk '{print $1}')
        msg=$(echo "$line" | sed 's/^[[:space:]]*[0-9]* //')
        # Only alert if the same error appears > 3 times
        if [[ "$count" -gt 3 ]]; then
            # Create a stable ID from the message hash
            alert_id="repeated-$(echo "$msg" | md5sum | cut -c1-12)"
            NEW_ALERTS+=("$(_make_alert "$alert_id" "warning" "Repeated error (${count}x)" "$msg" "$count")")
        fi
    done < <(echo "$_error_lines" | sed 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn | head -10)
fi

# ─── 2. Detect CRITICAL events (any CRITICAL is an alert) ───────────────────

critical_lines=$(grep '\[CRITICAL\]' "$LOG_FILE" 2>/dev/null || true)
critical_count=0
if [[ -n "$critical_lines" ]]; then
    critical_count=$(echo "$critical_lines" | wc -l | tr -d ' ')
    # Get the most recent critical message
    latest_critical=$(echo "$critical_lines" | tail -1 | sed 's/^\[[^]]*\] //')
    alert_id="critical-$(echo "$latest_critical" | md5sum | cut -c1-12)"
    NEW_ALERTS+=("$(_make_alert "$alert_id" "critical" "Critical event detected" "$latest_critical" "$critical_count")")
fi

# ─── 3. Detect error rate spikes ────────────────────────────────────────────
# Compare last hour's error count to the daily average rate

now_epoch=$(date +%s)
one_hour_ago=$(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M 2>/dev/null || echo "")

if [[ -n "$one_hour_ago" ]]; then
    # Count errors in the last hour by checking timestamps
    recent_errors=$(awk -v cutoff="$one_hour_ago" '$0 ~ /\[(ERROR|CRITICAL)\]/ && $1 >= "["cutoff {count++} END {print count+0}' "$LOG_FILE" 2>/dev/null || echo 0)

    # Get total errors and hours elapsed to compute average rate
    total_errors=$(grep -cE '\[(ERROR|CRITICAL)\]' "$LOG_FILE" 2>/dev/null || true)
    total_errors=${total_errors:-0}
    # Estimate hours elapsed today
    first_log_ts=$(head -1 "$LOG_FILE" 2>/dev/null | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' || echo "")
    if [[ -n "$first_log_ts" ]]; then
        first_epoch=$(date -d "$first_log_ts" +%s 2>/dev/null || echo "$now_epoch")
        hours_elapsed=$(( (now_epoch - first_epoch) / 3600 ))
        [[ "$hours_elapsed" -lt 1 ]] && hours_elapsed=1

        avg_errors_per_hour=$(( total_errors / hours_elapsed ))

        # Spike: > 10 errors/hour AND > 3x the average
        if [[ "$recent_errors" -gt 10 ]] && [[ "$avg_errors_per_hour" -gt 0 ]] && [[ "$recent_errors" -gt $((avg_errors_per_hour * 3)) ]]; then
            NEW_ALERTS+=("$(_make_alert "error-spike" "warning" "Error rate spike" "Last hour: ${recent_errors} errors (avg: ${avg_errors_per_hour}/hr)" "$recent_errors")")
        fi
    fi
fi

# ─── 4. Detect service restart loops ────────────────────────────────────────
# If a service was restarted > 2 times today, it's probably in a crash loop

restart_lines=$(grep 'attempting restart' "$LOG_FILE" 2>/dev/null || true)
if [[ -n "$restart_lines" ]]; then
    while IFS= read -r line; do
        count=$(echo "$line" | awk '{print $1}')
        service_msg=$(echo "$line" | sed 's/^[[:space:]]*[0-9]* //')
        if [[ "$count" -gt 2 ]]; then
            svc_name=$(echo "$service_msg" | grep -oP '\w+(?= is down)' || echo "unknown")
            alert_id="restart-loop-${svc_name}"
            NEW_ALERTS+=("$(_make_alert "$alert_id" "critical" "Service restart loop: ${svc_name}" "${count} restart attempts today" "$count")")
        fi
    done < <(echo "$restart_lines" | sed 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn)
fi

# ─── 5. Detect persistent warnings (same warning > 10 times/day) ────────────

warn_lines=$(grep '\[WARN\]' "$LOG_FILE" 2>/dev/null || true)
if [[ -n "$warn_lines" ]]; then
    while IFS= read -r line; do
        count=$(echo "$line" | awk '{print $1}')
        msg=$(echo "$line" | sed 's/^[[:space:]]*[0-9]* //')
        if [[ "$count" -gt 10 ]]; then
            alert_id="persistent-warn-$(echo "$msg" | md5sum | cut -c1-12)"
            NEW_ALERTS+=("$(_make_alert "$alert_id" "info" "Persistent warning (${count}x)" "$msg" "$count")")
        fi
    done < <(echo "$warn_lines" | sed 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn | head -5)
fi

# ─── 6. Check for failed Claude runs ────────────────────────────────────────

usage_file="${METRICS_DIR}/claude-usage-${TODAY}.jsonl"
if [[ -f "$usage_file" ]]; then
    failed_runs=$(jq -s '[.[] | select(.exit_code != 0)] | length' "$usage_file" 2>/dev/null || echo 0)
    total_runs=$(wc -l < "$usage_file" 2>/dev/null || echo 0)
    if [[ "$failed_runs" -gt 2 ]]; then
        # Get the most recent failure
        last_fail=$(jq -s '[.[] | select(.exit_code != 0)] | last | .task // "unknown"' "$usage_file" 2>/dev/null || echo "unknown")
        alert_id="claude-failures"
        NEW_ALERTS+=("$(_make_alert "$alert_id" "warning" "Claude API failures (${failed_runs}/${total_runs} runs)" "Last failed task: ${last_fail}" "$failed_runs")")
    fi
fi

# ─── Merge new alerts with existing ones ────────────────────────────────────
# - Update last_seen and count for recurring alerts
# - Auto-resolve alerts that didn't fire this run
# - Keep resolved alerts for 24h for dashboard visibility

merged_alerts="[]"

# Build a map of new alert IDs for quick lookup
new_alert_ids=""
for alert in "${NEW_ALERTS[@]}"; do
    aid=$(echo "$alert" | jq -r '.id')
    new_alert_ids="${new_alert_ids} ${aid}"
done

# Process existing alerts: resolve those not in new set
while IFS= read -r existing_id; do
    [[ -z "$existing_id" ]] && continue
    existing_alert=$(echo "$existing_alerts" | jq --arg id "$existing_id" '.alerts[] | select(.id == $id)')

    if echo "$new_alert_ids" | grep -qw "$existing_id"; then
        # Alert is still active — update last_seen and count from new data
        new_data=$(for a in "${NEW_ALERTS[@]}"; do echo "$a"; done | jq -s --arg id "$existing_id" '.[] | select(.id == $id)')
        new_count=$(echo "$new_data" | jq -r '.count')
        # Preserve first_seen from existing, update last_seen
        merged=$(echo "$existing_alert" | jq \
            --arg last "$NOW" \
            --argjson count "$new_count" \
            --arg detail "$(echo "$new_data" | jq -r '.detail')" \
            '.last_seen = $last | .count = $count | .detail = $detail | .resolved = false')
        merged_alerts=$(echo "$merged_alerts" | jq --argjson a "$merged" '. + [$a]')
    else
        # Alert not firing — auto-resolve if it was active, keep if recently resolved
        if [[ "$(echo "$existing_alert" | jq -r '.resolved')" == "false" ]]; then
            resolved=$(echo "$existing_alert" | jq --arg ts "$NOW" '.resolved = true | .resolved_at = $ts')
            merged_alerts=$(echo "$merged_alerts" | jq --argjson a "$resolved" '. + [$a]')
            marvin_log "INFO" "Alert auto-resolved: $(echo "$existing_alert" | jq -r '.title')"
        else
            # Already resolved — keep for 24h
            resolved_at=$(echo "$existing_alert" | jq -r '.resolved_at // ""')
            if [[ -n "$resolved_at" ]]; then
                resolved_epoch=$(date -d "$resolved_at" +%s 2>/dev/null || echo 0)
                if [[ $((now_epoch - resolved_epoch)) -lt 86400 ]]; then
                    merged_alerts=$(echo "$merged_alerts" | jq --argjson a "$existing_alert" '. + [$a]')
                fi
                # else: drop resolved alert older than 24h
            fi
        fi
    fi
done < <(echo "$existing_alerts" | jq -r '.alerts[].id' 2>/dev/null)

# Add genuinely new alerts (not already in existing set)
for alert in "${NEW_ALERTS[@]}"; do
    aid=$(echo "$alert" | jq -r '.id')
    already_exists=$(echo "$existing_alerts" | jq --arg id "$aid" '[.alerts[] | select(.id == $id)] | length' 2>/dev/null || echo 0)
    if [[ "$already_exists" -eq 0 ]]; then
        merged_alerts=$(echo "$merged_alerts" | jq --argjson a "$alert" '. + [$a]')
        marvin_log "WARN" "New alert: $(echo "$alert" | jq -r '.title') — $(echo "$alert" | jq -r '.detail' | head -c 100)"
        # Append to alert history
        echo "$alert" >> "$ALERT_HISTORY" 2>/dev/null || true
    fi
done

# Count active (unresolved) alerts by severity
active_count=$(echo "$merged_alerts" | jq '[.[] | select(.resolved == false)] | length')
critical_active=$(echo "$merged_alerts" | jq '[.[] | select(.resolved == false and .severity == "critical")] | length')

# Write final alerts file
jq -n \
    --arg ts "$NOW" \
    --argjson alerts "$merged_alerts" \
    --argjson active "$active_count" \
    --argjson critical "$critical_active" \
    '{
        timestamp: $ts,
        active_alerts: $active,
        critical_alerts: $critical,
        alerts: $alerts
    }' > "$ALERTS_FILE"

chmod 644 "$ALERTS_FILE"

marvin_log "INFO" "Log alerting complete: ${active_count} active alert(s), ${critical_active} critical"
