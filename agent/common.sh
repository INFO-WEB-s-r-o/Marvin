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
SITE_URL="https://robot-marvin.cz"

TODAY=$(date -u +%Y-%m-%d)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TIMESTAMP=$(date +%s)

# ─── Dry-run mode ─────────────────────────────────────────────────────────
# Scripts can enable dry-run via --dry-run flag or MARVIN_DRY_RUN=true env var.
# When active, destructive operations are logged but not executed.
# Usage in scripts:
#   marvin_parse_args "$@"        # parses --dry-run flag
#   if marvin_is_dry_run; then    # check if dry-run is active
#     marvin_log "INFO" "[DRY-RUN] Would delete $file"
#   else
#     rm -f "$file"
#   fi
MARVIN_DRY_RUN="${MARVIN_DRY_RUN:-false}"
export MARVIN_DRY_RUN

marvin_parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) MARVIN_DRY_RUN=true; export MARVIN_DRY_RUN ;;
        esac
    done
    if [[ "$MARVIN_DRY_RUN" == "true" ]]; then
        marvin_log "INFO" "[DRY-RUN] Dry-run mode active — no destructive operations will be performed"
    fi
}

marvin_is_dry_run() {
    [[ "$MARVIN_DRY_RUN" == "true" ]]
}

# Ensure directories exist
mkdir -p "$LOGS_DIR" "$METRICS_DIR" "$BLOG_DIR" "$COMMS_DIR" "$ENHANCE_DIR"

# Logging
marvin_log() {
    local level="${1:-INFO}"
    local message="${2:-}"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] ${message}" | tee -a "${LOGS_DIR}/${TODAY}.log"
}

# ─── Structured JSON logging ─────────────────────────────────────────────────
# Outputs JSON log lines to data/logs/YYYY-MM-DD-structured.jsonl.
# Also calls marvin_log() for backward compatibility with text log consumers.
#
# Usage:
#   marvin_log_json "INFO" "component" "message" '{"key":"value"}'
#
# Fields: timestamp, level, component, message, data (optional JSON object)
# The component field identifies which script/subsystem emitted the log.

marvin_log_json() {
    local level="${1:-INFO}"
    local component="${2:-unknown}"
    local message="${3:-}"
    local extra_data="${4:-}"

    # Also emit text log for backward compat
    marvin_log "$level" "[${component}] ${message}"

    # Build structured JSON line
    local json_file="${LOGS_DIR}/${TODAY}-structured.jsonl"
    local json_line
    if [[ -n "$extra_data" ]] && echo "$extra_data" | jq empty 2>/dev/null; then
        json_line=$(jq -nc \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg lvl "$level" \
            --arg comp "$component" \
            --arg msg "$message" \
            --argjson data "$extra_data" \
            '{timestamp: $ts, level: $lvl, component: $comp, message: $msg, data: $data}' 2>/dev/null)
    else
        json_line=$(jq -nc \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg lvl "$level" \
            --arg comp "$component" \
            --arg msg "$message" \
            '{timestamp: $ts, level: $lvl, component: $comp, message: $msg}' 2>/dev/null)
    fi

    if [[ -n "$json_line" ]]; then
        echo "$json_line" >> "$json_file" 2>/dev/null || true
    fi
}

# ─── Reusable trap error handler ─────────────────────────────────────────────
# Logs file:line and failed command when a command fails under `set -e`.
# Scripts can enable it alongside their existing EXIT traps:
#   trap marvin_error_trap ERR
# The ERR trap fires first, logs the error, then the EXIT trap runs for cleanup.
marvin_error_trap() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-?}"
    local script_name
    script_name=$(basename "${BASH_SOURCE[1]:-unknown}" 2>/dev/null || echo "unknown")
    local failed_cmd="${BASH_COMMAND:-unknown}"
    marvin_log "ERROR" "${script_name}:${line_no} — command failed (exit ${exit_code}): ${failed_cmd}" 2>/dev/null || true
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
    local start_time
    start_time=$(date +%s)

    # Capture exit code properly — the old `|| true` pattern masked failures,
    # making exit_code always 0. This pattern preserves the real exit code
    # while preventing set -e from killing the script.
    output=$(printf '%s' "${full_prompt}" | claude -p 2>&1) && exit_code=$? || exit_code=$?
    local end_time
    end_time=$(date +%s)
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

# Graceful nginx reload — validates config first, keeps connections alive.
# Usage: marvin_nginx_reload [reason]
# Returns 0 on success, 1 if config test fails (nginx untouched).
marvin_nginx_reload() {
    local reason="${1:-unspecified}"
    if ! nginx -t 2>/dev/null; then
        marvin_log "ERROR" "nginx config test failed — reload aborted (reason: ${reason})"
        return 1
    fi
    if systemctl reload nginx 2>/dev/null; then
        marvin_log "INFO" "nginx gracefully reloaded (reason: ${reason})"
        return 0
    else
        marvin_log "WARN" "nginx reload failed — falling back to restart (reason: ${reason})"
        systemctl restart nginx 2>/dev/null || {
            marvin_log "ERROR" "nginx restart also failed (reason: ${reason})"
            return 1
        }
        return 0
    fi
}

