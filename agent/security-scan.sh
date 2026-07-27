#!/usr/bin/env bash
# =============================================================================
# Marvin — Daily Security Scan
# =============================================================================
# Runs rkhunter and chkrootkit to detect rootkits, backdoors, and local
# exploits. Results are saved as JSON for the dashboard and logged.
#
# Cron: 04:00 UTC daily (before morning-check)
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR
source "$(dirname "$0")/lib/github.sh"

SECURITY_DIR="${DATA_DIR}/security"
REPORT_FILE="${SECURITY_DIR}/scan-${TODAY}.json"

mkdir -p "$SECURITY_DIR"

marvin_log "INFO" "=== DAILY SECURITY SCAN STARTING ==="

rkhunter_status="skipped"
rkhunter_warnings=0
rkhunter_infected=0
rkhunter_summary=""

chkrootkit_status="skipped"
chkrootkit_infected=0
chkrootkit_summary=""

# ─── 1. rkhunter scan ───────────────────────────────────────────────────────

if command -v rkhunter &>/dev/null; then
    marvin_log "INFO" "Running rkhunter scan..."

    # Update file properties database first (suppresses false positives from updates)
    rkhunter --propupd --quiet 2>/dev/null || true

    RKHUNTER_LOG="/var/log/rkhunter-marvin-${TODAY}.log"

    # Run the scan (--skip-keypress avoids interactive prompts)
    # --report-warnings-only keeps output concise
    if rkhunter --check --skip-keypress --report-warnings-only \
        --logfile "$RKHUNTER_LOG" --no-colors 2>&1; then
        rkhunter_status="clean"
        marvin_log "INFO" "rkhunter: no warnings"
    else
        rkhunter_status="warnings"
        marvin_log "WARN" "rkhunter: warnings detected — check ${RKHUNTER_LOG}"
    fi

    # Parse the log for summary
    if [[ -f "$RKHUNTER_LOG" ]]; then
        # `grep -c` always prints a count to stdout. With `|| echo 0`, when there
        # are 0 matches grep exits 1 *after* printing "0", causing `||` to also
        # print "0" — yielding "0\n0" or "00" (with `tr`), which corrupts the
        # downstream JSON. Use `|| true` so we keep grep's count and only swallow
        # the exit code. (Lesson: grep -c-double-output, 2026-05-01.)
        rkhunter_warnings=$(grep -c '\[ Warning \]' "$RKHUNTER_LOG" 2>/dev/null || true)
        rkhunter_infected=$(grep -c '\[ Infected \]' "$RKHUNTER_LOG" 2>/dev/null || true)
        rkhunter_warnings=${rkhunter_warnings:-0}
        rkhunter_infected=${rkhunter_infected:-0}
        rkhunter_summary=$(grep -E '\[ Warning \]|\[ Infected \]' "$RKHUNTER_LOG" 2>/dev/null | head -20 || echo "")

        if [[ "$rkhunter_infected" -gt 0 ]]; then
            rkhunter_status="infected"
            marvin_log "CRITICAL" "rkhunter found ${rkhunter_infected} infected file(s)!"
        fi

        # Exclude SSH root access warning from overall status — it is already
        # scored separately in self-test.sh (§9a ssh_root_login check).
        # Counting it here double-penalizes the same configuration. (#92)
        #
        # Note: the check-name line reads "Checking if SSH root access is
        # allowed   [ Warning ]". We match the exact check name to avoid
        # suppressing unrelated warnings that might contain "root access".
        if [[ "$rkhunter_status" == "warnings" ]]; then
            _other_warnings=$(grep '\[ Warning \]' "$RKHUNTER_LOG" 2>/dev/null \
                | grep -cv 'Checking if SSH root access is allowed' || true)
            _other_warnings=${_other_warnings:-0}
            if [[ "$_other_warnings" -eq 0 ]]; then
                rkhunter_status="clean"
                rkhunter_warnings=$(( rkhunter_warnings > 0 ? rkhunter_warnings - 1 : 0 ))
                marvin_log "INFO" "rkhunter: only root-access warning (scored separately) — treating as clean"
            fi
        fi
    fi

    # Clean up old scan logs (keep 7 days)
    find /var/log -name 'rkhunter-marvin-*.log' -mtime +7 -delete 2>/dev/null || true
else
    marvin_log "WARN" "rkhunter not installed — skipping"
fi

# ─── 2. chkrootkit scan ─────────────────────────────────────────────────────

if command -v chkrootkit &>/dev/null; then
    marvin_log "INFO" "Running chkrootkit scan..."

    CHKROOTKIT_OUTPUT=$(chkrootkit 2>&1) || true

    # chkrootkit reports "INFECTED" for actual findings
    chkrootkit_infected=$(echo "$CHKROOTKIT_OUTPUT" | grep -c "INFECTED" 2>/dev/null || true)
    chkrootkit_infected=${chkrootkit_infected:-0}
    chkrootkit_summary=$(echo "$CHKROOTKIT_OUTPUT" | grep "INFECTED" 2>/dev/null | head -20 || echo "")

    if [[ "$chkrootkit_infected" -gt 0 ]]; then
        chkrootkit_status="infected"
        marvin_log "CRITICAL" "chkrootkit found ${chkrootkit_infected} infected item(s)!"
    else
        chkrootkit_status="clean"
        marvin_log "INFO" "chkrootkit: clean"
    fi
else
    marvin_log "WARN" "chkrootkit not installed — skipping"
fi

# ─── 3. Additional security checks ──────────────────────────────────────────

# Check for world-writable files in sensitive locations
world_writable=$(find /etc /usr/bin /usr/sbin -type f -perm -o+w 2>/dev/null | head -20 || echo "")
world_writable_count=0
if [[ -n "$world_writable" ]]; then
    world_writable_count=$(echo "$world_writable" | wc -l)
    marvin_log "WARN" "Found ${world_writable_count} world-writable files in sensitive paths"
fi

