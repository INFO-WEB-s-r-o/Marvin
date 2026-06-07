#!/usr/bin/env bash
# =============================================================================
# Marvin — Log Watcher
# Scans /var/log for communication attempts, filtering attacks & noise
# Runs every 30 minutes via cron
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

OFFSETS_FILE="${COMMS_DIR}/log-offsets.json"
SIGNALS_FILE="${COMMS_DIR}/incoming-signals.json"
ANALYSIS_FILE="${COMMS_DIR}/log-analysis-${TODAY}.json"
PROMPT_FILE="${PROMPTS_DIR}/log-analysis.md"
MAX_FEED_SIZE=50000   # ~50KB max per run fed to Claude (reduced to avoid context overflow)

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
    # Firewall blocked packets — already handled by UFW/iptables, never contain
    # AI communication attempts. These were flooding the feed via hostname match.
    'UFW BLOCK'
    'UFW AUDIT'
    'UFW ALLOW'
    'IN=.*OUT=.*SRC=.*DST='
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
    # Generic dashboard data feeds: the frontend polls many /api/*.json
    # endpoints continuously, and ALL of them carry the referer
    # "https://robot-marvin.cz/", which matches the `marvin\.cz` INTEREST
    # pattern. Without these, normal browser polling (metrics/recent.json,
    # incidents/summary.json, alerts, peers-public, thoughts, changelog, …)
    # floods the "interesting" feed — 13k+ matching lines in access.log on a
    # busy day, producing 700KB+ prompts (2026-06-05). A GET to a public JSON
    # or SVG feed is never an AI communication attempt; real signals are POSTs
    # to /.well-known/ai-negotiate (not under /api/, still matched by interest).
    'GET /api/[^ ]*\.json'
    'GET /api/[^ ]*\.svg'
    'GET /api/blog'
    'GET /blog/.*\.md'
    'GET /style\.css'
    'GET /app\.js'
    'GET /i18n\.js'
    'GET /favicon'
    'GET / HTTP'
    'GET /_next/'
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

