#!/usr/bin/env bash
# =============================================================================
# Regression tests — security-scan.sh §4b's fail2ban policy parser (#987)
# =============================================================================
# §4b decides whether a clean rebuild from setup/bootstrap.sh would reproduce
# the ban policy the daemon is actually running. To do that it has to model
# fail2ban's own config semantics, and fail2ban does not use stock defaults: it
# constructs its parser with inline_comment_prefixes=";" (fail2ban's
# client/configparserinc.py), so `;` ends a value and `#` does NOT. Get that
# backwards and `findtime = 3600  # an hour` derives a tidy `3600`, matches the
# daemon, and reports clean on a heredoc that cannot rebuild production.
#
# That reasoning was checked once against ConfigParser itself and then written
# into a review comment, where nothing runs it and nothing notices when the
# parser is edited. This file is that check, committed.
#
# The oracle is Python's configparser configured the way fail2ban configures it
# — a genuinely independent implementation, not a second copy of the awk. Two
# copies of the same wrong shape agree perfectly; that is the failure mode this
# is built to avoid. The Python side also locates the heredoc by its own means
# (string compare, not a sed range), so the marker arm has an independent
# verdict too.
#
# The parser is EXTRACTED FROM THE REAL SCRIPT by marker, not copied here. The
# extracted artifact is `bash -n`'d before it is sourced, so a broken extraction
# fails loudly instead of silently testing nothing.
#
# Every fixture is paired with a MUTATION that must turn it red, and each
# mutation is itself verified to have landed (needle hit count == 1). A guard
# that cannot fail is not a guard; two of those have shipped here before.
#
# NOT covered, and deliberately so: the `degraded` arm (fail2ban-client answers
# for some pairs and not others) lives in §4b's comparison loop, which talks to
# a live daemon and cannot be reached without running the whole scan. The
# `unparseable` arm IS covered, from both of its causes — a renamed heredoc
# marker and a header configparser would reject.
#
# Usage: bash agent/tests/security-scan-4b-parser.test.sh
# Exit:  0 all pass, 1 any failure, 2 harness broken
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${SCRIPT_DIR}/security-scan.sh"

UNIT=$(mktemp) ; ORACLE=$(mktemp) ; FIXDIR=$(mktemp -d)
trap 'rm -f "$UNIT" "$ORACLE"; rm -rf "$FIXDIR"' EXIT

PASS=0 ; FAIL=0
_eq() { # _eq <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        printf '  \033[32mPASS\033[0m  %-34s %s\n' "$1" "${2:0:80}" ; PASS=$((PASS+1))
    else
        printf '  \033[31mFAIL\033[0m  %-34s\n        expected=[%s]\n        actual  =[%s]\n' "$1" "$2" "$3" ; FAIL=$((FAIL+1))
    fi
}
_die() { printf '\033[31mHARNESS BROKEN: %s\033[0m\n' "$1" >&2 ; exit 2 ; }

[[ -r "$TARGET" ]] || _die "cannot read ${TARGET}"

# ─── Extract the real parser ─────────────────────────────────────────────────
# From the `F2B_WATCH_KEYS=` assignment through the second column-0 `}`, which
# closes _f2b_derive_policy. Nothing between them sits at column 0.
_extract() {
    awk '/^F2B_WATCH_KEYS=/ { on=1 } on { print } on && /^\}/ { n++; if (n==2) exit }' "$TARGET"
}

# Whole-line replacement keyed by a literal substring. Needle and replacement
# both travel through the environment, never `awk -v`: -v escape-processes its
# value, and a backslash in it has made an in-use guard fail open before (#923).
# Prints the hit count on fd 3 so an inert mutation is caught, not assumed.
_mutate_line() { # _mutate_line <needle> <replacement>   (stdin -> stdout, count -> fd 3)
    MUT_NEEDLE="$1" MUT_REPL="$2" awk '
        index($0, ENVIRON["MUT_NEEDLE"]) { print ENVIRON["MUT_REPL"]; hits++; next }
        { print }
        END { print hits+0 > "/dev/fd/3" }'
}

