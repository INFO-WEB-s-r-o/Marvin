#!/usr/bin/env bash
# =============================================================================
# Regression tests — external-domains-check.sh authority parser + pin guards
# =============================================================================
# Covers the logic #965 added to agent/external-domains-check.sh, which had no
# test coverage at all despite three review rounds finding escapes in it (#968):
#
#   _http_check      the scheme://[userinfo@]host[:port] parser whose output the
#                    caller compares against the --resolve pin. Every escape
#                    this PR fixed was a parse that looked right: a cross-host
#                    redirect (round 1), then a same-host/other-PORT redirect
#                    that kept final_host == host and slipped back onto the
#                    local resolver (#966, round 3).
#   _is_public_ipv4  the range predicate added for #967 — a dotted quad is not
#                    proof the address is off this machine.
#
# WHY A STANDALONE FILE, not a self-test.sh section (which is what #968 asked
# for): 13 open PRs currently edit agent/self-test.sh and section letters have
# collided three times (#920, #927), so a new lettered section is the one change
# most likely to be lost in a merge. self-test.sh also has no automatic caller —
# it runs when an agent session decides to. This file is run by CI on every pull
# request instead (.github/workflows/tests.yml), which is a strictly more
# reliable caller than the section would have had.
#
# The functions are extracted from the SHIPPED script by name marker and
# `bash -n`-checked before sourcing, so these assertions cannot drift onto a
# stale copy: delete or rename a function and extraction fails loudly.
#
# Falsification is built in — the assertions are worthless until they have been
# seen to fail. MUTATE=<name> breaks one behaviour before sourcing:
#     MUTATE=list                 list the available mutations
#     MUTATE=no_userinfo_strip    stop stripping userinfo from the authority
#     MUTATE=no_scheme_port       stop defaulting the port from the scheme
#     MUTATE=no_ipv6_brackets     parse IPv6 literals as host:port
#     MUTATE=public_always_true   accept every address as public
# Each must turn some assertion below RED. If a mutation changes nothing, the
# test it was aimed at is not testing anything.
# =============================================================================

# `-e` is absent where the rest of the repo uses `set -euo pipefail`. The
# tempting explanation — that errexit would abort on the first failed
# comparison instead of tallying every FAIL — is wrong, and was measured
# before being written here: `_eq` decides with `if/else`, both branches
# succeed, so an assertion failure is never a non-zero command and errexit has
# nothing to fire on. Adding `-e` changes nothing. All five arms (unmutated
# plus each of the four mutations) produce byte-identical tallies and exit
# codes either way: 98/0 exit 0, 96/2, 91/7, 97/1, 54/44, each exit 1.
#
# So this is a free choice, not load-bearing, and that is the point of the
# comment: leave it alone *or* change it, but do not do either believing it
# protects the tally. What does protect the tally is `_eq` itself, and the CI
# mutation step's insistence on exit 1 specifically — exit 2 is `_die`, a
# broken harness, and is not accepted as evidence (#965 review r8).
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/external-domains-check.sh"
PASS=0; FAIL=0
FAILED_NAMES=()

_die() { printf 'TEST HARNESS BROKE: %s\n' "$1" >&2; exit 2; }

[[ -f "$SRC" ]] || _die "source not found at $SRC"

# ─── Extract the functions under test ────────────────────────────────────────
# By name marker, never by line number: a line-range extract goes stale
# silently and then prints a plausible pass table for a fragment of a function.
_extract() {
    local fn="$1" out
    out=$(awk -v fn="$fn" '
        $0 ~ "^"fn"\\(\\) \\{" { inside=1 }
        inside                 { print; body++ }
        inside && /^\}$/       { found=1; exit }
        END { if (!found) exit 3 }
    ' "$SRC") || _die "could not extract ${fn}() from $SRC (renamed or removed?)"
    [[ -n "$out" ]] || _die "extracted ${fn}() is empty"
    printf '%s\n' "$out"
}

UNIT="$(mktemp)"
trap 'rm -f "$UNIT"' EXIT
{
    echo '#!/usr/bin/env bash'
    _extract _is_public_ipv4
    echo
    _extract _http_check
    echo
    _extract _public_ip
} > "$UNIT"

