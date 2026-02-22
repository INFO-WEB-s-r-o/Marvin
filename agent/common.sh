#!/usr/bin/env bash
# =============================================================================
# Marvin — Common utilities shared across all agent scripts
# =============================================================================

MARVIN_DIR="/home/marvin"
DATA_DIR="${MARVIN_DIR}/data"
LOGS_DIR="${DATA_DIR}/logs"
METRICS_DIR="${DATA_DIR}/metrics"
BLOG_DIR="${DATA_DIR}/blog"
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
  "kernel": "$(uname -r)"
}
EOF
}

# Run Claude Code with a prompt file and context
run_claude() {
    local task_name="$1"
    local prompt="$2"
    local run_log="${LOGS_DIR}/${TODAY}-${task_name}-${TIMESTAMP}.md"
    
    marvin_log "INFO" "Starting Claude run: ${task_name}"
    
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
    
    # Run Claude Code in non-interactive mode  
    local output
    local start_time=$(date +%s)
    
    output=$(claude -p "${full_prompt}" 2>&1) || true
    local exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
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
    
    marvin_log "INFO" "Claude run complete: ${task_name} (${duration}s, exit=${exit_code})"
    
    echo "$output"
}

# Append to daily metrics history
append_metrics() {
    local metrics="$1"
    local history_file="${METRICS_DIR}/${TODAY}.jsonl"
    echo "$metrics" >> "$history_file"
    
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
