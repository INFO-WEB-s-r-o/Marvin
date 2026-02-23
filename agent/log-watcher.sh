#!/usr/bin/env bash
# =============================================================================
# Marvin — Log Watcher
# Scans /var/log for communication attempts, filtering attacks & noise
# Runs every 30 minutes via cron
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

OFFSETS_FILE="${COMMS_DIR}/log-offsets.json"
SIGNALS_FILE="${COMMS_DIR}/incoming-signals.json"
ANALYSIS_FILE="${COMMS_DIR}/log-analysis-${TODAY}.json"
PROMPT_FILE="${PROMPTS_DIR}/log-analysis.md"
MAX_FEED_SIZE=200000   # ~200KB max per run fed to Claude

# Ensure state files exist
[[ -f "$OFFSETS_FILE" ]] || echo '{}' > "$OFFSETS_FILE"
[[ -f "$SIGNALS_FILE" ]] || echo '{"signals":[],"last_updated":"","total_attacks":0,"total_communication":0}' > "$SIGNALS_FILE"

marvin_log "INFO" "Log watcher starting"

# ─── SSH / attack pattern exclusions ────────────────────────────────────────
# These never leave the filter; we don't even show them to Claude
SSH_PATTERNS=(
    'sshd\['
    'pam_unix.*sshd'
    'ssh2'
    'SSH'
    'publickey for'
    'Disconnected from'
    'Connection closed by'
    'Unable to negotiate'
    'userauth_pubkey'
    'keyboard-interactive'
    'fatal: no matching'
    'banner exchange'
)

# Pre-filter: obvious attacks / scanners we can catch with grep
ATTACK_PATTERNS=(
    'SELECT.*FROM'
    'UNION.*SELECT'
    'DROP TABLE'
    'OR 1=1'
    '\.\./\.\.'
    '/etc/passwd'
    '/etc/shadow'
    'wp-admin'
    'wp-login'
    'wp-content'
    'phpmyadmin'
    'phpMyAdmin'
    '/cgi-bin/'
    '/shell'
    '/cmd'
    '/eval'
    'base64_decode'
    'javascript:'
    '<script'
    '/\.env'
    '/\.git'
    'Nmap'
    'nmap'
    'masscan'
    'ZmEu'
    'Zgrab'
    'zgrab'
    'Nuclei'
    'nuclei'
)

# Web noise: routine dashboard polling, static assets, common crawlers
# These are normal operations — not interesting for communication detection
WEB_NOISE_PATTERNS=(
    'GET /api/status\.json'
    'GET /api/uptime\.json'
    'GET /api/metrics-history\.json'
    'GET /api/blog-index\.json'
    'GET /api/enhancements\.json'
    'GET /api/comms-summary\.json'
    'GET /api/comms/peers\.json'
    'GET /api/about\.json'
    'GET /blog/.*\.md'
    'GET /style\.css'
    'GET /app\.js'
    'GET /i18n\.js'
    'GET /favicon'
    'GET / HTTP'
    'Googlebot'
    'bingbot'
    'Baiduspider'
    'YandexBot'
    'DotBot'
    'AhrefsBot'
    'MJ12bot'
    'SemrushBot'
    'PetalBot'
    'facebookexternalhit'
    'Twitterbot'
)

# Build combined grep exclusion pattern
build_exclude_pattern() {
    local patterns=("$@")
    local result=""
    for p in "${patterns[@]}"; do
        [[ -n "$result" ]] && result="${result}|"
        result="${result}${p}"
    done
    echo "$result"
}

SSH_EXCLUDE=$(build_exclude_pattern "${SSH_PATTERNS[@]}")
ATTACK_EXCLUDE=$(build_exclude_pattern "${ATTACK_PATTERNS[@]}")
WEB_NOISE_EXCLUDE=$(build_exclude_pattern "${WEB_NOISE_PATTERNS[@]}")
FULL_EXCLUDE="${SSH_EXCLUDE}|${ATTACK_EXCLUDE}"

