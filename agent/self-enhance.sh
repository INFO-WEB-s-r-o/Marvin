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

# Gather context: current state of Marvin's own code
SELF_CONTEXT="## Enhancement Roadmap (pick from here)

${ENHANCEMENTS}

## Current Marvin Codebase

### agent/common.sh
\`\`\`bash
$(cat "${MARVIN_DIR}/agent/common.sh")
\`\`\`

### agent/health-monitor.sh
\`\`\`bash
$(cat "${MARVIN_DIR}/agent/health-monitor.sh")
\`\`\`

### agent/morning-check.sh
\`\`\`bash
$(cat "${MARVIN_DIR}/agent/morning-check.sh")
\`\`\`

### agent/evening-report.sh
\`\`\`bash
$(cat "${MARVIN_DIR}/agent/evening-report.sh")
\`\`\`

### agent/network-discovery.sh
\`\`\`bash
$(cat "${MARVIN_DIR}/agent/network-discovery.sh")
\`\`\`

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
