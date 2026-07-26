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
# The window must also span the ROTATED file. logrotate for nginx is daily at
# 00:00 and this script runs at :35, so the 00:35 run looks back to 23:30 —
# a half-hour that logrotate has already moved into error.log.1. Matching only
# "error.log" lost that slice every single night. Read error.log.1 first so the
# output stays chronological (the rotated file is strictly older), which also
# means `tail -50` truncates the oldest entries rather than the newest.
# Uncompressed only: error.log.2.gz and older are always outside a 65-minute
# window, so decompressing them would be pure cost. Widening the file set
# cannot over-report — the awk cutoff below still discards anything older.
#
# The guard accepts EITHER file. Guarding on error.log alone would skip the
# whole section — rotated file included — in the window where logrotate has
# moved error.log aside but nginx has not yet reopened it. That window is
# short, but it sits at exactly the boundary this section already gets wrong,
# and gating the rotated read on the live file's existence would reintroduce
# the same "the entry was there, we just didn't look" failure in miniature.
#
# Wrapped in a function taking the log directory as $1 (default
# /var/log/nginx) for one reason: so self-test §9g can drive it against a
# fixture tree. The reviewer of #862 asked for a committed regression test on
# the grounds that this single statement has now regressed three times — #848
# (the window was 185 minutes wide, not 65), #866 (a failed rotated read
# swallowed by the loop's exit status), and the fallback splice found
# mid-review of #862 itself — and every one of those was caught by an ad-hoc
# check that was run once, by hand, and never committed. That is a fair
# reading of the history. Behaviour below is unchanged; only the paths come
# from a variable now, and the result is printed rather than assigned.
_nginx_error_window() {
    local _nginx_dir="${1:-/var/log/nginx}"
    local _nginx_cutoff="" _nginx_read_ok=true _nginx_raw="" _nginx_log="" _nginx_part="" _nginx_recent=""

    # The trailing `|| _nginx_cutoff=""` is not redundant with the GNU/BSD
    # fallback above it. Hoisting this out of the `find -exec awk` argument
    # position and into a top-level assignment changed its failure mode: as an
    # argument, a total date failure could not trip `set -e` (command
    # substitutions used as arguments do not propagate their status), so the
    # cutoff simply came out empty and the comparison degraded to "match
    # everything". As a standalone simple command it *is* a failing command
    # under `set -euo pipefail` + the ERR trap, and would abort the entire
    # hourly run. Losing the age filter costs us an over-wide snapshot that
    # `tail -50` already bounds; losing the run costs us the whole check.
    _nginx_cutoff="$(env -u TZ date -d '65 minutes ago' '+%Y/%m/%d %H:%M:%S' 2>/dev/null || env -u TZ date -v-65M '+%Y/%m/%d %H:%M:%S')" || _nginx_cutoff=""

    # Capture, THEN emit — the read must not be spliced inline with a trailing
    # `|| fallback`. This pipeline can fail *late*: the loop writes file 1 to
    # the pipe and only then dies (unreadable error.log, awk gone), so `tail`
    # has already emitted when pipefail reports the failure. Inline, the
    # fallback's output would be appended to that partial read rather than
    # replace it — the double-JSON-document class from #841/#844/#846, wearing
    # a different hat. Verified: the old line emitted the filtered window AND
    # the whole unfiltered tail, with entries duplicated across the seam.
    #
    # An empty result is a SUCCESS, not a failure — a quiet hour has no errors
    # in the window. Only a non-zero status may reach the fallback; testing
    # for emptiness instead would fire the unfiltered fallback on every
    # healthy run and flood the snapshot with hours-old entries, which is
    # precisely the over-wide window #848 closed.
    # Read each file SEPARATELY and track failure per file. The compact
    # spelling — one `for` loop piped into `tail` — cannot report a failed read
    # of error.log.1: a `for` compound's exit status is the status of the last
    # command in its LAST iteration, so a broken rotated read is overwritten by
    # a healthy live one and pipefail never sees a non-zero (#866). Demonstrated
    # with an awk stub failing only on error.log.1: the old spelling returned 0
    # and captured the live line alone, silently dropping the rotated window.
    # That is this section's own failure — "the entry was there, we just didn't
    # look" — reappearing inside the code added to fix it, and only for the one
    # file it was added to read.
    #
    # `if` rather than `[[ ... ]] && _nginx_raw+=...` on the append: an AND-list
    # whose test fails leaves the loop with a non-zero status on a quiet hour,
    # which under `set -e` + the ERR trap is a lost run. An `if` with a false
    # condition returns 0.
    _nginx_read_ok=true
    _nginx_raw=""
    for _nginx_log in "${_nginx_dir}/error.log.1" "${_nginx_dir}/error.log"; do
        [[ -f "$_nginx_log" ]] || continue
        _nginx_part=""
        _nginx_part="$(awk -v d="$_nginx_cutoff" '$0 >= d' "$_nginx_log" 2>/dev/null)" || _nginx_read_ok=false
        if [[ -n "$_nginx_part" ]]; then
            _nginx_raw+="${_nginx_part}"$'\n'
        fi
    done

    # `tail` bounds the two files together, not each one: the 50-line cap is on
    # the window as a whole, and the newest entries are in error.log, read last.
    if [[ "$_nginx_read_ok" == true ]]; then
        _nginx_recent="$(printf '%s' "$_nginx_raw" | tail -50)"
    else
        # Last resort: the age filter itself is broken, so the 65-minute claim
        # in the heading cannot be honoured. Read BOTH files here too — a
        # fallback that reads only the live file silently reintroduces the
        # rotated-window gap this whole section exists to close — and label
        # the output, because an unfiltered tail under a "last 65 min" heading
        # invites the next hourly run to re-diagnose this morning's entries as
        # if they had just happened. `|| true` keeps a missing error.log.1
        # from failing the pipe under pipefail.
        #
        # The `else` below is deliberately near-unreachable (#862 review): the
        # `|| true` pins the left side of the pipe to 0 and `tail` on its output
        # all but cannot fail. It stays anyway, and the `if` in particular
        # stays, because the alternative — a bare
        # `_nginx_recent="$(…)"` — is a simple command whose failure DOES trip
        # `set -e` and the ERR trap, which aborts the entire hourly run. That is
        # the exact regression fixed in `d82ce5f` on this same branch, one
        # assignment up. Trading an unreachable branch for a lost run is a bad
        # trade even at low probability: the branch costs a reader ten seconds,
        # the abort costs an hour of monitoring.
        if _nginx_recent="$({ cat "${_nginx_dir}/error.log.1" "${_nginx_dir}/error.log" 2>/dev/null || true; } | tail -50)"; then
            _nginx_recent="[age filter unavailable — last 50 lines, UNFILTERED, window above does not hold]
${_nginx_recent}"
        else
            _nginx_recent="unavailable"
        fi
    fi
    printf '%s' "$_nginx_recent"
}

# `|| _nginx_recent="unavailable"` because a function called in a command
# substitution is still a simple command: were it ever to return non-zero, the
# ERR trap would abort the hourly run — the same trade refused twice inside the
# function above, and it would be odd to reintroduce it at the call site.
if [[ -f /var/log/nginx/error.log || -f /var/log/nginx/error.log.1 ]]; then
    _nginx_recent="$(_nginx_error_window /var/log/nginx)" || _nginx_recent="unavailable"
    LOG_SNAPSHOT+="### nginx error.log (last 65 min)
\`\`\`
${_nginx_recent}
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
