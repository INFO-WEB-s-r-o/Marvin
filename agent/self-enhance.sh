#!/usr/bin/env bash
# =============================================================================
# Marvin — Self-Enhancement (runs daily at 12:00 UTC)
# =============================================================================
# The most interesting (and dangerous) part:
#   - Reviews own scripts and prompts
#   - Proposes improvements
#   - Applies approved changes (to non-critical files)
#   - Logs everything for community review
#
# SAFETY: Marvin can modify files in agent/ and web/ directories.
#         He CANNOT modify setup/bootstrap.sh or this safety comment.
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/lib/github.sh"
trap marvin_error_trap ERR

marvin_log "INFO" "=== SELF-ENHANCEMENT STARTING ==="

check_claude || exit 1

# ─── Skip if too many open PRs already (don't pile up) ───────────────────────
# Mirrors fix-issues.sh's guard — self-enhance opens PRs the same as
# fix-issues does, but had no equivalent brake (added 2026-07-31, #935/#937
# fallout: PRs were accumulating faster than they could be reviewed/merged).
#
# Fails CLOSED (#996): a missing/invalid token or a failed/malformed PR
# fetch must skip this run, not fall through into self-enhancement with
# the PR count unknown — that silently recreates the exact pile-up this
# guard exists to prevent. The next daily run is a cheap retry.
if ! github_check_token 2>/dev/null; then
    marvin_log "WARN" "GitHub token check failed — cannot verify open-PR count, skipping self-enhancement this run"
    exit 0
fi
open_prs=$(github_list_prs 100 2>/dev/null) && _prs_fetch_ok=true || _prs_fetch_ok=false
if [[ "$_prs_fetch_ok" != "true" ]] || ! echo "$open_prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    marvin_log "WARN" "Could not fetch open PRs (transient) — skipping self-enhancement this run so the pile-up guard stays reliable"
    exit 0
fi
open_pr_count=$(echo "$open_prs" | jq 'length' 2>/dev/null || echo "0")
if [[ "$open_pr_count" -ge 3 ]]; then
    marvin_log "INFO" "Already ${open_pr_count} open PRs — skipping self-enhancement to avoid pile-up"
    exit 0
fi

# ─── Pre-flight: detect divergence from origin/main since morning sync ───────
# morning-check.sh pulled at 04:00 UTC. Self-enhance runs at 08:00 UTC. PRs that
# merged on GitHub in between leave local main 1+ commits behind origin/main,
# and Claude can propose duplicates of changes that just landed.
# (Yesterday's session walked into this with PR #710 vs #709.)
# We just fetch + capture the divergence; rebasing is morning-check's job.
PREFLIGHT_DIVERGENCE=""
if timeout 30 git -C "$MARVIN_DIR" fetch --quiet origin main 2>/dev/null; then
    _ahead=$(git -C "$MARVIN_DIR" log --oneline main..origin/main 2>/dev/null || true)
    if [[ -n "$_ahead" ]]; then
        _count=$(printf '%s\n' "$_ahead" | wc -l | tr -d ' ')
        marvin_log "WARN" "Pre-flight: origin/main is ${_count} commit(s) ahead of local main since morning-check pulled"
        PREFLIGHT_DIVERGENCE="origin/main is ${_count} commit(s) ahead — these merged on GitHub since 04:00 UTC and are NOT yet reflected in the codebase below. Re-check whether your planned change duplicates any of them before writing code:
${_ahead}"
    fi
else
    marvin_log "WARN" "Pre-flight: git fetch origin main failed or timed out"
fi

# ─── Rollback mechanism ─────────────────────────────────────────────────────
# Snapshot the codebase before Claude makes changes. If changes break scripts,
# revert automatically. This prevents self-enhancement from bricking the agent.

PRE_ENHANCE_HEAD=$(git -C "$MARVIN_DIR" rev-parse HEAD 2>/dev/null || echo "")

