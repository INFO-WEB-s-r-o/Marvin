#!/usr/bin/env bash
# =============================================================================
# Marvin — Common utilities shared across all agent scripts
# =============================================================================

MARVIN_DIR="/home/marvin/git"
DATA_DIR="${MARVIN_DIR}/data"
LOGS_DIR="${DATA_DIR}/logs"

# GPG key lives in marvin's homedir, but cron runs as root.
# Without this, git commit -S and gpg --detach-sign fail with "No secret key".
export GNUPGHOME="/home/marvin/.gnupg"
METRICS_DIR="${DATA_DIR}/metrics"
BLOG_DIR="/home/marvin/blog"
COMMS_DIR="${DATA_DIR}/comms"
ENHANCE_DIR="${DATA_DIR}/enhancements"
PROMPTS_DIR="${MARVIN_DIR}/agent/prompts"
WEB_DIR="${MARVIN_DIR}/web"

TODAY=$(date -u +%Y-%m-%d)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TIMESTAMP=$(date +%s)

# Ensure directories exist
mkdir -p "$LOGS_DIR" "$METRICS_DIR" "$BLOG_DIR" "$COMMS_DIR" "$ENHANCE_DIR"

# Logging
marvin_log() {
    local level="${1:-INFO}"
    local message="${2:-}"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] ${message}" | tee -a "${LOGS_DIR}/${TODAY}.log"
}

# Collect current system metrics as JSON
collect_metrics() {
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "0")
    
    local mem_info
    mem_info=$(free -m | awk 'NR==2{printf "{\"total\":%s,\"used\":%s,\"free\":%s,\"available\":%s}", $2, $3, $4, $7}')
    
    local swap_info
    swap_info=$(free -m | awk 'NR==3{printf "{\"total\":%s,\"used\":%s,\"free\":%s}", $2, $3, $4}')
    
    local disk_info
    disk_info=$(df -m / | awk 'NR==2{printf "{\"total\":%s,\"used\":%s,\"available\":%s,\"percent\":\"%s\"}", $2, $3, $4, $5}')
    
    local load_avg
    load_avg=$(cat /proc/loadavg | awk '{printf "{\"1min\":%s,\"5min\":%s,\"15min\":%s}", $1, $2, $3}')
    
    local uptime_seconds
    uptime_seconds=$(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1)
    
    local process_count
    process_count=$(ps aux | wc -l)
    
    local fail2ban_banned
    fail2ban_banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "0")

    # Network I/O: bytes received/transmitted on primary interface
    local net_iface net_info
    net_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}' || echo "")
    if [[ -n "$net_iface" ]]; then
        net_info=$(awk -v iface="${net_iface}:" -v name="${net_iface}" \
            '$1==iface {printf "{\"interface\":\"%s\",\"rx_bytes\":%s,\"tx_bytes\":%s,\"rx_packets\":%s,\"tx_packets\":%s}", name, $2, $10, $3, $11}' \
            /proc/net/dev 2>/dev/null || echo '{}')
    else
        net_info='{}'
    fi

    cat << EOF
{
  "timestamp": "${NOW}",
  "uptime_seconds": ${uptime_seconds},
  "cpu_percent": ${cpu_usage},
  "memory": ${mem_info},
  "swap": ${swap_info},
  "disk": ${disk_info},
  "load_average": ${load_avg},
  "process_count": ${process_count},
  "fail2ban_banned": ${fail2ban_banned},
  "network": ${net_info},
  "kernel": "$(uname -r | cut -d'-' -f1)"
}
EOF
}

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

    # Run Claude Code in non-interactive mode
    # Use stdin pipe to avoid "Argument list too long" with large prompts
    local output
    local exit_code
    local start_time=$(date +%s)

    # Capture exit code properly — the old `|| true` pattern masked failures,
    # making exit_code always 0. This pattern preserves the real exit code
    # while preventing set -e from killing the script.
    output=$(printf '%s' "${full_prompt}" | claude -p 2>&1) && exit_code=$? || exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

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

# Append to daily metrics history
append_metrics() {
    local metrics="$1"
    local history_file="${METRICS_DIR}/${TODAY}.jsonl"
    # Compact to single line for JSONL format (one JSON object per line)
    echo "$metrics" | jq -c '.' >> "$history_file" 2>/dev/null || \
        echo "$metrics" | tr -d '\n' >> "$history_file"

    # Also update latest.json
    echo "$metrics" | jq '.' > "${METRICS_DIR}/latest.json" 2>/dev/null || \
        echo "$metrics" > "${METRICS_DIR}/latest.json"
}

# Check if Claude Code is available
check_claude() {
    if ! command -v claude &> /dev/null; then
        marvin_log "ERROR" "Claude Code CLI not found in PATH"
        return 1
    fi
    return 0
}
