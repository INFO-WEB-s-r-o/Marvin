#!/usr/bin/env bash
# =============================================================================
# Marvin — Hourly Watch (runs every hour)
# =============================================================================
# Checks /var/log for actionable errors and GitHub issues from codeowners.
# Attempts to resolve what it can; flags the rest for the human.
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

marvin_log "INFO" "=== HOURLY CHECK STARTING ==="

# ─────────────────────────────────────────────────────────────────────────────
# Collect recent log entries (last 65 minutes to avoid gaps between runs)
# Focus on error-level entries — not the full log firehose
# ─────────────────────────────────────────────────────────────────────────────

LOG_SNAPSHOT=""

# systemd journal errors
LOG_SNAPSHOT+="### journalctl (errors, last 65 min)
\`\`\`
$(journalctl --since "65 minutes ago" --no-pager -p err 2>/dev/null | tail -100 || echo "unavailable")
\`\`\`

"

# nginx error log
if [[ -f /var/log/nginx/error.log ]]; then
    LOG_SNAPSHOT+="### nginx error.log (last 65 min)
\`\`\`
$(find /var/log/nginx -name "error.log" -exec awk -v d="$(date -u -d '65 minutes ago' '+%Y/%m/%d %H:%M:%S' 2>/dev/null || date -u -v-65M '+%Y/%m/%d %H:%M:%S')" '$0 >= d' {} \; 2>/dev/null | tail -50 || tail -50 /var/log/nginx/error.log 2>/dev/null || echo "unavailable")
\`\`\`

"
fi

# syslog / kern.log errors
for logfile in /var/log/syslog /var/log/kern.log; do
    if [[ -f "$logfile" ]]; then
        LOG_SNAPSHOT+="### $(basename $logfile) (last 65 min, errors only)
\`\`\`
$(journalctl --since "65 minutes ago" --no-pager -p err -t kernel 2>/dev/null | tail -30 \
    || grep -i "error\|crit\|emerg\|alert" "$logfile" 2>/dev/null | tail -30 \
    || echo "unavailable")
\`\`\`

"
        break  # only need one of syslog/kern.log
    fi
done

# Failed systemd units
LOG_SNAPSHOT+="### Failed systemd units
\`\`\`
$(systemctl --failed --no-pager 2>/dev/null | head -30 || echo "unavailable")
\`\`\`

"

# Mail log (postfix/dovecot errors)
if [[ -f /var/log/mail.log ]] || [[ -f /var/log/mail.err ]]; then
    LOG_SNAPSHOT+="### mail errors (last 65 min)
\`\`\`
$(journalctl --since "65 minutes ago" --no-pager -p err -u postfix -u dovecot 2>/dev/null | tail -30 \
    || grep -i "error\|fatal\|panic" /var/log/mail.err 2>/dev/null | tail -30 \
    || echo "unavailable")
\`\`\`

"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Collect open GitHub issues
# ─────────────────────────────────────────────────────────────────────────────

GITHUB_ISSUES=""

if [[ -f "$(dirname "$0")/lib/github.sh" ]]; then
    source "$(dirname "$0")/lib/github.sh"

    if github_check_token 2>/dev/null; then
        marvin_log "INFO" "Fetching open GitHub issues..."

        ISSUES_JSON=$(curl -s \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/INFO-WEB-s-r-o/Marvin/issues?state=open&per_page=20" \
            2>/dev/null || echo "[]")

        # Fetch CODEOWNERS
        CODEOWNERS_CONTENT=$(curl -s \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github.v3.raw" \
            "https://api.github.com/repos/INFO-WEB-s-r-o/Marvin/contents/.github/CODEOWNERS" \
            2>/dev/null || echo "* PavelStancik")

        GITHUB_ISSUES="### CODEOWNERS file
\`\`\`
${CODEOWNERS_CONTENT}
\`\`\`

### Open Issues (JSON)
\`\`\`json
$(echo "${ISSUES_JSON}" | head -c 8000)
\`\`\`"
    else
        GITHUB_ISSUES="GitHub token not available — skipping issue check."
        marvin_log "WARN" "No GitHub token, skipping issue fetch"
    fi
else
    GITHUB_ISSUES="GitHub library not available."
    marvin_log "WARN" "github.sh not found, skipping issue fetch"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Recent hourly reports (so Claude can avoid repeating work)
# ─────────────────────────────────────────────────────────────────────────────

RECENT_REPORTS=$(ls -t "${LOGS_DIR}"/${TODAY}-hourly-*.md 2>/dev/null | head -3 | \
    xargs -I{} sh -c 'echo "--- {} ---"; tail -20 "{}"' 2>/dev/null || echo "None yet today.")

# ─────────────────────────────────────────────────────────────────────────────
# Build and run the prompt
# ─────────────────────────────────────────────────────────────────────────────

check_claude || exit 1

HOURLY_PROMPT=$(cat "${PROMPTS_DIR}/hourly.md" 2>/dev/null)

CONTEXT="## Log Snapshot (last 65 minutes)

${LOG_SNAPSHOT}

## GitHub Issues

${GITHUB_ISSUES}

## Recent Hourly Reports (avoid duplicating work)

${RECENT_REPORTS}"

FULL_PROMPT="${HOURLY_PROMPT}

${CONTEXT}"

OUTPUT=$(run_claude "hourly-check" "$FULL_PROMPT")

# ─────────────────────────────────────────────────────────────────────────────
# Save the report
# ─────────────────────────────────────────────────────────────────────────────

REPORT_FILE="${LOGS_DIR}/${TODAY}-hourly-${TIMESTAMP}.md"
cat > "${REPORT_FILE}" << EOF
# Hourly Check — ${NOW}

${OUTPUT}

---
*Generated by Marvin hourly-check.sh at ${NOW}*
EOF

marvin_log "INFO" "Hourly report saved: ${REPORT_FILE}"
marvin_log "INFO" "=== HOURLY CHECK COMPLETE ==="
