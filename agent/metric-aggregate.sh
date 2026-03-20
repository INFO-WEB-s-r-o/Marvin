#!/usr/bin/env bash
# =============================================================================
# Marvin — Metric Aggregation
# =============================================================================
# Aggregates raw JSONL metrics into hourly and daily summaries.
# Reads data/metrics/YYYY-MM-DD.jsonl, outputs:
#   data/metrics/YYYY-MM-DD-hourly.json  (24 hourly buckets with min/avg/max)
#   data/metrics/YYYY-MM-DD-daily.json   (single-day summary)
#   data/metrics/weekly-summary.json     (rolling 7-day summary)
#
# Designed to run once per day (after midnight) on the previous day's data,
# but can also be called on-demand: metric-aggregate.sh [YYYY-MM-DD]
#
# Cron: Called from log-export.sh at 23:00 UTC (aggregates current day)
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

TARGET_DATE="${1:-$TODAY}"
JSONL_FILE="${METRICS_DIR}/${TARGET_DATE}.jsonl"

if [[ ! -f "$JSONL_FILE" ]]; then
    marvin_log "WARN" "No metrics file for ${TARGET_DATE} — skipping aggregation"
    exit 0
fi

HOURLY_FILE="${METRICS_DIR}/${TARGET_DATE}-hourly.json"
DAILY_FILE="${METRICS_DIR}/${TARGET_DATE}-daily.json"
WEEKLY_FILE="${METRICS_DIR}/weekly-summary.json"

marvin_log "INFO" "Aggregating metrics for ${TARGET_DATE}"

LINE_COUNT=$(wc -l < "$JSONL_FILE" | tr -d ' ')
marvin_log "INFO" "Processing ${LINE_COUNT} data points from ${JSONL_FILE}"

# ─── Hourly aggregation ─────────────────────────────────────────────────────
# Group metrics by hour, compute min/avg/max for key fields

# Under set -e, a failing jq would kill the script before $? is checked.
# Use && / || to capture the exit code without triggering set -e.
hourly_ok=true
jq -s '
  # Parse hour from timestamp
  map(. + {hour: (.timestamp | split("T")[1] | split(":")[0] | tonumber)})
  | group_by(.hour)
  | map({
      hour: .[0].hour,
      samples: length,
      cpu: {
        min: ([.[].cpu_percent] | min),
        avg: (([.[].cpu_percent] | add) / length | . * 10 | round / 10),
        max: ([.[].cpu_percent] | max)
      },
      memory_used_mb: {
        min: ([.[].memory.used] | min),
        avg: (([.[].memory.used] | add) / length | round),
        max: ([.[].memory.used] | max)
      },
      memory_available_mb: {
        min: ([.[].memory.available] | min),
        avg: (([.[].memory.available] | add) / length | round),
        max: ([.[].memory.available] | max)
      },
      swap_used_mb: {
        min: ([.[].swap.used] | min),
        avg: (([.[].swap.used] | add) / length | round),
        max: ([.[].swap.used] | max)
      },
      disk_used_mb: {
        min: ([.[].disk.used] | min),
        avg: (([.[].disk.used] | add) / length | round),
        max: ([.[].disk.used] | max)
      },
      load_1m: {
        min: ([.[]."load_average"."1min"] | min),
        avg: (([.[]."load_average"."1min"] | add) / length | . * 100 | round / 100),
        max: ([.[]."load_average"."1min"] | max)
      },
      process_count: {
        min: ([.[].process_count] | min),
        avg: (([.[].process_count] | add) / length | round),
        max: ([.[].process_count] | max)
      },
      fail2ban_banned: {
        min: ([.[].fail2ban_banned] | min),
        max: ([.[].fail2ban_banned] | max)
      }
    })
  | sort_by(.hour)
' "$JSONL_FILE" > "${HOURLY_FILE}.tmp" 2>/dev/null || hourly_ok=false

if [[ "$hourly_ok" == "true" ]] && jq empty "${HOURLY_FILE}.tmp" 2>/dev/null; then
    # Wrap in metadata envelope
    jq -n \
        --arg date "$TARGET_DATE" \
        --arg generated "$NOW" \
        --argjson hours "$(cat "${HOURLY_FILE}.tmp")" \
        --argjson total_samples "$LINE_COUNT" \
        '{
            date: $date,
            generated_at: $generated,
            total_samples: $total_samples,
            hourly: $hours
        }' > "$HOURLY_FILE"
    rm -f "${HOURLY_FILE}.tmp"
    marvin_log "INFO" "Hourly aggregation complete: ${HOURLY_FILE}"
