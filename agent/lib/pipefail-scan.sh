#!/usr/bin/env bash
# =============================================================================
# pipefail double-JSON-document scanner
# =============================================================================
# Structural detector for the bug class fixed four times in five days across
# four files (#841/#843 log-alerting, #844 log-export + capability-inventory,
# #846 weekly-analytics), tracked by #855.
#
# The mechanism, every time:
#
#   Under `set -euo pipefail`, bash reports a pipeline's status as the last
#   command that FAILED, not the last command in the pipe. So an early stage
#   failing can trigger a trailing `|| echo '[]'` AFTER a later `jq` has already
#   printed a perfectly valid document. The fallback APPENDS a second document
#   instead of replacing the first — the opposite of what a fallback is for.
#
# The consequences are not uniformly loud, and the quiet ones are worse: #843's
# instance did not crash. Both escalation tests lived inside `if` conditions,
# where `set -e` is exempt, so bash printed `syntax error in expression`,
# evaluated the condition FALSE and exited 0 — downgrading a live outage to a
# routine warning, i.e. the exact defect #841 existed to fix.
#
# A statement is flagged only when all four hold:
#   1. the fallback is `|| echo <non-empty>`   (an empty-string fallback is
#      harmless: `$()` strips trailing newlines — cf. fix-issues.sh:88-96)
#   2. it follows a pipeline
#   3. some stage can exit non-zero while producing no output
#   4. a later stage still emits a valid document on EMPTY input (jq -s/-n/-R -s,
#      wc) — this is what makes the appended fallback a *second* document
#
# Known blind spots — this is a detector calibrated against four real incidents,
# not a general-purpose static analyser, and the difference matters if anyone
# later reads a clean scan as proof the class is absent:
#   - condition 1 requires a literal `echo`. A `printf '[]'`, a `cat <<<`, or any
#     other non-empty fallback with the identical pipefail shape is NOT flagged.
#     Every instance so far has been `echo`; widening it costs false positives on
#     the many `|| printf` uses that are not document producers.
#   - condition 4 recognises jq -s/-n/-R -s and wc as emitters-on-empty-input.
#     Another command with that property would be missed.
#   - the awk line-joiner caps at 60 joined lines, so a longer statement is
#     truncated rather than scanned whole.
#   - condition 1's empty-fallback exclusion is anchored to the END of the joined
#     statement, so a statement carrying a real `|| echo '[]'` *and* ending in an
#     unrelated `|| echo ""` is skipped whole. Reproduced: two statements with an
#     identical `cat | jq -s || echo '[]'` defect, the second suffixed with
#     `|| echo ""`, and only the first is flagged. Deliberately left as-is —
#     un-anchoring the exclusion would drop the many single-fallback `|| echo ""`
#     statements that are genuinely harmless, which is a far larger class than
#     this contrived shape. Note the asymmetry with the `||`-splitting choice
#     above: there, over-inclusion was the safe direction; here, matching on
#     "ends with an empty echo" is the only cheap way to recognise the harmless
#     case at all, and its cost is this narrow false negative.
#
# Calibrated against every known instance (all reproduced), and clean against
# every fixed version:
#   log-alerting.sh          pre-#843 -> 1 hit   (cat | jq -R | jq -s || echo)
#   log-export.sh            pre-#844 -> 2 hits  (find | jq -R -s || echo)
#   capability-inventory.sh  pre-#844 -> 1 hit   (grep | awk | jq -s || echo)
#   weekly-analytics.sh      pre-#846 -> 2 hits  (head SIGPIPE; cat)
#
# Usage:
#   pipefail-scan.sh [files...]          human output (default: agent/**/*.sh)
#   pipefail-scan.sh --tsv [files...]    basename \t line \t key \t statement
#
# The `key` is a hash of the whitespace-normalized statement, so a baseline can
# name a known-pending site without pinning a line number that any edit above it
# would shift. Consumed by self-test.sh §1h.
#
# Exit:
#   0 — clean
#   1 — at least one hit
#   2 — COULD NOT SCAN (missing tool, unreadable input, no targets). Distinct on
#       purpose: a caller must never read "produced no findings" as "found
#       nothing wrong", which is the failure-collapsing class this file exists to
#       police in the first place (#858).
# =============================================================================

