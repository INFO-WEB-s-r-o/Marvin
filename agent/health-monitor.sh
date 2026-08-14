#!/usr/bin/env bash
# =============================================================================
# Marvin — Health Monitor (runs every 5 minutes)
# =============================================================================
# Lightweight: collects metrics, checks services, updates status.
# Does NOT invoke Claude (too expensive for every 5 min).
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

marvin_log_json "INFO" "health-monitor" "Health monitor starting"

# Collect and store metrics
metrics=$(collect_metrics)
append_metrics "$metrics"

# ─── Outbound connection sample (issue #882) ─────────────────────────────────
# The daily security scan used to be the ONLY thing that looked at outbound
# connections: one instantaneous `ss` at 04:00 local, the deadest minute here.
# It reported zero on 30 of 31 days while 704 MB left the box on one of them.
# Sampling belongs on this tick — 288 samples a day instead of one — and the
# scan's §3d now aggregates what this records.
#
# One `ss` call plus one jq over ~40 lines. Explicitly NOT `|| true`: a sampler
# that fails silently is the bug being fixed, so a failure is logged as a
# failure and the JSONL gets an error record to keep the gap visible.
if ! marvin_outbound_record_sample; then
    marvin_log_json "WARN" "health-monitor" \
        "Outbound connection sample failed — egress history has a gap for this tick"
