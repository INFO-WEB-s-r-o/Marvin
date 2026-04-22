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

# ─── Dependency guard (issue #615) ───────────────────────────────────────────
# This file calls marvin_log() at source-time (tool availability check below)
# and inside run_claude(). If sourced before common.sh, those calls would
# fail with "command not found". Fail fast with a clear message instead.
if ! declare -F marvin_log >/dev/null 2>&1; then
    echo "ERROR: agent/lib/claude.sh must be sourced after agent/common.sh" >&2
    return 1 2>/dev/null || exit 1
fi

# ─── Claude concurrency guard ────────────────────────────────────────────────
# Only one Claude CLI process should run at a time on a 2 vCPU machine.
# Concurrent Claude runs (from overlapping cron jobs) spike load to 9+ and
# starve both processes of CPU. This lock makes later callers wait up to
# CLAUDE_LOCK_TIMEOUT seconds, then skip if the lock is still held.
#
# Uses flock(1) on a shared lock file — POSIX-safe, no race conditions,
# auto-released on process exit (even on crash/kill).
CLAUDE_LOCK_FILE="/tmp/marvin-claude.lock"
CLAUDE_LOCK_TIMEOUT="${CLAUDE_LOCK_TIMEOUT:-300}"  # 5 min default wait

# ─── Tool availability check (issue #611) ────────────────────────────────────
# run_claude() may invoke `claude` under `nice`/`ionice` to lower priority on
# the 2-vCPU box. `nice` is in coreutils and `ionice` in util-linux — both
# normally present on Ubuntu — but if either is missing the whole pipeline
# would fail with "command not found", silently breaking every cron agent.
# Warn once at load so the gap is visible in logs before invocation time.
if ! command -v ionice &>/dev/null; then
    marvin_log "WARN" "ionice not found in PATH — Claude IO priority will not be lowered (install util-linux)" >&2
fi
if ! command -v nice &>/dev/null; then
    marvin_log "WARN" "nice not found in PATH — Claude CPU priority will not be lowered (install coreutils)" >&2
fi

# Run Claude Code with a prompt file and context
run_claude() {
    local task_name="$1"
    local prompt="$2"
    local run_log="${LOGS_DIR}/${TODAY}-${task_name}-${TIMESTAMP}.md"

    # Use >&2 for log calls so they don't leak into captured stdout
    marvin_log "INFO" "Starting Claude run: ${task_name}" >&2

    # Acquire exclusive lock — wait up to CLAUDE_LOCK_TIMEOUT seconds
    # Use bash auto-FD allocation ({var}>file) so we don't collide with any
    # other FD a caller or sourced library might already be using.
    local lock_fd
    exec {lock_fd}>"$CLAUDE_LOCK_FILE"
    if ! flock -w "$CLAUDE_LOCK_TIMEOUT" "$lock_fd"; then
        marvin_log "WARN" "Claude lock timeout after ${CLAUDE_LOCK_TIMEOUT}s — skipping ${task_name} (another Claude run is active)" >&2
        exec {lock_fd}>&-
        echo ""
        return 2  # Distinct exit code: caller can distinguish timeout from failure
    fi
    # Write holder info for debugging stale locks
    echo "$$:${task_name}:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&"$lock_fd" 2>/dev/null || true
    marvin_log "INFO" "Claude lock acquired for ${task_name}" >&2

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

    # Run claude at lowered CPU/IO priority so kernel threads (notably rcu_preempt)
    # and other system tasks get scheduled on this 2-vCPU box. Fixes #606 —
    # recurring rcu_preempt kthread starvation during sustained Claude runs.
    # Build prefix opportunistically: skip nice/ionice if either is missing
    # rather than aborting the whole invocation with "command not found" (#613).
    local prefix=()
    command -v nice   &>/dev/null && prefix+=(nice -n 10)
    command -v ionice &>/dev/null && prefix+=(ionice -c 2 -n 7)
    printf '%s' "${full_prompt}" | "${prefix[@]}" claude -p > "$output_file" 2>&1 && exit_code=$? || exit_code=$?
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Read output from temp file — preserves all data regardless of size
    # (temp file cleanup handled by RETURN trap above)
    output=$(<"$output_file") || { marvin_log "ERROR" "Failed to read Claude output temp file: ${output_file}" >&2; output=""; }

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

    # Release the Claude concurrency lock
    exec {lock_fd}>&- 2>/dev/null || true
    marvin_log "INFO" "Claude lock released for ${task_name}" >&2

    echo "$output"
    return $exit_code
}

# Run Claude with bounded retries on transient failures (exit code 1 only).
# Intended for once-a-day tasks (morning-check, evening-report) where a single
# transient API error or stochastic usage-policy classifier rejection would
# otherwise lose the whole day's output until the next cycle. For high-frequency
# tasks (every-5-min, hourly), the next cron cycle is a cheaper retry — use
# run_claude() directly there.
#
# Does NOT retry on:
#   - exit code 2 (lock timeout — another run is already active)
#   - exit code 0 (success)
#   - exit codes >1 (likely a persistent error: missing binary, SIGKILL, etc.)
#
# Usage: run_claude_with_retry "task" "prompt" [max_retries=1]
run_claude_with_retry() {
    local task="$1"
    local prompt="$2"
    local max_retries="${3:-1}"
    local attempt=0
    local exit_code=0
    local output=""
    local retry_delay=15

    while :; do
        exit_code=0
        output=$(run_claude "$task" "$prompt") || exit_code=$?

        # Success or non-transient failure — stop
        if [[ "$exit_code" -ne 1 ]]; then
            break
        fi

        # Retry budget exhausted
        if [[ "$attempt" -ge "$max_retries" ]]; then
            marvin_log "WARN" "All ${max_retries} retries exhausted for ${task} (last exit: ${exit_code})" >&2
            break
        fi

        attempt=$((attempt + 1))
        marvin_log "WARN" "Claude exit 1 for ${task} — retry ${attempt}/${max_retries} after ${retry_delay}s" >&2
        sleep "$retry_delay"
    done

    echo "$output"
    return $exit_code
}

# Self-heals from PATH misconfiguration: probe known install dirs before failing.
check_claude() {
    if command -v claude &> /dev/null; then
        return 0
    fi

    local candidate
    for candidate in /root/.local/bin/claude /usr/local/bin/claude /usr/bin/claude; do
        if [[ -x "$candidate" ]]; then
            local dir="${candidate%/*}"
            export PATH="${dir}:${PATH}"
            marvin_log "WARN" "claude missing from PATH — self-healed by adding ${dir}" >&2
            return 0
        fi
    done

    marvin_log "ERROR" "Claude Code CLI not found in PATH or known install locations" >&2
    return 1
}
