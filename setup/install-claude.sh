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

MARVIN_DIR="/opt/marvin"
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
cat > "$INVOCATION_LOG" << EOF
{
  "run_id": "${RUN_ID}",
  "timestamp": "${TIMESTAMP}",
  "task": "$1",
  "prompt_file": "${2:-none}",
  "status": "started"
}
EOF

# Run Claude Code in non-interactive (print) mode
# The -p flag makes it non-interactive
RESULT=$(claude -p "$@" 2>&1) || true
EXIT_CODE=$?

# Update invocation log with result
python3 -c "
import json, sys
with open('${INVOCATION_LOG}', 'r') as f:
    data = json.load(f)
data['status'] = 'completed' if ${EXIT_CODE} == 0 else 'failed'
data['exit_code'] = ${EXIT_CODE}
data['output_length'] = len('''${RESULT}''')
data['completed_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
with open('${INVOCATION_LOG}', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true

echo "$RESULT"
exit $EXIT_CODE
WRAPPER

chmod +x /usr/local/bin/marvin-claude
log "Marvin wrapper installed at /usr/local/bin/marvin-claude"
