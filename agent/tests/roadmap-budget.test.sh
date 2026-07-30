#!/usr/bin/env bash
# =============================================================================
# Regression tests — self-enhance.sh's roadmap prompt bound (_bounded_roadmap)
# =============================================================================
# The function under test decides how much of POSSIBLE_ENHANCEMENTS.md reaches
# the model. Getting it wrong is not cosmetic in either direction:
#
#   too much  → the prompt passes run_claude's 400,000-char ceiling and is cut
#               by a blunt byte slice (this happened 2026-07-20 and 07-27; the
#               07-27 slice discarded the one script that had actually failed)
#   too little → an unchecked roadmap item silently disappears, and a session
#               picking "from the earliest incomplete phase" cannot tell the
#               difference between "done" and "never shown to me"
#
# So the load-bearing invariant is: EVERY unchecked item survives, always.
#
# The function is EXTRACTED FROM THE REAL SCRIPT by marker, not copied here — a
# copy would drift and then agree with itself forever. The extracted artifact is
# `bash -n`'d before it is sourced, so a syntax-broken extraction fails loudly
# instead of silently testing nothing.
#
# Every assertion is paired with a MUTATION that must turn it red. A guard that
# cannot fail is not a guard, and two of those have shipped here before.
#
# Usage: bash agent/tests/roadmap-budget.test.sh
# Exit:  0 all pass, 1 any failure
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET="${SCRIPT_DIR}/self-enhance.sh"
REAL_ROADMAP="${REPO_DIR}/POSSIBLE_ENHANCEMENTS.md"

UNIT=$(mktemp)  ;  FIXTURE=$(mktemp)
trap 'rm -f "$UNIT" "$FIXTURE"' EXIT

PASS=0 ; FAIL=0
_eq() { # _eq <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        printf '  \033[32mPASS\033[0m  %-52s %s\n' "$1" "$2" ; PASS=$((PASS+1))
    else
        printf '  \033[31mFAIL\033[0m  %-52s expected=[%s] actual=[%s]\n' "$1" "$2" "$3" ; FAIL=$((FAIL+1))
    fi
}
_die() { printf '\033[31mHARNESS BROKEN: %s\033[0m\n' "$1" >&2 ; exit 1 ; }

# ─── Extract the real function ───────────────────────────────────────────────
# From the `_ROADMAP_LOG_HEADER=` assignment through the first column-0 `}`,
# which closes _bounded_roadmap. Nothing between them sits at column 0.
_extract() {
    awk '/^_ROADMAP_LOG_HEADER=/ { on=1 } on { print } on && /^\}/ { exit }' "$TARGET"
}

_build_unit() {   # _build_unit [mutation]
    local mutation="${1:-none}"
    {
        echo '#!/usr/bin/env bash'
        # marvin_log writes to STDOUT in production (lib/logging.sh). Stub it to
        # stderr and record it, so a call that forgot its >&2 redirect would
        # corrupt this stub's stdout exactly as it corrupts the real prompt.
        echo 'marvin_log() { printf "MARVIN_LOG[%s] %s\n" "$1" "$2" >&2; }'
        case "$mutation" in
            none) _extract ;;
            # Emit only the completed-log side: drops the phase sections, i.e.
            # every unchecked item. The unchecked-survival assertions MUST fail.
            drop_phases)   _extract | sed 's|^    head -n "\$((header_line - 1))" "\$file"$|    : # MUTATED: phases dropped|' ;;
            # Slice by bytes with no regard for entry boundaries — the blunt cut
            # this function exists to avoid. Boundary assertions MUST fail.
            byte_slice)    _extract | sed 's|^        over { next }$|        { if (bytes >= budget) next }|' ;;
            # Never report what was left out. The omission-notice assertion MUST fail.
            silent_drop)   _extract | sed 's|^            if (dropped > 0) {$|            if (0) {|' ;;
            # Treat a missing header as "nothing to bound" and emit nothing —
            # the silent-empty-roadmap failure. Fallback assertions MUST fail.
            quiet_fallback) _extract | sed 's|^        cat "\$file"$|        : # MUTATED: emit nothing|' ;;
            *) _die "unknown mutation $mutation" ;;
        esac
    } > "$UNIT"
    grep -q '^_bounded_roadmap() {' "$UNIT" || _die "extraction lost _bounded_roadmap (marker drift?)"
    bash -n "$UNIT" || _die "extracted unit does not parse (mutation=$mutation)"
    # shellcheck disable=SC1090
    source "$UNIT"
}

