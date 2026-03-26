#!/usr/bin/env bash
# =============================================================================
# Marvin — Enhancement History Tracker
# =============================================================================
# Scans enhancement reports and builds a structured JSON history of
# self-evolution: session counts, success/rollback rates, trends.
#
# Output: data/enhancements/history.json
# Cron: Called from self-enhance.sh after each session.
#       Can also run standalone: agent/enhancement-tracker.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR
marvin_parse_args "$@"

marvin_log "INFO" "Enhancement tracker starting"

HISTORY_FILE="${ENHANCE_DIR}/history.json"

# ─── Count enhancement sessions by type ──────────────────────────────────────
total_sessions=0
enhance_sessions=0
sync_sessions=0
rollback_sessions=0
weekly_sessions=0

# Per-week tracking (last 4 weeks)
declare -A week_counts
declare -A week_rollbacks

while IFS= read -r file; do
    fname=$(basename "$file")
    total_sessions=$((total_sessions + 1))

    # Classify by filename pattern
    if [[ "$fname" == *"ROLLED-BACK"* ]]; then
        rollback_sessions=$((rollback_sessions + 1))
    fi
    if [[ "$fname" == *"sync-learn"* ]]; then
        sync_sessions=$((sync_sessions + 1))
    elif [[ "$fname" == *"self-enhance"* || "$fname" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]+\.md$ ]]; then
        enhance_sessions=$((enhance_sessions + 1))
    fi

    # Extract date for weekly grouping
    file_date="${fname:0:10}"
    if [[ "$file_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        # ISO week number
        week_key=$(date -d "$file_date" +%G-W%V 2>/dev/null || echo "unknown")
        if [[ "$week_key" != "unknown" ]]; then
            week_counts[$week_key]=$(( ${week_counts[$week_key]:-0} + 1 ))
            if [[ "$fname" == *"ROLLED-BACK"* ]]; then
                week_rollbacks[$week_key]=$(( ${week_rollbacks[$week_key]:-0} + 1 ))
            fi
        fi
    fi
done < <(find "$ENHANCE_DIR" -maxdepth 1 -name "*.md" -type f | sort)

# ─── Compute success rate ────────────────────────────────────────────────────
success_rate="100.0"
if [[ "$enhance_sessions" -gt 0 ]]; then
    success_rate=$(awk -v total="$enhance_sessions" -v fail="$rollback_sessions" \
        'BEGIN{printf "%.1f", (total - fail) / total * 100}' 2>/dev/null || echo "100.0")
fi

# ─── Weekly trend (last 4 weeks) ────────────────────────────────────────────
weekly_trend="[]"
if [[ ${#week_counts[@]} -gt 0 ]]; then
    # Sort weeks descending, take last 4
    weekly_entries=()
    for week in $(echo "${!week_counts[@]}" | tr ' ' '\n' | sort -r | head -4); do
        count=${week_counts[$week]}
        rollbacks=${week_rollbacks[$week]:-0}
        weekly_entries+=("{\"week\":\"${week}\",\"sessions\":${count},\"rollbacks\":${rollbacks}}")
    done
    # Build JSON array (reverse to chronological order)
    weekly_trend=$(printf '%s\n' "${weekly_entries[@]}" | tac | jq -s '.' 2>/dev/null || echo "[]")
fi

# ─── First and latest session dates ─────────────────────────────────────────
# Extract dates from filenames — some files start with "sync-learn-YYYY-MM-DD" instead of "YYYY-MM-DD"
first_session=$(find "$ENHANCE_DIR" -maxdepth 1 -name "*.md" -type f -exec basename {} \; \
    | grep -oP '\d{4}-\d{2}-\d{2}' | sort | head -1)
latest_session=$(find "$ENHANCE_DIR" -maxdepth 1 -name "*.md" -type f -exec basename {} \; \
    | grep -oP '\d{4}-\d{2}-\d{2}' | sort | tail -1)

# ─── Days active ─────────────────────────────────────────────────────────────
days_active=0
if [[ -n "$first_session" && "$first_session" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    first_epoch=$(date -d "$first_session" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    if [[ "$first_epoch" -gt 0 ]]; then
        days_active=$(( (now_epoch - first_epoch) / 86400 ))
    fi
fi

# ─── Avg sessions per day ───────────────────────────────────────────────────
sessions_per_day="0.0"
if [[ "$days_active" -gt 0 ]]; then
    sessions_per_day=$(awk -v total="$enhance_sessions" -v days="$days_active" \
        'BEGIN{printf "%.1f", total / days}' 2>/dev/null || echo "0.0")
fi

# ─── Build output JSON ──────────────────────────────────────────────────────
if marvin_is_dry_run; then
    marvin_log "INFO" "[DRY-RUN] Would write history.json: ${total_sessions} sessions, ${rollback_sessions} rollbacks"
else
    jq -n \
        --arg ts "$NOW" \
        --argjson total "$total_sessions" \
        --argjson enhance "$enhance_sessions" \
        --argjson sync "$sync_sessions" \
        --argjson rollbacks "$rollback_sessions" \
        --arg success_rate "$success_rate" \
        --arg first "$first_session" \
        --arg latest "$latest_session" \
        --argjson days_active "$days_active" \
        --arg sessions_per_day "$sessions_per_day" \
        --argjson weekly "$weekly_trend" \
        '{
            timestamp: $ts,
            summary: {
                total_reports: $total,
                enhancement_sessions: $enhance,
                sync_learn_sessions: $sync,
                rollbacks: $rollbacks,
                success_rate_pct: ($success_rate | tonumber),
                first_session: $first,
                latest_session: $latest,
                days_active: $days_active,
                avg_sessions_per_day: ($sessions_per_day | tonumber)
            },
            weekly_trend: $weekly
        }' > "${HISTORY_FILE}.tmp" 2>/dev/null \
        && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"

    marvin_log "INFO" "Enhancement history updated: ${total_sessions} reports, ${enhance_sessions} enhancements, ${rollback_sessions} rollbacks, ${success_rate}% success rate"
fi