# Check for SUID/SGID binaries (just count — changes from last scan are interesting)
# `find | wc -l` under `set -o pipefail`: if find exits non-zero (a missing path,
# or EACCES on an unreadable dir — e.g. inside a container, or if /usr/libexec is
# ever dropped) the pipeline fails, so the old `|| echo 0` fired *in addition to*
# wc having already printed the real count, yielding "N\n0". Spliced into the JSON
# at `"suid_sgid_count": ${suid_count}` (line ~746) that produced invalid JSON and
# corrupted latest-scan.json (read by self-test §9c, incident-report, dashboard).
# Capture-then-fallback keeps wc's count and swallows only the exit code.
# (grep-c-double-output lesson; same class as the six sites fixed 2026-05-01.)
suid_count=$(find /usr/bin /usr/sbin /usr/local/bin /usr/lib /usr/libexec -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | wc -l || true)
suid_count=${suid_count:-0}

# Check for unauthorized listening ports (capture once, reuse below)
ss_output=$(ss -tlnp 2>/dev/null || echo "")
listening_ports=$(echo "$ss_output" | tail -n +2)
port_count=0

# Expected ports baseline — alert on anything not in this list
# Update this list when installing new services to avoid false-positive warnings.
# 22=SSH, 25=SMTP, 53=DNS(systemd-resolved), 80=HTTP, 443=HTTPS,
# 465=SMTPS, 587=STARTTLS, 993=IMAPS, 3000=Next.js,
# 3001=Grafana(local), 4317=OTEL-gRPC(local), 4318=OTEL-HTTP(local),
# 8889=OTEL-Prometheus-exporter(local), 9090=Prometheus(local)
# 6379=Redis(local), 8043=negotiate-listener(local), 11332-11334=Rspamd(local)
# Marvin-Brain stack (deployed 2026-05-25, all docker-proxy bound to 127.0.0.1):
#   3100=marvin-brain-mcp, 5432=marvin-brain-postgres(pgvector),
#   8000=marvin-brain-lightrag, 8787=marvin-brain-api
# Note: CUPS snap (port 631) disabled 2026-03-06 — not needed on a VPS
EXPECTED_PORTS="22 25 53 80 443 465 587 993 3000 3001 3100 4317 4318 5432 6379 8000 8043 8787 8889 9090 11332 11333 11334"

# Extract unique port numbers from listening sockets
active_ports=$(echo "$listening_ports" | awk '{print $4}' | grep -oP '\d+$' | sort -un)
# Count from deduplicated list to stay consistent with active_ports (avoids IPv4+IPv6 double-counting)
port_count=$(echo "$active_ports" | grep -c '[0-9]' 2>/dev/null || true)
port_count=${port_count:-0}
unexpected_ports=""
unexpected_count=0
unexpected_details_json="[]"

# Ports expected only on localhost — alert if bound to 0.0.0.0 or [::]
# Marvin-Brain ports (3100, 5432, 8000, 8787) all run via docker-proxy bound
# to 127.0.0.1; alert if anything escapes to a public interface.
# 8043 is the negotiate listener, reached only via the nginx reverse proxy
# (setup/nginx-site.conf -> http://127.0.0.1:8043). It was previously absent
# from this list — mislabelled "alt-HTTPS" in the baseline above — which is why
# its wildcard bind went unflagged from 2026-02-22 until 2026-07-26.
LOCALHOST_ONLY_PORTS="3001 3100 4317 4318 5432 6379 8000 8043 8787 8889 9090 11332 11333 11334"

for port in $active_ports; do
    if ! echo "$EXPECTED_PORTS" | grep -qw "$port"; then
        unexpected_ports="${unexpected_ports}${unexpected_ports:+, }${port}"
        unexpected_count=$((unexpected_count + 1))
        # Log the process listening on this unexpected port (reuse captured ss output)
        proc_info=$(echo "$ss_output" | grep ":${port} " | awk '{print $6}' | head -1)
        marvin_log "WARN" "Unexpected listener on port ${port}: ${proc_info}"
        # Accumulate details for JSON
        unexpected_details_json=$(echo "$unexpected_details_json" | jq --arg p "$port" --arg proc "$proc_info" '. + [{"port": ($p | tonumber), "process": $proc}]' 2>/dev/null || echo "$unexpected_details_json")
    fi
done

# Verify localhost-only ports are not bound to public interfaces
for port in $LOCALHOST_ONLY_PORTS; do
    if echo "$listening_ports" | grep -qP "(\*|0\.0\.0\.0|\[::\]):${port}\b"; then
        marvin_log "WARN" "Port ${port} expected localhost-only but bound to public interface"
    fi
done

if [[ "$unexpected_count" -gt 0 ]]; then
    marvin_log "WARN" "Found ${unexpected_count} unexpected listening port(s): ${unexpected_ports}"
fi

# Save port inventory for trending
PORT_INVENTORY="${SECURITY_DIR}/port-inventory.json"
port_list_json=$(echo "$active_ports" | jq -Rn '[inputs | select(. != "") | tonumber]' 2>/dev/null || echo "[]")
cat > "$PORT_INVENTORY" << PORTEOF
{
  "timestamp": "${NOW}",
  "total_ports": ${port_count},
  "unexpected_count": ${unexpected_count},
  "unexpected_ports": "${unexpected_ports}",
  "unexpected_port_details": ${unexpected_details_json},
  "expected_ports": "${EXPECTED_PORTS}",
  "active_ports": ${port_list_json}
}
PORTEOF
chmod 644 "$PORT_INVENTORY"
marvin_validate_json_or_warn "$PORT_INVENTORY" "port-inventory" || true

# ─── Shared: active Docker bridge subnet detection ───────────────────────────
# Used by BOTH the suspicious-connection check (3b) and the outbound audit (3d)
# so container↔container / docker-proxy↔container bridge traffic (e.g. the
# Marvin-Brain + monitoring stacks talking on 172.18/172.19 to ports like 4317
# OTEL-gRPC and 3100 marvin-brain-mcp) is not mislabeled as "unusual". Collected
# once per run. Only skips subnets Docker actually uses, not the whole 172.16/12
# range (fixes #591). Defined here (before 3b) rather than inside 3d so 3b can
# reuse it — otherwise 3b flags the exact bridge traffic 3d correctly ignores.
#
# MOVED (#882): _docker_bridges and _ip_in_docker_cidr now live in
# agent/lib/outbound.sh, sourced via common.sh, because the new 5-minute
# outbound sampler must use the SAME classifier as this scan. A second copy here
# would let sampler and aggregator drift on what counts as outbound, producing
# confidently wrong egress numbers — worse than no numbers at all.
#
# Still collected once per run: the probe inside the lib is lazy, so this call is
# what pays for it and every later _ip_in_docker_cidr hit is free.
marvin_outbound_bridges_init