# Confirm we actually captured whole functions, not a fragment that happens to
# parse in isolation.
for fn in _is_public_ipv4 _http_check _public_ip; do
    grep -q "^${fn}() {" "$UNIT" || _die "extraction lost ${fn}()"
done

# ─── Mutations (falsification) ───────────────────────────────────────────────
# The names are read back out of the case arms below rather than kept as a
# second copy anywhere. CI drives its mutation loop from `MUTATE=list`, so a
# hand-maintained list here would just move the drift one file to the left: a
# mutation added below and forgotten here would never be exercised, and nothing
# would say so.
_mutation_names() {
    local names
    names=$(sed -n '/^# ─── Mutations (falsification)/,/^esac$/p' "${BASH_SOURCE[0]}" \
        | sed -n 's/^    \([a-z_][a-z0-9_]*\)).*/\1/p' \
        | grep -v '^list$')
    [[ -n "$names" ]] || return 1
    printf '%s\n' "$names"
}

MUTATE="${MUTATE:-}"
case "$MUTATE" in
    "") ;;
    list)
        _mutation_names || _die "could not derive the mutation list from my own case arms"
        exit 0 ;;
    no_userinfo_strip)
        # The line that drops "user@" — its absence is how a redirect to
        # https://pinnedhost@evil.example/ would read as the pinned host.
        grep -q 'auth="${auth##\*@}"' "$UNIT" || _die "mutation target 'auth##*@' not found — code changed"
        sed -i 's/auth="${auth##\*@}"/: "keep userinfo"/' "$UNIT" ;;
    no_scheme_port)
        grep -q 'https) final_port=443' "$UNIT" || _die "mutation target 'https) final_port=443' not found"
        sed -i 's/https) final_port=443 ;;/https) : ;;/' "$UNIT" ;;
    no_ipv6_brackets)
        grep -q 'final_host="${auth%%\\]\*}\]"' "$UNIT" \
            || grep -q 'IPv6 literal' "$UNIT" || _die "mutation target (IPv6 branch) not found"
        sed -i 's/if \[\[ "$auth" == \\\[\*\\\]\* \]\]; then/if false; then/' "$UNIT" ;;
    public_always_true)
        grep -q '^_is_public_ipv4() {' "$UNIT" || _die "mutation target _is_public_ipv4 not found"
        # Replace the whole predicate with an unconditional accept.
        awk '
            /^_is_public_ipv4\(\) \{/ { print "_is_public_ipv4() { return 0"; skip=1; next }
            skip && /^\}$/            { print "}"; skip=0; next }
            skip                      { next }
            { print }
        ' "$UNIT" > "${UNIT}.m" && mv "${UNIT}.m" "$UNIT" ;;
    *) _die "unknown MUTATE='$MUTATE' (try MUTATE=list)" ;;
esac

# A mutation that broke the syntax would abort every arm and read as "no
# result"; bash -n separates "the code is wrong" from "the harness is wrong".
bash -n "$UNIT" || _die "extracted unit does not parse (bash -n failed)"
# shellcheck source=/dev/null
source "$UNIT" || _die "extracted unit failed to source"

# ─── Assertion helpers ───────────────────────────────────────────────────────
_eq() {  # _eq <name> <expected> <actual>
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        PASS=$((PASS + 1)); printf '  PASS  %-46s %s\n' "$name" "$got"
    else
        FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name")
        printf '  FAIL  %-46s want=[%s] got=[%s]\n' "$name" "$want" "$got"
    fi
}

