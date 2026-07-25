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
trap marvin_error_trap ERR

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

# Exclude log-alerting's own output to prevent recursive alerts:
# lines containing "New alert:" or "Alert auto-resolved:" are this script's
# previous WARN lines that embed original ERROR/CRITICAL text in their detail.
# Without this filter, "grep [CRITICAL]" matches our own "[WARN] New alert: ... [CRITICAL] ..."
# output, creating ever-growing nested alerts each hour.
# NOTE: These filter strings must stay in sync with _make_alert() output format.
_error_lines=$(grep -E '\[(CRITICAL|ERROR)\]' "$LOG_FILE" 2>/dev/null \
    | grep -v 'New alert:' | grep -v 'Alert auto-resolved:' || true)
if [[ -n "$_error_lines" ]]; then
    # Strip timestamp, deduplicate, count occurrences
    while IFS= read -r line; do
        count=$(echo "$line" | awk '{print $1}')
        msg=$(echo "$line" | sed 's/^[[:space:]]*[0-9]* //')
        # Only alert if the same error appears > 3 times
        if [[ "$count" -gt 3 ]]; then
            # Create a stable ID from the message hash
            alert_id="repeated-$(echo "$msg" | sha256sum | cut -c1-12)"
            NEW_ALERTS+=("$(_make_alert "$alert_id" "warning" "Repeated error (${count}x)" "$msg" "$count")")
        fi
    done < <(echo "$_error_lines" | sed 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn | head -10)
fi

# ─── 2. Detect CRITICAL events (any RECENT critical is an alert) ────────────
# Only consider CRITICAL events from the last 2 hours, not the whole day.
# A single transient critical that has already self-healed (e.g. nginx briefly
# restarted by unattended-upgrades during a package upgrade, recovered within a
# second) otherwise lingers as an "active" alert for the rest of the UTC day:
# the [CRITICAL] line stays in today's log file and every hourly run re-detects
# it, so it never auto-resolves until the day rolls over (2026-06-10 incident).
# Windowing lets a recovered transient auto-resolve in ~2-3h via the merge logic
# below, while an ongoing/recurring critical condition keeps producing fresh log
# lines and stays active. The 2h window is deliberately wider than the 1h cron
# gap so no transient critical is ever missed between hourly runs. Sections 3
# (error-rate spike) and 6 (Claude failures) already window by recency.

# Same recursive-alert filter as section 1 (see comment above)
critical_lines=$(grep '\[CRITICAL\]' "$LOG_FILE" 2>/dev/null \
    | grep -v 'New alert:' | grep -v 'Alert auto-resolved:' || true)
# Window to recent events only. ISO-8601 timestamps sort lexicographically, so a
# string '>=' on the bracketed timestamp field is a valid time comparison (same
# technique as section 3). Fail-open: if `date` can't produce a cutoff, keep all
# lines rather than risk dropping a genuine critical alert.
_critical_cutoff=$(date -u -d "2 hours ago" +%Y-%m-%dT%H:%M 2>/dev/null || echo "")
if [[ -n "$_critical_cutoff" && -n "$critical_lines" ]]; then
    critical_lines=$(echo "$critical_lines" | awk -v cutoff="[$_critical_cutoff" '$1 >= cutoff' || true)
