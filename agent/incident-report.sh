#!/usr/bin/env bash
# =============================================================================
# Marvin — Automated Incident Reports
# =============================================================================
# Detects, diagnoses, documents, and tracks incidents automatically.
# Triggered by health-monitor.sh when critical issues are found, and also
# runs on a schedule to finalize/close incidents from the past 24 hours.
#
# No Claude API call — pure log/metric analysis with jq.
#
# Modes:
#   --detect   Scan for new incidents (called by health-monitor or cron)
#   --close    Auto-close resolved incidents older than 4 hours
#   --summary  Generate incidents summary for dashboard
#
# Cron: twice daily (12:15 UTC after self-enhance, 00:15 UTC after midnight)
#   With --detect --close --summary flags
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

INCIDENTS_DIR="${DATA_DIR}/incidents"
ACTIVE_FILE="${INCIDENTS_DIR}/active-incidents.json"
LOCK_FILE="${INCIDENTS_DIR}/.active-incidents.lock"
HISTORY_DIR="${INCIDENTS_DIR}/history"
SUMMARY_FILE="${INCIDENTS_DIR}/summary.json"

mkdir -p "$INCIDENTS_DIR" "$HISTORY_DIR"

# Initialize active incidents file if missing
if [[ ! -f "$ACTIVE_FILE" ]]; then
    echo '{"incidents":[]}' > "$ACTIVE_FILE"
fi

# ─── Parse arguments ─────────────────────────────────────────────────────────
DO_DETECT=false
DO_CLOSE=false
DO_SUMMARY=false

for arg in "$@"; do
    case "$arg" in
        --detect)  DO_DETECT=true ;;
        --close)   DO_CLOSE=true ;;
        --summary) DO_SUMMARY=true ;;
        --dry-run) MARVIN_DRY_RUN=true; export MARVIN_DRY_RUN ;;
    esac
done

# Default: do all if no flags specified
if [[ "$DO_DETECT" == "false" && "$DO_CLOSE" == "false" && "$DO_SUMMARY" == "false" ]]; then
    DO_DETECT=true
    DO_CLOSE=true
    DO_SUMMARY=true
fi

marvin_log "INFO" "Incident report starting (detect=${DO_DETECT}, close=${DO_CLOSE}, summary=${DO_SUMMARY})"

# ─── Helper: generate incident ID ────────────────────────────────────────────
_incident_id() {
    local type="$1"
    echo "INC-${TODAY//-/}-${type}-$(date +%s | tail -c 5)-$$"
}

# ─── Helper: check if an active incident already exists for a given type ──────
_has_active_incident() {
    local type="$1"
    jq -e --arg t "$type" '.incidents[] | select(.type == $t and .status == "active")' \
        "$ACTIVE_FILE" &>/dev/null
}

# ─── Helper: create an incident ──────────────────────────────────────────────
_create_incident() {
    local id="$1" severity="$2" type="$3" title="$4" detail="$5"

    if [[ "${MARVIN_DRY_RUN:-false}" == "true" ]]; then
        marvin_log "INFO" "[DRY RUN] Would create incident: ${id} [${severity}] ${title}"
        return 0
    fi

    local incident
    incident=$(jq -nc \
        --arg id "$id" \
        --arg sev "$severity" \
        --arg type "$type" \
        --arg title "$title" \
        --arg detail "$detail" \
        --arg opened "$NOW" \
        --arg status "active" \
        '{
            id: $id,
            severity: $sev,
            type: $type,
            title: $title,
            detail: $detail,
            opened_at: $opened,
            status: $status,
            timeline: [{timestamp: $opened, event: ("Incident detected: " + $title)}],
            resolved_at: null,
            resolution: null,
            duration_minutes: null
        }')

    # Append to active incidents (flock to prevent concurrent write races)
    (
        flock -w 10 200 || { marvin_log "WARN" "Failed to acquire lock for incident create"; exit 1; }
        jq --argjson inc "$incident" '.incidents += [$inc]' "$ACTIVE_FILE" \
            > "${ACTIVE_FILE}.tmp" && mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
    ) 200>"$LOCK_FILE" || { marvin_log "WARN" "Incident create failed (lock timeout): ${id}"; return 1; }

    marvin_log "WARN" "INCIDENT OPENED: ${id} [${severity}] ${title}"

    # Write individual incident file
    echo "$incident" | jq '.' > "${HISTORY_DIR}/${id}.json"
}

