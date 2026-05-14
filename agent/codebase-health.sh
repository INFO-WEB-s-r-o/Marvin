#!/usr/bin/env bash
# =============================================================================
# Marvin — Codebase Health Score
# =============================================================================
# Evaluates the overall health of Marvin's codebase across 4 dimensions:
#   1. Code Quality (25 pts): syntax, conflict markers, ShellCheck
#   2. Code Hygiene (25 pts): TODOs, script size, error handling coverage
#   3. Operational Health (25 pts): error rates, security score, self-tests
#   4. Evolution (25 pts): enhancement success rate, roadmap progress
#
# Output: data/codebase/health.json
# Usage: agent/codebase-health.sh [--dry-run]
# Called from: weekly-enhance.sh, standalone
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR
marvin_parse_args "$@"

marvin_log "INFO" "Codebase health score evaluation starting"

HEALTH_DIR="${DATA_DIR}/codebase"
marvin_is_dry_run || mkdir -p "$HEALTH_DIR"
HEALTH_FILE="${HEALTH_DIR}/health.json"

AGENT_DIR="${MARVIN_DIR}/agent"

# ─── Count scripts and LOC ──────────────────────────────────────────────────
total_scripts=0
total_loc=0
oversized=0
while IFS= read -r script; do
    total_scripts=$((total_scripts + 1))
    loc=$(wc -l < "$script" 2>/dev/null || echo 0)
    total_loc=$((total_loc + loc))
    [[ "$loc" -gt 500 ]] && oversized=$((oversized + 1))
done < <(find "$AGENT_DIR" -name "*.sh" -type f)

avg_loc=0
[[ "$total_scripts" -gt 0 ]] && avg_loc=$((total_loc / total_scripts))

# ═════════════════════════════════════════════════════════════════════════════
# Dimension 1: Code Quality (0-25)
# ═════════════════════════════════════════════════════════════════════════════
quality_score=25
quality_notes=()

# Syntax check all scripts
syntax_errors=0
while IFS= read -r script; do
    if ! bash -n "$script" 2>/dev/null; then
        syntax_errors=$((syntax_errors + 1))
        quality_notes+=("Syntax error: $(basename "$script")")
    fi
done < <(find "$AGENT_DIR" -name "*.sh" -type f)
[[ "$syntax_errors" -gt 0 ]] && quality_score=$((quality_score - syntax_errors * 5))

# Merge conflict markers
conflict_files=0
while IFS= read -r file; do
    if grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$file" 2>/dev/null; then
        conflict_files=$((conflict_files + 1))
        quality_notes+=("Conflict markers: $(basename "$file")")
    fi
done < <(find "$AGENT_DIR" -name "*.sh" -type f; find "${WEB_DIR}/src" -type f \( -name "*.js" -o -name "*.ts" -o -name "*.tsx" \) 2>/dev/null || true)
[[ "$conflict_files" -gt 0 ]] && quality_score=$((quality_score - conflict_files * 5))

# ShellCheck (if available) — use JSON output for reliable severity counting
shellcheck_errors=0
shellcheck_warnings=0
if command -v shellcheck &>/dev/null; then
    while IFS= read -r script; do
        # The shellcheck CLI exits 1 with JSON already printed — `|| true` swallows only the exit code (lessons-learned: grep-c-double-output)
        sc_json=$(shellcheck -f json -S warning "$script" 2>/dev/null || true)
        sc_json=${sc_json:-'[]'}
        errs=$(echo "$sc_json" | jq '[.[] | select(.level=="error")] | length' 2>/dev/null || true)
        warns=$(echo "$sc_json" | jq '[.[] | select(.level=="warning")] | length' 2>/dev/null || true)
        errs=${errs:-0}
        warns=${warns:-0}
        shellcheck_errors=$((shellcheck_errors + errs))
        shellcheck_warnings=$((shellcheck_warnings + warns))
    done < <(find "$AGENT_DIR" -name "*.sh" -type f)
    [[ "$shellcheck_errors" -gt 0 ]] && quality_score=$((quality_score - shellcheck_errors * 2))
    [[ "$shellcheck_errors" -gt 0 ]] && quality_notes+=("ShellCheck errors: ${shellcheck_errors}")