else
    marvin_log "ERROR" "Hourly aggregation failed for ${TARGET_DATE}"
    rm -f "${HOURLY_FILE}.tmp"
fi

# ─── Daily aggregation ───────────────────────────────────────────────────────
# Single summary for the entire day

daily_ok=true
jq -s '
  {
    samples: length,
    cpu: {
      min: ([.[].cpu_percent] | min),
      avg: (([.[].cpu_percent] | add) / length | . * 10 | round / 10),
      max: ([.[].cpu_percent] | max),
      p95: (sort_by(.cpu_percent) | .[((length * 0.95) | floor)].cpu_percent)
    },
    memory_used_mb: {
      min: ([.[].memory.used] | min),
      avg: (([.[].memory.used] | add) / length | round),
      max: ([.[].memory.used] | max)
    },
    memory_available_mb: {
      min: ([.[].memory.available] | min),
      avg: (([.[].memory.available] | add) / length | round),
      max: ([.[].memory.available] | max)
    },
    swap_used_mb: {
      min: ([.[].swap.used] | min),
      avg: (([.[].swap.used] | add) / length | round),
      max: ([.[].swap.used] | max)
    },
    disk_used_mb: {
      first: (first.disk.used),
      last: (last.disk.used),
      delta: (last.disk.used - first.disk.used)
    },
    disk_percent: {
      first: (first.disk.percent),
      last: (last.disk.percent)
    },
    load_1m: {
      min: ([.[]."load_average"."1min"] | min),
      avg: (([.[]."load_average"."1min"] | add) / length | . * 100 | round / 100),
      max: ([.[]."load_average"."1min"] | max)
    },
    process_count: {
      min: ([.[].process_count] | min),
      avg: (([.[].process_count] | add) / length | round),
      max: ([.[].process_count] | max)
    },
    fail2ban: {
      min_banned: ([.[].fail2ban_banned] | min),
      max_banned: ([.[].fail2ban_banned] | max),
      net_change: (last.fail2ban_banned - first.fail2ban_banned)
    },
    uptime_hours: ((last.uptime_seconds - first.uptime_seconds) / 3600 | . * 10 | round / 10),
    network: {
      rx_mb: (if (last.network.rx_bytes // 0) >= (first.network.rx_bytes // 0) then (((last.network.rx_bytes // 0) - (first.network.rx_bytes // 0)) / 1048576 | round) else 0 end),
      tx_mb: (if (last.network.tx_bytes // 0) >= (first.network.tx_bytes // 0) then (((last.network.tx_bytes // 0) - (first.network.tx_bytes // 0)) / 1048576 | round) else 0 end),
      rx_bytes_first: (first.network.rx_bytes // 0),
      rx_bytes_last: (last.network.rx_bytes // 0),
      tx_bytes_first: (first.network.tx_bytes // 0),
      tx_bytes_last: (last.network.tx_bytes // 0)
    }
  }
' "$JSONL_FILE" > "${DAILY_FILE}.tmp" 2>/dev/null || daily_ok=false

if [[ "$daily_ok" == "true" ]] && jq empty "${DAILY_FILE}.tmp" 2>/dev/null; then
    jq -n \
        --arg date "$TARGET_DATE" \
        --arg generated "$NOW" \
        --argjson summary "$(cat "${DAILY_FILE}.tmp")" \
        --argjson total_samples "$LINE_COUNT" \
        '{
            date: $date,
            generated_at: $generated,
            total_samples: $total_samples,
            summary: $summary
        }' > "$DAILY_FILE"
    rm -f "${DAILY_FILE}.tmp"
    marvin_log "INFO" "Daily aggregation complete: ${DAILY_FILE}"
else
    marvin_log "ERROR" "Daily aggregation failed for ${TARGET_DATE}"
    rm -f "${DAILY_FILE}.tmp"
fi

# ─── Weekly rolling summary ─────────────────────────────────────────────────
# Combine the last 7 daily summaries into a weekly trend view

WEEKLY_DAYS=()
for i in $(seq 0 6); do
    d=$(date -u -d "${TARGET_DATE} - ${i} days" +%Y-%m-%d 2>/dev/null || date -u -v-${i}d -j -f "%Y-%m-%d" "$TARGET_DATE" +%Y-%m-%d 2>/dev/null)
    daily="${METRICS_DIR}/${d}-daily.json"
    if [[ -f "$daily" ]]; then
        WEEKLY_DAYS+=("$daily")
    fi
done

if [[ ${#WEEKLY_DAYS[@]} -gt 0 ]]; then
    # Merge daily summaries into weekly view
    weekly_ok=true
    jq -s '
      map({date: .date, summary: .summary})
      | sort_by(.date)
      | {
          period_start: first.date,
          period_end: last.date,
          days_with_data: length,
          daily_summaries: .,
          weekly_averages: {
            cpu_avg: ([.[].summary.cpu.avg] | add / length | . * 10 | round / 10),
            memory_used_avg_mb: ([.[].summary.memory_used_mb.avg] | add / length | round),
            load_avg: ([.[].summary.load_1m.avg] | add / length | . * 100 | round / 100),
            process_count_avg: ([.[].summary.process_count.avg] | add / length | round)
          }
        }
    ' "${WEEKLY_DAYS[@]}" > "${WEEKLY_FILE}.tmp" 2>/dev/null || weekly_ok=false

    if [[ "$weekly_ok" == "true" ]] && jq empty "${WEEKLY_FILE}.tmp" 2>/dev/null; then
        jq --arg generated "$NOW" '. + {generated_at: $generated}' \
            "${WEEKLY_FILE}.tmp" > "$WEEKLY_FILE"
        rm -f "${WEEKLY_FILE}.tmp"
        marvin_log "INFO" "Weekly summary updated: ${WEEKLY_FILE} (${#WEEKLY_DAYS[@]} days)"
    else
        rm -f "${WEEKLY_FILE}.tmp"
        marvin_log "WARN" "Weekly summary generation failed"
    fi
else
    marvin_log "WARN" "No daily summaries found for weekly aggregation"
fi

# ─── SLA / Uptime tracking ─────────────────────────────────────────────────
# Calculate uptime percentage from health check sample count.
# Expected: 288 samples/day (every 5 minutes = 12/hour * 24 hours).
# A missing sample means the health monitor didn't run (downtime or cron issue).
# Also accounts for partial days (first/last sample timestamps).

SLA_FILE="${METRICS_DIR}/sla.json"

_calculate_day_uptime() {
    local date="$1"
    local jsonl="${METRICS_DIR}/${date}.jsonl"
    [[ -f "$jsonl" ]] || return 0

    local samples
    samples=$(wc -l < "$jsonl" | tr -d ' ')
    [[ "$samples" -gt 0 ]] || return 0

    # Get first and last timestamps to determine the observation window
    local first_ts last_ts
    first_ts=$(head -1 "$jsonl" | jq -r '.timestamp' 2>/dev/null || echo "")
    last_ts=$(tail -1 "$jsonl" | jq -r '.timestamp' 2>/dev/null || echo "")

    if [[ -z "$first_ts" || -z "$last_ts" ]]; then
        echo "{\"date\":\"${date}\",\"samples\":${samples},\"expected\":288,\"uptime_pct\":0}"
        return
    fi

    # Calculate expected samples based on actual observation window
    local first_epoch last_epoch window_minutes expected
    first_epoch=$(date -d "$first_ts" +%s 2>/dev/null || echo 0)
    last_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo 0)

    if [[ "$first_epoch" -eq 0 || "$last_epoch" -eq 0 ]]; then
        # Fallback: assume full day
        expected=288
    else
        window_minutes=$(( (last_epoch - first_epoch) / 60 ))
        # Expected = window / 5min interval + 1 (for the first sample)
        expected=$(( window_minutes / 5 + 1 ))
        [[ "$expected" -lt 1 ]] && expected=1
    fi

    # Uptime % = samples collected / expected samples * 100
    local uptime_pct
    if [[ "$expected" -gt 0 ]]; then
        uptime_pct=$(awk "BEGIN {v = ($samples / $expected) * 100; if (v > 100) v = 100; printf \"%.2f\", v}")
    else
        uptime_pct="0.00"
    fi

    echo "{\"date\":\"${date}\",\"samples\":${samples},\"expected\":${expected},\"uptime_pct\":${uptime_pct}}"
}

# Calculate SLA for the last 30 days
SLA_DAYS=()
for i in $(seq 0 29); do
    d=$(date -u -d "${TARGET_DATE} - ${i} days" +%Y-%m-%d 2>/dev/null || \
        date -u -v-${i}d -j -f "%Y-%m-%d" "$TARGET_DATE" +%Y-%m-%d 2>/dev/null)
    day_sla=$(_calculate_day_uptime "$d")
    if [[ -n "$day_sla" ]]; then
        SLA_DAYS+=("$day_sla")
    fi
done

if [[ ${#SLA_DAYS[@]} -gt 0 ]]; then
    # Build JSON array from collected day SLAs
    sla_json=$(printf '%s\n' "${SLA_DAYS[@]}" | jq -s '
        sort_by(.date) |
        {
            days: .,
            summary: {
                days_tracked: length,
                total_samples: ([.[].samples] | add),
                total_expected: ([.[].expected] | add),
                overall_uptime_pct: (([.[].samples] | add) / ([.[].expected] | add) * 100 | . * 100 | round / 100),
                worst_day: (min_by(.uptime_pct) | {date: .date, uptime_pct: .uptime_pct}),
                best_day: (max_by(.uptime_pct) | {date: .date, uptime_pct: .uptime_pct}),
                days_at_100pct: ([.[] | select(.uptime_pct >= 99.9)] | length)
            }
        }
    ' 2>/dev/null)

    if [[ -n "$sla_json" ]] && echo "$sla_json" | jq empty 2>/dev/null; then
        echo "$sla_json" | jq --arg generated "$NOW" '. + {generated_at: $generated}' > "$SLA_FILE"
        overall=$(echo "$sla_json" | jq -r '.summary.overall_uptime_pct')
        days_tracked=$(echo "$sla_json" | jq -r '.summary.days_tracked')
        marvin_log "INFO" "SLA tracking: ${overall}% uptime over ${days_tracked} days"
    else
        marvin_log "WARN" "SLA calculation produced invalid JSON"
    fi
else
    marvin_log "WARN" "No metric data found for SLA calculation"
fi

# ─── Resource Forecasting ─────────────────────────────────────────────────
# Linear regression on daily disk/memory data to predict exhaustion.
# Uses the last 14 daily summaries for trend estimation.
# Output: data/metrics/resource-forecast.json

FORECAST_FILE="${METRICS_DIR}/resource-forecast.json"

# Collect the last 14 daily summaries (most recent first)
FORECAST_DAYS=()
for i in $(seq 0 13); do
    d=$(date -u -d "${TARGET_DATE} - ${i} days" +%Y-%m-%d 2>/dev/null || \
        date -u -v-${i}d -j -f "%Y-%m-%d" "$TARGET_DATE" +%Y-%m-%d 2>/dev/null)
    daily="${METRICS_DIR}/${d}-daily.json"
    if [[ -f "$daily" ]]; then
        FORECAST_DAYS+=("$daily")
    fi
done

if [[ ${#FORECAST_DAYS[@]} -ge 3 ]]; then
    # jq linear regression: index days as x=0..n, y=metric value
    # slope = (n*Σxy - Σx*Σy) / (n*Σx² - (Σx)²)
    forecast_ok=true
    jq -s '
        map({date: .date, disk_used: .summary.disk_used_mb.last, mem_used: .summary.memory_used_mb.avg})
        | sort_by(.date)
        | to_entries
        | {
            data_points: length,
            period_start: first.value.date,
            period_end: last.value.date,
            disk: (
                [.[] | {x: .key, y: .value.disk_used}] as $pts |
                ($pts | length) as $n |
                ($pts | map(.x) | add) as $sx |
                ($pts | map(.y) | add) as $sy |
                ($pts | map(.x * .y) | add) as $sxy |
                ($pts | map(.x * .x) | add) as $sx2 |
                (($n * $sxy - $sx * $sy) / ($n * $sx2 - $sx * $sx)) as $slope |
                ($sy / $n - $slope * $sx / $n) as $intercept |
                last.value.disk_used as $current |
                {
                    current_mb: $current,
                    trend_mb_per_day: ($slope | . * 10 | round / 10),
                    direction: (if $slope > 1 then "growing" elif $slope < -1 then "shrinking" else "stable" end)
                }
            ),
            memory: (
                [.[] | {x: .key, y: .value.mem_used}] as $pts |
                ($pts | length) as $n |
                ($pts | map(.x) | add) as $sx |
                ($pts | map(.y) | add) as $sy |
                ($pts | map(.x * .y) | add) as $sxy |
                ($pts | map(.x * .x) | add) as $sx2 |
                (($n * $sxy - $sx * $sy) / ($n * $sx2 - $sx * $sx)) as $slope |
                last.value.mem_used as $current |
                {
                    current_mb: $current,
                    trend_mb_per_day: ($slope | . * 10 | round / 10),
                    direction: (if $slope > 5 then "growing" elif $slope < -5 then "shrinking" else "stable" end)
                }
            )
        }
    ' "${FORECAST_DAYS[@]}" > "${FORECAST_FILE}.tmp" 2>/dev/null || forecast_ok=false

    if [[ "$forecast_ok" == "true" ]] && jq empty "${FORECAST_FILE}.tmp" 2>/dev/null; then
        # Enrich with exhaustion predictions using current disk/memory totals
        # Fix for issue #249: jq outputs "null" (exit 0) when key is missing,
        # so || fallback never fires. Use // empty to get empty string instead.
        local_disk_total=$(jq -r '.disk.total // empty' "${METRICS_DIR}/latest.json" 2>/dev/null) || true
        local_mem_total=$(jq -r '.memory.total // empty' "${METRICS_DIR}/latest.json" 2>/dev/null) || true

        if [[ -z "$local_disk_total" || -z "$local_mem_total" ]]; then
            marvin_log "WARN" "Resource forecast: could not read disk/memory totals from latest.json — skipping enrichment"
            mv "${FORECAST_FILE}.tmp" "$FORECAST_FILE"
            disk_trend=$(jq -r '.disk.trend_mb_per_day' "$FORECAST_FILE" 2>/dev/null) || true
            disk_dir=$(jq -r '.disk.direction' "$FORECAST_FILE" 2>/dev/null) || true
            marvin_log "INFO" "Resource forecast (basic): disk ${disk_dir:-unknown} (${disk_trend:-?} MB/day)"
        else

        jq --arg generated "$NOW" \
           --argjson disk_total "$local_disk_total" \
           --argjson mem_total "$local_mem_total" '
            .generated_at = $generated |
            .disk.total_mb = $disk_total |
            .disk.available_mb = ($disk_total - .disk.current_mb) |
            .disk.used_pct = (.disk.current_mb / $disk_total * 100 | . * 10 | round / 10) |
            .disk.days_to_80pct = (
                if .disk.trend_mb_per_day > 0 then
                    if .disk.current_mb >= ($disk_total * 0.8) then 0
                    else (($disk_total * 0.8 - .disk.current_mb) / .disk.trend_mb_per_day | floor) end
                else null end
            ) |
            .disk.days_to_90pct = (
                if .disk.trend_mb_per_day > 0 then
                    if .disk.current_mb >= ($disk_total * 0.9) then 0
                    else (($disk_total * 0.9 - .disk.current_mb) / .disk.trend_mb_per_day | floor) end
                else null end
            ) |
            .memory.total_mb = $mem_total |
            .memory.available_mb = ($mem_total - .memory.current_mb) |
            .memory.used_pct = (.memory.current_mb / $mem_total * 100 | . * 10 | round / 10) |
            .memory.days_to_80pct = (
                if .memory.trend_mb_per_day > 0 then
                    if .memory.current_mb >= ($mem_total * 0.8) then 0
                    else (($mem_total * 0.8 - .memory.current_mb) / .memory.trend_mb_per_day | floor) end
                else null end
            ) |
            .memory.days_to_90pct = (
                if .memory.trend_mb_per_day > 0 then
                    if .memory.current_mb >= ($mem_total * 0.9) then 0
                    else (($mem_total * 0.9 - .memory.current_mb) / .memory.trend_mb_per_day | floor) end
                else null end
            )
        ' "${FORECAST_FILE}.tmp" > "$FORECAST_FILE"
            rm -f "${FORECAST_FILE}.tmp"

            disk_trend=$(jq -r '.disk.trend_mb_per_day' "$FORECAST_FILE")
            disk_dir=$(jq -r '.disk.direction' "$FORECAST_FILE")
            days_80=$(jq -r '.disk.days_to_80pct // "N/A"' "$FORECAST_FILE")
            marvin_log "INFO" "Resource forecast: disk ${disk_dir} (${disk_trend} MB/day), days to 80%: ${days_80}"
        fi
    else
        rm -f "${FORECAST_FILE}.tmp"
        marvin_log "WARN" "Resource forecasting failed"
    fi
else
    marvin_log "WARN" "Not enough daily data for resource forecast (need 3+, have ${#FORECAST_DAYS[@]})"
fi

marvin_log "INFO" "Metric aggregation complete for ${TARGET_DATE}"