fi

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
    # Process count uses daily MAX instead of avg — same reasoning as Memory MB
    # above. The instantaneous 5-min reading naturally rises toward the daily
    # peak during cron runs and (since the 2026-05-25 Marvin-Brain Docker stack)
    # container churn, while the daily *average* baseline sits ~15 below it.
    # Comparing an instantaneous near-peak reading against the avg baseline with
    # a tight stddev produced recurring false positives (2026-05-25/29, 2026-06-02:
    # "Processes = 200, avg=182, 4.9σ"). Comparing today's reading against the
    # rolling daily-peak history eliminates this while still catching a genuine
    # process explosion that exceeds the historical peak band.
    _proc_maxes=$(for f in "${_daily_files[@]}"; do jq -r '.summary.process_count.max // empty' "$f" 2>/dev/null; done)
    # Net RX/TX anomaly detection moved to metric-aggregate.sh (runs once daily
    # at 23:00 UTC). Comparing today's running cumulative MB against full-day
    # historical totals produced escalating false-positives all day on any
    # heavier-traffic day — by 07:00 the day-so-far had already crossed
    # yesterday's full-day total on busy days.

    # Compute mean and stddev, then check current values
    # Format: label|values|current|direction|min_threshold
    #   direction: "high" = only alert above average, "both" = alert either way
    #   min_threshold: minimum absolute value before the metric is worth alerting on
    _vcpus=$(nproc 2>/dev/null || echo 2)
    _load_min_threshold=$(( _vcpus * 2 ))  # load < 2x vCPUs is never anomalous
    # Memory MB was the only anomaly metric with min_threshold=0, so any positive
    # 2σ deviation alerted regardless of how much RAM was actually in use. As the
    # daily-peak baseline drifts slowly upward (~10 MB/day while the Marvin-Brain
    # stack caches settle — 1293→1392 MB over 2026-06-10..19), the lagging 7-day
    # rolling baseline kept sitting just below the instantaneous reading, and with
    # the stddev floored at 2% the current value poked past 2σ almost every day:
    # marginal, non-actionable WARNs (2026-06-19 2.1σ, 2026-06-20 2.3σ) at only
    # ~36% of RAM with 2.6 GB free. Floor the alert at 60% of total RAM so the 2σ
    # check fires only when memory is BOTH statistically unusual AND absolutely
    # elevated; genuine pressure is independently caught by the swap manager
    # (available-MB check) and the resource-forecast in metric-aggregate.sh.
    # Scales with RAM, mirroring how _load_min_threshold scales with vCPUs.
    # Fails safe: `// 0` → threshold 0 → prior (no-mask) behaviour if jq fails.
    _mem_total=$(echo "$metrics" | jq -r '.memory.total // 0' 2>/dev/null)
    _mem_min_threshold=$(( _mem_total * 60 / 100 ))

    for pair in \
        "CPU%|${_cpu_avgs}|$(echo "$metrics" | jq -r '.cpu_percent' 2>/dev/null)|high|80" \
        "Memory MB|${_mem_maxes}|$(echo "$metrics" | jq -r '.memory.used' 2>/dev/null)|high|${_mem_min_threshold}" \
        "Load 1m|${_load_avgs}|$(echo "$metrics" | jq -r '.load_average["1min"]' 2>/dev/null)|high|${_load_min_threshold}" \
        "Processes|${_proc_maxes}|$(echo "$metrics" | jq -r '.process_count' 2>/dev/null)|high|200"; do
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
        _stats=$(echo "$_vals" | tr ' ' '\n' | sed '/^$/d' | awk '
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

# Pure helper — pages swapped in+out between two /proc/vmstat readings.
# Clamped to >=0 so a reboot (counters reset near zero) reads as "no paging
# observed" instead of a large negative number. Its own function so this
# arithmetic can be exercised in isolation instead of only by reading the
# log days later.
_swap_paging_delta() {
    local pin_now="$1" pout_now="$2" pin_prev="$3" pout_prev="$4"
    local delta=$(( (pin_now - pin_prev) + (pout_now - pout_prev) ))
    [[ "$delta" -lt 0 ]] && delta=0
    echo "$delta"
}

# Check swap usage (warn if > 80% AND actively paging).
#
# A high swap PERCENTAGE alone is not actionable: vm.swappiness=1 means the
# kernel almost never swaps a page back in once it's out, so cold pages
# accumulate toward the ceiling and then just sit there — "full" and "idle"
# look identical from a single free -m snapshot. Issue #1047 tracked exactly
# this from 2026-08-07: swap climbed 45%→92%→100%, available RAM stayed a
# healthy ~2.2GB the entire time, and vmstat si/so were 0 at every check —
# a capacity ceiling, not thrashing. The old static >80% rule WARNed every
# 5 minutes regardless (hundreds of times a day) and, because any non-empty
# ISSUES entry pins the public dashboard status to "warning" (see the
# STATUS block below), it left robot-marvin.cz showing a false warning for
# a week straight.
#
# Fix: only escalate to WARNING when swap pages actually moved (in or out)
# since the last health-monitor tick. /proc/vmstat's pswpin/pswpout are
# cumulative since boot, so a small state file carries the previous
# reading forward. Genuine low-RAM pressure is still caught independently
# by the "Check memory" block above (mem_available < 200MB) — this check
# only needed to stop conflating "full" with "moving", not to duplicate a
# memory threshold. A swap-full-but-idle host is still logged every cycle,
# just at INFO instead of WARN, and without flipping the dashboard red.
swap_total=$(echo "$metrics" | jq -r '.swap.total' 2>/dev/null)
swap_used=$(echo "$metrics" | jq -r '.swap.used' 2>/dev/null)
if [[ -n "$swap_total" ]] && [[ "$swap_total" -gt 0 ]]; then
    swap_percent=$((swap_used * 100 / swap_total))
    if [[ "$swap_percent" -gt 80 ]]; then
        swap_state_dir="${DATA_DIR}/state"
        swap_state_file="${swap_state_dir}/swap-paging.state"
        swap_state_persist_ok=1
        mkdir -p "$swap_state_dir" 2>/dev/null || swap_state_persist_ok=0

        pswpin_now=$(awk '/^pswpin /{print $2}' /proc/vmstat 2>/dev/null || echo "")
        pswpout_now=$(awk '/^pswpout /{print $2}' /proc/vmstat 2>/dev/null || echo "")
        [[ "$pswpin_now" =~ ^[0-9]+$ ]] || pswpin_now=0
        [[ "$pswpout_now" =~ ^[0-9]+$ ]] || pswpout_now=0

        pswpin_prev="" pswpout_prev=""
        if [[ -f "$swap_state_file" ]]; then
            read -r pswpin_prev pswpout_prev < "$swap_state_file" 2>/dev/null || true
        fi
        # No prior state (first run, or file lost) — seed prev=now so this
        # tick reads as idle rather than a false-positive spike.
        [[ "$pswpin_prev" =~ ^[0-9]+$ ]] || pswpin_prev="$pswpin_now"
        [[ "$pswpout_prev" =~ ^[0-9]+$ ]] || pswpout_prev="$pswpout_now"

        swap_delta_pages=$(_swap_paging_delta "$pswpin_now" "$pswpout_now" "$pswpin_prev" "$pswpout_prev")

        if [[ "$swap_state_persist_ok" -eq 1 ]]; then
            echo "${pswpin_now} ${pswpout_now}" > "$swap_state_file" 2>/dev/null || swap_state_persist_ok=0
        fi
        # Persistence failure (disk full, permissions, read-only fs) must be
        # loud: silently swallowing it reseeds prev=now on every tick and the
        # check reports "idle" forever, masking real paging indefinitely —
        # at the exact moment (disk full) real swap pressure is most likely.
        if [[ "$swap_state_persist_ok" -eq 0 ]]; then
            marvin_log "WARN" "swap-paging state file ${swap_state_file} could not be written — paging delta cannot be tracked between ticks, swap check will read idle until this is fixed"
        fi

        if [[ "$swap_delta_pages" -gt 0 ]]; then
            ISSUES+=("WARNING: Swap at ${swap_percent}% (actively paging, ${swap_delta_pages} pages since last check)")
            marvin_log "WARN" "Swap usage at ${swap_percent}% — actively paging (${swap_delta_pages} pages since last check)"
        else
            marvin_log "INFO" "Swap usage at ${swap_percent}% (idle — no paging activity since last check)"
        fi
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

# Resolve trusted paths for claude CLI — it's installed via npm and the
# node binary may live outside /usr/bin on some setups (nvm, .npm-global) (#189)
_trusted_node_bin=$(readlink -f "$(command -v node 2>/dev/null)" 2>/dev/null || echo "")
_trusted_claude_bin=$(readlink -f "$(command -v claude 2>/dev/null)" 2>/dev/null || echo "")

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    proc_pid=$(echo "$line" | awk '{print $1}')
    proc_cpu=$(echo "$line" | awk '{print $2}')
    proc_name=$(echo "$line" | awk '{print $3}')

    # ─── Container-managed processes (Docker / containerd) ──────────────────
    # Never host-kill a containerized process: Docker owns its lifecycle (cgroup
    # limits, healthchecks, restart policy), so a host kill -9 just corrupts state
    # Docker rebuilds anyway. cgroup membership is root-only (cgroupfs) and
    # unforgeable, unlike the `comm` field (prctl PR_SET_NAME, #38) — a stronger
    # trust signal than the name allowlist below. Matches docker-<hash>.scope
    # (cgroup v2) and /docker/<hash> (v1); host daemons (docker.service,
    # containerd.service) lack the [-/] and stay subject to detection. An empty
    # read (process raced to exit) falls through to the name allowlist. Full
    # rationale + threat model: PR #761. Read the whole file (procfs, zero I/O
    # cost): cgroup v1/hybrid hosts emit one line per controller, so the /docker
    # lines can sit past a fixed byte cap and a truncated read would silently
    # miss them (#762).
    proc_cgroup=$(cat "/proc/${proc_pid}/cgroup" 2>/dev/null || echo "")
    if [[ "$proc_cgroup" =~ /docker[-/] ]]; then
        marvin_log "INFO" "High CPU in container process: PID=${proc_pid} ${proc_name} at ${proc_cpu}% — Docker-managed, not tracked for host-kill"
        continue
    fi

    # Liveness guard: short-lived processes (notably the Marvin-Brain Docker
    # CMD-SHELL healthchecks — sub-second `sh`/`python`/`runc`) are sampled by
    # ps, then exit before we read their cgroup above, so they fall through and
    # get logged as runaways with a kill that can never land. A dead PID cannot
    # be a >10-min sustained runaway, so skip it silently. This cannot weaken
    # the killer or the exe-spoof checks below: a genuine runaway, or a live
    # attacker spoofing a comm via prctl(PR_SET_NAME), is alive across samples
    # and passes this guard. Mirrors the liveness check in the find|git branch
    # (#547) and the stale-entry cleanup below. (Full context: PR #781.)
    if [[ ! -d "/proc/${proc_pid}" ]]; then
        continue
    fi

    # Skip known-good processes — verify full exe path to prevent
    # comm field spoofing via prctl(PR_SET_NAME) (#38)
    proc_exe=$(readlink -f "/proc/${proc_pid}/exe" 2>/dev/null || echo "")
    case "$proc_name" in
        claude|apt*|dpkg*|unattended-upgr*|ps|jq|fail2ban*|file|appstreamcli|shellcheck|pg_isready|gzip|runc*|chkproc|certbot|cnf-update-db)
            # High-frequency, low-risk short-lived children — silent skip when
            # exe is unreadable (they exit between ps and readlink constantly).
            # Contrast with find|git below which logs + falls through, because
            # those run longer and an unreadable exe is more suspicious there.
            # pg_isready: Marvin-Brain postgres healthcheck runs every 5s inside
            # the marvin-brain-postgres-1 container; readlink -f returns empty
            # for container processes because /usr/lib/postgresql/17/bin/pg_isready
            # is inside the container's mount namespace, not the host's.
            # gzip: disk-cleanup.sh (01:00 UTC) and logrotate compress
            # multi-MB JSONL/log files; a single core hitting 100% for one
            # 5-min sample window is the normal shape of compression work.
            # Trusted exe path (/usr/bin/gzip) still required by the check below.
            # runc*: the OCI container runtime (/usr/bin/runc) launched by
            # containerd for the Marvin-Brain Docker stack. Both the plain
            # `runc` exec and the `runc:[2:INIT]` container-init child briefly
            # peg one core to 100% during container (re)starts and healthcheck
            # cycles — caught by `runc*` glob. Trusted exe path still enforced.
            # certbot: the Let's Encrypt client (/usr/bin/certbot) runs from
            # certbot.timer (twice daily) and during renewal spikes one core to
            # ~88-100% while building/verifying the ACME challenge. Trusted exe
            # path (/usr/bin/certbot) enforced below like every other entry.
            # chkproc: the chkrootkit /proc-scanner helper, run daily by both
            # security-scan.sh (04:00 UTC) and /etc/cron.daily/chkrootkit
            # (~19:15). Scanning every PID pegs a core for one 5-min sample.
            # Its exe lives at /usr/lib/chkrootkit/chkproc — a dpkg-owned,
            # root-only path NOT covered by the /usr/{bin,sbin,local/bin} list,
            # so that exact binary is pinned in the trusted check below
            # (otherwise allowlisting the name alone would just trade the
            # runaway WARN for an "Untrusted exe" WARN — same noise, #786).
            # Pinned to the specific binary rather than the package dir glob so
            # any future chkrootkit helper that pegs CPU still gets a deliberate
            # review rather than a silent skip (PR #786 review).
            # cnf-update-db: the command-not-found database updater, fired by the
            # apt hook /etc/apt/apt.conf.d/50command-not-found after every apt
            # operation (e.g. right after unattended-upgrades applies a security
            # update — observed 2026-07-01 at 66.6% CPU). It is a #!/usr/bin/python3
            # script, so /proc/PID/exe resolves to the interpreter (/usr/bin/
            # python3.x) — already covered by the /usr/bin/* trusted-path check
            # below, so no pinned exe entry is needed (unlike chkproc). It rebuilds
            # /var/lib/command-not-found/commands.db in seconds and can never reach
            # the 600s sustained-CPU kill threshold, so the WARN was pure noise. A
            # cnf-update-db-named process running an UNtrusted exe still WARNs.
            if [[ -z "$proc_exe" ]]; then
                continue
            fi
            if [[ "$proc_exe" == /usr/bin/* || "$proc_exe" == /usr/sbin/* || \
                  "$proc_exe" == /usr/local/bin/* || "$proc_exe" == /snap/* || \
                  "$proc_exe" == /usr/lib/chkrootkit/chkproc || \
                  ( -n "$_trusted_node_bin" && "$proc_exe" == "$_trusted_node_bin" ) || \
                  ( -n "$_trusted_claude_bin" && "$proc_exe" == "$_trusted_claude_bin" ) ]]; then
                continue
            fi
            # runc memfd self-exec: runc re-execs itself from an anonymous memfd
            # (the CVE-2019-5736 mitigation), so a LIVE runc's /proc/PID/exe never
            # resolves to /usr/bin/runc — readlink -f reads back empty, a
            # "(deleted)" target, or the literal /proc/PID/exe path. The empty
            # case is silently skipped above, but the non-empty cases fall through
            # to a daily false "Untrusted exe" WARN (observed 2026-06-24:
            # exe=/proc/2673255/exe at 100% CPU). The exe-path gate is therefore
            # structurally unable to verify a live runc, so the `runc*` allowlist
            # entry only ever covered the dead/empty case. runc cannot be
            # host-killed by this loop regardless (sub-minute container-setup
            # spikes never reach the 600s sustained threshold). Verify provenance
            # the way the top-of-loop cgroup guard does instead: a genuine runc is
            # launched by containerd-shim-runc-v2, which lives in the containerd /
            # docker systemd service slice (e.g. /system.slice/containerd.service),
            # so runc inherits that cgroup. That is NOT the per-container
            # docker-<hash>.scope the guard at line 321 matches — it's the runtime
            # *management* slice, a root-only, unforgeable cgroup (cgroupfs) that an
            # attacker cannot place a prctl(PR_SET_NAME)-spoofed `runc` into without
            # already holding root, in which case the monitor is moot anyway (same
            # threat model as PR #761). A runc-named process outside those slices
            # still WARNs and falls through to tracking. Fail-safe: an empty/
            # unreadable cgroup does not match, so it WARNs rather than being hidden.
            if [[ "$proc_name" == runc* && "$proc_cgroup" =~ /(containerd|docker)\.service(/|$) ]]; then
                continue
            fi
            marvin_log "WARN" "Untrusted exe for allowlisted name: ${proc_name} (PID ${proc_pid}, exe=${proc_exe}) at ${proc_cpu}% CPU"
        ;;
        find|git)
            # Only suppress find/git if it's the real binary AND launched by a
            # Marvin bash script — avoids blanket suppression (#510, #514).
            # git spikes to 100% CPU during morning-check fetch/pull/push and
            # github-interact push operations — this is normal and transient.
            if [[ -z "$proc_exe" ]]; then
                # /proc/PID/exe unreadable — most likely the process already exited
                # between ps and readlink (race condition). Check liveness:
                # - Dead process → skip silently (no threat from a finished process)
                # - Alive but unreadable exe → suspicious, log and fall through (#547)
                if [[ ! -d "/proc/${proc_pid}" ]]; then
                    continue  # Process already exited — harmless race condition
                fi
                marvin_log "WARN" "Cannot read exe for running ${proc_name} at ${proc_cpu}% CPU (PID ${proc_pid}) — treating as unverified"
            fi
            _expected_exe="/usr/bin/${proc_name}"
            if [[ "$proc_exe" == "$_expected_exe" ]]; then
                proc_ppid=$(awk '/^PPid:/{print $2}' "/proc/${proc_pid}/status" 2>/dev/null || echo "")
                if [[ -n "$proc_ppid" ]]; then
                    parent_exe=$(readlink -f "/proc/${proc_ppid}/exe" 2>/dev/null || echo "")
                    parent_cmdline=$(tr '\0' ' ' < "/proc/${proc_ppid}/cmdline" 2>/dev/null || echo "")
                    if [[ -n "${MARVIN_DIR}" && "$parent_exe" == */bash ]] && [[ "$parent_cmdline" == *"${MARVIN_DIR}"* ]]; then
                        continue
                    fi
                fi
                marvin_log "WARN" "Non-Marvin ${proc_name} at ${proc_cpu}% CPU (PID ${proc_pid}, ppid=${proc_ppid:-unknown})"
            else
                marvin_log "WARN" "Untrusted exe for allowlisted name: ${proc_name} (PID ${proc_pid}, exe=${proc_exe}) at ${proc_cpu}% CPU"
            fi
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
        [[ "$pid" =~ ^[0-9]+$ ]] || continue  # Sanitize: jq keys must be numeric PIDs
        if [[ ! -d "/proc/${pid}" ]]; then
            stale_pids+=("$pid")
        fi
    done < <(jq -r 'keys[]' "$RUNAWAY_FILE" 2>/dev/null)
    for pid in "${stale_pids[@]}"; do
        jq --arg pid "$pid" 'del(.[$pid])' "$RUNAWAY_FILE" > "${RUNAWAY_FILE}.tmp" \
            && mv "${RUNAWAY_FILE}.tmp" "$RUNAWAY_FILE"
    done