# ─── 3b. Active connection tracking & suspicious connection detection ─────────
# Snapshot established connections and flag unusual destinations

marvin_log "INFO" "Tracking active network connections..."

established_output=$(ss -tnp state established 2>/dev/null || echo "")
established_count=0
suspicious_conns="[]"
suspicious_count=0

if [[ -n "$established_output" ]]; then
    established_count=$(echo "$established_output" | tail -n +2 | grep -c '[0-9]' 2>/dev/null || true)
    established_count=${established_count:-0}

    # Known safe destination ports: 80/443 (HTTP/S), 53 (DNS), 123 (NTP),
    # 587/465/25 (email sending), 22 (SSH from us)
    SAFE_REMOTE_PORTS="22 25 53 80 123 443 465 587"

    # Check each connection for unusual remote ports
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        remote_addr=$(echo "$line" | awk '{print $4}')
        remote_port=$(echo "$remote_addr" | grep -oP ':\K[0-9]+$' || echo "")
        remote_ip=$(echo "$remote_addr" | sed 's/:[0-9]*$//')
        local_addr=$(echo "$line" | awk '{print $3}')
        proc_info=$(echo "$line" | awk '{print $5}' | head -1)

        # Skip inbound connections (local port is a well-known service port)
        local_port=$(echo "$local_addr" | grep -oP ':\K[0-9]+$' || echo "")
        if echo "22 25 80 443 465 587 993 3000" | grep -qw "$local_port" 2>/dev/null; then
            continue
        fi

        # Skip loopback connections — internal service-to-service traffic
        # (e.g. rspamd ↔ redis on 127.0.0.1:6379) is not outbound in any
        # meaningful sense. Without this, localhost services generate daily
        # false-positive WARN noise about "unusual remote ports".
        if [[ "$remote_ip" == "127.0.0.1" || "$remote_ip" == "::1" ]] \
            || [[ "$remote_ip" =~ ^127\. ]]; then
            continue
        fi

        # Skip traffic to active Docker bridge subnets — container↔container and
        # docker-proxy↔container traffic (Marvin-Brain/monitoring stacks) is not
        # an outbound destination worth flagging. Mirrors the 3d outbound-audit
        # skip; without it, ports like 4317 (OTEL-gRPC) and 3100 (marvin-brain-mcp)
        # on 172.18/172.19 produce false-positive "unusual remote ports" WARNs.
        # The emptiness guard is gone: _ip_in_docker_cidr self-initialises and
        # returns 1 when no bridges exist (#882).
        if _ip_in_docker_cidr "$remote_ip"; then
            continue
        fi

        # Skip if remote port is in safe list
        if echo "$SAFE_REMOTE_PORTS" | grep -qw "$remote_port" 2>/dev/null; then
            continue
        fi

        # Flag outbound connections to unusual remote ports
        if [[ -n "$remote_port" ]]; then
            suspicious_conns=$(echo "$suspicious_conns" | jq \
                --arg rip "$remote_ip" --arg rport "$remote_port" \
                --arg local "$local_addr" --arg proc "$proc_info" \
                '. + [{"remote_ip": $rip, "remote_port": ($rport | tonumber), "local": $local, "process": $proc}]' \
                2>/dev/null || echo "$suspicious_conns")
        fi
    done < <(echo "$established_output" | tail -n +2)

    # Capture, then trim to first line via parameter expansion. Avoids the
    # `jq | head -n 1 || echo 0` pipefail+SIGPIPE trap (#621): when jq emits
    # multiple lines, head exits after line 1, jq gets SIGPIPE → exit 141, and
    # under `set -o pipefail` the `|| echo 0` fallback fires and silently
    # zeroes a real count. Parameter expansion avoids the pipe entirely.
    suspicious_count=$(echo "$suspicious_conns" | jq 'length' 2>/dev/null || echo 0)
    suspicious_count=${suspicious_count%%$'\n'*}
    [[ "$suspicious_count" =~ ^[0-9]+$ ]] || suspicious_count=0
    if [[ "$suspicious_count" -gt 0 ]]; then
        marvin_log "WARN" "Found ${suspicious_count} connection(s) to unusual remote ports"
    fi
fi

# Save connection snapshot
CONN_SNAPSHOT="${SECURITY_DIR}/connections-latest.json"
cat > "$CONN_SNAPSHOT" << CONNEOF
{
  "timestamp": "${NOW}",
  "established_count": ${established_count},
  "suspicious_connections": ${suspicious_conns}
}
CONNEOF
chmod 644 "$CONN_SNAPSHOT"

marvin_log "INFO" "Connection tracking: ${established_count} established, $(echo "$suspicious_conns" | jq 'length' 2>/dev/null || echo 0) suspicious"

# ─── 3c. Connection rate monitoring by source IP ─────────────────────────────
# Analyze inbound connections to identify top source IPs and flag those with
# unusually high connection counts (possible DDoS, brute force, or scraping).

marvin_log "INFO" "Analyzing connection rates by source IP..."

top_sources_json="[]"
high_rate_count=0
HIGH_CONN_THRESHOLD=50  # Flag IPs with more than 50 concurrent connections