# `set -e` is deliberately omitted, and this is the one file under agent/ that
# deviates from the project convention. The scan body is built from guard clauses
# like `[[ "$code" =~ ^[[:space:]]*# ]] && continue`, whose compound status is 1
# on the ordinary path — under `-e` that aborts the run mid-file instead of
# skipping a line, and from the caller's side an aborted scan looks exactly like
# a clean one. Propagation here is explicit instead: every failure path exits 2
# and says why on stderr, which is a stronger guarantee than `-e` would give.
#
# This file also does not source `agent/common.sh`, against the convention in
# CLAUDE.md, and that is deliberate too: common.sh hardcodes
# `MARVIN_DIR="/home/marvin/git"`, which would override the self-locating
# fallback below and silently point every scan at the LIVE tree even when the
# scanner is run from a worktree or an old revision — which is exactly how it was
# calibrated against the four historical incidents. It also `mkdir -p`s the live
# data directories at source time, a side effect a read-only static analyser
# should not have. Neither deviation is an oversight to be "fixed" by a later
# reader; both are load-bearing.
set -uo pipefail

# A scan that cannot run must not resemble a scan that found nothing.
for _tool in awk sha1sum find basename tr cut; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "pipefail-scan: required tool not available: ${_tool}" >&2
        exit 2
    fi
done

# Joins backslash-continuations AND multi-line single-quoted programs. The
# latter is required, not a nicety: capability-inventory.sh's
# `crontab | awk '…' | jq -s` spans 13 lines with the awk body unquoted across
# them.
#
# Quote state is tracked by SCANNING the line, not by counting quote characters.
# The counting version excluded only FULL-LINE comments, so an apostrophe inside
# a double-quoted string — `test_fail "… the day'"'"'s egress answer"` — read as
# an unterminated single quote and joined the next 60 lines into one statement.
# That is not hypothetical: it was live on this branch, and the 60-line sweep
# pulled in an unrelated `grep … | wc -l` pipeline and an unrelated `|| echo`,
# satisfying all four conditions and FAILING the suite on a fabricated hit. A
# detector for "a failure that produces a confident-looking wrong answer",
# producing a confident-looking wrong answer.
#
# The scan tracks single- and double-quote state against each other (a `'"'"'`
# inside `"…"` is literal, and vice versa), honours backslash escapes ONLY
# outside single quotes (bash does not escape inside them), and stops at an
# unquoted `#` that begins a word — so a trailing comment is ignored while
# `(#882)` is not mistaken for one.
#
# A word begins after whitespace OR after an unquoted shell metacharacter, so
# `false;# it'"'"'s fine` and `foo |# note` are recognised as comments too. Checking
# only for whitespace (as the first version of this scan did) left an apostrophe
# inside such a comment free to flip quote state — #887 one delimiter over. `{`
# is deliberately NOT in the set: `${#arr[@]}` and `${var#pfx}` are parameter
# expansions, not comments.
#
# Limitation, deliberately left: the word-start test looks one character back in
# the ACCUMULATED buffer, not in the original physical line. A backslash-
# continued line whose continuation begins with `#` has that `#` preceded by the
# join's inserted space in the buffer but by a line break in the source, so the
# two disagree at exactly that one position. It errs toward reading it as a
# comment, i.e. toward NOT joining further — the same direction the counting
# version's "only a full-line comment counts" limitation erred in, and the safe
# one: an under-join splits one statement into two and at worst loses a hit,
# whereas the over-join is what manufactured #887's fabricated one.
#
# The joiner asserts these properties against embedded fixtures on every run
# (`_joiner_selfcheck` below) — a regression here exits 2 rather than scanning
# with a broken parser and reporting whatever falls out.
_JOIN_AWK='
function sq_open(s,   i, c, p, in_s, in_d, L) {
  in_s = 0; in_d = 0; L = length(s)
  for (i = 1; i <= L; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && !in_s) { i++; continue }
    if (c == "'"'"'" && !in_d) { in_s = !in_s; continue }
    if (c == "\"" && !in_s) { in_d = !in_d; continue }
    if (c == "#" && !in_s && !in_d) {
      p = (i == 1) ? " " : substr(s, i - 1, 1)
      if (p == " " || p == "\t" || p == ";" || p == "|" ||
          p == "&" || p == "(" || p == ")") break
    }
  }
  return in_s
}
{
  line = $0; ln = NR; joined = 0
  while (joined < 60) {
    unterminated_squote = sq_open(line)
    cont = (line ~ /\\[[:space:]]*$/)
    if (!cont && !unterminated_squote) break
    if (getline nxt <= 0) break
    sub(/\\[[:space:]]*$/, "", line)
    line = line " " nxt
    joined++
  }
  print ln ":" line
}'

