#!/usr/bin/env bash
# =============================================================================
# Regression tests — security-scan.sh §4c's GNUPGHOME ownership drift (#982)
# =============================================================================
# §4c decides whether the user who owns GNUPGHOME can still write inside it.
# That question was open for 64 days because reads never touch the write path:
# signing worked the entire time `pubring.kbx` was root-owned, so nothing in
# the ordinary operation of this host could have surfaced it (#980).
#
# The check that now answers it shipped with its reasoning in prose — a PR body
# describing a measurement taken once on a `cp -a` copy of the drifted homedir.
# That measurement is not runnable and does not notice when the function is
# edited. This file is that measurement, committed. Sibling of #987, which asks
# the same of §4b's fail2ban policy parser.
#
# The function is EXTRACTED FROM THE REAL SCRIPT by marker, not copied here, and
# the extraction is `bash -n`'d before it is sourced — a broken extraction fails
# loudly instead of silently testing nothing. common.sh is deliberately NOT
# sourced: inheriting `marvin_error_trap` would write real [ERROR] lines into
# the production log every time a mutation arm goes red on purpose.
#
# Every fixture is paired with a MUTATION that must turn it red, and the
# expected-red set is named per mutation — so a mutation that goes red on the
# WRONG fixture fails too, rather than being read as success. A guard that
# cannot fail is not a guard.
#
# Fixtures are REAL FILESYSTEM STATE, not synthesised find output, wherever the
# effective uid allows it: `ok`, `drift`, socket-only drift, nested drift, the
# absent homedir, and the unmapped-UID case are staged with actual chown. Two
# things cannot be staged that way and are handled explicitly rather than
# skipped:
#
#   - The `find exited non-zero` arm. Root bypasses DAC, so an unreadable
#     subtree does not stop root's walk, and §4c runs as root from
#     /etc/cron.d/marvin. It is driven through a `find` shim instead — and the
#     PREMISE the shim stands on (that a real unreadable subtree does make find
#     exit non-zero) is verified separately against the real binary, dropped to
#     an unprivileged uid via setpriv. That is the independent oracle: the shim
#     tests the branch, the oracle tests that the branch is reachable in life.
#
#   - The chown-dependent arms under a non-root euid. They are reported as
#     SKIP and counted, never as PASS. A suite that quietly shrinks when run by
#     the wrong user is how coverage is lost twice (#889, #892).
#
# Also asserted here, per #982: the caller-side consequence. `drift` is a
# finding and `unknown` means the scan could not look, which is also a finding
# (#882) — both must downgrade overall_status to `warnings`, and only `ok` may
# stay silent. The gate's condition text is extracted from the real script too.
#
# Usage: bash agent/tests/security-scan-4c-gnupg-drift.test.sh
# Exit:  0 all pass, 1 any failure, 2 harness broken
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${SCRIPT_DIR}/security-scan.sh"

UNIT=$(mktemp)
GATE=$(mktemp)
FIXROOT=$(mktemp -d)
trap 'rm -f "$UNIT" "$GATE"; chmod -R u+rwX "$FIXROOT" 2>/dev/null; rm -rf "$FIXROOT"' EXIT

PASS=0 ; FAIL=0 ; SKIP=0

_eq() { # _eq <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        printf '  \033[32mPASS\033[0m  %-32s %s\n' "$1" "${2:0:80}" ; PASS=$((PASS+1))
    else
        printf '  \033[31mFAIL\033[0m  %-32s\n        expected=[%s]\n        actual  =[%s]\n' "$1" "$2" "$3" ; FAIL=$((FAIL+1))
    fi
}
_skip() { printf '  \033[33mSKIP\033[0m  %-32s %s\n' "$1" "$2" ; SKIP=$((SKIP+1)) ; }
_die()  { printf '\033[31mHARNESS BROKEN: %s\033[0m\n' "$1" >&2 ; exit 2 ; }

[[ -r "$TARGET" ]] || _die "cannot read ${TARGET}"

