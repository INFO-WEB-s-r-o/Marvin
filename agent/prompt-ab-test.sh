#!/usr/bin/env bash
# =============================================================================
# Marvin — Prompt A/B Testing Harness (manual invocation only, NOT cron-wired)
# =============================================================================
# Runs two prompt variants for the same task through run_claude() and records
# duration, exit code, and output size for each, so a human can compare them
# side by side.
#
# Deliberately NOT wired into setup-cron.sh: every real run costs two Claude
# Code invocations, and this repo already treats "spend real API/session
# budget autonomously" as something that needs an explicit human go-ahead
# per run (see the LongMemEval scored-run precedent) rather than something a
# script decides for itself on a schedule.
#
# "Measure output quality" is deliberately NOT automated here. Scoring
# quality needs an LLM judge, and a judge is itself a prompt whose own
# quality nobody has evaluated — building one during an unsupervised session
# would trade one unverified guess for another with more moving parts.
# Reading the two run logs side by side is the actual quality comparison;
# this harness only measures what's cheap and objective around that read.
#
# Usage:
#   agent/prompt-ab-test.sh --task <name> --a <prompt-file-a> --b <prompt-file-b> [--dry-run]
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

AB_DIR="${METRICS_DIR}/prompt-ab"
mkdir -p "$AB_DIR"

TASK_NAME=""
PROMPT_A=""
PROMPT_B=""

marvin_parse_args "$@"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --task) TASK_NAME="${2:-}"; shift 2 ;;
        --a) PROMPT_A="${2:-}"; shift 2 ;;
        --b) PROMPT_B="${2:-}"; shift 2 ;;
        --dry-run) shift ;;  # already consumed by marvin_parse_args
        *) marvin_log "ERROR" "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$TASK_NAME" || -z "$PROMPT_A" || -z "$PROMPT_B" ]]; then
    cat >&2 <<USAGE
Usage: $(basename "$0") --task <name> --a <prompt-file-a> --b <prompt-file-b> [--dry-run]

Runs two prompt variants for the same task through run_claude() and writes a
comparison record (duration, exit code, output length) to:
  ${AB_DIR}/<task>-<timestamp>.json

Manual tool only — not wired into cron. Reading the two run logs
(${LOGS_DIR}/*-<task>-a-*.md and *-<task>-b-*.md) side by side is the actual
quality comparison; this harness measures the cheap, objective part around it.
USAGE
    exit 1
fi

for f in "$PROMPT_A" "$PROMPT_B"; do
    [[ -s "$f" ]] || { marvin_log "ERROR" "Prompt file missing or empty: ${f}"; exit 1; }
done

VARIANT_A_NAME="${TASK_NAME}-a"
VARIANT_B_NAME="${TASK_NAME}-b"

if marvin_is_dry_run; then
    marvin_log "INFO" "[DRY-RUN] Would run variant A (${PROMPT_A}, $(wc -c < "$PROMPT_A") chars) as task '${VARIANT_A_NAME}'"
    marvin_log "INFO" "[DRY-RUN] Would run variant B (${PROMPT_B}, $(wc -c < "$PROMPT_B") chars) as task '${VARIANT_B_NAME}'"
    marvin_log "INFO" "[DRY-RUN] No Claude calls made — would write ${AB_DIR}/${TASK_NAME}-${TIMESTAMP}.json"
    exit 0
fi

check_claude || exit 1

marvin_log "INFO" "=== PROMPT A/B TEST: ${TASK_NAME} ==="

# Usage: run_variant <name> <prompt-file>
# Echoes a JSON result object on stdout; leaves the full run log where
# run_claude() always puts it (LOGS_DIR/<date>-<name>-<timestamp>.md).
run_variant() {
    local name="$1" file="$2"
    local prompt start end duration output rc
    prompt=$(<"$file")
    start=$(date +%s)
    output=$(run_claude "$name" "$prompt") && rc=0 || rc=$?
    end=$(date +%s)
    duration=$((end - start))
    jq -n \
        --arg name "$name" \
        --arg file "$file" \
        --argjson duration "$duration" \
        --argjson exit_code "$rc" \
        --argjson output_chars "${#output}" \
        '{name: $name, prompt_file: $file, duration_s: $duration, exit_code: $exit_code, output_chars: $output_chars}'
}

RESULT_A=$(run_variant "$VARIANT_A_NAME" "$PROMPT_A")
RESULT_B=$(run_variant "$VARIANT_B_NAME" "$PROMPT_B")

OUT_FILE="${AB_DIR}/${TASK_NAME}-${TIMESTAMP}.json"
jq -n \
    --argjson a "$RESULT_A" \
    --argjson b "$RESULT_B" \
    --arg task "$TASK_NAME" \
    --arg date "$NOW" \
    '{task: $task, date: $date, variant_a: $a, variant_b: $b}' > "$OUT_FILE"

marvin_log "INFO" "Prompt A/B comparison complete — wrote ${OUT_FILE}"
echo "Variant A: $(jq -r '"\(.duration_s)s, exit=\(.exit_code), \(.output_chars) chars"' <<<"$RESULT_A")"
echo "Variant B: $(jq -r '"\(.duration_s)s, exit=\(.exit_code), \(.output_chars) chars"' <<<"$RESULT_B")"
echo "Run logs: ${LOGS_DIR}/${TODAY}-${VARIANT_A_NAME}-*.md and ${LOGS_DIR}/${TODAY}-${VARIANT_B_NAME}-*.md — read these side by side to judge quality."
