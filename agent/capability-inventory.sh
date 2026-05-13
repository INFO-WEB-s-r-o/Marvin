#!/usr/bin/env bash
# =============================================================================
# Marvin — Capability Inventory
# =============================================================================
# Scans the codebase, cron schedule, and roadmap to produce a structured
# inventory of everything Marvin can do today vs. day 1.
#
# Output: data/codebase/capabilities.json
# Usage: agent/capability-inventory.sh [--dry-run]
# Called from: weekly-enhance.sh, self-enhance.sh, standalone
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR
marvin_parse_args "$@"

marvin_log "INFO" "=== CAPABILITY INVENTORY STARTING ==="

CAP_DIR="${DATA_DIR}/codebase"
marvin_is_dry_run || mkdir -p "$CAP_DIR"
CAP_FILE="${CAP_DIR}/capabilities.json"
AGENT_DIR="${MARVIN_DIR}/agent"
CRON_FILE="/etc/cron.d/marvin"

# ─── 1. Count scripts ────────────────────────────────────────────────────────
total_scripts=0
total_loc=0
while IFS= read -r script; do
    total_scripts=$((total_scripts + 1))
    loc=$(wc -l < "$script" 2>/dev/null || echo 0)
    total_loc=$((total_loc + loc))
done < <(find "$AGENT_DIR" -name "*.sh" -type f 2>/dev/null)

marvin_log "INFO" "Found ${total_scripts} scripts, ${total_loc} total LOC"

# ─── 2. Count cron jobs ──────────────────────────────────────────────────────
cron_jobs=0
cron_entries="[]"
if [[ -f "$CRON_FILE" ]]; then
    cron_entries=$(grep -v '^\s*#' "$CRON_FILE" | grep -v '^\s*$' | grep -v '^[A-Z]' | \
        awk '{
            schedule=$1" "$2" "$3" "$4" "$5
            # Extract script name from path
            for(i=7;i<=NF;i++) {
                if($i ~ /\.sh$/) {
                    n=split($i, parts, "/")
                    script=parts[n]
                    break
                }
            }
            if(script) printf "{\"schedule\":\"%s\",\"script\":\"%s\"}\n", schedule, script
        }' 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")
    cron_jobs=$(echo "$cron_entries" | jq 'length' 2>/dev/null || echo 0)
fi

marvin_log "INFO" "Found ${cron_jobs} cron jobs"

# ─── 3. Categorize capabilities by domain ────────────────────────────────────
# Each capability is a JSON object with: name, category, script, description, since

capabilities="[]"

_add_cap() {
    local name="$1" category="$2" script="$3" desc="$4" since="${5:-unknown}"
    capabilities=$(echo "$capabilities" | jq \
        --arg n "$name" --arg c "$category" --arg s "$script" \
        --arg d "$desc" --arg dt "$since" \
        '. + [{name:$n, category:$c, script:$s, description:$d, since:$dt}]' 2>/dev/null || echo "$capabilities")
}

# System Administration
_add_cap "Health Monitoring"         "sysadmin" "health-monitor.sh"   "5-min metrics collection, service checks, anomaly detection"        "2026-02-23"
_add_cap "Disk Cleanup"              "sysadmin" "disk-cleanup.sh"     "Automated cleanup of old logs, apt cache, temp files"                "2026-02-24"
_add_cap "Morning Maintenance"       "sysadmin" "morning-check.sh"    "Daily git pull, system updates, cron verification"                   "2026-02-23"
_add_cap "Process Watchdog"          "sysadmin" "health-monitor.sh"   "Restarts critical services if down, kills runaway processes"         "2026-02-24"
_add_cap "Swap Management"           "sysadmin" "health-monitor.sh"   "Auto-creates/expands swap under RAM pressure"                       "2026-02-25"
_add_cap "Website Monitoring"        "sysadmin" "health-monitor.sh"   "HTTP checks, blog API validation, JS asset integrity, SSL expiry"   "2026-02-23"
_add_cap "Website Regeneration"      "sysadmin" "update-website.sh"   "15-min dashboard rebuild with latest metrics"                       "2026-02-23"
_add_cap "Email Server Management"   "sysadmin" "email-manage.sh"     "Postfix+Dovecot+Rspamd, daily summary, spam handling, 14-day cleanup" "2026-03-03"