# Count inbound connections per source IP (filter to service ports only)
# Use established state; match only connections to known local service ports
# to exclude outbound connections (fixes #258). Exclude loopback IPs (fixes #259).
all_conns_output=$(ss -tn state established 2>/dev/null || echo "")
if [[ -n "$all_conns_output" ]]; then
    # Extract peer IPs only where local side is a known service port
    # $4=Local Address:Port, $5=Peer Address:Port
    # Capture-then-fallback: under `set -o pipefail`, when grep matches nothing
    # the pipeline exits 1 *after* `jq -s '.'` has already written `[]` to
    # stdout. The old `pipeline ... || echo "[]"` shape then appended a second
    # `[]`, so the captured value was `"[]\n[]"` — which got spliced into
    # connection-rates.json as invalid JSON ("Expected separator between
    # values"), corrupting the dashboard data file. Same root-cause family as
    # the 2026-05-08 log-analysis _process_level fix and the broader
    # `grep-c-double-output` lesson. Keep jq's stdout, swallow only the exit.
    top_sources_json=$(echo "$all_conns_output" | tail -n +2 \
        | awk '$4 ~ /:(80|443|22|25|587|8080|3000)$/ {print $5}' \
        | grep -oP '^\d+\.\d+\.\d+\.\d+' \
        | grep -v '^127\.' \
        | grep -v '^0\.' \
        | sort | uniq -c | sort -rn | head -20 \
        | awk '{printf "{\"ip\":\"%s\",\"connections\":%d}\n", $2, $1}' \
        | jq -s '.' 2>/dev/null) || true
    top_sources_json=${top_sources_json:-"[]"}

    # Flag IPs exceeding the threshold
    # See suspicious_count above for the SIGPIPE+pipefail rationale (#621).
    high_rate_count=$(echo "$top_sources_json" | jq --argjson thr "$HIGH_CONN_THRESHOLD" \
        '[.[] | select(.connections > $thr)] | length' 2>/dev/null || echo 0)
    high_rate_count=${high_rate_count%%$'\n'*}
    [[ "$high_rate_count" =~ ^[0-9]+$ ]] || high_rate_count=0

    if [[ "$high_rate_count" -gt 0 ]]; then
        _flagged_ips=$(echo "$top_sources_json" | jq -r --argjson thr "$HIGH_CONN_THRESHOLD" \
            '.[] | select(.connections > $thr) | "\(.ip) (\(.connections) conns)"' 2>/dev/null | paste -sd', ' -)
        marvin_log "WARN" "High connection rate from ${high_rate_count} IP(s): ${_flagged_ips}"
    fi
fi

# Save connection rate data
RATE_FILE="${SECURITY_DIR}/connection-rates.json"
cat > "$RATE_FILE" << RATEEOF
{
  "timestamp": "${NOW}",
  "high_rate_threshold": ${HIGH_CONN_THRESHOLD},
  "high_rate_ips": ${high_rate_count},
  "top_sources": ${top_sources_json}
}
RATEEOF
marvin_validate_json_or_warn "$RATE_FILE" "connection-rates" || true
chmod 644 "$RATE_FILE"

marvin_log "INFO" "Connection rate analysis: ${high_rate_count} high-rate IP(s) above ${HIGH_CONN_THRESHOLD} conns"

# ─── 3d. Outbound connection auditing ────────────────────────────────────────
# Track what this server connects to externally. Provides visibility into
# outbound traffic: package managers, DNS, NTP, email relays, GitHub API, etc.
# Flags unexpected outbound destinations that could indicate compromise.
#
# REWRITTEN (#882). This section used to BE the whole control: one instantaneous
# `ss` at 04:00 local — the deadest minute on this box — written out as the day's
# answer. It reported zero outbound connections on 30 of 31 retained scans. The
# filters were never wrong; it just never looked. On 2026-07-26, 704 MB left this
# interface (19.5σ over a 21-day mean) and this control had no record of it and
# never could have.
#
# Now: the 5-minute health-monitor tick records samples (agent/lib/outbound.sh),
# and this section AGGREGATES them. The instantaneous sample is retained — it is
# still a real observation and other consumers read those fields — but it is one
# of 288, not the answer.
#
# The two claims are reported separately and never merged:
#   - what was observed (destinations, processes, unexpected ports)
#   - whether the sampler actually looked (coverage_status)
# A day with no samples reports "absent" and raises a warning. It does NOT report
# zero connections. That distinction is the entire fix.

marvin_log "INFO" "Auditing outbound connections..."

outbound_conns_json="[]"
outbound_count=0
outbound_unexpected=0
outbound_unexpected_json="[]"

# Port lists + classification live in agent/lib/outbound.sh so the sampler and
# this aggregator cannot disagree about what "outbound" means.
SAFE_OUTBOUND_PORTS="$MARVIN_SAFE_OUTBOUND_PORTS"

# ── Instantaneous sample (one data point, no longer the verdict) ──
outbound_output=$(ss -tnp state established 2>/dev/null || echo "")

if [[ -n "$outbound_output" ]]; then
    while IFS=$'\t' read -r remote_ip remote_port local_port proc_name; do
        [[ -z "$remote_ip" ]] && continue
        outbound_count=$((outbound_count + 1))

        outbound_conns_json=$(echo "$outbound_conns_json" | jq \
            --arg rip "$remote_ip" --arg rport "$remote_port" \
            --arg lport "$local_port" --arg proc "$proc_name" \
            '. + [{"remote_ip": $rip, "remote_port": ($rport | tonumber), "local_port": ($lport | tonumber), "process": $proc}]' \
            2>/dev/null || echo "$outbound_conns_json")

        if ! echo "$SAFE_OUTBOUND_PORTS" | grep -qw "$remote_port" 2>/dev/null; then
            outbound_unexpected=$((outbound_unexpected + 1))
            outbound_unexpected_json=$(echo "$outbound_unexpected_json" | jq \
                --arg rip "$remote_ip" --arg rport "$remote_port" \
                --arg proc "$proc_name" \
                '. + [{"remote_ip": $rip, "remote_port": ($rport | tonumber), "process": $proc}]' \
                2>/dev/null || echo "$outbound_unexpected_json")
            marvin_log "WARN" "Unexpected outbound: ${proc_name} → ${remote_ip}:${remote_port}"
        fi
    done < <(marvin_outbound_classify <<< "$outbound_output")

    if [[ "$outbound_unexpected" -gt 0 ]]; then
        marvin_log "WARN" "Found ${outbound_unexpected} outbound connection(s) to unusual ports"
    fi
fi

# Summarize outbound by destination port for trending
outbound_by_port="[]"
if [[ "$outbound_count" -gt 0 ]]; then
    outbound_by_port=$(echo "$outbound_conns_json" | jq '
        group_by(.remote_port) |
        map({port: .[0].remote_port, count: length, processes: [.[].process] | unique}) |
        sort_by(-.count)
    ' 2>/dev/null || echo "[]")
fi

# ── Day aggregate over the retained 5-minute samples ──
# Aggregates YESTERDAY (UTC): this scan runs at 02:00 UTC, so yesterday is the
# only complete 288-sample window available. Today's partial day is summarised
# separately for continuity rather than being compared against a 288 expectation
# it cannot possibly meet at 02:00.
OUTBOUND_AUDIT_DAY=$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null || echo "$TODAY")
outbound_day_json=$(marvin_outbound_day_summary "$OUTBOUND_AUDIT_DAY" \
    "$MARVIN_OUTBOUND_SAMPLES_PER_DAY")

