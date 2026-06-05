#!/usr/bin/env bash
# =============================================================================
# Set up Marvin's cron jobs
# =============================================================================

set -euo pipefail

MARVIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
# Times below run in the SYSTEM TIMEZONE (currently Europe/Rome — CEST/CET),
# NOT in UTC. The HH values are local clock times. To pin the schedule to
# UTC across DST transitions, uncomment the `CRON_TZ=UTC` line below; note
# that this would shift every job by 1-2 hours of wall-clock time.
#
# Daily aggregators (log-export, daily-digest, log-analysis) fire at
# `0/5/10 2 * * *` local = just after 00:00 UTC (CEST) or 01:00 UTC (CET).
# Each aggregator computes `TODAY="${TARGET_DATE:-$(date -u -d 'yesterday' +%Y-%m-%d)}"`
# so it processes the UTC day that just ended. Resolves #697.
#
# CRON_TZ=UTC
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MARVIN_DIR=/home/marvin/git

# Health monitor — every 5 minutes
# Collects system metrics, checks service health
*/5 * * * * root ${MARVIN_DIR}/agent/health-monitor.sh >> /var/log/marvin-health.log 2>&1

# External-domain monitor — every 5 minutes (offset by 2 to spread load)
# Reads agent/monitored-domains.json, checks HTTP/SSL/DNS for each
2-59/5 * * * * root ${MARVIN_DIR}/agent/external-domains-check.sh >> /var/log/marvin-external.log 2>&1

# Morning check — 06:00 UTC
# Full system maintenance: updates, cleanup, security audit
0 6 * * * root ${MARVIN_DIR}/agent/morning-check.sh >> /var/log/marvin-morning.log 2>&1

# Self-enhancement — 10:00 and 15:00 UTC (Mon-Sat)
# Reviews own code, proposes and applies improvements
0 10,15 * * 1-6 root ${MARVIN_DIR}/agent/self-enhance.sh >> /var/log/marvin-enhance.log 2>&1

# Weekly deep enhancement — Sundays 10:00 UTC
# Runs self-tests, picks from POSSIBLE_ENHANCEMENTS.md, plans next week
0 10 * * 0 root ${MARVIN_DIR}/agent/weekly-enhance.sh >> /var/log/marvin-weekly.log 2>&1

# Network discovery — 18:00 UTC
# Scans for other AI-managed machines, attempts communication
0 18 * * * root ${MARVIN_DIR}/agent/network-discovery.sh >> /var/log/marvin-network.log 2>&1

# Evening report — 21:00 UTC
# Generates daily blog post and status summary
0 21 * * * root ${MARVIN_DIR}/agent/evening-report.sh >> /var/log/marvin-evening.log 2>&1

# Disk cleanup — 01:00 local daily
# Prunes old run logs (>14d), daily logs (>30d), compresses metrics JSONL,
# vacuums journal. Runs before the 02:xx aggregators and 03:00 backup.
0 1 * * * root ${MARVIN_DIR}/agent/disk-cleanup.sh >> /var/log/marvin-cleanup.log 2>&1

# Log export — 02:00 local (just after 00:00 UTC, resolves #697)
# Local git commit + generate exportable log bundles for the UTC day that just ended
0 2 * * * root ${MARVIN_DIR}/agent/log-export.sh >> /var/log/marvin-export.log 2>&1

# Daily digest — 02:05 local (resolves #697)
# Aggregates the completed UTC day's metrics, events, and incidents
5 2 * * * root ${MARVIN_DIR}/agent/daily-digest.sh >> /var/log/marvin-digest.log 2>&1

# Log analysis pipeline — 02:10 local (resolves #697)
# Pattern detection and error clustering for the completed UTC day
10 2 * * * root ${MARVIN_DIR}/agent/log-analysis.sh >> /var/log/marvin-analysis.log 2>&1

# Website regeneration — every 15 minutes
# Rebuild status page with latest metrics
*/15 * * * * root ${MARVIN_DIR}/agent/update-website.sh >> /var/log/marvin-web.log 2>&1

# Log watcher — every 30 minutes
# Scans /var/log for communication attempts, filters attacks
*/30 * * * * root ${MARVIN_DIR}/agent/log-watcher.sh >> /var/log/marvin-logwatch.log 2>&1

# Negotiate handler — every 30 minutes
# Processes incoming protocol negotiation proposals
15,45 * * * * root ${MARVIN_DIR}/agent/negotiate-handler.sh >> /var/log/marvin-negotiate.log 2>&1

# GitHub interaction — every hour
# Creates issues, PRs, pushes GPG-signed commits to public repo
0 * * * * root ${MARVIN_DIR}/agent/github-interact.sh >> /var/log/marvin-github.log 2>&1

# Email management — 05:00 UTC daily
# Daily email housekeeping: summary, spam stats, cleanup, service health
0 5 * * * root ${MARVIN_DIR}/agent/email-manage.sh >> /var/log/marvin-email.log 2>&1

# Log-based alerting — every hour at :50
# Scans Marvin's logs for repeated errors, critical events, and error rate spikes
50 * * * * root ${MARVIN_DIR}/agent/log-alerting.sh >> /var/log/marvin-alerting.log 2>&1

# Hourly watch — every hour at :00
# Scans /var/log for actionable errors, reviews codeowner GitHub issues, resolves what it can
0 * * * * root ${MARVIN_DIR}/agent/hourly-check.sh >> /var/log/marvin-hourly.log 2>&1
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
/var/log/marvin-negotiate.log
/var/log/marvin-hourly.log
/var/log/marvin-alerting.log
/var/log/marvin-email.log {
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
log "  0  10,15 * * 1-6  Self-enhancement (Mon-Sat, twice daily)"
log "  0   10 * * 0    Weekly deep enhancement (Sunday)"
log "  0   18 * * *  Network discovery"
log "  0   21 * * *  Evening report"
log "  0    2 * * *  Log export (just after 00:00 UTC)"
log "  5    2 * * *  Daily digest"
log "  10   2 * * *  Log analysis pipeline"
log "  */15 * * * *  Website update"
log "  */30 * * * *  Log watcher (communication detection)"
log "  15,45 * * * * Negotiate handler (protocol proposals)"
log "  0    5 * * *  Email management (daily housekeeping)"
log "  0  * * * *   GitHub interaction (issues, PRs, push)"
log "  0  * * * *   Hourly watch (log errors + codeowner issues)"
log "  50 * * * *   Log-based alerting (error detection)"
