#!/usr/bin/env bash
#
# Drives the shell-syntax CI gate against fixtures that reproduce every defect
# it has ever had, and proves each assertion can fail.
#
# Why this exists (#931): the gate in `.github/workflows/shell-syntax.yml` was
# built on the principle that a check which cannot run must not report "clean".
# Six review rounds each found a way it could silently pass on a file it had not
# validated. Every one of those was demonstrated with a real fixture — and none
# of the fixtures was kept. The gate was therefore protected by a paragraph in
# CHANGELOG.md asserting that it worked, which is the failure mode it was
# written to prevent, one level up. Reintroduce `tr '\0' '\n'` tomorrow and CI
# stays green while the gate reports on 53 files and validates 52.
#
# Three rules this file obeys, because breaking any of them makes it decorative:
#
#   1. It runs the REAL gate. The `run:` block is extracted from the workflow by
#      job id and step name (`tests/lib/extract-workflow-step.py`). A test that
#      reimplemented the gate would agree with itself perfectly and would go on
#      agreeing after the real gate regressed.
#
#   2. It refuses to report if the extraction lost the thing under test. Every
#      defect below is anchored to an exact substring of the gate. If the gate is
#      reworded, this file FAILS LOUDLY rather than quietly testing nothing. That
#      brittleness is deliberate: a stale harness that prints a full, plausible
#      pass table from a truncated fragment is worse than one that stops.
#
#   3. Every assertion is shown failing. Each case runs twice — once against the
#      real gate, once against a mutant carrying the historical defect — and the
#      verdict must FLIP. A control that passes without the mutation having
#      landed certifies an unmutated tree, so the mutator requires exactly one
#      match and aborts on zero or many.
#
# Fixtures are generated at runtime into throwaway git repos. They cannot be
# committed: a tracked file named `good.sh<LF>good.sh` that does not parse is
# precisely what the real gate is supposed to reject, so checking the fixtures in
# would turn this repository's own CI red forever.
#
# Exit 0 = every assertion passed AND every control flipped.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/shell-syntax.yml"
EXTRACTOR="${REPO_ROOT}/tests/lib/extract-workflow-step.py"
JOB_ID="bash-n"
STEP_NAME="Parse every tracked shell script"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shell-syntax-gate-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
RESULTS=()