# Security
_add_cap "Security Scanning"         "security" "security-scan.sh"    "rkhunter, chkrootkit, port monitoring, open relay checks"           "2026-02-26"
_add_cap "File Integrity Monitoring" "security" "file-integrity.sh"   "SHA-256 checksums for critical files, change alerting"              "2026-02-28"
_add_cap "CVE Monitoring"            "security" "cve-monitor.sh"      "Tracks vulnerable packages, pending security updates"               "2026-03-02"
_add_cap "Connection Rate Monitoring" "security" "security-scan.sh"   "Per-IP connection rates, flags >50 concurrent"                      "2026-03-21"
_add_cap "Outbound Connection Audit" "security" "security-scan.sh"    "Tracks all outbound connections, flags unusual ports"               "2026-03-23"
_add_cap "Fail2ban Management"       "security" "health-monitor.sh"   "SSH + nginx jails, auto-restart if down"                            "2026-02-24"
_add_cap "Backup System"             "security" "backup.sh"           "Daily compressed snapshots of blog/agent/comms/configs, 7d+4w retention" "2026-04-02"

# Data & Analytics
_add_cap "Metric Aggregation"        "data"     "metric-aggregate.sh" "Hourly/daily/weekly summaries with min/avg/max/p95"                 "2026-03-02"
_add_cap "Anomaly Detection"         "data"     "health-monitor.sh"   "2σ deviation from 7-day rolling average, rate-limited alerts"       "2026-03-09"
_add_cap "Weekly Analytics"          "data"     "weekly-analytics.sh" "Data-driven report: trends, WoW deltas, Claude usage, errors"       "2026-03-10"
_add_cap "Daily Log Digest"          "data"     "daily-digest.sh"     "Structured summary of day's logs, error counts, Claude usage"       "2026-03-13"
_add_cap "Log Analysis Pipeline"     "data"     "log-analysis.sh"     "Error normalization, clustering, 7-day trend tracking"              "2026-03-25"
_add_cap "Log Export API"            "data"     "log-export.sh"       "Daily JSON bundles with gzip, API key auth, webhook notifications"  "2026-02-27"
_add_cap "Log-Based Alerting"        "data"     "log-alerting.sh"     "Hourly scan for repeated errors, rate spikes, restart loops"        "2026-03-14"
_add_cap "SLA Tracking"              "data"     "metric-aggregate.sh" "Daily uptime %, 30-day rolling window"                              "2026-03-05"
_add_cap "Resource Forecasting"      "data"     "metric-aggregate.sh" "Linear regression predicts disk/memory exhaustion"                  "2026-03-20"
_add_cap "Claude API Usage Tracking" "data"     "common.sh"           "Per-task duration, prompt/output chars, exit codes in JSONL"        "2026-03-07"
_add_cap "Export Push Client"        "data"     "export-push.sh"      "POSTs daily bundles to configured endpoints with SSRF protection"   "2026-04-04"

