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

# _code_only <file>
#   Echo <file> with full-line comments blanked out, so that an assertion about
#   a construct cannot be satisfied by prose *describing* that construct.
#
#   This is the third time this class has been reintroduced by code written to
#   prevent it (#858, #887, #890 §9k), and the nearest instance — §9f below —
#   sat four lines from the comment stating the rule. network-discovery.sh:209
#   is a comment reading "`.marvin_health_probe == true` happens to land on one
#   physical line today"; the runtime gate it describes is at line 219. Grep the
#   raw file and deleting 219 leaves §9f green. A guard that cannot tell a fix
#   from a description of a fix is worse than no guard, because it reports a
#   specific green.
#
#   Fails (returns 1, echoes nothing) when the file is unreadable or contains no
#   code at all, so that callers can distinguish "the marker is missing" from
#   "the scan never ran" instead of collapsing both into a silent pass. Callers
#   MUST check the exit status; `x=$(_code_only f) || true` reintroduces exactly
#   the bug this exists to close.
#
#   Deliberately only strips *full-line* comments: a trailing `# ...` on a line
#   of real code cannot make an absent construct look present, and stripping it
#   correctly would require parsing quote state, which has already false-FAILed
#   twice here (#875, #887).
_code_only() {
    local _co_file="$1" _co_out
    [[ -r "$_co_file" ]] || return 1
    _co_out=$(sed 's/^[[:space:]]*#.*$//' "$_co_file" 2>/dev/null) || return 1
    # A file of nothing but comments normalizes to whitespace, not to "".
    [[ -n "${_co_out//[[:space:]]/}" ]] || return 1
    printf '%s\n' "$_co_out"
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
# RATCHET, not a wall. When this shipped, the two PRs fixing the five sites then
# on main (#844, #846) were unmerged, and #855 concluded the detector therefore
# could not ship — a suite that is red for a reason nobody can act on is worse
# than no test. So known-pending sites were listed below and reported as WARN,
# while anything NOT listed was a FAIL: main was protected against a sixth
# instance immediately rather than after two human merges.
#
# Keyed by a hash of the whitespace-normalized statement, not by line number, so
# an edit above a known site does not read as a new defect. A fixed statement's
# key changes, so it drops out of the baseline by itself — reported as a stale
# WARN telling whoever merged the fix to delete the line.
#
# THE BASELINE IS NOW EMPTY, and that is the completed end state of #855, not an
# oversight. #844 (a45aaa0) and #846 (7352d2b) are both merged; the scanner exits
# 0 against this tree with zero hits, and all five entries duly reported as stale
# on 2026-07-28. Every excuse is spent: any hit from here on matches no entry and
# is a FAIL, which is exactly the property the baseline was always meant to decay
# into. Do NOT re-add an entry to silence a new finding — a reintroduction is the
# sixth instance this section exists to stop. The array itself stays (both loops
# below iterate it, and `"${arr[@]}"` on an empty array is safe under `set -u` on
# bash 4.4+; verified on this host's 5.2.21) so that a future genuinely-pending
# fix has somewhere to go without restructuring the check.
#
# Fields: basename | statement key | note. Split with `IFS='|' read -r f k note`
# so a note containing a pipe lands wholly in the third field and can never be
# mistaken for part of the key.
_PIPEFAIL_KNOWN=()

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

# ─── 1j. process-substitution producers that fail silently ───────────────────
# `set -euo pipefail` and the ERR trap do NOT reach inside `< <(...)`. If the
# producer dies, the loop body simply never runs and the script continues at
# exit 0 — a step that FAILED is indistinguishable from a step that found
# NOTHING (#858, #866, #872, #873). The `2>/dev/null` on most of these sites
# removes the last evidence.
#
# The live case that motivated this ratchet: network-discovery.sh pinged peers
# from `.peers[].url`, but peers.json migrated to `.domain` around 2026-03-24.
# jq stayed happy (valid file, valid query, empty result), so the loop ran zero
# times and every run read exactly like "no peers configured" — for 126 days.
# Note exit-code capture would NOT have caught it: jq exited 0. Only a
# post-loop emptiness check does. That is what this section enforces.
#
# Scope: producers containing `jq` or a real pipeline. Plain `find` producers
# (33 sites) fail rarely enough to deprioritise. Known gap: `git`-only
# producers (fix-issues.sh:44,320) are failure-capable but not yet counted.
#
# This is a BASELINE RATCHET, not a clean-tree assertion: the count may fall,
# never rise. Burn it down by adding a real post-loop emptiness check and
# marking the site `# procsub-guarded`. The marker is opt-in and greppable so a
# reviewer can see exactly which sites claim a guard.
#
# The scan deliberately uses command substitution (which DOES propagate exit
# codes) rather than the construct it polices, and treats empty output as
# FAILURE rather than success — blocks always exist, so "found nothing" means
# the scan did not run. That is #858's exact defect, not repeated here.

marvin_log "INFO" "Self-test: checking process-substitution producers for silent-zero risk"

# 24 → 26 on merging main, and the two additions are named here rather than
# quietly absorbed, because a baseline that rises without an explanation is how
# a ratchet stops meaning anything. Neither came from this branch — verified by
# scanning both trees and diffing per file, this branch's own site count is
# unchanged:
#   log-alerting.sh:208   `ls -1t ... | head -2`     — arrived with #841/#844
#   self-test.sh:906      `grep -rhoE ... || true`   — arrived with #851 (§9f)
# The second is a real instance of the class, not an artefact: `|| true` on a
# producer IS the silent-zero idiom. If that grep ever breaks, §9f finds zero
# flags and PASSES — a check reporting clean because it could not run. NOT
# fixed here (it is another branch's code and this one already carries three
# fixes) and NOT yet tracked in an issue — recorded at the baseline itself so
# the next person to trip §1j finds the reason rather than an unexplained 26.
#
# 26 → 27 on the SECOND merge of main (eba2aad), and this one had already gone
# red: the branch as pushed reported `27 unguarded … baseline 26 — a new one was
# added` when run against its own tree, and 28 against `main`. A ratchet that
# fails on the branch introducing it is not a ratchet, it is a broken build that
# happens to be about correctness, so the accounting is written down here in the
# same shape as the 24 → 26 note above. Net +1, from two arrivals and one
# departure, all three from other PRs:
#   security-scan.sh:284  `printf … | tr ',:'`        — arrived with #879 (UFW audit)
#   security-scan.sh:288  `printf … | awk … | sort`   — arrived with #879 (UFW audit)
#   security-scan.sh:483  `echo … | tail -n +2`       — GONE with #884, which
#       replaced the outbound loop's producer with `marvin_outbound_classify
#       <<< "$outbound_output"` — a herestring into a function, no pipeline and
#       no jq, so the scan does not classify it as failure-capable. Counted as a
#       departure, not as a fix: nothing was guarded, the site simply stopped
#       matching the scope. Worth knowing, because a baseline can fall for that
#       reason too and "the number went down" is not by itself progress.
# Verified by scanning four trees with this same section and diffing per file:
# df6690d (26, PASS), this branch (27), `main` (28 — the extra is the
# network-discovery.sh:133 site this PR fixes), and the deployed tree (29).
_PROCSUB_BASELINE=27

# Walks each `done < <(` site to its matching close paren so multi-line
# producers are classified on their whole text — the §1d site above pipes on a
# continuation line, which a line-based grep scores safe and misses.
# Algorithm, in three lines, because the per-branch rationale below is long and
# a maintainer should not have to reconstruct the shape from it (review of #874):
#   state machine over all agent/*.sh at once. On `done < <(`, start collecting
#   and track paren depth; append each following line until depth hits 0, or the
#   8-line runaway cap trips, or the file ends — flush and reset at every exit.
# Every exit path PRINTS. A block that leaves without printing is a site the
# scan silently lost, which is the one outcome this section must never produce.
_ps_awk='
function pcount(s,   i, c, d) {
    d = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "(") d++
        else if (c == ")") d--
    }
    return d
}
# awk globals persist across files. A block that never balances (a stray paren
# in a continuation comment) leaves `collecting` set, and since FNR resets per
# file the 8-line runaway cap goes negative and never trips — so the leak eats
# the NEXT file whole. Measured: a leaky file followed by a file containing one
# obvious jq producer emitted zero blocks. A scanner for silent misses,
# silently missing. Reset per file (#875).
#
# Flush, do not merely reset (#875, second half): a block still open at EOF has
# never been printed, so a bare reset drops a real site silently and the
# baseline quietly ratchets DOWN — the scanner under-reporting itself, which is
# precisely the failure mode this section exists to prevent. The 8-line runaway
# cap catches an unbalanced block mid-file, but not one that opens within 8
# lines of EOF. Emit what was collected and classify it on the text so far.
FNR == 1 {
    if (collecting) print startfile ":" startline ":" buf
    collecting = 0; depth = 0; buf = ""; startline = 0
}
END { if (collecting) print startfile ":" startline ":" buf }
{
    if (collecting) {
        buf = buf " " $0
        depth += pcount($0)
        if (depth <= 0 || FNR - startline >= 8) {
            print startfile ":" startline ":" buf
            collecting = 0
        }
        next
    }
    # A comment that *documents* the pattern is not a site. The §1j commentary
    # below quotes the construct verbatim and the scanner duly counted its own
    # documentation (58 blocks → 59). Benign here (no jq, no pipe, so it never
    # reached the baseline), but a comment citing a jq producer would have
    # inflated the count. Only skip at block start — comment lines *inside* a
    # collected block still carry parens that must be counted.
    if ($0 ~ /done[ \t]*<[ \t]*<\(/ && $0 !~ /^[ \t]*#/) {
        idx = index($0, "<(")
        rest = substr($0, idx + 2)
        depth = 1 + pcount(rest)
        buf = rest
        startline = FNR
        # Record the owning file at block start. A flush running at the FNR==1
        # of the NEXT file sees FILENAME already advanced, and would blame the
        # dropped site on whichever innocent file happened to follow.
        # (No apostrophes in this program: it is a single-quoted shell string,
        # and one stray quote ends it mid-awk. Caught by bash -n, but only
        # because the wreckage happened to be a syntax error.)
        startfile = FILENAME
        if (depth <= 0) print startfile ":" startline ":" buf
        else collecting = 1
    }
}
'

# `dirname "$0"`, not `${MARVIN_DIR}` — the same rule §1i states two sections
# up and for the same reason. `common.sh` hardcodes MARVIN_DIR to the live tree
# and overrides an inherited environment, so a MARVIN_DIR-resolved ratchet
# measures whatever is DEPLOYED and not what the branch ships. That is not
# theoretical here: run from this worktree, the baseline check reported 29
# against the deployed tree while the branch's own tree holds 27. The number a
# reviewer sees has to be the number they are reviewing.
_ps_files=$(find "$(dirname "$0")" -name '*.sh' -type f 2>/dev/null) || _ps_files=""
if [[ -z "$_ps_files" ]]; then
    test_fail "procsub scan: could not enumerate agent scripts — scan did NOT run"
else
    _ps_blocks=$(printf '%s\n' "$_ps_files" | xargs -d '\n' awk "$_ps_awk" 2>/dev/null) || _ps_blocks=""
    if [[ -z "$_ps_blocks" ]]; then
        test_fail "procsub scan: enumerator produced no output — scan did NOT run"
    else
        _ps_unguarded=0
        _ps_sites=""
        while IFS= read -r _ps_line; do
            [[ -z "$_ps_line" ]] && continue
            _ps_file="${_ps_line%%:*}"
            _ps_rest="${_ps_line#*:}"
            _ps_ln="${_ps_rest%%:*}"
            _ps_prod="${_ps_rest#*:}"
            # `|| true` / `|| echo` are not pipelines — drop `||` before looking
            # for a pipe, or every guarded fallback reads as failure-capable.
            _ps_nor="${_ps_prod//||/}"
            if [[ "$_ps_nor" != *"|"* ]] && ! [[ "$_ps_prod" =~ (^|[^a-zA-Z0-9_])jq($|[^a-zA-Z0-9_]) ]]; then
                continue
            fi
            # Guard marker may sit on the `done` line or just after the loop.
            _ps_from=$(( _ps_ln > 1 ? _ps_ln - 1 : 1 ))
            _ps_win=$(sed -n "${_ps_from},$((_ps_ln + 6))p" "$_ps_file" 2>/dev/null) || _ps_win=""
            if [[ "$_ps_win" == *"procsub-guarded"* ]]; then
                continue
            fi
            _ps_unguarded=$((_ps_unguarded + 1))
            _ps_sites="${_ps_sites}  $(basename "$_ps_file"):${_ps_ln}"$'\n'
        done <<< "$_ps_blocks"

        if [[ "$_ps_unguarded" -gt "$_PROCSUB_BASELINE" ]]; then
            test_fail "procsub: ${_ps_unguarded} unguarded failure-capable producers, baseline ${_PROCSUB_BASELINE} — a new one was added"
            printf '%s' "$_ps_sites" >&2
        elif [[ "$_ps_unguarded" -lt "$_PROCSUB_BASELINE" ]]; then
            test_pass "procsub: ${_ps_unguarded} unguarded (baseline ${_PROCSUB_BASELINE}) — lower _PROCSUB_BASELINE to lock the win in"
        else
            test_pass "procsub: ${_ps_unguarded} unguarded, at baseline ${_PROCSUB_BASELINE}"
        fi
    fi
fi

# ─── 1k. self-test section inventory — sections may be removed, not vanish ───
# `self-test.sh` is the file that catches regressions in everything else, and
# until now nothing caught regressions in it. Sections have vanished twice
# without anyone deciding to remove them:
#
#   #889 — §9i (the #877 guard) was deleted by a `git merge main`, not an edit.
#          The section landed on main from #878 while the branch was open, at
#          the same line range the branch had filled with a new section, and git
#          resolved the overlapping hunk in favour of the branch. No conflict.
#   #892 — §1i's weekly-analytics shape-parity check was written over by an
#          unrelated new check that took the same letter. Same header, different
#          body, no mention anywhere.
#
# Both were caught by a human reading a diff, and in both cases the CHANGELOG
# went on describing a test that no longer existed, because prose and code merge
# independently. Three of the four open PRs edit this file concurrently and all
# of them append to the same regions, so the exposure is not hypothetical.
#
# TITLES, not just section letters. #892 kept the letter and replaced what was
# under it; an inventory of letters would have called that file complete.
#
# Not a freeze: a section may be removed by deleting its line from the manifest
# in the same commit, which is a visible, reviewable diff instead of a silent
# hunk resolution. A section present in the file but absent from the manifest is
# a WARN naming the line to add, never a FAIL — an open PR must not be able to
# turn main red by being the first to merge.
#
# Resolved via `dirname "$0"`, not ${MARVIN_DIR}: a branch-authored check that
# resolves through MARVIN_DIR asserts against the DEPLOYED tree and passes while
# the branch it ships with is broken (#855, and again in #874's §1j this same
# day). And every "could not look" path below is a FAIL that says so, rather
# than a pass by absence of evidence — a section inventory that reports clean
# because it could not read the file would be the thing it is guarding against.

marvin_log "INFO" "Self-test: checking no self-test section has silently disappeared"

_si_self="$(dirname "$0")/self-test.sh"
_si_manifest="$(dirname "$0")/lib/self-test-sections.txt"

if [[ ! -r "$_si_self" ]]; then
    test_fail "section inventory: cannot read ${_si_self} — the inventory was NOT checked (a check that could not run, not a clean tree)"
elif [[ ! -r "$_si_manifest" ]]; then
    test_fail "section inventory: cannot read ${_si_manifest} — the manifest is missing or unreadable, so no section can be reported as lost (#891)"
else
    # Command substitution, which DOES propagate exit codes, and empty output is
    # treated as failure on both sides: headers always exist and the manifest is
    # never legitimately empty, so "found nothing" means the extraction broke.
    _si_present=$(grep -oE '^# ─── [^─]+' "$_si_self" | sed 's/^# ─── //; s/ *$//' | sort -u) || _si_present=""
    _si_expected=$(grep -vE '^[[:space:]]*(#|$)' "$_si_manifest" | sed 's/ *$//' | sort -u) || _si_expected=""

    if [[ -z "$_si_present" ]]; then
        test_fail "section inventory: extracted ZERO section headers from ${_si_self} — the header format changed or the scan broke; this assertion is inert and MUST be repaired (#891)"
    elif [[ -z "$_si_expected" ]]; then
        test_fail "section inventory: the manifest contains no entries — every section would look accounted for (#891)"
    else
        _si_missing=$(comm -23 <(printf '%s\n' "$_si_expected") <(printf '%s\n' "$_si_present"))
        _si_new=$(comm -13 <(printf '%s\n' "$_si_expected") <(printf '%s\n' "$_si_present"))
        _si_count=$(printf '%s\n' "$_si_present" | grep -c .)

        if [[ -n "$_si_missing" ]]; then
            test_fail "section inventory: $(printf '%s\n' "$_si_missing" | grep -c .) recorded section(s) have disappeared from self-test.sh — if the removal was deliberate, delete the line from lib/self-test-sections.txt in the same commit (#891): $(printf '%s' "$_si_missing" | tr '\n' '|')"
        else
            test_pass "section inventory: all $(printf '%s\n' "$_si_expected" | grep -c .) recorded sections still present (${_si_count} in file)"
        fi

        if [[ -n "$_si_new" ]]; then
            test_warn "section inventory: $(printf '%s\n' "$_si_new" | grep -c .) section(s) not yet recorded — add to lib/self-test-sections.txt: $(printf '%s' "$_si_new" | tr '\n' '|')"
        fi

        # ── No two sections may claim the same letter (#904) ──────────────────
        # The arms above answer "did a section vanish?". This one answers the
        # other half of #891: "is this letter already taken?" Three collisions
        # landed in this file before noon on 2026-07-27 (#895 vs #874's §1j,
        # #890 vs #884's §9j, and §9m picked by hand-scanning the open-PR set),
        # because choosing a letter no *open PR* is using is unsound by
        # construction — that set changes underneath you whenever one merges.
        #
        # Two mechanisms, and this is only the second of them. Both branches
        # inserting their manifest line at the same position makes git raise a
        # one-line conflict at the point of allocation — cheap, obvious, and
        # exactly where the decision is being made, instead of a 188-line
        # conflict in code git can silently resolve in favour of whichever side
        # it happened to prefer. That is how #889 deleted a regression guard
        # with no warning at all. But when the two insertions are far enough
        # apart to auto-merge, nothing objects: the tree ends up with two §9k
        # blocks and a manifest that records both. This FAILs on exactly that.
        #
        # Scanned from the FILE, not the deduped title set: two sections with
        # byte-identical headers collapse under `sort -u` and would otherwise be
        # invisible here. Unlettered headers (e.g. "Test helpers") are skipped
        # by the pattern rather than by a rule — but extracting zero letters
        # from a file that visibly has them means the header format moved, so
        # that case is a FAIL naming "did not run", never a quiet pass.
        _si_letters=$(grep -oE '^# ─── [0-9]+[a-z]?\.' "$_si_self" | sed 's/^# ─── //; s/\.$//') || _si_letters=""

        if [[ -z "$_si_letters" ]]; then
            test_fail "section inventory: extracted ZERO section letters from ${_si_self} — the header format changed and the letter-collision arm DID NOT RUN (#904)"
        else
            _si_dupes=$(printf '%s\n' "$_si_letters" | sort | uniq -d) || _si_dupes=""
            if [[ -n "$_si_dupes" ]]; then
                _si_dupehdrs=""
                while IFS= read -r _si_l; do
                    [[ -z "$_si_l" ]] && continue
                    _si_dupehdrs+="$(grep -oE "^# ─── ${_si_l}\.[^─]*" "$_si_self" | sed 's/^# ─── //; s/ *$//' | paste -sd '/' -)"
                    _si_dupehdrs+="; "
                done <<< "$_si_dupes"
                test_fail "section inventory: $(printf '%s\n' "$_si_dupes" | grep -c .) section letter(s) claimed twice in self-test.sh — two branches picked the same letter and the merge kept both, so one section's guarantee now depends on which copy runs (#904): ${_si_dupehdrs}"
            else
                test_pass "section inventory: all $(printf '%s\n' "$_si_letters" | grep -c .) section letters are unique"
            fi
        fi
    fi
fi

# ─── 1l. anonymize_ips() IPv6/IPv4 masking consistency (issues #986, #1003) ──
# The two IPv6 branches used to disagree: a compressed-form address ("::")
# was fully redacted while an explicit 8-group address only had its last 4
# groups masked, leaving the /64 (a standard single-LAN allocation) intact —
# weaker than the IPv4 rule three lines below it, which masks to a /24. Fixed
# by having both branches redact the whole address. This asserts the two
# spellings of the same address now produce the identical result, and that
# IPv4 masking (a different, deliberately looser policy) is unaffected.
#
# The /proxy/... case guards #1003: the IPv4 catch-all used to spare any IP
# preceded by "/" (to avoid mangling UA version strings like
# "Chrome/140.0.0.0"), which let a slash-prefixed IP in a path-like field
# reach a public endpoint unredacted.
#
# Sourced via `dirname "$0"` (as §1g does) so the check is meaningful on a
# branch worktree, not only post-merge.

marvin_log "INFO" "Self-test: checking anonymize_ips() IPv6/IPv4 masking"

_lib_common="$(dirname "$0")/common.sh"
if [[ ! -f "$_lib_common" ]]; then
    test_fail "anonymize_ips: common.sh not found at ${_lib_common}"
else
    _anon() {
        # shellcheck source=/dev/null  # path is runtime-resolved (branch or live tree)
        ( source "$_lib_common" >/dev/null 2>&1 && printf '%s' "$1" | anonymize_ips )
    }
    _anon_failures=0
    while IFS='|' read -r _in _want; do
        [[ -z "$_want" ]] && continue
        _got=$(_anon "$_in") || _got="<error>"
        if [[ "$_got" != "$_want" ]]; then
            test_fail "anonymize_ips: '${_in}' -> ${_got} (expected ${_want})"
            _anon_failures=$((_anon_failures + 1))
        fi
    done <<'ANON_CASES'
2001:0db8:85a3:1234:5678:9abc:def0:1111|[IPv6:REDACTED]
2a01:430:17:1::ffff:4a1|[IPv6:REDACTED]
2001:0db8:0000:0000:0000:0000:0000:0001|[IPv6:REDACTED]
2001:db8::1|[IPv6:REDACTED]
::1|[IPv6:REDACTED]
203.0.113.47|203.0.113.X
/proxy/203.0.113.77|/proxy/203.0.113.X
ANON_CASES
    # The two spellings of the same address (full-form vs. compressed) must
    # collapse to the identical redaction — that agreement is the actual bug
    # #986 reported, not just each branch individually returning REDACTED.
    _full_form=$(_anon "2001:0db8:0000:0000:0000:0000:0000:0001") || _full_form="<error>"
    _compressed=$(_anon "2001:db8::1") || _compressed="<error>"
    if [[ "$_full_form" != "$_compressed" ]]; then
        test_fail "anonymize_ips: full-form (${_full_form}) and compressed (${_compressed}) spellings of the same address disagree"
        _anon_failures=$((_anon_failures + 1))
    fi
    if [[ "$_anon_failures" -eq 0 ]]; then
        test_pass "anonymize_ips: IPv6 full-form and compressed addresses redact identically (#986)"
    fi
    unset -f _anon
fi

# ─── 1m. github_create_issue duplicate guard (#945) ──────────────────────────
# #942 and #943 were filed 31 seconds apart with byte-identical bodies — two
# complete github_create_issue() calls, each returning 201. The guard added for
# that has TWO ways to be wrong and they are not symmetric: failing to suppress
# costs a duplicate in the queue; suppressing when it should not silently
# destroys a finished bug report. So half these cases assert the guard FIRES
# and half assert it stays QUIET, and the quiet half is the important half.
#
# Drives the real github_create_issue() with github_list_issues/github_api
# stubbed, so what is asserted is the shipped control flow rather than a
# re-implementation of the jq filter that could drift from it. The stubbed POST
# answers #999: a result of 999 means "created", 942 means "suppressed", so one
# observation distinguishes them without inspecting internal state.
#
# Sourced via `dirname "$0"` (as §1g) so it asserts on the library shipping
# beside this test, and run in a subshell so github.sh's token export cannot
# leak into the rest of the suite.

marvin_log "INFO" "Self-test: checking github_create_issue duplicate guard"

_lib_github_dup="$(dirname "$0")/lib/github.sh"
if [[ ! -f "$_lib_github_dup" ]]; then
    test_fail "dup-guard: lib/github.sh not found at ${_lib_github_dup}"
else
    # Deliberately NO `grep -q _github_find_open_issue_by_title` pre-check: a
    # grep for a function name matches the comment that mentions it just as
    # happily as the code (#889, #892). A deleted guard is caught below by the
    # duplicate coming back as #999 instead of #942, which is behaviour.
    # $1 = open-issue listing the stub returns, $2 = title to file,
    # $3 = "fail" to make the listing fetch fail outright.
    _dup_probe() {
        local _fixture="$1" _title="$2" _mode="${3:-ok}"
        (
            # shellcheck source=/dev/null  # runtime-resolved (branch or live tree)
            source "$_lib_github_dup" >/dev/null 2>&1 || exit 90
            marvin_log() { :; }
            github_list_issues() {
                [[ "$_mode" != "fail" ]] || return 1
                printf '%s' "$_fixture"
            }
            github_api() {
                [[ "$1" == "POST" ]] || return 1
                printf '{"number":999,"html_url":"https://example.invalid/999"}'
            }
            github_create_issue "$_title" "a body" "" 2>/dev/null | jq -r '.number // "none"'
        )
    }

    # Same drive, reporting the duplicate marker rather than the number.
    # Exit 0 now means "created OR suppressed", so this field is the only
    # thing that separates them for a caller — github-interact.sh counts
    # ACTION_COUNT and logs "Created issue" off it.
    _dup_marker() {
        local _fixture="$1" _title="$2"
        (
            # shellcheck source=/dev/null  # runtime-resolved (branch or live tree)
            source "$_lib_github_dup" >/dev/null 2>&1 || exit 90
            marvin_log() { :; }
            github_list_issues() { printf '%s' "$_fixture"; }
            github_api() {
                [[ "$1" == "POST" ]] || return 1
                printf '{"number":999,"html_url":"https://example.invalid/999"}'
            }
            github_create_issue "$_title" "a body" "" 2>/dev/null \
                | jq -r '.marvin_duplicate_suppressed // "absent"'
        )
    }

    _dup_title='The same issue was filed twice, 30 seconds apart'
    _dup_open="[{\"number\":942,\"title\":\"${_dup_title}\",\"html_url\":\"https://example.invalid/942\",\"pull_request\":null}]"
    _dup_other='[{"number":900,"title":"something else entirely","html_url":"https://example.invalid/900","pull_request":null}]'
    # Same title, but it is a PULL REQUEST — GET /issues returns PRs too, and
    # this repo routinely has more open PRs than issues.
    _dup_as_pr="[{\"number\":941,\"title\":\"${_dup_title}\",\"html_url\":\"https://example.invalid/941\",\"pull_request\":{\"url\":\"x\"}}]"

    _dup_failures=0
    _dup_assert() {
        local _label="$1" _want="$2" _got="$3"
        if [[ "$_got" != "$_want" ]]; then
            test_fail "dup-guard: ${_label} -> ${_got} (expected ${_want})"
            _dup_failures=$((_dup_failures + 1))
        fi
    }

    # --- the guard must FIRE ---
    _g=$(_dup_probe "$_dup_open" "$_dup_title") || _g="<error>"
    _dup_assert "exact-title duplicate is suppressed" "942" "$_g"
    _g=$(_dup_probe "$_dup_open" "   ${_dup_title}  ") || _g="<error>"
    _dup_assert "whitespace-padded duplicate is suppressed" "942" "$_g"

    # --- the guard must stay QUIET (each of these, wrong, eats a bug report) ---
    _g=$(_dup_probe "$_dup_other" "$_dup_title") || _g="<error>"
    _dup_assert "unrelated open issue does not block" "999" "$_g"
    _g=$(_dup_probe "$_dup_as_pr" "$_dup_title") || _g="<error>"
    _dup_assert "same title on an open PR does not block (.pull_request)" "999" "$_g"
    _g=$(_dup_probe "[]" "$_dup_title") || _g="<error>"
    _dup_assert "empty issue list does not block" "999" "$_g"
    _g=$(_dup_probe '{"message":"Bad credentials"}' "$_dup_title") || _g="<error>"
    _dup_assert "non-array error body does not block (fail open)" "999" "$_g"
    _g=$(_dup_probe "" "$_dup_title" "fail") || _g="<error>"
    _dup_assert "failed lookup does not block (fail open)" "999" "$_g"

    # --- a suppression must be distinguishable from a creation ---
    # Without this the caller logs "Created issue: …" for an issue it did not
    # create, corrupting the same log whose `Created issue #NNN` lines are the
    # evidence #945 was built from.
    _g=$(_dup_marker "$_dup_open" "$_dup_title") || _g="<error>"
    _dup_assert "suppressed result is marked" "true" "$_g"
    _g=$(_dup_marker "$_dup_other" "$_dup_title") || _g="<error>"
    _dup_assert "genuinely created result is NOT marked" "absent" "$_g"

    # And the caller must actually read the marker. Structural, not
    # behavioural — the discrimination is inline in a 300-line script. Matched
    # only on lines whose first non-blank character is not `#`, because a grep
    # for the field name matches the paragraph explaining it (#889, #892).
    _gi_path="$(dirname "$0")/github-interact.sh"
    if [[ ! -f "$_gi_path" ]]; then
        test_fail "dup-guard: github-interact.sh not found at ${_gi_path} — the caller-side check did NOT run"
        _dup_failures=$((_dup_failures + 1))
    elif ! grep -qE '^[[:space:]]*[^#[:space:]].*marvin_duplicate_suppressed' "$_gi_path"; then
        test_fail "dup-guard: github-interact.sh has no CODE reference to marvin_duplicate_suppressed — a suppressed duplicate is being counted and logged as a creation (#945)"
        _dup_failures=$((_dup_failures + 1))
    fi

    if [[ "$_dup_failures" -eq 0 ]]; then
        test_pass "dup-guard: github_create_issue suppresses same-title duplicates, marks them, and fails open (10 cases)"
    fi
    unset -f _dup_probe _dup_marker _dup_assert
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

    # The runtime checks above cannot see the failure that produced them. A
    # carry-over field hardcoded in the beacon template yields a populated,
    # well-formed, perfectly fresh document — it is simply the wrong value, so
    # `born populated` and `last_seen fresh` both pass while the beacon says
    # something nobody wrote. That has now happened twice: `born` was a literal
    # until #851, `message` until #936, and the second sat untouched through the
    # whole of the first being fixed. This asserts the property that separates
    # the two — the template SUBSTITUTES each carry-over field rather than
    # hardcoding it.
    #
    # Read via `dirname "$0"`, not ${MARVIN_DIR} as the recovery-wiring arm
    # below does: ${MARVIN_DIR} is hardcoded to the deployed tree, so a
    # branch-authored check that used it would grade main and pass on this very
    # branch while the defect it detects was still in it.
    #
    # Two properties, because "carried" alone is not enough. A carry-over field
    # must ALSO be substituted unquoted: the value is captured as JSON (`jq -c`)
    # and brings its own quoting, so a `"${BEACON_BORN}"` re-wrapped in the
    # heredoc's literal quotes emits a MALFORMED document for any value holding
    # a `"`, a backslash or a newline.
    #
    # An earlier revision of this comment waved that case off as "the `jq empty`
    # validation gate does catch it". It discards it, which is not the same
    # thing: the gate keeps the previous identity.json, and the previous
    # identity.json is where the offending value lives, so the next run reads it
    # back and discards again. `last_seen` freezes while the stale beacon keeps
    # being served. Nothing recovers from that without a hand edit, so the
    # quoting has to be asserted here rather than deferred to the gate.
    _nd_tmpl="$(dirname "$0")/network-discovery.sh"
    _nd_block=""
    if [[ -r "$_nd_tmpl" ]]; then
        _nd_block=$(awk '/^cat > .*identity\.json\.tmp.*<< *EOF$/{f=1;next} f&&/^EOF$/{exit} f' \
                        "$_nd_tmpl" 2>/dev/null || true)
    fi
    if [[ -z "$_nd_block" ]]; then
        # Extraction failing must not read as "nothing wrong here".
        test_fail "beacon template: could not extract the identity.json heredoc from ${_nd_tmpl} — carry-over check DID NOT RUN"
    else
        _co_bad=0
        for _co_field in born message; do
            _co_line=$(grep -E "^[[:space:]]*\"${_co_field}\"[[:space:]]*:" <<< "$_nd_block" || true)
            if [[ -z "$_co_line" ]]; then
                test_fail "beacon template: no \"${_co_field}\" line in the beacon heredoc — a carry-over field has vanished from the published document"
                _co_bad=$((_co_bad + 1))
            elif [[ "$_co_line" != *'${'* ]]; then
                test_fail "beacon template: \"${_co_field}\" is hardcoded in the beacon heredoc — every run overwrites the value carried forward from the previous one"
                _co_bad=$((_co_bad + 1))
            elif [[ "$_co_line" == *'"${'* ]]; then
                test_fail "beacon template: \"${_co_field}\" is substituted inside literal quotes — the value already carries its own JSON quoting, so a \" or backslash in it emits a malformed beacon that the validation gate discards on every subsequent run"
                _co_bad=$((_co_bad + 1))
            fi
        done
        if [[ "$_co_bad" -eq 0 ]]; then
            test_pass "beacon template: carry-over fields (born, message) are substituted unquoted, not hardcoded or re-quoted"
        fi
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
    # Comment-stripped, or the assertion is satisfied by the block of prose
    # directly above the dispatch that explains what --beacon-only is for.
    if ! _nd_code=$(_code_only "$_nd_script"); then
        test_fail "beacon recovery: network-discovery.sh yielded no code to scan for flag handling — check could not run"
        _nd_code=""
    fi
    _nd_flags_checked=0
    _nd_flags_bad=0
    while IFS= read -r _nd_flag; do
        [[ -n "$_nd_flag" ]] || continue
        [[ -n "$_nd_code" ]] || break
        _nd_flags_checked=$((_nd_flags_checked + 1))
        if ! grep -q -- "\"${_nd_flag}\"" <<< "$_nd_code"; then
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
    _nl_norm=""
    _nl_scan_ok=1
    if _nl_code=$(_code_only "$_nl_file"); then
        _nl_norm=$(tr -s '[:space:]' ' ' <<< "$_nl_code")
    else
        _nl_scan_ok=0
    fi
    # Does the gate still exist in network-discovery.sh at all? If someone drops
    # the pre-condition, the probe starts polluting the inbox again (#852) and
    # this test must not quietly keep passing on the listener half alone.
    #
    # Comment-stripped for the same reason the listener half is, and it is not
    # hypothetical here: network-discovery.sh:209 is a comment quoting this very
    # marker while explaining the gate at line 219. Grepping the raw file, this
    # assertion passes on a file whose runtime gate has been deleted (#899).
    _nd_code=""
    _nd_scan_ok=1
    _nd_code=$(_code_only "$_nd_file") || _nd_scan_ok=0
    if [[ "$_nd_scan_ok" -eq 0 || "$_nl_scan_ok" -eq 0 ]]; then
        test_fail "beacon negotiate gate: could not extract code from network-discovery.sh and/or negotiate-listener.sh — check did not run, treat as unverified rather than green"
    elif ! grep -q 'marvin_health_probe == true' <<< "$_nd_code"; then
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

# ─── 9j. Outbound egress sampling is wired, running, and reaches the score ────
# Section letter 9j: 9h and 9i are live on main (#856/#878 merged while this
# branch was open); 9k is claimed by the open #890. 9g is free but left so,
# since #862's replacement may yet want it.
#
# This section was originally written AT 9i's line range, back when #878 was
# still open and 9i did not exist on main. The `git merge main` that followed
# resolved that overlapping hunk in favour of this branch and deleted 9i — the
# #877 regression guard — silently. Restored above (#889). A section letter
# chosen against the set of *open PRs* rather than against main is a letter that
# stops being true the moment one of them merges; check main before renumbering.
#
# Issue #882: outbound auditing took ONE `ss` sample a day, at the deadest minute
# on this box, and published the result as the day's answer. It reported zero
# outbound connections on 30 of 31 retained scans while 704 MB left the interface
# on one of them. Nothing was broken — it simply never looked, and "never looked"
# and "nothing there" produced the same output.
#
# Four things must hold for the fix to be worth anything, each a way it could rot
# back into a control that reports clean because it is blind:
#   1. the sampler is called from a script that actually runs on a tick
#   2. the call is not `|| true`-suppressed
#   3. the daily scan consults the day aggregate, not just its own instant sample
#   4. coverage status reaches overall_status (the #880 lesson: a finding that
#      only reaches marvin_log is invisible to every consumer of the reports)
# Plus a drift guard: exactly ONE copy of the classifier may exist.

marvin_log "INFO" "Self-test: checking outbound egress sampling is wired and scored"

_ob_lib="${MARVIN_DIR}/agent/lib/outbound.sh"
_ob_hm="${MARVIN_DIR}/agent/health-monitor.sh"
_ob_scan="${MARVIN_DIR}/agent/security-scan.sh"

if [[ ! -r "$_ob_lib" ]]; then
    test_warn "outbound sampling: agent/lib/outbound.sh not present — #882 fix not deployed yet, egress history is one sample/day"
else
    # (1) + (2) — wired into the 5-minute tick, failure not swallowed.
    if ! grep -q 'marvin_outbound_record_sample' "$_ob_hm" 2>/dev/null; then
        test_fail "outbound sampling: lib/outbound.sh exists but health-monitor.sh never calls marvin_outbound_record_sample — the sampler has no live caller, so the egress history stays empty and #882 is unfixed in effect"
    elif grep -qE 'marvin_outbound_record_sample[[:space:]]*(\|\|[[:space:]]*true|&>|>[[:space:]]*/dev/null)' "$_ob_hm" 2>/dev/null; then
        test_fail "outbound sampling: health-monitor.sh suppresses marvin_outbound_record_sample failures — a sampler that fails silently reproduces the exact defect #882 fixed"
    else
        test_pass "outbound sampling: health-monitor.sh (5-min cron tick) calls the sampler and does not suppress its failures"
    fi

    # (3) — the daily scan must read the aggregate, not just its own instant.
    if grep -q 'marvin_outbound_day_summary' "$_ob_scan" 2>/dev/null; then
        test_pass "outbound sampling: security-scan.sh §3d aggregates the retained samples"
    else
        test_fail "outbound sampling: security-scan.sh no longer calls marvin_outbound_day_summary — §3d is back to publishing a single instantaneous sample as the day's egress answer (#882)"
    fi

    # (4) — coverage must be able to move overall_status, or it is decoration.
    # Scoped to the gate block itself (overall_status="clean" up to the report
    # heredoc), so a passing mention of the variable elsewhere cannot satisfy it.
    if awk '/^overall_status="clean"/{f=1} f && /outbound_coverage_status/{found=1} /^cat > "\$REPORT_FILE"/{f=0} END{exit !found}' "$_ob_scan" 2>/dev/null; then
        test_pass "outbound sampling: egress coverage status participates in overall_status"
    else
        test_fail "outbound sampling: outbound_coverage_status does not reach the overall_status gate — a day the sampler never ran would score clean, which is precisely the 30-day failure in #882"
    fi

    # Drift guard — one classifier only. Two copies cannot be kept in agreement,
    # and a sampler that disagrees with its aggregator about what counts as
    # outbound produces authoritative-looking numbers that mean nothing.
    _ob_dupes=$(grep -lE '^_ip_in_docker_cidr\(\)' "${MARVIN_DIR}"/agent/*.sh "${MARVIN_DIR}"/agent/lib/*.sh 2>/dev/null | wc -l)
    if [[ "$_ob_dupes" -eq 1 ]]; then
        test_pass "outbound sampling: exactly one copy of the outbound classifier (_ip_in_docker_cidr)"
    else
        test_fail "outbound sampling: ${_ob_dupes} definitions of _ip_in_docker_cidr — the sampler and the daily aggregate can now drift on what 'outbound' means (#882/#591)"
    fi

    # Runtime — is it actually producing samples? Self-activating: only assert
    # this once the sampler is deployed, so an unmerged branch warns instead of
    # failing on a host that has not been given the code yet.
    if grep -q 'marvin_outbound_record_sample' "$_ob_hm" 2>/dev/null; then
        # Resolve the path through the library, never by rebuilding it here.
        # A second hand-written copy of the sample path is the same "two places
        # must agree" risk this PR just removed for _ip_in_docker_cidr, one file
        # over. Today the two happen to coincide — SECURITY_DIR is unset at this
        # point in self-test.sh, so _marvin_outbound_dir() also falls through to
        # ${DATA_DIR}/security — but that agreement is incidental, not designed.
        # If the fallback chain ever changes, a hardcoded copy silently starts
        # stat()ing a file nothing writes and reports "ZERO samples today"
        # forever, which is a FAIL below.
        _ob_paths_ok=true
        _ob_today=$(marvin_outbound_sample_file "$(date -u +%Y-%m-%d)") \
            || { _ob_today=""; _ob_paths_ok=false; }
        _ob_yday=$(marvin_outbound_sample_file "$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null)") \
            || { _ob_yday=""; _ob_paths_ok=false; }
        # Count RECORDS, not lines, and assign the fallback rather than echoing
        # it. Two bugs in the one line this replaces:
        #
        #   1. `$(grep -c . f || echo 0)` — `grep -c` prints 0 and THEN exits 1
        #      on no match, so the fallback appended a second document and
        #      _ob_count became "0\n0", an arithmetic error at the `-gt` below.
        #      This is the #855/#857 double-document class, and §1h caught it in
        #      this very file.
        #   2. `grep -c .` counts LINES. The sampler's records were
        #      pretty-printed (the missing `jq -c` fixed in this PR), so one
        #      sample was ~31 lines and this reported "31 samples recorded
        #      today" against 1 real sample. `^{` counts record openings, which
        #      is correct for BOTH the compact form and any legacy
        #      pretty-printed file still inside the 30-day retention window.
        _ob_count=0
        if [[ "$_ob_paths_ok" != true ]]; then
            # The path could not be resolved, so no file was ever looked at.
            # Say exactly that and assert nothing else — falling through with an
            # empty path would make both -f tests false and land on the "ZERO
            # samples today" FAIL below, reporting a definite finding from a
            # check that never ran. That collapse of "could not look" into
            # "looked and found nothing" is the shape coverage_status exists to
            # separate; it would be poor to reintroduce it in the test for it.
            test_warn "outbound sampling: could not resolve the sample file path — _marvin_outbound_dir() found none of SECURITY_DIR/DATA_DIR/MARVIN_DIR, so runtime sampling was NOT verified"
        else
            if [[ -f "$_ob_today" ]]; then
                _ob_count=$(grep -c '^{' "$_ob_today" 2>/dev/null) || _ob_count=0
            fi
            # Expected samples so far today, one per 5 minutes since 00:00 UTC.
            # Single epoch reading rather than `10#%H`/`10#%M` (#886): `10#` does
            # fix the octal crash, but two `date` calls can still straddle a
            # minute boundary and report hour N with minute 0. One cannot.
            _ob_expected=$(( (($(date -u +%s) % 86400) / 60) / 5 ))
            if [[ "$_ob_count" -gt 0 ]]; then
                _ob_errs=$(grep -c '"error"' "$_ob_today" 2>/dev/null) || _ob_errs=0
                if [[ "$_ob_errs" -gt 0 ]]; then
                    test_warn "outbound sampling: ${_ob_errs} of ${_ob_count} samples today recorded an error — gaps in the egress history"
                else
                    test_pass "outbound sampling: ${_ob_count} samples recorded today (≈${_ob_expected} expected so far)"
                fi
            elif [[ -f "$_ob_yday" ]]; then
                test_warn "outbound sampling: no samples yet today but yesterday's history exists — expected shortly after 00:00 UTC"
            elif [[ "$_ob_expected" -lt 3 ]]; then
                test_warn "outbound sampling: no samples yet — fewer than 3 ticks have elapsed since 00:00 UTC"
            else
                test_fail "outbound sampling: sampler is wired into health-monitor.sh but has produced ZERO samples today after ~${_ob_expected} ticks — egress is unmonitored and the daily audit will report coverage 'absent' (#882)"
            fi
        fi
    fi
fi

# ─── 9k. Hourly nginx error window must include the rotated log ──────────────
# Issue #860. logrotate runs daily at 00:00 local; the 00:35 run's 65-minute
# window opens at 23:30 the previous day, by which time those entries live in
# error.log.1. Reading only the live log dropped that half-hour every night,
# and dropped it invisibly — "no errors in the window" and "nobody read the
# window" render identically in the report.
#
# Source-level, deliberately: the runtime symptom appears for one run a day, at
# 00:35, and only when something was actually logged in that half-hour. A test
# that waits for those three conditions to coincide reports clean almost every
# time it runs, which is the property that let this survive undetected.
# Resolved via `dirname "$0"`, not ${MARVIN_DIR}: common.sh hardcodes the
# latter to /home/marvin/git, so a branch-authored check spelled that way
# asserts against what is *deployed* and reports on a tree this branch is
# not (#855, and again in #874's §1j the same day). Shown: against the live
# tree this section FAILs on its own branch, because main has no fix yet.
_hc="$(dirname "$0")/hourly-check.sh"
if [[ -r "$_hc" ]]; then
    # Scanned inside _nginx_error_window's body with comment lines stripped,
    # not across the whole file. The prose above the function names both
    # `error.log.1` and `UNREAD` — matching the file at large would have gone
    # on passing if the body were reverted and that comment block left behind,
    # which is a test that asserts the fix was once described rather than that
    # it is still wired in. Same defect as §9j's pre-#884 shape.
    _hc_body=$(sed -n '/^_nginx_error_window()[[:space:]]*{/,/^}/p' "$_hc" \
                 | grep -v '^[[:space:]]*#') || _hc_body=""

    if [[ -z "$_hc_body" ]]; then
        # Fail-closed: an extraction that silently yields nothing would make
        # both checks below fail for the wrong reason, or — had they been
        # written the other way round — pass for no reason at all.
        test_fail "hourly nginx window: could not extract _nginx_error_window() from ${_hc} — the function was renamed or removed, so #860/#866 are unverified rather than clean"
    else
        # The loop must actually name the rotated log, not merely mention it.
        if printf '%s\n' "$_hc_body" | grep -qE '^[[:space:]]*for .*error\.log\.1'; then
            test_pass "hourly nginx window: the read loop names the rotated error.log.1, so the 23:30–00:00 span survives logrotate (#860)"
        else
            test_fail "hourly nginx window: _nginx_error_window() does not iterate over error.log.1 — the 00:35 run's window opens at 23:30 inside a file it does not read, so that half-hour is dropped nightly (#860)"
        fi

        # The other half, from #866: an unreadable log must be reported as
        # unread. A loop over two files sharing one status flag lets the
        # readable file's success erase the unreadable one's failure, and the
        # run then prints a short window with nothing saying half of it was
        # never opened. Asserted on the emitting printf, not on the word.
        if printf '%s\n' "$_hc_body" | grep -qE 'printf.*UNREAD.*INCOMPLETE, not clean'; then
            test_pass "hourly nginx window: a log it could not read is reported as unread rather than folded into an empty window (#866)"
        else
            test_fail "hourly nginx window: _nginx_error_window() emits no unread-log notice — a log that cannot be opened is indistinguishable from a log with no errors (#866)"
        fi
    fi
else
    test_warn "hourly nginx window: ${_hc} not readable — #860/#866 checks skipped"
fi

# ─── 9l. UFW findings must reach the security-scan score (#893) ──────────────
# §9j asserts the egress-coverage half of the same rule. This is the ingress
# half, and it exists because the ingress half was already lost once: PR #884
# rewrote the `overall_status` elif chain and dropped `ufw_unexpected_count` and
# `ufw_scan_ok` out of it. Both variables were still computed, still logged, and
# still written into the JSON report — only the one field consumers actually
# read stopped reflecting them. It merged. For six hours, an inactive firewall
# (#881) and a world-open port with no EXPECTED_PORTS entry (#849, 8042/tcp for
# 154 days) both scored `overall_status="clean"`.
#
# Nothing structural stops that happening again — the terms sit in one long
# condition that every future edit to this chain rewrites wholesale. So assert
# it, scoped to the gate block itself (`overall_status="clean"` up to the report
# heredoc) so a mention of the variable anywhere else in the file — the logging
# block above it, the JSON below it, both of which survived #884 intact — cannot
# satisfy the check. That scoping is the whole point: an unscoped grep for
# `ufw_scan_ok` passes against the exact broken file this section is named for.
#
# Section letter 9l, not 9k: #890 held 9k when this was written and has since
# merged, so §9k now sits on main and directly above. Checked against main AND
# the open branches, per the trap recorded in §9j's own comment (#889/#891).
#
# That check is what the letter reservation was for, and it is not what the
# merge did. `git merge main` on this branch (24c1bed) resolved the conflict in
# self-test.sh by writing §9l over §9k's lines rather than beside them — the
# reservation was honoured in the letter and lost in the resolution, and the
# diff showed it as one 59→61 hunk with nothing named in the PR body or the
# CHANGELOG. Same shape as #889. Restored verbatim from main above (#907).

marvin_log "INFO" "Self-test: checking UFW findings participate in the security scan's overall_status"

_ufw_scan="$(dirname "$0")/security-scan.sh"

if [[ ! -r "$_ufw_scan" ]]; then
    # "Could not read the file" is not "the gate is fine". Say which one it is.
    test_fail "UFW scoring: cannot read ${_ufw_scan} — the overall_status gate was NOT verified (this is a check that could not run, not a clean result)"
else
    # Comment lines are dropped, not just the block scoped. Found by mutation:
    # with comments included, deleting the `elif [[ "$ufw_scan_ok" != true ]]`
    # arm outright still PASSED, because the explanatory comment directly above
    # it names the variable. A check satisfied by prose about the code rather
    # than the code is the #875 defect class, and it would have reported clean
    # against a gate with the arm cut out from under it.
    _ufw_gate=$(awk '
        /^overall_status="clean"/ { f = 1 }
        /^cat > "\$REPORT_FILE"/  { f = 0 }
        f && !/^[[:space:]]*#/    { print }
    ' "$_ufw_scan" 2>/dev/null) || _ufw_gate=""

    if [[ -z "$_ufw_gate" ]]; then
        test_fail "UFW scoring: could not isolate the overall_status gate block in security-scan.sh — the anchors (overall_status=\"clean\" … cat > \"\\\$REPORT_FILE\") no longer match, so this assertion is inert and MUST be repaired, not ignored"
    else
        _ufw_missing=""
        grep -q 'ufw_unexpected_count' <<< "$_ufw_gate" || _ufw_missing="ufw_unexpected_count"
        grep -q 'ufw_scan_ok' <<< "$_ufw_gate" \
            || _ufw_missing="${_ufw_missing:+${_ufw_missing}, }ufw_scan_ok"

        if [[ -z "$_ufw_missing" ]]; then
            test_pass "UFW scoring: both ufw_unexpected_count and ufw_scan_ok participate in overall_status"
        else
            test_fail "UFW scoring: ${_ufw_missing} absent from the overall_status gate — UFW findings are computed and logged but no longer scored, so an inactive firewall (#881) or an unexpected open port (#849) reports overall_status=\"clean\" (#893)"
        fi
    fi
fi

# ─── 9m. Morning blog blurb survives a technical-section-only screen hit ──────
# 2026-08-02: a routine "used the `.env` PAT directly" aside in the internal
# GitHub-issues section of the morning report tripped screen_blog_content()'s
# sensitive-file-path pattern, and because morning-check.sh screened the whole
# $OUTPUT (technical report + public blurb) as one blob, the entire day's post
# was dropped — including a fully compliant blurb. Fixed by splitting the two
# at the ---MORNING_BLOG_EN--- marker and screening them separately, mirroring
# evening-report.sh's existing per-language screening. Two things can silently
# undo that: (a) the split logic itself regressing, and (b) morning-check.sh
# going back to a single screen_blog_content call on the combined text. Assert
# both — a grep for "screen_blog_content" alone would pass against the old,
# broken, single-call version too (same class of false-clean §9l's comment
# describes: prose/incidental mentions satisfying a check that isn't actually
# wired the way it claims).

marvin_log "INFO" "Self-test: checking morning blog technical/blurb screening is split, not monolithic"

_morning_sh="$(dirname "$0")/morning-check.sh"

if [[ ! -r "$_morning_sh" ]]; then
    test_fail "morning blurb screening: cannot read ${_morning_sh} — NOT verified"
else
    _morning_screen_calls=$(grep -c 'screen_blog_content "\$MORNING_BLURB"\|screen_blog_content "\$MORNING_TECH"\|screen_blog_content "\$file_blurb"\|screen_blog_content "\$file_tech"' "$_morning_sh" 2>/dev/null || true)
    _morning_screen_calls="${_morning_screen_calls:-0}"

    if [[ "$_morning_screen_calls" -lt 4 ]]; then
        test_fail "morning blurb screening: expected separate screen_blog_content calls for MORNING_BLURB/MORNING_TECH and file_blurb/file_tech, found ${_morning_screen_calls} — technical-only hits will drop the whole day's post again (regression of the 2026-08-02 fix)"
    else
        # Functional half: reproduce the actual 2026-08-02 failure input through
        # the same split-then-screen primitive morning-check.sh now uses.
        _mb_output=$'## GitHub Issues\n- gh CLI still broken/401, used the `.env` PAT directly\n\n---MORNING_BLOG_EN---\n\nA clean poetic blurb about waking up.\n\n---MORNING_BLOG_CS---\n\nCisty blurb.'
        _mb_blurb=$(printf '%s\n' "$_mb_output" | sed -n '/---MORNING_BLOG_EN---/,$p')
        _mb_tech=$(printf '%s\n' "$_mb_output" | sed '/---MORNING_BLOG_EN---/,$d')

        if ! screen_blog_content "$_mb_blurb" "self-test-morning-blurb" >/dev/null 2>&1; then
            test_fail "morning blurb screening: clean blurb was blocked by the split screen — false positive on content containing no sensitive patterns"
        elif screen_blog_content "$_mb_tech" "self-test-morning-tech" >/dev/null 2>&1; then
            test_fail "morning blurb screening: technical section containing a sensitive-file-path match ('.env') was NOT blocked — screen_blog_content regressed"
        else
            test_pass "morning blurb screening: technical-section hit is isolated from the blurb (blurb clean, tech blocked, ${_morning_screen_calls} split screen call sites present)"
        fi
        rm -f "${BLOCKED_BLOGS_DIR:-/home/marvin/blocked-blogs}"/self-test-morning-tech-*.txt 2>/dev/null || true
    fi
fi

# ─── 9o. openapi.yaml must agree with the nginx /api/ allowlist (#883) ───────
# Section letter 9o, not 9m: by the time this rebased onto main, 9m had been
# taken by the morning-blog-blurb screening fix and 9n by the executable-bits
# check. Picked against the set actually on main at rebase time, per the same
# trap §9j's own comment warns about — a letter reserved against the *open* PR
# set stops being true the moment one of those merges first.
#
# Issue #883: `data/openapi.yaml` is published at /.well-known/openapi.yaml as
# this server's API contract, and nothing has ever compared it to what nginx
# actually serves. It had drifted in BOTH directions at once — 10 endpoints
# served by the #861 allowlist and absent from the spec, and 2 documented
# endpoints (`/api/exports/`) published as open that answer 401 — while the spec
# header claimed "all endpoints ... require no authentication".
#
# Both directions are checked, because they fail differently:
#   A. served-but-undocumented — the public surface is larger than the published
#      contract, so nobody reviewing the spec can see the real exposure.
#   B. documented-but-unserved — worse for a consumer: they build against a path
#      that does not exist, or one that silently needs a key.
#
# Everything here is resolved through `dirname "$0"`, NOT ${MARVIN_DIR}: the
# latter is hardcoded to /home/marvin/git, so a branch that fixed the spec would
# be graded against the deployed copy and pass (or fail) on the wrong file
# entirely — the trap already recorded in #855/#874/#890.
#
# Comments are stripped from the nginx config before parsing. The explanatory
# block above the allowlist names /api/blog-index.json and /api/security/... in
# prose; a parser that reads prose invents endpoints nginx does not serve, which
# is the same class of false result as #889/#892.

marvin_log "INFO" "Self-test: checking openapi.yaml against the nginx /api/ allowlist"

_od_conf="$(dirname "$0")/../setup/nginx-site.conf"
_od_spec="$(dirname "$0")/../data/openapi.yaml"

if [[ ! -r "$_od_conf" || ! -r "$_od_spec" ]]; then
    test_fail "openapi drift: cannot read setup/nginx-site.conf and/or data/openapi.yaml — the contract check DID NOT RUN (this is not a clean result)"
else
    # Expand the allowlist regex into concrete paths. Handles the two shapes the
    # config actually uses: (?:a|b|c)\.json groups, and bare literal alternatives.
    # Deliberately narrow — an unrecognised shape must yield nothing and trip the
    # emptiness check below rather than silently under-reporting the surface.
    _od_expand() {
        local b="$1" grp inner rest suffix alt
        local -a alts
        while [[ "$b" == *'(?:'* ]]; do
            grp=${b#*\(\?:}; inner=${grp%%)*}; rest=${grp#*)}
            suffix=""
            # Consume the group's suffix as well as reading it: left in place it
            # comes back around as a bare literal alternative and is emitted as
            # the nonsense path /api/.json.
            if [[ "$rest" == '\.json'* ]]; then
                suffix=".json"; rest=${rest#\\.json}
            fi
            IFS='|' read -ra alts <<< "$inner"
            for alt in "${alts[@]}"; do printf '/api/%s%s\n' "$alt" "$suffix"; done
            b=$rest
        done
        b=${b//\\./.}
        IFS='|' read -ra alts <<< "$b"
        for alt in "${alts[@]}"; do
            [[ "$alt" =~ ^[A-Za-z0-9_/.-]+$ ]] && printf '/api/%s\n' "$alt"
        done
    }

    # Everything below is scoped to the TLS server block. openapi.yaml declares
    # `servers: https://robot-marvin.cz`, so that block IS the contract. The
    # port-80 block is defense-in-depth hardening with its own
    # `location /api/exports/ { return 403; }`, and a whole-file parse reads that
    # 403 as "exports is denied" and fails the direction-B arm on a pair of
    # endpoints that are served perfectly well over HTTPS. Same server-block
    # scoping trap as the ai-negotiate location.
    _od_tls=$(awk '
        /^server[[:space:]]*\{/ { n++; next }
        n { buf[n] = buf[n] $0 "\n"; if ($0 ~ /listen[[:space:]]+(\[::\]:)?443/) tls[n] = 1 }
        END { for (i = 1; i <= n; i++) if (i in tls) printf "%s", buf[i] }
    ' "$_od_conf" | grep -vE '^[[:space:]]*#') || _od_tls=""

    if [[ -z "$_od_tls" ]]; then
        test_fail "openapi drift: could not isolate the TLS (443) server block in setup/nginx-site.conf — the contract check DID NOT RUN"
        _od_locline=""
        _od_skip=1
    else
        _od_skip=0
        _od_locline=$(printf '%s\n' "$_od_tls" \
                      | grep -oE 'location[[:space:]]+~[[:space:]]+\^/api/\(.*\)\$' \
                      | head -1) || _od_locline=""
    fi

    if [[ "$_od_skip" -eq 1 ]]; then
        : # already reported above; do not also emit a misleading pass
    elif [[ -z "$_od_locline" ]]; then
        test_fail "openapi drift: no regex /api/ allowlist found in setup/nginx-site.conf — either #861 was reverted (the /api/ surface is a denylist again) or the config shape changed and this check can no longer read it; either way it DID NOT RUN"
    else
        _od_body=${_od_locline#*^/api/(}
        _od_body=${_od_body%)\$}
        _od_served=$(_od_expand "$_od_body" | grep -vE '^/api/$|^$' | sort -u) || _od_served=""
        _od_documented=$(grep -oE '^  (/[^ :]+):' "$_od_spec" | tr -d ' :' | sort -u) || _od_documented=""

        if [[ -z "$_od_served" ]]; then
            test_fail "openapi drift: the /api/ allowlist regex was found but expanded to ZERO paths — the parser no longer understands the config shape; it DID NOT RUN (an empty served-set would otherwise make every documented path look undocumented and vice versa)"
        elif [[ -z "$_od_documented" ]]; then
            test_fail "openapi drift: data/openapi.yaml yielded ZERO paths — the spec is empty or its shape changed; the check DID NOT RUN"
        else
            _od_doc_api=$(printf '%s\n' "$_od_documented" | grep '^/api/') || _od_doc_api=""

            # ── Direction A: served but undocumented ──
            _od_undoc=$(comm -23 <(printf '%s\n' "$_od_served") <(printf '%s\n' "$_od_doc_api")) || _od_undoc=""
            if [[ -n "$_od_undoc" ]]; then
                test_fail "openapi drift: $(printf '%s\n' "$_od_undoc" | wc -l) endpoint(s) are served by the nginx /api/ allowlist but absent from data/openapi.yaml — the published contract understates the real public surface (#883): $(printf '%s' "$_od_undoc" | tr '\n' ' ')"
            else
                test_pass "openapi drift: all $(printf '%s\n' "$_od_served" | wc -l) allowlisted /api/ endpoints are documented in openapi.yaml"
            fi

            # ── Direction B: documented but not served ──
            # A documented path counts as served if it is in the allowlist, or if
            # a dedicated prefix `location` block covers it and that block does
            # not deny.
            #
            # Coverage is restricted to prefixes STRICTLY BELOW /api/ — i.e.
            # longer than "/api/" itself. Two catch-alls would otherwise make this
            # direction incapable of ever failing, which is worse than not having
            # it: `location /api/` is the deny-all, and `location /` is the
            # Next.js proxy that prefix-matches literally every path. The first
            # draft of this section excluded only /api/, and a mutation that
            # deleted peers-public.json from the allowlist while leaving it
            # documented still reported PASS — caught by mutation-testing the
            # arm, not by reading it.
            _od_serving_prefixes=$(printf '%s\n' "$_od_tls" | awk '
                /^[[:space:]]*location[[:space:]]+/ {
                    inloc = 0
                    if ($2 ~ /^\//) { p = $2; inloc = 1; seen[p] = 1 } else { p = "" }
                    next
                }
                /^[[:space:]]*}[[:space:]]*$/ { inloc = 0; p = ""; next }
                inloc && /deny all|return 403/ { denied[p] = 1 }
                END {
                    for (k in seen)
                        if (!(k in denied) && index(k, "/api/") == 1 && k != "/api/")
                            print k
                }
            ') || _od_serving_prefixes=""

            _od_unserved=""
            while IFS= read -r _od_p; do
                [[ -z "$_od_p" ]] && continue
                printf '%s\n' "$_od_served" | grep -qxF "$_od_p" && continue
                _od_covered=0
                while IFS= read -r _od_pref; do
                    [[ -z "$_od_pref" ]] && continue
                    # Fixed-string prefix test: a regex match here would fail OPEN
                    # on a path containing regex metacharacters (the /api/exports/
                    # {date}.json brace is exactly such a case).
                    if awk -v s="$_od_p" -v pre="$_od_pref" 'BEGIN{exit !(index(s,pre)==1)}'; then
                        _od_covered=1; break
                    fi
                done <<< "$_od_serving_prefixes"
                [[ "$_od_covered" -eq 0 ]] && _od_unserved+="${_od_p} "
            done <<< "$_od_doc_api"

            if [[ -n "$_od_unserved" ]]; then
                test_fail "openapi drift: documented endpoint(s) are neither in the /api/ allowlist nor covered by a serving location block — anyone building against the published spec gets 403/404 (#883): ${_od_unserved}"
            else
                test_pass "openapi drift: every documented /api/ endpoint is either allowlisted or covered by a dedicated serving location block"
            fi

            # ── Auth posture: an auth_request-gated path must document its 401 ──
            # Presence-only comparison would call the /api/exports/ pair clean
            # while the spec published them as open. That was half of #883.
            #
            # Attribution is by brace DEPTH, not by a bare `}` reset (#903).
            # A bare reset is what the report suggested and it is wrong here:
            # literal-prefix location blocks in this very file wrap nested
            # `if (...) { ... }` blocks (/.well-known/ai-negotiate has two),
            # so the first inner `}` would clear the tracker while still
            # inside the block and an auth_request further down would be
            # attributed to nothing. That is the same silent miss #903
            # reports, only narrower — so the sibling parser's idiom three
            # blocks up is not the one to copy.
            #
            # Per-line NET brace counting is what keeps braces inside quoted
            # strings from derailing the depth: the one such line in this
            # config (the 401 return whose JSON body carries both braces) is
            # self-balancing. A line that is NOT self-balancing surfaces as a
            # final-depth mismatch, reported below as an explicit FAIL rather
            # than a confident wrong answer.
            _od_auth_raw=$(printf '%s\n' "$_od_tls" | awk '
                {
                    _l = $0
                    _o = gsub(/\{/, "", _l)
                    _c = gsub(/\}/, "", _l)

                    if (depth == 0 && $0 ~ /^[[:space:]]*location[[:space:]]+/) {
                        if ($2 == "=" || $2 == "~" || $2 == "~*" || $2 == "^~") {
                            mod = $2; path = $3
                        } else {
                            mod = ""; path = $2
                        }
                        # `~`/`~*` are regexes and `@name` is a named block —
                        # neither is a path prefix, so a documented endpoint
                        # cannot be prefix-matched against it. Carried out as
                        # `U` so an auth_request inside one gets REPORTED
                        # instead of dropped on the floor.
                        if (mod != "~" && mod != "~*" && path ~ /^\//) {
                            p = path; u = ""
                        } else {
                            p = ""; u = (mod == "" ? path : mod " " path)
                        }
                    }

                    # Count the openers on this line before testing, so a
                    # single-line location-with-auth_request is still seen.
                    depth += _o
                    if (depth >= 1 && $0 ~ /auth_request/) {
                        if (p != "")      print "P\t" p
                        else if (u != "") print "U\t" u
                    }
                    depth -= _c
                    if (depth <= 0) { p = ""; u = "" }
                    if (depth < mind) mind = depth
                }
                END { print "D\t" depth "\t" mind }
            ') || _od_auth_raw=""

            _od_depth=$(printf '%s\n' "$_od_auth_raw" | awk -F'\t' '$1=="D"{print $2":"$3}') || _od_depth=""
            _od_authed_prefixes=$(printf '%s\n' "$_od_auth_raw" | awk -F'\t' '$1=="P"{print $2}' | sort -u) || _od_authed_prefixes=""
            _od_auth_unmatchable=$(printf '%s\n' "$_od_auth_raw" | awk -F'\t' '$1=="U"{print $2}' | sort -u) || _od_auth_unmatchable=""

            _od_authgap=""
            while IFS= read -r _od_pref; do
                [[ -z "$_od_pref" ]] && continue
                while IFS= read -r _od_p; do
                    [[ -z "$_od_p" ]] && continue
                    awk -v s="$_od_p" -v pre="$_od_pref" 'BEGIN{exit !(index(s,pre)==1)}' || continue
                    # Does this path's own block in the spec declare a 401?
                    if ! awk -v want="  ${_od_p}:" '
                        $0 == want { inpath=1; next }
                        inpath && /^  \// { exit }
                        inpath && /^ *"401":/ { found=1; exit }
                        END { exit !found }
                    ' "$_od_spec"; then
                        _od_authgap+="${_od_p} "
                    fi
                done <<< "$_od_doc_api"
            done <<< "$_od_authed_prefixes"

            # The extraction above strips the opening `server {` but keeps the
            # matching closing brace, so a correctly-counted TLS block ends at
            # depth -1 and never dips below it. Any other result means the
            # brace accounting lost its place — an unbalanced brace inside a
            # string, or a changed extraction — and every attribution built on
            # top of it is untrustworthy. Say so; do not report a verdict.
            if [[ "$_od_depth" != "-1:-1" ]]; then
                test_fail "openapi drift: auth-posture arm did not run — nginx brace accounting ended at depth:min '${_od_depth:-unknown}', expected '-1:-1'; auth_request attribution cannot be trusted (#903)"
            elif [[ -n "$_od_authgap" ]]; then
                test_fail "openapi drift: endpoint(s) behind an nginx auth_request are documented WITHOUT a 401 response — the spec publishes an authenticated endpoint as open (#883): ${_od_authgap}"
            elif [[ -z "$_od_authed_prefixes" ]]; then
                test_warn "openapi drift: no prefix-matchable auth_request-gated location blocks found in nginx-site.conf — the auth-posture arm had nothing to check"
            else
                test_pass "openapi drift: every documented endpoint behind an auth_request declares a 401 response"
            fi

            # A regex or named location carrying an auth_request cannot be
            # prefix-matched against a documented path, so this arm cannot
            # judge it. Name it rather than skipping it silently — an
            # unreported gate is how a newly-gated public endpoint would slip
            # past the very check that exists to catch one (#903).
            if [[ "$_od_depth" == "-1:-1" && -n "$_od_auth_unmatchable" ]]; then
                test_warn "openapi drift: auth_request present in location block(s) this arm cannot prefix-match against a documented path — check their 401 documentation by hand (#903): $(printf '%s' "$_od_auth_unmatchable" | tr '\n' ' ')"
            fi
        fi
    fi
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
    "${MARVIN_DIR}/setup/chkrootkit-service-override.conf /etc/systemd/system/chkrootkit.service.d/override.conf chkrootkit-systemd-override"
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

# --- 9d, second half: a live config must trace to a MERGED source ------------
# Issue #961. Everything above answers "does the source in this working tree
# match the live file?" — which is silent about the failure that actually
# happened. On 2026-07-29 three live configs existed in git only as OPEN PRs:
# the fail2ban postfix journalmatch (#938), this drop-in (#926), and the
# agent-card vhost alias (#952). All three had been written up as landed.
# `setup/bootstrap.sh` on main reproduces none of them, so the host could not be
# rebuilt from its own repository — and the security control doing the most
# visible work (postfix-sasl, 4 IPs banned off 253 failures) was the one a
# rebuild would silently discard.
#
# The array-driven form of this check cannot work. A drift pair naming
# setup/chkrootkit-service-override.conf is added by the same PR that adds the
# file, so it can only fire *after* the merge it exists to police. This half is
# driven by the LIVE HOST instead: it enumerates what is actually installed and
# asks whether origin/main could produce it. That inversion is the whole point.
#
# Scope is systemd drop-ins under /etc/systemd/system/*.d/. Bounded (2 on this
# host), admin-owned, and the one config shape that changes a unit's behaviour
# while leaving the unit file itself untouched — so `systemctl cat` drift and
# file-integrity both look past it.
#
# Polarity is fail-safe. Provenance is established by CONTENT, not by filename:
# a live file passes only if some blob reachable from origin/main is byte-for-
# byte identical to it. Distro-owned drop-ins are named in an explicit exclusion
# list rather than pattern-matched, so an override that is neither ours nor
# listed WARNs for classification instead of being absorbed by a wildcard.
#
# WARN-only, matching §9d's contract above. origin/main is read from the LOCAL
# ref without fetching — an out-of-band fetch here would consume commits that
# sync-and-learn has not yet analysed (#924) — so a source merged within the
# last hour can read as unmerged until the next sync. That is a false WARN and
# never a false PASS, which is the correct direction for this check to be wrong.

marvin_log "INFO" "Self-test: checking live systemd drop-ins trace to a merged source"

# Drop-ins owned by the distro / cloud-init. Listed by exact path, not by
# pattern: a pattern broad enough to cover these would also cover ours.
#
# This list is a standing maintenance point, not a one-off record of today's
# host. Any NEW distro- or cloud-init-owned drop-in that appears here will WARN
# for classification until it is added — deliberately, because that WARN is the
# only moment anyone is asked whether the file is really foreign. Adding an
# entry is the cheap half; the expensive half would be a wildcard that silently
# absorbed one of ours.
_foreign_dropins=(
    "/etc/systemd/system/sshd-keygen@.service.d/disable-sshd-keygen-if-cloud-init-active.conf"
)

_merged_ref="origin/main"
_merged_tree=""
if ! _merged_tree=$(git -C "${MARVIN_DIR}" ls-tree -r "$_merged_ref" 2>/dev/null) || [[ -z "$_merged_tree" ]]; then
    # A check that could not run must not report "clean" — say so explicitly
    # rather than letting an unreadable ref collapse into "nothing unmerged".
    test_warn "merged-source provenance: cannot read ${_merged_ref} in ${MARVIN_DIR} — provenance NOT verified for any live drop-in"
else
    # This assignment is at top-level scope inside an `else` branch, which set -e
    # does NOT exempt (only an if/while *condition* is exempt), and `2>/dev/null`
    # hides find's stderr but not its exit code — so under pipefail an unreadable
    # cwd or a stat error would abort the whole suite here, taking §9h and all of
    # §10 with it (#963). Guarded like the file's other find call sites (l.694,
    # l.1798) — but with the status kept rather than discarded: a bare
    # `|| _live_dropins=""` would feed the empty-list PASS below and report a
    # broken enumeration as "no drop-ins installed", which is the one thing this
    # block promises not to do. Partial output is still iterated; each file it did
    # reach gets its own verdict, and the WARN says the list may be short.
    _find_rc=0
    _live_dropins=$(find /etc/systemd/system -mindepth 2 -maxdepth 2 -path '*.d/*' -name '*.conf' 2>/dev/null | sort) || _find_rc=$?
    if (( _find_rc != 0 )); then
        test_warn "merged-source provenance: enumerating /etc/systemd/system/*.d/ failed (find|sort exit ${_find_rc}) — the drop-in list may be incomplete, so provenance is NOT verified for any file missing from it"
    elif [[ -z "$_live_dropins" ]]; then
        test_pass "merged-source provenance: no systemd drop-ins installed under /etc/systemd/system"
    fi
    while IFS= read -r _dropin; do
        [[ -n "$_dropin" ]] || continue

        _foreign=0
        for _f in "${_foreign_dropins[@]}"; do
            if [[ "$_dropin" == "$_f" ]]; then _foreign=1; break; fi
        done
        if (( _foreign )); then
            test_pass "merged-source provenance: ${_dropin} — distro-owned, no tracked source expected"
            continue
        fi

        # hash-object without -w computes the id without writing it, so the
        # cat-file probe below stays a real question about the object store.
        _live_hash=""
        if ! _live_hash=$(git -C "${MARVIN_DIR}" hash-object "$_dropin" 2>/dev/null) || [[ -z "$_live_hash" ]]; then
            test_warn "merged-source provenance: could not hash ${_dropin} — provenance NOT verified for this file"
            continue
        fi

        # ls-tree rows are `<mode> <type> <sha>\t<path>`; awk's default FS splits
        # on the tab too, so $3 is the sha alone. The sha reaches awk through
        # ENVIRON rather than -v, which escape-processes its value (#923).
        if printf '%s\n' "$_merged_tree" \
            | H="$_live_hash" awk '$2 == "blob" && $3 == ENVIRON["H"] { found = 1 } END { exit !found }'; then
            test_pass "merged-source provenance: ${_dropin} — reproducible from ${_merged_ref}"
        # `cat-file -e` asks the object store, which is a wider question than
        # "is it committed". Verified rather than assumed, in a scratch repo:
        # a blob that was `git add`ed and never committed answers YES, and so
        # does one whose only branch has since been deleted (dangling until gc).
        # Neither is reachable from any commit. The wording below therefore says
        # "exists in this repo" and names the branch case as the likely one
        # instead of asserting it — an unmerged branch is by far the common
        # cause here, but it is not the only thing that satisfies this probe.
        # What the same experiment confirms is the load-bearing half: an
        # untracked file hashed without -w answers NO, so this stays a real
        # question about the store rather than one this check just seeded.
        elif git -C "${MARVIN_DIR}" cat-file -e "$_live_hash" 2>/dev/null; then
            test_warn "merged-source provenance: ${_dropin} — its exact content exists in this repo's object store but is NOT reachable from ${_merged_ref}: most likely a source sitting on an unmerged branch (a staged-but-uncommitted or recently-deleted-branch object would also land here), and a rebuild from main would not produce this file (#961)"
        else
            test_warn "merged-source provenance: ${_dropin} — no merged source: nothing in ${_merged_ref} has this content, and neither does any commit in this repo (#961)"
        fi
    done <<< "$_live_dropins"
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

# ─── 9n. Agent and setup scripts must stay executable in the index ────────────
# Issue #910. Commit 8024ed9 restored §9k by rewriting agent/self-test.sh whole
# instead of editing in place, so the new file landed at the umask default and
# the mode went 100755 → 100644. Nothing noticed: file-integrity.sh baselines
# sha256/size/mtime but not mode, self-test.sh had no permission assertion at
# all, and the diff renders as `agent/self-test.sh | 0` with 0 insertions and 0
# deletions — GitHub's file view shows literally nothing. There is also no
# runtime symptom, because nothing invokes self-test.sh via its shebang; it is
# run as `bash agent/self-test.sh`, and bash does not consult the exec bit.
#
# Section letter 9n: 9a–9k are live on main, 9l is claimed by the open #894 and
# 9m by the open #902. Chosen to collide with neither (#904).
#
# Reads the git INDEX rather than the filesystem, which is the whole point: it
# makes the assertion independent of the checkout's own permissions and pins
# the mode that actually merges. A `chmod +x` in a dirty working tree must not
# be able to turn this green.
#
# Scoped to *.sh directly in agent/ and setup/ — 39 + 5 files, all 100755 on
# main with zero exceptions. agent/lib/ is deliberately excluded: the split
# there is real (claude/logging/metrics/outbound/prompts are 644 and sourced;
# github.sh and pipefail-scan.sh are 755 and run), so a blanket rule would be
# wrong and would have to carry an exception list that rots.
#
# Resolved via `dirname "$0"`, not ${MARVIN_DIR}: the latter is hardcoded to
# the deployed tree, so a branch-authored check would assert against main and
# pass while the branch it ships with is broken (#855, #874, #890).

marvin_log "INFO" "Self-test: checking agent/setup script mode bits in the git index"

_mode_repo=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || _mode_repo=""

# Parenthesised deliberately (#911 review): `A || B && C` binds as `A || (B && C)`
# in [[ ]], which is the intent here, but relying on that precedence silently is
# how a guard comes to mean something other than it reads. `.git` is tested as
# both a directory and a file so a worktree checkout (where it is a file) counts.
if [[ -z "$_mode_repo" || ( ! -d "${_mode_repo}/.git" && ! -f "${_mode_repo}/.git" ) ]]; then
    test_warn "script mode bits: could not resolve a git repo from \$0 — check skipped (#910)"
else
    # `git ls-files -s` emits "<mode> <sha> <stage>\t<path>". The pathspec globs
    # would also match agent/lib/*.sh (git's `*` crosses `/`), so the top-level
    # restriction is applied here, in awk, against the real path field.
    #
    # Exit status is captured explicitly rather than swallowed with `|| true`:
    # a git failure and a clean tree must not produce the same verdict, or the
    # check reports "clean" for a scan that never ran.
    if _mode_raw=$(git -C "$_mode_repo" ls-files -s -- 'agent/*.sh' 'setup/*.sh' 2>/dev/null); then
        _mode_git_ok=1
    else
        _mode_git_ok=0
        _mode_raw=""
    fi

    _mode_top=$(awk -F'\t' 'NF==2 && $2 ~ /^(agent|setup)\/[^\/]+\.sh$/ { print }' <<< "$_mode_raw") || _mode_top=""
    _mode_total=$(awk 'NF' <<< "$_mode_top" | wc -l) || _mode_total=0
    _mode_bad=$(awk -F'\t' 'NF==2 { split($1, f, " "); if (f[1] != "100755") printf "%s (%s) ", $2, f[1] }' <<< "$_mode_top") || _mode_bad=""

    if [[ "$_mode_git_ok" -ne 1 ]]; then
        test_warn "script mode bits: git ls-files failed in ${_mode_repo} — check could not run (#910)"
    elif [[ "$_mode_total" -eq 0 ]]; then
        # Zero tracked scripts is not a pass. Either the pathspec stopped
        # matching or the layout moved; both make every assertion below vacuous.
        test_fail "script mode bits: no tracked *.sh found directly in agent/ or setup/ — the check matched nothing and cannot vouch for anything (#910)"
    elif [[ -n "$_mode_bad" ]]; then
        test_fail "script mode bits: ${_mode_bad% } is not 100755 in the index — a whole-file rewrite drops the exec bit invisibly (0 insertions, 0 deletions in the diff) (#910)"
    else
        test_pass "script mode bits: all ${_mode_total} tracked *.sh in agent/ and setup/ are 100755 in the index (#910)"
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