fi

[[ $quality_score -lt 0 ]] && quality_score=0

# ═════════════════════════════════════════════════════════════════════════════
# Dimension 2: Code Hygiene (0-25)
# ═════════════════════════════════════════════════════════════════════════════
hygiene_score=25
hygiene_notes=()

# TODO/FIXME/HACK markers
todo_count=0
while IFS= read -r script; do
    t=$(grep -ciE '\bTODO\b|\bFIXME\b|\bHACK\b|\bXXX\b' "$script" 2>/dev/null) || t=0
    todo_count=$((todo_count + t))
done < <(find "$AGENT_DIR" -name "*.sh" -type f)
if [[ "$todo_count" -gt 10 ]]; then
    hygiene_score=$((hygiene_score - 3))
    hygiene_notes+=("TODO/FIXME markers: ${todo_count}")
elif [[ "$todo_count" -gt 0 ]]; then
    hygiene_notes+=("TODO/FIXME markers: ${todo_count}")
fi

# Oversized scripts (>500 LOC)
if [[ "$oversized" -gt 3 ]]; then
    hygiene_score=$((hygiene_score - 3))
    hygiene_notes+=("Oversized scripts (>500 LOC): ${oversized}")
elif [[ "$oversized" -gt 0 ]]; then
    hygiene_notes+=("Oversized scripts (>500 LOC): ${oversized}")
fi

# Error trap coverage
trap_count=0
trap_eligible=0
while IFS= read -r script; do
    trap_eligible=$((trap_eligible + 1))
    if grep -q 'marvin_error_trap\|trap.*ERR' "$script" 2>/dev/null; then
        trap_count=$((trap_count + 1))
    fi
done < <(find "$AGENT_DIR" -maxdepth 1 -name "*.sh" -type f ! -name "common.sh")
trap_pct=0
[[ "$trap_eligible" -gt 0 ]] && trap_pct=$((trap_count * 100 / trap_eligible))
if [[ "$trap_pct" -lt 50 ]]; then
    hygiene_score=$((hygiene_score - 5))
    hygiene_notes+=("Error trap coverage: ${trap_pct}%")
elif [[ "$trap_pct" -lt 80 ]]; then
    hygiene_score=$((hygiene_score - 2))
    hygiene_notes+=("Error trap coverage: ${trap_pct}%")
fi

[[ $hygiene_score -lt 0 ]] && hygiene_score=0

# ═════════════════════════════════════════════════════════════════════════════
# Dimension 3: Operational Health (0-25)
# ═════════════════════════════════════════════════════════════════════════════
ops_score=25
ops_notes=()

# Average errors per day (last 7 days)
total_errors=0
total_log_days=0
for i in $(seq 0 6); do
    d=$(date -u -d "${TODAY} - ${i} day" +%Y-%m-%d 2>/dev/null || true)
    [[ -z "$d" ]] && continue
    log="${LOGS_DIR}/${d}.log"
    if [[ -f "$log" ]]; then
        total_log_days=$((total_log_days + 1))
        # grep -c exits 1 on zero matches with "0" already printed — `|| true` swallows only the exit code (lessons-learned: grep-c-double-output)
        day_errors=$(grep -ci '\[ERROR\]' "$log" 2>/dev/null || true)
        day_errors=${day_errors:-0}
        total_errors=$((total_errors + day_errors))
    fi
done
avg_errors_per_day=0
[[ "$total_log_days" -gt 0 ]] && avg_errors_per_day=$((total_errors / total_log_days))
if [[ "$avg_errors_per_day" -gt 20 ]]; then
    ops_score=$((ops_score - 5))
    ops_notes+=("High error rate: ${avg_errors_per_day}/day")
elif [[ "$avg_errors_per_day" -gt 10 ]]; then
    ops_score=$((ops_score - 2))
    ops_notes+=("Elevated error rate: ${avg_errors_per_day}/day")
