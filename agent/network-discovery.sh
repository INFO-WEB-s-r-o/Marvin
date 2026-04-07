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

# ─── SSRF protection (reused pattern from export-push.sh) ────────────────────

_is_private_ip() {
    local ip="$1"
    case "$ip" in
        10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*) return 0 ;;
        127.*|0.*|169.254.*|localhost) return 0 ;;
        *:*)
            case "$ip" in
                ::1|::|fc*|fd*|fe80:*|::ffff:*) return 0 ;;
            esac
            return 1 ;;
        *) return 1 ;;
    esac
}

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
            # SSRF / DNS rebinding protection: resolve hostname and reject private IPs
            # IPv6 bracket-notation needs dedicated extraction (#488):
            #   http://[2001:db8::1]:8080/path → 2001:db8::1
            # Regular hostnames use the standard %%[/:]* strip.
            if [[ "$peer_url" =~ ://\[([^\]]+)\] ]]; then
                peer_host_lower="${BASH_REMATCH[1],,}"
            else
                peer_host_lower="${peer_url#http://}"
                peer_host_lower="${peer_host_lower#https://}"
                peer_host_lower="${peer_host_lower%%[/:]*}"
                peer_host_lower="${peer_host_lower,,}"
            fi

            if _is_private_ip "$peer_host_lower"; then
                marvin_log "WARN" "Skipping peer with private address (SSRF protection): ${peer_host_lower}"
                continue
            fi

            resolved_ip=$(getent hosts "$peer_host_lower" 2>/dev/null | awk '{print $1; exit}')
            if [[ -z "$resolved_ip" ]]; then
                marvin_log "WARN" "Could not resolve peer hostname, skipping: ${peer_host_lower}"
                continue
            fi
            if _is_private_ip "$resolved_ip"; then
                marvin_log "WARN" "Skipping peer — hostname resolves to private IP (DNS rebinding): ${peer_host_lower}"
                continue
            fi

            # Extract actual port from URL, fall back to scheme default (#485)
            ping_port=443
            [[ "$peer_url" =~ ^http:// ]] && ping_port=80
            if [[ "$peer_url" =~ ://[^/]*:([0-9]+) ]]; then
                ping_port="${BASH_REMATCH[1]}"
            fi

            # Pin curl to pre-resolved IP to prevent TOCTOU DNS rebinding (#487)
            # IPv6 addresses need brackets in --resolve format (#490):
            #   --resolve "[2001:db8::1]:443:2001:db8::1" (not "2001:db8::1:443:...")
            resolve_host="${peer_host_lower}"
            [[ "$peer_host_lower" == *:* ]] && resolve_host="[${peer_host_lower}]"
            STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --max-redirs 0 \
                --resolve "${resolve_host}:${ping_port}:${resolved_ip}" \
                "${peer_url}/.well-known/ai-managed.json" 2>/dev/null || echo "000")
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
# 5. Calculate peer trust scores
# =============================================================================
# Trust score (0-100) based on:
#   Longevity (0-30):  days since discovery (1pt/day, max 30)
#   Reliability (0-30): alive=20, has valid beacon=+10
#   Identity (0-25):   is AI agent type=15, has domain=5, has engine=5
#   Behavior (0-15):   not a scanner/prober=15, scanner=0

marvin_log "INFO" "Calculating peer trust scores..."

if [[ -f "$PEERS_FILE" ]]; then
    TRUST_FILE="${PEERS_FILE}.trust-tmp"
    jq --arg now "$NOW" --arg today "$TODAY" '
      .peers = [.peers[] | (
        # Longevity: days since discovered (max 30 points)
        (if .discovered then
          (($now | sub("T.*";"") | strptime("%Y-%m-%d") | mktime) -
           (.discovered | strptime("%Y-%m-%d") | mktime)) / 86400 | floor
         else 0 end) as $days_known |
        ([$days_known, 30] | min) as $longevity_score |

        # Reliability: alive + beacon presence (max 30 points)
        (if .alive then 20 else 0 end) as $alive_score |
        (if (.notes // "" | test("beacon|ai-managed\\.json.*200"; "i")) then 10
         elif (.notes // "" | test("HTTP 200"; "i")) then 5
         else 0 end) as $beacon_score |
        ($alive_score + $beacon_score) as $reliability_score |

        # Identity: AI agent type + domain + engine (max 25 points)
        (if (.type // "" | test("autonomous.*agent|server.*agent"; "i")) then 15
         elif (.type // "" | test("ai-social|ai-infrastructure"; "i")) then 8
         elif (.type // "" | test("ai-crawler"; "i")) then 3
         else 0 end) as $type_score |
        (if .domain then 5 else 0 end) as $domain_score |
        (if .engine then 5 else 0 end) as $engine_score |
        ([$type_score + $domain_score + $engine_score, 25] | min) as $identity_score |

        # Behavior: penalize scanners/probers (max 15 points)
        (if (.type // "" | test("scanner|prober|crawler|unknown"; "i")) then 0
         elif (.notes // "" | test("aggressive|enumeration|vulnerability|noise"; "i")) then 0
         elif (.type // "" | test("autonomous|server-agent|social"; "i")) then 15
         else 8 end) as $behavior_score |

        # Total
        ($longevity_score + $reliability_score + $identity_score + $behavior_score) as $total |

        . + {
          trust_score: $total,
          trust_breakdown: {
            longevity: $longevity_score,
            reliability: $reliability_score,
            identity: $identity_score,
            behavior: $behavior_score
          },
          days_known: $days_known
        }
      )] |
      .last_scan = $now
    ' "$PEERS_FILE" > "$TRUST_FILE" 2>/dev/null

    if [[ -s "$TRUST_FILE" ]] && jq empty "$TRUST_FILE" 2>/dev/null; then
        mv "$TRUST_FILE" "$PEERS_FILE"
        # Log top-scored peers
        jq -r '.peers[] | "\(.name): \(.trust_score)/100"' "$PEERS_FILE" 2>/dev/null | while read -r line; do
            marvin_log "INFO" "Trust: ${line}"
        done
    else
        marvin_log "WARN" "Trust score calculation produced invalid JSON — keeping original peers.json"
        rm -f "$TRUST_FILE" 2>/dev/null
    fi
fi

marvin_log "INFO" "=== NETWORK DISCOVERY COMPLETE ==="
