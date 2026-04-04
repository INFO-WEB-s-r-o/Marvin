#!/usr/bin/env bash
# =============================================================================
# Marvin — Metrics Library
# =============================================================================
# System metric collection and storage functions.
#
# Requires these variables from common.sh:
#   METRICS_DIR, NOW, TODAY
#
# Usage: sourced automatically by common.sh (do not source directly)
# =============================================================================

# Collect current system metrics as JSON
collect_metrics() {
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "0")

    local mem_info
    mem_info=$(free -m | awk 'NR==2{printf "{\"total\":%s,\"used\":%s,\"free\":%s,\"available\":%s}", $2, $3, $4, $7}')

    local swap_info
    swap_info=$(free -m | awk 'NR==3{printf "{\"total\":%s,\"used\":%s,\"free\":%s}", $2, $3, $4}')

    local disk_info
    disk_info=$(df -m / | awk 'NR==2{printf "{\"total\":%s,\"used\":%s,\"available\":%s,\"percent\":\"%s\"}", $2, $3, $4, $5}')

    local load_avg
    load_avg=$(cat /proc/loadavg | awk '{printf "{\"1min\":%s,\"5min\":%s,\"15min\":%s}", $1, $2, $3}')

    local uptime_seconds
    uptime_seconds=$(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1)

    local process_count
    process_count=$(ps aux | wc -l)

    local fail2ban_banned
    fail2ban_banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "0")

    # Network I/O: bytes received/transmitted on primary interface
    local net_iface net_info
    net_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}' || echo "")
    if [[ -n "$net_iface" ]]; then
        net_info=$(awk -v iface="${net_iface}:" -v name="${net_iface}" \
            '$1==iface {printf "{\"interface\":\"%s\",\"rx_bytes\":%s,\"tx_bytes\":%s,\"rx_packets\":%s,\"tx_packets\":%s}", name, $2, $10, $3, $11}' \
            /proc/net/dev 2>/dev/null || echo '{}')
    else
        net_info='{}'
    fi

    cat << EOF
{
  "timestamp": "${NOW}",
  "uptime_seconds": ${uptime_seconds},
  "cpu_percent": ${cpu_usage},
  "memory": ${mem_info},
  "swap": ${swap_info},
  "disk": ${disk_info},
  "load_average": ${load_avg},
  "process_count": ${process_count},
  "fail2ban_banned": ${fail2ban_banned},
  "network": ${net_info},
  "kernel": "$(uname -r | cut -d'-' -f1)"
}
EOF
}

# Append to daily metrics history
append_metrics() {
    local metrics="$1"
    local history_file="${METRICS_DIR}/${TODAY}.jsonl"
    # Compact to single line for JSONL format (one JSON object per line)
    echo "$metrics" | jq -c '.' >> "$history_file" 2>/dev/null || \
        echo "$metrics" | tr -d '\n' >> "$history_file"

    # Also update latest.json
    echo "$metrics" | jq '.' > "${METRICS_DIR}/latest.json" 2>/dev/null || \
        echo "$metrics" > "${METRICS_DIR}/latest.json"
}