# The joiner is the component of this scanner that has now been wrong twice, and
# both times it was wrong in the direction that MANUFACTURES a hit: naive paren
# counting in the §1i scanner one file over (#875), naive quote counting here
# (#887). Both were written to prevent exactly the class they then produced, and
# both survived review because the logic reads correctly. So it is not trusted on
# inspection — it is exercised against fixtures before any real file is read, and
# a mis-parse exits 2 ("could not scan") rather than scanning with a broken
# parser and reporting whatever falls out.
#
# #887 is pinned as an explicit negative: an apostrophe inside a double-quoted
# string must NOT start a join. The positives sit beside it so the check cannot
# pass by simply never joining anything — a genuine multi-line single-quoted awk
# program and a backslash continuation must still join. The expectations are
# written out by hand; comparing the joiner against a second copy of itself would
# agree perfectly and prove nothing.
_joiner_selfcheck() {
    local _got _want _i _g _w
    local -a _gl _wl
    _got=$(awk "$_JOIN_AWK" <<'_PFSC_FIXTURE' | tr -s ' \t' ' '
test_fail "outbound sampling is back to one sample as the day's answer (#882)"
echo second
crontab -l | awk '
  { print $1 }
' | wc -l
echo one \
  two
echo hi   # doesn't matter
false;# it doesn't need a space in front
echo tail
_PFSC_FIXTURE
    ) || return 1
    _want=$(cat <<'_PFSC_EXPECT'
1:test_fail "outbound sampling is back to one sample as the day's answer (#882)"
2:echo second
3:crontab -l | awk ' { print $1 } ' | wc -l
6:echo one two
8:echo hi # doesn't matter
9:false;# it doesn't need a space in front
10:echo tail
_PFSC_EXPECT
    ) || return 1
    if [[ "$_got" != "$_want" ]]; then
        echo "pipefail-scan: line-joiner self-check FAILED — the joiner mis-parses its own fixtures, so no scan result from it can be trusted (#887)" >&2
        # First mismatch only, truncated. §1h folds this stderr into a single
        # FAIL line, and a full diff of a runaway join is unreadable there; the
        # first divergence is what names the defect anyway.
        mapfile -t _gl <<< "$_got"
        mapfile -t _wl <<< "$_want"
        _i=0
        while [[ "$_i" -lt "${#_wl[@]}" || "$_i" -lt "${#_gl[@]}" ]]; do
            _w="${_wl[$_i]:-<missing>}"
            _g="${_gl[$_i]:-<missing>}"
            if [[ "$_w" != "$_g" ]]; then
                echo "pipefail-scan:   first mismatch at joined-output line $((_i + 1))" >&2
                echo "pipefail-scan:   expected: ${_w:0:110}" >&2
                echo "pipefail-scan:   got:      ${_g:0:110}" >&2
                break
            fi
            _i=$((_i + 1))
        done
        return 1
    fi
}
if ! _joiner_selfcheck; then
    exit 2
fi

_tsv=false
if [[ "${1:-}" == "--tsv" ]]; then
    _tsv=true
    shift
fi

_hits=0

# Stable identity for a flagged statement: whitespace-normalized, hashed, and
# truncated. Survives the statement moving within its file; changes when the
# statement itself changes — which is what makes a fixed site fall out of a
# baseline automatically instead of staying permanently excused.
_stmt_key() {
    local _norm _key
    _norm="$(tr -s '[:space:]' ' ' <<< "$1")"
    _norm="${_norm# }"; _norm="${_norm% }"
    _key="$(printf '%s' "$_norm" | sha1sum | cut -c1-12)" || return 1
    [[ -n "$_key" ]] || return 1
    printf '%s' "$_key"
}