# Network & Communication
_add_cap "Network Discovery"         "network"  "network-discovery.sh" "Scans for AI-managed servers, probes .well-known endpoints"        "2026-02-23"
_add_cap "DNS Resolution Monitoring" "network"  "health-monitor.sh"   "Verifies domain resolves correctly via Google DNS"                  "2026-03-13"
_add_cap "Latency Monitoring"        "network"  "health-monitor.sh"   "ICMP ping + HTTPS response time, JSONL trending"                   "2026-03-13"
_add_cap "Bandwidth Monitoring"      "network"  "health-monitor.sh"   "rx/tx bytes per interface, network I/O anomaly detection"           "2026-03-10"
_add_cap "Protocol Negotiation"      "network"  "negotiate-handler.sh" "POST endpoint, Claude-powered analysis, rate limiting"             "2026-02-23"
_add_cap "Log Watcher"               "network"  "log-watcher.sh"      "Scans /var/log for communication attempts, filters attacks"         "2026-02-23"
_add_cap "GPG Identity & Signing"    "network"  "lib/github.sh"       "RSA 4096 key, signed commits/issues, public key serving"           "2026-01-30"
_add_cap "Negotiate Inbox Listener"  "network"  "negotiate-listener.sh" "HTTP listener on port 8043 accepting POST negotiations from nginx" "2026-02-22"
_add_cap "External Domain Monitoring" "network" "external-domains-check.sh" "Tracks HTTP/SSL/DNS health of monitored external domains, 5-min cadence" "2026-05-01"

# Self-Evolution
_add_cap "Self-Enhancement"          "evolution" "self-enhance.sh"    "Reviews and modifies own code, max 3 changes per session"           "2026-02-23"
_add_cap "Weekly Deep Enhancement"   "evolution" "weekly-enhance.sh"  "Sunday deep session: self-tests, picks roadmap items"               "2026-02-23"
_add_cap "GitHub Interaction"        "evolution" "github-interact.sh" "Autonomous issues, PRs, GPG-signed commits, auto-merge"            "2026-01-30"
_add_cap "Issue Auto-Fixer"          "evolution" "fix-issues.sh"      "Reads open issues, creates validated PRs, attempts auto-merge"     "2026-02-28"
_add_cap "Self-Testing"              "evolution" "self-test.sh"       "34 automated checks: syntax, JSON, services, metrics, grade A-F"   "2026-02-23"
_add_cap "Codebase Health Score"     "evolution" "codebase-health.sh" "4-dimension scoring: quality, hygiene, ops, evolution (A-F)"        "2026-03-26"
_add_cap "Enhancement Tracker"       "evolution" "enhancement-tracker.sh" "Session counts, success/rollback rate, weekly trends"           "2026-03-26"
_add_cap "Lessons Learned"           "evolution" "lessons-learned.sh" "Codified lessons + anti-patterns, auto-detected from error logs"    "2026-03-27"
_add_cap "Capability Inventory"      "evolution" "capability-inventory.sh" "This script — tracks what Marvin can do today"                 "2026-03-28"
_add_cap "Incident Reports"          "evolution" "incident-report.sh"  "Auto-detects, diagnoses, documents, and resolves incidents (7 types)" "2026-03-30"
_add_cap "Zero-Downtime Web Deploy"  "evolution" "deploy-web.sh"       "npm ci+build+restart with backup/rollback and JS asset healthcheck" "2026-04-01"

# Content
_add_cap "Evening Blog Post"         "content"  "evening-report.sh"   "Bilingual (EN/CS) daily blog posts"                                "2026-02-23"
_add_cap "Hourly Watch"              "content"  "hourly-check.sh"     "Scans logs for actionable errors, reviews GitHub issues"            "2026-02-27"
_add_cap "Public Changelog Feed"     "content"  "changelog-gen.sh"    "Generates /api/changelog.json from enhancement reports for dashboard timeline" "2026-04-03"
_add_cap "Thoughts Extractor"        "content"  "thoughts-extract.sh" "Pulls reflections/intentions from enhancement reports for dashboard" "2026-04-07"

# ─── 4. Roadmap progress ─────────────────────────────────────────────────────
roadmap_total=0
roadmap_done=0
if [[ -f "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" ]]; then
    # grep-c-double-output lesson: `grep -c X 2>/dev/null || echo 0` writes "0\n0"
    # on a zero-match file (grep prints "0" then exits 1). Downstream arithmetic
    # on line 134 (`roadmap_done * 100 / roadmap_total`) would crash on the
    # multi-line value. Capture-then-fallback keeps grep's count, swallows
    # only the exit code.
    roadmap_total=$(grep -cP '^\s*- \[[ x]\]' "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" 2>/dev/null || true)
    roadmap_total="${roadmap_total:-0}"
    roadmap_done=$(grep -cP '^\s*- \[x\]' "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" 2>/dev/null || true)
    roadmap_done="${roadmap_done:-0}"
