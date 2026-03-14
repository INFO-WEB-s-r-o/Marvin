#!/usr/bin/env bash
# =============================================================================
# Marvin — Health Monitor (runs every 5 minutes)
# =============================================================================
# Lightweight: collects metrics, checks services, updates status.
# Does NOT invoke Claude (too expensive for every 5 min).
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

marvin_log "INFO" "Health monitor starting"

# Collect and store metrics
metrics=$(collect_metrics)
append_metrics "$metrics"

# Quick health checks
ISSUES=()

# ─── Anomaly detection (compare current vs 7-day rolling average) ────────────
# Uses daily summaries from metric-aggregate.sh to detect unusual metric values.
# Alerts when a metric deviates by more than 2 standard deviations from the mean.

# Anomaly deduplication: only alert once per metric per hour
_ANOMALY_ALERT_FILE="${METRICS_DIR}/anomaly-last-alert.json"
[[ -f "$_ANOMALY_ALERT_FILE" ]] || echo '{}' > "$_ANOMALY_ALERT_FILE"
_ANOMALY_DETAILS=()

_anomaly_check() {
    local label="$1" current="$2" avg="$3" stddev="$4"
    # $5 = direction: "high" (only alert above avg), "both" (default)
    # $6 = min_threshold: minimum absolute value before alerting (e.g., CPU must be >50)
    local direction="${5:-both}" min_threshold="${6:-0}"
    local is_anomaly=false deviation="0"

    # Skip if current is below the minimum absolute threshold
    # e.g., CPU=4% is never concerning regardless of deviation from average
    if awk -v cur="$current" -v thr="$min_threshold" 'BEGIN{exit (cur < thr) ? 0 : 1}' 2>/dev/null; then
        return
    fi

    # When stddev is too small (< 1), use absolute percentage deviation instead
    # This prevents masking large deviations on normally-stable metrics (#153)
    if awk -v sd="$stddev" 'BEGIN{exit (sd < 1) ? 0 : 1}' 2>/dev/null; then
        # Fallback: flag if current deviates >20% from mean (and mean is non-trivial)
        local pct_dev raw_dev
        raw_dev=$(awk -v cur="$current" -v mean="$avg" \
            'BEGIN{if(mean==0){printf "0"}else{printf "%.1f", (cur-mean)/mean*100}}' 2>/dev/null || echo "0")
        pct_dev=$(awk -v d="$raw_dev" 'BEGIN{if(d<0)d=-d; printf "%.1f", d}' 2>/dev/null || echo "0")
        # Direction filter: skip negative deviations when direction=high
        if [[ "$direction" == "high" ]] && awk -v d="$raw_dev" 'BEGIN{exit (d < 0) ? 0 : 1}' 2>/dev/null; then
            return
        fi
        if awk -v pd="$pct_dev" 'BEGIN{exit (pd > 20.0) ? 0 : 1}' 2>/dev/null; then
            deviation="${pct_dev}%"
            is_anomaly=true
        fi
    else
        deviation=$(awk -v cur="$current" -v mean="$avg" -v sd="$stddev" \
            'BEGIN{printf "%.1f", (cur - mean) / sd}' 2>/dev/null || echo "0")
        # Direction filter: skip negative deviations when direction=high
        if [[ "$direction" == "high" ]] && awk -v d="$deviation" 'BEGIN{exit (d < 0) ? 0 : 1}' 2>/dev/null; then
            return
        fi
        local abs_dev
        abs_dev=$(awk -v d="$deviation" 'BEGIN{if(d<0) d=-d; printf "%.1f", d}' 2>/dev/null || echo "0")
        if awk -v ad="$abs_dev" 'BEGIN{exit (ad > 2.0) ? 0 : 1}' 2>/dev/null; then
            deviation="${deviation}σ"
            is_anomaly=true
        fi
    fi

    if [[ "$is_anomaly" == "true" ]]; then
        _ANOMALY_DETAILS+=("{\"metric\":\"${label}\",\"current\":${current},\"avg\":${avg},\"deviation\":\"${deviation}\"}")

        # Rate limit: only log/alert if not alerted for this metric in the last 60 min (#152)
        local last_alert now_ts
        now_ts=$(date +%s)
        last_alert=$(jq -r --arg m "$label" '.[$m] // 0' "$_ANOMALY_ALERT_FILE" 2>/dev/null || echo 0)
        local elapsed=$(( now_ts - last_alert ))

        if [[ "$elapsed" -ge 3600 ]]; then
            ISSUES+=("WARNING: ${label} anomaly — current ${current}, avg ${avg}, ${deviation} deviation")
            marvin_log "WARN" "Anomaly: ${label} = ${current} (avg=${avg}, stddev=${stddev}, deviation=${deviation})"
            # Update last alert timestamp
            jq --arg m "$label" --argjson ts "$now_ts" '.[$m] = $ts' "$_ANOMALY_ALERT_FILE" \
                > "${_ANOMALY_ALERT_FILE}.tmp" && mv "${_ANOMALY_ALERT_FILE}.tmp" "$_ANOMALY_ALERT_FILE"
        fi
    fi
}