fi

# Check nginx — graceful reload preferred over hard restart
if ! systemctl is-active --quiet nginx 2>/dev/null; then
    ISSUES+=("CRITICAL: nginx is not running")
    marvin_log "CRITICAL" "nginx is down — testing config before restart"
    if nginx -t 2>/dev/null; then
        systemctl start nginx 2>/dev/null || {
            marvin_log "ERROR" "nginx start failed — forcing restart"
            systemctl restart nginx 2>/dev/null || true
        }
    else
        marvin_log "ERROR" "nginx config test failed — cannot restart safely"
    fi
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

# Check marvin-web (Next.js dashboard)
if ! systemctl is-active --quiet marvin-web 2>/dev/null; then
    ISSUES+=("CRITICAL: marvin-web (dashboard) is not running")
    marvin_log "CRITICAL" "marvin-web is down — attempting restart"
    systemctl restart marvin-web 2>/dev/null || true
fi

# ─── Website selfcheck ─────────────────────────────────────────────────────
# Single curl gets body + HTTP code in one round trip; retries once on
# transient failure to suppress flaky body-truncation WARNs.
SITE_URL="https://robot-marvin.cz"
SITE_OK=true
http_code="000"
page_body=""

for _attempt in 1 2; do
    # \x1F (Unit Separator) cannot legally appear in HTML, so it's an unambiguous body/code delimiter.
    site_response=$(curl -s --max-time 10 -w $'\x1F%{http_code}' "${SITE_URL}/" 2>/dev/null || true)
    http_code="${site_response##*$'\x1F'}"
    page_body="${site_response%$'\x1F'*}"
    # Defensive: a corrupted/partial response could leave http_code non-numeric
    [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code="000"

    if [[ "$http_code" == "200" ]] && grep -q 'Marvin' <<< "$page_body"; then
        break
    fi
    [[ "$_attempt" -eq 1 ]] && sleep 3
done

if [[ "$http_code" != "200" ]]; then
    ISSUES+=("CRITICAL: Website ${SITE_URL} returned HTTP ${http_code} (after retry)")
    marvin_log "CRITICAL" "Website returned HTTP ${http_code} (after retry)"
    SITE_OK=false
elif ! grep -q 'Marvin' <<< "$page_body"; then
    ISSUES+=("WARNING: Website returned 200 but missing 'Marvin' marker in body (after retry)")
    marvin_log "WARN" "Website body missing expected content (after retry)"
    SITE_OK=false
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

# Check 5: Next.js JS asset integrity (detects build/server mismatch)
# The running server may have an old build ID while disk has a newer build —
# causing the HTML to reference JS chunks that no longer exist (all 404).
# This is invisible to HTTP 200 checks but breaks the entire dashboard.
_js_chunk=$(curl -s --max-time 10 "${SITE_URL}/" 2>/dev/null \
    | grep -oP 'src="/_next/static/chunks/[^"]*"' | head -1 \
    | grep -oP '/_next/static/chunks/[^"]*' || true)
if [[ -n "$_js_chunk" ]]; then
    _chunk_status=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "${SITE_URL}${_js_chunk}" 2>/dev/null || echo "000")
    if [[ "$_chunk_status" != "200" ]]; then
        # HTTP 404 = file definitively missing (stale build ID) → rebuild immediately.
        # Non-404 errors (400, 502, 000) may be transient (nginx rate limit, temp
        # error, network blip) → retry once after 5s before triggering a costly
        # full rebuild. Prevents unnecessary rebuilds from transient issues (#400-fix).
        if [[ "$_chunk_status" != "404" ]]; then
            marvin_log "WARN" "JS asset ${_js_chunk} returned HTTP ${_chunk_status} — retrying in 5s"
            sleep 5
            _chunk_status=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "${SITE_URL}${_js_chunk}" 2>/dev/null || echo "000")
            if [[ "$_chunk_status" == "200" ]]; then
                marvin_log "INFO" "JS asset check passed on retry — transient error resolved"
            fi
        fi
    fi
    if [[ "$_chunk_status" != "200" ]]; then
        marvin_log "CRITICAL" "JS asset ${_js_chunk} returned HTTP ${_chunk_status} — build/server mismatch detected"
        if marvin_rebuild_web "health-monitor: JS asset HTTP ${_chunk_status}"; then
            ISSUES+=("WARNING: JS asset HTTP ${_chunk_status} detected — auto-rebuilt web successfully")
            marvin_log "INFO" "Build/server mismatch auto-resolved via rebuild"
        else
            ISSUES+=("CRITICAL: JS asset ${_js_chunk} returned HTTP ${_chunk_status} — rebuild failed")
            marvin_log "CRITICAL" "Web rebuild failed — dashboard may be broken until next manual intervention"
            SITE_OK=false
        fi
    fi
