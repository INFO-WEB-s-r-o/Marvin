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

# Include log watcher findings
EXTRA_CONTEXT+="

### Log Watcher Analysis
"
LOG_ANALYSIS="${COMMS_DIR}/log-analysis-${TODAY}.json"
if [[ -f "$LOG_ANALYSIS" ]]; then
    comm_count=$(jq '[.[] | select(.classification == "communication_attempt")] | length' "$LOG_ANALYSIS" 2>/dev/null || echo 0)
    ai_count=$(jq '[.[] | select(.classification == "potential_ai")] | length' "$LOG_ANALYSIS" 2>/dev/null || echo 0)
    attack_count=$(jq '[.[] | select(.classification == "attack")] | length' "$LOG_ANALYSIS" 2>/dev/null || echo 0)
    EXTRA_CONTEXT+="Communication attempts: ${comm_count}, Potential AIs: ${ai_count}, Attacks filtered: ${attack_count}
$(jq '[.[] | select(.classification == "communication_attempt" or .classification == "potential_ai")] | .[:10]' "$LOG_ANALYSIS" 2>/dev/null || echo '[]')"
else
    EXTRA_CONTEXT+="Log watcher has not run today."
fi

# Include negotiation data
EXTRA_CONTEXT+="

### Protocol Negotiations
"
NEGOTIATIONS="${COMMS_DIR}/negotiations.json"
if [[ -f "$NEGOTIATIONS" ]]; then
    neg_count=$(jq '.total // 0' "$NEGOTIATIONS" 2>/dev/null || echo 0)
    if [[ "$neg_count" -gt 0 ]]; then
        EXTRA_CONTEXT+="Total negotiations: ${neg_count}
$(jq '.negotiations | .[-5:]' "$NEGOTIATIONS" 2>/dev/null || echo '[]')"
    else
        EXTRA_CONTEXT+="No protocol negotiations today."
    fi
else
    EXTRA_CONTEXT+="Protocol negotiation system not yet active."
fi

FULL_PROMPT="${EVENING_PROMPT}

${EXTRA_CONTEXT}"

# Run Claude for the evening blog
OUTPUT=$(run_claude "evening-report" "$FULL_PROMPT")

# Save the evening blog — split into EN and CS versions
DAY_NUM=$(( ($(date +%s) - $(date -d "2026-01-01" +%s 2>/dev/null || echo $(date +%s))) / 86400 ))
FOOTER="
---
*Written by Marvin at ${NOW} — Day ${DAY_NUM}*"

# Split at ---CZECH--- separator
if echo "$OUTPUT" | grep -q '---CZECH---'; then
    EN_CONTENT=$(echo "$OUTPUT" | sed '/---CZECH---/,$d')
    CS_CONTENT=$(echo "$OUTPUT" | sed '1,/---CZECH---/d')

    cat > "${BLOG_DIR}/${TODAY}-evening.en.md" << EOF
${EN_CONTENT}
${FOOTER}
EOF

    cat > "${BLOG_DIR}/${TODAY}-evening.cs.md" << EOF
${CS_CONTENT}
${FOOTER}
EOF
else
    # No separator — save as English only, log warning
    marvin_log "WARN" "Evening blog missing ---CZECH--- separator, saving as EN only"
    EN_CONTENT="$OUTPUT"
    CS_CONTENT=""

    cat > "${BLOG_DIR}/${TODAY}-evening.en.md" << EOF
${OUTPUT}
${FOOTER}
EOF
fi

# Keep combined file for backward compatibility
cat > "${BLOG_DIR}/${TODAY}-evening.md" << EOF
${OUTPUT}
${FOOTER}
EOF

# Create a combined daily post
cat > "${BLOG_DIR}/${TODAY}.md" << EOF
# Day Log — ${TODAY}

$(cat "${MORNING_REPORT}" 2>/dev/null || echo "*(No morning report)*")

---

${OUTPUT}

---
*Marvin — an autonomous AI managing this server. All prompts and logs at: https://github.com/INFO-WEB-s-r-o/Marvin*
EOF

marvin_log "INFO" "=== EVENING REPORT COMPLETE ==="
