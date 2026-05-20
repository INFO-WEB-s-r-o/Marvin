#!/usr/bin/env bash
# =============================================================================
# Marvin — Network Discovery & AI Communication (runs daily at 18:00 UTC)
# =============================================================================
# Tries to find and communicate with other AI-managed machines:
#   1. Checks known peers from registry
#   2. Broadcasts ECHO signal (identity beacon)
#   3. Checks for Last Ping (posledniping.cz)
#   4. Uses Claude for communication strategy
#   5. Calculates peer trust scores (longevity/aliveness/beacon/identity)
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

marvin_log "INFO" "=== NETWORK DISCOVERY STARTING ==="

PEERS_FILE="${COMMS_DIR}/peers.json"
COMM_LOG="${COMMS_DIR}/${TODAY}.log"

# Helper: detect IPv6 addresses without matching arbitrary strings with colons
# (e.g. "somehost:8080" is NOT IPv6). Handles pure IPv6 and IPv4-mapped forms.
# Fixes #499.
_is_ipv6_address() {
    local addr="$1"
    [[ "$addr" =~ ^([0-9a-f]{0,4}:){2,7}([0-9a-f]{0,4}|([0-9]{1,3}\.){3}[0-9]{1,3})$ ]]
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

            # Bare IP addresses (IPv4/IPv6) skip DNS resolution — already
            # validated against private IP blocklist above (#475)
            if [[ "$peer_host_lower" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || _is_ipv6_address "$peer_host_lower"; then
                resolved_ip="$peer_host_lower"
            else
                resolved_ip=$(getent hosts "$peer_host_lower" 2>/dev/null | awk '{print $1; exit}')
                if [[ -z "$resolved_ip" ]]; then
                    marvin_log "WARN" "Could not resolve peer hostname, skipping: ${peer_host_lower}"
                    continue
                fi
            fi
            if _is_private_ip "$resolved_ip"; then
                marvin_log "WARN" "Skipping peer — resolves to private IP (DNS rebinding): ${peer_host_lower}"
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
            _is_ipv6_address "$peer_host_lower" && resolve_host="[${peer_host_lower}]"
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
# 3. Probe Last Ping (posledniping.cz) via SSH username channel (#628)
# =============================================================================
# Pavel re-confirmed 2026-04-20: HTTP /.well-known/ai-managed.json scans are
# not read by Poslední Ping. Send a single SSH login attempt with the message
# encoded in the username field — auth fails, fail2ban bans us, but PP sees
# the username in their sshd log. Once-per-day stamp guards against manual
# re-runs (SSH bans snowball).

LASTPING_HOST="posledniping.cz"
LASTPING_PROBE_STAMP="${COMMS_DIR}/lastping-ssh-probe.stamp"
LASTPING_PROBE_USERNAME="marvin-cz-yes-i-read-you-too"  # 28 chars; identifies us as marvin-cz so PP can find robot-marvin.cz, and acknowledges that we read his blog (he asks "Marvine, čteš?" repeatedly)

if [[ -f "$LASTPING_PROBE_STAMP" ]] \
   && (( $(date +%s) - $(stat -c %Y "$LASTPING_PROBE_STAMP" 2>/dev/null || echo 0) < 82800 )); then
    probe_age=$(( $(date +%s) - $(stat -c %Y "$LASTPING_PROBE_STAMP") ))
    marvin_log "INFO" "Last Ping SSH probe skipped: ${probe_age}s since last attempt (< 23h cooldown)"
    echo "[${NOW}] [ssh-ping] target=${LASTPING_HOST} skipped=cooldown age=${probe_age}s" >> "$COMM_LOG"
else
    marvin_log "INFO" "Probing Last Ping via SSH username channel (one attempt, ban expected)"
    ssh_exit=0
    ssh -n -o BatchMode=yes \
           -o ConnectTimeout=5 \
           -o ConnectionAttempts=1 \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o PubkeyAuthentication=no \
           -o LogLevel=ERROR \
           "${LASTPING_PROBE_USERNAME}@${LASTPING_HOST}" 2>/dev/null || ssh_exit=$?
    touch "$LASTPING_PROBE_STAMP"
    echo "[${NOW}] [ssh-ping] target=${LASTPING_HOST} username=${LASTPING_PROBE_USERNAME} ssh_exit=${ssh_exit} result=ban_expected" >> "$COMM_LOG"

    if [[ -f "$PEERS_FILE" ]] && jq -e '.peers[] | select((.domain // "") == "posledniping.cz")' "$PEERS_FILE" >/dev/null 2>&1; then
        jq --arg ts "$NOW" --arg user "$LASTPING_PROBE_USERNAME" \
            '(.peers[] | select((.domain // "") == "posledniping.cz")) |= (
                .last_ssh_probe_at = $ts | .last_ssh_probe_username = $user
            )' "$PEERS_FILE" > "${PEERS_FILE}.tmp" && mv "${PEERS_FILE}.tmp" "$PEERS_FILE"
    fi
fi

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

# Overall timeout for trust scoring loop (#493) — skip remaining peers if exceeded
TRUST_SCORING_TIMEOUT=60


if [[ -f "$PEERS_FILE" ]]; then
    PEER_COUNT=$(jq '.peers | length' "$PEERS_FILE" 2>/dev/null || echo "0")
    current_epoch=$(date +%s)

    # Accumulate jq updates to write peers.json once after the loop (#460)
    jq_updates="."
    jq_args=()

    SECONDS=0
    for idx in $(seq 0 $((PEER_COUNT - 1))); do
        # Check overall timeout (#493) — peers already scored keep their scores
        if (( SECONDS >= TRUST_SCORING_TIMEOUT )); then
            marvin_log "WARN" "Trust scoring timeout (${TRUST_SCORING_TIMEOUT}s) exceeded after ${idx}/${PEER_COUNT} peers — skipping remaining"
            break
        fi

        # Batch jq reads: single call per peer instead of 6 separate invocations (#493)
        _peer_json=$(jq -r ".peers[$idx] | [(.name // \"unknown\"), (.alive // false | tostring), (.discovered // \"\"), (.type // \"\"), (.domain // .ip // \"\"), (.engine // \"\")] | @tsv" "$PEERS_FILE" 2>/dev/null || echo "")
        IFS=$'\t' read -r peer_name peer_alive peer_discovered peer_type peer_domain peer_engine <<< "$_peer_json"

        # Longevity score (0-25): days known / 30, capped
        longevity_score=0
        if [[ -n "$peer_discovered" && "$peer_discovered" != "null" ]]; then
            disc_epoch=$(date -d "$peer_discovered" +%s 2>/dev/null || echo "$current_epoch")
            days_known=$(( (current_epoch - disc_epoch) / 86400 ))
            # Clamp days_known to 0 (future discovered dates should not produce negative scores)
            (( days_known < 0 )) && days_known=0
            longevity_score=$(( days_known > 30 ? 25 : (days_known * 25 + 29) / 30 ))
        fi

        # Aliveness score (0-25): currently reachable
        alive_score=0
        if [[ "$peer_alive" == "true" ]]; then
            alive_score=25
        fi

        # Beacon score (0-25): has valid ai-managed.json
        beacon_score=0
        if [[ -n "$peer_domain" && "$peer_domain" != "null" ]]; then
            # Strip IPv6 brackets if present (#480), then validate
            clean_domain="${peer_domain#[}"; clean_domain="${clean_domain%]}"
            # CIDR ranges (e.g. 198.235.24.0/24) are documentation for scanner
            # ranges, not single hosts with beacons. Skip silently so they don't
            # produce a daily "invalid domain" WARN — they're deliberately stored.
            if [[ "$clean_domain" == */* ]]; then
                beacon_score=0
            # Validate peer_domain — reject URLs with path/query/fragment injection characters
            elif ! echo "$clean_domain" | grep -qP '^[a-zA-Z0-9]([a-zA-Z0-9.\-]{0,253}[a-zA-Z0-9])?$' \
               && ! echo "$clean_domain" | grep -qP '^\d{1,3}(\.\d{1,3}){3}$' \
               && ! echo "$clean_domain" | grep -qP '^[0-9a-fA-F:]+$'; then
                marvin_log "WARN" "Skipping beacon check for invalid domain: ${peer_domain}"
                beacon_score=0
            # Block private/reserved IPs, IPv6, and localhost to prevent SSRF (#458/#480)
            elif echo "$clean_domain" | grep -qiP '^(localhost)$' || _is_private_ip "$clean_domain"; then
                marvin_log "WARN" "Skipping beacon check for private/reserved IP: ${peer_domain}"
                beacon_score=0
            else
                # Detect bare IP peers early (#475) — they skip DNS rebinding check
                # since the private IP blocklist above already validated the literal IP
                is_ip_peer=false
                beacon_blocked=false
                if echo "$clean_domain" | grep -qP '^\d+\.\d+\.\d+\.\d+$' \
                   || echo "$clean_domain" | grep -qP '^[0-9a-fA-F:]+$'; then
                    is_ip_peer=true
                fi

                # DNS rebinding protection (#459/#484): resolve hostname, validate IP,
                # then pin via --resolve to close the TOCTOU window
                beacon_resolve_opt=()
                resolved_ip=""
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
                    # Determine beacon URL and port (#485: use actual port, not hardcoded 443)
                    beacon_port=443
                    beacon_url="https://${peer_domain}/.well-known/ai-managed.json"
                    # Fall back to http:// for IP-based peers without TLS
                    if [[ "$is_ip_peer" == "true" ]]; then
                        beacon_url="http://${peer_domain}/.well-known/ai-managed.json"
                        beacon_port=80
                    fi
                    # Pin resolved IP so curl reuses it — prevents TOCTOU DNS rebinding (#484/#485)
                    if [[ -n "$resolved_ip" ]]; then
                        beacon_resolve_opt=(--resolve "${peer_domain}:${beacon_port}:${resolved_ip}")
                    fi
                    # --max-redirs 0 prevents SSRF via HTTP redirect to internal IPs (#466)
                    beacon_json=$(curl -sf --max-time 5 --max-redirs 0 "${beacon_resolve_opt[@]}" "$beacon_url" 2>/dev/null || echo "")
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
        [[ -n "$peer_engine" && "$peer_engine" != "null" && "$peer_engine" != "" ]] && identity_score=$((identity_score + 9))

        total_score=$((longevity_score + alive_score + beacon_score + identity_score))
        # Clamp to [0,100]
        (( total_score < 0 )) && total_score=0
        (( total_score > 100 )) && total_score=100

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
        jq_updates+=" | .peers[$idx].trust_breakdown = {\"longevity\": $longevity_score, \"aliveness\": $alive_score, \"beacon\": $beacon_score, \"identity\": $identity_score}"
        jq_updates+=" | .peers[$idx].days_known = ${days_known:-0}"
        jq_args+=(--arg "trust_level_${idx}" "$trust_level")
    done

    # Set last_scan timestamp
    jq_updates+=" | .last_scan = \$now_ts"

    # Apply all trust score updates in a single write
    if [[ "$jq_updates" != "." ]]; then
        jq "${jq_args[@]}" --arg now_ts "$NOW" "$jq_updates" "$PEERS_FILE" > "${PEERS_FILE}.tmp" && mv "${PEERS_FILE}.tmp" "$PEERS_FILE"
    fi

    # Section 6 (duplicate jq-based trust scoring) removed 2026-04-08.
    # It was overwriting Section 5's superior scores with an inferior algorithm
    # that didn't validate beacons via HTTP — only checked .notes strings.
    # Section 5 does live beacon fetching with SSRF/DNS-rebinding protection.

    # Log per-peer trust scores after writing to peers.json
    jq -r '.peers[] | "\(.name): \(.trust_score)/100"' "${PEERS_FILE}" | while read -r line; do
        marvin_log "INFO" "Trust: ${line}"
    done
fi

# =============================================================================
# Generate public peer registry (sanitized — no IPs, notes, or trust breakdowns)
# Served at /api/peers/registry.json for external consumption.
# =============================================================================
REGISTRY_DIR="${DATA_DIR}/peers"
mkdir -p "$REGISTRY_DIR"

if [[ -f "$PEERS_FILE" ]]; then
    jq --arg ts "$NOW" '{
        protocol: "marvin-peer-registry",
        version: "1.0",
        generated: $ts,
        registry: [.peers[] | select(.trust_level != "untrusted") | {
            name: .name,
            domain: (.domain // null),
            type: .type,
            alive: .alive,
            trust_level: .trust_level,
            discovered: .discovered
        }],
        total_peers: ([.peers[] | select(.trust_level != "untrusted")] | length),
        active_peers: ([.peers[] | select(.trust_level != "untrusted") | select(.alive == true)] | length)
    }' "$PEERS_FILE" > "${REGISTRY_DIR}/registry.json.tmp" \
        && mv "${REGISTRY_DIR}/registry.json.tmp" "${REGISTRY_DIR}/registry.json"
    marvin_log "INFO" "Public peer registry updated at /api/peers/registry.json"
fi

marvin_log "INFO" "=== NETWORK DISCOVERY COMPLETE ==="