# ─── Helper: add timeline event to an incident ───────────────────────────────
_add_timeline() {
    local type="$1" event="$2"
    local ts="$NOW"
    (
        flock -w 10 200 || { marvin_log "WARN" "Failed to acquire lock for timeline update"; exit 1; }
        jq --arg t "$type" --arg ts "$ts" --arg ev "$event" \
            '(.incidents[] | select(.type == $t and .status == "active") | .timeline) += [{timestamp: $ts, event: $ev}]' \
            "$ACTIVE_FILE" > "${ACTIVE_FILE}.tmp" && mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
    ) 200>"$LOCK_FILE" || marvin_log "WARN" "Timeline update failed (lock timeout): ${type}"
}

# ─── DETECT: Scan for new incidents ──────────────────────────────────────────
if [[ "$DO_DETECT" == "true" ]]; then
    marvin_log "INFO" "Scanning for incidents..."

    LOG_FILE="${LOGS_DIR}/${TODAY}.log"
    STATUS_FILE="${DATA_DIR}/status.json"
    ALERTS_FILE="${DATA_DIR}/alerts/active-alerts.json"

    # --- 1. Service down incidents ---
    for svc in nginx fail2ban cron marvin-web; do
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            if ! _has_active_incident "service-down-${svc}"; then
                _create_incident \
                    "$(_incident_id "svc-${svc}")" \
                    "critical" \
                    "service-down-${svc}" \
                    "Service ${svc} is down" \
                    "systemctl reports ${svc} as inactive/failed"
            fi
        else
            # Service is up — if there's an active incident for it, add recovery event
            if _has_active_incident "service-down-${svc}"; then
                _add_timeline "service-down-${svc}" "Service ${svc} recovered (now active)"
            fi
        fi
    done

    # --- 2. Disk critical (>95%) ---
    if [[ -f "$STATUS_FILE" ]]; then
        disk_pct=$(jq -r '.metrics.disk.percent // "0%"' "$STATUS_FILE" 2>/dev/null | tr -d '%')
        if [[ "${disk_pct:-0}" -gt 95 ]]; then
            if ! _has_active_incident "disk-critical"; then
                _create_incident \
                    "$(_incident_id "disk")" \
                    "critical" \
                    "disk-critical" \
                    "Disk usage critical at ${disk_pct}%" \
                    "Root filesystem at ${disk_pct}%. Threshold: 95%."
            fi
        fi
    fi

    # --- 3. SSL certificate expiring soon (<7 days) ---
    if [[ -f "$STATUS_FILE" ]]; then
        ssl_days=$(jq -r '.checks.ssl_min_days // 999' "$STATUS_FILE" 2>/dev/null)
        if [[ "${ssl_days:-999}" -lt 7 ]]; then
            if ! _has_active_incident "ssl-expiring"; then
                _create_incident \
                    "$(_incident_id "ssl")" \
                    "critical" \
                    "ssl-expiring" \
                    "SSL certificate expires in ${ssl_days} days" \
                    "Minimum certificate expiry across all services: ${ssl_days} days"
            fi
        fi
    fi

    # --- 4. Website down ---
    if [[ -f "$STATUS_FILE" ]]; then
        site_status=$(jq -r '.checks.website // "ok"' "$STATUS_FILE" 2>/dev/null)
        if [[ "$site_status" == "failing" ]]; then
            if ! _has_active_incident "website-down"; then
                http_code=$(jq -r '.checks.website_http // "000"' "$STATUS_FILE" 2>/dev/null)
                _create_incident \
                    "$(_incident_id "web")" \
                    "critical" \
                    "website-down" \
                    "Website is not responding correctly (HTTP ${http_code})" \
                    "Health check reports website as failing. HTTP status: ${http_code}"
            fi
        else
            if _has_active_incident "website-down"; then
                _add_timeline "website-down" "Website recovered (status: ok)"
            fi
        fi
    fi

    # --- 5. DNS resolution failure ---
    if [[ -f "$STATUS_FILE" ]]; then
        dns_status=$(jq -r '.checks.dns // "ok"' "$STATUS_FILE" 2>/dev/null)
        if [[ "$dns_status" == "failing" ]]; then
            if ! _has_active_incident "dns-failure"; then
                _create_incident \
                    "$(_incident_id "dns")" \
                    "critical" \
                    "dns-failure" \
                    "DNS resolution failing for robot-marvin.cz" \
                    "External DNS query returned incorrect or empty result"
            fi
        fi
    fi

    # --- 6. Repeated errors from log-alerting ---
    if [[ -f "$ALERTS_FILE" ]]; then
        critical_alert_count=$(jq '[.alerts[] | select(.severity == "critical")] | length' "$ALERTS_FILE" 2>/dev/null || echo 0)
        if [[ "${critical_alert_count:-0}" -gt 0 ]]; then
            if ! _has_active_incident "alert-escalation"; then
                alert_titles=$(jq -r '[.alerts[] | select(.severity == "critical") | .title] | join(", ")' "$ALERTS_FILE" 2>/dev/null || echo "unknown")
                _create_incident \
                    "$(_incident_id "alert")" \
                    "high" \
                    "alert-escalation" \
                    "Critical alerts escalated: ${alert_titles}" \
                    "log-alerting.sh detected ${critical_alert_count} critical alert(s)"
            fi
        else
            # No critical alerts — if there was an escalation incident, note recovery
            if _has_active_incident "alert-escalation"; then
                _add_timeline "alert-escalation" "All critical alerts resolved"
            fi
        fi
    fi

    # --- 7. High error rate in today's logs ---
    if [[ -f "$LOG_FILE" ]]; then
        total_lines=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')
        error_lines=$(grep -Ec '\[ERROR\]|\[CRITICAL\]' "$LOG_FILE" 2>/dev/null || true)
        total_lines="${total_lines:-0}"
        error_lines="${error_lines:-0}"
        if [[ "$total_lines" -gt 100 ]]; then
            error_rate=$((error_lines * 100 / total_lines))
            if [[ "$error_rate" -gt 10 ]]; then
                if ! _has_active_incident "high-error-rate"; then
                    _create_incident \
                        "$(_incident_id "errrate")" \
                        "high" \
                        "high-error-rate" \
                        "Error rate at ${error_rate}% (${error_lines}/${total_lines} lines)" \
                        "Error/critical lines exceed 10% of total log output"
                fi
            fi
        fi
    fi

    active_count=$(jq '.incidents | length' "$ACTIVE_FILE" 2>/dev/null || echo 0)
    marvin_log "INFO" "Incident detection complete: ${active_count} active incident(s)"