# Collapse a recorded detail to exactly one line.
#
# The FAIL paths below interpolate captured gate output, and that output is built
# from adversarial filenames — the same bytes these fixtures exist to provoke. A
# raw newline in a table cell puts whatever follows it at column 0 of the step
# log, where GitHub parses it as a workflow command. `case_forge`'s FAIL message
# greps for `^::notice` and would have re-emitted the forged command it had just
# caught. That is the gate's own second review round (#921) recurring inside the
# harness written to prevent it: the human-readable line is the same channel as
# the annotation. "Only reached when something is already broken" describes
# exactly when a person will be reading this log.
#
# Newlines and carriage returns become their two-character escapes, so a row is
# always one line and nothing it carries can reach column 0. Long captures are
# truncated — the table is a summary, and the failing run's raw output is already
# in the log above it.
flatten() {  # <text>
    local v="$1"
    v="${v//$'\r'/\\r}"
    v="${v//$'\n'/\\n}"
    if (( ${#v} > 400 )); then
        v="${v:0:400}…[truncated]"
    fi
    printf '%s' "$v"
}

record() {  # <PASS|FAIL> <case> <detail>
    local verdict="$1" name="$2" detail
    detail="$(flatten "$3")"
    RESULTS+=("${verdict}|${name}|${detail}")
    if [[ "$verdict" == "PASS" ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
}

die() {
    printf '\n!! %s\n' "$1" >&2
    printf '!! Refusing to report fixture results — this run proves nothing.\n' >&2
    exit 2
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — extract the gate, and verify the extraction still contains the gate
# ─────────────────────────────────────────────────────────────────────────────

[[ -f "$WORKFLOW" ]] || die "workflow not found: ${WORKFLOW}"
[[ -f "$EXTRACTOR" ]] || die "extractor not found: ${EXTRACTOR}"

GATE="${WORK}/gate.sh"
if ! python3 "$EXTRACTOR" "$WORKFLOW" "$JOB_ID" "$STEP_NAME" run > "$GATE"; then
    die "could not extract the \`run:\` block for step '${STEP_NAME}'"
fi

[[ -s "$GATE" ]] || die "extracted \`run:\` block is empty"

# The extraction must still parse. If it does not, the harness is executing a
# fragment and every verdict below would be about the truncation, not the gate.
if ! bash -n -- "$GATE"; then
    die "extracted \`run:\` block does not parse — extraction is broken, not the gate"
fi

# Each anchor is the exact text of a defence the gate carries. Absence means
# either the defence was removed (a real regression) or the gate was reworded
# (this file is now stale). Both must stop the run: a mutation that matches
# nothing would otherwise "pass" its control by doing nothing at all.
ANCHORS=(
    "git ls-files -z -- '*.sh'"
    "while IFS= read -r -d '' f; do"
    'bash -n -- "$f"'
    '_esc_prop "$f"'
    'v="${v//,/%2C}"'
    "printf 'BROKEN  %q"
    'if [[ "$total" -eq 0 ]]; then'
)
missing=()
for anchor in "${ANCHORS[@]}"; do
    grep -qF -- "$anchor" "$GATE" || missing+=("$anchor")
done
if (( ${#missing[@]} > 0 )); then
    printf '\n!! The extracted gate is missing %d anchor(s):\n' "${#missing[@]}" >&2
    printf '!!   %s\n' "${missing[@]}" >&2
    die "extraction lost the thing under test"
fi

printf 'Extracted %s bytes from %s [%s / %s]\n' \
    "$(wc -c < "$GATE" | tr -d ' ')" "${WORKFLOW#"${REPO_ROOT}/"}" "$JOB_ID" "$STEP_NAME"
printf 'All %d anchors present; extraction parses.\n\n' "${#ANCHORS[@]}"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Literal (non-regex) single-occurrence replacement. Exactly one match is
# required: zero means the mutation never landed and the "control" would be
# certifying an unmutated tree, which is how two negative controls passed in
# #907. Many means the anchor is ambiguous and the mutant is not the defect.
mutate() {  # <file> <literal-from> <literal-to>
    python3 - "$@" <<'PY'
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
n = src.count(frm)
if n != 1:
    sys.stderr.write(
        f"MUTATION EFFECTIVE? NO - pattern found {n} time(s), need exactly 1:\n"
        f"  {frm!r}\n"
    )
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(frm, to))
PY
}

# Build a mutant of the gate carrying one historical defect. Aborts the whole
# run if the mutation did not land or left a script that does not parse.
make_mutant() {  # <name> <from> <to> [<from> <to> ...]
    local name="$1"; shift
    local path="${WORK}/mutant-${name}.sh"
    cp "$GATE" "$path"
    while (( $# >= 2 )); do
        if ! mutate "$path" "$1" "$2"; then
            die "mutation '${name}' did not land — control would certify an unmutated gate"
        fi
        shift 2
    done
    (( $# == 0 )) || die "make_mutant '${name}': odd number of from/to arguments"
    if ! bash -n -- "$path"; then
        die "mutant '${name}' does not parse — it tests the mutation, not the defect"
    fi
    printf '%s' "$path"
}

# Run a gate script inside a fixture repo. Captures output and exit status
# without letting either kill this script.
GATE_OUT=""
GATE_RC=0
run_gate() {  # <gate-script> <fixture-dir>
    GATE_OUT=""
    GATE_RC=0
    GATE_OUT="$(cd "$2" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE bash "$1" 2>&1)" || GATE_RC=$?
}

# A throwaway git repo. `git add` populates the index, which is all
# `git ls-files` reads — no commit, so no author identity is needed.
new_repo() {  # <name>  -> prints path
    local dir="${WORK}/repo-$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    printf '%s' "$dir"
}

seal_repo() {  # <dir>
    git -C "$1" add -A
}

BROKEN_SRC='if true; then'   # unterminated `if` — bash -n rejects it
VALID_SRC='echo hello'

# ─────────────────────────────────────────────────────────────────────────────
# Case 1 — a filename containing a newline must not split into two records
#
# Defect: `git ls-files -z | tr '\0' '\n'` with a plain `read -r`. The name
# `good.sh<LF>good.sh` becomes two records, both of which resolve to the valid
# `good.sh`. The file that does not parse is counted as two clean ones.
# ─────────────────────────────────────────────────────────────────────────────

fx_newline() {
    local dir="$1"
    printf '%s\n' "$VALID_SRC" > "${dir}/good.sh"
    printf '%s\n' "$BROKEN_SRC" > "${dir}/$(printf 'good.sh\ngood.sh')"
    seal_repo "$dir"
}

case_newline() {
    local dir mutant
    dir="$(new_repo newline)"; fx_newline "$dir"

    run_gate "$GATE" "$dir"
    if (( GATE_RC != 0 )) && grep -q '1 broken' <<< "$GATE_OUT"; then
        record PASS "newline-in-name" "gate rejected: $(grep -o 'checked.*' <<< "$GATE_OUT")"
    else
        record FAIL "newline-in-name" "expected nonzero + '1 broken', got rc=${GATE_RC}: ${GATE_OUT}"
    fi

    # Control: reintroduce the exact historical defect.
    mutant="$(make_mutant newline \
        "while IFS= read -r -d '' f; do" "while IFS= read -r f; do" \
        "done < <(git ls-files -z -- '*.sh')" "done < <(git ls-files -z -- '*.sh' | tr '\\0' '\\n')")"
    dir="$(new_repo newline-ctl)"; fx_newline "$dir"
    run_gate "$mutant" "$dir"
    if (( GATE_RC == 0 )); then
        record PASS "newline-in-name [control]" "defect reinstated -> gate passed a broken file (rc=0)"
    else
        record FAIL "newline-in-name [control]" "mutant still caught it (rc=${GATE_RC}) — assertion unproven"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 2 — a comma in a filename must not inject annotation properties
#
# Defect: annotation properties are comma-delimited, so a file named
# `evil,line=99,col=1,title=Looks fine.sh` relocates the error onto line 99 of a
# file that does not exist, under a title claiming it is fine.
# ─────────────────────────────────────────────────────────────────────────────

EVIL_COMMA='evil,line=99,col=1,title=Looks fine.sh'

fx_comma() {
    local dir="$1"
    printf '%s\n' "$BROKEN_SRC" > "${dir}/${EVIL_COMMA}"
    seal_repo "$dir"
}

# Only the PROPERTY region of an annotation is comma-delimited. `bash -n` echoes
# the offending filename back inside its error text, so raw commas in the message
# half are expected and harmless — asserting over the whole line fails against a
# correct gate. Returns the text between `::error ` and the first `::`.
annotation_props() {  # <annotation-line>
    local rest="${1#::error }"
    printf '%s' "${rest%%::*}"
}

case_comma() {
    local dir mutant ann props
    dir="$(new_repo comma)"; fx_comma "$dir"

    run_gate "$GATE" "$dir"
    ann="$(grep '^::error ' <<< "$GATE_OUT" || true)"
    props="$(annotation_props "$ann")"
    if [[ -n "$ann" ]] && [[ "$props" == *'%2C'* ]] && [[ "$props" != *,* ]]; then
        record PASS "comma-injection" "properties escaped: ${props}"
    else
        record FAIL "comma-injection" "property region unescaped: ${props:-<no ::error line>}"
    fi

    mutant="$(make_mutant comma 'v="${v//,/%2C}"; v="${v//:/%3A}"' 'v="${v//:/%3A}"')"
    dir="$(new_repo comma-ctl)"; fx_comma "$dir"
    run_gate "$mutant" "$dir"
    ann="$(grep '^::error ' <<< "$GATE_OUT" || true)"
    props="$(annotation_props "$ann")"
    if [[ -n "$ann" ]] && [[ "$props" == *',line=99'* ]]; then
        record PASS "comma-injection [control]" "unescaped -> injected 'line=99,title=Looks fine'"
    else
        record FAIL "comma-injection [control]" "mutant injected nothing into properties — assertion unproven"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 3 — a filename starting with `-` must be parsed, not read as options
#
# Defect: `bash -n "$f"` on a tracked `-c.sh`. Note the direction, which #930
# initially got backwards: this is NOT a bypass. Every `*.sh` name contains a
# `.`, which is not a valid option character, so bash always exits nonzero. The
# real failure is a false FAIL — a perfectly valid script turns CI red and the
# annotation says `invalid option` instead of naming a syntax error. The fixture
# therefore holds a VALID script, and the control is the verdict flipping 0 -> 1.
# ─────────────────────────────────────────────────────────────────────────────

fx_dash() {
    local dir="$1"
    printf '%s\n' "$VALID_SRC" > "${dir}/-c.sh"
    seal_repo "$dir"
}

case_dash() {
    local dir mutant
    dir="$(new_repo dash)"; fx_dash "$dir"

    run_gate "$GATE" "$dir"
    if (( GATE_RC == 0 )) && grep -q 'checked 1 tracked' <<< "$GATE_OUT"; then
        record PASS "leading-dash-name" "valid '-c.sh' parsed as a path (rc=0)"
    else
        record FAIL "leading-dash-name" "valid script rejected, rc=${GATE_RC}: ${GATE_OUT}"
    fi

    mutant="$(make_mutant dash 'bash -n -- "$f"' 'bash -n "$f"')"
    dir="$(new_repo dash-ctl)"; fx_dash "$dir"
    run_gate "$mutant" "$dir"
    if (( GATE_RC != 0 )) && grep -qi 'invalid option\|usage' <<< "$GATE_OUT"; then
        record PASS "leading-dash-name [control]" "no '--' -> false FAIL on a valid script (rc=${GATE_RC})"
    else
        record FAIL "leading-dash-name [control]" "mutant did not false-FAIL — assertion unproven"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 4 — matching zero files is not a pass
#
# Defect: the pathspec stops matching (layout moved, extension changed) and the
# gate reports "0 broken" as success. "The scanner broke" must never be rendered
# as "the scanner found nothing".
# ─────────────────────────────────────────────────────────────────────────────

fx_empty() {
    local dir="$1"
    printf 'no shell scripts here\n' > "${dir}/README.md"
    seal_repo "$dir"
}

case_empty() {
    local dir mutant
    dir="$(new_repo empty)"; fx_empty "$dir"

    run_gate "$GATE" "$dir"
    if (( GATE_RC != 0 )) && grep -q 'scanned nothing' <<< "$GATE_OUT"; then
        record PASS "zero-match-pathspec" "empty scan refused (rc=${GATE_RC})"
    else
        record FAIL "zero-match-pathspec" "expected refusal, got rc=${GATE_RC}: ${GATE_OUT}"
    fi

    mutant="$(make_mutant empty \
        'if [[ "$total" -eq 0 ]]; then' 'if false; then')"
    dir="$(new_repo empty-ctl)"; fx_empty "$dir"
    run_gate "$mutant" "$dir"
    if (( GATE_RC == 0 )); then
        record PASS "zero-match-pathspec [control]" "guard removed -> vacuous scan reported clean (rc=0)"
    else
        record FAIL "zero-match-pathspec [control]" "mutant still refused — assertion unproven"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 5 — the plain log line must not forge a workflow command
#
# Defect: GitHub parses EVERY line of step output for workflow commands, so the
# human-readable line is the same channel as the annotation. A raw filename
# containing a newline puts its tail at column 0, forging the command the
# annotation escaping had just closed. `%q` renders it as one token.
# ─────────────────────────────────────────────────────────────────────────────

FORGE_NAME='evil
::notice title=FORGED::pwned.sh'

fx_forge() {
    local dir="$1"
    printf '%s\n' "$BROKEN_SRC" > "${dir}/${FORGE_NAME}"
    seal_repo "$dir"
}

case_forge() {
    local dir mutant
    dir="$(new_repo forge)"; fx_forge "$dir"

    run_gate "$GATE" "$dir"
    if ! grep -q '^::notice' <<< "$GATE_OUT"; then
        record PASS "log-channel-forging" "no line began a forged command"
    else
        record FAIL "log-channel-forging" "forged command survived: $(grep '^::notice' <<< "$GATE_OUT")"
    fi

    mutant="$(make_mutant forge "printf 'BROKEN  %q\\n%s\\n' \"\$f\"" "printf 'BROKEN  %s\\n%s\\n' \"\$f\"")"
    dir="$(new_repo forge-ctl)"; fx_forge "$dir"
    run_gate "$mutant" "$dir"
    if grep -q '^::notice' <<< "$GATE_OUT"; then
        record PASS "log-channel-forging [control]" "raw %s -> '::notice title=FORGED' at column 0"
    else
        record FAIL "log-channel-forging [control]" "mutant forged nothing — assertion unproven"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 6 — the job must bound its own runtime
#
# Defect: no `timeout-minutes`, so the job inherits the 6-hour default. This is a
# YAML property rather than shell, so it is asserted against the parsed workflow;
# the control is a copy of the workflow with the key deleted.
# ─────────────────────────────────────────────────────────────────────────────

case_timeout() {
    local t rc=0 ctl_yaml out
    t="$(python3 "$EXTRACTOR" "$WORKFLOW" "$JOB_ID" -- timeout)" || rc=$?
    if (( rc == 0 )) && [[ "$t" =~ ^[0-9]+$ ]] && (( t > 0 && t <= 15 )); then
        record PASS "job-timeout" "timeout-minutes=${t} (bounded, <= 15)"
    else
        record FAIL "job-timeout" "expected 1..15, got '${t}' (rc=${rc})"
    fi

    # Deleted structurally, not by text. A literal `timeout-minutes: 5` match is
    # ambiguous the moment a second job sets the same budget — which is exactly
    # what happened when `gate-selftest` was added below `bash-n`, and the
    # mutator correctly refused to guess. Keying on the job id cannot drift.
    ctl_yaml="${WORK}/no-timeout.yml"
    if ! python3 - "$WORKFLOW" "$ctl_yaml" "$JOB_ID" <<'PY'
import sys, yaml
src, dst, job = sys.argv[1:4]
with open(src, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
if doc["jobs"][job].pop("timeout-minutes", None) is None:
    sys.stderr.write(f"MUTATION EFFECTIVE? NO - job {job!r} had no timeout-minutes to delete\n")
    sys.exit(3)
with open(dst, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh)
PY
    then
        die "timeout control mutation did not land"
    fi
    rc=0
    out="$(python3 "$EXTRACTOR" "$ctl_yaml" "$JOB_ID" -- timeout 2>&1)" || rc=$?
    if (( rc != 0 )) && grep -q 'no .timeout-minutes' <<< "$out"; then
        record PASS "job-timeout [control]" "key removed -> extractor refused (rc=${rc})"
    else
        record FAIL "job-timeout [control]" "mutant reported '${out}' (rc=${rc}) — assertion unproven"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run
# ─────────────────────────────────────────────────────────────────────────────

case_newline
case_comma
case_dash
case_empty
case_forge
case_timeout

printf '%s\n' "─────────────────────────────────────────────────────────────────"
for row in "${RESULTS[@]}"; do
    IFS='|' read -r verdict name detail <<< "$row"
    printf '%-4s  %-34s  %s\n' "$verdict" "$name" "$detail"
done
printf '%s\n' "─────────────────────────────────────────────────────────────────"

TOTAL=$((PASSED + FAILED))
# Half the rows are controls, so an odd or short total means a case silently did
# not run — which would otherwise read as a clean sweep of whatever did.
EXPECTED=12
if (( TOTAL != EXPECTED )); then
    die "recorded ${TOTAL} results, expected ${EXPECTED} — a case did not run"
fi

printf '%d/%d assertions passed (6 defects, each with its negative control)\n' "$PASSED" "$TOTAL"
(( FAILED == 0 ))
