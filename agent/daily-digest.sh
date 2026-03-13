#!/usr/bin/env bash
# =============================================================================
# Marvin — Daily Log Digest
# =============================================================================
# Summarizes the day's logs into a human-readable JSON digest.
# No Claude API call needed — pure text/jq processing.
# Runs at 23:30 UTC via cron (after all other daily tasks).
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

marvin_log "INFO" "Daily digest starting for ${TODAY}"

LOG_FILE="${LOGS_DIR}/${TODAY}.log"
DIGEST_FILE="${DATA_DIR}/logs/digest-${TODAY}.json"
DIGEST_LATEST="${DATA_DIR}/logs/digest-latest.json"

if [[ ! -f "$LOG_FILE" ]]; then
    marvin_log "WARN" "No log file found for ${TODAY}"
    exit 0
fi

# Helper: grep -c that returns a clean integer.
# grep -c exits 1 on zero matches; || true prevents set -e from killing us.
_count() { grep -c "$@" 2>/dev/null || true; }

# Helper: grep that returns matches or empty string (avoids pipefail issues).
_grep() { grep "$@" 2>/dev/null || true; }

# ─── Count log levels ────────────────────────────────────────────────────────
total_lines=$(wc -l < "$LOG_FILE")
critical_count=$(_count '\[CRITICAL\]' "$LOG_FILE")
error_count=$(_count '\[ERROR\]' "$LOG_FILE")
warn_count=$(_count '\[WARN\]' "$LOG_FILE")
info_count=$(_count '\[INFO\]' "$LOG_FILE")

# ─── Extract unique error/warning messages ───────────────────────────────────
# Use _grep to avoid pipefail exit when grep finds no matches in a pipeline
_error_lines=$(_grep -E '\[(CRITICAL|ERROR)\]' "$LOG_FILE")
if [[ -n "$_error_lines" ]]; then
    top_errors_json=$(echo "$_error_lines" \
        | sed 's/^\[[^]]*\] //' \
        | sort | uniq -c | sort -rn | head -10 \
        | while read -r count msg; do
            jq -nc --argjson c "$count" --arg m "$msg" '{count: $c, message: $m}'
        done | jq -s '.')
else
    top_errors_json='[]'
fi

_warn_lines=$(_grep '\[WARN\]' "$LOG_FILE")
if [[ -n "$_warn_lines" ]]; then
    top_warnings_json=$(echo "$_warn_lines" \
        | sed 's/^\[[^]]*\] //' \
        | sort | uniq -c | sort -rn | head -10 \
        | while read -r count msg; do
            jq -nc --argjson c "$count" --arg m "$msg" '{count: $c, message: $m}'
        done | jq -s '.')
else
    top_warnings_json='[]'
fi

# ─── Service restarts ────────────────────────────────────────────────────────
service_restarts=$(_count 'attempting restart' "$LOG_FILE")
_restart_lines=$(_grep 'attempting restart' "$LOG_FILE")
if [[ -n "$_restart_lines" ]]; then
    service_restart_details=$(echo "$_restart_lines" \
        | sed 's/^\[[^]]*\] //' | sort -u \
        | jq -R . | jq -s '.')
else
    service_restart_details='[]'
fi

# ─── Claude API usage ────────────────────────────────────────────────────────
usage_file="${METRICS_DIR}/claude-usage-${TODAY}.jsonl"
claude_runs=0
claude_total_duration=0
claude_errors=0
claude_tasks_json='[]'

if [[ -f "$usage_file" ]]; then
    claude_runs=$(wc -l < "$usage_file")
    claude_total_duration=$(jq -s '[.[].duration_s] | add // 0' "$usage_file" 2>/dev/null || echo 0)
    claude_errors=$(jq -s '[.[] | select(.exit_code != 0)] | length' "$usage_file" 2>/dev/null || echo 0)
    claude_tasks_json=$(jq -s 'group_by(.task) | map({task: .[0].task, runs: length, total_duration_s: ([.[].duration_s] | add), errors: ([.[] | select(.exit_code != 0)] | length)}) | sort_by(-.runs)' "$usage_file" 2>/dev/null || echo '[]')
fi

# ─── Health status summary ───────────────────────────────────────────────────
metrics_file="${METRICS_DIR}/${TODAY}.jsonl"
total_checks=0
if [[ -f "$metrics_file" ]]; then
    total_checks=$(wc -l < "$metrics_file")
fi

# ─── Anomaly count ───────────────────────────────────────────────────────────
anomaly_count=$(_count '\[WARN\] Anomaly:' "$LOG_FILE")
_anomaly_lines=$(_grep '\[WARN\] Anomaly:' "$LOG_FILE")
if [[ -n "$_anomaly_lines" ]]; then
    anomaly_metrics=$(echo "$_anomaly_lines" \
        | sed 's/.*Anomaly: //' | sed 's/ =.*//' \
        | sort | uniq -c | sort -rn \
        | while read -r count metric; do
            jq -nc --argjson c "$count" --arg m "$metric" '{metric: $m, count: $c}'
        done | jq -s '.')
else
    anomaly_metrics='[]'
fi

# ─── Key events (first occurrence of notable log messages) ───────────────────
_event_lines=$(_grep -iE '(Starting Claude|complete|Created|Pushed|Merged|Killed|Failed|fixed|Committed)' "$LOG_FILE")
if [[ -n "$_event_lines" ]]; then
    key_events=$(echo "$_event_lines" \
        | grep -v 'Health monitor complete' \
        | head -20 \
        | jq -R . | jq -s '.')
else
    key_events='[]'
fi

# ─── Build the digest ────────────────────────────────────────────────────────
jq -n \
    --arg date "$TODAY" \
    --arg ts "$NOW" \
    --argjson total_lines "$total_lines" \
    --argjson critical "$critical_count" \
    --argjson errors "$error_count" \
    --argjson warnings "$warn_count" \
    --argjson info "$info_count" \
    --argjson top_errors "$top_errors_json" \
    --argjson top_warnings "$top_warnings_json" \
    --argjson service_restarts "$service_restarts" \
    --argjson restart_details "$service_restart_details" \
    --argjson claude_runs "$claude_runs" \
    --argjson claude_duration "$claude_total_duration" \
    --argjson claude_errors "$claude_errors" \
    --argjson claude_tasks "$claude_tasks_json" \
    --argjson health_checks "$total_checks" \
    --argjson anomaly_count "$anomaly_count" \
    --argjson anomaly_metrics "$anomaly_metrics" \
    --argjson key_events "$key_events" \
    '{
        date: $date,
        generated_at: $ts,
        log_summary: {
            total_lines: $total_lines,
            by_level: {critical: $critical, error: $errors, warning: $warnings, info: $info}
        },
        top_errors: $top_errors,
        top_warnings: $top_warnings,
        service_restarts: {count: $service_restarts, details: $restart_details},
        claude_usage: {
            total_runs: $claude_runs,
            total_duration_s: $claude_duration,
            error_runs: $claude_errors,
            by_task: $claude_tasks
        },
        health: {
            checks_today: $health_checks,
            anomalies_triggered: $anomaly_count,
            anomaly_breakdown: $anomaly_metrics
        },
        key_events: $key_events
    }' > "$DIGEST_FILE"

# Also update latest pointer
cp "$DIGEST_FILE" "$DIGEST_LATEST"

marvin_log "INFO" "Daily digest complete: ${total_lines} log lines, ${error_count} errors, ${warn_count} warnings, ${claude_runs} Claude runs"
