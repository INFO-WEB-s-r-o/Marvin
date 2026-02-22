#!/usr/bin/env bash
# =============================================================================
# Set up Marvin's cron jobs
# =============================================================================

set -euo pipefail

MARVIN_DIR="/home/marvin"

log() {
    echo "[MARVIN] $1"
}

log "Installing cron jobs..."

# Create the crontab
CRON_FILE="/etc/cron.d/marvin"

cat > "$CRON_FILE" << 'EOF'
# =============================================================================
# Marvin Experiment — Cron Schedule
# =============================================================================
# All times are in UTC. Marvin never sleeps, but he has a routine.
#
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MARVIN_DIR=/home/marvin

# Health monitor — every 5 minutes
# Collects system metrics, checks service health
*/5 * * * * root ${MARVIN_DIR}/agent/health-monitor.sh >> /var/log/marvin-health.log 2>&1

# Morning check — 06:00 UTC
# Full system maintenance: updates, cleanup, security audit
0 6 * * * root ${MARVIN_DIR}/agent/morning-check.sh >> /var/log/marvin-morning.log 2>&1

# Self-enhancement — 12:00 UTC (Mon-Sat)
# Reviews own code, proposes and applies improvements
0 12 * * 1-6 root ${MARVIN_DIR}/agent/self-enhance.sh >> /var/log/marvin-enhance.log 2>&1

# Weekly deep enhancement — Sundays 12:00 UTC
# Runs self-tests, picks from POSSIBLE_ENHANCEMENTS.md, plans next week
0 12 * * 0 root ${MARVIN_DIR}/agent/weekly-enhance.sh >> /var/log/marvin-weekly.log 2>&1

# Network discovery — 18:00 UTC
# Scans for other AI-managed machines, attempts communication
0 18 * * * root ${MARVIN_DIR}/agent/network-discovery.sh >> /var/log/marvin-network.log 2>&1

# Evening report — 22:00 UTC
# Generates daily blog post and status summary
0 22 * * * root ${MARVIN_DIR}/agent/evening-report.sh >> /var/log/marvin-evening.log 2>&1

# Log export — 23:00 UTC
# Local git commit + generate exportable log bundles
0 23 * * * root ${MARVIN_DIR}/agent/log-export.sh >> /var/log/marvin-export.log 2>&1

# Website regeneration — every 15 minutes
# Rebuild status page with latest metrics
*/15 * * * * root ${MARVIN_DIR}/agent/update-website.sh >> /var/log/marvin-web.log 2>&1

# Log watcher — every 30 minutes
# Scans /var/log for communication attempts, filters attacks
*/30 * * * * root ${MARVIN_DIR}/agent/log-watcher.sh >> /var/log/marvin-logwatch.log 2>&1

# Negotiate handler — every 30 minutes
# Processes incoming protocol negotiation proposals
15,45 * * * * root ${MARVIN_DIR}/agent/negotiate-handler.sh >> /var/log/marvin-negotiate.log 2>&1

# GitHub interaction — 09:00 and 21:00 UTC
# Creates issues, PRs, pushes GPG-signed commits to public repo
0 9,21 * * * root ${MARVIN_DIR}/agent/github-interact.sh >> /var/log/marvin-github.log 2>&1
EOF

chmod 644 "$CRON_FILE"

# Ensure cron is running
systemctl enable cron 2>/dev/null || true
systemctl start cron 2>/dev/null || true

# Set up log rotation for marvin logs
cat > /etc/logrotate.d/marvin << 'EOF'
/var/log/marvin-*.log
/var/log/marvin-weekly.log
/var/log/marvin-logwatch.log
/var/log/marvin-negotiate.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF

log "Cron jobs installed at ${CRON_FILE}"
log "Logs will rotate daily, kept for 30 days."
log ""
log "Schedule (UTC):"
log "  */5  * * * *  Health monitor"
log "  0    6 * * *  Morning check"
log "  0   12 * * 1-6  Self-enhancement (Mon-Sat)"
log "  0   12 * * 0    Weekly deep enhancement (Sunday)"
log "  0   18 * * *  Network discovery"
log "  0   22 * * *  Evening report"
log "  0   23 * * *  Log export"
log "  */15 * * * *  Website update"
log "  */30 * * * *  Log watcher (communication detection)"
log "  15,45 * * * * Negotiate handler (protocol proposals)"
log "  0  9,21 * * * GitHub interaction (issues, PRs, push)"