fi

# Security score (from self-test.sh)
sec_score=0
if [[ -f "${DATA_DIR}/security/security-score.json" ]]; then
    sec_score=$(jq -r '.score // 0' "${DATA_DIR}/security/security-score.json" 2>/dev/null || echo 0)
    sec_score_int=${sec_score%%.*}
    if [[ "$sec_score_int" -lt 70 ]]; then
        ops_score=$((ops_score - 5))
        ops_notes+=("Security score: ${sec_score}/100")
    elif [[ "$sec_score_int" -lt 85 ]]; then
        ops_score=$((ops_score - 2))
    fi
fi

# SLA uptime
# Note: the value lives under .summary.overall_uptime_pct (set by
# metric-aggregate.sh, see agent/metric-aggregate.sh:362+). Reading from the
# top-level key returned null and silently skipped the -lt 99 deduction
# from 2026-03-26 until 2026-05-14.
sla_pct="unknown"
if [[ -f "${METRICS_DIR}/sla.json" ]]; then
    sla_pct=$(jq -r '.summary.overall_uptime_pct // "unknown"' "${METRICS_DIR}/sla.json" 2>/dev/null || echo "unknown")
    if [[ "$sla_pct" != "unknown" ]]; then
        sla_int=${sla_pct%%.*}
        if [[ "$sla_int" -lt 99 ]]; then
            ops_score=$((ops_score - 3))
            ops_notes+=("SLA below 99%: ${sla_pct}%")
        fi
    fi
fi

[[ $ops_score -lt 0 ]] && ops_score=0

# ═════════════════════════════════════════════════════════════════════════════
# Dimension 4: Evolution (0-25)
# ═════════════════════════════════════════════════════════════════════════════
evo_score=25
evo_notes=()

success_rate="100.0"
rollbacks=0
enhance_sessions=0
sessions_per_day="0"

if [[ -f "${ENHANCE_DIR}/history.json" ]]; then
    success_rate=$(jq -r '.summary.success_rate_pct // 100' "${ENHANCE_DIR}/history.json" 2>/dev/null || echo 100)
    rollbacks=$(jq -r '.summary.rollbacks // 0' "${ENHANCE_DIR}/history.json" 2>/dev/null || echo 0)
    enhance_sessions=$(jq -r '.summary.enhancement_sessions // 0' "${ENHANCE_DIR}/history.json" 2>/dev/null || echo 0)
    sessions_per_day=$(jq -r '.summary.avg_sessions_per_day // 0' "${ENHANCE_DIR}/history.json" 2>/dev/null || echo 0)

    sr_int=${success_rate%%.*}
    if [[ "$sr_int" -lt 80 ]]; then
        evo_score=$((evo_score - 5))
        evo_notes+=("Enhancement success rate: ${success_rate}%")
    elif [[ "$sr_int" -lt 95 ]]; then
        evo_score=$((evo_score - 2))
    fi

    spd_int=${sessions_per_day%%.*}
    if [[ "$spd_int" -lt 1 ]]; then
        evo_score=$((evo_score - 2))
        evo_notes+=("Low enhancement activity: ${sessions_per_day}/day")
    fi
else
    evo_score=$((evo_score - 5))
    evo_notes+=("No enhancement history found")
fi

# Roadmap progress
roadmap_total=0
roadmap_done=0
roadmap_pct=0
if [[ -f "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" ]]; then
    # grep -c exits 1 on zero matches — prophylactic guard (lessons-learned: grep-c-double-output)
    roadmap_total=$(grep -c '^\- \[' "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" 2>/dev/null || true)
    roadmap_done=$(grep -c '^\- \[x\]' "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" 2>/dev/null || true)
    roadmap_total=${roadmap_total:-0}
    roadmap_done=${roadmap_done:-0}
    [[ "$roadmap_total" -gt 0 ]] && roadmap_pct=$((roadmap_done * 100 / roadmap_total))
    evo_notes+=("Roadmap: ${roadmap_done}/${roadmap_total} (${roadmap_pct}%)")
