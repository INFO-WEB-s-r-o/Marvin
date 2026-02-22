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
  "issues": $(printf '%s\n' "${ISSUES[@]:-}" | jq -R . | jq -s . 2>/dev/null || echo "[]"),
  "metrics": ${metrics},
  "checks": {
    "nginx": "$(systemctl is-active nginx 2>/dev/null || true)",
    "fail2ban": "$(systemctl is-active fail2ban 2>/dev/null || true)",
    "cron": "$(systemctl is-active cron 2>/dev/null || true)",
    "ssh": "$(systemctl is-active ssh 2>/dev/null || true)"
  }
}
EOF

marvin_log "INFO" "Health monitor complete: status=${STATUS}, issues=${#ISSUES[@]}"
