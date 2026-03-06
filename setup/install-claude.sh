#!/usr/bin/env bash
# =============================================================================
# Install Claude Code CLI
# =============================================================================

set -euo pipefail

log() {
    echo "[MARVIN] $1"
}

log "Installing Claude Code CLI..."

# Method 1: npm global install (most common)
if command -v npm &> /dev/null; then
    npm install -g @anthropic-ai/claude-code 2>/dev/null || true
fi

# Verify installation
if command -v claude &> /dev/null; then
    log "Claude Code CLI installed: $(claude --version 2>/dev/null || echo 'version unknown')"
else
    log "WARNING: Claude Code CLI not found in PATH."
    log "You may need to install it manually:"
    log "  npm install -g @anthropic-ai/claude-code"
    log "  or follow: https://docs.anthropic.com/en/docs/claude-code"
fi

# Create a wrapper script that ensures proper environment
cat > /usr/local/bin/marvin-claude << 'WRAPPER'
#!/usr/bin/env bash
# Marvin's Claude Code wrapper — ensures environment is set up
# and logs every invocation

MARVIN_DIR="/home/marvin/git"
LOG_DIR="${MARVIN_DIR}/data/logs"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_ID=$(date +%s)

# Load environment
if [[ -f /etc/environment ]]; then
    set -a
    source /etc/environment
    set +a
fi

# Load any local env overrides
if [[ -f "${MARVIN_DIR}/.env" ]]; then
    set -a
    source "${MARVIN_DIR}/.env"
    set +a
fi

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Log the invocation
INVOCATION_LOG="${LOG_DIR}/invocation-${RUN_ID}.json"
jq -n \
    --arg run_id "${RUN_ID}" \
    --arg timestamp "${TIMESTAMP}" \
    --arg task "${1:-}" \
    --arg prompt_file "${2:-none}" \
    '{run_id: $run_id, timestamp: $timestamp, task: $task, prompt_file: $prompt_file, status: "started"}' \
    > "$INVOCATION_LOG"

# Run Claude Code in non-interactive (print) mode
# The -p flag makes it non-interactive
RESULT=$(claude -p "$@" 2>&1) || true
EXIT_CODE=$?

# Update invocation log with result
COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTPUT_LENGTH=${#RESULT}
jq \
    --arg status "$([ "$EXIT_CODE" -eq 0 ] && echo completed || echo failed)" \
    --argjson exit_code "$EXIT_CODE" \
    --argjson output_length "$OUTPUT_LENGTH" \
    --arg completed_at "$COMPLETED_AT" \
    '. + {status: $status, exit_code: $exit_code, output_length: $output_length, completed_at: $completed_at}' \
    "$INVOCATION_LOG" > "${INVOCATION_LOG}.tmp" && mv "${INVOCATION_LOG}.tmp" "$INVOCATION_LOG" \
    2>/dev/null || true

echo "$RESULT"
exit $EXIT_CODE
WRAPPER

chmod +x /usr/local/bin/marvin-claude
log "Marvin wrapper installed at /usr/local/bin/marvin-claude"
