#!/usr/bin/env bash
# =============================================================================
# Marvin — Logging Library
# =============================================================================
# Shared logging functions: plain text, structured JSON, and error trapping.
#
# Requires these variables from common.sh:
#   LOGS_DIR, TODAY
#
# Usage: sourced automatically by common.sh (do not source directly)
# =============================================================================

# Plain text logging — appends to data/logs/YYYY-MM-DD.log
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