fi

# ─── CLOSE: Auto-resolve incidents that are no longer active ─────────────────
if [[ "$DO_CLOSE" == "true" ]]; then
    marvin_log "INFO" "Checking for resolvable incidents..."

    now_epoch=$(date +%s)
    resolved_count=0

    # Iterate over active incidents by extracting their IDs first, then lookup by ID
    # (fixes bug where positional indices skipped incidents after resolved ones)
    mapfile -t active_ids < <(jq -r '[.incidents[] | select(.status == "active")] | .[].id' "$ACTIVE_FILE" 2>/dev/null)

    for inc_id in "${active_ids[@]}"; do
        [[ -z "$inc_id" ]] && continue
        inc_type=$(jq -r --arg id "$inc_id" '.incidents[] | select(.id == $id) | .type // empty' "$ACTIVE_FILE" 2>/dev/null || echo "")
        inc_status=$(jq -r --arg id "$inc_id" '.incidents[] | select(.id == $id) | .status // empty' "$ACTIVE_FILE" 2>/dev/null || echo "")
        inc_opened=$(jq -r --arg id "$inc_id" '.incidents[] | select(.id == $id) | .opened_at // empty' "$ACTIVE_FILE" 2>/dev/null || echo "")

        [[ -z "$inc_type" ]] && continue

        # Determine if incident should be auto-resolved
        should_resolve=false
        resolution=""

        case "$inc_type" in
            service-down-*)
                svc="${inc_type#service-down-}"
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    should_resolve=true
                    resolution="Service ${svc} recovered automatically"
                fi
                ;;
            disk-critical)
                disk_pct=$(df / --output=pcent | tail -1 | tr -d ' %')
                if [[ "${disk_pct:-100}" -le 95 ]]; then
                    should_resolve=true
                    resolution="Disk usage dropped to ${disk_pct}%"
                fi
                ;;
            ssl-expiring)
                ssl_days=$(jq -r '.checks.ssl_min_days // 999' "${DATA_DIR}/status.json" 2>/dev/null)
                if [[ "${ssl_days:-0}" -ge 7 ]]; then
                    should_resolve=true
                    resolution="SSL certificates renewed (${ssl_days} days remaining)"
                fi
                ;;
            website-down)
                http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "https://robot-marvin.cz/" 2>/dev/null || echo "000")
                if [[ "$http_code" == "200" ]]; then
                    should_resolve=true
                    resolution="Website responding with HTTP 200"
                fi
                ;;
            dns-failure)
                resolved_ip=$(dig +short robot-marvin.cz A @8.8.8.8 2>/dev/null | tail -1 || echo "")
                expected_ip=$(jq -r '.checks.dns_expected_ip // "80.211.223.26"' "${DATA_DIR}/status.json" 2>/dev/null || echo "80.211.223.26")
                if [[ "$resolved_ip" == "$expected_ip" ]]; then
                    should_resolve=true
                    resolution="DNS resolution restored to correct IP"
                fi
                ;;
            alert-escalation)
                crit_count=$(jq '[.alerts[] | select(.severity == "critical")] | length' \
                    "${DATA_DIR}/alerts/active-alerts.json" 2>/dev/null || echo 0)
                if [[ "${crit_count:-0}" -eq 0 ]]; then
                    should_resolve=true
                    resolution="All critical alerts cleared"
                fi
                ;;
            high-error-rate)
                # Auto-close after 4 hours — error rate is a daily aggregate metric that
                # resets with each new log file. This is a staleness timeout, not a
                # confirmation that the error rate has dropped.
                opened_epoch=$(date -d "$inc_opened" +%s 2>/dev/null || echo "$now_epoch")
                age_hours=$(( (now_epoch - opened_epoch) / 3600 ))
                if [[ "$age_hours" -ge 4 ]]; then
                    should_resolve=true
                    resolution="Staleness timeout after ${age_hours} hours — error rate is a daily metric; new incidents will open if rate remains elevated"
                fi
                ;;
        esac

        if [[ "$should_resolve" == "true" ]]; then
            if [[ "${MARVIN_DRY_RUN:-false}" == "true" ]]; then
                marvin_log "INFO" "[DRY RUN] Would resolve incident: ${inc_id} — ${resolution}"
                resolved_count=$((resolved_count + 1))
                continue
            fi
            # Calculate duration
            opened_epoch=$(date -d "$inc_opened" +%s 2>/dev/null || echo "$now_epoch")
            duration_min=$(( (now_epoch - opened_epoch) / 60 ))

            # Update the incident (flock to prevent concurrent write races)
            (
                flock -w 10 200 || { marvin_log "WARN" "Failed to acquire lock for incident resolve"; exit 1; }
                jq --arg id "$inc_id" --arg res "$resolution" --arg ts "$NOW" --argjson dur "$duration_min" \
                    '(.incidents[] | select(.id == $id)) |= (
                        .status = "resolved" |
                        .resolved_at = $ts |
                        .resolution = $res |
                        .duration_minutes = $dur |
                        .timeline += [{timestamp: $ts, event: ("Resolved: " + $res)}]
                    )' "$ACTIVE_FILE" > "${ACTIVE_FILE}.tmp" && mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
            ) 200>"$LOCK_FILE" || { marvin_log "WARN" "Incident resolve failed (lock timeout): ${inc_id}"; continue; }

            # Update individual history file
            if [[ -f "${HISTORY_DIR}/${inc_id}.json" ]]; then
                jq --arg res "$resolution" --arg ts "$NOW" --argjson dur "$duration_min" \
                    '.status = "resolved" | .resolved_at = $ts | .resolution = $res | .duration_minutes = $dur |
                     .timeline += [{timestamp: $ts, event: ("Resolved: " + $res)}]' \
                    "${HISTORY_DIR}/${inc_id}.json" > "${HISTORY_DIR}/${inc_id}.json.tmp" \
                    && mv "${HISTORY_DIR}/${inc_id}.json.tmp" "${HISTORY_DIR}/${inc_id}.json"
            fi

            marvin_log "INFO" "INCIDENT RESOLVED: ${inc_id} — ${resolution} (${duration_min}min)"
            resolved_count=$((resolved_count + 1))
        fi
    done

    # Archive incidents older than 7 days (resolved by resolved_at, active by opened_at)
    # This prevents stale active incidents from accumulating indefinitely (#361)
    week_ago=$(date -u -d "${TODAY} - 7 days" +%Y-%m-%dT00:00:00Z 2>/dev/null || echo "")
    if [[ -n "$week_ago" ]]; then
        (
            flock -w 10 200 || { marvin_log "WARN" "Failed to acquire lock for archive cleanup"; exit 1; }
            jq --arg cutoff "$week_ago" \
                '.incidents |= [.[] | select(
                    (.status == "active" and .opened_at > $cutoff) or
                    (.status != "active" and .resolved_at > $cutoff)
                )]' \
                "$ACTIVE_FILE" > "${ACTIVE_FILE}.tmp" && mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
        ) 200>"$LOCK_FILE" || marvin_log "WARN" "Archive cleanup failed (lock timeout)"
    fi

    marvin_log "INFO" "Incident closure check complete: ${resolved_count} resolved"