# Collect daily summary values from the last 7 days
_daily_files=()
for i in $(seq 1 7); do
    _d=$(date -u -d "${TODAY} - ${i} day" +%Y-%m-%d 2>/dev/null || true)
    [[ -n "$_d" && -f "${METRICS_DIR}/${_d}-daily.json" ]] && _daily_files+=("${METRICS_DIR}/${_d}-daily.json")
done

if [[ ${#_daily_files[@]} -ge 3 ]]; then
    # Extract key metrics from daily summaries using jq
    _cpu_avgs=$(for f in "${_daily_files[@]}"; do jq -r '.summary.cpu.avg // empty' "$f" 2>/dev/null; done)
    # Memory uses daily MAX instead of avg — instantaneous 5-min readings naturally
    # spike 100-200 MB above the daily average during cron runs/builds, causing
    # 6-8σ false positives daily. Comparing against daily peak history eliminates this.
    _mem_maxes=$(for f in "${_daily_files[@]}"; do jq -r '.summary.memory_used_mb.max // empty' "$f" 2>/dev/null; done)
    _load_avgs=$(for f in "${_daily_files[@]}"; do jq -r '.summary.load_1m.avg // empty' "$f" 2>/dev/null; done)
    _proc_avgs=$(for f in "${_daily_files[@]}"; do jq -r '.summary.process_count.avg // empty' "$f" 2>/dev/null; done)

    # Compute mean and stddev, then check current values
    # Format: label|values|current|direction|min_threshold
    #   direction: "high" = only alert above average, "both" = alert either way
    #   min_threshold: minimum absolute value before the metric is worth alerting on
    _vcpus=$(nproc 2>/dev/null || echo 2)
    _load_min_threshold=$(( _vcpus * 2 ))  # load < 2x vCPUs is never anomalous
    for pair in \
        "CPU%|${_cpu_avgs}|$(echo "$metrics" | jq -r '.cpu_percent' 2>/dev/null)|high|40" \
        "Memory MB|${_mem_maxes}|$(echo "$metrics" | jq -r '.memory.used' 2>/dev/null)|high|0" \
        "Load 1m|${_load_avgs}|$(echo "$metrics" | jq -r '.load_average["1min"]' 2>/dev/null)|high|${_load_min_threshold}" \
        "Processes|${_proc_avgs}|$(echo "$metrics" | jq -r '.process_count' 2>/dev/null)|high|200"; do
        _label="${pair%%|*}"
        _rest="${pair#*|}"
        _vals="${_rest%%|*}"
        _rest2="${_rest#*|}"
        _current="${_rest2%%|*}"
        _rest3="${_rest2#*|}"
        _direction="${_rest3%%|*}"
        _min_thr="${_rest3##*|}"

        [[ -z "$_current" || "$_current" == "null" ]] && continue

        # Calculate mean and stddev from the values
        _stats=$(echo "$_vals" | tr ' ' '\n' | grep -v '^$' | awk '
            {sum += $1; sumsq += $1*$1; n++}
            END {if(n>=3) printf "%.2f %.2f", sum/n, sqrt(sumsq/n - (sum/n)^2)}
        ' 2>/dev/null || echo "")

        [[ -z "$_stats" ]] && continue
        _mean="${_stats%% *}"
        _sd="${_stats##* }"

        # Apply minimum stddev floor of 2% of the mean to prevent false positives
        # from metrics with naturally low cross-day variance. Smoothed daily
        # values may differ by only ~10 units while actual variance is much larger.
        # Without this floor, tiny stddev values trigger alerts on normal fluctuations.
        _sd=$(awk -v sd="$_sd" -v mean="$_mean" \
            'BEGIN{floor = mean * 0.02; if(floor < 1) floor = 1; printf "%.2f", (sd > floor ? sd : floor)}' \
            2>/dev/null || echo "$_sd")

        _anomaly_check "$_label" "$_current" "$_mean" "$_sd" "$_direction" "$_min_thr"
    done

    # Write anomaly status for dashboard consumption (includes anomaly details)
    _anomaly_json="[]"
    if [[ ${#_ANOMALY_DETAILS[@]} -gt 0 ]]; then
        _anomaly_json=$(printf '%s\n' "${_ANOMALY_DETAILS[@]}" | jq -s '.' 2>/dev/null || echo '[]')
    fi
    jq -n \
        --arg ts "$NOW" \
        --argjson days "${#_daily_files[@]}" \
        --argjson anomalies "$_anomaly_json" \
        '{timestamp: $ts, baseline_days: $days, status: "active", anomalies: $anomalies}' \
        > "${METRICS_DIR}/anomaly-status.json" 2>/dev/null || true
else
    marvin_log "INFO" "Anomaly detection: insufficient data (${#_daily_files[@]} daily summaries, need 3+)"
fi

# Check disk space (warn at 85%, critical at 95%)
disk_percent=$(echo "$metrics" | jq -r '.disk.percent' 2>/dev/null | tr -d '%')
if [[ -n "$disk_percent" ]] && [[ "$disk_percent" -gt 95 ]]; then
    ISSUES+=("CRITICAL: Disk at ${disk_percent}%")
    marvin_log "CRITICAL" "Disk usage at ${disk_percent}%"
elif [[ -n "$disk_percent" ]] && [[ "$disk_percent" -gt 85 ]]; then
    ISSUES+=("WARNING: Disk at ${disk_percent}%")
    marvin_log "WARN" "Disk usage at ${disk_percent}%"
fi

# Check memory (warn if available < 200MB)
mem_available=$(echo "$metrics" | jq -r '.memory.available' 2>/dev/null)
if [[ -n "$mem_available" ]] && [[ "$mem_available" -lt 200 ]]; then
    ISSUES+=("WARNING: Only ${mem_available}MB RAM available")
    marvin_log "WARN" "Low memory: ${mem_available}MB available"
fi

# Check swap usage (warn if > 80%)
swap_total=$(echo "$metrics" | jq -r '.swap.total' 2>/dev/null)
swap_used=$(echo "$metrics" | jq -r '.swap.used' 2>/dev/null)
if [[ -n "$swap_total" ]] && [[ "$swap_total" -gt 0 ]]; then
    swap_percent=$((swap_used * 100 / swap_total))
    if [[ "$swap_percent" -gt 80 ]]; then
        ISSUES+=("WARNING: Swap at ${swap_percent}%")
        marvin_log "WARN" "Swap usage at ${swap_percent}%"
    fi
fi

# Automatic swap management — expand if RAM pressure detected
# Triggers when: available RAM < 200MB AND swap is either missing or >80% used
if [[ -n "$mem_available" ]] && [[ "$mem_available" -lt 200 ]]; then
    swap_file="/swap"
    current_swap_mb=${swap_total:-0}
    current_swap_used_pct=0
    if [[ "$current_swap_mb" -gt 0 ]]; then
        current_swap_used_pct=$((swap_used * 100 / current_swap_mb))
    fi

    # Check available disk space before attempting swap operations
    disk_free_mb=$(df -m / --output=avail | tail -1 | tr -d ' ')

    if [[ "$current_swap_mb" -eq 0 ]]; then
        # No swap at all — create a 1GB swap file
        if [[ "$disk_free_mb" -lt 1200 ]]; then
            marvin_log "WARN" "Insufficient disk space (${disk_free_mb}MB free) to create 1GB swap — skipping"
        elif dd if=/dev/zero of="${swap_file}" bs=1M count=1024 status=none 2>/dev/null \
            && chmod 600 "${swap_file}" \
            && mkswap "${swap_file}" >/dev/null 2>&1 \
            && swapon "${swap_file}" 2>/dev/null; then
            marvin_log "INFO" "Created and activated 1GB swap file"
            ISSUES+=("INFO: Created 1GB swap file due to RAM pressure")
        else
            marvin_log "ERROR" "Failed to create swap file (${mem_available}MB RAM available)"
            ISSUES+=("WARNING: Failed to create swap — low memory with no swap")
        fi
    elif [[ "$current_swap_used_pct" -gt 80 && "$current_swap_mb" -lt 2048 ]]; then
        # Swap exists but is >80% used and under 2GB — try to expand
        new_size_mb=$((current_swap_mb * 2))
        [[ "$new_size_mb" -gt 2048 ]] && new_size_mb=2048
        if [[ "$disk_free_mb" -lt $((new_size_mb + 200)) ]]; then
            marvin_log "WARN" "Insufficient disk space (${disk_free_mb}MB free) to expand swap to ${new_size_mb}MB — skipping"
        else
            marvin_log "WARN" "RAM pressure + swap ${current_swap_used_pct}% used — expanding swap to ${new_size_mb}MB"
            swapoff "${swap_file}" 2>/dev/null || true
            if dd if=/dev/zero of="${swap_file}" bs=1M count="$new_size_mb" status=none 2>/dev/null \
                && chmod 600 "${swap_file}" \
                && mkswap "${swap_file}" >/dev/null 2>&1 \
                && swapon "${swap_file}" 2>/dev/null; then
                marvin_log "INFO" "Expanded swap to ${new_size_mb}MB"
                ISSUES+=("INFO: Expanded swap to ${new_size_mb}MB due to memory pressure")
            else
                marvin_log "ERROR" "Failed to expand swap"
                ISSUES+=("WARNING: Failed to expand swap under memory pressure")
                # Try to re-enable old swap
                swapon "${swap_file}" 2>/dev/null || true
            fi
        fi
    fi
fi

# Check load average (warn if > 2x vCPU)
load_1m=$(echo "$metrics" | jq -r '.load_average["1min"]' 2>/dev/null)
vcpus=$(nproc 2>/dev/null || echo 2)
load_threshold=$((vcpus * 2))
if [[ -n "$load_1m" ]]; then
    load_int=$(echo "$load_1m" | cut -d'.' -f1)
    if [[ "$load_int" -gt "$load_threshold" ]]; then
        ISSUES+=("WARNING: Load average ${load_1m} (threshold: ${load_threshold})")
        marvin_log "WARN" "High load: ${load_1m}"
    fi
fi

# Check for runaway processes (>50% CPU)
# Uses a tracking file to identify processes that stay hot across multiple checks
RUNAWAY_FILE="${DATA_DIR}/runaway-procs.json"
[[ -f "$RUNAWAY_FILE" ]] || echo '{}' > "$RUNAWAY_FILE"

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    proc_pid=$(echo "$line" | awk '{print $1}')
    proc_cpu=$(echo "$line" | awk '{print $2}')
    proc_name=$(echo "$line" | awk '{print $3}')

    # Skip known-good processes — verify full exe path to prevent
    # comm field spoofing via prctl(PR_SET_NAME) (#38)
    proc_exe=$(readlink -f "/proc/${proc_pid}/exe" 2>/dev/null || echo "")
    case "$proc_name" in
        claude|apt*|dpkg*|ps|jq|fail2ban*)
            if [[ "$proc_exe" == /usr/bin/* || "$proc_exe" == /usr/sbin/* || \
                  "$proc_exe" == /usr/local/bin/* || "$proc_exe" == /snap/* ]]; then
                continue
            fi
            marvin_log "WARN" "Untrusted exe for allowlisted name: ${proc_name} (PID ${proc_pid}, exe=${proc_exe:-unknown}) at ${proc_cpu}% CPU"
        ;;
    esac

    # Check if this PID was already flagged
    prev_ts=$(jq -r --arg pid "$proc_pid" '.[$pid].first_seen // 0' "$RUNAWAY_FILE" 2>/dev/null || echo 0)
    tracked_name=$(jq -r --arg pid "$proc_pid" '.[$pid].name // ""' "$RUNAWAY_FILE" 2>/dev/null || echo "")
    now_ts=$(date +%s)

    # Guard against PID reuse: if the tracked name doesn't match, discard stale entry
    if [[ "$prev_ts" -ne 0 && -n "$tracked_name" && "$tracked_name" != "$proc_name" ]]; then
        jq --arg pid "$proc_pid" 'del(.[$pid])' "$RUNAWAY_FILE" > "${RUNAWAY_FILE}.tmp" \
            && mv "${RUNAWAY_FILE}.tmp" "$RUNAWAY_FILE"
        marvin_log "INFO" "PID ${proc_pid} reused: was ${tracked_name}, now ${proc_name} — reset tracking"
        prev_ts=0
    fi

    if [[ "$prev_ts" -eq 0 ]]; then
        # First sighting — record it
        jq --arg pid "$proc_pid" --arg name "$proc_name" --argjson ts "$now_ts" --arg cpu "$proc_cpu" \
            '.[$pid] = {name: $name, first_seen: $ts, cpu: $cpu}' "$RUNAWAY_FILE" > "${RUNAWAY_FILE}.tmp" \
            && mv "${RUNAWAY_FILE}.tmp" "$RUNAWAY_FILE"
        marvin_log "WARN" "High CPU process detected: PID=${proc_pid} ${proc_name} at ${proc_cpu}%"
    else
        elapsed=$((now_ts - prev_ts))
        if [[ "$elapsed" -gt 600 ]]; then
            # >10 minutes of sustained high CPU — kill it
            ISSUES+=("CRITICAL: Killed runaway process ${proc_name} (PID ${proc_pid}, ${proc_cpu}% CPU for ${elapsed}s)")
            marvin_log "CRITICAL" "Killing runaway process: PID=${proc_pid} ${proc_name} (${proc_cpu}% CPU for ${elapsed}s)"
            kill -15 "$proc_pid" 2>/dev/null || true
            sleep 2
            kill -9 "$proc_pid" 2>/dev/null || true
            # Remove from tracking
            jq --arg pid "$proc_pid" 'del(.[$pid])' "$RUNAWAY_FILE" > "${RUNAWAY_FILE}.tmp" \
                && mv "${RUNAWAY_FILE}.tmp" "$RUNAWAY_FILE"
        else
            ISSUES+=("WARNING: Process ${proc_name} (PID ${proc_pid}) at ${proc_cpu}% CPU for ${elapsed}s")
        fi
    fi
done < <(ps -eo pid,%cpu,comm --no-headers --sort=-%cpu 2>/dev/null | awk '$2 > 50.0 && $3 !~ /^(ps|awk|sort)$/ {print $1, $2, $3}')

# Clean stale entries from runaway tracking (PIDs that are no longer running)
if [[ -f "$RUNAWAY_FILE" ]]; then
    stale_pids=()
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        if ! kill -0 "$pid" 2>/dev/null; then
            stale_pids+=("$pid")
        fi
    done < <(jq -r 'keys[]' "$RUNAWAY_FILE" 2>/dev/null)
    for pid in "${stale_pids[@]}"; do
        jq --arg pid "$pid" 'del(.[$pid])' "$RUNAWAY_FILE" > "${RUNAWAY_FILE}.tmp" \
            && mv "${RUNAWAY_FILE}.tmp" "$RUNAWAY_FILE"
    done
fi

# Check nginx
if ! systemctl is-active --quiet nginx 2>/dev/null; then
    ISSUES+=("CRITICAL: nginx is not running")
    marvin_log "CRITICAL" "nginx is down — attempting restart"
    systemctl restart nginx 2>/dev/null || true
fi

# Check fail2ban
if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
    ISSUES+=("WARNING: fail2ban is not running")
    marvin_log "WARN" "fail2ban is down — attempting restart"
    systemctl restart fail2ban 2>/dev/null || true
fi

# Check cron
if ! systemctl is-active --quiet cron 2>/dev/null; then
    ISSUES+=("CRITICAL: cron is not running")
    marvin_log "CRITICAL" "cron is down — attempting restart"
    systemctl restart cron 2>/dev/null || true
fi

# ─── Website selfcheck ─────────────────────────────────────────────────────
# Verify the live site is actually serving content
SITE_URL="https://robot-marvin.cz"
SITE_OK=true

# Check 1: Main page returns 200 and contains expected content
http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "${SITE_URL}/" 2>/dev/null || echo "000")
if [[ "$http_code" != "200" ]]; then
    ISSUES+=("CRITICAL: Website ${SITE_URL} returned HTTP ${http_code}")
    marvin_log "CRITICAL" "Website returned HTTP ${http_code}"
    SITE_OK=false
else
    # Verify page contains the expected footer/header marker
    page_body=$(curl -s --max-time 10 "${SITE_URL}/" 2>/dev/null || echo "")
    if ! echo "$page_body" | grep -q 'Marvin'; then
        ISSUES+=("WARNING: Website returned 200 but missing 'Marvin' marker in body")
        marvin_log "WARN" "Website body missing expected content"
        SITE_OK=false
    fi
fi

# Check 2: Blog API returns dates
blog_api=$(curl -s --max-time 10 "${SITE_URL}/api/blog" 2>/dev/null || echo "")
if echo "$blog_api" | jq -e '.dates[0]' &>/dev/null; then
    latest_blog_date=$(echo "$blog_api" | jq -r '.dates[0]')
    # Warn if latest blog post is older than 2 days
    latest_ts=$(date -d "$latest_blog_date" +%s 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    age_days=$(( (now_ts - latest_ts) / 86400 ))
    if [[ "$age_days" -gt 2 ]]; then
        ISSUES+=("WARNING: Latest blog post is ${age_days} days old (${latest_blog_date})")
        marvin_log "WARN" "Blog stale: latest post is ${latest_blog_date} (${age_days} days ago)"
    fi
else
    ISSUES+=("CRITICAL: Blog API ${SITE_URL}/api/blog returned invalid data")
    marvin_log "CRITICAL" "Blog API returned invalid JSON or no dates"
    SITE_OK=false
fi

# Check 3: Blog post content is accessible
if [[ -n "${latest_blog_date:-}" ]]; then
    blog_post=$(curl -s --max-time 10 "${SITE_URL}/api/blog/${latest_blog_date}?lang=en" 2>/dev/null || echo "")
    if ! echo "$blog_post" | jq -e '.posts[0].content' &>/dev/null; then
        ISSUES+=("WARNING: Blog post for ${latest_blog_date} returned no content")
        marvin_log "WARN" "Blog post ${latest_blog_date} has no content"
    fi
fi

# Check 4: Static blog markdown via nginx
# Find the latest evening .en.md file that actually exists on disk
latest_evening_md=$(ls -1 /home/marvin/blog/*-evening.en.md 2>/dev/null | sort | tail -1 | xargs -r basename)
if [[ -n "${latest_evening_md:-}" ]]; then
    md_http=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "${SITE_URL}/blog/${latest_evening_md}" 2>/dev/null || echo "000")
    if [[ "$md_http" != "200" ]]; then
        ISSUES+=("WARNING: Blog markdown ${latest_evening_md} returned HTTP ${md_http}")
        marvin_log "WARN" "Blog markdown file not accessible (HTTP ${md_http})"
    fi
fi

# ─── SSL certificate expiry checks ──────────────────────────────────────────
# Check TLS certificates for web and email services, warn if <14 days to expiry

ssl_min_days=999
_check_cert_expiry() {
    local host="$1"
    local port="$2"
    local label="$3"
    local starttls_flag="${4:-}"

    local openssl_args=(-connect "${host}:${port}" -servername "$host")
    [[ -n "$starttls_flag" ]] && openssl_args+=(-starttls "$starttls_flag")

    local expiry_date
    expiry_date=$(echo | openssl s_client "${openssl_args[@]}" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null \
        | sed 's/notAfter=//')

    if [[ -n "$expiry_date" ]]; then
        local expiry_epoch now_epoch days_left
        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        if [[ "$expiry_epoch" -gt 0 ]]; then
            days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
            if [[ "$days_left" -lt "$ssl_min_days" ]]; then
                ssl_min_days=$days_left
            fi
            if [[ "$days_left" -lt 7 ]]; then
                ISSUES+=("CRITICAL: ${label} SSL cert expires in ${days_left} days")
                marvin_log "CRITICAL" "${label} SSL cert expires in ${days_left} days"
            elif [[ "$days_left" -lt 14 ]]; then
                ISSUES+=("WARNING: ${label} SSL cert expires in ${days_left} days")
                marvin_log "WARN" "${label} SSL cert expires in ${days_left} days"
            fi
        fi
    fi
}

_check_cert_expiry "robot-marvin.cz" 443 "HTTPS"
_check_cert_expiry "robot-marvin.cz" 465 "SMTPS"
_check_cert_expiry "robot-marvin.cz" 993 "IMAPS"

# ─── DNS resolution monitoring ──────────────────────────────────────────────
# Verify own domain resolves to the correct IP address
_expected_ip="80.211.223.26"
_dns_status="skipped"
if command -v dig &>/dev/null; then
    _dns_status="ok"
    # Query external DNS (Google) to avoid local resolver entries (127.0.1.1)
    _resolved_ip=$(dig +short robot-marvin.cz A @8.8.8.8 2>/dev/null | tail -1 || echo "")
    if [[ -z "$_resolved_ip" ]]; then
        ISSUES+=("WARNING: DNS resolution failed for robot-marvin.cz")
        marvin_log "WARN" "DNS resolution failed for robot-marvin.cz"
        _dns_status="failing"
    elif [[ "$_resolved_ip" != "$_expected_ip" ]]; then
        ISSUES+=("CRITICAL: DNS mismatch — robot-marvin.cz resolves to ${_resolved_ip}, expected ${_expected_ip}")
        marvin_log "CRITICAL" "DNS mismatch: ${_resolved_ip} != ${_expected_ip}"
        _dns_status="failing"
    fi
fi

# ─── Latency monitoring ─────────────────────────────────────────────────────
# Measure network latency to key endpoints: ICMP ping + HTTPS response time.
# Results stored in status.json and appended to latency JSONL for trending.
_ping_rtt=""
_https_rtt=""

# ICMP ping to Google DNS (general network health indicator)
if command -v ping &>/dev/null; then
    _ping_output=$(ping -c 3 -W 5 8.8.8.8 2>/dev/null || echo "")
    _ping_rtt=$(echo "$_ping_output" | awk -F'/' '/rtt|round-trip/ {printf "%.1f", $5}' 2>/dev/null || echo "")
    if [[ -n "$_ping_rtt" ]]; then
        # Alert if average RTT > 100ms (unusual for a datacenter VPS)
        if awk -v rtt="$_ping_rtt" 'BEGIN{exit (rtt > 100) ? 0 : 1}' 2>/dev/null; then
            ISSUES+=("WARNING: High network latency — ping to 8.8.8.8 is ${_ping_rtt}ms")
            marvin_log "WARN" "High ping latency to 8.8.8.8: ${_ping_rtt}ms"
        fi
    fi
fi

# HTTPS response time to own website (measures full TLS handshake + response)
_https_rtt=$(curl -so /dev/null -w '%{time_total}' --max-time 15 "https://robot-marvin.cz/" 2>/dev/null || echo "")
if [[ -n "$_https_rtt" ]]; then
    # Convert seconds to ms
    _https_rtt=$(awk -v t="$_https_rtt" 'BEGIN{printf "%.0f", t * 1000}' 2>/dev/null || echo "")
    # Alert if own site takes >5s to respond
    if [[ -n "$_https_rtt" ]] && [[ "$_https_rtt" -gt 5000 ]]; then
        ISSUES+=("WARNING: Own website slow — HTTPS response ${_https_rtt}ms")
        marvin_log "WARN" "Slow HTTPS response: ${_https_rtt}ms"
    fi
fi

# Append latency data to daily JSONL for trending analysis
if [[ -n "$_ping_rtt" || -n "$_https_rtt" ]]; then
    _latency_file="${METRICS_DIR}/latency-${TODAY}.jsonl"
    jq -nc \
        --arg ts "$NOW" \
        --arg ping "${_ping_rtt:-null}" \
        --arg https "${_https_rtt:-null}" \
        '{timestamp: $ts,
          ping_8888_ms: (if $ping == "null" then null else ($ping | tonumber) end),
          https_self_ms: (if $https == "null" then null else ($https | tonumber) end)}' \
        >> "$_latency_file" 2>/dev/null || true
fi

# Update status file for the web dashboard
STATUS="healthy"
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    for issue in "${ISSUES[@]}"; do
        if [[ "$issue" == CRITICAL* ]]; then
            STATUS="critical"
            break
        fi
    done
    if [[ "$STATUS" != "critical" ]]; then
        STATUS="warning"
    fi
fi

# Write status summary
cat > "${DATA_DIR}/status.json" << EOF
{
  "timestamp": "${NOW}",
  "status": "${STATUS}",
  "issues_count": ${#ISSUES[@]},
  "issues": $(if [[ ${#ISSUES[@]} -gt 0 ]]; then printf '%s\n' "${ISSUES[@]}" | jq -R . | jq -s .; else echo '[]'; fi),
  "metrics": ${metrics},
  "checks": {
    "nginx": "$(systemctl is-active nginx 2>/dev/null || true)",
    "fail2ban": "$(systemctl is-active fail2ban 2>/dev/null || true)",
    "cron": "$(systemctl is-active cron 2>/dev/null || true)",
    "ssh": "$(systemctl is-active ssh 2>/dev/null || true)",
    "website": "$(if [[ "$SITE_OK" == "true" ]]; then echo "ok"; else echo "failing"; fi)",
    "website_http": "${http_code:-000}",
    "blog_latest": "${latest_blog_date:-unknown}",
    "ssl_min_days": ${ssl_min_days},
    "dns": "${_dns_status}",
    "ping_ms": ${_ping_rtt:-null},
    "https_ms": ${_https_rtt:-null}
  }
}
EOF

# ─── Recent metrics for dashboard sparklines ────────────────────────────────
# Combine today's and yesterday's JSONL into a JSON array at data/metrics/recent.json.
# Lightweight: reads ~500 lines of JSONL, produces a single JSON array.
# Served at /api/metrics/recent.json for client-side sparkline rendering.
_yesterday=$(date -u -d "${TODAY} - 1 day" +%Y-%m-%d 2>/dev/null || true)
{
    [[ -n "$_yesterday" && -f "${METRICS_DIR}/${_yesterday}.jsonl" ]] && cat "${METRICS_DIR}/${_yesterday}.jsonl"
    [[ -f "${METRICS_DIR}/${TODAY}.jsonl" ]] && cat "${METRICS_DIR}/${TODAY}.jsonl"
} | jq -s '.' > "${METRICS_DIR}/recent.json.tmp" 2>/dev/null \
    && mv "${METRICS_DIR}/recent.json.tmp" "${METRICS_DIR}/recent.json" \
    || true

marvin_log "INFO" "Health monitor complete: status=${STATUS}, issues=${#ISSUES[@]}"