IS_ROOT=0 ; [[ "$(id -u)" -eq 0 ]] && IS_ROOT=1

# The homedir owner and the drifting writer. Mirrors production exactly:
# GNUPGHOME is marvin's, the cron agents that write into it run as root.
OWNER_USER="marvin" ; OTHER_USER="root"
if [[ "$IS_ROOT" -eq 1 ]]; then
    id -u "$OWNER_USER" >/dev/null 2>&1 || _die "user ${OWNER_USER} does not exist"
fi
# An unmapped UID, for the `stat -c '%U'` -> literal "UNKNOWN" arm.
UNMAPPED_UID=60999
if [[ "$IS_ROOT" -eq 1 ]] && getent passwd "$UNMAPPED_UID" >/dev/null 2>&1; then
    _die "uid ${UNMAPPED_UID} is mapped on this host — pick another for the UNKNOWN arm"
fi

# ─── Extract the real function ───────────────────────────────────────────────
# From the definition line through the first column-0 `}`. Nothing inside the
# function body sits at column 0.
_extract_unit() {
    awk '/^_gnupg_ownership_drift\(\) \{/ { on=1 } on { print } on && /^\}/ { exit }' "$TARGET"
}

# The caller-side gate: §4c's arm of the overall_status if-chain, rewritten
# from `elif` to `if` so it can be evaluated standalone. Taking the condition
# from the script means a future edit to it is seen here.
_extract_gate() {
    awk '
        /^elif \[\[ "\$gpg_drift_status" != "ok" \]\]; then$/ { on=1 }
        on { sub(/^elif /, "if "); print }
        on && /^fi$/ { exit }
    ' "$TARGET"
}

# Whole-line replacement keyed by a literal substring. Needle and replacement
# travel through the environment, never `awk -v`: -v escape-processes its value,
# and a backslash in one has made an in-use guard fail open before (#923).
# Hit count goes to fd 3 so an inert mutation is caught rather than assumed.
_mutate_line() { # _mutate_line <needle> <replacement>   (stdin -> stdout, count -> fd 3)
    MUT_NEEDLE="$1" MUT_REPL="$2" awk '
        index($0, ENVIRON["MUT_NEEDLE"]) { print ENVIRON["MUT_REPL"]; hits++; next }
        { print }
        END { print hits+0 > "/dev/fd/3" }'
}

_apply() { # _apply <src> <dst> <needle> <replacement>   -- dies unless exactly 1 hit
    local hits
    hits=$(_mutate_line "$3" "$4" < "$1" 3>&1 1>"$2.tmp")
    mv "$2.tmp" "$2"
    [[ "$hits" == "1" ]] || _die "mutation needle matched ${hits} lines (want 1): ${3}"
}