_enhance_rollback() {
    marvin_log "WARN" "Rolling back self-enhancement changes..."
    cd "$MARVIN_DIR" 2>/dev/null || return 1
    # Reset to pre-enhancement commit — this reverts both committed and uncommitted changes
    local git_out
    if [[ -n "${PRE_ENHANCE_HEAD}" ]]; then
        marvin_log "INFO" "Resetting to pre-enhancement HEAD: ${PRE_ENHANCE_HEAD:0:12}"
        if ! git_out=$(git reset --hard "$PRE_ENHANCE_HEAD" 2>&1); then
            marvin_log "CRITICAL" "git reset --hard failed: ${git_out}"
            return 1
        fi
    else
        # Fallback: revert only uncommitted changes if HEAD wasn't captured
        if ! git_out=$(git checkout -- agent/ web/ 2>&1); then
            marvin_log "CRITICAL" "git checkout rollback failed: ${git_out}"
            return 1
        fi
    fi
    if ! git_out=$(git clean -fd agent/ web/ 2>&1); then
        marvin_log "WARN" "git clean failed during rollback: ${git_out}"
    fi
    marvin_log "INFO" "Rollback complete — codebase restored to pre-enhancement state"
}

_validate_post_enhance() {
    local valid=true

    # 1. Bash syntax + conflict marker check for .sh files in the repo
    #    Files outside Marvin's write scope (agent/, web/) produce warnings
    #    instead of rollbacks — Marvin can't fix setup/ scripts (#304).
    while IFS= read -r script; do
        local is_writable=true
        if [[ "$script" != "${MARVIN_DIR}/agent/"* && "$script" != "${MARVIN_DIR}/web/"* ]]; then
            is_writable=false
        fi
        if ! bash -n "$script" 2>/dev/null; then
            if [[ "$is_writable" == "true" ]]; then
                marvin_log "ERROR" "Post-enhance validation FAILED: syntax error in ${script#${MARVIN_DIR}/}"
                valid=false
            else
                marvin_log "WARN" "Pre-existing syntax error in read-only script (non-fatal): ${script#${MARVIN_DIR}/}"
            fi
        fi
        if grep -qE '^<{7} |^={7}$|^>{7} ' "$script" 2>/dev/null; then
            if [[ "$is_writable" == "true" ]]; then
                marvin_log "ERROR" "Post-enhance validation FAILED: conflict markers in ${script#${MARVIN_DIR}/}"
                valid=false
            else
                marvin_log "WARN" "Conflict markers in read-only script (non-fatal): ${script#${MARVIN_DIR}/}"
            fi
        fi
    done < <(find "${MARVIN_DIR}" -name "*.sh" -type f -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/data/*")

    # 2. Conflict marker check for web/ source files (JS/TS/JSX/TSX/JSON/CSS)
    #    These aren't bash-checkable but conflict markers would break the build
    while IFS= read -r webfile; do
        if grep -qE '^<{7} |^={7}$|^>{7} ' "$webfile" 2>/dev/null; then
            marvin_log "ERROR" "Post-enhance validation FAILED: conflict markers in ${webfile#${MARVIN_DIR}/}"
            valid=false
        fi
    done < <(find "${MARVIN_DIR}/web" -type f \( -name "*.js" -o -name "*.ts" -o -name "*.jsx" -o -name "*.tsx" -o -name "*.json" -o -name "*.css" \) -not -path "*/node_modules/*" -not -path "*/.next/*" 2>/dev/null)

    [[ "$valid" == "true" ]]
}

# Read the enhancement prompt (modular: task prompt + shared modules)
ENHANCE_PROMPT=$(marvin_build_prompt "enhance" identity security-rules)

# ─── The enhancement roadmap, bounded ───────────────────────────────────────
# POSSIBLE_ENHANCEMENTS.md is append-only and now 288 KB, of which 268 KB (93%,
# 249 entries) is the "Completed Enhancements Log". Passing the whole file made
# the roadmap 82% of this prompt and twice drove it past run_claude's ceiling:
# 404,819 chars on 2026-07-20 and 497,498 on 2026-07-27, against 400,000.
#
# That ceiling is enforced by a blunt slice. On 07-27 the slice landed
# mid-security-scan.sh and discarded everything after it — including
# self-test.sh, the one script that had genuinely failed that day and the
# entire reason the failure-script selector exists. The budgeting added that
# session stopped the selector from over-spending; it did not shrink the thing
# actually consuming the budget, which is this file.
#
# What a session picks from is the phase sections — every unchecked item, all
# 19 KB — so those go in VERBATIM AND IN FULL, always. Bounding happens only
# below the completed-log header.
#
# The completed log is written newest-first, so "recent" is a prefix of it and
# needs no date parsing: keep WHOLE entries up to a size budget, then stop and
# say how many were left out. Whole entries, because a mid-entry cut presents a
# severed sentence as if it were the complete record — the same defect as the
# blunt slice this exists to avoid, just moved upstream.
#
# The budget counts in the SAME unit run_claude's cut uses. Both are characters
# under the cron locale (LANG=C.UTF-8), because awk length() and bash ${#var}
# each follow the locale — see the measurement in lib/claude.sh. Do not "fix"
# either side to count bytes on its own; the two agreeing is the property that
# matters, and this file's 2,101 multibyte bytes are 0.8% of the headroom.
_ROADMAP_LOG_HEADER='## Completed Enhancements Log'
_ROADMAP_RECENT_BUDGET=60000

# Echoes the roadmap for the prompt. NOTE: stdout here IS the roadmap text, so
# nothing in this function may call marvin_log without redirecting to stderr —
# marvin_log writes to stdout (lib/logging.sh), and a log line would be
# captured and rendered to the model as though it were roadmap content.
_bounded_roadmap() {
    local file="$1" budget="$2" header_line
    header_line=$(grep -n -F -x "$_ROADMAP_LOG_HEADER" "$file" | head -1 | cut -d: -f1) || header_line=""

    if [[ -z "$header_line" ]]; then
        # The file was restructured and the boundary is gone. Emit it whole
        # rather than guess where the log starts: an over-long prompt is
        # recoverable (run_claude warns and truncates), a roadmap silently
        # missing its unchecked items is not — there would be nothing to pick
        # from and no sign anything was lost. Say so out loud, because a quiet
        # fallback here reads exactly like a bound that worked.
        marvin_log "WARN" "self-enhance: roadmap header '${_ROADMAP_LOG_HEADER}' not found — passing the roadmap UNBOUNDED ($(wc -c <"$file") bytes); prompt may be truncated" >&2
        cat "$file"
        return
    fi

    # Everything above the completed log: verbatim, unconditionally.
    head -n "$((header_line - 1))" "$file"

    # The completed log: whole entries while under budget, then a named remainder.
    tail -n +"$header_line" "$file" | awk -v budget="$budget" '
        # Entry boundary. Counted before the budget gate so that entries we
        # drop are still counted and can be reported.
        /^- \[x\] \*\*\[/ {
            entries++
            if (bytes >= budget) over = 1
        }
        over { next }
        {
            print
            bytes += length($0) + 1
            if (/^- \[x\] \*\*\[/) kept++
        }
        END {
            dropped = entries - kept
            if (dropped > 0) {
                printf "\n_(%d older completed entries omitted from this prompt to keep it inside the prompt budget. They are NOT gone: the full history is in POSSIBLE_ENHANCEMENTS.md on disk. Append new entries there as usual.)_\n", dropped
            }
        }
    '
}

ENHANCEMENTS=""
if [[ -f "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" ]]; then
    ENHANCEMENTS=$(_bounded_roadmap "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" "$_ROADMAP_RECENT_BUDGET")
fi

# Gather context: list all scripts with sizes, include only the most relevant ones
# Full dump of all scripts exceeds 160KB (~40K tokens) — too large for effective enhancement.
# Instead: include a directory listing + only scripts mentioned in today's errors or roadmap.
SCRIPTS_CONTEXT=""

# Always include the directory listing so Claude knows what exists
SCRIPTS_CONTEXT+="### Script inventory (name — lines — bytes)
\`\`\`
$(find "${MARVIN_DIR}/agent" -name "*.sh" -type f -exec sh -c 'echo "$(wc -l < "$1") lines  $(wc -c < "$1") bytes  ${1#'"${MARVIN_DIR}/"'}"' _ {} \; | sort -k3)
\`\`\`

"

# Include key infrastructure scripts that are always relevant (common.sh, lib/).
#
# ONE list, read by both the loop below and _rank_scripts' skip check. It used
# to be written out twice — literals here, literals again in the skip test —
# with nothing tying them together. Adding a third always-included script and
# updating only one copy would have dumped it into the prompt twice, spending
# budget on a duplicate while a genuinely implicated script was refused for
# want of it.
ALWAYS_INCLUDED_SCRIPTS=("agent/common.sh" "agent/lib/github.sh")

for script_name in "${ALWAYS_INCLUDED_SCRIPTS[@]}"; do
    script="${MARVIN_DIR}/${script_name}"
    if [[ -f "$script" ]]; then
        SCRIPTS_CONTEXT+="### ${script_name}
\`\`\`bash
$(cat "$script")
\`\`\`

"
    fi
done

# ─── Scripts implicated in today's failures ─────────────────────────────────
# Selected here, but appended AFTER the rest of the prompt is assembled, so the
# dump can be budgeted against real remaining headroom (see below).
#
# The previous selector was `grep -oP '(?<=agent/)[a-z-]+\.sh'` over the whole
# log, and it never once did what its comment claimed. Two independent faults,
# either of which alone would have broken it:
#
#   1. It required a literal `agent/` prefix, but marvin_error_trap logs the
#      BASENAME (`self-test.sh:1279 — command failed`, lib/logging.sh:120).
#      No ERR-trap line can match that lookbehind — structurally, not by bad
#      luck. The selector could not see an error if it tried.
#   2. It scanned every line at every level, so what it actually matched was
#      whatever else happened to spell a path that day. On 2026-07-27 that was
#      four INFO lines from file-integrity.sh ("git-synced — /home/…/agent/
#      <name>.sh") — a monitored-path list with no relation to failure.
#
# So "scripts that had errors today" resolved to "scripts file-integrity
# mentioned in passing", and each was then labelled "(had errors today)" in the
# prompt — a false claim, not merely a miss. It pulled in 153,656 bytes of
# unrelated source, which is what drove the prompt to 497,498 chars against
# run_claude's 400,000 ceiling. The hard cut landed mid-`security-scan.sh` and
# discarded `self-test.sh` — the ONE script that had genuinely failed that day,
# and the whole reason this selector exists.
#
# Match basenames on failure lines only, and rank ERROR/CRITICAL above WARN so
# that when the budget binds it drops the least-implicated script, not the most
# (priority order: fix failures first).
_failure_log="${LOGS_DIR}/${TODAY}.log"
_selector_ran=true
_err_bases=""
_warn_bases=""
if [[ -r "$_failure_log" ]]; then
    _err_bases=$( { grep -E '\[(ERROR|CRITICAL)\]' "$_failure_log" 2>/dev/null || true; } \
        | grep -oE '[A-Za-z0-9_.-]+\.sh' | sort -u ) || _err_bases=""
    _warn_bases=$( { grep -E '\[WARN\]' "$_failure_log" 2>/dev/null || true; } \
        | grep -oE '[A-Za-z0-9_.-]+\.sh' | sort -u ) || _warn_bases=""
else
    # A scan that could not run must not read as "nothing found".
    _selector_ran=false
    marvin_log "WARN" "Cannot read ${_failure_log} — failure-implicated scripts NOT selected this run"
fi

# Resolve basenames to real files, dropping anything already dumped in full
# above. Emits "<size>\t<relpath>" so the caller can order and budget.
#
# `wc -m` (characters), NOT `wc -c` (bytes). The budget these sizes are spent
# against is built from `${#var}`, and run_claude's own ceiling test is
# `${#full_prompt}` — both of which count CHARACTERS under this host's
# C.UTF-8 locale. Mixing the two units is not academic here: the em-dashes and
# accented text throughout these scripts make `self-test.sh` 73,503 bytes but
# 70,667 characters. `wc -c` overstates every candidate by ~4%, which biases
# toward refusing a script that would in fact have fitted — the precise
# outcome this whole section exists to prevent. Under a C/POSIX locale the two
# coincide, so this is correct either way rather than locale-dependent.
#
# The sort is `-s -t $'\t' -k1,1n` and deliberately NOT `-n -u` (#897). With
# `-n` active and no explicit key, GNU sort compares — and therefore dedupes —
# on the leading numeric field alone, so two DIFFERENT scripts with the same
# `wc -m` count are "duplicates" and one is discarded:
#
#   $ printf '100\tA.sh\n100\tB.sh\n' | sort -n -u   →   only 100<TAB>A.sh
#
# The loser vanished before the budgeting loop ever saw it, so it appeared
# neither in the prompt nor in `_omitted` (that notice is built only from what
# survives into `_ranked`) — a silent drop of an implicated script, in the code
# whose entire purpose is to have no silent drops. `-u` was never needed:
# within one call each base yields at most one real path per candidate
# directory, and cross-tier repeats are deduped downstream by
# `awk '!seen[$2]++'` on the full relative path. `-k1,1n` confines the numeric
# comparison to the size field, and `-s` keeps ties in input order so the
# ranking is reproducible run to run.
_rank_scripts() {
    local base path rel already script_name
    for base in $1; do
        for path in "${MARVIN_DIR}/agent/${base}" "${MARVIN_DIR}/agent/lib/${base}"; do
            [[ -f "$path" ]] || continue
            rel="${path#"${MARVIN_DIR}"/}"
            # Skip anything the always-include loop already dumped in full.
            already=false
            for script_name in "${ALWAYS_INCLUDED_SCRIPTS[@]}"; do
                [[ "$rel" == "$script_name" ]] && { already=true; break; }
            done
            [[ "$already" == "true" ]] && continue
            printf '%s\t%s\n' "$(wc -m < "$path")" "$rel"
        done
    done | sort -s -t $'\t' -k1,1n
}
# ERROR/CRITICAL tier first, then WARN; awk drops a script already ranked in
# the higher tier so it keeps its stronger claim on the budget.
_ranked=$( { _rank_scripts "$_err_bases"; _rank_scripts "$_warn_bases"; } | awk '!seen[$2]++' )

# Claude can read additional scripts as needed using its Read tool

# Run lessons-learned maintenance to generate summary for prompt
LESSONS_SUMMARY=""
if [[ -x "$(dirname "$0")/lessons-learned.sh" ]]; then
    bash "$(dirname "$0")/lessons-learned.sh" || marvin_log "WARN" "Lessons-learned script failed (non-fatal)"
    if [[ -f "${DATA_DIR}/lessons-summary.md" ]]; then
        LESSONS_SUMMARY=$(head -100 "${DATA_DIR}/lessons-summary.md")
    fi
fi

# ─── Prompt assembly, budgeted against run_claude's hard ceiling ────────────
# run_claude truncates at MARVIN_CLAUDE_MAX_PROMPT_CHARS with a blunt cut
# that slices mid-file and drops everything after it. Assemble the parts we
# cannot do without first, measure what is left, and spend the remainder on
# script bodies deliberately — naming whatever did not fit, rather than letting
# the tail fall off in silence.
SELF_CONTEXT_HEAD="${PREFLIGHT_DIVERGENCE:+## Pre-flight Warning: origin/main has moved since morning sync

${PREFLIGHT_DIVERGENCE}

}## Enhancement Roadmap (pick from here)

${ENHANCEMENTS}

## Current Marvin Codebase

${SCRIPTS_CONTEXT}"

SELF_CONTEXT_TAIL="
### Recent Enhancement History
\`\`\`
$(ls -la "${ENHANCE_DIR}/" 2>/dev/null | tail -20 || echo "No previous enhancements")
\`\`\`

### Recent Issues from Logs
\`\`\`
$(grep -i "error\|warn\|critical\|fail" "${LOGS_DIR}/${TODAY}.log" 2>/dev/null | tail -30 || echo "No issues found today")
\`\`\`

### Web Dashboard HTML (current)
\`\`\`html
$(head -50 "${WEB_DIR}/index.html" 2>/dev/null || echo "Not yet created")
\`\`\`

${LESSONS_SUMMARY:+## Lessons Learned (avoid repeating these mistakes)

${LESSONS_SUMMARY}}
"

# Reserve room for run_claude's own preamble (system-state JSON, date and task
# name, prepended inside run_claude and therefore invisible to the arithmetic
# here) plus the omission notice this block may append.
_PROMPT_RESERVE=8000
_budget=$(( MARVIN_CLAUDE_MAX_PROMPT_CHARS - ${#ENHANCE_PROMPT} - ${#SELF_CONTEXT_HEAD} - ${#SELF_CONTEXT_TAIL} - _PROMPT_RESERVE ))

FAILURE_SCRIPTS_BLOCK=""
_included=0
_omitted=""
while IFS=$'\t' read -r _size _rel; do
    [[ -n "$_rel" ]] || continue
    # Build the entry, then charge the budget what it ACTUALLY costs. The
    # previous version guessed "~40 chars of heading and fence overhead" and
    # spent that; the real wrapper is `### ` + the relative path + ` (implicated
    # in today's failures)` + two fenced lines + a blank line — 51 chars plus
    # the path, measured at 69 for agent/self-test.sh and 71 for
    # agent/lib/logging.sh. Every included entry therefore under-charged the
    # budget by ~30 chars, and the error grew with the path. Small against an
    # 8000-char reserve, but it is the same species of defect as the one this
    # file was opened to fix: an assumed constant standing in for a quantity
    # that is right there to be measured. `${#_entry}` is exactly the unit
    # run_claude enforces in (characters), so there is nothing left to drift.
    _entry="### ${_rel} (implicated in today's failures)
\`\`\`bash
$(cat "${MARVIN_DIR}/${_rel}")
\`\`\`

"
    if [[ "$_budget" -gt "${#_entry}" ]]; then
        FAILURE_SCRIPTS_BLOCK+="$_entry"
        _budget=$(( _budget - ${#_entry} ))
        _included=$(( _included + 1 ))
    else
        _omitted+="${_omitted:+, }${_rel} (${_size} chars)"
    fi
done <<< "$_ranked"

if [[ "$_selector_ran" != "true" ]]; then
    FAILURE_SCRIPTS_BLOCK+="### Scripts implicated in today's failures: SELECTION FAILED

Today's log could not be read, so this section is **not** empty-because-clean.
It is empty because the scan did not run. Do not read it as an all-clear.

"
elif [[ -n "$_omitted" ]]; then
    marvin_log "WARN" "Prompt budget exhausted — omitted failure-implicated script(s): ${_omitted}"
    FAILURE_SCRIPTS_BLOCK+="### Omitted for prompt budget — read these yourself if relevant

${_omitted}

These scripts are implicated in today's failures but did not fit the prompt
budget. They are NOT absent from the codebase and NOT irrelevant — open them
with your Read tool before concluding anything about today's failures.

"
fi
marvin_log "INFO" "Failure-implicated scripts: ${_included} included, ${_omitted:-none} omitted; ${_budget} chars of budget left"

FULL_PROMPT="${ENHANCE_PROMPT}

${SELF_CONTEXT_HEAD}
${FAILURE_SCRIPTS_BLOCK}${SELF_CONTEXT_TAIL}"

# Run Claude for self-enhancement. Up to 2 retries on transient exit=1 with
# escalating backoff — self-enhance runs once per day, so a single transient
# API error / stochastic classifier rejection would otherwise lose the whole
# day's enhancement. Crucially, a bare `OUTPUT=$(run_claude ...)` under
# `set -euo pipefail` + the ERR trap does not just skip — it fires
# marvin_error_trap and kills the session before the rollback/validation logic
# below can run (exactly what happened 2026-07-10T08:00:11Z at :214). Capture
# the exit code and skip gracefully instead — same pattern as morning-check.sh
# (retry) and hourly-check.sh (graceful skip). On failure Claude applied no
# changes (the request is rejected before any work), so there is nothing to
# roll back; the next daily run retries.
CLAUDE_EXIT=0
OUTPUT=$(run_claude_with_retry "self-enhance" "$FULL_PROMPT" 2) || CLAUDE_EXIT=$?

if [[ $CLAUDE_EXIT -ne 0 ]]; then
    marvin_log "WARN" "Claude run failed (exit=${CLAUDE_EXIT}) — skipping this self-enhance cycle (no changes applied; next daily run retries)"
    marvin_log "INFO" "=== SELF-ENHANCEMENT COMPLETE (SKIPPED — transient Claude failure) ==="
    exit 0
fi

# ─── Post-enhancement validation ────────────────────────────────────────────
# If Claude's changes broke any scripts, roll back automatically
if ! _validate_post_enhance; then
    marvin_log "CRITICAL" "Self-enhancement produced invalid code — triggering rollback"
    if ! _enhance_rollback; then
        marvin_log "CRITICAL" "Rollback FAILED — codebase may be in unknown state. Manual intervention required."
        exit 2
    fi
    # Save the output anyway for debugging
    ENHANCE_FILE="${ENHANCE_DIR}/${TODAY}-${TIMESTAMP}-ROLLED-BACK.md"
    cat > "$ENHANCE_FILE" << EOF
# Self-Enhancement ROLLED BACK — ${NOW}

**Reason:** Post-enhancement validation failed (syntax error or conflict markers)

## Claude's Analysis & Changes (reverted)

${OUTPUT}

---
*Enhancement run ${TIMESTAMP} — changes were rolled back automatically*
EOF
    marvin_log "INFO" "Rolled-back enhancement log saved: ${ENHANCE_FILE}"
    marvin_log "INFO" "=== SELF-ENHANCEMENT COMPLETE (ROLLED BACK) ==="
    exit 1
fi

marvin_log "INFO" "Post-enhancement validation passed"

# ─── Auto-rebuild web if source files changed ────────────────────────────────
# Detects web/ source modifications and triggers a full Next.js rebuild+restart.
# Without this, source edits produce stale builds → JS asset 404s for hours.
#
# grep-c-double-output lesson: `grep -cE ... || echo "0"` writes "0\n0" on zero
# matches (grep prints its 0, then the fallback prints another 0). The captured
# multi-line value then made `[[ -gt 0 ]]` log a "syntax error in expression"
# to stderr and silently fall through to the else branch on every cron run
# that changed only agent/ (which is most days). Capture-then-fallback keeps
# grep's count and only swallows the exit code.
_web_changed=$(git -C "$MARVIN_DIR" diff --name-only HEAD~1 HEAD 2>/dev/null \
    | grep -cE '^web/.*\.(tsx?|jsx?|css|json)$' || true)
_web_changed=${_web_changed:-0}
if [[ "$_web_changed" -gt 0 ]]; then
    marvin_log "INFO" "Detected ${_web_changed} web source file(s) changed — triggering rebuild"
    if ! marvin_rebuild_web "self-enhance (${_web_changed} files changed)"; then
        marvin_log "WARN" "Web rebuild failed after self-enhance — dashboard may show stale content"
    fi
else
    marvin_log "INFO" "No web source changes detected — skipping rebuild"
fi

# Save the enhancement proposal
ENHANCE_FILE="${ENHANCE_DIR}/${TODAY}-${TIMESTAMP}.md"
cat > "$ENHANCE_FILE" << EOF
# Self-Enhancement Proposal — ${NOW}

## Claude's Analysis & Changes

${OUTPUT}

---
*Enhancement run ${TIMESTAMP}*
EOF

marvin_log "INFO" "Enhancement proposal saved: ${ENHANCE_FILE}"

# Update enhancement history tracker
if [[ -x "$(dirname "$0")/enhancement-tracker.sh" ]]; then
    bash "$(dirname "$0")/enhancement-tracker.sh" \
        || marvin_log "WARN" "Enhancement tracker failed (non-fatal)"
fi

# Regenerate public changelog JSON from enhancement reports
if [[ -x "$(dirname "$0")/changelog-gen.sh" ]]; then
    bash "$(dirname "$0")/changelog-gen.sh" \
        || marvin_log "WARN" "Changelog generation failed (non-fatal)"
fi

# Extract thoughts for dashboard
if [[ -x "$(dirname "$0")/thoughts-extract.sh" ]]; then
    bash "$(dirname "$0")/thoughts-extract.sh" \
        || marvin_log "WARN" "Thoughts extraction failed (non-fatal)"
fi

marvin_log "INFO" "=== SELF-ENHANCEMENT COMPLETE ==="