# ─── curl / dig stubs ────────────────────────────────────────────────────────
# _http_check's whole job under test is parsing curl's -w output, so curl is
# replaced by something that emits a scripted line. Nothing here touches the
# network: no real domain is probed and ai4shops' serverless DB is never woken.
STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS" "$UNIT"' EXIT
cat > "${STUBS}/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${STUB_CURL_OUT:-}"
exit "${STUB_CURL_RC:-0}"
STUB
cat > "${STUBS}/dig" <<'STUB'
#!/usr/bin/env bash
# Answers per-resolver from STUB_DIG_<n>, indexed by call order.
n=$(cat "${STUB_DIG_COUNT}" 2>/dev/null || echo 0); n=$((n + 1))
printf '%s' "$n" > "${STUB_DIG_COUNT}"
var="STUB_DIG_${n}"
printf '%s\n' "${!var-}"
STUB
chmod +x "${STUBS}/curl" "${STUBS}/dig"
PATH="${STUBS}:${PATH}"

_parse() {  # _parse <url_effective> -> _http_check's echoed line
    STUB_CURL_OUT="200 0.100 $1" _http_check "https://pinned.example/" pinned.example 203.0.113.9
}

# ═══ 1. Authority parser — the cases the CHANGELOG claimed were covered ══════
echo "─── _http_check authority parsing ───"
_eq "userinfo stripped (host@evil)"        "200 100 evil.example:443"   "$(_parse 'https://host@evil.example/')"
_eq "userinfo with colon, explicit port"   "200 100 example.com:8443"   "$(_parse 'https://u:p@example.com:8443/x')"
_eq "':'/'@' inside path"                  "200 100 example.com:443"    "$(_parse 'https://example.com/a:b@c')"
_eq "'@' and ':' inside query"             "200 100 example.com:443"    "$(_parse 'https://example.com/p?u=a@b:9')"
_eq "'@' inside fragment"                  "200 100 example.com:443"    "$(_parse 'https://example.com/#x@y:1')"
_eq "explicit https port kept"             "200 100 example.com:8443"   "$(_parse 'https://example.com:8443/')"
_eq "https default port"                   "200 100 example.com:443"    "$(_parse 'https://example.com/')"
_eq "http default port"                    "200 100 example.com:80"     "$(_parse 'http://example.com/')"
_eq "uppercase authority folded"           "200 100 example.com:443"    "$(_parse 'HTTPS://EXAMPLE.COM/')"
_eq "mixed-case host folded"               "200 100 example.com:8443"   "$(_parse 'https://ExAmPlE.CoM:8443/')"
_eq "IPv6 literal with port"               "200 100 [::1]:9091"         "$(_parse 'https://[::1]:9091/')"
_eq "IPv6 literal, default port"           "200 100 [::1]:443"          "$(_parse 'https://[::1]/')"
_eq "non-http scheme fails closed"         "200 100 example.com:?"      "$(_parse 'ftp://example.com/')"
_eq "no scheme fails closed"               "200 100 example.com:?"      "$(_parse 'example.com/x')"

# #966: a same-host redirect to another PORT. --resolve is scoped to the exact
# port it names, so this hop went through the local resolver. The authority must
# come back carrying :8443 — folding it to :443 is precisely the bug, because
# the caller's comparison would then match the pin and publish it as external.
_eq "#966 off-pin port NOT folded to 443"  "200 100 pinned.example:8443" "$(_parse 'https://pinned.example:8443/')"
_eq "#966 off-pin plain port"              "200 100 pinned.example:8080" "$(_parse 'http://pinned.example:8080/')"
# The caller rejects anything that is neither host:80 nor host:443 — assert the
# comparison the caller actually makes, not just the string.
for auth in "pinned.example:8443" "pinned.example:?" "evil.example:443"; do
    host=pinned.example
    if [[ "$auth" != "${host,,}:80" && "$auth" != "${host,,}:443" ]]; then verdict=rejected; else verdict=accepted; fi
    _eq "caller verdict on ${auth}" "rejected" "$verdict"
done
for auth in "pinned.example:443" "pinned.example:80"; do
    host=pinned.example
    if [[ "$auth" != "${host,,}:80" && "$auth" != "${host,,}:443" ]]; then verdict=rejected; else verdict=accepted; fi
    _eq "caller verdict on ${auth}" "accepted" "$verdict"
done

echo "─── _http_check failure shape ───"
_eq "curl died: two fields, no authority" "000 0" \
    "$(STUB_CURL_OUT="" STUB_CURL_RC=6 _http_check 'https://pinned.example/' pinned.example 203.0.113.9)"