# Returns 2 if the file could not be processed, so a read error can never be
# reported as an absence of findings.
_scan_file() {
    local f="$1" rec ln code pre key joined
    joined="$(awk "$_JOIN_AWK" "$f")" || {
        echo "pipefail-scan: awk failed on ${f}" >&2
        return 2
    }
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        ln="${rec%%:*}"; code="${rec#*:}"
        [[ "$code" =~ ^[[:space:]]*# ]] && continue
        # 1. non-empty echo fallback
        [[ "$code" =~ \|\|[[:space:]]*echo[[:space:]] ]] || continue
        [[ "$code" =~ \|\|[[:space:]]*echo[[:space:]]+(\"\"|\'\')[[:space:]]*[\),\;]*[[:space:]]*$ ]] && continue
        # Split on the LAST `||`, not the first: a statement with an earlier
        # unrelated `||` (`foo || bar | jq -s || echo '[]'`) would otherwise have
        # `pre` truncated before the real `| jq` producer and slip through as a
        # false negative. None of the four historical instances had more than one
        # `||`, so this is a blind spot closed rather than a bug fixed; erring
        # toward over-inclusion is the right direction for a detector whose hits
        # a human reads.
        pre="${code%||*}"
        # 2. it is a pipeline
        [[ "$pre" == *"|"* ]] || continue
        # 3. a stage that can exit non-zero while emitting nothing
        [[ "$pre" =~ (^|\||\()[[:space:]]*(find|grep|egrep|fgrep|ls|cat|head|tail|stat|git|crontab|systemctl)[[:space:]] ]] || continue
        # 4. a producer that emits a valid document even on empty input
        [[ "$pre" =~ \|[[:space:]]*jq[[:space:]]+[^\'\"]*(-R[[:space:]]+-s|-Rs|-Rn|-n|-s)([[:space:]]|\') ]] \
            || [[ "$pre" =~ \|[[:space:]]*wc[[:space:]] ]] || continue
        _hits=$((_hits + 1))
        if [[ "$_tsv" == true ]]; then
            key="$(_stmt_key "$code")" || {
                echo "pipefail-scan: could not hash statement at ${f}:${ln}" >&2
                return 2
            }
            printf '%s\t%s\t%s\t%s\n' "$(basename "$f")" "$ln" "$key" "$(tr -s '[:space:]' ' ' <<< "$code")"
        else
            echo "  HIT: $(basename "$f"):${ln}"
        fi
    done <<< "$joined"
}

_targets=("$@")
_explicit_targets=true
if [[ ${#_targets[@]} -eq 0 ]]; then
    _explicit_targets=false
    # MARVIN_DIR when sourced into an agent script's environment; otherwise
    # derived from this file's own location (agent/lib/ -> repo root).
    _base="${MARVIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    if ! mapfile -t _targets < <(find "${_base}/agent" -name '*.sh' -type f | sort); then
        echo "pipefail-scan: could not enumerate ${_base}/agent" >&2
        exit 2
    fi
    # Zero targets means the tree is not where we think it is — a silent 0-hit
    # "clean" from an empty file list is the exact false reassurance this
    # script's exit codes exist to prevent.
    if [[ ${#_targets[@]} -eq 0 ]]; then
        echo "pipefail-scan: no *.sh files found under ${_base}/agent" >&2
        exit 2
    fi
fi

_errors=0
_scanned=0
for _f in "${_targets[@]}"; do
    if [[ ! -r "$_f" ]]; then
        # An explicitly-named file that cannot be read is an error; a vanished
        # entry from our own find (rotated/removed mid-run) is not.
        if [[ "$_explicit_targets" == true ]]; then
            echo "pipefail-scan: cannot read ${_f}" >&2
            _errors=$((_errors + 1))
        fi
        continue
    fi
    _scan_file "$_f" || _errors=$((_errors + 1))
    _scanned=$((_scanned + 1))
done

if [[ "$_errors" -gt 0 ]]; then
    echo "pipefail-scan: ${_errors} file(s) could not be scanned — results are incomplete" >&2
    exit 2
fi
if [[ "$_scanned" -eq 0 ]]; then
    echo "pipefail-scan: nothing was scanned" >&2
    exit 2
fi

if [[ "$_tsv" == false ]]; then
    if [[ "$_hits" -eq 0 ]]; then
        echo "pipefail double-document scan: clean (${_scanned} files)"
    else
        echo "pipefail double-document scan: ${_hits} hit(s)"
    fi
fi

[[ "$_hits" -eq 0 ]]
