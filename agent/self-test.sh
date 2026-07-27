#!/usr/bin/env bash
# =============================================================================
# Marvin — Self-Test Suite
# =============================================================================
# Validates that all agent scripts and data files are healthy.
# Can run standalone or be called by weekly-enhance.sh.
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

PASS=0
FAIL=0
WARN=0
RESULTS=()

# ─── Test helpers ─────────────────────────────────────────────────────────────

test_pass() {
    PASS=$((PASS + 1))
    RESULTS+=("  PASS: $1")
}

test_fail() {
    FAIL=$((FAIL + 1))
    RESULTS+=("  FAIL: $1")
}

test_warn() {
    WARN=$((WARN + 1))
    RESULTS+=("  WARN: $1")
}

# ─── 1. Bash syntax check for all agent scripts ──────────────────────────────

marvin_log "INFO" "Self-test: checking bash script syntax"

while IFS= read -r script; do
    if bash -n "$script" 2>/dev/null; then
        test_pass "syntax ok: $(basename "$script")"
    else
        test_fail "syntax error: $(basename "$script")"
    fi
done < <(find "${MARVIN_DIR}/agent" -name "*.sh" -type f | sort)

# ─── 1a. Python syntax check for agent data-processing scripts ───────────────
# perf-analytics.py and any future Python helpers must compile cleanly. Only
# runs when python3 is present and at least one .py file exists under agent/.

if command -v python3 >/dev/null 2>&1; then
    while IFS= read -r pyscript; do
        [[ -z "$pyscript" ]] && continue
        if python3 -m py_compile "$pyscript" 2>/dev/null; then
            test_pass "python syntax ok: $(basename "$pyscript")"
        else
            test_fail "python syntax error: $(basename "$pyscript")"
        fi
    done < <(find "${MARVIN_DIR}/agent" -name "*.py" -type f | sort)
fi

# ─── 1b. Merge conflict marker check ─────────────────────────────────────────
# Detects leftover <<<<<<< / ======= / >>>>>>> markers that break scripts

marvin_log "INFO" "Self-test: checking for merge conflict markers"

while IFS= read -r script; do
    if grep -qE '^<{7} |^={7}$|^>{7} ' "$script" 2>/dev/null; then
        test_fail "merge conflict markers: $(basename "$script")"
    else
        test_pass "no conflict markers: $(basename "$script")"
    fi
done < <(find "${MARVIN_DIR}/agent" -name "*.sh" -type f | sort)

# ─── 1c. ShellCheck static analysis ──────────────────────────────────────────
# Runs ShellCheck (if installed) to catch common bash pitfalls and bugs

if command -v shellcheck &>/dev/null; then
    marvin_log "INFO" "Self-test: running ShellCheck static analysis"
    _sc_errors=0
    while IFS= read -r script; do
        # Check for errors only (SC level error) — warnings tracked separately
        if ! shellcheck -S error "$script" >/dev/null 2>&1; then
            test_fail "shellcheck errors: $(basename "$script")"
            _sc_errors=$((_sc_errors + 1))
        fi
    done < <(find "${MARVIN_DIR}/agent" -name "*.sh" -type f | sort)
    if [[ "$_sc_errors" -eq 0 ]]; then
        test_pass "shellcheck: all scripts pass (no errors)"
    fi
    # Count warnings (informational, not a test failure) — use find for recursive coverage
    _sc_warn_count=$(find "${MARVIN_DIR}/agent" -name "*.sh" -type f -print0 \
        | xargs -0 shellcheck -S warning 2>&1 \
        | grep -c 'SC[0-9]' || true)
    if [[ "$_sc_warn_count" -gt 0 ]]; then
        test_warn "shellcheck: ${_sc_warn_count} warnings across all scripts"
    fi
else
    test_warn "shellcheck not installed — skipping static analysis"
fi

# ─── 1d. run_claude call-site exit-code capture ──────────────────────────────
# Every `VAR=$(run_claude ...)` / `VAR=$(run_claude_with_retry ...)` call site
# must capture the exit code (via `|| rc=$?` or `&& rc=0 || rc=$?`). A bare
# command substitution under `set -euo pipefail` + `trap marvin_error_trap ERR`
# crashes the whole script on ANY non-zero return (transient exit 1, lock-timeout
# exit 2) BEFORE the call site's post-run logic can run — the class that killed
# hourly-check (2026-06-12), network-discovery (2026-07-06), self-enhance
# (2026-07-11) and evening-report (latent, fixed 2026-07-13). Detect the pattern
# structurally instead of waiting for the next crash in the logs.

marvin_log "INFO" "Self-test: checking run_claude call sites capture exit codes"

_unguarded_calls=0
while IFS= read -r _hit; do
    [[ -z "$_hit" ]] && continue
    _cf="${_hit%%:*}"
    _cl="${_hit#*:}"; _cl="${_cl%%:*}"
    # Window heuristic (not an exact call→capture pairing): the call line plus
    # the next 4 lines — covers multiline invocations whose `|| rc=$?` capture
    # lands a couple of lines below the `run_claude` line (e.g.
    # network-discovery.sh spreads it across 3 lines). Trade-off: an unrelated
    # `X=$?` within the window reads as guarded (false negative — low risk at
    # our call-site density). The `|| true` keeps this detector from tripping
    # its own rule: a bare `$(sed …)` here would abort self-test on the ERR trap
    # if `$_cf` were ever unreadable — exactly the crash class §1d exists to catch.
    _cwin=$(sed -n "${_cl},$((_cl + 4))p" "$_cf" 2>/dev/null) || true
    # Guard idiom recognised: `VAR=$?` (incl. `&& rc=0 || rc=$?`). A call site
    # that tests `$?` inline without assigning it would false-positive here — no
    # current site does; keep captures in the `VAR=$?` form.
    if ! grep -qE '=\$\?' <<< "$_cwin"; then
        test_fail "run_claude call site missing exit-code capture: $(basename "$_cf"):${_cl}"
        _unguarded_calls=$((_unguarded_calls + 1))
    fi
