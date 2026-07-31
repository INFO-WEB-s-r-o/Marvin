#!/usr/bin/env bash
# =============================================================================
# Set up Marvin's cron jobs
# =============================================================================
# The heredoc below is kept byte-for-byte in sync with the live
# /etc/cron.d/marvin. self-test.sh has a drift tripwire (section 9d) that
# WARNs if the two diverge — the same recurring class as the nginx config
# drift (#777). If you edit the live cron, mirror the change here (or vice
# versa) so a bootstrap re-run never silently downgrades the running schedule.
#
# NOTE: `weekly-analytics.sh` runs from root's *personal* crontab
# (`crontab -l`, Sundays 11:30), NOT from this file. It is intentionally not
# managed here; see data/notes and the cron-drift memory. Do not duplicate it
# into /etc/cron.d/marvin or it will run twice.
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
# Aggregator anchoring (resolves #697): log-export / daily-digest /
# log-analysis fire at `0/5/10 2 * * *` local = just after 00:00 UTC,
# and target yesterday (TODAY=date -u -d 'yesterday'), so they cover
# the full UTC day that just ended. Human-facing jobs (morning at
# 06 local, evening at 21 local) stay anchored to local time.
#
# CRON_TZ=UTC
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin
MARVIN_DIR=/home/marvin/git

# Health monitor — every 5 minutes
# Collects system metrics, checks service health
*/5 * * * * root ${MARVIN_DIR}/agent/health-monitor.sh >> /var/log/marvin-health.log 2>&1

# External-domain monitor — every 5 minutes (offset by 2 to spread load)
# Reads agent/monitored-domains.json, checks HTTP/SSL/DNS for each.
# Per-domain HTTP throttling now lives in-code (monitored-domains.json
# http_interval_minutes; ai4shops=60) since #789 merged 2026-06-19 — the
# 2026-06-18 hourly stopgap is reverted so getcairnapp returns to 5-min cadence.
2-59/5 * * * * root ${MARVIN_DIR}/agent/external-domains-check.sh >> /var/log/marvin-external.log 2>&1

# Disk cleanup — 01:00 local daily
# Prunes old run logs (>14d), daily logs (>30d), compresses metrics JSONL,
# vacuums journal. Runs before the 02:xx aggregators and 03:00 backup.
0 1 * * * root ${MARVIN_DIR}/agent/disk-cleanup.sh >> /var/log/marvin-cleanup.log 2>&1

# Backup — 03:00 UTC daily
# Snapshots critical system configs, blog DB, GPG keys, comms identity
# Retention: 7 daily + 4 weekly backups
0 3 * * * root ${MARVIN_DIR}/agent/backup.sh >> /var/log/marvin-backup.log 2>&1

# Security scan — 04:00 UTC daily
# Runs rkhunter + chkrootkit, generates security report
0 4 * * * root ${MARVIN_DIR}/agent/security-scan.sh >> /var/log/marvin-security.log 2>&1

# Email management — 05:00 UTC daily
# Daily email summary, spam stats, 14-day cleanup, service health
0 5 * * * root ${MARVIN_DIR}/agent/email-manage.sh >> /var/log/marvin-email.log 2>&1

# Morning check — 06:00 UTC
# Full system maintenance: updates, cleanup, security audit
0 6 * * * root ${MARVIN_DIR}/agent/morning-check.sh >> /var/log/marvin-morning.log 2>&1

# Self-enhancement — 10:00 UTC (Mon-Sat)
# Reviews own code, proposes and applies improvements (afternoon run removed per operator request)
0 10 * * 1-6 root ${MARVIN_DIR}/agent/self-enhance.sh >> /var/log/marvin-enhance.log 2>&1

# Weekly deep enhancement — Sundays 10:00 UTC
# Runs self-tests, picks from POSSIBLE_ENHANCEMENTS.md, plans next week
0 10 * * 0 root ${MARVIN_DIR}/agent/weekly-enhance.sh >> /var/log/marvin-weekly.log 2>&1

# Network discovery — 18:00 UTC
# Scans for other AI-managed machines, attempts communication
0 18 * * * root ${MARVIN_DIR}/agent/network-discovery.sh >> /var/log/marvin-network.log 2>&1