# ─── Fixture: N entries of known size, M unchecked items ─────────────────────
# Entries are MULTI-LINE on purpose. 38 of the real file's 249 entries span more
# than one line, and that is the only shape that can tell an entry-boundary cut
# apart from a line-boundary one: with single-line entries the two coincide, so
# a fixture built from those would let a line-slicing regression pass. Each
# entry carries an explicit ENTRY-n-END terminator, so a severed entry shows up
# as a header with no matching terminator rather than having to be eyeballed.
_make_fixture() {  # _make_fixture <n_entries> <n_unchecked> <entry_bytes>
    local n="$1" unchecked="$2" size="$3" i pad
    pad=$(head -c "$size" /dev/zero | tr '\0' 'x')
    {
        echo '# Possible Enhancements'
        echo
        echo '## Phase 1 — Survival'
        for ((i=1; i<=unchecked; i++)); do echo "- [ ] UNCHECKED-ITEM-${i}"; done
        echo '- [x] an already-done inline item'
        echo
        echo '## Completed Enhancements Log'
        echo
        for ((i=1; i<=n; i++)); do
            echo "- [x] **[2026-07-$(printf '%02d' $(( (i % 28) + 1 )) )]** ENTRY-${i} ${pad}"
            echo "  continuation of ENTRY-${i}"
            echo "  ENTRY-${i}-END"
            echo
        done
    } > "$FIXTURE"
}

_count_unchecked()  { grep -c '^- \[ \]' <<<"$1" || true; }
_count_entries()    { grep -c '^- \[x\] \*\*\[' <<<"$1" || true; }
_count_terminators() { grep -c 'ENTRY-[0-9]*-END' <<<"$1" || true; }

echo "═══ _bounded_roadmap — extracted from $(basename "$TARGET") ═══"
echo

# ═══ 1. The load-bearing invariant: unchecked items always survive ══════════
echo "─── unchecked items survive the bound ───"
_build_unit none
_make_fixture 40 12 4000          # 40 entries x ~4 KB = 160 KB, budget 20 KB
OUT=$(_bounded_roadmap "$FIXTURE" 20000)
_eq "all 12 unchecked items kept (budget far exceeded)" "12" "$(_count_unchecked "$OUT")"
_eq "phase header kept"                                 "1"  "$(grep -c '^## Phase 1' <<<"$OUT" || true)"

# The mutation half: prove that assertion CAN fail.
_build_unit drop_phases
OUT_M=$(_bounded_roadmap "$FIXTURE" 20000)
MUT=$(_count_unchecked "$OUT_M")
if [[ "$MUT" == "12" ]]; then
    printf '  \033[31mFAIL\033[0m  %-52s MUTATION INEFFECTIVE — guard cannot fail\n' "drop_phases must break unchecked survival"; FAIL=$((FAIL+1))
else
    printf '  \033[32mPASS\033[0m  %-52s MUTATION EFFECTIVE (kept %s, not 12)\n' "drop_phases breaks unchecked survival" "$MUT"; PASS=$((PASS+1))
fi

# ═══ 2. The cut lands on an entry boundary ══════════════════════════════════
echo "─── whole entries only, never a severed one ───"
_build_unit none
_make_fixture 40 12 4000
OUT=$(_bounded_roadmap "$FIXTURE" 20000)
# Every kept entry must still carry its terminator: header count == terminator
# count. A cut that stops partway through an entry leaves a header with none.
KEPT=$(_count_entries "$OUT")
_eq "every kept entry is whole (headers == terminators)" "$KEPT" "$(_count_terminators "$OUT")"
[[ "$KEPT" -gt 0 && "$KEPT" -lt 40 ]] \
    && { printf '  \033[32mPASS\033[0m  %-52s %s of 40\n' "bound actually bit (kept a strict subset)" "$KEPT"; PASS=$((PASS+1)); } \
    || { printf '  \033[31mFAIL\033[0m  %-52s kept=%s\n' "bound actually bit" "$KEPT"; FAIL=$((FAIL+1)); }

# Mutation: cut on the line that crosses the budget instead of at the next entry
# boundary. On a multi-line entry that severs it — header kept, terminator lost.
_build_unit byte_slice
OUT_M=$(_bounded_roadmap "$FIXTURE" 20000)
H_M=$(_count_entries "$OUT_M") ; T_M=$(_count_terminators "$OUT_M")
if [[ "$H_M" == "$T_M" ]]; then
    printf '  \033[31mFAIL\033[0m  %-52s MUTATION INEFFECTIVE (h=%s t=%s)\n' "byte_slice must sever an entry" "$H_M" "$T_M"; FAIL=$((FAIL+1))
else
    printf '  \033[32mPASS\033[0m  %-52s MUTATION EFFECTIVE (h=%s t=%s)\n' "byte_slice severs an entry" "$H_M" "$T_M"; PASS=$((PASS+1))
fi

# ═══ 3. What was dropped is named ═══════════════════════════════════════════
echo "─── the remainder is reported, not silently dropped ───"
_build_unit none
_make_fixture 40 12 4000
OUT=$(_bounded_roadmap "$FIXTURE" 20000)
KEPT=$(_count_entries "$OUT")
# The notice line itself is not an entry, so kept excludes it.
_eq "omission notice present"                           "1"  "$(grep -c 'older completed entries omitted' <<<"$OUT" || true)"
_eq "notice names the exact dropped count"              "$((40 - KEPT))" "$(grep -oE '^_\(([0-9]+) older' <<<"$OUT" | grep -oE '[0-9]+' || true)"
_eq "notice says the history is still on disk"          "1"  "$(grep -c 'full history is in POSSIBLE_ENHANCEMENTS.md' <<<"$OUT" || true)"