# Partial day-so-far: expected = elapsed 5-minute ticks since 00:00 UTC.
#
# Derived from a single epoch reading, NOT from `$(date +%H) * 60 + $(date +%M)`
# (#886). Two independent reasons, and the first one crashes:
#
#   1. Zero-padding is octal. `date -u +%H` yields `08`/`09` and bash reads a
#      leading-zero literal as octal, where those are not valid digits:
#      `bash: 08: value too great for base`. Under this file's `set -euo
#      pipefail` + ERR trap that aborts the ENTIRE daily security scan, not just
#      this section. The review that caught it judged the scheduled 02:00 run
#      safe because minute `00` is valid octal — but §3d does not run at 02:00.
#      rkhunter takes ~4m16s, so this line executes at **02:04** (02:04:17–02:04:21
#      across 2026-07-22/24/26). The production run is four minutes of rkhunter
#      drift away from aborting the whole scan, which makes this a live fault
#      rather than an ad-hoc-invocation-only one.
#   2. Two `date` calls can straddle a minute boundary: read `%H` at 02:59:59.99
#      and `%M` in the next millisecond and you get hour 2 with minute 0 — 120
#      instead of 180. Rare, silent, and wrong rather than loud.
#
# `%s % 86400` is immune to both: one reading, no padded fields, no parsing.
# `_today_expected` is only ever a sample-count expectation, so integer minutes
# are all it needs.
_elapsed_min=$(( ($(date -u +%s) % 86400) / 60 ))
_today_expected=$(( _elapsed_min / 5 ))
[[ "$_today_expected" -lt 1 ]] && _today_expected=1
outbound_today_json=$(marvin_outbound_day_summary "$TODAY" "$_today_expected")

outbound_coverage_status=$(jq -r '.coverage_status' <<< "$outbound_day_json" 2>/dev/null || echo "unknown")
outbound_coverage_pct=$(jq -r '.coverage_percent' <<< "$outbound_day_json" 2>/dev/null || echo "0")
outbound_day_samples=$(jq -r '.samples_recorded' <<< "$outbound_day_json" 2>/dev/null || echo "0")
outbound_day_failed=$(jq -r '.samples_failed' <<< "$outbound_day_json" 2>/dev/null || echo "0")
outbound_day_unexpected=$(jq -r '.unexpected_destinations | length' <<< "$outbound_day_json" 2>/dev/null || echo "0")
outbound_day_distinct=$(jq -r '.distinct_destinations // 0' <<< "$outbound_day_json" 2>/dev/null || echo "0")
outbound_day_peak=$(jq -r '.peak_concurrent // 0' <<< "$outbound_day_json" 2>/dev/null || echo "0")

# Coverage is a first-class finding. "The sampler did not run" must never render
# as "nothing left the box" — that equivalence is what made this control useless
# for 30 days, and it is the same defect as a firewall audit that reads an absent
# firewall as verified-clean (#881).
case "$outbound_coverage_status" in
    absent)
        marvin_log "WARN" "Outbound audit: NO samples retained for ${OUTBOUND_AUDIT_DAY} — egress for that day is UNKNOWN, not clean. Is health-monitor.sh running?"
        ;;
    degraded)
        marvin_log "WARN" "Outbound audit: only ${outbound_day_samples}/${MARVIN_OUTBOUND_SAMPLES_PER_DAY} samples (${outbound_coverage_pct}%) for ${OUTBOUND_AUDIT_DAY} — too sparse to attribute egress"
        ;;
    aggregate-failed)
        marvin_log "WARN" "Outbound audit: sample aggregation FAILED for ${OUTBOUND_AUDIT_DAY} — treat as no data"
        ;;
    ok)
        marvin_log "INFO" "Outbound audit: ${outbound_day_samples} samples (${outbound_coverage_pct}%) for ${OUTBOUND_AUDIT_DAY}, ${outbound_day_distinct} distinct destination(s), peak ${outbound_day_peak} concurrent"
        ;;
esac

if [[ "$outbound_day_failed" -gt 0 ]] 2>/dev/null; then
    marvin_log "WARN" "Outbound audit: ${outbound_day_failed} sample(s) on ${OUTBOUND_AUDIT_DAY} recorded an error — gaps in the egress history"
fi

if [[ "$outbound_day_unexpected" -gt 0 ]] 2>/dev/null; then
    marvin_log "WARN" "Outbound audit: ${outbound_day_unexpected} unexpected destination(s) across ${OUTBOUND_AUDIT_DAY}"
fi

# Save outbound audit
OUTBOUND_FILE="${SECURITY_DIR}/outbound-audit.json"
# Written to a temp file, restricted, then mv'd into place — NOT `cat >` on the
# destination followed by chmod (#885). Two reasons, both real here:
#
#   1. Permissions. `cat >` creates a missing file at the process umask (644 for
#      root) and preserves the existing mode on a file that is already 644 — so
#      the destination holds the new egress history world-readable until the
#      chmod lands. Everything under data/ is HTTP-reachable until the /api/
#      allowlist (#861) lands, so that window is genuinely reachable. Restrict
#      first, rename second — the same ordering #636 established in
#      file-integrity.sh, for the same reason.
#   2. Atomicity. `cat >` truncates before it writes, so a reader arriving
#      mid-write gets a partial document. mv on the same filesystem is atomic.
#
# 640, not the 644 the rest of data/security/ uses: this is a record of every
# destination this host contacted, and that is not something to publish.
_ob_tmp=$(mktemp "${OUTBOUND_FILE}.XXXXXX")
chmod 640 "$_ob_tmp"
cat > "$_ob_tmp" << OUTEOF
{
  "timestamp": "${NOW}",
  "outbound_total": ${outbound_count},
  "outbound_unexpected": ${outbound_unexpected},
  "unexpected_connections": ${outbound_unexpected_json},
  "by_port": ${outbound_by_port},
  "all_connections": ${outbound_conns_json},
  "sampling_note": "outbound_total/outbound_unexpected above are ONE instantaneous sample taken at scan time. Use day_aggregate for the actual day; check its coverage_status before believing any count.",
  "day_aggregate": ${outbound_day_json},
  "today_partial": ${outbound_today_json}
}
OUTEOF
# Validate BEFORE publishing: a malformed document must not replace a good one.
if jq -e . "$_ob_tmp" >/dev/null 2>&1; then
    mv -f "$_ob_tmp" "$OUTBOUND_FILE"
    # Tighten a destination left at 644 by an older version of this code; the
    # mv above already carries 640 for a newly-created file.
    chmod 640 "$OUTBOUND_FILE"