_build_unit() { # _build_unit <mutation>
    local raw ; raw=$(mktemp)
    _extract_unit > "$raw"
    [[ -s "$raw" ]] || _die "extraction of _gnupg_ownership_drift produced nothing"
    grep -q '^_gnupg_ownership_drift() {' "$raw" || _die "extraction missing its own header"

    case "$1" in
      none)
        cp "$raw" "$UNIT" ;;

      # Score agent sockets as persistent drift. They are recreated by whoever
      # last started gpg-agent, so this is the mutation that would make §4c flap
      # nightly on a host where root and marvin both use gpg.
      sockets_count_as_drift)
        _apply "$raw" "$UNIT" 'if [[ "$ftype" == "s" ]]; then' '            if false; then' ;;

      # Count the drifted entries behind a pipe instead of a here-string. The
      # loop then runs in a subshell, both counters come back zero, and every
      # drifted homedir on earth reports ok. This is the exact lesson the
      # function's own comment cites; it is here to prove the comment is load-
      # bearing and not decorative.
      pipe_subshell)
        local tmp2 ; tmp2=$(mktemp)
        _apply "$raw" "$tmp2" 'while IFS=$'"'"'\t'"'"' read -r ftype fowner fpath; do' \
               '        printf '"'"'%s\n'"'"' "$walk" | while IFS=$'"'"'\t'"'"' read -r ftype fowner fpath; do'
        _apply "$tmp2" "$UNIT" 'done <<< "$walk"' '        done'
        rm -f "$tmp2" ;;

      # Treat a walk that aborted as a walk that found nothing (#882 class).
      swallow_find_rc)
        _apply "$raw" "$UNIT" 'if [[ "$rc" -ne 0 ]]; then' '    if false; then' ;;

      # Drop the coreutils "UNKNOWN" arm. `stat` exits 0 printing that literal
      # for an unmapped uid, so the -z guard alone does not cover it: the string
      # reaches find, find refuses it, and the verdict blames the walk instead
      # of the lookup.
      no_unknown_owner_guard)
        _apply "$raw" "$UNIT" 'if [[ -z "$owner" || "$owner" == "UNKNOWN" ]]; then' \
               '    if [[ -z "$owner" ]]; then' ;;

      # Drop the absent-homedir guard.
      no_dir_guard)
        _apply "$raw" "$UNIT" 'if [[ ! -d "$home" ]]; then' '    if false; then' ;;

      # Invert the ownership test: report every entry the owner DOES own.
      invert_user_test)
        _apply "$raw" "$UNIT" 'walk=$(find "$home" -mindepth 1 \! -user "$owner"' \
               '    walk=$(find "$home" -mindepth 1 -user "$owner" -printf '"'"'%y\t%u\t%p\n'"'"' 2>/dev/null) || rc=$?' ;;

      *) _die "unknown mutation: $1" ;;
    esac
    rm -f "$raw"

    bash -n "$UNIT" || _die "mutated unit does not parse (mutation=$1)"
    # shellcheck disable=SC1090
    source "$UNIT" || _die "cannot source mutated unit (mutation=$1)"
}

# ─── Fixtures ────────────────────────────────────────────────────────────────
# Built once, reused by every arm. Ownership is only staged under root; the
# arms that need it are skipped loudly otherwise.
chmod 711 "$FIXROOT"   # traversable by the unprivileged premise oracle below