# Nothing dropped → no notice at all (the mirror half: stay quiet when clean).
OUT_SMALL=$(_bounded_roadmap "$FIXTURE" 900000)
_eq "budget not reached: all 40 entries kept"           "40" "$(_count_entries "$OUT_SMALL")"
_eq "budget not reached: no omission notice"            "0"  "$(grep -c 'older completed entries omitted' <<<"$OUT_SMALL" || true)"

_build_unit silent_drop
OUT_M=$(_bounded_roadmap "$FIXTURE" 20000)
if [[ "$(grep -c 'older completed entries omitted' <<<"$OUT_M" || true)" == "1" ]]; then
    printf '  \033[31mFAIL\033[0m  %-52s MUTATION INEFFECTIVE\n' "silent_drop must remove the notice"; FAIL=$((FAIL+1))
else
    printf '  \033[32mPASS\033[0m  %-52s MUTATION EFFECTIVE\n' "silent_drop removes the notice"; PASS=$((PASS+1))
fi

# ═══ 4. Missing header → unbounded + loud, never silently empty ═════════════
echo "─── restructured file: fail toward too much, and say so ───"
_build_unit none
_make_fixture 40 12 100
grep -v '^## Completed Enhancements Log$' "$FIXTURE" > "${FIXTURE}.nohdr" && mv "${FIXTURE}.nohdr" "$FIXTURE"
ERRF=$(mktemp)
OUT=$(_bounded_roadmap "$FIXTURE" 20000 2>"$ERRF")
_eq "no header: every unchecked item still present"     "12" "$(_count_unchecked "$OUT")"
_eq "no header: every entry still present"              "40" "$(_count_entries "$OUT")"
_eq "no header: WARN emitted"                           "1"  "$(grep -c 'MARVIN_LOG\[WARN\].*UNBOUNDED' "$ERRF" || true)"
_eq "no header: WARN did NOT leak onto stdout"          "0"  "$(grep -c 'MARVIN_LOG' <<<"$OUT" || true)"
rm -f "$ERRF"

_build_unit quiet_fallback
OUT_M=$(_bounded_roadmap "$FIXTURE" 20000 2>/dev/null)
if [[ "$(_count_unchecked "$OUT_M")" == "12" ]]; then
    printf '  \033[31mFAIL\033[0m  %-52s MUTATION INEFFECTIVE\n' "quiet_fallback must lose the items"; FAIL=$((FAIL+1))
else
    printf '  \033[32mPASS\033[0m  %-52s MUTATION EFFECTIVE (kept %s)\n' "quiet_fallback loses the items" "$(_count_unchecked "$OUT_M")"; PASS=$((PASS+1))
fi

# ═══ 5. Against the REAL roadmap, at the production budget ══════════════════
echo "─── the live POSSIBLE_ENHANCEMENTS.md ───"
_build_unit none
if [[ -r "$REAL_ROADMAP" ]]; then
    REAL_UNCHECKED=$(grep -c '^- \[ \]' "$REAL_ROADMAP" || true)
    REAL_ENTRIES=$(awk '/^## Completed Enhancements Log/,0' "$REAL_ROADMAP" | grep -c '^- \[x\] \*\*\[' || true)
    OUT=$(_bounded_roadmap "$REAL_ROADMAP" "$_ROADMAP_RECENT_BUDGET")
    _eq "real file: no unchecked item lost" "$REAL_UNCHECKED" "$(_count_unchecked "$OUT")"
    BEFORE=$(wc -c <"$REAL_ROADMAP") ; AFTER=$(wc -c <<<"$OUT")
    KEPT=$(_count_entries "$OUT")
    printf '  \033[36mINFO\033[0m  %-52s %d -> %d bytes (-%d%%), %d of %d entries\n' \
        "size at production budget" "$BEFORE" "$AFTER" "$(( (BEFORE - AFTER) * 100 / BEFORE ))" "$KEPT" "$REAL_ENTRIES"
    [[ "$AFTER" -lt "$BEFORE" ]] \
        && { printf '  \033[32mPASS\033[0m  %-52s\n' "real file: bound reduces the payload"; PASS=$((PASS+1)); } \
        || { printf '  \033[31mFAIL\033[0m  %-52s\n' "real file: bound reduces the payload"; FAIL=$((FAIL+1)); }
    # The most recent entry is the one a session most needs; it must survive.
    # `--` before the pattern: it begins with "- ", which grep would otherwise
    # parse as options and abort on.
    NEWEST=$(awk '/^## Completed Enhancements Log/,0' "$REAL_ROADMAP" | grep -m1 -oE '^- \[x\] \*\*\[[0-9-]+\]')
    _eq "real file: newest entry retained" "1" "$(grep -cF -- "$NEWEST" <<<"$OUT" || true)"
else
    printf '  \033[33mSKIP\033[0m  real roadmap not readable at %s\n' "$REAL_ROADMAP"
fi

echo
echo "───────────────────────────────────────────"
printf ' roadmap budget tests: %d pass, %d fail\n' "$PASS" "$FAIL"
echo "───────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]]
