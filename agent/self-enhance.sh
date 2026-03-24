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
trap marvin_error_trap ERR

marvin_log "INFO" "=== SELF-ENHANCEMENT STARTING ==="

check_claude || exit 1

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

    # 1. Bash syntax + conflict marker check for ALL .sh files in the repo
    #    (not just agent/ — catches setup/, root scripts, new files)
    while IFS= read -r script; do
        if ! bash -n "$script" 2>/dev/null; then
            marvin_log "ERROR" "Post-enhance validation FAILED: syntax error in ${script#${MARVIN_DIR}/}"
            valid=false
        fi
        if grep -qE '^<{7} |^={7}$|^>{7} ' "$script" 2>/dev/null; then
            marvin_log "ERROR" "Post-enhance validation FAILED: conflict markers in ${script#${MARVIN_DIR}/}"
            valid=false
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

# Read the enhancement prompt
ENHANCE_PROMPT=$(cat "${PROMPTS_DIR}/enhance.md")

# Read the enhancement roadmap
ENHANCEMENTS=""
if [[ -f "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" ]]; then
    ENHANCEMENTS=$(cat "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md")
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

# Include key infrastructure scripts that are always relevant (common.sh, lib/)
for script in "${MARVIN_DIR}/agent/common.sh" "${MARVIN_DIR}/agent/lib/github.sh"; do
    if [[ -f "$script" ]]; then
        script_name="${script#${MARVIN_DIR}/}"
        SCRIPTS_CONTEXT+="### ${script_name}
\`\`\`bash
$(cat "$script")
\`\`\`

"
    fi
done

# Include scripts that had errors today
error_scripts=$(grep -oP '(?<=agent/)[a-z-]+\.sh' "${LOGS_DIR}/${TODAY}.log" 2>/dev/null | sort -u || echo "")
for script_base in $error_scripts; do
    script="${MARVIN_DIR}/agent/${script_base}"
    if [[ -f "$script" ]]; then
        script_name="${script#${MARVIN_DIR}/}"
        # Skip if already included
        if ! echo "$SCRIPTS_CONTEXT" | grep -q "### ${script_name}"; then
            SCRIPTS_CONTEXT+="### ${script_name} (had errors today)
\`\`\`bash
$(cat "$script")
\`\`\`

"
        fi
    fi
done

# Claude can read additional scripts as needed using its Read tool

SELF_CONTEXT="## Enhancement Roadmap (pick from here)

${ENHANCEMENTS}

## Current Marvin Codebase

${SCRIPTS_CONTEXT}

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
"

FULL_PROMPT="${ENHANCE_PROMPT}

${SELF_CONTEXT}"

# Run Claude for self-enhancement
OUTPUT=$(run_claude "self-enhance" "$FULL_PROMPT")

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
marvin_log "INFO" "=== SELF-ENHANCEMENT COMPLETE ==="