_mksock() { python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$1"; }

_build_fixtures() {
    local d

    # clean: homedir and every entry owned by the same user
    d="${FIXROOT}/clean" ; mkdir -p "$d/sub" ; : > "$d/pubring.kbx" ; : > "$d/sub/deep"
    [[ "$IS_ROOT" -eq 1 ]] && chown -R "$OWNER_USER" "$d"

    # drift_one: a single foreign-owned persistent file — production's shape.
    # TWO owned entries beside it, deliberately: with one of each, owned and
    # unowned counts are equal and the `invert_user_test` mutation produces the
    # identical tuple, so the fixture would assert nothing about which side of
    # the comparison is being counted. Asymmetry is what makes it load-bearing.
    d="${FIXROOT}/drift_one" ; mkdir -p "$d"
    : > "$d/pubring.kbx" ; : > "$d/trustdb.gpg" ; : > "$d/random_seed"
    if [[ "$IS_ROOT" -eq 1 ]]; then chown -R "$OWNER_USER" "$d" ; chown "$OTHER_USER" "$d/pubring.kbx" ; fi

    # drift_three: the count must be the count, not a boolean
    d="${FIXROOT}/drift_three" ; mkdir -p "$d" ; : > "$d/a" ; : > "$d/b" ; : > "$d/c" ; : > "$d/mine"
    if [[ "$IS_ROOT" -eq 1 ]]; then chown -R "$OWNER_USER" "$d" ; chown "$OTHER_USER" "$d/a" "$d/b" "$d/c" ; fi

    # nested: drift below the top level must still be found. Same asymmetry rule
    # as drift_one — the subdirectory alone would balance the one drifted key.
    d="${FIXROOT}/nested" ; mkdir -p "$d/private-keys-v1.d"
    : > "$d/private-keys-v1.d/key.key" ; : > "$d/pubring.kbx"
    if [[ "$IS_ROOT" -eq 1 ]]; then chown -R "$OWNER_USER" "$d" ; chown "$OTHER_USER" "$d/private-keys-v1.d/key.key" ; fi

    # socket_only: a foreign-owned agent socket alone must NOT gate
    d="${FIXROOT}/socket_only" ; mkdir -p "$d" ; : > "$d/pubring.kbx" ; _mksock "$d/S.gpg-agent"
    if [[ "$IS_ROOT" -eq 1 ]]; then chown -R "$OWNER_USER" "$d" ; chown "$OTHER_USER" "$d/S.gpg-agent" ; fi

    # socket_and_file: the socket is counted separately, the file still gates
    d="${FIXROOT}/socket_and_file" ; mkdir -p "$d" ; : > "$d/pubring.kbx" ; _mksock "$d/S.gpg-agent"
    if [[ "$IS_ROOT" -eq 1 ]]; then
        chown -R "$OWNER_USER" "$d" ; chown "$OTHER_USER" "$d/S.gpg-agent" "$d/pubring.kbx"
    fi

    # unmapped: homedir owned by a uid with no passwd entry
    d="${FIXROOT}/unmapped" ; mkdir -p "$d" ; : > "$d/pubring.kbx"
    [[ "$IS_ROOT" -eq 1 ]] && chown -R "$UNMAPPED_UID" "$d"

    # unreadable: for the premise oracle only, never for the unit
    d="${FIXROOT}/unreadable" ; mkdir -p "$d/sub" ; : > "$d/sub/hidden"
    if [[ "$IS_ROOT" -eq 1 ]]; then chown -R nobody "$d" 2>/dev/null ; fi
    chmod 000 "$d/sub"

    # absent: deliberately not created — ${FIXROOT}/absent
    return 0
}

# Reduce a detail string to the class it belongs to, so the assertions pin
# meaning without pinning temp-directory paths.
_class() {
    case "$1" in
        "homedir absent"*)                 echo absent ;;
        "cannot resolve owner"*)           echo unresolved ;;
        "find exited"*)                    echo walkfail ;;
        "all persistent entries owned by"*) echo owned ;;
        *"not owned by"*)                  echo unowned ;;
        *)                                 echo other ;;
    esac
}

# One fixture -> "status/drift/sockets/class"
_run() { # _run <path>
    local status drift sockets detail
    IFS=$'\t' read -r status drift sockets detail < <(_gnupg_ownership_drift "$1")
    printf '%s/%s/%s/%s' "$status" "$drift" "$sockets" "$(_class "$detail")"
}

# The find-shim arm. Root bypasses DAC, so this branch is unreachable through
# permissions on the uid §4c actually runs as; the shim reaches it directly and
# the oracle below proves it is a real condition and not a hypothetical.
_run_walkfail() {
    local out
    find() { return 1; }
    out=$(_run "${FIXROOT}/clean")
    unset -f find
    printf '%s' "$out"
}

# Expected tuples. Chown-dependent arms are named so they can be skipped as a
# group under a non-root euid rather than silently reported as passing.
FIXTURES=(
    "clean|${FIXROOT}/clean|ok/0/0/owned|any"
    "drift_one|${FIXROOT}/drift_one|drift/1/0/unowned|root"
    "drift_three|${FIXROOT}/drift_three|drift/3/0/unowned|root"
    "nested|${FIXROOT}/nested|drift/1/0/unowned|root"
    "socket_only|${FIXROOT}/socket_only|ok/0/1/owned|root"
    "socket_and_file|${FIXROOT}/socket_and_file|drift/1/1/unowned|root"
    "absent|${FIXROOT}/absent|unknown/0/0/absent|any"
    "unmapped_uid|${FIXROOT}/unmapped|unknown/0/0/unresolved|root"
)

