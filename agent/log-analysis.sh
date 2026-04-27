#!/usr/bin/env bash
# =============================================================================
# Marvin — Log Analysis Pipeline
# =============================================================================
# Pattern detection and error clustering across multiple days.
# Normalizes error messages (strips variable parts like PIDs, timestamps,
# branch names), clusters similar errors, and tracks 7-day trends.
#
# No Claude API call — pure jq/awk/bash processing.
# Runs at 23:45 UTC via cron (after daily-digest at 23:30).
#
# Output: data/logs/analysis-YYYY-MM-DD.json
#         data/logs/analysis-latest.json
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

marvin_log "INFO" "Log analysis pipeline starting for ${TODAY}"

LOG_FILE="${LOGS_DIR}/${TODAY}.log"
ANALYSIS_FILE="${DATA_DIR}/logs/analysis-${TODAY}.json"
ANALYSIS_LATEST="${DATA_DIR}/logs/analysis-latest.json"

if [[ ! -f "$LOG_FILE" ]]; then
    marvin_log "WARN" "No log file found for ${TODAY}"
    exit 0
fi

# ─── Phase 1: Normalize error messages ──────────────────────────────────────
# Strip variable parts to create "error signatures" that group similar messages.
# E.g., "Failed to push branch fix/issues-1774445101" → "Failed to push branch fix/issues-*"

_normalize_message() {
    sed -E \
        -e 's/PID[= ]*[0-9]+/PID=*/g' \
        -e 's/\b[0-9]{10,}\b/*/g' \
        -e 's/fix\/issues-[0-9]+/fix\/issues-*/g' \
        -e 's/fix\/[a-z0-9-]+/fix\/*/' \
        -e 's/enhance\/[a-z0-9-]+/enhance\/*/' \
        -e 's/data\/[0-9-]+/data\/*/' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z/TIMESTAMP/g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/DATE/g' \
        -e 's/\b[0-9a-f]{7,40}\b/HASH/g' \
        -e 's/HTTP [0-9]{3}/HTTP NNN/g' \
        -e 's/\b[0-9]+(\.[0-9]+)?%/*%/g' \
        -e 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/IP/g' \
        -e 's/port [0-9]+/port */g' \
        -e 's/[0-9]+ (seconds?|minutes?|hours?|days?|bytes?|MB|GB|KB)/* \1/g' \
        -e 's/[0-9]+s\b/*s/g' \
        -e 's/(exit[= ]*)[0-9]+/\1*/g'
}

# ─── Phase 2: Extract and cluster errors/warnings ──────────────────────────

# Extract error/warning lines, normalize, count occurrences
_process_level() {
    local level="$1"
    local pattern="$2"

    grep -E "$pattern" "$LOG_FILE" 2>/dev/null \
        | sed 's/^\[[^]]*\] //' \
        | _normalize_message \
        | sort | uniq -c | sort -rn \
        | head -20 \
        | while read -r count signature; do
            # Find one raw example for this signature
            jq -nc --argjson c "$count" --arg s "$signature" \
                '{count: $c, signature: $s}'
        done | jq -s '.' 2>/dev/null || echo '[]'
}

error_clusters=$(_process_level "errors" '\[(CRITICAL|ERROR)\]')
warning_clusters=$(_process_level "warnings" '\[WARN\]')

# ─── Phase 3: Identify recurring patterns across 7 days ────────────────────
# Compare today's error signatures against the last 7 days to find persistent issues.

TREND_DAYS=7
recurring_patterns='[]'
new_patterns='[]'
resolved_patterns='[]'

# Collect signatures from past days
_past_signatures_file=$(mktemp)
_today_signatures_file=$(mktemp)
trap 'rm -f "$_past_signatures_file" "$_today_signatures_file"' EXIT

# Today's signatures
echo "$error_clusters" | jq -r '.[].signature' 2>/dev/null > "$_today_signatures_file" || true

# Past days' signatures
for i in $(seq 1 $TREND_DAYS); do
    _d=$(date -u -d "${TODAY} - ${i} day" +%Y-%m-%d 2>/dev/null || true)
    [[ -z "$_d" ]] && continue
    _past_analysis="${DATA_DIR}/logs/analysis-${_d}.json"
    if [[ -f "$_past_analysis" ]]; then
        jq -r '.error_clusters[].signature // empty' "$_past_analysis" 2>/dev/null >> "$_past_signatures_file" || true
    else
        # Fall back to raw log if analysis doesn't exist yet
        _past_log="${LOGS_DIR}/${_d}.log"
        if [[ -f "$_past_log" ]]; then
            grep -E '\[(CRITICAL|ERROR)\]' "$_past_log" 2>/dev/null \
                | sed 's/^\[[^]]*\] //' \
                | _normalize_message \
                | sort -u >> "$_past_signatures_file" || true
        fi
    fi