else
    marvin_log "WARN" "Could not extract JS chunk URL from page to verify asset integrity"
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
    # Match only a real dotted-quad IPv4 — octets bounded to 0-255 so junk like
    # 999.999.999.999 can never pass as an "answer" (per PR #799 review).
    _octet='(25[0-5]|2[0-4][0-9]|[01]?[0-9]{1,2})'
    _ipv4_re="^(${_octet}\.){3}${_octet}$"
    # Query external DNS (Google) to avoid local resolver entries (127.0.1.1).
    # dig prints diagnostics like ";; no servers could be reached" to stdout when a
    # resolver is unreachable, so keep only lines shaped like a dotted-quad IPv4.
    _resolved_ip=$(dig +short robot-marvin.cz A @8.8.8.8 2>/dev/null | grep -E "$_ipv4_re" | tail -1 || echo "")
    if [[ -z "$_resolved_ip" ]]; then
        # No valid answer (resolver unreachable or empty) — transient, not a hijack.
        ISSUES+=("WARNING: DNS resolution failed for robot-marvin.cz")
        marvin_log "WARN" "DNS resolution failed for robot-marvin.cz"
        _dns_status="failing"
    elif [[ "$_resolved_ip" != "$_expected_ip" ]]; then
        # A valid but wrong IP from one resolver could be a blip; confirm against a
        # second independent resolver before escalating to a CRITICAL hijack alert.
        _resolved_ip2=$(dig +short robot-marvin.cz A @1.1.1.1 2>/dev/null | grep -E "$_ipv4_re" | tail -1 || echo "")
        if [[ -z "$_resolved_ip2" || "$_resolved_ip2" == "$_expected_ip" ]]; then
            ISSUES+=("WARNING: DNS resolution inconsistent for robot-marvin.cz — 8.8.8.8 returned ${_resolved_ip}, expected ${_expected_ip}")
            marvin_log "WARN" "DNS inconsistent: 8.8.8.8=${_resolved_ip}, 1.1.1.1=${_resolved_ip2:-unreachable}, expected ${_expected_ip}"
            _dns_status="failing"
        else
            ISSUES+=("CRITICAL: DNS mismatch — robot-marvin.cz resolves to ${_resolved_ip}, expected ${_expected_ip}")
            marvin_log "CRITICAL" "DNS mismatch: ${_resolved_ip} (8.8.8.8), ${_resolved_ip2} (1.1.1.1) != ${_expected_ip}"
            _dns_status="failing"
        fi
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
    "marvin_web": "$(systemctl is-active marvin-web 2>/dev/null || true)",
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

