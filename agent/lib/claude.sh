#!/usr/bin/env bash
# =============================================================================
# Marvin — Claude API Library
# =============================================================================
# Functions for interacting with the Claude Code CLI.
#
# Requires these variables/functions from common.sh:
#   LOGS_DIR, METRICS_DIR, TODAY, NOW, TIMESTAMP
#   marvin_log() from lib/logging.sh
#   collect_metrics() from lib/metrics.sh
#
# Usage: sourced automatically by common.sh (do not source directly)
# =============================================================================

# Run Claude Code with a prompt file and context
run_claude() {
    local task_name="$1"
    local prompt="$2"
    local run_log="${LOGS_DIR}/${TODAY}-${task_name}-${TIMESTAMP}.md"

    # Use >&2 for log calls so they don't leak into captured stdout
    marvin_log "INFO" "Starting Claude run: ${task_name}" >&2

    # Collect system context to prepend
    local system_context
    system_context=$(collect_metrics)

    local full_prompt="## Current System State
\`\`\`json
${system_context}
\`\`\`

## Today's Date: ${TODAY}

## Task: ${task_name}

${prompt}"

    # Guard against context overflow: truncate if prompt exceeds ~400K chars (~100K tokens)
    local prompt_len=${#full_prompt}
    local max_chars=400000
    if [[ "$prompt_len" -gt "$max_chars" ]]; then
        marvin_log "WARN" "Prompt too large (${prompt_len} chars) — truncating to ${max_chars}" >&2
        full_prompt="${full_prompt:0:$max_chars}

--- TRUNCATED: prompt exceeded ${max_chars} char limit (was ${prompt_len}) ---"
    fi
    marvin_log "INFO" "Prompt size: ${prompt_len} chars (~$((prompt_len / 4)) tokens)" >&2

    # Sanitize prompt: strip invalid UTF-8 sequences (unpaired surrogates, etc.)
    # Root cause: log data can contain binary/malformed bytes that produce
    # "no low surrogate in string" JSON encoding errors in the Claude API.
    # iconv round-trip through UTF-8 drops any byte sequences that aren't valid UTF-8.
    # Guard: if iconv produces empty output from non-empty input, keep the original (#454).
    local sanitized
    sanitized=$(printf '%s' "$full_prompt" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true)
    if [[ -z "${sanitized}" && -n "${full_prompt}" ]]; then
        marvin_log "WARN" "UTF-8 sanitization produced empty prompt — using original" >&2
    else
        full_prompt="${sanitized}"
    fi

    # Run Claude Code in non-interactive mode
    # Use stdin pipe to avoid "Argument list too long" with large prompts
    #
    # IMPORTANT: Output is captured via temp file, NOT $() variable substitution.
    # Bash $() can silently lose data with very large responses or partial writes,
    # causing "No response from Claude" false errors (lesson: claude-output-capture-data-loss).
    # Writing to a file first preserves all bytes reliably.
    local output
    local exit_code
    local start_time
    start_time=$(date +%s)

    local output_file
    output_file=$(mktemp "${LOGS_DIR}/claude-output-XXXXXX.tmp")
    trap 'rm -f "${output_file:-}"' RETURN

    printf '%s' "${full_prompt}" | claude -p > "$output_file" 2>&1 && exit_code=$? || exit_code=$?
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Read output from temp file — preserves all data regardless of size
    # (temp file cleanup handled by RETURN trap above)
    output=$(<"$output_file" 2>/dev/null || true)

    if [[ "$exit_code" -ne 0 ]]; then
        marvin_log "WARN" "Claude exited with code ${exit_code} for task: ${task_name}" >&2
    fi

    # Log the full interaction
    cat > "$run_log" << EOF
# Marvin Run: ${task_name}
- **Date**: ${NOW}
- **Duration**: ${duration}s
- **Exit Code**: ${exit_code}

## Prompt
\`\`\`
${full_prompt}
\`\`\`

## Response
${output}

---
*Run ID: ${TIMESTAMP} | Task: ${task_name}*
EOF

    marvin_log "INFO" "Claude run complete: ${task_name} (${duration}s, exit=${exit_code})" >&2

    # Track Claude API usage for analytics (Phase 2 roadmap)
    # Date-sharded files prevent unbounded growth (one file per day)
    local output_len=${#output}
    local usage_file="${METRICS_DIR}/claude-usage-${TODAY}.jsonl"
    jq -nc \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg task "$task_name" \
        --argjson duration "$duration" \
        --argjson prompt_chars "$prompt_len" \
        --argjson output_chars "$output_len" \
        --argjson exit_code "$exit_code" \
        '{timestamp: $ts, task: $task, duration_s: $duration, prompt_chars: $prompt_chars, output_chars: $output_chars, exit_code: $exit_code}' \
        >> "$usage_file" 2>/dev/null || true

    echo "$output"
}

# Check if Claude Code is available
check_claude() {
    if ! command -v claude &> /dev/null; then
        marvin_log "ERROR" "Claude Code CLI not found in PATH"
        return 1
    fi
    return 0
}