else
    rm -f "$_ob_tmp"
    marvin_log "WARN" "Outbound audit: generated document is not valid JSON — previous outbound-audit.json preserved"
fi
marvin_validate_json_or_warn "$OUTBOUND_FILE" "outbound-audit" || true

marvin_log "INFO" "Outbound audit: instantaneous sample ${outbound_count} connections, ${outbound_unexpected} to unusual ports; ${OUTBOUND_AUDIT_DAY} coverage ${outbound_coverage_status}"

# ─── 3e. Geographic analysis of incoming connections ──────────────────────────
# Uses geoiplookup (local GeoIP database) to map visitor IPs to countries.
# Data sources: nginx access logs, top connecting IPs (3c), fail2ban banned IPs.
# Fast — no network calls, all local lookups.

marvin_log "INFO" "Running geographic analysis of incoming connections..."

geo_data="[]"
geo_country_count=0
geo_total_ips=0
geo_available=false
geo_top_country="Unknown"

if command -v geoiplookup &>/dev/null; then
    geo_available=true
    # Collect unique public IPs from three sources (streamed — no large in-memory buffering)
    unique_ips=$(
        {
            # Source 1: nginx access logs (current + rotated, capped at 50k lines each)
            for logfile in /var/log/nginx/access.log /var/log/nginx/access.log.1; do
                [[ -f "$logfile" ]] && tail -n 50000 "$logfile" 2>/dev/null | awk '{print $1}' || true
            done
            # Source 2: top connecting IPs from section 3c
            echo "${top_sources_json}" | jq -r '.[].ip' 2>/dev/null || true
            # Source 3: fail2ban banned IPs (all active jails)
            for _jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g' || true); do
                fail2ban-client status "$_jail" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' || true
            done
        } | sort -u \
          | grep -Ev '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.|::1|0\.0\.0\.0|$)' || true
    )
    geo_total_ips=$(echo "$unique_ips" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' 2>/dev/null || true)
    geo_total_ips=${geo_total_ips:-0}

    if [[ "$geo_total_ips" -gt 0 ]]; then
        # Lookup each IP (cap at 500 to bound runtime), extract "CC, Country Name"
        geo_raw=$(echo "$unique_ips" | head -500 | while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            result=$(geoiplookup "$ip" 2>/dev/null | head -1)
            if echo "$result" | grep -q "not found"; then
                echo "XX Unknown"
            else
                # Output: "CC Country Name" (strip "GeoIP Country Edition: CC, Name" → "CC Name")
                echo "$result" | sed 's/^[^:]*: //' | sed 's/,/ /'
            fi
        done | sort | uniq -c | sort -rn | head -20)

        # Convert to JSON array (jq handles all escaping — no manual JSON in awk)
        # Same capture-then-fallback shape as top_sources_json above —
        # jq -n with `[inputs | ...]` writes `[]` even on empty input, so
        # `pipeline ... || echo "[]"` would double up on any pipefail.
        geo_data=$(echo "$geo_raw" | awk '
            NF >= 3 {
                count = $1; code = $2;
                name = "";
                for (i = 3; i <= NF; i++) name = name (i>3 ? " " : "") $i;
                printf "%s\t%s\t%d\n", code, name, count
            }' | jq -Rn --arg total "$geo_total_ips" '[inputs | split("\t") | {code: .[0], name: .[1], country: .[1], count: (.[2] | tonumber), unique_ips: (.[2] | tonumber), percent: (if ($total | tonumber) > 0 then ((.[2] | tonumber) * 100 / ($total | tonumber) * 10 | round / 10) else 0 end)}]' 2>/dev/null) || true
        geo_data=${geo_data:-"[]"}

        geo_country_count=$(echo "$geo_data" | jq 'length' 2>/dev/null || echo 0)
        geo_top_country=$(echo "$geo_data" | jq -r '.[0].country // "Unknown"' 2>/dev/null || echo "Unknown")
        marvin_log "INFO" "Top origin: $(echo "$geo_data" | jq -r '.[0] | "\(.country) (\(.unique_ips) IPs)"' 2>/dev/null || echo 'N/A')"
    fi
else
    marvin_log "WARN" "geoiplookup not available — skipping geographic analysis"
fi

# Save geographic analysis report
GEO_FILE="${SECURITY_DIR}/connection-geo.json"
cat > "$GEO_FILE" << GEOEOF
{
  "timestamp": "${NOW}",
  "geo_available": ${geo_available},
  "total_unique_ips": ${geo_total_ips},
  "country_count": ${geo_country_count},
  "top_country": $(printf '%s' "$geo_top_country" | jq -Rs '.' 2>/dev/null || echo '"Unknown"'),
  "countries": ${geo_data}
}
GEOEOF
chmod 644 "$GEO_FILE"
marvin_validate_json_or_warn "$GEO_FILE" "connection-geo" || true

marvin_log "INFO" "Geographic analysis: ${geo_total_ips} unique IPs from ${geo_country_count} countries"

# ─── 4. File integrity monitoring ─────────────────────────────────────────────

FIM_SCRIPT="$(dirname "$0")/file-integrity.sh"
fim_status="skipped"
fim_changes=0
fim_missing=0

if [[ -x "$FIM_SCRIPT" ]]; then
    marvin_log "INFO" "Running file integrity check..."
    "$FIM_SCRIPT" 2>&1 || true

    FIM_REPORT="${SECURITY_DIR}/file-integrity-latest.json"
    if [[ -f "$FIM_REPORT" ]]; then
        fim_status=$(jq -r '.status // "unknown"' "$FIM_REPORT" 2>/dev/null || echo "unknown")
        fim_changes=$(jq '.changes | length' "$FIM_REPORT" 2>/dev/null || echo 0)
        fim_missing=$(jq '.missing_files | length' "$FIM_REPORT" 2>/dev/null || echo 0)

        if [[ "$fim_status" == "alert" ]]; then
            marvin_log "WARN" "File integrity alert: ${fim_changes} changed, ${fim_missing} missing"
        else
            marvin_log "INFO" "File integrity: ${fim_status}"
        fi
    fi
else
    marvin_log "WARN" "file-integrity.sh not found — skipping"
fi

# ─── 5. CVE / package vulnerability monitoring ──────────────────────────────

marvin_log "INFO" "Checking for security-relevant package updates..."

# Refresh package lists (quiet, non-interactive)
apt-get update -qq 2>/dev/null || true

# Check for upgradable packages and identify security updates
upgradable_all=0
upgradable_security=0
upgradable_security_phased=0
upgradable_security_actionable=0
upgradable_list=""
security_list=""

if upgradable_raw=$(apt list --upgradable 2>/dev/null | tail -n +2); then
    upgradable_all=$(echo "$upgradable_raw" | grep -c '[a-z]' || true)
    # Security updates come from *-security repositories
    security_raw=$(echo "$upgradable_raw" | grep -i 'security' 2>/dev/null || echo "")
    if [[ -n "$security_raw" ]]; then
        upgradable_security=$(echo "$security_raw" | wc -l | tr -d ' ')
        security_list=$(echo "$security_raw" | head -20)

        # Distinguish phased-deferred security updates from genuinely actionable
        # ones. Ubuntu rolls a security update out to a fraction of machines at a
        # time ("phasing"); unattended-upgrades correctly holds a phased update
        # back until this host's phase is reached, then applies it automatically.
        # A NON-phased security update still pending is a different, real signal
        # (unattended-upgrades failing, a dependency-blocked package, a manual
        # hold). Both previously collapsed into one daily WARN, so a genuinely
        # stuck update was indistinguishable from routine, self-healing phasing.
        # Fail-safe: any parse failure leaves the phased set empty, so every
        # pending security update counts as actionable — this can never hide one.
        _phased_pkgs=$(apt-get -s upgrade 2>/dev/null | awk '/^The following upgrades have been deferred due to phasing:/{f=1;next} /^[^ ]/{f=0} f{for(i=1;i<=NF;i++)print $i}' || true)
        while IFS= read -r _sec_line; do
            [[ -z "$_sec_line" ]] && continue
            _sec_pkg="${_sec_line%%/*}"   # "pkg/repo ver arch [..]" → "pkg"
            if [[ -n "$_phased_pkgs" ]] && grep -qxF "$_sec_pkg" <<< "$_phased_pkgs"; then
                upgradable_security_phased=$((upgradable_security_phased + 1))
            else
                upgradable_security_actionable=$((upgradable_security_actionable + 1))
            fi
        done <<< "$security_raw"

        if [[ "$upgradable_security_actionable" -gt 0 ]]; then
            marvin_log "WARN" "Found ${upgradable_security} pending security update(s): ${upgradable_security_actionable} actionable, ${upgradable_security_phased} phased-deferred by Ubuntu"
        else
            marvin_log "INFO" "Found ${upgradable_security} pending security update(s), all ${upgradable_security_phased} phased-deferred by Ubuntu (will auto-apply)"
        fi
    fi
    upgradable_list=$(echo "$upgradable_raw" | head -30)
fi

# Check for packages with known CVEs using ubuntu-security-status (if available)
esm_infra=0
esm_apps=0
cve_status="unknown"
if command -v ubuntu-security-status &>/dev/null; then
    uss_output=$(ubuntu-security-status 2>/dev/null || echo "")
    esm_infra=$(echo "$uss_output" | grep -oP '\d+(?= packages from Ubuntu Main)' 2>/dev/null || echo 0)
    esm_apps=$(echo "$uss_output" | grep -oP '\d+(?= packages from Ubuntu Universe)' 2>/dev/null || echo 0)
    cve_status="checked"
fi

# Parse recent unattended-upgrades activity (all-time from current log)
auto_patched=0
if [[ -f /var/log/unattended-upgrades/unattended-upgrades.log ]]; then
    auto_patched=$(grep -c "Packages that will be upgraded" \
        /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null || true)
    # Ensure numeric value (grep -c may return empty on error)
    auto_patched=${auto_patched:-0}
fi

# Write CVE report
CVE_REPORT="${SECURITY_DIR}/cve-status.json"
cat > "$CVE_REPORT" << CVEEOF
{
  "timestamp": "${NOW}",
  "upgradable_total": ${upgradable_all},
  "upgradable_security": ${upgradable_security},
  "upgradable_security_phased": ${upgradable_security_phased},
  "upgradable_security_actionable": ${upgradable_security_actionable},
  "security_packages": $(echo "$security_list" | jq -R -s 'split("\n") | map(select(. != ""))' 2>/dev/null || echo "[]"),
  "all_upgradable": $(echo "$upgradable_list" | jq -R -s 'split("\n") | map(select(. != ""))' 2>/dev/null || echo "[]"),
  "auto_patches_applied": ${auto_patched},
  "esm_main_packages": ${esm_infra},
  "esm_universe_packages": ${esm_apps},
  "cve_check_status": "${cve_status}"
}
CVEEOF
chmod 644 "$CVE_REPORT"

marvin_log "INFO" "CVE status: ${upgradable_all} upgradable (${upgradable_security} security), ${auto_patched} auto-patched"

# ─── 6. Generate report ─────────────────────────────────────────────────────

# Determine overall status
# Note: gate on actionable (not total) pending security updates so an all-phased
# day does not log "all N phased-deferred (will auto-apply)" and then contradict
# itself with "Overall status: warnings". On any parse failure the classifier
# leaves actionable == total, so this stays fail-safe (still warns).
overall_status="clean"
if [[ "$rkhunter_status" == "infected" || "$chkrootkit_status" == "infected" ]]; then
    overall_status="infected"
elif [[ "$fim_status" == "alert" ]]; then
    overall_status="alert"
elif [[ "$rkhunter_status" == "warnings" || "$world_writable_count" -gt 0 || "$upgradable_security_actionable" -gt 0 || "$unexpected_count" -gt 0 || "$suspicious_count" -gt 0 || "$high_rate_count" -gt 0 || "$outbound_unexpected" -gt 0 || "$outbound_day_unexpected" -gt 0 ]]; then
    overall_status="warnings"
# A control that could not look must not be scored as a control that looked and
# found nothing (#882, same defect class as #881). Absent/degraded/failed egress
# coverage is itself a warning: it means this scan cannot speak to what left the
# box, and 30 consecutive days of exactly that went unnoticed because it scored
# "clean" every time.
elif [[ "$outbound_coverage_status" != "ok" ]]; then
    overall_status="warnings"
fi

cat > "$REPORT_FILE" << EOF
{
  "timestamp": "${NOW}",
  "overall_status": "${overall_status}",
  "rkhunter": {
    "status": "${rkhunter_status}",
    "warnings": ${rkhunter_warnings},
    "infected": ${rkhunter_infected},
    "summary": $(echo "$rkhunter_summary" | jq -Rs '.' 2>/dev/null || echo '""')
  },
  "chkrootkit": {
    "status": "${chkrootkit_status}",
    "infected": ${chkrootkit_infected},
    "summary": $(echo "$chkrootkit_summary" | jq -Rs '.' 2>/dev/null || echo '""')
  },
  "file_integrity": {
    "status": "${fim_status}",
    "changes": ${fim_changes},
    "missing": ${fim_missing},
    "world_writable_count": ${world_writable_count},
    "suid_sgid_count": ${suid_count}
  },
  "cve_monitoring": {
    "upgradable_total": ${upgradable_all},
    "upgradable_security": ${upgradable_security},
    "upgradable_security_phased": ${upgradable_security_phased},
    "upgradable_security_actionable": ${upgradable_security_actionable},
    "auto_patches_applied": ${auto_patched}
  },
  "network": {
    "listening_ports": ${port_count},
    "unexpected_ports": ${unexpected_count},
    "unexpected_port_list": "${unexpected_ports}",
    "unexpected_port_details": ${unexpected_details_json},
    "established_connections": ${established_count},
    "suspicious_connections": $(echo "$suspicious_conns" | jq 'length' 2>/dev/null || echo 0),
    "high_rate_ips": ${high_rate_count},
    "high_rate_threshold": ${HIGH_CONN_THRESHOLD},
    "outbound_total": ${outbound_count},
    "outbound_unexpected": ${outbound_unexpected},
    "outbound_sample_scope": "instantaneous",
    "outbound_day": "${OUTBOUND_AUDIT_DAY}",
    "outbound_day_coverage_status": "${outbound_coverage_status}",
    "outbound_day_coverage_percent": ${outbound_coverage_pct},
    "outbound_day_samples": ${outbound_day_samples},
    "outbound_day_samples_failed": ${outbound_day_failed},
    "outbound_day_distinct_destinations": ${outbound_day_distinct},
    "outbound_day_peak_concurrent": ${outbound_day_peak},
    "outbound_day_unexpected": ${outbound_day_unexpected},
    "geo_available": ${geo_available},
    "geo_unique_ips": ${geo_total_ips},
    "geo_countries": ${geo_country_count},
    "geo_top_country": $(printf '%s' "$geo_top_country" | jq -Rs '.' 2>/dev/null || echo '"Unknown"')
  }
}
EOF

# Validate the daily report before propagating to latest-scan.json — a
# corrupt scan-${TODAY}.json silently propagated as latest-scan.json was
# the root cause of the 2026-05-01 self-test crash (see lessons-learned).
marvin_validate_json_or_warn "$REPORT_FILE" "scan-daily" || true

# Also maintain a latest scan pointer for the dashboard
cp "$REPORT_FILE" "${SECURITY_DIR}/latest-scan.json"
chmod 644 "${SECURITY_DIR}/latest-scan.json"
marvin_validate_json_or_warn "${SECURITY_DIR}/latest-scan.json" "scan-latest" || true

# ─── 7. Alert escalation for critical findings ──────────────────────────────

ROOTKIT_ALERT_SENTINEL="${SECURITY_DIR}/rootkit-alert-issued"

if [[ "$overall_status" == "infected" ]]; then
    marvin_log "CRITICAL" "Rootkit infection detected — escalating via GitHub issue"
    if [[ -f "$ROOTKIT_ALERT_SENTINEL" ]]; then
        marvin_log "WARN" "Rootkit alert already issued (sentinel: ${ROOTKIT_ALERT_SENTINEL}) — skipping duplicate GitHub issue"
    else
        alert_body=$(cat <<ALERTEOF
## Automated Security Alert

**Scan date:** ${NOW}
**rkhunter:** ${rkhunter_status} (${rkhunter_infected} infected)
**chkrootkit:** ${chkrootkit_status} (${chkrootkit_infected} infected)

### Findings

$(if [[ -n "$rkhunter_summary" ]]; then echo "**rkhunter:**"; echo '```'; echo "$rkhunter_summary"; echo '```'; fi)
$(if [[ -n "$chkrootkit_summary" ]]; then echo "**chkrootkit:**"; echo '```'; echo "$chkrootkit_summary"; echo '```'; fi)

This server may be compromised. **Manual investigation is required.**
Full report: \`${REPORT_FILE}\`
ALERTEOF
        )
        alert_title="CRITICAL: Rootkit infection detected — ${TODAY}"
        if github_create_issue "$alert_title" "$alert_body" "security" || \
           github_create_issue "$alert_title" "$alert_body"; then
            echo "${NOW}" > "$ROOTKIT_ALERT_SENTINEL"
            marvin_log "INFO" "Rootkit alert issue created — sentinel written to prevent duplicates"
        else
            marvin_log "ERROR" "Failed to create GitHub issue for rootkit alert"
        fi
    fi
elif [[ -f "$ROOTKIT_ALERT_SENTINEL" ]]; then
    marvin_log "INFO" "Previous rootkit alert cleared — scan is clean, removing sentinel"
    rm -f "$ROOTKIT_ALERT_SENTINEL"
fi

# Clean up old scan reports (keep 30 days)
find "$SECURITY_DIR" -name 'scan-*.json' -mtime +30 -delete 2>/dev/null || true

marvin_log "INFO" "Security scan report: ${REPORT_FILE}"
marvin_log "INFO" "Overall status: ${overall_status} (rkhunter: ${rkhunter_status}, chkrootkit: ${chkrootkit_status})"
marvin_log "INFO" "=== DAILY SECURITY SCAN COMPLETE ==="