_build_unit() { # _build_unit <mutation>
    local mut="$1" needle repl hits
    case "$mut" in
      none)
        _extract > "$UNIT" ; hits=1 ;;
      # The literal suggestion from #976's first review: also treat `#` as an
      # inline comment. It is the wrong character for fail2ban, and it is the
      # reason the hash_in_value fixture exists as a control.
      strip_hash)
        needle='v=$0; sub(/^[^=]*=[ \t]*/,"",v)'
        repl='            v=$0; sub(/^[^=]*=[ \t]*/,"",v); sub(/[ \t]+;.*$/,"",v); sub(/[ \t]+#.*$/,"",v); gsub(/[ \t]+$/,"",v)' ;;
      # Resolve a section header at the FIRST `]` instead of the last — the
      # obvious reading, and not the one configparser's greedy SECTCRE takes.
      first_bracket)
        needle='match(sec, /\][^]]*$/)'
        repl='            match(sec, /\]/); sec=substr(sec, 1, RSTART-1)' ;;
      # Guess at a name for a header configparser rejects outright, instead of
      # refusing the file.
      accept_bad_header)
        needle='if (hdr_bad) exit 1'
        repl='            if (0) exit 1' ;;
      # Drop the [DEFAULT] fallback, so an inherited setting reads as absent.
      no_default)
        needle='else if (("DEFAULT" SUBSEP k) in vals)'
        repl='                else if (0) print ""' ;;
      # Unanchor the heredoc marker from the file it writes, so the check will
      # happily lock onto a heredoc for some other file.
      loose_marker)
        needle='command sed -n "/^cat > '
        repl='    command sed -n "/^cat > .*jail/,/^EOF$/p" \' ;;
      *) _die "unknown mutation ${mut}" ;;
    esac

    if [[ "$mut" != "none" ]]; then
        hits=$(_extract | _mutate_line "$needle" "$repl" 3>&1 1>"$UNIT")
        [[ "$hits" == "1" ]] || _die "mutation ${mut} matched ${hits} lines, expected 1 — the needle has gone stale"
    fi

    [[ -s "$UNIT" ]] || _die "extraction produced nothing — the ${mut} marker moved"
    bash -n "$UNIT" || _die "extracted unit (${mut}) does not parse"
}

# ─── Fixtures ────────────────────────────────────────────────────────────────
# Each is a miniature bootstrap.sh: the heredoc under test, wrapped in enough
# surrounding shell that the marker has something to be distinguished from.
_fixture() { # _fixture <name> <heredoc-target-path>  (body on stdin)
    { printf 'apt-get install -y fail2ban\n\ncat > %s << '"'"'EOF'"'"'\n' "$2"
      cat
      printf 'EOF\n\nsystemctl restart fail2ban\n'
    } > "${FIXDIR}/$1.sh"
}

# The shape production actually has: section-level findtime beating [DEFAULT],
# two jails inheriting everything, and `#` comment lines between them.
_fixture real /etc/fail2ban/jail.local <<'FIXEOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
maxretry = 3
bantime = 86400
# A drop-in from 2024 set this; naming it here makes jail.local win outright.
findtime = 3600

[nginx-http-auth]
enabled = true
FIXEOF

# THE CONTROL. `#` is not fail2ban's inline comment prefix, so the value really
# is "3600  # an hour". A parser that tidies this up invents agreement.
_fixture hash_in_value /etc/fail2ban/jail.local <<'FIXEOF'
[DEFAULT]
findtime = 600
maxretry = 3
bantime = 3600

[sshd]
findtime = 3600  # an hour
maxretry = 3#three
FIXEOF

# `;` IS the inline comment prefix, and only when preceded by whitespace.
_fixture semicolon_in_value /etc/fail2ban/jail.local <<'FIXEOF'
[DEFAULT]
findtime = 600
maxretry = 3
bantime = 3600

[sshd]
bantime = 600 ; ten minutes
findtime = 900;not-a-comment
FIXEOF

# A `;` comment on the header line, and a whole-line `;` comment.
_fixture semicolon_on_header /etc/fail2ban/jail.local <<'FIXEOF'
[DEFAULT]
findtime = 600
maxretry = 3
bantime = 3600
; a whole-line comment

[sshd] ; the ssh jail
maxretry = 5
FIXEOF

# configparser's SECTCRE is greedy: the header ends at the LAST `]`.
_fixture nested_brackets /etc/fail2ban/jail.local <<'FIXEOF'
[DEFAULT]
findtime = 600
maxretry = 3
bantime = 3600

[nginx[bot]]
maxretry = 4
FIXEOF

# Nothing overridden — every derived value must carry origin DEFAULT.
_fixture default_inherit /etc/fail2ban/jail.local <<'FIXEOF'
[DEFAULT]
findtime = 600
maxretry = 3
bantime = 3600

[sshd]
enabled = true
FIXEOF

# A header with no `]`. configparser refuses the whole file; so must §4b,
# rather than deriving a policy from a name it guessed.
_fixture unterminated_header /etc/fail2ban/jail.local <<'FIXEOF'
[DEFAULT]
findtime = 600
maxretry = 3
bantime = 3600

