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

# ─── Prompt size ceiling ─────────────────────────────────────────────────────
# The single source of truth for how large a prompt run_claude() will accept
# before it hard-truncates. Callers that assemble large prompts (self-enhance.sh)
# budget against this so they can drop content deliberately — and SAY what they
# dropped — instead of letting run_claude slice the tail off mid-file.
#
# `:=` so an operator can override it for a one-off run; unset behaves exactly
# as the previous hardcoded 400000 did.
: "${MARVIN_CLAUDE_MAX_PROMPT_CHARS:=400000}"
export MARVIN_CLAUDE_MAX_PROMPT_CHARS

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
    # Write holder info for debugging stale locks. Brace group prevents
    # the redirection from competing with `2>/dev/null` when $lock_fd
    # happens to resolve to fd 2 (shellcheck SC2261).
    { echo "$$:${task_name}:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&"$lock_fd"; } 2>/dev/null || true
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

    # Guard against context overflow: truncate if prompt exceeds ~400K chars (~100K tokens).
    #
    # This is a HARD, BLUNT CUT, not a considered selection: it slices mid-line,
    # mid-file, mid-word, and everything after the boundary is gone with only a
    # WARN to say so. A caller that assembles a large prompt must budget itself
    # against this limit rather than discover it here — see self-enhance.sh,
    # whose 2026-07-27 run was cut mid-`security-scan.sh` and silently lost the
    # one script that had actually failed that day.
    #
    # The unit is CHARACTERS, not bytes — this comment said "BYTE CUT" until
    # 2026-07-30. Bash substring expansion follows the locale, and cron gets
    # LANG=C.UTF-8 from /etc/default/locale via pam_env (/etc/pam.d/cron:13).
    # Measured: a 10-em-dash prompt (30 B) cut at 5 keeps 5 chars / 15 B, with
    # the codepoint intact. So budget with ${#var} or awk length(), which follow
    # the same locale and therefore agree with this cut for free; forcing either
    # to count bytes would make the budget DISagree with the cut it protects.
    #
    # Exported (rather than a `local`) so those callers can budget against the
    # real number instead of hardcoding a second copy that drifts out of sync.
    local prompt_len=${#full_prompt}
    local max_chars="${MARVIN_CLAUDE_MAX_PROMPT_CHARS}"
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

    # Classify *why* a run failed so downstream alerting can tell a benign,
    # self-resolving subscription throttle ("You've hit your session limit ·
    # resets …" — clears automatically when the usage window rolls over) apart
    # from a genuine API/tooling error. Only meaningful when exit_code != 0.
    # The generic WARN below is left EXACTLY as-is: lessons-learned.sh keys its
    # `claude-exit-code-1-transient` expected-recurrence lesson on that string.
    local fail_reason=""
    if [[ "$exit_code" -ne 0 ]]; then
        marvin_log "WARN" "Claude exited with code ${exit_code} for task: ${task_name}" >&2
        # Match the throttle message's distinctive verb phrase ("You've hit your
        # session limit ·"), not a bare "(session|usage) limit" substring: some
        # tasks (e.g. log-analysis) feed raw log content into the prompt, and a
        # genuine failure whose response merely echoes those words from the input
        # must NOT be masked as a benign throttle in log-alerting.sh §6. Kept
        # tolerant of apostrophe styling / leading whitespace (no strict ^ anchor).
        if printf '%s' "$output" | grep -qiE 'hit your (session|usage) limit'; then
            fail_reason="session_limit"
            marvin_log "INFO" "Claude session/usage limit reached for ${task_name} — benign, resets automatically (not counted as an API failure)" >&2
        # Expired OAuth credentials are the opposite of benign: unlike a session
        # limit they never clear on their own — every subsequent cron run dies the
        # same way until a human re-authenticates interactively. Tagging them
        # separately lets log-alerting.sh §6 escalate instead of filing yet another
        # indistinguishable "Claude API failure" warning (2026-07-21 → 07-25: 338
        # consecutive runs lost this way, alert stuck at severity=warning).
        # Patterns are the CLI's own auth-failure wording, distinctive enough not to
        # collide with log text echoed back by log-analysis-style prompts.
        #
        # Deliberately case-SENSITIVE (no -i, unlike the session-limit test above).
        # The whole reason for matching a distinctive phrase rather than a bare
        # "401" is to avoid firing on log text a prompt fed back to us, and `-i`
        # gives that back: an nginx or app log line reading "re-authenticate to
        # continue" in any casing would match. The CLI emits fixed casing, so the
        # narrow match costs nothing. If it ever changes its casing, this degrades
        # to fail_reason="error" — the pre-#841 behaviour — and the ≥90%-of-window
        # branch in log-alerting.sh §6 still escalates the outage to critical; it
        # just names the failure less precisely. Under-classifying is recoverable,
        # a false auth page that no re-auth can clear is not.
        elif printf '%s' "$output" | grep -qE 'OAuth access token has expired|Re-authenticate to continue|Failed to authenticate\. API Error: 40[13]'; then
            fail_reason="auth"
            marvin_log "ERROR" "Claude authentication failed for ${task_name} — credentials expired, requires interactive re-auth (no cron run can recover this)" >&2
        else
            fail_reason="error"
        fi
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
        --arg fail_reason "$fail_reason" \
        '{timestamp: $ts, task: $task, duration_s: $duration, prompt_chars: $prompt_chars, output_chars: $output_chars, exit_code: $exit_code, fail_reason: (if $fail_reason == "" then null else $fail_reason end)}' \
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
    # Escalating backoff: each retry waits longer so stochastic classifier
    # state / transient API pressure has more time to clear. Index is
    # `attempt - 1` (attempts are 1-based after the initial call).
    local retry_delays=(15 60 180 300)

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
        local delay_index=$((attempt - 1))
        local retry_delay="${retry_delays[$delay_index]:-${retry_delays[-1]}}"
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