done

# Classify patterns
if [[ -s "$_today_signatures_file" && -s "$_past_signatures_file" ]]; then
    # Recurring: appears both today and in past days
    _recurring=$(comm -12 <(sort -u "$_today_signatures_file") <(sort -u "$_past_signatures_file"))
    if [[ -n "$_recurring" ]]; then
        recurring_patterns=$(echo "$_recurring" | while read -r sig; do
            today_count=$(echo "$error_clusters" | jq -r --arg s "$sig" '.[] | select(.signature == $s) | .count' 2>/dev/null || echo 0)
            past_count=$(grep -cF "$sig" "$_past_signatures_file" 2>/dev/null || echo 0)
            jq -nc --arg s "$sig" --argjson tc "${today_count:-0}" --argjson pd "$past_count" \
                '{signature: $s, today_count: $tc, past_days_seen: $pd, status: "recurring"}'
        done | jq -s '.' 2>/dev/null || echo '[]')
    fi

    # New: appears today but not in past
    _new=$(comm -23 <(sort -u "$_today_signatures_file") <(sort -u "$_past_signatures_file"))
    if [[ -n "$_new" ]]; then
        new_patterns=$(echo "$_new" | while read -r sig; do
            today_count=$(echo "$error_clusters" | jq -r --arg s "$sig" '.[] | select(.signature == $s) | .count' 2>/dev/null || echo 0)
            jq -nc --arg s "$sig" --argjson tc "${today_count:-0}" \
                '{signature: $s, today_count: $tc, status: "new"}'
        done | jq -s '.' 2>/dev/null || echo '[]')
    fi

    # Resolved: appeared in past but not today
    _resolved=$(comm -13 <(sort -u "$_today_signatures_file") <(sort -u "$_past_signatures_file"))
    if [[ -n "$_resolved" ]]; then
        resolved_patterns=$(echo "$_resolved" | sort -u | head -10 | while read -r sig; do
            past_count=$(grep -cF "$sig" "$_past_signatures_file" 2>/dev/null || echo 0)
            jq -nc --arg s "$sig" --argjson pd "$past_count" \
                '{signature: $s, past_days_seen: $pd, status: "resolved"}'
        done | jq -s '.' 2>/dev/null || echo '[]')
    fi
fi

# ─── Phase 4: Error rate trend (7-day) ─────────────────────────────────────
# Track total errors per day to detect escalation or improvement.

daily_error_trend='[]'
for i in $(seq $TREND_DAYS -1 0); do
    _d=$(date -u -d "${TODAY} - ${i} day" +%Y-%m-%d 2>/dev/null || true)
    [[ -z "$_d" ]] && continue
    _day_log="${LOGS_DIR}/${_d}.log"
    _day_errors=0
    _day_warnings=0
    _day_criticals=0
    if [[ -f "$_day_log" ]]; then
        _day_errors=$(grep -c '\[ERROR\]' "$_day_log" 2>/dev/null || true)
        _day_warnings=$(grep -c '\[WARN\]' "$_day_log" 2>/dev/null || true)
        _day_criticals=$(grep -c '\[CRITICAL\]' "$_day_log" 2>/dev/null || true)
    fi
    daily_error_trend=$(echo "$daily_error_trend" | jq --arg d "$_d" \
        --argjson e "$_day_errors" --argjson w "$_day_warnings" --argjson c "$_day_criticals" \
        '. + [{date: $d, errors: $e, warnings: $w, criticals: $c}]' 2>/dev/null || echo "$daily_error_trend")
done

# Compute trend direction (comparing today vs 7-day average)
trend_direction="stable"
if echo "$daily_error_trend" | jq -e 'length > 2' &>/dev/null; then
    _today_errors=$(echo "$daily_error_trend" | jq '.[- 1].errors' 2>/dev/null || echo 0)
    _avg_errors=$(echo "$daily_error_trend" | jq '[.[:-1] | .[].errors] | (add / length) | floor' 2>/dev/null || echo 0)
    if [[ "$_today_errors" -gt $((_avg_errors * 2)) && "$_today_errors" -gt 5 ]]; then
        trend_direction="worsening"
    elif [[ "$_today_errors" -lt $((_avg_errors / 2)) || "$_today_errors" -le 2 ]]; then
        trend_direction="improving"
    fi
