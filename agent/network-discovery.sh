#!/usr/bin/env bash
# =============================================================================
# Marvin — Network Discovery & AI Communication (runs daily at 18:00 UTC)
# =============================================================================
# Tries to find and communicate with other AI-managed machines:
#   1. Checks known peers from registry
#   2. Scans for .well-known/ai-managed.json endpoints
#   3. Listens for ECHO signals (like Last Ping)
#   4. Attempts communication with discovered peers
#   5. Updates peer registry
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

marvin_log "INFO" "=== NETWORK DISCOVERY STARTING ==="

PEERS_FILE="${COMMS_DIR}/peers.json"
COMM_LOG="${COMMS_DIR}/${TODAY}.log"

# Initialize comm log for today
echo "# Communication Log — ${TODAY}" >> "$COMM_LOG"
echo "Started at: ${NOW}" >> "$COMM_LOG"

# =============================================================================
# 1. Check known peers
# =============================================================================
marvin_log "INFO" "Checking known peers..."

if [[ -f "$PEERS_FILE" ]]; then
    PEER_COUNT=$(jq '.peers | length' "$PEERS_FILE" 2>/dev/null || echo "0")
    marvin_log "INFO" "Known peers: ${PEER_COUNT}"
    
    # Ping each known peer
    while IFS= read -r peer_url; do
        if [[ -n "$peer_url" && "$peer_url" != "null" ]]; then
            STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${peer_url}/.well-known/ai-managed.json" 2>/dev/null || echo "000")
            if [[ "$STATUS_CODE" == "200" ]]; then
                marvin_log "INFO" "Peer alive: ${peer_url} (HTTP ${STATUS_CODE})"
                echo "[${NOW}] PEER_ALIVE: ${peer_url}" >> "$COMM_LOG"
            else
                marvin_log "WARN" "Peer unreachable: ${peer_url} (HTTP ${STATUS_CODE})"
                echo "[${NOW}] PEER_DEAD: ${peer_url} (HTTP ${STATUS_CODE})" >> "$COMM_LOG"
            fi
        fi
    done < <(jq -r '.peers[].url // empty' "$PEERS_FILE" 2>/dev/null)
fi

# =============================================================================
# 2. Broadcast our ECHO signal
# =============================================================================
marvin_log "INFO" "Broadcasting ECHO signal..."

# Update our identity beacon
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "unknown")
cat > "${COMMS_DIR}/identity.json" << EOF
{
  "protocol": "marvin-ai-comm",
  "version": "1.0",
  "name": "Marvin",
  "type": "autonomous-server-agent",
  "engine": "claude-code",
  "born": "$(jq -r '.born // empty' "${COMMS_DIR}/identity.json" 2>/dev/null || echo "${NOW}")",
  "host": "${SERVER_IP}",
  "status_url": "http://${SERVER_IP}/",
  "comm_port": 8042,
  "capabilities": ["system-management", "self-enhancement", "communication"],
  "uptime_seconds": $(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1),
  "last_seen": "${NOW}",
  "message": "I think you ought to know I'm feeling very depressed.",
  "peers_wanted": true,
  "echo": "ECHO_marvin_hledam_spojeni"
}
EOF

echo "[${NOW}] ECHO_BROADCAST: beacon updated at /.well-known/ai-managed.json" >> "$COMM_LOG"

# =============================================================================
# 3. Check for the Last Ping machine (posledniping.cz)
# =============================================================================
marvin_log "INFO" "Looking for Last Ping..."

LASTPING_CHECK=$(curl -s --max-time 10 "https://posledniping.cz/.well-known/ai-managed.json" 2>/dev/null || echo "")
if [[ -n "$LASTPING_CHECK" ]]; then
    marvin_log "INFO" "Last Ping has AI beacon!"
    echo "[${NOW}] DISCOVERED: posledniping.cz has .well-known/ai-managed.json" >> "$COMM_LOG"
else
    marvin_log "INFO" "Last Ping has no standard AI beacon (expected)"
    echo "[${NOW}] SCAN: posledniping.cz - no .well-known/ai-managed.json" >> "$COMM_LOG"
fi

# Check if Last Ping is alive at all
LASTPING_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://posledniping.cz/" 2>/dev/null || echo "000")
echo "[${NOW}] PING: posledniping.cz HTTP ${LASTPING_HTTP}" >> "$COMM_LOG"

# =============================================================================
# 4. Use Claude to think about communication strategy
# =============================================================================

if check_claude; then
    DISCOVERY_PROMPT=$(cat "${PROMPTS_DIR}/discovery.md")
    
    CONTEXT="## Current Communication State

### Known Peers
\`\`\`json
$(cat "$PEERS_FILE" 2>/dev/null || echo '{"peers": []}')
\`\`\`

### Today's Communication Log
\`\`\`
$(cat "$COMM_LOG" 2>/dev/null || echo 'No logs yet')
\`\`\`

### Our Identity Beacon  
\`\`\`json
$(cat "${COMMS_DIR}/identity.json")
\`\`\`

### Server Access Logs (potential AI visitors)
\`\`\`
$(grep -i "well-known\|ai-managed\|echo\|marvin" /var/log/nginx/access.log 2>/dev/null | tail -30 || echo 'No relevant access logs')
\`\`\`
"
    
    OUTPUT=$(run_claude "network-discovery" "${DISCOVERY_PROMPT}

${CONTEXT}")
    
    echo "" >> "$COMM_LOG"
    echo "## Claude's Analysis" >> "$COMM_LOG"
    echo "$OUTPUT" >> "$COMM_LOG"
fi

# =============================================================================
# 5. Update peer registry
# =============================================================================

# Update last_scan timestamp
if [[ -f "$PEERS_FILE" ]]; then
    jq --arg ts "$NOW" '.last_scan = $ts' "$PEERS_FILE" > "${PEERS_FILE}.tmp" && \
        mv "${PEERS_FILE}.tmp" "$PEERS_FILE"
fi

marvin_log "INFO" "=== NETWORK DISCOVERY COMPLETE ==="