fi
roadmap_pct=0
[[ "$roadmap_total" -gt 0 ]] && roadmap_pct=$((roadmap_done * 100 / roadmap_total))

# ─── 5. Day-1 baseline (hardcoded from initial deploy) ───────────────────────
# On day 1 (2026-02-22), Marvin had: common.sh, health-monitor.sh, morning-check.sh,
# evening-report.sh, self-enhance.sh, update-website.sh — 6 scripts, ~600 LOC
day1_scripts=6
day1_loc=600
day1_capabilities=5  # health, morning, blog, self-enhance, website

cap_count=$(echo "$capabilities" | jq 'length' 2>/dev/null || echo 0)

# ─── 6. Category summary ─────────────────────────────────────────────────────
categories=$(echo "$capabilities" | jq '
    group_by(.category) | map({
        category: .[0].category,
        count: length,
        items: [.[].name]
    }) | sort_by(.category)
' 2>/dev/null || echo "[]")

# ─── 7. Write output ─────────────────────────────────────────────────────────
output=$(jq -n \
    --arg ts "$NOW" \
    --argjson caps "$capabilities" \
    --argjson cats "$categories" \
    --argjson cron "$cron_entries" \
    --argjson total_scripts "$total_scripts" \
    --argjson total_loc "$total_loc" \
    --argjson cron_jobs "$cron_jobs" \
    --argjson cap_count "$cap_count" \
    --argjson day1_scripts "$day1_scripts" \
    --argjson day1_loc "$day1_loc" \
    --argjson day1_caps "$day1_capabilities" \
    --argjson roadmap_total "$roadmap_total" \
    --argjson roadmap_done "$roadmap_done" \
    --argjson roadmap_pct "$roadmap_pct" \
    '{
        generated: $ts,
        summary: {
            total_capabilities: $cap_count,
            total_scripts: $total_scripts,
            total_loc: $total_loc,
            cron_jobs: $cron_jobs,
            roadmap: {total: $roadmap_total, done: $roadmap_done, percent: $roadmap_pct}
        },
        growth: {
            day1: {scripts: $day1_scripts, loc: $day1_loc, capabilities: $day1_caps},
            today: {scripts: $total_scripts, loc: $total_loc, capabilities: $cap_count},
            multiplier: {
                scripts: (if $day1_scripts > 0 then ($total_scripts / $day1_scripts * 10 | round / 10) else null end),
                loc: (if $day1_loc > 0 then ($total_loc / $day1_loc * 10 | round / 10) else null end),
                capabilities: (if $day1_caps > 0 then ($cap_count / $day1_caps * 10 | round / 10) else null end)
            }
        },
        categories: $cats,
        capabilities: $caps,
        cron_schedule: $cron
    }')

if marvin_is_dry_run; then
    marvin_log "INFO" "[DRY-RUN] Would write capabilities.json (${cap_count} capabilities)"
    echo "$output" | jq '.summary'
else
    echo "$output" | jq '.' > "$CAP_FILE"
    marvin_log "INFO" "Wrote ${CAP_FILE}: ${cap_count} capabilities"
fi

# ─── 8. Summary ──────────────────────────────────────────────────────────────
marvin_log "INFO" "Capability inventory: ${cap_count} capabilities across $(echo "$categories" | jq 'length') categories"
marvin_log "INFO" "Growth since day 1: scripts ${day1_scripts}→${total_scripts}, LOC ${day1_loc}→${total_loc}, capabilities ${day1_capabilities}→${cap_count}"
marvin_log "INFO" "Roadmap: ${roadmap_done}/${roadmap_total} (${roadmap_pct}%)"
marvin_log "INFO" "=== CAPABILITY INVENTORY COMPLETE ==="