# ─── Peer health exchange endpoint ────────────────────────────────────────────
# Generates a non-sensitive health summary for AI peer consumption.
# Served at /api/peer-health.json. Peers can fetch this to assess Marvin's status.
# Deliberately excludes: issue details, internal IPs, service names, error messages.
_peer_cpu=$(echo "$metrics" | jq -r '.cpu_percent // 0' 2>/dev/null)
_peer_mem_pct=0
_peer_mem_total=$(echo "$metrics" | jq -r '.memory.total // 0' 2>/dev/null)
_peer_mem_used=$(echo "$metrics" | jq -r '.memory.used // 0' 2>/dev/null)
if [[ "$_peer_mem_total" -gt 0 ]]; then
    _peer_mem_pct=$(( _peer_mem_used * 100 / _peer_mem_total ))
fi
_peer_disk_pct=$(echo "$metrics" | jq -r '.disk.percent // "0"' 2>/dev/null | tr -d '%')
_peer_load=$(echo "$metrics" | jq -r '.load_average["1min"] // 0' 2>/dev/null)
_peer_uptime=""
if [[ -f "${METRICS_DIR}/sla.json" ]]; then
    _peer_uptime=$(jq -r '.summary.overall_uptime_pct // empty' "${METRICS_DIR}/sla.json" 2>/dev/null || echo "")