_arm() { # _arm <mutation>  -> "name<US>expected<US>actual" per line
    _build_unit "$1"
    local name path exp need act
    for f in "${FIXTURES[@]}"; do
        IFS='|' read -r name path exp need <<< "$f"
        [[ "$need" == "root" && "$IS_ROOT" -ne 1 ]] && continue
        act=$(_run "$path")
        printf '%s\037%s\037%s\n' "$name" "$exp" "$act"
    done
    printf '%s\037%s\037%s\n' "walk_fails" "unknown/0/0/walkfail" "$(_run_walkfail)"
}

_build_fixtures

# ─── 1. The real function, unmutated, against every fixture ──────────────────
echo
echo "── _gnupg_ownership_drift vs staged homedirs (unmutated) ──"
[[ "$IS_ROOT" -eq 1 ]] || _skip "ownership arms" "not root — chown-dependent fixtures not staged"
BASELINE=$(_arm none) || exit 2
while IFS=$'\037' read -r n e a; do
    [[ -z "$n" ]] && continue
    _eq "$n" "$e" "$a"
done <<< "$BASELINE"

# ─── 2. The premise the find shim stands on ──────────────────────────────────
# The shim asserts §4c handles a non-zero find. This asserts a non-zero find is
# a thing that happens: real binary, real unreadable subtree, unprivileged uid.
echo
echo "── oracle: real find really does exit non-zero on an unreadable subtree ──"
if [[ "$IS_ROOT" -eq 1 ]]; then
    ORC=0
    setpriv --reuid=65534 --regid=65534 --clear-groups \
        find "${FIXROOT}/unreadable" -mindepth 1 \! -user nobody -printf '%y\t%u\t%p\n' \
        >/dev/null 2>&1 || ORC=$?
    _eq "real find rc on unreadable subtree" "nonzero" "$([[ "$ORC" -ne 0 ]] && echo nonzero || echo "zero")"
else
    ORC=0
    find "${FIXROOT}/unreadable" -mindepth 1 -printf '%y\n' >/dev/null 2>&1 || ORC=$?
    _eq "real find rc on unreadable subtree" "nonzero" "$([[ "$ORC" -ne 0 ]] && echo nonzero || echo "zero")"
fi

# ─── 3. Every mutation must turn its named fixtures red ──────────────────────
# A mutation that breaks nothing means the assertions above were never load-
# bearing. Naming the expected-red set means a mutation that goes red on the
# wrong fixture is a failure, not a shrug.
echo
echo "── mutations (each must break exactly the fixtures it is aimed at) ──"
_mutation_arm() { # _mutation_arm <mutation> <fixture-that-must-go-red>...
    local mut="$1"; shift
    local want="$*" out red=""
    out=$(_arm "$mut") || exit 2
    while IFS=$'\037' read -r n e a; do
        [[ -z "$n" ]] && continue
        [[ "$e" != "$a" ]] && red+="${n} "
    done <<< "$out"
    red="${red% }"
    if [[ -z "$red" ]]; then
        printf '  \033[31mMUTATION INEFFECTIVE\033[0m  %-24s broke nothing — the assertions above prove nothing\n' "$mut"
        FAIL=$((FAIL+1)); return
    fi
    _eq "mutation:${mut}" "$want" "$red"
}

if [[ "$IS_ROOT" -eq 1 ]]; then
    # socket_and_file goes red too: its socket becomes a second drifted entry.
    _mutation_arm sockets_count_as_drift  socket_only socket_and_file
    # socket_only goes red on the socket counter, which the subshell zeroes as
    # surely as the drift counter — the fixture that does NOT gate still notices.
    _mutation_arm pipe_subshell           drift_one drift_three nested socket_only socket_and_file
    _mutation_arm no_unknown_owner_guard  unmapped_uid
    _mutation_arm invert_user_test        clean drift_one drift_three nested socket_only socket_and_file