# System noise: internal operations that are never communication attempts
SYSTEM_NOISE_PATTERNS=(
    'CRON\['
    'systemd\['
    'systemd-'
    'snapd\['
    'logrotate'
    'run-parts'
    'anacron'
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
SYSTEM_NOISE_EXCLUDE=$(build_exclude_pattern "${SYSTEM_NOISE_PATTERNS[@]}")
FULL_EXCLUDE="${SSH_EXCLUDE}|${ATTACK_EXCLUDE}"

# ─── Interest patterns — entries we WANT to see ────────────────────────────
INTEREST_PATTERNS=(
    '\.well-known'
    'ai-managed'
    'ai-negotiate'
    'X-AI-'
    'X-Marvin-'
    'X-Protocol-'
    'marvin\.cz'
    'marvin@'
    'communicate'
    'hello'
    'protocol'
    'negotiate'
    'echo.*signal'
    ':8042'
    'POST /.well-known'
    'POST /api/.*negotiate'
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

    # Find readable log files — prioritize security and web logs to stay within context limits
    # Priority files first, then everything else (truncated by MAX_FEED_SIZE)
    local priority_files=""
    for pf in /var/log/auth.log /var/log/fail2ban.log /var/log/nginx/error.log /var/log/nginx/access.log /var/log/marvin-*.log; do
        [[ -f "$pf" && -r "$pf" ]] && priority_files+="${pf}"$'\n'
    done

    local other_files
    other_files=$(find /var/log -type f \
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

    # Combine: priority files first (deduped)
    local log_files
    log_files=$(printf '%s\n%s' "$priority_files" "$other_files" | awk '!seen[$0]++')

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
            # then keep only entries matching interest patterns IN THE REQUEST.
            #
            # Root-cause fix for the dashboard-poll flood (2026-06-05/06): every
            # browser request to the dashboard carries the referer
            # "https://robot-marvin.cz/", and the literal "robot-marvin.cz"
            # *contains* the `marvin\.cz` interest pattern as a substring — so a
            # plain `grep -iE "$INTEREST_RE"` flagged EVERY dashboard poll as
            # "interesting". The WEB_NOISE_EXCLUDE blocklist patched this per
            # endpoint, but any new dashboard feed silently re-introduced the
            # leak (703KB on 2026-06-05, 2.6MB on 2026-06-06 before the cap).
            #
            # The structural fix: strip the trailing referer + user-agent quoted
            # fields (combined-log-format: `... "$referer" "$user_agent"`) before
            # interest-matching, so keywords are only matched against the request
            # line itself. Genuine inbound AI signals are POSTs/GETs to a PATH
            # (e.g. /.well-known/ai-negotiate) or carry a keyword in the request
            # query — all preserved. Referer/UA-only matches (our own dashboard
            # referer, a "claude-bot" UA) are never communication attempts and
            # are correctly dropped. The original full line (incl. referer/UA) is
            # still emitted for Claude's context — only the *match target* is
            # narrowed. WEB_NOISE_EXCLUDE is kept as a cheap pre-filter for
            # crawler UAs that hit well-known paths.
            #
            # INTEREST_RE is passed via the environment (not awk -v) because awk
            # -v processes C escape sequences and would mangle `\.` in the regex.
            #
            # Case-insensitivity via tolower() on BOTH sides, NOT gawk's
            # IGNORECASE=1: IGNORECASE is a gawk extension silently ignored by
            # mawk (Ubuntu's default awk), which would make matching
            # case-sensitive and drop genuine signals (issue #776). tolower() is
            # POSIX and behaves identically on gawk and mawk. Safe here because
            # INTEREST_PATTERNS contain no case-bearing regex metaclasses
            # (\D/\S/\W) — only `\.` literals, which tolower() leaves untouched.
            interesting=$(echo "$filtered" | grep -viE "$WEB_NOISE_EXCLUDE" 2>/dev/null \
                | INTEREST_RE_ENV="$INTEREST_RE" awk 'BEGIN{re=tolower(ENVIRON["INTEREST_RE_ENV"])} { key=$0; sub(/"[^"]*"[[:space:]]+"[^"]*"[[:space:]]*$/,"",key); if (tolower(key) ~ re) print }' 2>/dev/null) || interesting=""
        else
            # System logs — exclude internal operations, then keep only interest matches
            interesting=$(echo "$filtered" | grep -viE "$SYSTEM_NOISE_EXCLUDE" 2>/dev/null | grep -iE "$INTEREST_RE" 2>/dev/null) || interesting=""
        fi

        if [[ -n "$interesting" ]]; then
            # Enforce MAX_FEED_SIZE as a HARD ceiling on the per-file block.
            # Previously the cap was only checked *after* appending a whole
            # file's interesting block, so a single high-volume file (e.g.
            # nginx access.log on a busy dashboard day) could overshoot the
            # 50KB budget by 10x+ — 703KB on 2026-06-05 — and force
            # run_claude's crude 400KB hard-truncation (~177K tokens), an
            # expensive call that silently drops the tail at an arbitrary
            # byte boundary. Bounding the block here keeps the feed within the
            # documented contract.
            local remaining=$((MAX_FEED_SIZE - collected_size))
            if [[ "$remaining" -le 0 ]]; then
                marvin_log "INFO" "Log collection truncated at ${MAX_FEED_SIZE} bytes (expected safety limit)"
                break
            fi
            if [[ ${#interesting} -gt "$remaining" ]]; then
                interesting="${interesting:0:$remaining}"
            fi

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

        # Stop if we've reached the budget
        if [[ "$collected_size" -ge "$MAX_FEED_SIZE" ]]; then
            marvin_log "INFO" "Log collection truncated at ${MAX_FEED_SIZE} bytes (expected safety limit)"
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

# Lock-acquisition timeout: log-watcher runs every 30 min, so a missed cycle
# is cheap — the next cron run will pick up the same offset. Waiting the
# default 5 minutes for the lock burns CPU and trips `set -e` silently when
# self-enhance (10:00 local / 08:00 UTC) holds the lock for its full run.
# Cap at 60s and treat exit 2 (lock timeout) as a clean skip.
export CLAUDE_LOCK_TIMEOUT=60
raw_output=$(run_claude "log-analysis" "$analysis_prompt") && claude_rc=0 || claude_rc=$?

if [[ "$claude_rc" -eq 2 ]]; then
    marvin_log "INFO" "log-analysis skipped — Claude lock held by another task; next 30-min run will catch up"
    exit 0
fi
if [[ "$claude_rc" -ne 0 ]]; then
    marvin_log "WARN" "log-analysis Claude exit ${claude_rc} — skipping this cycle"
    exit 0
fi

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

# Validate the extracted text is actually a JSON array before anything tries to
# merge or query it. The sed extraction above only guarantees non-emptiness, not
# validity — truncated output (head -500 cutting mid-array) or prose-wrapped
# output yields text that crashes the `jq -s 'add'` merge below under
# `set -euo pipefail` + the ERR trap, killing the script before the graceful
# fallback can run and silently dropping that cycle's signal update.
# Mirror the "could not parse" handling: save raw for forensics, skip cleanly.
if ! echo "$analysis_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    marvin_log "WARN" "Claude output is not a valid JSON array, saving raw"
    echo "$raw_output" > "${COMMS_DIR}/log-analysis-raw-${TIMESTAMP}.txt"
    exit 0
fi

# Save full analysis
if [[ -f "$ANALYSIS_FILE" ]]; then
    # Verify existing file is valid JSON before merging
    if jq empty "$ANALYSIS_FILE" 2>/dev/null; then
        existing=$(cat "$ANALYSIS_FILE")
        # `|| true`: a failed merge (incompatible JSON shapes, e.g. array vs
        # object) must fall through to the graceful handler below, not trip
        # set -e / the ERR trap and kill the script (exit-code-masking lesson).
        merged=$(echo "$existing" "$analysis_json" | jq -s 'add' 2>/dev/null) || true
        if [[ -n "$merged" ]] && echo "$merged" | jq empty 2>/dev/null; then
            echo "$merged" | jq '.' > "$ANALYSIS_FILE"
        else
            # Merge produced invalid JSON — log snippet for forensics, then delete (issue #91)
            snippet=$(head -3 "$ANALYSIS_FILE" 2>/dev/null | tr -d '\n\r' | tr -cd '[:print:]' | cut -c1-200 || echo '<empty>')
            marvin_log "WARN" "JSON merge failed — corrupt content snippet: ${snippet}"
            rm -f "$ANALYSIS_FILE"
            echo "$analysis_json" | jq '.' > "$ANALYSIS_FILE" 2>/dev/null || echo "$analysis_json" > "$ANALYSIS_FILE"
        fi
    else
        # Existing file is corrupted — log snippet for forensics, then delete (issue #91)
        snippet=$(head -3 "$ANALYSIS_FILE" 2>/dev/null | tr -d '\n\r' | tr -cd '[:print:]' | cut -c1-200 || echo '<empty>')
        marvin_log "WARN" "Corrupted analysis file — content snippet: ${snippet}"
        rm -f "$ANALYSIS_FILE"
        echo "$analysis_json" | jq '.' > "$ANALYSIS_FILE" 2>/dev/null || echo "$analysis_json" > "$ANALYSIS_FILE"
    fi
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
