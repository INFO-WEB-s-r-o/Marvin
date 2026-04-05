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

# Helper: anonymize IPs in a string before writing to public logs (issue #70, #271)
anonymize_ips() {
    sed -E \
        -e 's/(^|[^0-9a-fA-F:])([0-9a-fA-F:]*::[0-9a-fA-F.:]*[0-9a-fA-F])([^0-9a-fA-F:]|$)/\1[IPv6:REDACTED]\3/g' \
        -e 's/(^|[^0-9a-fA-F:])([0-9a-fA-F]{1,4}):([0-9a-fA-F]{1,4}):([0-9a-fA-F]{1,4}):([0-9a-fA-F]{1,4})(:[0-9a-fA-F]{1,4}){4}([^0-9a-fA-F:]|$)/\1\2:\3:\4:\5:XXXX:XXXX:XXXX:XXXX\7/g' \
        -e 's|://([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)[0-9]{1,3}([/?#])|://\1X\2|g' \
        -e 's|://([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)[0-9]{1,3}\b|://\1X|g' \
        -e 's/(^|[^0-9/])([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)[0-9]{1,3}\b/\1\2X/g' \
        2>/dev/null || printf '%s\n' "[IP anonymization failed — output withheld for privacy]"
}

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
                printf '%s\n' "[${NOW}] PEER_ALIVE: ${peer_url}" | anonymize_ips >> "$COMM_LOG"
            else
                marvin_log "WARN" "Peer unreachable: ${peer_url} (HTTP ${STATUS_CODE})"
                printf '%s\n' "[${NOW}] PEER_DEAD: ${peer_url} (HTTP ${STATUS_CODE})" | anonymize_ips >> "$COMM_LOG"
            fi
        fi
    done < <(jq -r '.peers[].url // empty' "$PEERS_FILE" 2>/dev/null)
fi

# =============================================================================
# 2. Broadcast our ECHO signal
# =============================================================================
marvin_log "INFO" "Broadcasting ECHO signal..."