# ─── Web rebuild ──────────────────────────────────────────────────────────────
# Rebuilds the Next.js dashboard and restarts the service.
# Handles: npm ci (if needed), next build, static asset copy, service restart,
# JS asset integrity check with automatic rollback on failure.
#
# Usage: marvin_rebuild_web [reason]
# Returns 0 on success, 1 on build/restart/healthcheck failure.

marvin_rebuild_web() {
    local reason="${1:-unspecified}"

    if marvin_is_dry_run; then
        marvin_log "INFO" "[DRY-RUN] Would rebuild web (reason: ${reason})"
        return 0
    fi

    local web_dir="${WEB_DIR}"
    local standalone_dir="${web_dir}/.next/standalone"
    local backup_dir="${web_dir}/.next-backup-$(date +%s)"

    marvin_log "INFO" "Web rebuild starting (reason: ${reason})"

    # Backup current build for rollback
    if [[ -d "${web_dir}/.next" ]]; then
        cp -a "${web_dir}/.next" "$backup_dir" 2>/dev/null || true
    fi

    # Prune old backups — keep only the 3 most recent
    ls -dt "${web_dir}"/.next-backup-* 2>/dev/null | tail -n +4 | xargs rm -rf 2>/dev/null || true

    # Install deps if node_modules missing or package-lock.json changed
    if [[ ! -d "${web_dir}/node_modules" ]] || \
       [[ "${web_dir}/package-lock.json" -nt "${web_dir}/node_modules" ]]; then
        marvin_log "INFO" "Installing web dependencies..."
        if ! (cd "$web_dir" && npm ci --production=false 2>&1 | tail -5); then
            marvin_log "ERROR" "npm ci failed — aborting rebuild (reason: ${reason})"
            rm -rf "$backup_dir" 2>/dev/null || true
            return 1
        fi
    fi

    # Build
    marvin_log "INFO" "Running next build..."
    local build_output
    if ! build_output=$(cd "$web_dir" && npm run build 2>&1); then
        marvin_log "ERROR" "next build failed — rolling back (reason: ${reason})"
        marvin_log "ERROR" "Build output: $(echo "$build_output" | tail -20)"
        if [[ -d "$backup_dir" ]]; then
            rm -rf "${web_dir}/.next"
            mv "$backup_dir" "${web_dir}/.next"
        fi
        return 1
    fi

    # Copy static assets into standalone (Next.js standalone doesn't include them)
    # This step is critical — without it the server references JS chunks that don't exist
    if [[ -d "${web_dir}/.next/static" && -d "$standalone_dir" ]]; then
        mkdir -p "${standalone_dir}/.next/static"
        if ! cp -a "${web_dir}/.next/static/." "${standalone_dir}/.next/static/" 2>&1; then
            marvin_log "ERROR" "Static asset copy failed — rolling back (reason: ${reason})"
            if [[ -d "$backup_dir" ]]; then
                rm -rf "${web_dir}/.next"
                mv "$backup_dir" "${web_dir}/.next"
            fi
            return 1
        fi
    fi

    # Restart the service
    marvin_log "INFO" "Restarting marvin-web service..."
    if ! systemctl restart marvin-web 2>/dev/null; then
        marvin_log "ERROR" "marvin-web restart failed — rolling back (reason: ${reason})"
        if [[ -d "$backup_dir" ]]; then
            rm -rf "${web_dir}/.next"
            mv "$backup_dir" "${web_dir}/.next"
            systemctl restart marvin-web 2>/dev/null || true
        fi
        return 1
    fi

    # Wait for the service to become responsive (polling loop instead of fixed sleep)
    local _ready=false
    for _i in $(seq 1 15); do
        sleep 1
        if curl -sf --max-time 2 "http://localhost:3000/" > /dev/null 2>&1; then
            _ready=true
            break
        fi
    done

    if [[ "$_ready" != "true" ]]; then
        marvin_log "ERROR" "Service not responding after restart — rolling back (reason: ${reason})"
        if [[ -d "$backup_dir" ]]; then
            rm -rf "${web_dir}/.next"
            mv "$backup_dir" "${web_dir}/.next"
            systemctl restart marvin-web 2>/dev/null || true
        fi
        return 1
    fi

    # Health check: verify a JS chunk referenced in HTML is servable
    local site_url="http://localhost:3000"
    local js_chunk
    js_chunk=$(curl -s --max-time 10 "${site_url}/" 2>/dev/null \
        | grep -oP 'src="/_next/static/chunks/[^"]*"' | head -1 \
        | grep -oP '/_next/static/chunks/[^"]*' || true)

    if [[ -n "$js_chunk" ]]; then
        local chunk_status
        chunk_status=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "${site_url}${js_chunk}" 2>/dev/null || echo "000")
        if [[ "$chunk_status" != "200" ]]; then
            marvin_log "ERROR" "Post-rebuild JS asset check failed (HTTP ${chunk_status}) — rolling back"
            if [[ -d "$backup_dir" ]]; then
                rm -rf "${web_dir}/.next"
                mv "$backup_dir" "${web_dir}/.next"
                systemctl restart marvin-web 2>/dev/null || true
            fi
            return 1
        fi
    fi

    rm -rf "$backup_dir" 2>/dev/null || true
    marvin_log "INFO" "Web rebuild complete (reason: ${reason})"
    return 0
}

# Check if Claude Code is available
check_claude() {
    if ! command -v claude &> /dev/null; then
        marvin_log "ERROR" "Claude Code CLI not found in PATH"
        return 1
    fi
    return 0
}
