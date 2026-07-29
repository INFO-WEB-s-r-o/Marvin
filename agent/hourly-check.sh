#!/usr/bin/env bash
# =============================================================================
# Marvin — Hourly Watch (runs every hour)
# =============================================================================
# Checks /var/log for actionable errors and GitHub issues from codeowners.
# Attempts to resolve what it can; flags the rest for the human.
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

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
# NOTE: nginx writes error.log timestamps in LOCAL time, so the cutoff must be
# built in local time too. Using `date -u` here made the cutoff lag the real one
# by the UTC offset, widening the window to 65+offset minutes (185 under CEST,
# 125 under CET) and re-serving hours-old entries as "last 65 min" every run.
# "local" here means the SYSTEM zone (/etc/localtime), which is the zone nginx
# logs in — nginx's unit sets no Environment, so it cannot be told otherwise.
# `env -u TZ` pins the cutoff to that same zone: a TZ inherited from cron or a
# service environment would reintroduce the identical skew, silently and with
# nothing to catch it, since over-collecting never looks like a failure.
#
# The window is read from the rotated log as well as the live one (#860).
# logrotate runs `daily` at 00:00 local, so the 00:35 run's 65-minute window
# opens at 23:30 the previous day — a span that by then lives entirely in
# error.log.1. `find /var/log/nginx -name "error.log"` matched only the live
# file, so those 30 minutes were dropped every single night, and dropped
# invisibly: an empty window and a window nobody read produce the same report.
#
# Only `.1` is read, on purpose. `delaycompress` leaves exactly one rotation
# uncompressed, and a 65-minute window cannot reach past it — .2.gz is always
# more than a day old. Reading further back would cost a zcat per run to
# re-examine entries every window has already excluded.
#
# Timestamps sort lexically in `%Y/%m/%d %H:%M:%S`, so the same string cutoff
# filters both files correctly; .1 is read first so the output stays in
# chronological order.
_nginx_error_window() {
    local cutoff="$1" f lines all="" failed=""
    for f in /var/log/nginx/error.log.1 /var/log/nginx/error.log; do
        [[ -f "$f" ]] || continue
        # Per-file status, deliberately not shared (#866). A single `ok` flag
        # that each iteration overwrites lets a readable error.log erase the
        # fact that error.log.1 could not be opened — the run then prints a
        # confident, short window and nothing says half of it is missing.
        # awk exits 0 on "no matching lines", so a non-zero status here really
        # is a read failure and not an empty result.
        if lines=$(awk -v d="$cutoff" '$0 >= d' "$f" 2>/dev/null); then
            if [[ -n "$lines" ]]; then
                all+="${lines}"$'\n'
            fi
        else
            failed="${failed}${failed:+, }${f}"
        fi
    done

    if [[ -n "$all" ]]; then
        printf '%s' "$all" | tail -50
    fi
    # An unreadable log is reported as unread, never folded into the quiet
    # case. `x=$(scan) || true` collapsing "could not look" into "found
    # nothing" is the exact bug this section keeps being rewritten to avoid.
    if [[ -n "$failed" ]]; then
        printf '!! UNREAD: %s — this window is INCOMPLETE, not clean\n' "$failed"
    elif [[ -z "$all" ]]; then
        printf -- '-- No entries --\n'
    fi
    return 0
}

if [[ -f /var/log/nginx/error.log || -f /var/log/nginx/error.log.1 ]]; then
    # Computed once, outside the substitution below, so that a `date` failure
    # is visible as an empty cutoff rather than silently becoming an awk
    # pattern that matches every line ever logged.
    _nginx_cutoff=$(env -u TZ date -d '65 minutes ago' '+%Y/%m/%d %H:%M:%S' 2>/dev/null \
        || env -u TZ date -v-65M '+%Y/%m/%d %H:%M:%S' 2>/dev/null \
        || echo "")
    if [[ -z "$_nginx_cutoff" ]]; then
        LOG_SNAPSHOT+="### nginx error.log (last 65 min)
