#!/usr/bin/env bash
# =============================================================================
# Marvin — Evening Report (runs daily at 22:00 UTC)
# =============================================================================
# Generates a blog post about the day:
#   - What happened (metrics, incidents, fixes)
#   - Philosophical reflection (Marvin's personality)
#   - Actions taken
#   - Tomorrow's outlook
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

marvin_log "INFO" "=== EVENING REPORT STARTING ==="

check_claude || exit 1

# Read the evening prompt
EVENING_PROMPT=$(cat "${PROMPTS_DIR}/evening.md")

# Gather the day's data
DAY_METRICS="${METRICS_DIR}/${TODAY}.jsonl"
DAY_LOG="${LOGS_DIR}/${TODAY}.log"
MORNING_REPORT="${BLOG_DIR}/${TODAY}-morning.md"

EXTRA_CONTEXT="## Today's Data

### Metrics History (today)
\`\`\`jsonl"

if [[ -f "$DAY_METRICS" ]]; then
    # Get first and last metrics of the day
    EXTRA_CONTEXT+="
--- First reading ---
$(head -1 "$DAY_METRICS")
--- Latest reading ---
$(tail -1 "$DAY_METRICS")
--- Total readings today: $(wc -l < "$DAY_METRICS") ---"
else
    EXTRA_CONTEXT+="
No metrics collected today."
fi

EXTRA_CONTEXT+="\`\`\`

### Today's Log
\`\`\`"
if [[ -f "$DAY_LOG" ]]; then
    EXTRA_CONTEXT+="$(tail -100 "$DAY_LOG")"
else
    EXTRA_CONTEXT+="No log entries today."
fi
EXTRA_CONTEXT+="\`\`\`

### Morning Report
"
if [[ -f "$MORNING_REPORT" ]]; then
    EXTRA_CONTEXT+="$(cat "$MORNING_REPORT")"
else
    EXTRA_CONTEXT+="No morning report was generated today."
fi

EXTRA_CONTEXT+="

### Enhancement Attempts Today
"
ENHANCE_FILES=$(find "${ENHANCE_DIR}" -name "${TODAY}*" -type f 2>/dev/null)
if [[ -n "$ENHANCE_FILES" ]]; then
    for f in $ENHANCE_FILES; do
        EXTRA_CONTEXT+="$(cat "$f")
"
    done
else
    EXTRA_CONTEXT+="No self-enhancement attempts today."
fi

EXTRA_CONTEXT+="

### Communication Attempts Today
"
COMM_LOG="${COMMS_DIR}/${TODAY}.log"
if [[ -f "$COMM_LOG" ]]; then
    EXTRA_CONTEXT+="$(cat "$COMM_LOG")"
else
    EXTRA_CONTEXT+="No communication attempts today."
fi

FULL_PROMPT="${EVENING_PROMPT}

${EXTRA_CONTEXT}"

# Run Claude for the evening blog
OUTPUT=$(run_claude "evening-report" "$FULL_PROMPT")

# Save the evening blog
cat > "${BLOG_DIR}/${TODAY}-evening.md" << EOF
${OUTPUT}

---
*Written by Marvin at ${NOW} — Day $(( ($(date +%s) - $(date -d "2026-01-01" +%s 2>/dev/null || echo $(date +%s))) / 86400 ))*
EOF

# Create a combined daily post
cat > "${BLOG_DIR}/${TODAY}.md" << EOF
# Day Log — ${TODAY}

$(cat "${MORNING_REPORT}" 2>/dev/null || echo "*(No morning report)*")

---

${OUTPUT}

---
*Marvin — an autonomous AI managing this server. All prompts and logs at: github.com/YOUR_USERNAME/marvin-experiment*
EOF

marvin_log "INFO" "=== EVENING REPORT COMPLETE ==="