_eq "empty url_effective: two fields"     "000 0" \
    "$(STUB_CURL_OUT="000 0 " _http_check 'https://pinned.example/' pinned.example 203.0.113.9)"

# ═══ 2. _is_public_ipv4 — #967 ══════════════════════════════════════════════
echo "─── _is_public_ipv4 rejects unroutable answers (#967) ───"
_pub() { if _is_public_ipv4 "$1"; then echo public; else echo rejected; fi; }
for ip in 127.0.0.1 127.0.1.1 127.255.255.255 10.0.0.1 10.255.255.255 \
          172.16.0.1 172.31.255.255 192.168.1.1 169.254.169.254 \
          0.0.0.0 100.64.0.1 100.127.255.255 224.0.0.1 239.1.1.1 \
          255.255.255.255 240.0.0.1; do
    _eq "reject ${ip}" "rejected" "$(_pub "$ip")"
done
# 127.0.1.1 above is the exact address in /etc/hosts that #964 was filed for —
# reached through the DNS answer this time instead of the hosts file.
for ip in 80.211.223.26 8.8.8.8 1.1.1.1 9.9.9.9 223.255.255.255 \
          172.15.255.255 172.32.0.1 192.167.1.1 192.169.1.1 \
          100.63.255.255 100.128.0.1 11.0.0.1 126.255.255.255 1.0.0.0; do
    _eq "accept ${ip}" "public" "$(_pub "$ip")"
done
echo "─── _is_public_ipv4 rejects the rest of the special-purpose registry ───"
# TEST-NET-1/2/3, IETF protocol assignments and the benchmarking range. Each
# reject is paired with both of its neighbouring /24s (or /15) so the test
# proves a bounded range and not a whole prefix quietly disappearing: a rule
# written as `o1 == 203` would pass every reject row below and be caught only
# by the accept rows.
for ip in 192.0.0.1 192.0.0.255 192.0.2.1 192.0.2.255 \
          198.51.100.1 198.51.100.255 203.0.113.1 203.0.113.255 \
          198.18.0.1 198.19.255.255; do
    _eq "reject ${ip}" "rejected" "$(_pub "$ip")"
done
for ip in 192.0.1.1 192.0.3.1 192.1.2.1 198.51.99.1 198.51.101.1 \
          198.52.100.1 203.0.112.1 203.0.114.1 203.1.113.1 \
          198.17.255.255 198.20.0.1; do
    _eq "accept neighbour ${ip}" "public" "$(_pub "$ip")"
done
# NOTE for a future reader tempted to "fix" the inconsistency: section 1 pins
# _http_check fixtures to 203.0.113.9, which this section now rejects. Both are
# correct. _http_check takes an already-resolved pin as an argument and never
# consults _is_public_ipv4 — the screening happens once, in _public_ip. RFC 5737
# is exactly what a documentation fixture should use.

echo "─── _is_public_ipv4 rejects malformed input ───"
for bad in "" "abc" "1.2.3" "1.2.3.4.5" "256.1.1.1" "1.256.1.1" "1.1.1.256" \
           "-1.1.1.1" "1.1.1" "1.1.1.a" "999.999.999.999" " 8.8.8.8"; do
    _eq "reject malformed [${bad}]" "rejected" "$(_pub "$bad")"
done
# Zero-padded octets must be read base 10, not octal: 010 is ten, and
# 010.0.0.1 is therefore inside 10.0.0.0/8 and must be rejected.
_eq "zero-padded 010.0.0.1 is 10/8"  "rejected" "$(_pub 010.0.0.1)"
_eq "zero-padded 008.008.008.008"    "public"   "$(_pub 008.008.008.008)"