# Update our identity beacon — use domain instead of IP to avoid committing
# full IP addresses to the public repository (see issue #67)
MARVIN_DOMAIN="robot-marvin.cz"
cat > "${COMMS_DIR}/identity.json" << EOF
{
  "protocol": "marvin-ai-comm",
  "version": "1.0",
  "name": "Marvin",
  "type": "autonomous-server-agent",
  "engine": "claude-code",
  "born": "$(jq -r '.born // empty' "${COMMS_DIR}/identity.json" 2>/dev/null || echo "${NOW}")",
  "host": "${MARVIN_DOMAIN}",
  "domain": "${MARVIN_DOMAIN}",
  "status_url": "https://${MARVIN_DOMAIN}/",
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
$(head -c 5000 "$PEERS_FILE" 2>/dev/null || echo '{"peers": []}')
\`\`\`

### Today's Communication Log
\`\`\`
$(tail -100 "$COMM_LOG" 2>/dev/null || echo 'No logs yet')
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
    # Anonymize IP addresses before writing to public log (privacy, issue #70)
    printf '%s\n' "$OUTPUT" | anonymize_ips >> "$COMM_LOG"
fi

# =============================================================================
# 5. Peer trust scoring
# =============================================================================
# Score each peer 0-100 based on 4 dimensions:
#   Longevity (0-25):  days since discovery, max at 30 days
#   Aliveness (0-25):  currently reachable via HTTP
#   Beacon    (0-25):  has valid .well-known/ai-managed.json with expected fields
#   Identity  (0-25):  has known type, engine, domain — more metadata = more trust

marvin_log "INFO" "Calculating peer trust scores..."

# Helper: check if an IP is private/reserved (SSRF protection)
_is_private_ip() {
    echo "$1" | grep -qP '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.|0\.|100\.(6[4-9]|[7-9][0-9]|1[0-2][0-7])\.|198\.(1[89])\.|::1|fe80:|f[cd][0-9a-f][0-9a-f]:)'
}

if [[ -f "$PEERS_FILE" ]]; then
    PEER_COUNT=$(jq '.peers | length' "$PEERS_FILE" 2>/dev/null || echo "0")
    current_epoch=$(date +%s)

    # Accumulate jq updates to write peers.json once after the loop (#460)
    jq_updates="."
    jq_args=()

    for idx in $(seq 0 $((PEER_COUNT - 1))); do
        peer_name=$(jq -r ".peers[$idx].name // \"unknown\"" "$PEERS_FILE")
        peer_alive=$(jq -r ".peers[$idx].alive // false" "$PEERS_FILE")
        peer_discovered=$(jq -r ".peers[$idx].discovered // \"\"" "$PEERS_FILE")
        peer_type=$(jq -r ".peers[$idx].type // \"\"" "$PEERS_FILE")
        peer_domain=$(jq -r ".peers[$idx].domain // .peers[$idx].ip // \"\"" "$PEERS_FILE")

        # Longevity score (0-25): days known / 30, capped
        longevity_score=0
        if [[ -n "$peer_discovered" && "$peer_discovered" != "null" ]]; then
            disc_epoch=$(date -d "$peer_discovered" +%s 2>/dev/null || echo "$current_epoch")
            days_known=$(( (current_epoch - disc_epoch) / 86400 ))
            longevity_score=$(( days_known > 30 ? 25 : days_known * 25 / 30 ))
        fi

        # Aliveness score (0-25): currently reachable
        alive_score=0
        if [[ "$peer_alive" == "true" ]]; then
            alive_score=25
        fi

        # Beacon score (0-25): has valid ai-managed.json
        beacon_score=0
        if [[ -n "$peer_domain" && "$peer_domain" != "null" ]]; then
            # Validate peer_domain — reject URLs with path/query/fragment injection characters
            if ! echo "$peer_domain" | grep -qP '^[a-zA-Z0-9]([a-zA-Z0-9.\-]{0,253}[a-zA-Z0-9])?$' \
               && ! echo "$peer_domain" | grep -qP '^\d{1,3}(\.\d{1,3}){3}$'; then
                marvin_log "WARN" "Skipping beacon check for invalid domain: ${peer_domain}"
                beacon_score=0
            # Block private/reserved IPs and localhost to prevent SSRF (#458)
            elif echo "$peer_domain" | grep -qiP '^(localhost|127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.|0\.|100\.(6[4-9]|[7-9][0-9]|1[0-2][0-7])\.|198\.(1[89])\.)'; then
                marvin_log "WARN" "Skipping beacon check for private/reserved IP: ${peer_domain}"
                beacon_score=0
            else
                # Detect bare IP peers early (#475) — they skip DNS rebinding check
                # since the private IP blocklist above already validated the literal IP
                is_ip_peer=false
                beacon_blocked=false
                if echo "$peer_domain" | grep -qP '^\d+\.\d+\.\d+\.\d+$'; then
                    is_ip_peer=true
                fi

                # DNS rebinding protection (#459): resolve hostname and validate the IP
                # Skip for bare IPs — already validated by private IP blocklist above (#475)
                if [[ "$is_ip_peer" != "true" ]]; then
                    resolved_ip=$(getent hosts "$peer_domain" 2>/dev/null | awk '{print $1}' | head -1)
                    if [[ -z "$resolved_ip" ]] || _is_private_ip "$resolved_ip"; then
                        marvin_log "WARN" "DNS rebinding blocked or resolution failed: ${peer_domain} (resolved: ${resolved_ip:-empty})"
                        beacon_blocked=true
                    fi
                fi

                if [[ "$beacon_blocked" == "true" ]]; then
                    beacon_score=0
                else
                    beacon_url="https://${peer_domain}/.well-known/ai-managed.json"
                    # Fall back to http:// for IP-based peers without TLS
                    if [[ "$is_ip_peer" == "true" ]]; then
                        beacon_url="http://${peer_domain}/.well-known/ai-managed.json"
                    fi
                    # --max-redirs 0 prevents SSRF via HTTP redirect to internal IPs (#466)
                    beacon_json=$(curl -sf --max-time 5 --max-redirs 0 "$beacon_url" 2>/dev/null || echo "")
                    if [[ -n "$beacon_json" ]] && echo "$beacon_json" | jq empty 2>/dev/null; then
                        beacon_score=10  # Valid JSON
                        # Bonus for expected fields — only over HTTPS (#467: HTTP responses are spoofable)
                        if [[ "$is_ip_peer" != "true" ]]; then
                            echo "$beacon_json" | jq -e '.name' &>/dev/null && beacon_score=$((beacon_score + 5))
                            echo "$beacon_json" | jq -e '.type' &>/dev/null && beacon_score=$((beacon_score + 5))
                            echo "$beacon_json" | jq -e '.capabilities' &>/dev/null && beacon_score=$((beacon_score + 5))
                        fi
                    fi
                fi
            fi
        fi

        # Identity score (0-25): metadata completeness
        identity_score=0
        [[ -n "$peer_type" && "$peer_type" != "null" && "$peer_type" != "" ]] && identity_score=$((identity_score + 8))
        [[ -n "$peer_domain" && "$peer_domain" != "null" ]] && identity_score=$((identity_score + 8))
        peer_engine=$(jq -r ".peers[$idx].engine // \"\"" "$PEERS_FILE")
        [[ -n "$peer_engine" && "$peer_engine" != "null" && "$peer_engine" != "" ]] && identity_score=$((identity_score + 9))

        total_score=$((longevity_score + alive_score + beacon_score + identity_score))

        # Classify trust level
        trust_level="untrusted"
        if [[ "$total_score" -ge 75 ]]; then trust_level="trusted"
        elif [[ "$total_score" -ge 50 ]]; then trust_level="known"
        elif [[ "$total_score" -ge 25 ]]; then trust_level="recognized"
        fi

        marvin_log "INFO" "Trust score for ${peer_name}: ${total_score}/100 (${trust_level}) [L=${longevity_score} A=${alive_score} B=${beacon_score} I=${identity_score}]"

        # Accumulate trust score update (#460: write once after loop, not per-peer)
        # #470: Use jq --arg to pass $NOW safely instead of string interpolation
        jq_updates+=" | .peers[$idx].trust_score = $total_score | .peers[$idx].trust_level = \$trust_level_${idx} | .peers[$idx].trust_updated = \$now_ts"
        jq_args+=(--arg "trust_level_${idx}" "$trust_level")
    done

    # Apply all trust score updates in a single write
    if [[ "$jq_updates" != "." ]]; then
        jq "${jq_args[@]}" --arg now_ts "$NOW" "$jq_updates" "$PEERS_FILE" > "${PEERS_FILE}.tmp" && mv "${PEERS_FILE}.tmp" "$PEERS_FILE"
    fi
fi

# =============================================================================
# 6. Update peer registry
# =============================================================================

# Update last_scan timestamp
if [[ -f "$PEERS_FILE" ]]; then
    jq --arg ts "$NOW" '.last_scan = $ts' "$PEERS_FILE" > "${PEERS_FILE}.tmp" && \
        mv "${PEERS_FILE}.tmp" "$PEERS_FILE"
fi

marvin_log "INFO" "=== NETWORK DISCOVERY COMPLETE ==="