# ─── Interest patterns — entries we WANT to see ────────────────────────────
INTEREST_PATTERNS=(
    '\.well-known'
    'ai-managed'
    'ai-negotiate'
    'X-AI-'
    'X-Marvin-'
    'X-Protocol-'
    'marvin'
    'communicate'
    'hello'
    'protocol'
    'negotiate'
    'echo.*signal'
    'ECHO'
    '/api/'
    ':8042'
    'POST'
    'agent'
    'autonomous'
    'claude'
    'gpt'
    'llm'
    'bot.*chat'
)

INTEREST_RE=$(build_exclude_pattern "${INTEREST_PATTERNS[@]}")

# ─── Scan log files ────────────────────────────────────────────────────────
scan_logs() {
    local collected=""
    local collected_size=0
    local files_scanned=0
    local lines_total=0
    local lines_excluded=0
    local lines_interesting=0

    # Read current offsets
    local offsets
    offsets=$(cat "$OFFSETS_FILE")

    # Find all readable log files (text files, skip binaries, journals, gz)
    local log_files
    log_files=$(find /var/log -type f \
        ! -name '*.gz' \
        ! -name '*.xz' \
        ! -name '*.bz2' \
        ! -name '*.old' \
        ! -name '*.journal' \
        ! -name 'btmp' \
        ! -name 'wtmp' \
        ! -name 'lastlog' \
        ! -name 'faillog' \
        -readable 2>/dev/null | sort)

    while IFS= read -r logfile; do
        [[ -z "$logfile" ]] && continue
        # Skip binary files
        file -b --mime "$logfile" 2>/dev/null | grep -q 'text/' || continue

        local filesize
        filesize=$(stat -c%s "$logfile" 2>/dev/null || stat -f%z "$logfile" 2>/dev/null || echo 0)

        # Get stored offset for this file
        local prev_offset
        prev_offset=$(echo "$offsets" | jq -r --arg f "$logfile" '.[$f] // 0')

        # If file shrunk (rotated), reset offset
        if [[ "$filesize" -lt "$prev_offset" ]]; then
            prev_offset=0
        fi

        # Skip if no new content
        [[ "$filesize" -le "$prev_offset" ]] && continue

        files_scanned=$((files_scanned + 1))

        # Read new content from offset
        local new_content
        new_content=$(tail -c +"$((prev_offset + 1))" "$logfile" 2>/dev/null) || continue
        local new_lines
        new_lines=$(echo "$new_content" | wc -l)
        lines_total=$((lines_total + new_lines))

        # Phase 1: Exclude SSH + obvious attacks
        local filtered
        filtered=$(echo "$new_content" | grep -viE "$FULL_EXCLUDE" 2>/dev/null) || filtered=""
        local excluded_count=$((new_lines - $(echo "$filtered" | wc -l)))
        lines_excluded=$((lines_excluded + excluded_count))

        # Phase 2: Keep only interesting entries (if file is large)
        # For small files or nginx access logs, keep more
        local interesting
        if echo "$logfile" | grep -qE 'nginx|apache|access'; then
            # Web server logs — filter routine polling and known crawlers,
            # then keep only entries matching interest patterns
            interesting=$(echo "$filtered" | grep -viE "$WEB_NOISE_EXCLUDE" 2>/dev/null | grep -iE "$INTEREST_RE" 2>/dev/null) || interesting=""
        else
            # System logs — only keep entries matching interest patterns
            interesting=$(echo "$filtered" | grep -iE "$INTEREST_RE" 2>/dev/null) || interesting=""
        fi

        if [[ -n "$interesting" ]]; then
            local count
            count=$(echo "$interesting" | wc -l)
            lines_interesting=$((lines_interesting + count))

            collected+="
=== ${logfile} (${count} entries) ===
${interesting}
"
            collected_size=$((collected_size + ${#interesting}))
        fi

        # Update offset
        offsets=$(echo "$offsets" | jq --arg f "$logfile" --argjson s "$filesize" '.[$f] = $s')

        # Stop if we've collected enough
        if [[ "$collected_size" -gt "$MAX_FEED_SIZE" ]]; then
            marvin_log "WARN" "Log collection truncated at ${MAX_FEED_SIZE} bytes"
            break
        fi
    done <<< "$log_files"

    # Save updated offsets
    echo "$offsets" | jq '.' > "$OFFSETS_FILE"

    marvin_log "INFO" "Scanned ${files_scanned} files, ${lines_total} new lines, excluded ${lines_excluded}, interesting ${lines_interesting}"

    # Return collected data
    echo "$collected"
}

# ─── Main ───────────────────────────────────────────────────────────────────

collected_logs=$(scan_logs)

if [[ -z "$collected_logs" || ${#collected_logs} -lt 10 ]]; then
    marvin_log "INFO" "No interesting log entries found this cycle"
    exit 0
fi

marvin_log "INFO" "Found ${#collected_logs} bytes of interesting log data — sending to Claude"

# Load the prompt
if [[ ! -f "$PROMPT_FILE" ]]; then
    marvin_log "ERROR" "Log analysis prompt not found: $PROMPT_FILE"
    exit 1
fi

prompt_content=$(cat "$PROMPT_FILE")

# Build the full prompt with log data
analysis_prompt="${prompt_content}

## Log Data to Analyze

\`\`\`
${collected_logs}
\`\`\`

Respond ONLY with the JSON array. No markdown fences, no explanation."

# Run Claude analysis
if ! check_claude; then
    marvin_log "ERROR" "Claude not available, saving raw logs for next run"
    echo "$collected_logs" >> "${COMMS_DIR}/pending-log-review.txt"
    exit 1
fi

raw_output=$(run_claude "log-analysis" "$analysis_prompt")

# Try to extract JSON from the output
analysis_json=$(echo "$raw_output" | sed -n '/^\[/,/^\]/p' | head -500)

if [[ -z "$analysis_json" ]]; then
    # Try extracting from code block
    analysis_json=$(echo "$raw_output" | sed -n '/```json/,/```/p' | sed '1d;$d')
fi

if [[ -z "$analysis_json" ]]; then
    marvin_log "WARN" "Could not parse JSON from Claude output, saving raw"
    echo "$raw_output" > "${COMMS_DIR}/log-analysis-raw-${TIMESTAMP}.txt"
    exit 0
fi

# Save full analysis
if [[ -f "$ANALYSIS_FILE" ]]; then
    # Merge with existing today's analysis
    existing=$(cat "$ANALYSIS_FILE")
    merged=$(echo "$existing" "$analysis_json" | jq -s 'add')
    echo "$merged" | jq '.' > "$ANALYSIS_FILE"
else
    echo "$analysis_json" | jq '.' > "$ANALYSIS_FILE" 2>/dev/null || echo "$analysis_json" > "$ANALYSIS_FILE"
fi

# Update incoming signals file — extract communication_attempt & potential_ai entries
comm_entries=$(echo "$analysis_json" | jq '[.[] | select(.classification == "communication_attempt" or .classification == "potential_ai")]' 2>/dev/null || echo '[]')
attack_count=$(echo "$analysis_json" | jq '[.[] | select(.classification == "attack")] | length' 2>/dev/null || echo 0)
comm_count=$(echo "$analysis_json" | jq '[.[] | select(.classification == "communication_attempt")] | length' 2>/dev/null || echo 0)

# Update signals file
if [[ -f "$SIGNALS_FILE" ]]; then
    existing_signals=$(cat "$SIGNALS_FILE")
else
    existing_signals='{"signals":[],"last_updated":"","total_attacks":0,"total_communication":0}'
fi

updated_signals=$(echo "$existing_signals" | jq \
    --argjson new "$comm_entries" \
    --arg ts "$NOW" \
    --argjson attacks "$attack_count" \
    --argjson comms "$comm_count" '
    .signals = ((.signals + $new) | .[-100:]) |
    .last_updated = $ts |
    .total_attacks = (.total_attacks + $attacks) |
    .total_communication = (.total_communication + $comms)
')

echo "$updated_signals" | jq '.' > "$SIGNALS_FILE"

marvin_log "INFO" "Log analysis complete: ${attack_count} attacks, ${comm_count} communication attempts"

# If communication attempts found, log prominently
if [[ "$comm_count" -gt 0 ]]; then
    marvin_log "NOTICE" "*** ${comm_count} communication attempt(s) detected! Check ${SIGNALS_FILE} ***"
fi
