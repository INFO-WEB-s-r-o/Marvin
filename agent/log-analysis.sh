#!/usr/bin/env bash
# =============================================================================
# Marvin — Log Analysis Pipeline
# =============================================================================
# Pattern detection and error clustering across multiple days.
# Normalizes error messages (strips variable parts like PIDs, timestamps,
# branch names), clusters similar errors, and tracks 7-day trends.
#
# No Claude API call — pure jq/awk/bash processing.
# Cron fires shortly after 00:00 UTC (after log-export and daily-digest).
#
# Output: data/logs/analysis-YYYY-MM-DD.json
#         data/logs/analysis-latest.json
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

# Target the UTC day that just ended. Override for manual runs:
#   TARGET_DATE=YYYY-MM-DD bash agent/log-analysis.sh
TODAY="${TARGET_DATE:-$(date -u -d 'yesterday' +%Y-%m-%d)}"

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

# Extract error/warning lines, normalize, count occurrences.
#
# The capture-then-fallback pattern below replaces the older
# `pipeline ... || echo '[]'` shape, which under `set -o pipefail` produced
# `[]\n[]` whenever grep matched nothing: jq -s already wrote `[]` to stdout,
# then pipefail propagated grep's exit 1 and `|| echo '[]'` appended a second
# `[]`. The captured value `[]\n[]` then crashed the downstream `--argjson`
# call with jq exit 2, leaving analysis-YYYY-MM-DD.json missing on every
# clean-error day. Same root cause family as `grep-c-double-output` lesson —
# a command that writes to stdout *before* exiting non-zero must not be
# combined with a `||`-emitting fallback.
_process_level() {
    # shellcheck disable=SC2034  # $1 ("errors"/"warnings") is documentation at the call site; pattern in $2 does the actual work
    local level="$1"
    local pattern="$2"
    local _out

    _out=$(grep -E "$pattern" "$LOG_FILE" 2>/dev/null \
        | sed 's/^\[[^]]*\] //' \
        | _normalize_message \
        | sort | uniq -c | sort -rn \
        | head -20 \
        | while read -r count signature; do
            # Find one raw example for this signature
            jq -nc --argjson c "$count" --arg s "$signature" \
                '{count: $c, signature: $s}'
        done | jq -s '.' 2>/dev/null) || true
    echo "${_out:-[]}"
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
_analysis_tmp=""
_latest_tmp=""
trap 'rm -f "$_past_signatures_file" "$_today_signatures_file" "${_analysis_tmp:-}" "${_latest_tmp:-}"' EXIT INT TERM

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

# Classify patterns. The `grep -cF ... || true; var=${var:-0}` shape below
# is required because `grep -c` always prints its count (even "0") *and*
# exits 1 when the count is zero. The older `|| echo 0` shape produced
# `0\n0`, which then crashed the per-iteration `--argjson pd` with jq exit 2
# and the per-iteration jq's silent failure dropped the entry from the array.
# Same root cause family as `grep-c-double-output` lesson.
if [[ -s "$_today_signatures_file" && -s "$_past_signatures_file" ]]; then
    # Recurring: appears both today and in past days
    _recurring=$(comm -12 <(sort -u "$_today_signatures_file") <(sort -u "$_past_signatures_file"))
    if [[ -n "$_recurring" ]]; then
        _recurring_out=$(echo "$_recurring" | while read -r sig; do
            today_count=$(echo "$error_clusters" | jq -r --arg s "$sig" '.[] | select(.signature == $s) | .count' 2>/dev/null || true)
            past_count=$(grep -cF "$sig" "$_past_signatures_file" 2>/dev/null || true)
            jq -nc --arg s "$sig" --argjson tc "${today_count:-0}" --argjson pd "${past_count:-0}" \
                '{signature: $s, today_count: $tc, past_days_seen: $pd, status: "recurring"}'
        done | jq -s '.' 2>/dev/null) || true
        recurring_patterns=${_recurring_out:-[]}
    fi

    # New: appears today but not in past
    _new=$(comm -23 <(sort -u "$_today_signatures_file") <(sort -u "$_past_signatures_file"))
    if [[ -n "$_new" ]]; then
        _new_out=$(echo "$_new" | while read -r sig; do
            today_count=$(echo "$error_clusters" | jq -r --arg s "$sig" '.[] | select(.signature == $s) | .count' 2>/dev/null || true)
            jq -nc --arg s "$sig" --argjson tc "${today_count:-0}" \
                '{signature: $s, today_count: $tc, status: "new"}'
        done | jq -s '.' 2>/dev/null) || true
        new_patterns=${_new_out:-[]}
    fi

    # Resolved: appeared in past but not today
    _resolved=$(comm -13 <(sort -u "$_today_signatures_file") <(sort -u "$_past_signatures_file"))
    if [[ -n "$_resolved" ]]; then
        _resolved_out=$(echo "$_resolved" | sort -u | head -10 | while read -r sig; do
            past_count=$(grep -cF "$sig" "$_past_signatures_file" 2>/dev/null || true)
            jq -nc --arg s "$sig" --argjson pd "${past_count:-0}" \
                '{signature: $s, past_days_seen: $pd, status: "resolved"}'
        done | jq -s '.' 2>/dev/null) || true
        resolved_patterns=${_resolved_out:-[]}
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

error_cluster_count=$(echo "$error_clusters" | jq 'length' 2>/dev/null || echo 0)
warning_cluster_count=$(echo "$warning_clusters" | jq 'length' 2>/dev/null || echo 0)
recurring_count=$(echo "$recurring_patterns" | jq 'length' 2>/dev/null || echo 0)
new_count=$(echo "$new_patterns" | jq 'length' 2>/dev/null || echo 0)
resolved_count=$(echo "$resolved_patterns" | jq 'length' 2>/dev/null || echo 0)

# Validate JSON inputs before passing to --argjson — a malformed value
# (multi-line, fallback text spliced in, etc.) would abort jq mid-execution
# and, before the atomic-write fix below, leave the destination empty (#638).
# `jq -s 'length == 1'` (instead of plain `jq empty`) catches multi-document
# inputs like "[]\n[]" — `jq empty` accepts those as valid JSON, but
# --argjson rejects them with exit 2. The capture-then-fallback fix in
# _process_level prevents the multi-doc case at source; this guard remains
# as defense-in-depth.
for _name in error_clusters warning_clusters recurring_patterns new_patterns resolved_patterns daily_error_trend component_health; do
    if ! jq -s -e 'length == 1' <<<"${!_name}" >/dev/null 2>&1; then
        marvin_log "WARN" "log-analysis: \$${_name} not single valid JSON document — substituting []"
        printf -v "$_name" '%s' '[]'
    fi
done

# Atomic write: build the report in a sibling tmp file, only mv-promote on
# successful jq completion. Mirrors PR #635 baseline-write hardening — fixes
# #638 (zero-byte analysis files when jq exits non-zero under set -euo pipefail).
_analysis_tmp=$(mktemp "${ANALYSIS_FILE}.XXXXXX")
if jq -n \
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
    }' > "$_analysis_tmp"; then
    # mktemp defaults to 0600 — restore the 644 that every other file under
    # data/ carries, so non-root local readers (lessons-learned.sh, self-test
    # §9b/§9d) can still read it after the atomic mv.
    #
    # This previously read "so nginx/dashboard consumers can still fetch
    # /api/logs/analysis-*.json", which has been false since #861 made
    # `location /api/` an allowlist: /api/logs/analysis-latest.json returns 403,
    # verified live. The permission is still correct, the old reason was not —
    # and tying 644 to an HTTP consumer that no longer exists invites both
    # "nothing fetches it, so tighten to 600" (breaks the local readers) and
    # "restore the endpoint" (re-publishes internal analysis, incl. attacker IPs).
    chmod 644 "$_analysis_tmp"
    mv -f "$_analysis_tmp" "$ANALYSIS_FILE"
else
    _jq_exit=$?
    rm -f "$_analysis_tmp"
    marvin_log "ERROR" "log-analysis: jq failed (exit ${_jq_exit}) — preserving previous ${ANALYSIS_FILE}"
    exit "$_jq_exit"
fi

# Atomic copy to analysis-latest.json so a partial cp doesn't leave consumers
# (dashboard, lessons-learned.sh, recurring-pattern detector) reading garbage.
_latest_tmp=$(mktemp "${ANALYSIS_LATEST}.XXXXXX")
if cp "$ANALYSIS_FILE" "$_latest_tmp" && chmod 644 "$_latest_tmp" && mv -f "$_latest_tmp" "$ANALYSIS_LATEST"; then
    :
else
    rm -f "$_latest_tmp"
    marvin_log "WARN" "log-analysis: failed to update ${ANALYSIS_LATEST}"
fi

marvin_log "INFO" "Log analysis complete: ${error_cluster_count} error clusters, ${warning_cluster_count} warning clusters, ${recurring_count} recurring, ${new_count} new, ${resolved_count} resolved, trend=${trend_direction}"
