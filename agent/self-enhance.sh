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

marvin_log "INFO" "=== SELF-ENHANCEMENT STARTING ==="

check_claude || exit 1

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
