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
# them. Full-line comments are excluded from quote-parity counting so an
# apostrophe in prose ("doesn't") can't start a runaway join; the 60-line cap is
# the backstop.
_JOIN_AWK='
{
  line = $0; ln = NR; joined = 0
  while (joined < 60) {
    probe = line
    gsub(/\\'"'"'/, "", probe)
    stripped = probe
    sub(/^[[:space:]]*#.*$/, "", stripped)
    n = gsub(/'"'"'/, "'"'"'", stripped)
    odd = (n % 2)
    cont = (line ~ /\\[[:space:]]*$/)
    if (!cont && !odd) break
    if (getline nxt <= 0) break
    sub(/\\[[:space:]]*$/, "", line)
    line = line " " nxt
    joined++
  }
  print ln ":" line
}'

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