fi
critical_count=0
if [[ -n "$critical_lines" ]]; then
    critical_count=$(echo "$critical_lines" | wc -l | tr -d ' ')
    # Get the most recent critical message
    latest_critical=$(echo "$critical_lines" | tail -1 | sed 's/^\[[^]]*\] //')
    alert_id="critical-$(echo "$latest_critical" | sha256sum | cut -c1-12)"
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
    # Same recursive-alert filter as section 1 — exclude alerting's own output
    total_errors=$(grep -E '\[(ERROR|CRITICAL)\]' "$LOG_FILE" 2>/dev/null \
        | grep -v 'New alert:' | grep -v 'Alert auto-resolved:' | wc -l || true)
    total_errors=$(( total_errors + 0 ))
    total_errors=${total_errors:-0}
    # Estimate hours elapsed today
    first_log_ts=$(head -1 "$LOG_FILE" 2>/dev/null | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' || echo "")
    if [[ -n "$first_log_ts" ]]; then
        first_epoch=$(date -d "$first_log_ts" +%s 2>/dev/null || echo "$now_epoch")
        hours_elapsed=$(( (now_epoch - first_epoch) / 3600 ))
        [[ "$hours_elapsed" -lt 1 ]] && hours_elapsed=1

        # Use multiplication to avoid integer division truncation:
        # recent_errors > 3 * (total_errors / hours_elapsed)
        # becomes: recent_errors * hours_elapsed > total_errors * 3
        avg_errors_per_hour=$(( total_errors / hours_elapsed ))

        # Spike: > 10 errors/hour AND > 3x the average (using multiplication to avoid truncation)
        if [[ "$recent_errors" -gt 10 ]] && [[ $((recent_errors * hours_elapsed)) -gt $((total_errors * 3)) ]]; then
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

# Same recursive-alert filter as sections 1-2 (see comment in section 1)
warn_lines=$(grep '\[WARN\]' "$LOG_FILE" 2>/dev/null \
    | grep -v 'New alert:' | grep -v 'Alert auto-resolved:' || true)
if [[ -n "$warn_lines" ]]; then
    while IFS= read -r line; do
        count=$(echo "$line" | awk '{print $1}')
        msg=$(echo "$line" | sed 's/^[[:space:]]*[0-9]* //')
        if [[ "$count" -gt 10 ]]; then
            alert_id="persistent-warn-$(echo "$msg" | sha256sum | cut -c1-12)"
            NEW_ALERTS+=("$(_make_alert "$alert_id" "info" "Persistent warning (${count}x)" "$msg" "$count")")
        fi
    done < <(echo "$warn_lines" | sed 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn | head -5)
fi

# ─── 6. Check for failed Claude runs ────────────────────────────────────────

usage_file="${METRICS_DIR}/claude-usage-${TODAY}.jsonl"
if [[ -f "$usage_file" ]]; then
    # Exclude session/usage-limit throttles: a "You've hit your session limit"
    # exit is benign and self-resolving (the window rolls over on its own — see
    # 2026-07-04, where 5 such exits tripped this alert and it auto-resolved once
    # the limit reset at 14:30 UTC). run_claude() tags these fail_reason=
    # "session_limit"; only genuine API/tooling errors should page here. The
    # `(.fail_reason // "")` guard keeps pre-classification entries (no field →
    # null) counted, so this never *hides* a real historical failure.
    failed_runs=$(jq -s '[.[] | select(.exit_code != 0 and (.fail_reason // "") != "session_limit")] | length' "$usage_file" 2>/dev/null || echo 0)
    total_runs=$(wc -l < "$usage_file" 2>/dev/null || echo 0)
    if [[ "$failed_runs" -gt 2 ]]; then
        # Get the most recent genuine (non-throttle) failure
        last_fail=$(jq -sr '[.[] | select(.exit_code != 0 and (.fail_reason // "") != "session_limit")] | last | .task // "unknown"' "$usage_file" 2>/dev/null || echo "unknown")
        alert_id="claude-failures"

        # Severity is a function of *how much* is broken, not just that something
        # is. A couple of scattered API errors is a warning; a pipeline where
        # (nearly) every run dies is an outage nobody can see from the inside,
        # because the tasks that would report it are themselves dead. Escalate so
        # incident-report.sh picks it up on its next pass.
        #
        # Escalation reads the TAIL of the day (last 10 runs), not the daily
        # totals: the day-long counts can never recover before midnight UTC, so a
        # cumulative test would keep screaming "outage" for hours after the
        # pipeline came back. The warning below stays day-scoped — that one is a
        # tally, this one is a state.
        severity="warning"
        title="Claude API failures (${failed_runs}/${total_runs} runs)"
        detail="Last failed task: ${last_fail}"

        recent_total=$(jq -s '.[-10:] | length' "$usage_file" 2>/dev/null || echo 0)
        recent_failed=$(jq -s '[.[-10:][] | select(.exit_code != 0 and (.fail_reason // "") != "session_limit")] | length' "$usage_file" 2>/dev/null || echo 0)
        recent_auth=$(jq -s '[.[-10:][] | select((.fail_reason // "") == "auth")] | length' "$usage_file" 2>/dev/null || echo 0)

        if [[ "${recent_auth:-0}" -gt 0 ]]; then
            # Credentials expired: no retry, no next cron cycle, and no agent run
            # can fix this — only an interactive login by the human can.
            severity="critical"
            title="Claude auth expired — pipeline halted (${recent_failed}/${recent_total} recent runs failed)"
            detail="${recent_auth} of the last ${recent_total} run(s) failed with expired OAuth credentials. Requires interactive re-auth on the host (run \`claude\` and log in); no automated task can recover this. Last failed task: ${last_fail}"
        elif [[ "${recent_total:-0}" -ge 10 && $((recent_failed * 100 / recent_total)) -ge 90 ]]; then
            severity="critical"
            title="Claude pipeline outage (${recent_failed}/${recent_total} recent runs failed)"
            detail="Near-total failure rate over the last ${recent_total} runs — every scheduled task is dying. Last failed task: ${last_fail}"
        fi

        NEW_ALERTS+=("$(_make_alert "$alert_id" "$severity" "$title" "$detail" "$failed_runs")")
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
        # Preserve first_seen from existing, update last_seen.
        # Title and severity are refreshed too: both can carry live numbers
        # (e.g. "Claude API failures (7/62 runs)") or escalate over time, and a
        # frozen title made the dashboard show 4-day-old counts for an alert whose
        # real state had gone from 7/62 to 94/94.
        merged=$(echo "$existing_alert" | jq \
            --arg last "$NOW" \
            --argjson count "$new_count" \
            --arg detail "$(echo "$new_data" | jq -r '.detail')" \
            --arg title "$(echo "$new_data" | jq -r '.title')" \
            --arg sev "$(echo "$new_data" | jq -r '.severity')" \
            '.last_seen = $last | .count = $count | .detail = $detail | .title = $title | .severity = $sev | .resolved = false')
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