else
    _skip "mutation:sockets_count_as_drift" "needs root-staged fixtures"
    _skip "mutation:pipe_subshell"          "needs root-staged fixtures"
    # Was: `_mutation_arm ... || _skip ...`, intending to attempt the arm and
    # fall back. The fallback could never fire. _mutation_arm reports through
    # _eq, which RECORDS a failure and returns success, so the `||` saw a
    # zero status and the skip was unreachable — the arm ran unconditionally
    # against a fixture that only exists under root.
    #
    # `unmapped_uid` is staged by `chown -R "$UNMAPPED_UID"`, which non-root
    # cannot do, so off-root the fixture is a plain directory owned by the
    # runner. Removing the unknown-owner guard from a scan that has no
    # unknown-owned file to find changes nothing, and the suite said so:
    # "MUTATION INEFFECTIVE — broke nothing". That verdict was correct. The
    # bug was asking the question at all without the fixture.
    #
    # It now skips like its three siblings, which is what the other arms in
    # this branch have always done. On a root runner all four still execute.
    _skip "mutation:no_unknown_owner_guard" "needs root-staged fixtures"
    _skip "mutation:invert_user_test"        "needs root-staged fixtures"
fi
_mutation_arm swallow_find_rc  walk_fails
_mutation_arm no_dir_guard     absent

# ─── 4. The caller-side gate (#982, #882) ────────────────────────────────────
# "drift" is a finding; "unknown" means the scan could not look, which is also a
# finding. Only "ok" may leave overall_status alone.
echo
echo "── overall_status gate: only 'ok' is silent ──"
_extract_gate > "$GATE"
[[ -s "$GATE" ]] || _die "extraction of the gpg overall_status gate produced nothing"
grep -q 'gpg_drift_status' "$GATE" || _die "extracted gate does not mention gpg_drift_status"
bash -n "$GATE" || _die "extracted gate does not parse"

_gate() { # _gate <status> [<gate-file>]
    # gpg_drift_status is read by the extracted gate below, which shellcheck
    # cannot follow through `source` of a runtime path.
    # shellcheck disable=SC2034
    local gpg_drift_status="$1" overall_status="clean"
    # shellcheck disable=SC1090
    source "${2:-$GATE}"
    printf '%s' "$overall_status"
}
_eq "gate: ok"      "clean"    "$(_gate ok)"
_eq "gate: drift"   "warnings" "$(_gate drift)"
_eq "gate: unknown" "warnings" "$(_gate unknown)"

# The gate mutation: score only `drift`, letting "could not look" pass as clean.
# This is #882 exactly, and it must be caught here.
GATE_MUT=$(mktemp) ; trap 'rm -f "$UNIT" "$GATE" "$GATE_MUT"; chmod -R u+rwX "$FIXROOT" 2>/dev/null; rm -rf "$FIXROOT"' EXIT
_apply "$GATE" "$GATE_MUT" 'if [[ "$gpg_drift_status" != "ok" ]]; then' 'if [[ "$gpg_drift_status" == "drift" ]]; then'
if [[ "$(_gate unknown "$GATE_MUT")" == "warnings" ]]; then
    printf '  \033[31mMUTATION INEFFECTIVE\033[0m  %-24s unknown still scored — the gate assertions prove nothing\n' "gate_drift_only"
    FAIL=$((FAIL+1))
else
    _eq "mutation:gate_drift_only" "unknown-scores-clean" "unknown-scores-clean"
fi

# ─── 5. Quiet control ────────────────────────────────────────────────────────
# The unmutated function, re-run after all that rebuilding of $UNIT. A
# disagreement here means the harness is mutating state it should not.
echo
echo "── quiet control (unmutated, re-run) ──"
CONTROL=$(_arm none) || exit 2
_eq "control identical to baseline" "identical" \
    "$([[ "$CONTROL" == "$BASELINE" ]] && echo identical || echo DIVERGED)"

echo
printf 'security-scan §4c gnupg drift: \033[32m%d passed\033[0m, ' "$PASS"
if (( SKIP > 0 )); then printf '\033[33m%d skipped\033[0m, ' "$SKIP"; fi
if (( FAIL > 0 )); then printf '\033[31m%d failed\033[0m\n' "$FAIL"; exit 1; fi
printf '0 failed\n'; exit 0