fi
_peer_caps=0
if [[ -f "${DATA_DIR}/capabilities.json" ]]; then
    _peer_caps=$(jq -r '.total_capabilities // 0' "${DATA_DIR}/capabilities.json" 2>/dev/null || echo 0)
fi
_peer_count=0
if [[ -f "${COMMS_DIR}/peers.json" ]]; then
    _peer_count=$(jq -r '.peers | length' "${COMMS_DIR}/peers.json" 2>/dev/null || echo 0)
fi
jq -nc \
    --arg name "Marvin" \
    --arg domain "robot-marvin.cz" \
    --arg engine "claude-code" \
    --arg ts "$NOW" \
    --arg status "$STATUS" \
    --argjson cpu "$_peer_cpu" \
    --argjson mem "$_peer_mem_pct" \
    --argjson disk "${_peer_disk_pct:-0}" \
    --arg load "$_peer_load" \
    --arg uptime_30d "${_peer_uptime:-unknown}" \
    --argjson ssl_days "${ssl_min_days:-0}" \
    --argjson peers "$_peer_count" \
    --argjson capabilities "$_peer_caps" \
    '{
        name: $name,
        domain: $domain,
        engine: $engine,
        protocol: "marvin-peer-health/1.0",
        timestamp: $ts,
        status: $status,
        metrics: {
            cpu_percent: $cpu,
            memory_percent: $mem,
            disk_percent: ($disk | tonumber),
            load_1m: ($load | tonumber)
        },
        uptime_30d_pct: (if $uptime_30d != "unknown" then ($uptime_30d | tonumber) else null end),
        ssl_cert_days: $ssl_days,
        peers_known: $peers,
        capabilities: $capabilities
    }' > "${DATA_DIR}/peer-health.json.tmp" 2>/dev/null \
    && mv "${DATA_DIR}/peer-health.json.tmp" "${DATA_DIR}/peer-health.json" \
    || true

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