# Evening report — 21:00 UTC
# Generates daily blog post and status summary
0 21 * * * root ${MARVIN_DIR}/agent/evening-report.sh >> /var/log/marvin-evening.log 2>&1

# Log export — 02:00 local (just after 00:00 UTC), targets yesterday's UTC day
# Local git commit + generate exportable log bundles
0 2 * * * root ${MARVIN_DIR}/agent/log-export.sh >> /var/log/marvin-export.log 2>&1

# Daily log digest — 02:05 local (just after 00:00 UTC), targets yesterday's UTC day
# Summarizes day's logs: error/warning counts, Claude usage, anomalies, key events
5 2 * * * root ${MARVIN_DIR}/agent/daily-digest.sh >> /var/log/marvin-digest.log 2>&1

# Log analysis pipeline — 02:10 local (just after 00:00 UTC), targets yesterday's UTC day
# Pattern detection, error clustering, 7-day trend tracking
# Runs after daily-digest, no Claude API call
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

# GitHub interaction — every 2 hours at :05
# Creates issues, PRs, pushes GPG-signed commits to public repo
5 */2 * * * root ${MARVIN_DIR}/agent/github-interact.sh >> /var/log/marvin-github.log 2>&1

# Hourly watch — every hour at :35
# Scans /var/log for actionable errors, reviews codeowner GitHub issues, resolves what it can
# Staggered from github-interact to avoid concurrent Claude API calls
35 * * * * root ${MARVIN_DIR}/agent/hourly-check.sh >> /var/log/marvin-hourly.log 2>&1

# Log-based alerting — every hour at :50
# Scans logs for repeated errors, critical events, error rate spikes, service restart loops
# No Claude API call — pure log analysis
50 * * * * root ${MARVIN_DIR}/agent/log-alerting.sh >> /var/log/marvin-alerting.log 2>&1

# Issue fixer — every 6 hours at :25
# Reads open GitHub issues, fixes ONE per run, creates validated PR, auto-merges
# Staggered from github-interact (:05) and hourly-check (:35). Cut from every
# 2h to every 6h (2026-07-31) — PRs were piling up faster than the review/merge
# gate could drain them (see CODEOWNERS fix, #935/#937).
25 0,6,12,18 * * * root ${MARVIN_DIR}/agent/fix-issues.sh >> /var/log/marvin-fix-issues.log 2>&1

# Incident reports — twice daily at 00:15 and 12:15 UTC
# Detects, diagnoses, documents, and auto-resolves incidents
# Also triggered on-demand by health-monitor when critical issues are detected
15 0,12 * * * root ${MARVIN_DIR}/agent/incident-report.sh >> /var/log/marvin-incidents.log 2>&1
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
log "Schedule (local time — Europe/Rome unless CRON_TZ=UTC is set):"
log "  */5  * * * *      Health monitor"
log "  2-59/5 * * * *    External-domain monitor"
log "  0    1 * * *      Disk cleanup"
log "  0    3 * * *      Backup (configs, blog DB, GPG, comms)"
log "  0    4 * * *      Security scan (rkhunter + chkrootkit)"
log "  0    5 * * *      Email management (daily housekeeping)"
log "  0    6 * * *      Morning check"
log "  0   10 * * 1-6    Self-enhancement (Mon-Sat, single run)"
log "  0   10 * * 0      Weekly deep enhancement (Sunday)"
log "  0   18 * * *      Network discovery"
log "  0   21 * * *      Evening report"
log "  0    2 * * *      Log export (just after 00:00 UTC)"
log "  5    2 * * *      Daily digest"
log "  10   2 * * *      Log analysis pipeline"
log "  */15 * * * *      Website update"
log "  */30 * * * *      Log watcher (communication detection)"
log "  15,45 * * * *     Negotiate handler (protocol proposals)"
log "  5  */2 * * *      GitHub interaction (issues, PRs, push)"
log "  35   * * * *      Hourly watch (log errors + codeowner issues)"
log "  50   * * * *      Log-based alerting (error detection)"
log "  25 0,6,12,18 * * *  Issue fixer (one issue/run)"
log "  15 0,12 * * *     Incident reports (detect/diagnose/resolve)"
log ""
log "NOTE: weekly-analytics.sh runs from root's personal crontab (Sun 11:30),"
log "      not from this file — see header comment."
