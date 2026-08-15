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

        # Three defects, all measured on 2026-07-29 against the live repo:
        #
        # 1. GET /issues returns PULL REQUESTS as well as issues. 10 of the 20
        #    slots were PRs, so half the window was spent on things Task 2 is
        #    explicitly told not to triage. Filtered on `has("pull_request")`.
        #
        # 2. The raw payload was 156,304 characters against a 8,000-char cap
        #    below — 95% discarded, leaving ONE complete issue out of 30 open,
        #    and the survivor did not even parse because the cut landed
        #    mid-string. Almost all of that bulk is `*_url` fields nothing
        #    reads, plus the GPG signature block on every Marvin-authored body.
        #    Projecting to the fields Task 2 actually uses, dropping the
        #    signature blocks, and clipping bodies fits every open issue in a
        #    fraction of the budget. Breadth matters more than depth here: the
        #    task triages a queue, and a full body is one `gh` call away.
        #
        # 3. `curl -s` exits 0 on an HTTP error (#934), so `|| echo "[]"` was
        #    dead code and a 401/404 error body flowed on AS ISSUE DATA. The
        #    status code is now read explicitly, and a failed fetch is reported
        #    as a failure rather than as an empty queue.
        # 4. `per_page=100` with no pagination silently truncated. The cap counts
        #    issues AND pull requests together while the PR filter runs after it,
        #    so PRs burn slots that never become issues. Measured 2026-07-29: 48
        #    of 100 used (30 issues + 18 PRs) — already half the cap. The failure
        #    mode is the one this whole block exists to kill: a short queue that
        #    reads as complete, under a note that says "no issue is omitted".
        #    Now paged; if the page bound is ever reached, that is REPORTED
        #    rather than assumed away, and a mid-run page failure fails the whole
        #    fetch rather than shipping the pages that happened to arrive.
        # 5. Every call is time-bounded, matching `github_api()` in lib/github.sh
        #    (#835, #948). This is a cron-triggered run: `set -euo pipefail`
        #    bounds correctness, not wall-clock time, so an untimed curl against
        #    a stalled or half-open connection hangs the hourly check for as long
        #    as the kernel keeps the socket. With up to ISSUES_MAX_PAGES
        #    sequential calls before `run_claude` is even reached, that hang
        #    compounds. Bounded, a stall curl-times-out to 000, fails the fetch,
        #    and the next hourly run is a cheap retry — which is how the rest of
        #    this script is designed to fail. Worst case is therefore
        #    ISSUES_MAX_PAGES × 20s = 200s of fetch, deliberately finite.
        #
        # The prompt-size bound is now implicit rather than a hard character cut:
        # ISSUES_MAX_PAGES × ISSUES_PER_PAGE × ISSUE_BODY_CLIP, ~400 KB at the
        # extreme. That is intentional — the 8,000-char cut this block replaced
        # bounded the prompt by silently destroying the data, and a truncated
        # queue that reads as complete is the defect, not the size. If the
        # backlog ever grows enough for that ceiling to matter, lower
        # ISSUE_BODY_CLIP or ISSUES_MAX_PAGES: both are named, and reaching the
        # page bound is reported.
        ISSUES_PER_PAGE=100
        ISSUES_MAX_PAGES=10
        ISSUES_PAGES=""
        ISSUES_CODE=""
        ISSUES_FETCH_OK=1
        ISSUES_TRUNCATED=0
        _page=1
        while true; do
            _raw=$(curl -s -w '\n%{http_code}' \
                --connect-timeout 10 --max-time 20 \
                -H "Authorization: token ${GITHUB_TOKEN}" \
                -H "Accept: application/vnd.github.v3+json" \
                "https://api.github.com/repos/INFO-WEB-s-r-o/Marvin/issues?state=open&per_page=${ISSUES_PER_PAGE}&page=${_page}") \
                || _raw=""
            ISSUES_CODE=$(printf '%s' "$_raw" | tail -n 1)
            _body=$(printf '%s' "$_raw" | sed '$d')
            if [[ "$ISSUES_CODE" != "200" ]]; then ISSUES_FETCH_OK=0; break; fi
            # `length` on an error OBJECT returns its key count, which would pass
            # for a page size. Require an array before believing the count.
            _n=$(printf '%s' "$_body" | jq 'if type=="array" then length else empty end' 2>/dev/null) || _n=""
            if [[ -z "$_n" ]]; then ISSUES_FETCH_OK=0; break; fi
            ISSUES_PAGES="${ISSUES_PAGES}${_body}"$'\n'
            if (( _n < ISSUES_PER_PAGE )); then break; fi
            if (( _page >= ISSUES_MAX_PAGES )); then ISSUES_TRUNCATED=1; break; fi
            _page=$(( _page + 1 ))
        done

        ISSUES_BODY=""
        if (( ISSUES_FETCH_OK == 1 )); then
            ISSUES_BODY=$(printf '%s' "$ISSUES_PAGES" | jq -c -s 'add // []' 2>/dev/null) || ISSUES_BODY=""
        fi

        # Measured against the live queue (30 open issues, 2026-07-29): clipping
        # bodies at 300/400/600/900 chars yields 19.7k/22.8k/29.0k/38.2k. Every
        # one of the 30 bodies exceeds 400, so this single number sets the cost.
        # 400 buys the whole queue for ~23k chars — against 8k that previously
        # bought one unparseable issue. Raise it if triage starts needing more
        # context than the opening paragraph; the full body is one `gh` call away.
        ISSUE_BODY_CLIP=400

        # ─── Trust boundary: whose issue text may enter the model's context ───
        #
        # This repository is PUBLIC. Anyone on the internet can open an issue.
        # Until this filter existed, every open issue — any author — was clipped
        # to 400 chars and pasted into the context of a Claude session that holds
        # Edit, Write, Bash and the ability to open pull requests, running
        # unsupervised on a host that also serves other tenants.
        #
        # The author restriction was real, but it lived only in prompts/hourly.md
        # as "only act on issues where the author is listed in CODEOWNERS". That
        # is an instruction to the model, not a boundary around it: the untrusted
        # text still reached the context, and an instruction is exactly the thing
        # a prompt injection targets. 400 characters is ample for one.
        #
        # So the filter moved out of the prompt and into the fetch. Untrusted
        # issues are now dropped before the model sees them — the model cannot be
        # talked out of a `jq select` it never runs.
        #
        # Derived from CODEOWNERS rather than hardcoded here, because CODEOWNERS
        # already documents this exact list and warns that removing a name
        # "silently switches off Marvin's issue handling". Two sources would
        # drift, and the drift would be silent in the direction that matters.
        # The LOCAL checkout is read, not the API copy: this is a trust decision,
        # and it should not depend on a network fetch that can fail or be
        # answered by something other than the repository.
        #
        # Filtering on author_association instead would be wrong and was tried on
        # paper first: `github-actions[bot]` reports NONE, so association-based
        # filtering silently discards the review bot's issues — 13 of the 24 open
        # on 2026-08-06, and Marvin's single largest source of real work.
        #
        # Fails CLOSED. If the list cannot be derived, no issues are shown and the
        # run is told the boundary failed. An empty allowlist that reads as "no
        # issues today" is the failure this whole file keeps being rewritten to
        # prevent.
        TRUSTED_AUTHORS_JSON=""
        _co_local="${MARVIN_DIR}/CODEOWNERS"
        if [[ -r "$_co_local" ]]; then
            TRUSTED_AUTHORS_JSON=$(
                {
                    # Owners: @handle on any non-comment line.
                    grep -vE '^[[:space:]]*#' "$_co_local" \
                        | grep -oE '@[A-Za-z0-9][A-Za-z0-9-]*' | sed 's/^@//'
                    # Trusted issue authors: the documented comment block lists
                    # one login per line as `#   <login>   — description`.
                    grep -oE '^#[[:space:]]+[A-Za-z0-9][A-Za-z0-9._-]*(\[bot\])?[[:space:]]+—' "$_co_local" \
                        | sed -E 's/^#[[:space:]]+//; s/[[:space:]]+—$//'
                } | grep -vE '^$' | sort -u | jq -R . | jq -c -s .
            ) || TRUSTED_AUTHORS_JSON=""
        fi
        if [[ -z "$TRUSTED_AUTHORS_JSON" ]] \
            || ! printf '%s' "$TRUSTED_AUTHORS_JSON" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
            TRUSTED_AUTHORS_JSON=""
        fi

        ISSUES_JSON=""
        ISSUES_NOTE=""
        ISSUES_DROPPED=0
        if [[ -n "$ISSUES_BODY" && -n "$TRUSTED_AUTHORS_JSON" ]]; then
            # Counted before filtering so the drop is reported, not silent. An
            # untrusted issue is invisible to the model by design, but it must
            # not be invisible to the log.
            ISSUES_DROPPED=$(printf '%s' "$ISSUES_BODY" \
                | jq --argjson trusted "$TRUSTED_AUTHORS_JSON" \
                  '[ .[] | select(has("pull_request") | not)
                     | select(.user.login as $l | ($trusted | index($l)) | not) ] | length' 2>/dev/null) \
                || ISSUES_DROPPED=0
            ISSUES_JSON=$(printf '%s' "$ISSUES_BODY" | jq -c --argjson clip "$ISSUE_BODY_CLIP" --argjson trusted "$TRUSTED_AUTHORS_JSON" '
                [ .[]
                  | select(has("pull_request") | not)
                  # The trust boundary. Untrusted issue text never reaches the
                  # prompt, so it can never instruct the agent that reads it.
                  | select(.user.login as $l | $trusted | index($l))
                  # Bind the issue before descending into .body: inside the clip
                  # expression `.` is the body STRING, so a bare \(.number) there
                  # is "Cannot index string with string" — which this block would
                  # then report as a failed fetch.
                  | . as $iss
                  | { number, title,
                      author: .user.login,
                      author_association,
                      labels: [.labels[].name],
                      created_at, updated_at, comments,
                      body: ( (.body // "")
                              | split("*🔐 GPG-signed")[0]
                              | if length > $clip
                                then .[0:$clip] + "\n…[body clipped — read it in full with `gh issue view \($iss.number)`]"
                                else . end ) }
                ]' 2>/dev/null) || ISSUES_JSON=""
        fi

        # Comments are a separate, unfiltered surface (#1037). The trust
        # boundary above only ever covered the issue *author* and *body* —
        # hourly-check.sh never fetched comment text, so hourly.md Step 2
        # asked the model to check each comment's `user.login` itself, after
        # the text was already sitting in its context. That is the identical
        # in-context pattern #1033 replaced for bodies, for the same reason:
        # an instruction to disregard untrusted text is exactly what a prompt
        # injection is written to defeat. Filtered into `jq` here instead, one
        # `gh`-equivalent call per trusted issue that has any comments at all.
        if [[ -n "$ISSUES_JSON" && -n "$TRUSTED_AUTHORS_JSON" ]]; then
            while IFS= read -r _cnum; do
                [[ -n "$_cnum" ]] || continue
                _craw=$(curl -s -w '\n%{http_code}' \
                    --connect-timeout 10 --max-time 20 \
                    -H "Authorization: token ${GITHUB_TOKEN}" \
                    -H "Accept: application/vnd.github.v3+json" \
                    "https://api.github.com/repos/INFO-WEB-s-r-o/Marvin/issues/${_cnum}/comments?per_page=100") \
                    || _craw=""
                _ccode=$(printf '%s' "$_craw" | tail -n 1)
                _cbody=$(printf '%s' "$_craw" | sed '$d')
                if [[ "$_ccode" != "200" ]]; then
                    # A failed fetch must not silently read as "no comments" —
                    # flagged on the issue object so the prompt can say the
                    # comments are unknown rather than assume there are none.
                    ISSUES_JSON=$(printf '%s' "$ISSUES_JSON" | jq -c --argjson n "$_cnum" \
                        'map(if .number == $n then . + {comments_trusted_error: "fetch failed"} else . end)')
                    continue
                fi
                _cfiltered=$(printf '%s' "$_cbody" | jq -c --argjson trusted "$TRUSTED_AUTHORS_JSON" '
                    if type=="array" then
                        [ .[] | select(.user.login as $l | $trusted | index($l))
                          | {author: .user.login, body} ]
                    else [] end' 2>/dev/null) || _cfiltered="[]"
                ISSUES_JSON=$(printf '%s' "$ISSUES_JSON" | jq -c --argjson n "$_cnum" --argjson c "$_cfiltered" \
                    'map(if .number == $n then . + {comments_trusted: $c} else . end)')
            done < <(printf '%s' "$ISSUES_JSON" | jq -r '.[] | select(.comments > 0) | .number')
        fi

        if [[ -z "$TRUSTED_AUTHORS_JSON" ]]; then
            # Distinct from a failed fetch, and reported as its own verdict: the
            # queue may be perfectly readable while the trust list is not, and
            # collapsing the two would send someone to debug the wrong thing.
            ISSUES_JSON="[]"
            ISSUES_NOTE="**TRUST LIST UNAVAILABLE — NO ISSUES SHOWN.** ${MARVIN_DIR}/CODEOWNERS could not be read or yielded no trusted authors, so the author allowlist could not be built. This is NOT an empty queue: issues were deliberately withheld because there was no way to establish who wrote them. Do not act on issue reports this cycle; read them with \`gh issue list\` if needed."
            marvin_log "ERROR" "Trusted-author list could not be derived from ${MARVIN_DIR}/CODEOWNERS — issue feed withheld (failing closed)"
        elif [[ -z "$ISSUES_JSON" ]]; then
            # Never let a broken fetch read as a clean queue.
            ISSUES_JSON="[]"
            ISSUES_NOTE="**ISSUE FETCH FAILED (HTTP ${ISSUES_CODE:-none}) — this is NOT an empty queue.** Treat the list below as unknown, not as \"no open issues\"."
            marvin_log "WARN" "Open-issue fetch failed (HTTP ${ISSUES_CODE:-none}) — reported to the run as a failure, not as an empty queue"
        else
            ISSUES_COUNT=$(printf '%s' "$ISSUES_JSON" | jq 'length' 2>/dev/null || echo "?")
            ISSUES_PRS=$(printf '%s' "$ISSUES_BODY" | jq '[.[] | select(has("pull_request"))] | length' 2>/dev/null || echo "?")
            if (( ISSUES_TRUNCATED == 1 )); then
                # A cap that is reached must say so. "no issue is omitted" is the
                # one sentence this block must never print when it is untrue.
                ISSUES_NOTE="**QUEUE TRUNCATED — MORE OPEN ISSUES EXIST THAN ARE LISTED.** Stopped at the ${ISSUES_MAX_PAGES}-page bound (${ISSUES_PER_PAGE}/page). ${ISSUES_COUNT} issues shown (pull requests excluded: ${ISSUES_PRS}); the rest were not fetched. Do not read the list below as the whole queue."
                marvin_log "WARN" "Open-issue fetch hit the ${ISSUES_MAX_PAGES}-page bound — queue truncated at ${ISSUES_COUNT} issues, reported to the run as truncated"
            else
                # "no issue is omitted" was true until issues from untrusted
                # authors stopped being shown. It is now a claim this block can
                # only make about the trusted queue, and it says which.
                ISSUES_NOTE="${ISSUES_COUNT} open issues from trusted authors, all of them (pull requests excluded: ${ISSUES_PRS}; issues from authors not listed in CODEOWNERS, withheld before reaching this prompt: ${ISSUES_DROPPED}). Bodies over ${ISSUE_BODY_CLIP} chars are clipped and GPG signature blocks stripped; no TRUSTED issue is omitted. The withheld ones are not invisible — \`gh issue list\` shows the full queue. Comments are filtered the same way: each issue's \`comments_trusted\` array holds only comments from a trusted author; a \`comments_trusted_error\` field means the comment fetch failed and the comment list for that issue is unknown, not empty."
                marvin_log "INFO" "Fetched ${ISSUES_COUNT} open issues from trusted authors (${ISSUES_PRS} PRs filtered out, ${ISSUES_DROPPED} untrusted-author issues withheld from the prompt); comment authors filtered per-issue via jq"
            fi
        fi

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
        # NOTE: bash EXIT traps do not stack — a second `trap ... EXIT` anywhere
        # later in this script REPLACES this one, and the temp file would then
        # leak silently rather than failing loudly. This is currently the only
        # EXIT trap here (line 11's is ERR, a different signal, so it does not
        # collide). If you add another, fold this `rm -f` into it.
        trap 'rm -f "${CODEOWNERS_BODY}"' EXIT
        # Time-bounded, matching `github_api()` in lib/github.sh (#835, #948).
        # This runs from cron: `set -euo pipefail` bounds correctness, not
        # wall-clock time, so an untimed curl against a stalled or half-open
        # connection hangs the hourly check for as long as the kernel keeps the
        # socket — before `run_claude` is reached, so the run produces nothing
        # at all. Bounded, a stall curl-times-out and lands in the `*)` arm
        # below as `HTTP 000`, which already says "this is NOT the same as the
        # file being absent". The next hourly run is then a cheap retry.
        CODEOWNERS_HTTP=$(curl -s -o "${CODEOWNERS_BODY}" -w '%{http_code}' \
            --connect-timeout 10 --max-time 20 \
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
        # Intentional, not redundant with the EXIT trap above: the trap is the
        # backstop for the abnormal paths, this is best-effort early cleanup so
        # the temp file does not outlive its last read through the long tail of
        # this script. Removing either one is safe; removing both is not.
        rm -f "${CODEOWNERS_BODY}"

        GITHUB_ISSUES="### CODEOWNERS file
\`\`\`
${CODEOWNERS_CONTENT}
\`\`\`

### Open Issues (JSON)
${ISSUES_NOTE}
\`\`\`json
${ISSUES_JSON}
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

# Match only this task's own reports (${TODAY}-hourly-<epoch>.md). The bare
# `-hourly-*` glob also matched ${TODAY}-hourly-check-<epoch>.md — the full run
# transcript the runner writes beside each report — and the two sort adjacently,
# so two of these three slots went to the SAME run and the anti-duplication
# window was 2 runs, not 3.
#
# nullglob rather than `ls ... || echo "None yet today."`: that fallback
# collapsed "the scan broke" into "no reports exist", and a run told there is no
# history repeats the previous hour's work. An empty array here means the
# directory is genuinely empty; anything else fails loudly under errexit.
#
# The suffix is matched as EXACTLY ten digits, not `[0-9]*`. The sort below is
# lexical, and that is only newest-first while every name is the same width —
# and this directory still holds the older ${TODAY}-hourly-<HHMM>.md form (19
# files across 2026-07-26 and -27, before the switch to epoch). A loose match
# lets a four-digit name outrank a ten-digit one whenever it wins character by
# character: `1835` beats `1785332101` at the second character, putting an
# eighteen-hour-old report at the top of a "three most recent" window. The real
# 07-27 mix escapes that only because the switch landed at 17:35, and `1735`
# loses. That is luck, not an invariant, so the width is enforced by the
# selector rather than asserted in a comment.
shopt -s nullglob
RECENT_FILES=( "${LOGS_DIR}/${TODAY}"-hourly-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].md )
shopt -u nullglob

if (( ${#RECENT_FILES[@]} == 0 )); then
    RECENT_REPORTS="None yet today."
else
    # every name is now a ten-digit epoch, so a reverse lexical sort is newest-first
    mapfile -t RECENT_FILES < <(printf '%s\n' "${RECENT_FILES[@]}" | sort -r)
    RECENT_REPORTS=""
    # The read is guarded, and this guard is NOT the fallback removed above. That
    # one collapsed a broken scan into "no reports exist" — a silent, plausible
    # lie the next run acts on. This one swallows only the exit status: the
    # failure is written into the block that ships, so a run whose slot could not
    # be read is told so, instead of quietly seeing one report fewer.
    #
    # Unguarded, one unreadable file is fatal. Under `set -euo pipefail` the
    # assignment takes the command substitution's status, and marvin_error_trap
    # only logs — it does not suppress the exit. A file rotated away between the
    # glob and the read would kill not just this block but the log snapshot, the
    # Claude invocation and the report save for the entire cycle.
    for _report in "${RECENT_FILES[@]:0:3}"; do
        RECENT_REPORTS+="--- ${_report} ---"$'\n'
        RECENT_REPORTS+="$(tail -20 "${_report}" 2>/dev/null \
            || echo "!! UNREADABLE — this slot's content is missing, not empty")"$'\n'
    done
fi

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