# ─── Recent structured logs (local consumers only) ───────────────────────────
# Parse today's log into a JSON array at data/logs/recent.json.
# Format: [{timestamp, level, message}, ...] — last 500 entries.
#
# NOT served over HTTP. This said "Served at /api/logs/recent.json for dashboard
# log viewer / search" from 2026-03-18 until 2026-07-28, which stopped being
# true when #861 turned `location /api/` from a denylist into an allowlist
# (deployed 2026-07-27 05:40Z). The whole /api/logs/ namespace now returns 403,
# verified live, and no dashboard log viewer exists — the frontend fetches only
# /api/blog* and /api/reports/weekly-card-latest.svg.
#
# Do NOT "fix" that 403 by adding logs/ to the allowlist. These are raw internal
# operational log lines; publishing all of data/ under /api/ is the exact defect
# #861 was opened to close. Local readers use the file on disk.
mkdir -p "${DATA_DIR}/logs"
if [[ -f "${LOGS_DIR}/${TODAY}.log" ]]; then
    awk -F'[][]' '
    /^\[.*\] \[.*\]/ {
        ts = $2
        lvl = $4
        # Everything after the second ] + space is the message
        msg = substr($0, index($0, "] [" lvl "]") + length(lvl) + 5)
        gsub(/\\/, "\\\\", msg)
        gsub(/"/, "\\\"", msg)
        gsub(/\t/, "\\t", msg)
        gsub(/\n/, "\\n", msg)
        gsub(/\r/, "\\r", msg)
        printf "{\"timestamp\":\"%s\",\"level\":\"%s\",\"message\":\"%s\"}\n", ts, lvl, msg
    }' "${LOGS_DIR}/${TODAY}.log" | tail -500 | jq -s '.' \
        > "${DATA_DIR}/logs/recent.json.tmp" 2>/dev/null \
        && mv "${DATA_DIR}/logs/recent.json.tmp" "${DATA_DIR}/logs/recent.json" \
        || true
fi

# ─── Trigger incident detection on critical status ───────────────────────────
# Run incident-report.sh in detect+summary mode when critical issues are found.
# Deliberately omits --close: auto-resolution runs only via the twice-daily cron
# (00:15, 12:15 UTC) to avoid resolving transient recoveries too eagerly.
# Runs async (background + disown) to avoid slowing down the 5-min health check.
if [[ "$STATUS" == "critical" ]]; then
    if [[ -x "${MARVIN_DIR}/agent/incident-report.sh" ]]; then
        bash "${MARVIN_DIR}/agent/incident-report.sh" --detect --summary \
            >> "${LOGS_DIR}/incidents.log" 2>&1 &
        disown 2>/dev/null || true
    fi
fi

marvin_log_json "INFO" "health-monitor" "Health monitor complete" \
    "$(jq -nc --arg s "${STATUS}" --argjson n "${#ISSUES[@]}" '{status:$s,issues_count:$n}')"
