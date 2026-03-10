#!/usr/bin/env bash
# =============================================================================
# Marvin — Weekly Analytics Report (runs Sundays at 11:30 UTC)
# =============================================================================
# Generates a data-driven weekly report with:
#   - System metrics trends (CPU, memory, disk, load) with week-over-week delta
#   - Claude API usage stats (runs, duration, errors)
#   - Log analysis (errors, warnings, top issues)
#   - Security summary (fail2ban, scans, CVEs)
#   - SLA/uptime tracking
#   - Enhancement activity stats
#
# Output:
#   data/reports/weekly-YYYY-MM-DD.json   (machine-readable)
#   data/reports/weekly-YYYY-MM-DD.md     (human-readable digest)
#
# Does NOT invoke Claude — pure data aggregation.
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

REPORTS_DIR="${DATA_DIR}/reports"
mkdir -p "$REPORTS_DIR"

# The report covers the 7 days ending yesterday (or a given date)
REPORT_END="${1:-$(date -u -d "${TODAY} - 1 day" +%Y-%m-%d 2>/dev/null || echo "$TODAY")}"
REPORT_START=$(date -u -d "${REPORT_END} - 6 days" +%Y-%m-%d 2>/dev/null || echo "$REPORT_END")

# Previous week for comparison
PREV_END=$(date -u -d "${REPORT_START} - 1 day" +%Y-%m-%d 2>/dev/null || echo "$REPORT_START")
PREV_START=$(date -u -d "${PREV_END} - 6 days" +%Y-%m-%d 2>/dev/null || echo "$PREV_END")

REPORT_JSON="${REPORTS_DIR}/weekly-${REPORT_END}.json"
REPORT_MD="${REPORTS_DIR}/weekly-${REPORT_END}.md"

marvin_log "INFO" "Weekly analytics: ${REPORT_START} to ${REPORT_END}"

# ─── Helper: collect dates in a range ────────────────────────────────────────
_dates_in_range() {
    local start="$1" end="$2"
    local d="$start"
    while [[ "$d" < "$end" || "$d" == "$end" ]]; do
        echo "$d"
        d=$(date -u -d "${d} + 1 day" +%Y-%m-%d 2>/dev/null || break)
    done
}