fi

# ─── SUMMARY: Generate dashboard-friendly summary ────────────────────────────
if [[ "$DO_SUMMARY" == "true" ]]; then
    active_incidents=$(jq '[.incidents[] | select(.status == "active")]' "$ACTIVE_FILE" 2>/dev/null || echo '[]')
    active_count=$(echo "$active_incidents" | jq 'length' 2>/dev/null || echo 0)
    active_critical=$(echo "$active_incidents" | jq '[.[] | select(.severity == "critical")] | length' 2>/dev/null || echo 0)

    # Count resolved incidents from history (last 30 days only)
    resolved_30d=0
    total_duration=0
    cutoff_30d=$(date -u -d "${TODAY} - 30 days" +%Y%m%d 2>/dev/null || echo "00000000")
    for f in "${HISTORY_DIR}"/INC-*.json; do
        [[ -f "$f" ]] || continue
        # Extract date from filename (INC-YYYYMMDD-...) to filter by age
        fname=$(basename "$f")
        file_date="${fname:4:8}"
        [[ "$file_date" < "$cutoff_30d" ]] && continue
        status=$(jq -r '.status // empty' "$f" 2>/dev/null || echo "")
        if [[ "$status" == "resolved" ]]; then
            resolved_30d=$((resolved_30d + 1))
            dur=$(jq -r '.duration_minutes // 0' "$f" 2>/dev/null || echo 0)
            total_duration=$((total_duration + dur))
        fi
    done

    avg_resolution=0
    if [[ "$resolved_30d" -gt 0 ]]; then
        avg_resolution=$((total_duration / resolved_30d))
    fi

    jq -nc \
        --arg ts "$NOW" \
        --argjson active "$active_count" \
        --argjson critical "$active_critical" \
        --argjson resolved "$resolved_30d" \
        --argjson avg_min "$avg_resolution" \
        --argjson incidents "$active_incidents" \
        '{
            timestamp: $ts,
            active_incidents: $active,
            critical_incidents: $critical,
            resolved_last_30d: $resolved,
            avg_resolution_minutes: $avg_min,
            incidents: $incidents
        }' > "$SUMMARY_FILE"

    marvin_log "INFO" "Incident summary updated: ${active_count} active, ${resolved_30d} resolved (30d), avg ${avg_resolution}min MTTR"
fi

marvin_log "INFO" "Incident report complete"