fi

# ─── Phase 5: Component health (from structured logs) ──────────────────────
# If structured JSONL logs exist, compute per-component error rates.

component_health='[]'
STRUCTURED_LOG="${LOGS_DIR}/${TODAY}-structured.jsonl"
if [[ -f "$STRUCTURED_LOG" ]]; then
    component_health=$(jq -s '
        group_by(.component) |
        map({
            component: .[0].component,
            total: length,
            errors: [.[] | select(.level == "ERROR" or .level == "CRITICAL")] | length,
            warnings: [.[] | select(.level == "WARN")] | length
        }) |
        sort_by(-.errors)
    ' "$STRUCTURED_LOG" 2>/dev/null || echo '[]')
fi

# ─── Phase 6: Build analysis report ────────────────────────────────────────

# Sanitize numeric captures: trim past first newline + numeric regex guard.
# Mirrors the security-scan.sh pattern from PRs #619/#621 — `jq | … || echo 0`
# can leave partial output spliced with the fallback when jq fails mid-stream.
error_cluster_count=$(echo "$error_clusters" | jq 'length' 2>/dev/null || echo 0)
error_cluster_count=${error_cluster_count%%$'\n'*}
[[ "$error_cluster_count" =~ ^[0-9]+$ ]] || error_cluster_count=0
warning_cluster_count=$(echo "$warning_clusters" | jq 'length' 2>/dev/null || echo 0)
warning_cluster_count=${warning_cluster_count%%$'\n'*}
[[ "$warning_cluster_count" =~ ^[0-9]+$ ]] || warning_cluster_count=0
recurring_count=$(echo "$recurring_patterns" | jq 'length' 2>/dev/null || echo 0)
recurring_count=${recurring_count%%$'\n'*}
[[ "$recurring_count" =~ ^[0-9]+$ ]] || recurring_count=0
new_count=$(echo "$new_patterns" | jq 'length' 2>/dev/null || echo 0)
new_count=${new_count%%$'\n'*}
[[ "$new_count" =~ ^[0-9]+$ ]] || new_count=0
resolved_count=$(echo "$resolved_patterns" | jq 'length' 2>/dev/null || echo 0)
resolved_count=${resolved_count%%$'\n'*}
[[ "$resolved_count" =~ ^[0-9]+$ ]] || resolved_count=0

# Atomic write: `>` truncates the destination before jq runs, so a jq failure
# under `set -euo pipefail` leaves analysis-YYYY-MM-DD.json zero bytes (#638).
# Mirrors the file-integrity.sh baseline-write hardening from PRs #632/#635.
_tmp_analysis=$(mktemp --tmpdir="${DATA_DIR}/logs" .analysis.XXXXXX)
trap 'rm -f "$_past_signatures_file" "$_today_signatures_file" "$_tmp_analysis"' EXIT

jq -n \
    --arg date "$TODAY" \
    --arg ts "$NOW" \
    --arg trend "$trend_direction" \
    --argjson error_clusters "$error_clusters" \
    --argjson warning_clusters "$warning_clusters" \
    --argjson recurring "$recurring_patterns" \
    --argjson new_patterns "$new_patterns" \
    --argjson resolved "$resolved_patterns" \
    --argjson error_trend "$daily_error_trend" \
    --argjson components "$component_health" \
    '{
        date: $date,
        generated_at: $ts,
        summary: {
            error_cluster_count: ($error_clusters | length),
            warning_cluster_count: ($warning_clusters | length),
            recurring_patterns: ($recurring | length),
            new_patterns: ($new_patterns | length),
            resolved_patterns: ($resolved | length),
            trend_direction: $trend
        },
        error_clusters: $error_clusters,
        warning_clusters: $warning_clusters,
        pattern_analysis: {
            recurring: $recurring,
            new: $new_patterns,
            resolved: $resolved
        },
        error_trend_7d: $error_trend,
        component_health: $components
    }' > "$_tmp_analysis"

mv -f "$_tmp_analysis" "$ANALYSIS_FILE"

cp "$ANALYSIS_FILE" "$ANALYSIS_LATEST"

marvin_log "INFO" "Log analysis complete: ${error_cluster_count} error clusters, ${warning_cluster_count} warning clusters, ${recurring_count} recurring, ${new_count} new, ${resolved_count} resolved, trend=${trend_direction}"
