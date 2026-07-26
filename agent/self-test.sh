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

# ─── 1i. process-substitution producers that fail silently ───────────────────
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

_PROCSUB_BASELINE=24

# Walks each `done < <(` site to its matching close paren so multi-line
# producers are classified on their whole text — the §1d site above pipes on a
# continuation line, which a line-based grep scores safe and misses.
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
    # A comment that *documents* the pattern is not a site. The §1i commentary
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

_ps_files=$(find "${MARVIN_DIR}/agent" -name '*.sh' -type f 2>/dev/null) || _ps_files=""
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