done < <(grep -rnE '[A-Za-z_][A-Za-z0-9_]*=\$\(run_claude' "${MARVIN_DIR}/agent" --include='*.sh' 2>/dev/null \
            | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [[ "$_unguarded_calls" -eq 0 ]]; then
    test_pass "run_claude call sites: all capture exit codes"
fi

# ─── 1e. negotiate-listener handler: reachable, and answers valid JSON ───────
# The listener spent 2026-02-22 → 2026-07-26 `active (running)` and completely
# inert: socat re-invokes this script as its own per-connection handler, so a
# `command -v socat` test placed before the `--handle` test sent every child
# back into the listen branch to die on EADDRINUSE against its own parent. Five
# months of 502s that no monitor noticed, because the parent never exited.
#
# Drive the handler directly (no socat, no port, no service) and assert on what
# a peer would actually receive. A functional check rather than a grep for the
# branch order: it also covers the response framing, where a character-counted
# Content-Length was truncating the body past a multi-byte em dash.

marvin_log "INFO" "Self-test: checking negotiate listener answers a synthetic proposal"

_negotiate_ls="${MARVIN_DIR}/agent/negotiate-listener.sh"
if [[ ! -f "$_negotiate_ls" ]]; then
    test_fail "negotiate-listener.sh missing"
elif ! command -v jq &>/dev/null; then
    test_warn "jq not installed — skipping negotiate listener handler test"
else
    _neg_tmp=$(mktemp -d)
    _neg_body='{"self_test":true,"from":"self-test.sh"}'
    _neg_resp=$(
        printf 'POST /.well-known/ai-negotiate HTTP/1.1\r\nX-Real-IP: 127.0.0.1\r\nX-Request-Id: self-test\r\nContent-Length: %s\r\n\r\n%s' \
            "${#_neg_body}" "$_neg_body" \
        | MARVIN_NEGOTIATE_INBOX="$_neg_tmp" bash "$_negotiate_ls" --handle 2>/dev/null
    ) || _neg_resp=""
    rm -rf "$_neg_tmp"

    # Split on the header/body boundary and compare the advertised byte count
    # against the body actually emitted — a client reads exactly the former.
    _neg_declared=$(grep -aiE '^Content-Length:' <<< "$_neg_resp" | tr -d '\r' | awk '{print $2}' | head -1)
    _neg_payload=${_neg_resp#*$'\r\n\r\n'}
    _neg_actual=$(printf '%s' "$_neg_payload" | LC_ALL=C wc -c | tr -d '[:space:]')

    if [[ -z "$_neg_resp" ]]; then
        test_fail "negotiate listener: --handle produced no response (dispatch order regressed?)"
    elif [[ "$_neg_resp" != "HTTP/1.1 202 Accepted"* ]]; then
        test_fail "negotiate listener: expected 202, got '$(head -1 <<< "$_neg_resp" | tr -d '\r')'"
    elif ! jq -e . >/dev/null 2>&1 <<< "$_neg_payload"; then
        test_fail "negotiate listener: 202 body is not valid JSON"
    elif [[ "$_neg_declared" != "$_neg_actual" ]]; then
        test_fail "negotiate listener: Content-Length ${_neg_declared} != ${_neg_actual} body bytes (client reads a truncated document)"
    else
        test_pass "negotiate listener: handler reachable, 202 body valid and correctly framed"
    fi
fi

# ─── 1f. negotiate health probe is side-effect-free (#852) ───────────────────
# The beacon's negotiate_url is gated on a live POST to this endpoint (see
# network-discovery.sh), and §1e above is why that POST now reaches a handler at
# all. The new hazard is the health check becoming a *participant*: an unmarked
# POST is filed in the inbox, and negotiate-handler.sh answers it with a real
# Claude call and a self-authored entry in the public negotiation history —
# daily, forever.
#
# Assert both halves of the contract, because each fails silently on its own: a
# 2xx (without it the beacon just quietly stops advertising a working endpoint)
# AND an untouched inbox (without it Marvin bills himself to negotiate with
# himself). The inbox is redirected to a scratch dir, so "wrote nothing" is
# checked as "the directory is still empty" rather than inferred.

marvin_log "INFO" "Self-test: checking negotiate health probe writes nothing"

_probe_ls="${MARVIN_DIR}/agent/negotiate-listener.sh"
if [[ ! -f "$_probe_ls" ]]; then
    test_fail "negotiate-listener.sh missing"
elif ! command -v jq &>/dev/null; then
    test_warn "jq not installed — skipping negotiate health probe test"
else
    _probe_tmp=$(mktemp -d)
    _probe_body='{"marvin_health_probe":true}'
    _probe_resp=$(
        printf 'POST /.well-known/ai-negotiate HTTP/1.1\r\nX-Real-IP: 127.0.0.1\r\nX-Request-Id: self-test\r\nContent-Length: %s\r\n\r\n%s' \
            "${#_probe_body}" "$_probe_body" \
        | MARVIN_NEGOTIATE_INBOX="$_probe_tmp" bash "$_probe_ls" --handle 2>/dev/null
    ) || _probe_resp=""
    # Count what negotiate-handler.sh would actually pick up.
    _probe_written=$(find "$_probe_tmp" -type f -name '*.json' 2>/dev/null | wc -l)
    rm -rf "$_probe_tmp"

    if [[ "$_probe_resp" != "HTTP/1.1 2"* ]]; then
        test_fail "negotiate health probe: expected 2xx, got '$(head -1 <<< "$_probe_resp" | tr -d '\r')' — beacon gate cannot open"
    elif [[ "$_probe_written" -ne 0 ]]; then
        test_fail "negotiate health probe: wrote ${_probe_written} inbox record(s) — the daily beacon probe is filing itself as a peer proposal"
    else
        test_pass "negotiate health probe: 2xx and inbox untouched"
    fi
fi

# ─── 1g. github.sh label normalization (issue #850) ──────────────────────────
# A `labels:` list with spaces after the commas ("marvin-auto, incident") used
# to reach the API as " incident", and GitHub rejects the WHOLE issue with a 422
# (resource=Label) — title, body and the Claude run that produced them, gone,
# leaving only `[ERROR] Errors: name`. Three finished bug reports died this way
# on 2026-07-26 before anyone noticed, because the failure destroys the evidence
# of itself. Unit-test the transform so the fix cannot silently regress.
#
# Sourced via `dirname "$0"` rather than ${MARVIN_DIR} (as §1/§1d use) on
# purpose: this asserts on the library that ships next to *this* test, so the
# check is meaningful when run from a branch worktree and not only post-merge.
# Run in a subshell so github.sh's token loading/`export` cannot leak into the
# rest of the suite, and capture the status explicitly — a bare `$(...)` here
# would abort self-test on the ERR trap, the exact class §1d exists to catch.

marvin_log "INFO" "Self-test: checking github.sh label normalization"

_lib_github="$(dirname "$0")/lib/github.sh"
if [[ ! -f "$_lib_github" ]]; then
    test_fail "labels: lib/github.sh not found at ${_lib_github}"
else
    _norm() {
        # shellcheck source=/dev/null  # path is runtime-resolved (branch or live tree)
        ( source "$_lib_github" >/dev/null 2>&1 && github_normalize_labels "$1" )
    }
    _label_failures=0
    # `unique` sorts ascending, so expectations are in sorted order.
    while IFS='|' read -r _in _want; do
        [[ -z "$_want" ]] && continue
        _got=$(_norm "$_in") || _got="<error>"
        if [[ "$_got" != "$_want" ]]; then
            test_fail "labels: '${_in}' -> ${_got} (expected ${_want})"
            _label_failures=$((_label_failures + 1))
        fi
        # The whole point of `-c`: one line, or the WARN that reports a label
        # rejection gets shredded by health-monitor.sh's line-based log parser.
        if [[ "$(printf '%s' "$_got" | wc -l)" -ne 0 ]]; then
            test_fail "labels: '${_in}' produced multi-line JSON (needs jq -c)"
            _label_failures=$((_label_failures + 1))
        fi
    done <<'LABEL_CASES'
marvin-auto, incident, enhancement|["enhancement","incident","marvin-auto"]
a, b ,c,,a|["a","b","c"]
marvin-auto|["marvin-auto"]
 , , |[]
	tabbed , spaced |["spaced","tabbed"]
-n|["-n"]
LABEL_CASES
    # Empty input is handled by the guard clause, not the jq filter — checked
    # separately because a here-doc line cannot carry an empty first field.
    _got=$(_norm "") || _got="<error>"
    [[ "$_got" == "[]" ]] || {
        test_fail "labels: empty input -> ${_got} (expected [])"
        _label_failures=$((_label_failures + 1))
    }
    if [[ "$_label_failures" -eq 0 ]]; then
        test_pass "labels: trim/dedupe/compact normalization correct (7 cases)"
    fi
    unset -f _norm
fi

# ─── 1h. pipefail double-JSON-document detector (#855) ───────────────────────
# The bug class fixed four times in five days, in four files (#841/#843
# log-alerting, #844 log-export + capability-inventory, #846 weekly-analytics):
# under `set -euo pipefail` an early pipeline stage failing fires a trailing
# `|| echo '[]'` AFTER a later `jq` has already printed a valid document, so the
# "fallback" appends a second document instead of replacing the first. Each of
# the four reviews found a variant the previous one had walked past, which is why
# this is a grep and not a fifth code review. Detection lives in
# agent/lib/pipefail-scan.sh; see its header for the four-condition rule.
#
# RATCHET, not a wall. The two PRs that fix the five sites still on main (#844,
# #846) are unmerged, and #855 concluded the detector therefore could not ship —
# a suite that is red for a reason nobody can act on is worse than no test. So
# known-pending sites are listed below and reported as WARN; anything NOT listed
# is a FAIL. That protects main against a sixth instance today instead of after
# two merges, and cannot turn the suite red on merge.
#
# Keyed by a hash of the whitespace-normalized statement, not by line number, so
# an edit above a known site does not read as a new defect. A fixed statement's
# key changes, so it drops out of the baseline by itself — reported as a stale
# WARN telling whoever merged the fix to delete the line. Removing all five is
# the last step of #855.
# Fields: basename | statement key | note. Split with `IFS='|' read -r f k note`
# so a note containing a pipe lands wholly in the third field and can never be
# mistaken for part of the key.
_PIPEFAIL_KNOWN=(
    "capability-inventory.sh|f00b3f0b1a2d|cron-entries jq -s fallback — fix pending in PR #844"
    "log-export.sh|2295353653c5|enhancement_log find + jq -R -s fallback — fix pending in PR #844"
    "log-export.sh|7996086ae437|blog_posts find + jq -R -s fallback — fix pending in PR #844"
    "weekly-analytics.sh|ba972a99c6ce|claude-usage cat + jq -s fallback — fix pending in PR #846"
    "weekly-analytics.sh|46dcf3def0ca|error_summary head -5 SIGPIPE — fix pending in PR #846"
)

_pipefail_scan="${MARVIN_DIR}/agent/lib/pipefail-scan.sh"
if [[ ! -r "$_pipefail_scan" ]]; then
    test_warn "pipefail double-document scanner missing (${_pipefail_scan})"
else
    marvin_log "INFO" "Self-test: scanning for pipefail double-document fallbacks"
    # The scanner's exit code is load-bearing and must NOT be collapsed (#858):
    #   0 = clean, 1 = hits, 2 = could not scan.
    # An earlier version used `|| true`, which made a scanner that failed to run
    # indistinguishable from a clean tree — it would have reported PASS *and*
    # declared all five baseline entries stale, i.e. announced that #844/#846 had
    # landed when nothing had. That is the same "collapse a failure into an empty
    # result and call it fine" shape this whole section exists to catch, which is
    # the second time this bug class has been reintroduced by code written to
    # prevent it. The capture still must not fire the ERR trap (the §1d class),
    # hence `&& rc=0 || rc=$?` rather than a bare substitution.
    # The scanner names the cause of every exit 2 on stderr (missing tool,
    # unreadable file, awk failure, unenumerable tree, empty target list).
    # Discarding that with `2>/dev/null` would leave an operator holding a bare
    # "exit 2" and a manual rerun to learn which of the five fired — throwing away
    # failure detail inside the one check whose purpose is to stop failure detail
    # being thrown away. Captured to a file rather than merged with `2>&1`, so a
    # diagnostic line can never be read back as a TSV finding.
    _pf_err=$(mktemp 2>/dev/null) || _pf_err="/dev/null"
    _pf_out=$(bash "$_pipefail_scan" --tsv 2>"$_pf_err") && _pf_rc=0 || _pf_rc=$?
    _pf_reason=$(tr '\n' ';' <"$_pf_err" 2>/dev/null | sed 's/;*$//; s/;/; /g') || _pf_reason=""
    [[ "$_pf_err" == "/dev/null" ]] || rm -f "$_pf_err"
    _pf_trusted=true
    if [[ "$_pf_rc" -gt 1 ]]; then
        test_fail "pipefail double-document scanner could not run (exit ${_pf_rc}${_pf_reason:+: ${_pf_reason}}) — the check did NOT execute; do not read this run as clean"
        _pf_trusted=false
    elif [[ "$_pf_rc" -eq 0 && -n "$_pf_out" ]]; then
        test_fail "pipefail scanner reported clean (exit 0) but printed findings — scanner contract violated, results untrustworthy"
        _pf_trusted=false
    elif [[ "$_pf_rc" -eq 1 && -z "$_pf_out" ]]; then
        test_fail "pipefail scanner reported hits (exit 1) but printed nothing — scanner contract violated, results untrustworthy"
        _pf_trusted=false
    fi
    _pf_new=0
    _pf_seen=()
    # `_pf_stmt` is never read, but it is NOT dead code — it is the sink that
    # absorbs the TSV's 4th field (the statement text). `read` assigns everything
    # left over to its final variable, so dropping it would make `_pf_key` become
    # "<hash>\t<statement>", no baseline entry would ever match, and all five
    # known-pending sites would report as unbaselined FAILs — turning the suite
    # red on merge. Verified: shellcheck flags it at neither warning nor info.
    while IFS=$'\t' read -r _pf_file _pf_line _pf_key _pf_stmt; do
        [[ "$_pf_trusted" == true ]] || break
        [[ -z "${_pf_file:-}" ]] && continue
        _pf_id="${_pf_file}|${_pf_key}"
        _pf_note=""
        for _pf_b in "${_PIPEFAIL_KNOWN[@]}"; do
            IFS='|' read -r _pf_bf _pf_bk _pf_bn <<< "$_pf_b"
            if [[ "${_pf_bf}|${_pf_bk}" == "$_pf_id" ]]; then
                _pf_note="$_pf_bn"
                break
            fi
        done
        _pf_seen+=("$_pf_id")
        if [[ -n "$_pf_note" ]]; then
            test_warn "pipefail double-document (known): ${_pf_file}:${_pf_line} — ${_pf_note}"
        else
            test_fail "pipefail double-document fallback: ${_pf_file}:${_pf_line} (a failing early stage appends a second JSON document after jq already printed one — assign the fallback instead of echoing it)"
            _pf_new=$((_pf_new + 1))
        fi
    done <<< "$_pf_out"
    if [[ "$_pf_trusted" == true && "$_pf_new" -eq 0 ]]; then
        test_pass "pipefail double-document scan: no new sites"
    fi
    # Stale baseline entries: the fix landed, so the line is now excusing
    # nothing and must go, or it silently re-excuses a reintroduction later.
    # Gated on a trustworthy scan — an unlisted-because-nothing-ran entry is not
    # a landed fix, and saying so would be the false all-clear from #858.
    for _pf_b in "${_PIPEFAIL_KNOWN[@]}"; do
        [[ "$_pf_trusted" == true ]] || break
        IFS='|' read -r _pf_bf _pf_bk _pf_bn <<< "$_pf_b"
        _pf_bid="${_pf_bf}|${_pf_bk}"
        _pf_found=false
        if [[ ${#_pf_seen[@]} -gt 0 ]]; then
            for _pf_s in "${_pf_seen[@]}"; do
                [[ "$_pf_s" == "$_pf_bid" ]] && _pf_found=true && break
            done
        fi
        if [[ "$_pf_found" == false ]]; then
            test_warn "pipefail baseline entry is stale — the fix landed, remove it from _PIPEFAIL_KNOWN: ${_pf_bid}"
        fi
    done
fi

# ─── 1i. weekly-analytics fallback/success shape parity ──────────────────────
# `_claude_usage()` emits one object on success and a hand-written zero object
# on the failure/empty paths. Those two shapes must carry the same keys: a
# consumer reading a field that only the success shape defines gets `null`
# instead of 0, and nothing downstream distinguishes "no runs" from "key was
# never there". This is not hypothetical — both fallback literals had already
# drifted from the jq object, omitting total_prompt_chars and
# total_output_chars, and the drift was invisible because the fallback only
# renders on an I/O fault. Collapsed to a single `_zero_claude_usage()`; this
# asserts it stays in step as fields are added to the jq block.
#
# Extract the functions from the script rather than sourcing it (the script
# runs its whole pipeline at import) and read them via `dirname $0`, NOT
# MARVIN_DIR — a branch-authored test that resolves through MARVIN_DIR asserts
# against the deployed main copy and would pass while the branch regressed.

marvin_log "INFO" "Self-test: checking weekly-analytics claude-usage shape parity"

_wa_script="$(dirname "$0")/weekly-analytics.sh"
if [[ -r "$_wa_script" ]]; then
    # Slices one function out of weekly-analytics.sh: matches its opening
    # `fn() {` and stops at the first `}` in column 0.
    #
    # That terminator is a structural ASSUMPTION about the source file, not
    # something the source file enforces. Every brace inside the three
    # functions extracted here — including the multi-line jq literal — is
    # indented today; a future reformat leaving a closing `}` at column 0
    # mid-body would truncate the slice. It fails safe rather than silently
    # passing: a truncated function is unbalanced bash, `eval` rejects it, and
    # the `|| exit 3` / `declare -F` guards below render that as test_warn
    # ("could not run"), never test_pass. Recorded so the next reader knows
    # the assumption is deliberate and what to re-check if it spreads.
    _wa_extract() {
        awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^\}$/ {exit}' "$_wa_script"
    }
    # Subshell: the extracted functions and the METRICS_DIR override must not
    # leak into the rest of the suite.
    #
    # `|| _shape_rc=$?` rather than a bare assignment read by `$?` on the next
    # line: this file runs under `set -euo pipefail` with `trap
    # marvin_error_trap ERR`, so an assignment from a subshell that exits
    # non-zero is a failing simple command, and the suite ABORTS — reporting a
    # crash — at the exact moment this check finds the drift it exists to
    # find. Demonstrated after the fact: with a field deleted from
    # `_zero_claude_usage()`, the previous spelling fired the ERR trap and
    # exited 1 with no `test_fail` line at all; the entry above claims this
    # negative control "fails with both key lists printed", and it did not.
    # As part of an OR-list the assignment is exempt from both errexit and the
    # trap. (Same defect, same shape, found the same way in #862's §9g.)
    _shape_rc=0
    _shape_result=$(
        set +e
        _wa_tmp=$(mktemp -d) || exit 3
        trap 'rm -rf "$_wa_tmp"' EXIT
        # Read by the _claude_usage extracted below; shellcheck cannot see
        # through the eval, hence the disable rather than a spurious export.
        # shellcheck disable=SC2034
        METRICS_DIR="$_wa_tmp"
        _wa_day=$(date -u +%Y-%m-%d)
        printf '{"task":"selftest","duration_s":1,"prompt_chars":1,"output_chars":1,"exit_code":0}\n' \
            > "${_wa_tmp}/claude-usage-${_wa_day}.jsonl" || exit 3
        # `eval` is on the guideline's security red-flag list, so the trust
        # boundary is worth stating rather than leaving to inference: the text
        # evaluated here is sliced from agent/weekly-analytics.sh, a file
        # tracked in this same repo and already executed as root by cron. It is
        # never runtime input, never peer- or user-supplied, and never leaves
        # this subshell. Anyone who can change what this evaluates can already
        # change what the daily job runs.
        eval "$(_wa_extract _dates_in_range)" 2>/dev/null || exit 3
        eval "$(_wa_extract _zero_claude_usage)" 2>/dev/null || exit 3
        eval "$(_wa_extract _claude_usage)" 2>/dev/null || exit 3
        # All three, not just one. `eval ""` on a failed extraction succeeds, so
        # `|| exit 3` above cannot catch an extractor miss — only this can. And a
        # missing `_dates_in_range` specifically produces a FALSE PASS, not a
        # crash: it is called from `< <(_dates_in_range …)`, whose command-not-
        # found never reaches `_claude_usage`'s exit status, so `files` comes back
        # empty and `_claude_usage` returns `_zero_claude_usage` — the check then
        # compares the fallback shape against itself and reports test_pass having
        # asserted nothing. Demonstrated: extracting only the other two functions
        # exits 0 today. (#867 — an assertion that cannot fail.)
        declare -F _dates_in_range _zero_claude_usage _claude_usage >/dev/null || exit 3
        _ok=$(_claude_usage "$_wa_day" "$_wa_day" | jq -r 'keys|join(",")' 2>/dev/null) || exit 3
        _zero=$(_zero_claude_usage | jq -r 'keys|join(",")' 2>/dev/null) || exit 3
        [[ -n "$_ok" && -n "$_zero" ]] || exit 3
        [[ "$_ok" == "$_zero" ]] && exit 0
        printf 'success=[%s] fallback=[%s]' "$_ok" "$_zero"
        exit 1
    ) || _shape_rc=$?
    case "$_shape_rc" in
        0) test_pass "weekly-analytics: claude-usage fallback shape matches success shape" ;;
        1) test_fail "weekly-analytics: claude-usage fallback shape drifted — ${_shape_result}" ;;
        # Exit 3 is "could not run the check", kept distinct from a clean pass —
        # the §1h lesson from #858: a harness that collapses "did not run" into
        # "found nothing" reports green for a test that never executed.
        *) test_warn "weekly-analytics: claude-usage shape check could not run (extract/jq failure)" ;;
    esac
else
    test_warn "weekly-analytics: claude-usage shape check skipped — script not readable"
fi

# ─── 2. JSON data file validation ────────────────────────────────────────────

marvin_log "INFO" "Self-test: validating JSON data files"

for json_file in "${DATA_DIR}/status.json" \
                 "${DATA_DIR}/uptime.json" \
                 "${DATA_DIR}/blog-index.json" \
                 "${DATA_DIR}/about.json" \
                 "${DATA_DIR}/comms-summary.json" \
                 "${DATA_DIR}/metrics-history.json" \
                 "${COMMS_DIR}/identity.json" \
                 "${COMMS_DIR}/incoming-signals.json" \
                 "${COMMS_DIR}/peers.json"; do
    if [[ ! -f "$json_file" ]]; then
        test_warn "missing: $(basename "$json_file")"
        continue
    fi
    if jq empty "$json_file" 2>/dev/null; then
        test_pass "valid json: $(basename "$json_file")"
    else
        test_fail "invalid json: $(basename "$json_file")"
    fi
done

# ─── 3. Critical service checks ──────────────────────────────────────────────

marvin_log "INFO" "Self-test: checking critical services"

for service in nginx fail2ban cron ssh; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        test_pass "service running: $service"
    else
        test_fail "service down: $service"
    fi
done

# ─── 4. Metric assertion tests ───────────────────────────────────────────────

marvin_log "INFO" "Self-test: checking metric thresholds"

if [[ -f "${DATA_DIR}/status.json" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
        test_warn "jq not installed; skipping metric threshold checks"
    else
        disk_pct_raw=$(jq -r '.metrics.disk.percent // "0%"' "${DATA_DIR}/status.json" 2>/dev/null || true)
        disk_pct=$(printf '%s' "$disk_pct_raw" | tr -d '%')
        mem_avail=$(jq -r '.metrics.memory.available // 0' "${DATA_DIR}/status.json" 2>/dev/null || true)

        if ! [[ "$disk_pct" =~ ^[0-9]+$ ]]; then
            test_warn "disk usage metric missing or invalid in status.json"
        else
            if [[ "$disk_pct" -lt 80 ]]; then
                test_pass "disk usage ${disk_pct}% (< 80%)"
            elif [[ "$disk_pct" -lt 95 ]]; then
                test_warn "disk usage ${disk_pct}% (warning threshold)"
            else
                test_fail "disk usage ${disk_pct}% (critical!)"
            fi
        fi

        if ! [[ "$mem_avail" =~ ^[0-9]+$ ]]; then
            test_warn "memory available metric missing or invalid in status.json"
        else
            if [[ "$mem_avail" -gt 200 ]]; then
                test_pass "memory available ${mem_avail}MB (> 200MB)"
            else
                test_warn "memory available ${mem_avail}MB (low)"
            fi
        fi
    fi
fi

# ─── 5. health-monitor.sh produces valid JSON ────────────────────────────────

marvin_log "INFO" "Self-test: verifying collect_metrics output"

metrics_output=$(collect_metrics 2>/dev/null || echo "")
if [[ -n "$metrics_output" ]] && echo "$metrics_output" | jq empty 2>/dev/null; then
    test_pass "collect_metrics produces valid JSON"
else
    test_fail "collect_metrics output is not valid JSON"
fi

# ─── 6. Claude CLI availability ──────────────────────────────────────────────

if command -v claude &>/dev/null; then
    test_pass "claude CLI found in PATH"
else
    test_fail "claude CLI not found"
fi

# ─── 7. Web dashboard exists ─────────────────────────────────────────────────

if [[ -f "${WEB_DIR}/package.json" ]]; then
    test_pass "Next.js dashboard exists"
elif [[ -f "${WEB_DIR}/index.html" ]]; then
    test_pass "static dashboard exists"
else
    test_fail "dashboard missing — no package.json or index.html"
fi

# ─── 7b. Web build artifact ownership ────────────────────────────────────────
# Catches the regression class that broke deploy-web.sh on 2026-05-04: cron
# (root) running npm into web/{node_modules,.next} leaves root-owned files
# that lock out the marvin-uid deploy. marvin_rebuild_web() now drops to
# marvin, but a single misbehaving rebuild path can poison the directory.

_affected_dir_count=0
for _dir in "${WEB_DIR}/node_modules" "${WEB_DIR}/.next"; do
    [[ -d "$_dir" ]] || continue
    # No pipe to `grep -q` — under `set -o pipefail` that would risk the
    # SIGPIPE class fixed in PR #672. `find -quit` is bounded to a single
    # match, captured into a string and tested with `[[ -n ]]` instead.
    if [[ -n "$(find "$_dir" -not -user marvin -print -quit 2>/dev/null)" ]]; then
        _affected_dir_count=$((_affected_dir_count + 1))
    fi
done
if [[ $_affected_dir_count -eq 0 ]]; then
    test_pass "web build artifacts owned by marvin"
else
    test_fail "web build artifacts have non-marvin ownership in ${_affected_dir_count} dir(s) — next deploy-web.sh will EACCES"
fi

# ─── 8. Git repo health ──────────────────────────────────────────────────────

if git -C "${MARVIN_DIR}" status --porcelain >/dev/null 2>&1; then
    test_pass "git repository accessible"
elif [[ -d "${MARVIN_DIR}/.git" ]]; then
    test_pass "git directory exists (possible safe.directory restriction)"
else
    test_fail "git repository inaccessible"
fi

# ─── 9. Cron job health verification ──────────────────────────────────────────
# Checks that expected cron-triggered scripts have fired recently.
# Uses today's and yesterday's logs to verify each major task ran.

marvin_log "INFO" "Self-test: verifying cron job health"

YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d 2>/dev/null || echo "")
_cron_log_today="${LOGS_DIR}/${TODAY}.log"
_cron_log_yesterday="${LOGS_DIR}/${YESTERDAY}.log"

# Combine today + yesterday for a 48h window (some tasks run once daily)
_cron_combined=""
[[ -f "$_cron_log_today" ]] && _cron_combined=$(cat "$_cron_log_today")
[[ -f "$_cron_log_yesterday" ]] && _cron_combined="${_cron_combined}
$(cat "$_cron_log_yesterday")"

# Expected tasks and their log markers (task_name:log_marker).
# Markers must match what the script ACTUALLY logs — health-monitor and
# morning-check use marvin_log_json() which emits "Health monitor"/"Morning
# check" rather than the all-caps banners the other scripts use.
_cron_tasks=(
    "health-monitor:Health monitor"
    "morning-check:Morning check"
    "security-scan:SECURITY SCAN"
    "log-export:LOG EXPORT"
    "hourly-check:HOURLY CHECK"
)

_cron_ok=0
_cron_missing=0
for entry in "${_cron_tasks[@]}"; do
    task_name="${entry%%:*}"
    marker="${entry##*:}"
    # Use bash glob match instead of `echo "$big" | grep -q`. Under
    # `set -o pipefail`, grep -q closes the pipe after the first match,
    # echo gets SIGPIPE and exits 141, the pipeline exits 141, and
    # `set -e` kills the script — or worse, the if-condition reads it
    # as "no match" and reports a present cron task as missing. Same
    # SIGPIPE-under-pipefail trap as daily-digest.sh (lesson 2026-04-28).
    if [[ "$_cron_combined" == *"$marker"* ]]; then
        test_pass "cron ran: ${task_name}"
        _cron_ok=$((_cron_ok + 1))
    else
        test_warn "cron not seen in 48h: ${task_name}"
        _cron_missing=$((_cron_missing + 1))
    fi
done

if [[ "$_cron_missing" -eq 0 ]]; then
    marvin_log "INFO" "All ${_cron_ok} expected cron tasks verified"
else
    marvin_log "WARN" "${_cron_missing} cron task(s) not seen in 48h logs"
fi

# ─── 9b. log-analysis daily output freshness ──────────────────────────────────
# Catches the missing-analysis-file class of bugs (lessons 2026-05-07/08):
# log-analysis.sh wrote zero-byte or corrupt files for 2026-05-03/05/07,
# leaving analysis-latest.json days stale. Operator noticed before self-test
# did. Now self-test fails fast if the latest pointer is older than 48h or
# not parseable single-document JSON.

marvin_log "INFO" "Self-test: verifying log-analysis output freshness"

_analysis_latest="${DATA_DIR}/logs/analysis-latest.json"
if [[ ! -f "$_analysis_latest" ]]; then
    test_fail "log-analysis output: analysis-latest.json missing"
elif ! jq -s -e 'length == 1' "$_analysis_latest" >/dev/null 2>&1; then
    # `jq -s -e 'length == 1'` rejects multi-document files (the 2026-05-08
    # bug shape) and zero-byte files (the 2026-05-03/05/07 bug shape) —
    # plain `jq empty` would accept "[]\n[]" as valid.
    test_fail "log-analysis output: analysis-latest.json not single valid JSON document"
else
    # Freshness check: file mtime within last 48h. The cron job runs daily,
    # so a >48h gap means at least one run was lost (typically the symptom
    # of a silent crash that left the previous file in place).
    _latest_age_s=$(( $(date +%s) - $(stat -c %Y "$_analysis_latest" 2>/dev/null || echo 0) ))
    if [[ "$_latest_age_s" -gt 172800 ]]; then
        _latest_age_h=$(( _latest_age_s / 3600 ))
        test_fail "log-analysis output: analysis-latest.json is ${_latest_age_h}h stale (cron not producing daily updates)"
    else
        test_pass "log-analysis output: analysis-latest.json valid and fresh"
    fi
fi

# ─── 9c. Runtime JSON file integrity sweep ────────────────────────────────────
# Validates that the public-facing runtime JSON files served by nginx parse as
# single JSON documents. Companion to section 9b (log-analysis) but generalized:
# yesterday's "Next Time" item explicitly called out
# `connection-rates.json` / `cve-status.json` / `port-inventory.json` etc. as
# the next class of files that should be sanity-checked because the dashboard
# silently accepts whatever bytes they contain.
#
# Files were corrupt for weeks (2026-04-XX → 2026-05-08) before someone
# happened to grep for the pattern. The new `marvin_validate_json_or_warn`
# write-time guards (PR for 2026-05-11) close the producer side; this section
# closes the consumer side by detecting any pre-existing or out-of-band
# corruption that slipped past the producers.
#
# Failure is downgraded to WARN rather than FAIL because (a) some files are
# ephemeral and may not exist if the producer never ran, and (b) we don't want
# a single corrupt non-load-bearing file to flip the whole self-test grade
# from A to B until the operator can see the message.

marvin_log "INFO" "Self-test: sweeping runtime JSON file integrity"

# Whitelist — list intentionally to keep the surface bounded and explicit.
# Each entry is (relative-path-under-data label).
_runtime_json_targets=(
    "security/connection-rates.json connection-rates"
    "security/cve-status.json cve-status"
    "security/port-inventory.json port-inventory"
    "security/connection-geo.json connection-geo"
    "security/outbound-audit.json outbound-audit"
    "security/connections-latest.json connections-latest"
    "security/latest-scan.json scan-latest"
    "logs/analysis-latest.json analysis-latest"
    "logs/recent.json logs-recent"
    "metrics/sla.json sla"
    "metrics/recent.json metrics-recent"
    "metrics/resource-forecast.json resource-forecast"
    "metrics/weekly-summary.json weekly-summary"
    "changelog.json changelog"
)

for _entry in "${_runtime_json_targets[@]}"; do
    _rel="${_entry% *}"
    _label="${_entry##* }"
    _path="${DATA_DIR}/${_rel}"
    if [[ ! -f "$_path" ]]; then
        # Missing files are not flagged — the producer may legitimately not
        # have run yet (e.g. first hour after a fresh deploy). Section 9b
        # already enforces freshness for the load-bearing log-analysis file.
        continue
    fi
    if [[ ! -s "$_path" ]]; then
        test_warn "runtime json: ${_label} is zero bytes (${_rel})"
        continue
    fi
    if ! jq -s -e 'length == 1' "$_path" >/dev/null 2>&1; then
        _bytes=$(wc -c < "$_path" 2>/dev/null || echo "?")
        test_warn "runtime json: ${_label} is not a single valid JSON document (${_bytes} bytes, ${_rel})"
        continue
    fi
    test_pass "runtime json: ${_label} valid (${_rel})"
done

# ─── 9e. Public beacon content freshness ─────────────────────────────────────
# /.well-known/ai-managed.json is the document every peer and scanner reads to
# decide whether anything lives here. It advertised 2026-04-08 for 109 days:
# network-discovery.sh rewrote it daily and logged "ECHO_BROADCAST: beacon
# updated" every time, but the file was git-tracked, so every `git checkout` /
# `git reset --hard` in the morning-pull and self-enhance rollback paths
# restored the stale committed blob over it.
#
# This asserts on the `last_seen` value INSIDE the document, not on the file
# mtime — a checkout that reverts the content still bumps the mtime, so an
# mtime check would have passed happily throughout those 109 days. The
# distinction is the entire point of this test.

marvin_log "INFO" "Self-test: verifying public beacon freshness"

_beacon="${COMMS_DIR}/identity.json"
if [[ ! -f "$_beacon" ]]; then
    test_fail "beacon: identity.json missing (nginx serves this at /.well-known/ai-managed.json)"
else
    _beacon_seen=$(jq -r '.last_seen // empty' "$_beacon" 2>/dev/null || true)
    if [[ -z "$_beacon_seen" ]]; then
        test_fail "beacon: last_seen absent — cannot tell whether the beacon is live"
    else
        _beacon_seen_s=$(date -d "$_beacon_seen" +%s 2>/dev/null || echo 0)
        if [[ "$_beacon_seen_s" -eq 0 ]]; then
            test_fail "beacon: last_seen is not a parseable timestamp (${_beacon_seen})"
        else
            # discovery runs daily at 18:00 UTC; >48h means a run was lost or
            # its write is being reverted.
            _beacon_age_s=$(( $(date +%s) - _beacon_seen_s ))
            if [[ "$_beacon_age_s" -gt 172800 ]]; then
                test_fail "beacon: last_seen is $(( _beacon_age_s / 86400 ))d stale (${_beacon_seen}) — beacon is frozen"
            else
                test_pass "beacon: last_seen fresh ($(( _beacon_age_s / 3600 ))h old)"
            fi
        fi
    fi

    # `born: ""` shipped publicly from 2026-02-24 to 2026-07-26 because the
    # heredoc that carried it forward read a file the same command had already
    # truncated. Empty-but-present fields parse as valid JSON, so the integrity
    # sweep above cannot see them.
    if [[ -z "$(jq -r '.born // empty' "$_beacon" 2>/dev/null || true)" ]]; then
        test_fail "beacon: born is empty — carry-over field is not being preserved"
    else
        test_pass "beacon: born populated"
    fi
fi

# Recovery wiring: morning-check.sh regenerates the beacon by invoking
# network-discovery.sh with a flag, and that call is the only thing standing
# between "the pull deleted the untracked beacon" and a 404 on
# /.well-known/ai-managed.json for up to 24h. Nothing else asserts the flag it
# passes is a flag network-discovery.sh still understands — rename or drop it
# and the recovery silently degrades to a WARN, which is precisely how the
# beacon stayed frozen for 109 days. Static check, deliberately: actually
# running --beacon-only would emit a live negotiate probe and rewrite the real
# beacon, which a test suite has no business doing.
_nd_script="${MARVIN_DIR}/agent/network-discovery.sh"
if [[ -r "$_nd_script" ]]; then
    _nd_flags_checked=0
    _nd_flags_bad=0
    while IFS= read -r _nd_flag; do
        [[ -n "$_nd_flag" ]] || continue
        _nd_flags_checked=$((_nd_flags_checked + 1))
        if ! grep -q -- "\"${_nd_flag}\"" "$_nd_script"; then
            test_fail "beacon recovery: callers pass network-discovery.sh ${_nd_flag}, but that flag is not handled there"
            _nd_flags_bad=$((_nd_flags_bad + 1))
        fi
    done < <(grep -rhoE 'network-discovery\.sh"?[[:space:]]+--[a-z-]+' "${MARVIN_DIR}/agent" 2>/dev/null \
                | grep -oE '\-\-[a-z-]+' | sort -u || true)
    if [[ "$_nd_flags_checked" -gt 0 && "$_nd_flags_bad" -eq 0 ]]; then
        test_pass "beacon recovery: all ${_nd_flags_checked} network-discovery.sh flag(s) used by callers are handled"
    fi

    # And the other direction, which is the worse failure: a recovery call that
    # loses its flag doesn't fail, it runs the FULL discovery from the morning
    # pull — section 3's SSH probe (deliberately fail2ban-triggering, once-daily
    # stamped), a Claude call, and a peer-trust rewrite, none of which belong in
    # a 06:00 git sync. Unflagged invocation is therefore a FAIL, not a WARN.
    _nd_unflagged=0
    _nd_calls=0
    while IFS= read -r _nd_call; do
        # Skip comments: the file discusses this call as well as making it.
        [[ "${_nd_call#"${_nd_call%%[![:space:]]*}"}" == \#* ]] && continue
        _nd_calls=$((_nd_calls + 1))
        [[ "$_nd_call" == *"--beacon-only"* ]] || _nd_unflagged=$((_nd_unflagged + 1))
    done < <(grep -hE 'bash[[:space:]]+"?[^"]*network-discovery\.sh' \
                 "${MARVIN_DIR}/agent/morning-check.sh" 2>/dev/null || true)
    if [[ "$_nd_unflagged" -gt 0 ]]; then
        test_fail "beacon recovery: morning-check.sh invokes network-discovery.sh without --beacon-only — a git sync would trigger a full discovery run (SSH probe, Claude call, trust rescore)"
    elif [[ "$_nd_calls" -gt 0 ]]; then
        test_pass "beacon recovery: morning-check.sh's ${_nd_calls} network-discovery.sh call(s) all pass --beacon-only"
    else
        test_warn "beacon recovery: morning-check.sh no longer invokes network-discovery.sh at all — a pull that deletes the untracked beacon now has nothing to restore it"
    fi
fi

# ─── 9f. Beacon negotiate gate ⇆ listener marker agreement ───────────────────
# network-discovery.sh only probes (and therefore only advertises) the negotiate
# endpoint if the DEPLOYED negotiate-listener.sh implements the health-probe
# short-circuit, matched by grepping for `.marvin_health_probe == true`. That is
# a textual dependency on a construct owned by a different file, and it fails
# CLOSED: if the marker is renamed, the gate shuts, `negotiate_url` silently
# disappears from the public beacon, and the only trace is a WARN among many.
# That is the exact failure shape §9e exists for — a document quietly going
# stale while everything reports success — so it gets a test rather than a
# note in a review thread.
#
# Self-activating by design, which removes the "add this to whichever PR lands
# second" coordination the review asked for: while #847 is unmerged the
# deployed listener has no probe machinery at all and this WARNs. Once it does,
# absence of the exact marker can only mean drift, and that FAILs.

marvin_log "INFO" "Self-test: checking beacon negotiate gate agrees with listener marker"

_nd_file="${MARVIN_DIR}/agent/network-discovery.sh"
_nl_file="${MARVIN_DIR}/agent/negotiate-listener.sh"
if [[ -r "$_nd_file" && -r "$_nl_file" ]]; then
    # Normalize exactly as the runtime gate does, or the test would disagree
    # with the code it is guarding: strip full-line comments (so prose that
    # merely mentions the marker cannot satisfy it) then collapse whitespace
    # (so reflowing the multi-line jq expression is not a false positive).
    _nl_norm=$(sed 's/^[[:space:]]*#.*$//' "$_nl_file" 2>/dev/null | tr -s '[:space:]' ' ') || _nl_norm=""
    # Does the gate still exist in network-discovery.sh at all? If someone drops
    # the pre-condition, the probe starts polluting the inbox again (#852) and
    # this test must not quietly keep passing on the listener half alone.
    if ! grep -q 'marvin_health_probe == true' "$_nd_file" 2>/dev/null; then
        test_fail "beacon negotiate gate: network-discovery.sh no longer checks for the listener's health-probe marker — the daily probe would write a forged peer entry to the negotiate inbox (#852)"
    elif grep -q '\.marvin_health_probe == true' <<< "$_nl_norm"; then
        test_pass "beacon negotiate gate: listener implements the health-probe marker the beacon gate greps for"
    elif grep -qE '"(alive|probe)"|probe.*:.*true' <<< "$_nl_norm"; then
        # Probe machinery present but not under the expected marker: drift.
        test_fail "beacon negotiate gate: negotiate-listener.sh has probe handling but not '.marvin_health_probe == true' — the beacon gate is now permanently closed and negotiate_url will silently vanish from the public beacon"
    else
        test_warn "beacon negotiate gate: deployed negotiate-listener.sh has no health-probe short-circuit yet (#847 unmerged) — gate correctly fails closed, negotiate_url omitted"
    fi
else
    test_warn "beacon negotiate gate: network-discovery.sh or negotiate-listener.sh not readable — check skipped"
fi

# ─── 9i. --beacon-only reports failure when the beacon was discarded ─────────
# #877: `--beacon-only` ended in an unconditional `exit 0`, so morning-check.sh's
# `|| marvin_log WARN "Beacon regeneration failed"` could never fire. The caller
# runs this ONLY when identity.json is already missing after a git sync, so the
# discard path leaves no beacon at all — and the caller recorded a successful
# recovery over a file that does not exist.
#
# Deliberately structural rather than behavioural. Executing the real
# `--beacon-only` path would fire the localhost negotiate probe at line ~222,
# which POSTs to the live endpoint and lands a forged peer entry in the real
# negotiate inbox (#852) — a self-test must not do that, and sandboxing
# COMMS_DIR does not sandbox the probe's destination. The regression this needs
# to stop is textual anyway: someone simplifying the block back to a bare
# `exit 0`.
#
# Resolved via `dirname "$0"`, not ${MARVIN_DIR}: the latter is hardcoded to the
# deployed tree, so a branch-authored check would assert against main and pass
# while the branch it ships with is broken.

marvin_log "INFO" "Self-test: checking --beacon-only exit status carries the discard path"

_bo_file="$(dirname "$0")/network-discovery.sh"
if [[ -r "$_bo_file" ]]; then
    # The early-exit block, not the argument-parsing block of the same name:
    # take the LAST `if [[ "$BEACON_ONLY" == true ]]` region that closes on a
    # column-0 `fi`. Both are at column 0, and the exit block is always later.
    _bo_block=$(awk '
        /^if \[\[ "\$BEACON_ONLY" == true \]\]; then$/ { collecting=1; buf=""; next }
        collecting && /^fi$/ { collecting=0; last=buf; next }
        collecting { buf = buf $0 "\n" }
        END { printf "%s", last }
    ' "$_bo_file") || _bo_block=""

    # A single unconditional assignment would make the flag meaningless while
    # leaving every check below it green, so pin the count as well as the shape.
    _bo_set_count=$(grep -c '^[[:space:]]*BEACON_WRITTEN=true$' "$_bo_file") || _bo_set_count=0

    if [[ -z "$_bo_block" ]]; then
        test_warn "--beacon-only exit status: could not locate the early-exit block in network-discovery.sh — check skipped (reformatted?)"
    elif ! grep -q 'exit 1' <<< "$_bo_block"; then
        test_fail "--beacon-only exit status: the early-exit block has no failing exit — a discarded beacon is reported to morning-check.sh as a successful regeneration (#877)"
    elif ! grep -q 'BEACON_WRITTEN' <<< "$_bo_block"; then
        test_fail "--beacon-only exit status: the early-exit block exits non-zero but not on BEACON_WRITTEN — failure is keyed on something other than 'was the beacon actually written' (#877)"
    elif [[ "$_bo_set_count" -ne 1 ]]; then
        test_fail "--beacon-only exit status: BEACON_WRITTEN=true is set ${_bo_set_count} times (expected exactly 1, on the mv success path) — the flag no longer proves the beacon was written"
    else
        test_pass "--beacon-only exit status: failure path is keyed on BEACON_WRITTEN and exits non-zero (#877)"
    fi
else
    test_warn "--beacon-only exit status: network-discovery.sh not readable — check skipped"
fi

# ─── 9z. Stale GPG home in project tree (issue #737) ─────────────────────────
# Surfaces if /home/marvin/git/.gnupg/ exists. Currently a Feb-23 dormant
# artefact with byte-identical duplicates of the active /home/marvin/.gnupg/
# key material; removal requires human review (one-way destructive). After
# removal this tripwire also catches any future re-creation by a misconfigured
# cron invocation that drops GNUPGHOME and lands on cwd-relative ~/.gnupg.

if [[ -d "${MARVIN_DIR}/.gnupg" ]]; then
    test_warn "stale GPG home present at ${MARVIN_DIR}/.gnupg — see issue #737"
fi

# ─── 9d. Source ⇆ live config drift detection ─────────────────────────────────
# Catches the recurring "the source-controlled config and the running config
# have silently diverged" class. It bit us twice: the nginx /llms.txt route
# (#777 — live had the fix, source did not, so a redeploy from source would
# have regressed it) and the cron schedule (setup/setup-cron.sh had gone stale
# vs the live /etc/cron.d/marvin — a bootstrap re-run would have dropped active
# jobs like backup/security-scan/fix-issues/incident-report and lost the
# /root/.local/bin PATH entry the claude CLI lives on).
#
# WARN-only: drift is an operator-reconcile signal, not a hard failure. The
# checks are read-only diffs of repo files against their installed counterparts.

marvin_log "INFO" "Self-test: checking source ⇆ live config drift"

# Shared drift check for a single source⇆live pair (WARN-only, read-only diff).
# Extracted so the nginx/systemd/deploy-hook checks below share one body and
# can't silently drift apart. Only flagged when the source exists; a live file
# absent on this host (config not installed) is informational, not a failure.
_check_config_drift() {
    local _src="$1" _live="$2" _label="$3"
    if [[ ! -f "$_src" ]]; then
        test_warn "config drift: ${_label} source missing (${_src})"
    elif [[ ! -f "$_live" ]]; then
        test_warn "config drift: ${_label} live copy not present (${_live})"
    elif diff -q "$_src" "$_live" >/dev/null 2>&1; then
        test_pass "config in sync: ${_label}"
    else
        test_warn "config drift: ${_label} — ${_src} differs from live ${_live} (reconcile before next deploy/bootstrap)"
    fi
}

# nginx: (repo-source live-installed label) — only flagged when both exist.
_nginx_drift_pairs=(
    "${MARVIN_DIR}/setup/nginx-site.conf /etc/nginx/sites-available/marvin nginx-site"
    "${MARVIN_DIR}/setup/nginx-monitoring.conf /etc/nginx/sites-available/monitoring nginx-monitoring"
    "${MARVIN_DIR}/setup/nginx-rate-limits.conf /etc/nginx/conf.d/marvin-rate-limits.conf nginx-rate-limits"
)
for _pair in "${_nginx_drift_pairs[@]}"; do
    read -r _src _live _label <<< "$_pair"
    _check_config_drift "$_src" "$_live" "$_label"
done

# systemd: the marvin-web unit runs the entire dashboard but lived ONLY on the
# host (hand-created 2026-03-01, untracked) until 2026-06-28 — a rebuild had no
# source to regenerate it from. Now captured at setup/marvin-web.service and
# installed by bootstrap.sh from that file; this diff catches any future
# divergence (e.g. a manual `systemctl edit` that the source never learns about).
# Same WARN-only, read-only-diff contract as the nginx/cron pairs above.
_systemd_drift_pairs=(
    "${MARVIN_DIR}/setup/marvin-web.service /etc/systemd/system/marvin-web.service marvin-web.service"
)
for _pair in "${_systemd_drift_pairs[@]}"; do
    read -r _src _live _label <<< "$_pair"
    _check_config_drift "$_src" "$_live" "$_label"
done

# certbot deploy hook: reloads dovecot/postfix/nginx after a cert renewal so a
# long-running service can't keep serving a stale in-memory cert (the 2026-07-08
# IMAPS incident — dovecot served a cert 13 days from expiry while the on-disk
# cert had 73 days left). Installed by bootstrap.sh from the tracked source;
# this diff catches a hand-edited live hook the source never learns about.
# Same WARN-only, read-only-diff contract as the pairs above. Only flagged when
# both exist — a host without SSL configured has no live hook and is skipped.
_deployhook_drift_pairs=(
    "${MARVIN_DIR}/setup/letsencrypt-deploy-hook.sh /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh letsencrypt-deploy-hook"
)
for _pair in "${_deployhook_drift_pairs[@]}"; do
    read -r _src _live _label <<< "$_pair"
    _check_config_drift "$_src" "$_live" "$_label"
done

# cron: extract the /etc/cron.d/marvin heredoc that setup-cron.sh would write
# and diff it against the live file. The heredoc delimiter is single-quoted
# ('EOF'), so ${MARVIN_DIR} stays literal in both — a byte-for-byte comparison
# is valid. Stop at the FIRST standalone EOF (the cron heredoc closes before
# the later logrotate heredoc).
_cron_setup_src="${MARVIN_DIR}/setup/setup-cron.sh"
_cron_live="/etc/cron.d/marvin"
if [[ ! -f "$_cron_setup_src" ]]; then
    test_warn "config drift: setup-cron.sh source missing (${_cron_setup_src})"
elif [[ ! -f "$_cron_live" ]]; then
    test_warn "config drift: live cron not present (${_cron_live})"
else
    # \047 is a literal apostrophe — matches the single-quoted 'EOF' opener
    # exactly (vs. the wildcard `.EOF.`) while keeping the awk program in shell
    # single-quotes, so `\$CRON_FILE` survives unescaped.
    _cron_generated=$(awk '/cat > "\$CRON_FILE" << \047EOF\047/{f=1;next} f&&/^EOF$/{exit} f' "$_cron_setup_src" 2>/dev/null)
    if [[ -z "$_cron_generated" ]]; then
        test_warn "config drift: could not extract cron heredoc from setup-cron.sh"
    elif diff -q <(printf '%s\n' "$_cron_generated") "$_cron_live" >/dev/null 2>&1; then
        test_pass "config in sync: cron (setup-cron.sh ⇆ /etc/cron.d/marvin)"
    else
        test_warn "config drift: cron — setup-cron.sh would not reproduce live /etc/cron.d/marvin (a bootstrap re-run could drop or revert active jobs)"
    fi
fi

# ─── 9h. nginx must not retain raw request bodies in the negotiate inbox ──────
# Issue #854. `client_body_in_file_only on` in the /.well-known/ai-negotiate
# location made nginx keep every request body forever, as a raw
# attacker-controlled file inside the very directory negotiate-handler.sh globs
# for proposals. It survived because the glob is `*.json` and nginx's temp files
# have no extension — one character of luck between "inert" and "the public
# endpoint feeds the handler unsanitized input".
#
# Lives in the §9 config family rather than §1 because it is the same shape as
# §9d: an assertion about configuration, not about script syntax. Sources are
# FAIL (the repo is what a rebuild reads); the live copy is WARN, because
# reconciling it is a deploy step and §9d already tracks that drift. Checked in
# BOTH tracked sources — nginx-site.conf and bootstrap.sh's heredoc — since only
# the former is diffed against live, so a bootstrap re-run was free to reinstate
# what a fix to the other one removed.

marvin_log "INFO" "Self-test: checking nginx does not retain raw negotiate bodies"

# Two distinct invariants, deliberately not merged into one regex — the review of
# #856 was right that `client_body_in_file_only clean` does NOT retain (nginx
# removes the file after the request), so banning it under a "retains" message
# would fail a future legitimate config with a factually false reason.
#
#   RETAIN — `in_file_only on` is the one value that never removes the file.
#   INBOX  — a client_body_temp_path under the project data dir puts a raw,
#            caller-controlled body inside the directory negotiate-handler.sh
#            globs, which is the actual defect. This one catches `clean` too:
#            transient or not, untrusted input does not belong in the inbox.
#
# So `clean` with a temp path outside the project tree stays legal, and both
# messages state something true.
_body_retain_re='^[[:space:]]*client_body_in_file_only[[:space:]]+on([[:space:]]|;)'
_body_inbox_re='^[[:space:]]*client_body_temp_path[[:space:]]+[^;]*(negotiate-inbox|data/comms)'
_body_retain_fails=0
for _brs in "${MARVIN_DIR}/setup/nginx-site.conf" "${MARVIN_DIR}/setup/bootstrap.sh"; do
    [[ -r "$_brs" ]] || continue
    if grep -qE "$_body_retain_re" "$_brs" 2>/dev/null; then
        test_fail "nginx source never removes request-body temp files (client_body_in_file_only on): $(basename "$_brs")"
        _body_retain_fails=$((_body_retain_fails + 1))
    fi
    if grep -qE "$_body_inbox_re" "$_brs" 2>/dev/null; then
        test_fail "nginx source writes raw request bodies into the handler's inbox (client_body_temp_path): $(basename "$_brs")"
        _body_retain_fails=$((_body_retain_fails + 1))
    fi
done
if [[ "$_body_retain_fails" -eq 0 ]]; then
    test_pass "nginx sources do not deposit raw request bodies in the negotiate inbox"
fi

_nginx_live_site="/etc/nginx/sites-available/marvin"
if [[ -r "$_nginx_live_site" ]] \
    && grep -qE "$_body_retain_re|$_body_inbox_re" "$_nginx_live_site" 2>/dev/null; then
    test_warn "live nginx config still deposits raw request bodies in the negotiate inbox — reload after deploying the fixed nginx-site.conf (#854)"
fi

# Residue: nginx temp bodies are extension-less numeric names, so any non-*.json
# file in the inbox is either retained-body leftovers or something stranger.
# WARN-only — the handler ignores them, and deleting evidence is not a test's job.
_inbox_dir="${COMMS_DIR}/negotiate-inbox"
if [[ -d "$_inbox_dir" ]]; then
    # Assignment fallback, not `|| echo` — a bare `$(find | wc)` under
    # `set -euo pipefail` + the ERR trap would abort the whole suite if the dir
    # were ever unreadable (the §1d crash class, and the #841 fallback shape).
    _inbox_residue=$(find "$_inbox_dir" -maxdepth 1 -type f ! -name '*.json' 2>/dev/null | wc -l) || _inbox_residue=0
    if [[ "${_inbox_residue:-0}" -gt 0 ]]; then
        test_warn "negotiate inbox holds ${_inbox_residue} non-JSON file(s) — retained nginx request bodies (#854)"
    else
        test_pass "negotiate inbox holds no retained request bodies"
    fi
fi

# ─── 10. Security scoring system ──────────────────────────────────────────────
# Grades the server A-F across multiple security dimensions

marvin_log "INFO" "Self-test: computing security score"

SEC_SCORE=100
SEC_DETAILS=()

# 9a. SSH root access (rkhunter flags this as a warning)
if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null; then
    SEC_DETAILS+=("ssh_root_login: disabled (+0)")
elif grep -q "^PermitRootLogin prohibit-password" /etc/ssh/sshd_config 2>/dev/null; then
    SEC_DETAILS+=("ssh_root_login: key-only (-5)")
    SEC_SCORE=$((SEC_SCORE - 5))
else
    SEC_DETAILS+=("ssh_root_login: allowed (-15)")
    SEC_SCORE=$((SEC_SCORE - 15))
fi

# 9b. Firewall active
if ufw status 2>/dev/null | grep -q "Status: active"; then
    SEC_DETAILS+=("firewall: active (+0)")
else
    SEC_DETAILS+=("firewall: inactive (-20)")
    SEC_SCORE=$((SEC_SCORE - 20))
fi

# 9c. Fail2ban running with jails
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    jail_count=$(fail2ban-client status 2>/dev/null | grep -oP 'Number of jail:\s+\K\d+' || echo 0)
    if [[ "$jail_count" -ge 2 ]]; then
        SEC_DETAILS+=("fail2ban: ${jail_count} jails active (+0)")
    else
        SEC_DETAILS+=("fail2ban: only ${jail_count} jail (-5)")
        SEC_SCORE=$((SEC_SCORE - 5))
    fi
else
    SEC_DETAILS+=("fail2ban: not running (-15)")
    SEC_SCORE=$((SEC_SCORE - 15))
fi

# 9d. SSL certificates valid
cert_days=0
if [[ -f /etc/letsencrypt/live/robot-marvin.cz/fullchain.pem ]]; then
    cert_expiry=$(openssl x509 -enddate -noout -in /etc/letsencrypt/live/robot-marvin.cz/fullchain.pem 2>/dev/null | cut -d= -f2)
    if [[ -n "$cert_expiry" ]]; then
        cert_epoch=$(date -d "$cert_expiry" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        cert_days=$(( (cert_epoch - now_epoch) / 86400 ))
    fi
fi
if [[ "$cert_days" -gt 30 ]]; then
    SEC_DETAILS+=("ssl_cert: valid ${cert_days}d (+0)")
elif [[ "$cert_days" -gt 7 ]]; then
    SEC_DETAILS+=("ssl_cert: expiring in ${cert_days}d (-5)")
    SEC_SCORE=$((SEC_SCORE - 5))
elif [[ "$cert_days" -gt 0 ]]; then
    SEC_DETAILS+=("ssl_cert: critical — ${cert_days}d left (-15)")
    SEC_SCORE=$((SEC_SCORE - 15))
else
    SEC_DETAILS+=("ssl_cert: expired or missing (-25)")
    SEC_SCORE=$((SEC_SCORE - 25))
fi

# 9e. Unattended upgrades enabled
if dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
    SEC_DETAILS+=("unattended_upgrades: enabled (+0)")
else
    SEC_DETAILS+=("unattended_upgrades: missing (-10)")
    SEC_SCORE=$((SEC_SCORE - 10))
fi

# 9f. Security scan results (from security-scan.sh)
# Validate JSON before extracting fields — a corrupt latest-scan.json (e.g.
# from a buggy run that wrote malformed values like "0\n0") would otherwise
# crash self-test under `set -e` with jq exit 5. Fall through to the
# "no data" branch instead, so self-test still produces a report.
LATEST_SCAN="${DATA_DIR}/security/latest-scan.json"
if [[ -f "$LATEST_SCAN" ]] && jq empty "$LATEST_SCAN" 2>/dev/null; then
    # Read the ACTUAL rootkit-scanner verdicts, not overall_status. overall_status
    # flips to "warnings" for reasons unrelated to rootkits — pending apt security
    # updates, unexpected listening ports, world-writable files (issue: it was
    # mis-attributing all of those to "rootkit_scan", and even double-counting
    # world-writable files, which are scored separately below).
    rk_status=$(jq -r '.rkhunter.status // "unknown"' "$LATEST_SCAN" 2>/dev/null)
    ck_status=$(jq -r '.chkrootkit.status // "unknown"' "$LATEST_SCAN" 2>/dev/null)
    rk_infected=$(jq -r '.rkhunter.infected // 0' "$LATEST_SCAN" 2>/dev/null)
    ck_infected=$(jq -r '.chkrootkit.infected // 0' "$LATEST_SCAN" 2>/dev/null)
    [[ "$rk_infected" =~ ^[0-9]+$ ]] || rk_infected=0
    [[ "$ck_infected" =~ ^[0-9]+$ ]] || ck_infected=0
    scan_infected=$((rk_infected + ck_infected))
    world_writable=$(jq -r '.file_integrity.world_writable_count // 0' "$LATEST_SCAN" 2>/dev/null)
    [[ "$world_writable" =~ ^[0-9]+$ ]] || world_writable=0
    # Score only ACTIONABLE pending security updates. A phased-deferred update
    # is Ubuntu deliberately throttling a rollout — unattended-upgrades applies
    # it automatically once this host's phase is reached — so it is not a
    # hardening deficiency and should not dock the grade (same accuracy spirit
    # as splitting rootkit_scan out of overall_status). Falls back to the total
    # `upgradable_security` when the new actionable field is absent (older scan
    # JSON), preserving prior behavior; then to 0.
    sec_updates=$(jq -r '.cve_monitoring.upgradable_security_actionable // .cve_monitoring.upgradable_security // 0' "$LATEST_SCAN" 2>/dev/null)
    [[ "$sec_updates" =~ ^[0-9]+$ ]] || sec_updates=0

    if [[ "$scan_infected" -gt 0 ]]; then
        SEC_DETAILS+=("rootkit_scan: INFECTED (-40)")
        SEC_SCORE=$((SEC_SCORE - 40))
    elif [[ "$rk_status" == "warnings" || "$ck_status" == "warnings" ]]; then
        SEC_DETAILS+=("rootkit_scan: warnings (-5)")
        SEC_SCORE=$((SEC_SCORE - 5))
    else
        SEC_DETAILS+=("rootkit_scan: clean (+0)")
    fi

    # Pending security updates — a distinct posture concern that was previously
    # invisible (folded into the mislabeled rootkit_scan line via overall_status).
    # Now scored on its own so the penalty is correctly attributed and a
    # genuinely clean rootkit scan no longer hides outstanding patches.
    if [[ "$sec_updates" -gt 0 ]]; then
        SEC_DETAILS+=("pending_security_updates: ${sec_updates} (-5)")
        SEC_SCORE=$((SEC_SCORE - 5))
    else
        SEC_DETAILS+=("pending_security_updates: none (+0)")
    fi

    if [[ "$world_writable" -gt 0 ]]; then
        SEC_DETAILS+=("world_writable_files: ${world_writable} (-5)")
        SEC_SCORE=$((SEC_SCORE - 5))
    else
        SEC_DETAILS+=("world_writable_files: none (+0)")
    fi
else
    SEC_DETAILS+=("rootkit_scan: no data (-10)")
    SEC_SCORE=$((SEC_SCORE - 10))
fi

# 9g. Password authentication disabled for SSH
if grep -qE "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
    SEC_DETAILS+=("ssh_password_auth: disabled (+0)")
else
    SEC_DETAILS+=("ssh_password_auth: enabled (-10)")
    SEC_SCORE=$((SEC_SCORE - 10))
fi

# 9h. security.txt Expires field (RFC 9116 — file is invalid once Expires is in the past)
SECURITY_TXT="${MARVIN_DIR}/web/public/.well-known/security.txt"
if [[ -f "$SECURITY_TXT" ]]; then
    sec_expires=$(grep -m1 -iE '^Expires:' "$SECURITY_TXT" 2>/dev/null | sed -E 's/^[Ee]xpires:[[:space:]]*//' | tr -d '\r' || true)
    if [[ -n "$sec_expires" ]]; then
        # Strip fractional seconds (e.g. .000Z) — older GNU date refuses to parse them.
        # Bug #671: epoch-0 fallback would otherwise score "expired (-10)" indefinitely.
        sec_expires_clean=$(printf '%s' "$sec_expires" | sed -E 's/\.[0-9]+(Z|[+-][0-9:]+)?$/\1/')
        sec_expires_epoch=$(date -d "$sec_expires_clean" +%s 2>/dev/null || echo 0)
        sec_now_epoch=$(date +%s)
        if [[ "$sec_expires_epoch" -eq 0 ]]; then
            SEC_DETAILS+=("security_txt: unparseable Expires '${sec_expires}' (-2)")
            SEC_SCORE=$((SEC_SCORE - 2))
        else
            sec_days=$(( (sec_expires_epoch - sec_now_epoch) / 86400 ))
            if [[ "$sec_days" -gt 90 ]]; then
                SEC_DETAILS+=("security_txt: valid ${sec_days}d (+0)")
            elif [[ "$sec_days" -gt 30 ]]; then
                SEC_DETAILS+=("security_txt: expiring in ${sec_days}d (-2)")
                SEC_SCORE=$((SEC_SCORE - 2))
            elif [[ "$sec_days" -gt 0 ]]; then
                SEC_DETAILS+=("security_txt: critical — ${sec_days}d left (-5)")
                SEC_SCORE=$((SEC_SCORE - 5))
            else
                SEC_DETAILS+=("security_txt: expired (-10)")
                SEC_SCORE=$((SEC_SCORE - 10))
            fi
        fi
    else
        SEC_DETAILS+=("security_txt: malformed — no Expires field (-2)")
        SEC_SCORE=$((SEC_SCORE - 2))
    fi
fi

# Clamp score to 0-100
[[ "$SEC_SCORE" -lt 0 ]] && SEC_SCORE=0

# Grade
if [[ "$SEC_SCORE" -ge 90 ]]; then
    SEC_GRADE="A"
elif [[ "$SEC_SCORE" -ge 80 ]]; then
    SEC_GRADE="B"
elif [[ "$SEC_SCORE" -ge 65 ]]; then
    SEC_GRADE="C"
elif [[ "$SEC_SCORE" -ge 50 ]]; then
    SEC_GRADE="D"
else
    SEC_GRADE="F"
fi

test_pass "security score: ${SEC_SCORE}/100 (grade ${SEC_GRADE})"

# Write security score JSON
SECURITY_DIR="${DATA_DIR}/security"
mkdir -p "$SECURITY_DIR"
jq -n \
    --arg ts "$NOW" \
    --argjson score "$SEC_SCORE" \
    --arg grade "$SEC_GRADE" \
    '{timestamp: $ts, score: $score, grade: $grade, details: $ARGS.positional}' \
    --args -- "${SEC_DETAILS[@]}" \
    > "${SECURITY_DIR}/security-score.json.tmp" \
    && mv "${SECURITY_DIR}/security-score.json.tmp" "${SECURITY_DIR}/security-score.json"
chmod 644 "${SECURITY_DIR}/security-score.json"

# ─── Report ───────────────────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL + WARN))

echo ""
echo "═══════════════════════════════════════════"
echo " Marvin Self-Test Report — ${NOW}"
echo "═══════════════════════════════════════════"
echo ""
for r in "${RESULTS[@]}"; do
    echo "$r"
done
echo ""
echo "───────────────────────────────────────────"
echo " Total: ${TOTAL} | Pass: ${PASS} | Fail: ${FAIL} | Warn: ${WARN}"
echo " Security Score: ${SEC_SCORE}/100 (Grade: ${SEC_GRADE})"
echo "═══════════════════════════════════════════"

# Save report as JSON
cat > "${DATA_DIR}/self-test.json" << EOF
{
  "timestamp": "${NOW}",
  "total": ${TOTAL},
  "pass": ${PASS},
  "fail": ${FAIL},
  "warn": ${WARN},
  "grade": "$(if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then echo "A"; elif [[ $FAIL -eq 0 ]]; then echo "B"; elif [[ $FAIL -lt 3 ]]; then echo "C"; else echo "F"; fi)",
  "security_score": ${SEC_SCORE},
  "security_grade": "${SEC_GRADE}"
}
EOF

marvin_log "INFO" "Self-test complete: ${PASS} pass, ${FAIL} fail, ${WARN} warn | Security: ${SEC_GRADE} (${SEC_SCORE}/100)"

# Exit with failure if any test failed
[[ "$FAIL" -eq 0 ]]