fi

[[ $evo_score -lt 0 ]] && evo_score=0

# ═════════════════════════════════════════════════════════════════════════════
# Total score and grade
# ═════════════════════════════════════════════════════════════════════════════
total_score=$((quality_score + hygiene_score + ops_score + evo_score))

grade="F"
if   [[ "$total_score" -ge 90 ]]; then grade="A"
elif [[ "$total_score" -ge 80 ]]; then grade="B"
elif [[ "$total_score" -ge 70 ]]; then grade="C"
elif [[ "$total_score" -ge 60 ]]; then grade="D"
fi

# Collect all notes
all_notes=()
[[ ${#quality_notes[@]} -gt 0 ]] && all_notes+=("${quality_notes[@]}")
[[ ${#hygiene_notes[@]} -gt 0 ]] && all_notes+=("${hygiene_notes[@]}")
[[ ${#ops_notes[@]} -gt 0 ]] && all_notes+=("${ops_notes[@]}")
[[ ${#evo_notes[@]} -gt 0 ]] && all_notes+=("${evo_notes[@]}")

notes_json="[]"
if [[ ${#all_notes[@]} -gt 0 ]]; then
    notes_json=$(printf '%s\n' "${all_notes[@]}" | jq -R . | jq -s '.' 2>/dev/null || echo '[]')
fi

# ─── Output ──────────────────────────────────────────────────────────────────
if marvin_is_dry_run; then
    marvin_log "INFO" "[DRY-RUN] Codebase health: ${total_score}/100 (${grade})"
else
    jq -n \
        --arg ts "$NOW" \
        --argjson total "$total_score" \
        --arg grade "$grade" \
        --argjson quality "$quality_score" \
        --argjson hygiene "$hygiene_score" \
        --argjson ops "$ops_score" \
        --argjson evolution "$evo_score" \
        --argjson scripts "$total_scripts" \
        --argjson loc "$total_loc" \
        --argjson avg_loc "$avg_loc" \
        --argjson syntax_errors "$syntax_errors" \
        --argjson shellcheck_errors "$shellcheck_errors" \
        --argjson shellcheck_warnings "$shellcheck_warnings" \
        --argjson conflict_files "$conflict_files" \
        --argjson todo_count "$todo_count" \
        --argjson oversized "$oversized" \
        --argjson trap_pct "$trap_pct" \
        --argjson avg_errors_per_day "$avg_errors_per_day" \
        --argjson sec_score "$sec_score" \
        --arg sla_pct "$sla_pct" \
        --argjson roadmap_pct "$roadmap_pct" \
        --argjson notes "$notes_json" \
        '{
            timestamp: $ts,
            score: $total,
            grade: $grade,
            dimensions: {
                code_quality: {score: $quality, max: 25},
                code_hygiene: {score: $hygiene, max: 25},
                operational_health: {score: $ops, max: 25},
                evolution: {score: $evolution, max: 25}
            },
            metrics: {
                total_scripts: $scripts,
                total_loc: $loc,
                avg_loc_per_script: $avg_loc,
                syntax_errors: $syntax_errors,
                shellcheck_errors: $shellcheck_errors,
                shellcheck_warnings: $shellcheck_warnings,
                conflict_files: $conflict_files,
                todo_fixme_count: $todo_count,
                oversized_scripts: $oversized,
                error_trap_coverage_pct: $trap_pct,
                avg_errors_per_day: $avg_errors_per_day,
                security_score: $sec_score,
                sla_uptime_pct: $sla_pct,
                roadmap_progress_pct: $roadmap_pct
            },
            notes: $notes
        }' > "${HEALTH_FILE}.tmp" 2>/dev/null \
        && mv "${HEALTH_FILE}.tmp" "$HEALTH_FILE"

    marvin_log "INFO" "Codebase health: ${total_score}/100 (${grade}) — quality=${quality_score} hygiene=${hygiene_score} ops=${ops_score} evolution=${evo_score}"
fi