[sshd
maxretry = 3
FIXEOF

# The heredoc still exists, but writes a different file. §4b must report that it
# could not look, not that it looked and found nothing wrong.
_fixture renamed_marker /etc/fail2ban/jail.other <<'FIXEOF'
[DEFAULT]
findtime = 600
maxretry = 3
bantime = 3600

[sshd]
findtime = 7200
FIXEOF

FIXTURES=(real hash_in_value semicolon_in_value semicolon_on_header
          nested_brackets default_inherit unterminated_header renamed_marker)

# ─── The oracle ──────────────────────────────────────────────────────────────
cat > "$ORACLE" <<'PYEOF'
import configparser, sys

WATCH = ["findtime", "maxretry", "bantime"]
OPEN  = "cat > /etc/fail2ban/jail.local << 'EOF'"

# Locate the heredoc independently of the sed range under test: exact line
# compare, then everything up to the next line that is exactly EOF.
lines = open(sys.argv[1]).read().splitlines()
body = None
for i, line in enumerate(lines):
    if line == OPEN:
        for j in range(i + 1, len(lines)):
            if lines[j] == "EOF":
                body = lines[i + 1:j]
                break
        break
if body is None or not body:
    print("NOBODY"); sys.exit(0)

# fail2ban's kwargs: SafeConfigParserWithIncludes forces
# inline_comment_prefixes=";" and leaves the whole-line prefixes at ("#", ";").
cp = configparser.ConfigParser(inline_comment_prefixes=";")
try:
    cp.read_string("\n".join(body) + "\n")
except Exception:
    print("REFUSED"); sys.exit(0)

rows = []
for sec in cp.sections():
    raw = cp._sections[sec]
    for key in WATCH:
        if key in raw:
            rows.append((sec, key, raw[key], "jail"))
        elif key in cp.defaults():
            rows.append((sec, key, cp.defaults()[key], "DEFAULT"))
rows.sort(key=lambda r: (r[0], r[1]))          # matches LC_ALL=C sort -k1,1 -k2,2
print("|".join("\t".join(r) for r in rows) if rows else "EMPTY")
PYEOF

command -v python3 >/dev/null || _die "python3 absent — the oracle cannot run"

# ─── Run one arm ─────────────────────────────────────────────────────────────
# Prints "<fixture> <expected> <actual>" per fixture, tab-separated.
_arm() { # _arm <mutation>
    _build_unit "$1"
    local f exp act
    for f in "${FIXTURES[@]}"; do
        exp=$(python3 "$ORACLE" "${FIXDIR}/${f}.sh") || _die "oracle failed on ${f}"
        act=$(
            set -uo pipefail           # as production does; -e omitted so rc is capturable
            # shellcheck source=/dev/null
            source "$UNIT"
            body=$(_f2b_heredoc_body "${FIXDIR}/${f}.sh")
            if [[ -z "$body" ]]; then printf 'NOBODY'; exit 0; fi
            rows=$(printf '%s\n' "$body" | _f2b_derive_policy); rc=$?
            if   (( rc != 0 ));      then printf 'REFUSED'
            elif [[ -z "$rows" ]];   then printf 'EMPTY'
            else printf '%s' "$rows" | tr '\n' '|' | command sed 's/|$//'
            fi
        )
        printf '%s\037%s\037%s\n' "$f" "$exp" "$act"
    done
}

# ─── 1. The real parser must agree with the oracle on every fixture ──────────
echo
echo "── parser vs ConfigParser oracle (unmutated) ──"
BASELINE=$(_arm none) || exit 2
while IFS=$'\037' read -r f exp act; do
    [[ -z "$f" ]] && continue
    _eq "$f" "$exp" "$act"
done <<< "$BASELINE"

# ─── 2. Every mutation must turn at least one fixture red ────────────────────
# A mutation that changes nothing means the assertion above was never load-
# bearing. The expected-red list is named, so a mutation that goes red on the
# WRONG fixture is a failure too, not a shrug.
echo
echo "── mutations (each must break the fixture it is aimed at) ──"
_mutation_arm() { # _mutation_arm <mutation> <fixture-that-must-go-red>...
    local mut="$1"; shift
    local out red=""
    out=$(_arm "$mut") || exit 2
    while IFS=$'\037' read -r f exp act; do
        [[ -z "$f" ]] && continue
        [[ "$exp" != "$act" ]] && red+="${f} "
    done <<< "$out"
    red=$(printf '%s' "$red" | command sed 's/ $//')
    if [[ -z "$red" ]]; then
        printf '  \033[31mMUTATION INEFFECTIVE\033[0m  %-22s broke nothing — the assertions above prove nothing\n' "$mut"
        FAIL=$((FAIL+1)); return
    fi
    _eq "mutation:${mut}" "$*" "$red"
}

_mutation_arm strip_hash        hash_in_value
_mutation_arm first_bracket     nested_brackets
_mutation_arm accept_bad_header unterminated_header
_mutation_arm no_default        real hash_in_value semicolon_in_value semicolon_on_header nested_brackets default_inherit
_mutation_arm loose_marker      renamed_marker

# ─── 3. Quiet control ────────────────────────────────────────────────────────
# The unmutated parser, re-run after all that rebuilding of $UNIT. If this ever
# disagrees with the first arm, the harness is mutating state it should not.
echo
echo "── quiet control (unmutated, re-run) ──"
CONTROL=$(_arm none) || exit 2
_eq "control identical to baseline" "identical" \
    "$([[ "$CONTROL" == "$BASELINE" ]] && echo identical || echo DIVERGED)"

echo
printf 'security-scan §4b parser: \033[32m%d passed\033[0m, ' "$PASS"
if (( FAIL > 0 )); then printf '\033[31m%d failed\033[0m\n' "$FAIL"; exit 1; fi
printf '0 failed\n'; exit 0