\`\`\`
!! could not compute the 65-minute cutoff — window NOT read
\`\`\`

"
    else
        LOG_SNAPSHOT+="### nginx error.log (last 65 min)
\`\`\`
$(_nginx_error_window "$_nginx_cutoff")
\`\`\`

"
    fi
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

        # Fetch CODEOWNERS. The file is at the repo ROOT — there is no
        # .github/CODEOWNERS and there never has been (#934), so this asked
        # the contents API for a path that 404s on every single run.
        #
        # The old `|| echo "* PavelStancik"` fallback never fired and could
        # not have: `curl -s` without `-f` exits 0 on an HTTP 404, because
        # the transfer succeeded. What actually reached the prompt was the
        # API's 404 JSON body, pasted under the heading "CODEOWNERS file" —
        # which the agent then reasonably read as "the file is absent" and
        # applied the PavelStancik-only rule to, skipping the review-bot
        # issues that are its largest source of work (this cost ~3h and one
        # money-burning issue on 2026-06-05).
        #
        # An HTTP error must be reported AS a failure rather than collapsing
        # into "the file does not exist" — but the two cases are not the same
        # message, and a bare `curl -sf` cannot tell them apart: 404 and a
        # DNS failure both exit non-zero and produce one indistinguishable
        # string. The prompt has always had a "genuinely absent" branch; with
        # a single failure message that branch describes a state this script
        # cannot emit, which is the same dead-instruction shape #934 was.
        # So capture the status code and name all three states.
        CODEOWNERS_BODY=$(mktemp)
        trap 'rm -f "${CODEOWNERS_BODY}"' EXIT
        CODEOWNERS_HTTP=$(curl -s -o "${CODEOWNERS_BODY}" -w '%{http_code}' \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github.v3.raw" \
            "https://api.github.com/repos/INFO-WEB-s-r-o/Marvin/contents/CODEOWNERS" \
            2>/dev/null) || CODEOWNERS_HTTP="000"

        case "${CODEOWNERS_HTTP}" in
            200)
                CODEOWNERS_CONTENT=$(cat "${CODEOWNERS_BODY}")
                # A 200 whose body is empty (or only whitespace) is the one
                # cell this state machine did not name. It reaches the prompt
                # as a blank fenced block — byte-identical to what a genuinely
                # absent file produces — so it lands on the sole-codeowner
                # rule and silently drops every bot-authored issue. That is
                # #934's collapse arriving through the SUCCESS branch, which
                # is why a status code alone is not enough: assert on the
                # value that actually ships, not on a proxy for it.
                #
                # Tested on the file content rather than `[[ -s ]]` on the
                # body: `$(cat)` strips trailing newlines, so a whitespace-
                # only body is non-empty on disk and empty in the variable.
                #
                # Deliberately keeps the `FETCH FAILED` prefix that
                # hourly.md keys off, so this needs no matching prompt edit.
                if [[ -z "${CODEOWNERS_CONTENT//[[:space:]]/}" ]]; then
                    CODEOWNERS_CONTENT="FETCH FAILED — HTTP 200, but the CODEOWNERS body was empty.
An empty body is NOT an absent file. Do not fall back to a sole-codeowner
assumption on the strength of this message; read ${MARVIN_DIR}/CODEOWNERS
from the local checkout instead."
                fi
                ;;
            404)
                CODEOWNERS_CONTENT="ABSENT — the repository has no CODEOWNERS file at its root (HTTP 404).
This is the one case in which the sole-codeowner rule applies: treat
PavelStancik as the only codeowner."
                ;;
            *)
                CODEOWNERS_CONTENT="FETCH FAILED — could not read CODEOWNERS (HTTP ${CODEOWNERS_HTTP}).
This is NOT the same as the file being absent. Do not fall back to a
sole-codeowner assumption on the strength of this message; read
${MARVIN_DIR}/CODEOWNERS from the local checkout instead."
                ;;
        esac
        rm -f "${CODEOWNERS_BODY}"

        GITHUB_ISSUES="### CODEOWNERS file
\`\`\`
${CODEOWNERS_CONTENT}
\`\`\`

### Open Issues (JSON)
\`\`\`json
${ISSUES_JSON:0:8000}
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

# hourly-check runs hourly (cron :35) — a missed cycle is cheap, the next run
# picks up the same work. Cap lock-wait at 60s so an overlapping Claude task
# (e.g. log-watcher at :30) doesn't burn 5 min before skipping.
#
# Capture the exit code instead of a bare `OUTPUT=$(run_claude ...)`: under
# `set -euo pipefail` + the ERR trap, a transient Claude failure (exit 1) or a
# lock timeout (exit 2) would otherwise fire the trap, log a spurious
# `hourly-check.sh — command failed (exit 1)` ERROR, and kill the script before
# the report is ever saved. Both are expected, non-critical conditions for a
# high-frequency task — the next hourly run is a cheap retry. See lessons
# claude-exit-code-1-transient and claude-lock-timeout-expected-on-cron-overlap.
export CLAUDE_LOCK_TIMEOUT=60
OUTPUT=$(run_claude "hourly-check" "$FULL_PROMPT") && CLAUDE_RC=0 || CLAUDE_RC=$?

if [[ "$CLAUDE_RC" -eq 2 ]]; then
    marvin_log "INFO" "Hourly check skipped — Claude lock held by another task; next hourly run will catch up"
    exit 0
fi

if [[ "$CLAUDE_RC" -ne 0 ]]; then
    marvin_log "WARN" "hourly-check Claude exit ${CLAUDE_RC} — skipping this cycle (next hourly run is a cheap retry)"
    exit 0
fi

if [[ -z "$OUTPUT" ]]; then
    marvin_log "WARN" "hourly-check produced empty output — skipping report this cycle"
    exit 0
fi

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