# ═══ 3. _public_ip wiring — a rejected answer must not become a pin ═════════
echo "─── _public_ip advances past non-public answers (#967) ───"
export STUB_DIG_COUNT="${STUBS}/digcount"
_resolve() {  # args: answer per resolver, in order
    : > "$STUB_DIG_COUNT"
    STUB_DIG_1="${1-}" STUB_DIG_2="${2-}" STUB_DIG_3="${3-}" \
        PUBLIC_RESOLVERS="8.8.8.8 1.1.1.1 9.9.9.9" _public_ip pinned.example 2>/dev/null
}
_eq "first resolver public -> used"        "80.211.223.26" "$(_resolve 80.211.223.26 80.211.223.26 80.211.223.26)"
_eq "poisoned 1st, public 2nd -> 2nd"      "80.211.223.26" "$(_resolve 127.0.0.1 80.211.223.26 80.211.223.26)"
_eq "poisoned 1st+2nd, public 3rd -> 3rd"  "80.211.223.26" "$(_resolve 10.0.0.1 192.168.1.1 80.211.223.26)"
_eq "ALL poisoned -> empty, never a pin"   ""              "$(_resolve 127.0.1.1 10.0.0.1 192.168.1.1)"
_eq "no answers at all -> empty"           ""              "$(_resolve '' '' '')"
# The critical one: the returned value must be empty, NOT the loopback address.
# An empty return drives the caller's pin_failed=1 path (000/failing); returning
# 127.0.1.1 would pin curl to this machine and publish a confident 200.
_eq "ALL poisoned -> not loopback"         "not-loopback" \
    "$( r="$(_resolve 127.0.1.1 127.0.0.1 10.0.0.1)"; [[ "$r" == *127.* || "$r" == *10.* ]] && echo "LOOPBACK-PINNED:$r" || echo not-loopback )"
# Mirror arm: the guard must stay quiet on the answer it should not change.
_eq "MIRROR public answer untouched"       "80.211.223.26" "$(_resolve 80.211.223.26)"
# Rejection must be visible to an operator, and must NOT go to stdout (which is
# the address the caller pins).
_stderr="$( : > "$STUB_DIG_COUNT"; STUB_DIG_1=127.0.0.1 STUB_DIG_2=127.0.0.1 STUB_DIG_3=127.0.0.1 \
            PUBLIC_RESOLVERS="8.8.8.8 1.1.1.1 9.9.9.9" _public_ip pinned.example 2>&1 >/dev/null )"
_eq "rejection is logged to stderr"        "logged" \
    "$( [[ "$_stderr" == *"non-public address"* ]] && echo logged || echo "MISSING:[$_stderr]" )"

# ═══ 4. The falsification harness describes itself accurately ═══════════════
# CI runs exactly the mutations `MUTATE=list` names. Two ways that stops being
# true without anyone noticing: the derivation itself breaks and silently
# returns nothing (CI would then verify zero mutations and stay green), or a
# mutation is implemented but never written into the header block a human
# reads. Both are the prose-vs-code drift this repo keeps rediscovering.
echo "─── mutation list is derived, not remembered ───"
_arm_names="$(_mutation_names | sort | tr '\n' ' ')"
# Deliberately NOT compared against a literal list of names here: that would be
# a third copy, and the drift would just move into this assertion. The header
# block is an independent source, so an empty or broken derivation cannot agree
# with it by accident.
_eq "derivation returns something" "derived" \
    "$( [[ -n "$_arm_names" ]] && echo derived || echo "EMPTY — CI would verify no mutations" )"
_doc_names="$(sed -n 's/^#     MUTATE=\([a-z_][a-z0-9_]*\)  *.*/\1/p' "${BASH_SOURCE[0]}" \
    | grep -v '^list$' | sort | tr '\n' ' ')"
_eq "header block lists what is implemented" "$_arm_names" "$_doc_names"

# ─── Report ──────────────────────────────────────────────────────────────────
echo
echo "───────────────────────────────────────────"
printf ' external-domains parser tests: %d pass, %d fail' "$PASS" "$FAIL"
[[ -n "$MUTATE" ]] && printf '  (MUTATE=%s)' "$MUTATE"
echo
if (( FAIL > 0 )); then
    printf ' failed: %s\n' "${FAILED_NAMES[*]}"
fi
echo "───────────────────────────────────────────"
(( FAIL == 0 ))