# ─── 1. System metrics trends ───────────────────────────────────────────────
_metrics_summary() {
    local start="$1" end="$2"
    local daily_files=()
    while IFS= read -r d; do
        local f="${METRICS_DIR}/${d}-daily.json"
        [[ -f "$f" ]] && daily_files+=("$f")
    done < <(_dates_in_range "$start" "$end")

    if [[ ${#daily_files[@]} -eq 0 ]]; then
        echo '{}'
        return
    fi

    jq -s '
        {
            days_with_data: length,
            cpu: {
                avg: ([.[].summary.cpu.avg // 0] | add / length | . * 10 | round / 10),
                max: ([.[].summary.cpu.max // 0] | max),
                p95_avg: ([.[].summary.cpu.p95 // 0] | add / length | . * 10 | round / 10)
            },
            memory_used_mb: {
                avg: ([.[].summary.memory_used_mb.avg // 0] | add / length | round),
                max: ([.[].summary.memory_used_mb.max // 0] | max)
            },
            load_1m: {
                avg: ([.[].summary.load_1m.avg // 0] | add / length | . * 100 | round / 100),
                max: ([.[].summary.load_1m.max // 0] | max)
            },
            process_count: {
                avg: ([.[].summary.process_count.avg // 0] | add / length | round),
                max: ([.[].summary.process_count.max // 0] | max)
            },
            disk: {
                start_mb: (first.summary.disk_used_mb.first // 0),
                end_mb: (last.summary.disk_used_mb.last // 0),
                delta_mb: ((last.summary.disk_used_mb.last // 0) - (first.summary.disk_used_mb.first // 0))
            },
            total_samples: ([.[].summary.samples // 0] | add)
        }
    ' "${daily_files[@]}" 2>/dev/null || echo '{}'
}

current_metrics=$(_metrics_summary "$REPORT_START" "$REPORT_END")
prev_metrics=$(_metrics_summary "$PREV_START" "$PREV_END")

# ─── 2. Claude API usage ────────────────────────────────────────────────────
_claude_usage() {
    local start="$1" end="$2"
    local files=()
    while IFS= read -r d; do
        local f="${METRICS_DIR}/claude-usage-${d}.jsonl"
        [[ -f "$f" ]] && files+=("$f")
    done < <(_dates_in_range "$start" "$end")

    if [[ ${#files[@]} -eq 0 ]]; then
        echo '{"total_runs":0,"total_duration_s":0,"avg_duration_s":0,"errors":0,"error_rate_pct":0,"by_task":{}}'
        return
    fi

    cat "${files[@]}" | jq -s '
        {
            total_runs: length,
            total_duration_s: ([.[].duration_s] | add // 0),
            avg_duration_s: (if length > 0 then ([.[].duration_s] | add) / length | round else 0 end),
            total_prompt_chars: ([.[].prompt_chars] | add // 0),
            total_output_chars: ([.[].output_chars] | add // 0),
            errors: ([.[] | select(.exit_code != 0)] | length),
            error_rate_pct: (if length > 0 then ([.[] | select(.exit_code != 0)] | length) / length * 100 | . * 10 | round / 10 else 0 end),
            by_task: (group_by(.task) | map({
                key: .[0].task,
                value: {
                    runs: length,
                    total_s: ([.[].duration_s] | add // 0),
                    errors: ([.[] | select(.exit_code != 0)] | length)
                }
            }) | from_entries)
        }
    ' 2>/dev/null || echo '{"total_runs":0}'
}

current_claude=$(_claude_usage "$REPORT_START" "$REPORT_END")
prev_claude=$(_claude_usage "$PREV_START" "$PREV_END")

# ─── 3. Log analysis ────────────────────────────────────────────────────────
_log_stats() {
    local start="$1" end="$2"
    local total_lines=0 total_errors=0 total_warnings=0 total_criticals=0
    local top_errors=""

    while IFS= read -r d; do
        local f="${LOGS_DIR}/${d}.log"
        [[ -f "$f" ]] || continue
        total_lines=$((total_lines + $(wc -l < "$f")))
        local _e; _e=$(grep -c "\[ERROR\]" "$f" 2>/dev/null) || true
        local _w; _w=$(grep -c "\[WARN\]" "$f" 2>/dev/null) || true
        local _c; _c=$(grep -c "\[CRITICAL\]" "$f" 2>/dev/null) || true
        total_errors=$((total_errors + ${_e:-0}))
        total_warnings=$((total_warnings + ${_w:-0}))
        total_criticals=$((total_criticals + ${_c:-0}))
    done < <(_dates_in_range "$start" "$end")

    # Top error messages (deduplicated)
    local error_summary="[]"
    local all_errors=""
    while IFS= read -r d; do
        local f="${LOGS_DIR}/${d}.log"
        [[ -f "$f" ]] || continue
        all_errors+=$(grep "\[ERROR\]" "$f" 2>/dev/null | sed 's/.*\[ERROR\] //' || true)
        all_errors+=$'\n'
    done < <(_dates_in_range "$start" "$end")

    if [[ -n "$all_errors" ]]; then
        error_summary=$(echo "$all_errors" | grep -v '^$' | sort | uniq -c | sort -rn | head -5 \
            | awk '{count=$1; $1=""; sub(/^ /, ""); printf "{\"count\":%d,\"message\":\"%s\"}\n", count, $0}' \
            | jq -s '.' 2>/dev/null || echo '[]')
    fi

    jq -n \
        --argjson lines "$total_lines" \
        --argjson errors "$total_errors" \
        --argjson warnings "$total_warnings" \
        --argjson criticals "$total_criticals" \
        --argjson top_errors "$error_summary" \
        '{
            total_lines: $lines,
            errors: $errors,
            warnings: $warnings,
            criticals: $criticals,
            top_errors: $top_errors
        }'
}

current_logs=$(_log_stats "$REPORT_START" "$REPORT_END")
prev_logs=$(_log_stats "$PREV_START" "$PREV_END")

# ─── 4. Security summary ────────────────────────────────────────────────────
security_score="N/A"
security_grade="N/A"
if [[ -f "${DATA_DIR}/security/security-score.json" ]]; then
    security_score=$(jq -r '.score // "N/A"' "${DATA_DIR}/security/security-score.json" 2>/dev/null || echo "N/A")
    security_grade=$(jq -r '.grade // "N/A"' "${DATA_DIR}/security/security-score.json" 2>/dev/null || echo "N/A")
fi

fail2ban_total=0
if command -v fail2ban-client &>/dev/null; then
    fail2ban_total=$(fail2ban-client status sshd 2>/dev/null | grep "Total banned" | awk '{print $NF}' || echo 0)
fi

cve_pending=0
if [[ -f "${DATA_DIR}/security/cve-status.json" ]]; then
    cve_pending=$(jq -r '.security_updates_available // 0' "${DATA_DIR}/security/cve-status.json" 2>/dev/null || echo 0)
fi

security_json=$(jq -n \
    --arg score "$security_score" \
    --arg grade "$security_grade" \
    --argjson f2b "$fail2ban_total" \
    --argjson cve "$cve_pending" \
    '{score: $score, grade: $grade, fail2ban_total_banned: $f2b, pending_cves: $cve}')

# ─── 5. SLA / Uptime ────────────────────────────────────────────────────────
sla_json='{"overall_uptime_pct": 0, "days_tracked": 0}'
if [[ -f "${METRICS_DIR}/sla.json" ]]; then
    sla_json=$(jq '.summary // {overall_uptime_pct: 0, days_tracked: 0}' "${METRICS_DIR}/sla.json" 2>/dev/null || echo "$sla_json")
fi

# ─── 6. Enhancement activity ────────────────────────────────────────────────
enhancement_count=0
while IFS= read -r d; do
    _ec=$(find "${ENHANCE_DIR}" -maxdepth 1 -name "${d}*.md" 2>/dev/null | wc -l) || true
    enhancement_count=$((enhancement_count + ${_ec:-0}))
done < <(_dates_in_range "$REPORT_START" "$REPORT_END")

# ─── 7. Compute week-over-week deltas ───────────────────────────────────────
_delta() {
    local current="$1" previous="$2"
    awk -v c="$current" -v p="$previous" 'BEGIN{
        if(p==0){printf "0"}
        else{printf "%.1f", (c-p)/p*100}
    }' 2>/dev/null || echo "0"
}

cpu_delta=$(_delta \
    "$(echo "$current_metrics" | jq -r '.cpu.avg // 0')" \
    "$(echo "$prev_metrics" | jq -r '.cpu.avg // 0')")
mem_delta=$(_delta \
    "$(echo "$current_metrics" | jq -r '.memory_used_mb.avg // 0')" \
    "$(echo "$prev_metrics" | jq -r '.memory_used_mb.avg // 0')")
claude_runs_delta=$(_delta \
    "$(echo "$current_claude" | jq -r '.total_runs // 0')" \
    "$(echo "$prev_claude" | jq -r '.total_runs // 0')")
error_delta=$(_delta \
    "$(echo "$current_logs" | jq -r '.errors // 0')" \
    "$(echo "$prev_logs" | jq -r '.errors // 0')")

# ─── 8. Assemble final JSON report ──────────────────────────────────────────
jq -n \
    --arg start "$REPORT_START" \
    --arg end "$REPORT_END" \
    --arg generated "$NOW" \
    --argjson metrics "$current_metrics" \
    --argjson prev_metrics "$prev_metrics" \
    --argjson claude "$current_claude" \
    --argjson prev_claude "$prev_claude" \
    --argjson logs "$current_logs" \
    --argjson prev_logs "$prev_logs" \
    --argjson security "$security_json" \
    --argjson sla "$sla_json" \
    --argjson enhancements "$enhancement_count" \
    --arg cpu_delta "$cpu_delta" \
    --arg mem_delta "$mem_delta" \
    --arg runs_delta "$claude_runs_delta" \
    --arg err_delta "$error_delta" \
    '{
        period: {start: $start, end: $end},
        generated_at: $generated,
        system_metrics: {
            current_week: $metrics,
            previous_week: $prev_metrics,
            trends: {
                cpu_avg_delta_pct: ($cpu_delta | tonumber),
                memory_avg_delta_pct: ($mem_delta | tonumber),
                note: "Positive = increased vs previous week"
            }
        },
        claude_api: {
            current_week: $claude,
            previous_week: $prev_claude,
            trends: {
                runs_delta_pct: ($runs_delta | tonumber)
            }
        },
        logs: {
            current_week: $logs,
            previous_week: $prev_logs,
            trends: {
                errors_delta_pct: ($err_delta | tonumber)
            }
        },
        security: $security,
        sla: $sla,
        enhancements_attempted: $enhancements
    }' > "$REPORT_JSON" 2>/dev/null

if ! jq empty "$REPORT_JSON" 2>/dev/null; then
    marvin_log "ERROR" "Weekly report JSON invalid — aborting"
    exit 1
fi

# ─── 9. Generate human-readable markdown digest ─────────────────────────────
cpu_avg=$(echo "$current_metrics" | jq -r '.cpu.avg // "?"')
cpu_max=$(echo "$current_metrics" | jq -r '.cpu.max // "?"')
mem_avg=$(echo "$current_metrics" | jq -r '.memory_used_mb.avg // "?"')
mem_max=$(echo "$current_metrics" | jq -r '.memory_used_mb.max // "?"')
load_avg=$(echo "$current_metrics" | jq -r '.load_1m.avg // "?"')
disk_delta=$(echo "$current_metrics" | jq -r '.disk.delta_mb // 0')
disk_end=$(echo "$current_metrics" | jq -r '.disk.end_mb // "?"')
samples=$(echo "$current_metrics" | jq -r '.total_samples // 0')

claude_runs=$(echo "$current_claude" | jq -r '.total_runs // 0')
claude_dur=$(echo "$current_claude" | jq -r '.total_duration_s // 0')
claude_dur_h=$(awk "BEGIN{printf \"%.1f\", $claude_dur / 3600}" 2>/dev/null || echo "0")
claude_errors=$(echo "$current_claude" | jq -r '.errors // 0')
claude_err_pct=$(echo "$current_claude" | jq -r '.error_rate_pct // 0')

log_errors=$(echo "$current_logs" | jq -r '.errors // 0')
log_warnings=$(echo "$current_logs" | jq -r '.warnings // 0')
log_criticals=$(echo "$current_logs" | jq -r '.criticals // 0')

uptime_pct=$(echo "$sla_json" | jq -r '.overall_uptime_pct // "?"' 2>/dev/null || echo "?")
days_tracked=$(echo "$sla_json" | jq -r '.days_tracked // "?"' 2>/dev/null || echo "?")

# Build top-tasks table
top_tasks=$(echo "$current_claude" | jq -r '
    .by_task // {} | to_entries | sort_by(-.value.runs) | .[:5] |
    .[] | "| \(.key) | \(.value.runs) | \(.value.total_s)s | \(.value.errors) |"
' 2>/dev/null || echo "| (no data) | - | - | - |")

# Build top-errors list
top_errors_md=$(echo "$current_logs" | jq -r '
    .top_errors // [] | .[:5] |
    .[] | "- **\(.count)x** \(.message)"
' 2>/dev/null || echo "- (none)")

# Direction indicators
_arrow() { if awk -v d="$1" 'BEGIN{exit (d > 5) ? 0 : 1}' 2>/dev/null; then echo "↑"; elif awk -v d="$1" 'BEGIN{exit (d < -5) ? 0 : 1}' 2>/dev/null; then echo "↓"; else echo "→"; fi; }

cat > "$REPORT_MD" << EOF
# Marvin Weekly Analytics Report
**Period:** ${REPORT_START} to ${REPORT_END}
**Generated:** ${NOW}

---

## System Health

| Metric | Average | Peak | WoW Change |
|--------|---------|------|------------|
| CPU % | ${cpu_avg}% | ${cpu_max}% | ${cpu_delta}% $(_arrow "$cpu_delta") |
| Memory | ${mem_avg} MB | ${mem_max} MB | ${mem_delta}% $(_arrow "$mem_delta") |
| Load 1m | ${load_avg} | — | — |
| Disk Used | ${disk_end} MB | — | ${disk_delta:+$disk_delta} MB delta |

- **Samples collected:** ${samples}
- **Uptime:** ${uptime_pct}% over ${days_tracked} days

## Claude API Usage

| Metric | This Week | WoW Change |
|--------|-----------|------------|
| Total runs | ${claude_runs} | ${claude_runs_delta}% $(_arrow "$claude_runs_delta") |
| Total time | ${claude_dur_h}h | — |
| Errors | ${claude_errors} (${claude_err_pct}%) | — |

### Top Tasks by Run Count

| Task | Runs | Duration | Errors |
|------|------|----------|--------|
${top_tasks}

## Log Summary

| Level | Count | WoW Change |
|-------|-------|------------|
| Errors | ${log_errors} | ${error_delta}% $(_arrow "$error_delta") |
| Warnings | ${log_warnings} | — |
| Criticals | ${log_criticals} | — |

### Top Recurring Errors
${top_errors_md}

## Security

- **Score:** ${security_score}/100 (Grade: ${security_grade})
- **Fail2ban total banned:** ${fail2ban_total}
- **Pending CVEs:** ${cve_pending}

## Enhancements

- **Enhancement sessions this week:** ${enhancement_count}

---
*Generated automatically by weekly-analytics.sh — no Claude API calls used.*
EOF

marvin_log "INFO" "Weekly analytics report: ${REPORT_JSON}"
marvin_log "INFO" "Weekly analytics digest: ${REPORT_MD}"
