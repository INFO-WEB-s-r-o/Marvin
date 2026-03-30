#!/usr/bin/env bash
# =============================================================================
# Marvin — Automated Incident Reports
# =============================================================================
# Detects, diagnoses, documents, and tracks incidents automatically.
# Scans health status, active alerts, service state, and log patterns.
# Auto-resolves incidents when conditions clear.
#
# No Claude API call — pure log/metric analysis with jq.
#
# Modes:
#   --detect   Scan for new incidents (default if no flags)
#   --close    Auto-resolve incidents where conditions cleared
#   --summary  Generate dashboard-friendly summary
#
# Cron: twice daily (00:15 and 12:15 UTC)
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

INCIDENTS_DIR="${DATA_DIR}/incidents"
ACTIVE_FILE="${INCIDENTS_DIR}/active-incidents.json"
LOCK_FILE="${INCIDENTS_DIR}/.lock"
HISTORY_DIR="${INCIDENTS_DIR}/history"
SUMMARY_FILE="${INCIDENTS_DIR}/summary.json"

mkdir -p "$INCIDENTS_DIR" "$HISTORY_DIR"

# Initialize active incidents file if missing or corrupt
if [[ ! -f "$ACTIVE_FILE" ]] || ! jq empty "$ACTIVE_FILE" 2>/dev/null; then
    echo '{"incidents":[]}' > "$ACTIVE_FILE"
fi

# ─── Parse arguments ─────────────────────────────────────────────────────────
DO_DETECT=false
DO_CLOSE=false
DO_SUMMARY=false

marvin_parse_args "$@"

for arg in "$@"; do
    case "$arg" in
        --detect)  DO_DETECT=true ;;
        --close)   DO_CLOSE=true ;;
        --summary) DO_SUMMARY=true ;;
    esac
done

# Default: do all if no flags specified
if [[ "$DO_DETECT" == "false" && "$DO_CLOSE" == "false" && "$DO_SUMMARY" == "false" ]]; then
    DO_DETECT=true
    DO_CLOSE=true
    DO_SUMMARY=true
fi

marvin_log_json "INFO" "incident-report" "Starting (detect=${DO_DETECT}, close=${DO_CLOSE}, summary=${DO_SUMMARY})"

# ─── Helpers ─────────────────────────────────────────────────────────────────

_incident_id() {
    local type="$1"
    echo "INC-${TODAY//-/}-${type}-$(date +%s | tail -c 5)"
}

_has_active_incident() {
    local type="$1"
    jq -e --arg t "$type" '.incidents[] | select(.type == $t and .status == "active")' \
        "$ACTIVE_FILE" &>/dev/null
}

_create_incident() {
    local id="$1" severity="$2" type="$3" title="$4" detail="$5"

    if marvin_is_dry_run; then
        marvin_log "INFO" "[DRY-RUN] Would create incident: ${id} [${severity}] ${title}"
        return 0
    fi

    local incident
    incident=$(jq -nc \
        --arg id "$id" --arg sev "$severity" --arg type "$type" \
        --arg title "$title" --arg detail "$detail" --arg ts "$NOW" \
        '{id:$id, severity:$sev, type:$type, title:$title, detail:$detail,
          opened_at:$ts, status:"active", resolved_at:null, resolution:null}')

    # Append with file lock to prevent concurrent write races
    (
        flock -w 10 200 || { marvin_log "WARN" "Lock timeout on incident create"; return 1; }
        jq --argjson inc "$incident" '.incidents += [$inc]' "$ACTIVE_FILE" \
            > "${ACTIVE_FILE}.tmp" && mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
    ) 200>"$LOCK_FILE"

    marvin_log "WARN" "INCIDENT OPENED: ${id} [${severity}] ${title}"
    echo "$incident" | jq '.' > "${HISTORY_DIR}/${id}.json" 2>/dev/null || true
}

# ─── DETECT ──────────────────────────────────────────────────────────────────
if [[ "$DO_DETECT" == "true" ]]; then
    marvin_log "INFO" "Scanning for incidents..."

    STATUS_FILE="${DATA_DIR}/status.json"
    ALERTS_FILE="${DATA_DIR}/alerts/active-alerts.json"
    LOG_FILE="${LOGS_DIR}/${TODAY}.log"

    # 1. Service down detection
    for svc in nginx fail2ban cron marvin-web; do
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            if ! _has_active_incident "service-down-${svc}"; then
                _create_incident "$(_incident_id "svc-${svc}")" "critical" \
                    "service-down-${svc}" "Service ${svc} is down" \
                    "systemctl reports ${svc} as inactive/failed"
            fi
        fi
    done

    # 2. Disk critical (>95%)
    if [[ -f "$STATUS_FILE" ]]; then
        disk_pct=$(jq -r '.metrics.disk.percent // "0%"' "$STATUS_FILE" 2>/dev/null | tr -d '%')
        if [[ "${disk_pct:-0}" -gt 95 ]]; then
            if ! _has_active_incident "disk-critical"; then
                _create_incident "$(_incident_id "disk")" "critical" \
                    "disk-critical" "Disk usage critical at ${disk_pct}%" \
                    "Root filesystem at ${disk_pct}%. Threshold: 95%."
            fi
        fi
    fi

    # 3. SSL certificate expiring (<7 days)
    if [[ -f "$STATUS_FILE" ]]; then
        ssl_days=$(jq -r '.checks.ssl_min_days // 999' "$STATUS_FILE" 2>/dev/null)
        if [[ "${ssl_days:-999}" -lt 7 ]]; then
            if ! _has_active_incident "ssl-expiring"; then
                _create_incident "$(_incident_id "ssl")" "critical" \
                    "ssl-expiring" "SSL certificate expires in ${ssl_days} days" \
                    "Minimum certificate expiry across all services: ${ssl_days} days"
            fi
        fi
    fi

    # 4. Website down
    if [[ -f "$STATUS_FILE" ]]; then
        site_status=$(jq -r '.checks.website // "ok"' "$STATUS_FILE" 2>/dev/null)
        if [[ "$site_status" == "failing" ]]; then
            if ! _has_active_incident "website-down"; then
                http_code=$(jq -r '.checks.website_http // "000"' "$STATUS_FILE" 2>/dev/null)
                _create_incident "$(_incident_id "web")" "critical" \
                    "website-down" "Website not responding (HTTP ${http_code})" \
                    "Health check reports website as failing"
            fi
        fi
    fi

    # 5. DNS resolution failure
    if [[ -f "$STATUS_FILE" ]]; then
        dns_status=$(jq -r '.checks.dns // "ok"' "$STATUS_FILE" 2>/dev/null)
        if [[ "$dns_status" == "failing" ]]; then
            if ! _has_active_incident "dns-failure"; then
                _create_incident "$(_incident_id "dns")" "critical" \
                    "dns-failure" "DNS resolution failing for robot-marvin.cz" \
                    "External DNS query returned incorrect or empty result"
            fi
        fi
    fi

    # 6. Critical alerts escalation
    if [[ -f "$ALERTS_FILE" ]] && jq empty "$ALERTS_FILE" 2>/dev/null; then
        crit_alerts=$(jq '[.alerts[] | select(.severity == "critical")] | length' \
            "$ALERTS_FILE" 2>/dev/null) || crit_alerts=0
        if [[ "${crit_alerts:-0}" -gt 0 ]]; then
            if ! _has_active_incident "alert-escalation"; then
                titles=$(jq -r '[.alerts[] | select(.severity == "critical") | .title] | join(", ")' \
                    "$ALERTS_FILE" 2>/dev/null) || titles="unknown"
                _create_incident "$(_incident_id "alert")" "warning" \
                    "alert-escalation" "Critical alerts: ${titles}" \
                    "${crit_alerts} critical alert(s) from log-alerting.sh"
            fi
        fi
    fi

    # 7. High error rate in today's logs (>10%)
    if [[ -f "$LOG_FILE" ]]; then
        total_lines=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')
        error_lines=$(grep -cE '\[ERROR\]|\[CRITICAL\]' "$LOG_FILE" 2>/dev/null) || error_lines=0
        if [[ "${total_lines:-0}" -gt 100 ]]; then
            error_rate=$((error_lines * 100 / total_lines))
            if [[ "$error_rate" -gt 10 ]]; then
                if ! _has_active_incident "high-error-rate"; then
                    _create_incident "$(_incident_id "errrate")" "warning" \
                        "high-error-rate" "Error rate at ${error_rate}% (${error_lines}/${total_lines})" \
                        "Error/critical lines exceed 10% of total log output"
                fi
            fi
        fi
    fi

    active_count=$(jq '[.incidents[] | select(.status == "active")] | length' \
        "$ACTIVE_FILE" 2>/dev/null) || active_count=0
    marvin_log "INFO" "Incident detection complete: ${active_count} active"
fi

# ─── CLOSE ───────────────────────────────────────────────────────────────────
if [[ "$DO_CLOSE" == "true" ]]; then
    marvin_log "INFO" "Checking for resolvable incidents..."
    resolved_count=0
    now_epoch=$(date +%s)

    mapfile -t active_ids < <(jq -r '[.incidents[] | select(.status == "active")] | .[].id' \
        "$ACTIVE_FILE" 2>/dev/null)

    for inc_id in "${active_ids[@]}"; do
        [[ -z "$inc_id" ]] && continue
        inc_type=$(jq -r --arg id "$inc_id" '.incidents[] | select(.id == $id) | .type' \
            "$ACTIVE_FILE" 2>/dev/null) || continue
        inc_opened=$(jq -r --arg id "$inc_id" '.incidents[] | select(.id == $id) | .opened_at' \
            "$ACTIVE_FILE" 2>/dev/null) || continue

        should_resolve=false
        resolution=""

        case "$inc_type" in
            service-down-*)
                svc="${inc_type#service-down-}"
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    should_resolve=true
                    resolution="Service ${svc} recovered"
                fi ;;
            disk-critical)
                pct=$(df / --output=pcent | tail -1 | tr -d ' %')
                if [[ "${pct:-100}" -le 95 ]]; then
                    should_resolve=true
                    resolution="Disk usage dropped to ${pct}%"
                fi ;;
            ssl-expiring)
                days=$(jq -r '.checks.ssl_min_days // 999' "${DATA_DIR}/status.json" 2>/dev/null)
                if [[ "${days:-0}" -ge 7 ]]; then
                    should_resolve=true
                    resolution="SSL certificates renewed (${days} days remaining)"
                fi ;;
            website-down)
                code=$(curl -so /dev/null -w '%{http_code}' --max-time 10 \
                    "https://robot-marvin.cz/" 2>/dev/null) || code="000"
                if [[ "$code" == "200" ]]; then
                    should_resolve=true
                    resolution="Website responding (HTTP 200)"
                fi ;;
            dns-failure)
                ip=$(dig +short robot-marvin.cz A @8.8.8.8 2>/dev/null | tail -1)
                if [[ "${ip:-}" == "80.211.223.26" ]]; then
                    should_resolve=true
                    resolution="DNS resolution restored"
                fi ;;
            alert-escalation)
                cc=$(jq '[.alerts[] | select(.severity == "critical")] | length' \
                    "${DATA_DIR}/alerts/active-alerts.json" 2>/dev/null) || cc=0
                if [[ "${cc:-0}" -eq 0 ]]; then
                    should_resolve=true
                    resolution="All critical alerts cleared"
                fi ;;
            high-error-rate)
                # Auto-close after 4 hours (staleness timeout)
                opened_epoch=$(date -d "$inc_opened" +%s 2>/dev/null) || opened_epoch="$now_epoch"
                if [[ $(( (now_epoch - opened_epoch) / 3600 )) -ge 4 ]]; then
                    should_resolve=true
                    resolution="Staleness timeout (4h)"
                fi ;;
        esac

        if [[ "$should_resolve" == "true" ]]; then
            if marvin_is_dry_run; then
                marvin_log "INFO" "[DRY-RUN] Would resolve: ${inc_id} — ${resolution}"
                resolved_count=$((resolved_count + 1))
                continue
            fi
            opened_epoch=$(date -d "$inc_opened" +%s 2>/dev/null) || opened_epoch="$now_epoch"
            duration_min=$(( (now_epoch - opened_epoch) / 60 ))
            (
                flock -w 10 200 || { marvin_log "WARN" "Lock timeout on resolve"; continue; }
                jq --arg id "$inc_id" --arg res "$resolution" --arg ts "$NOW" --argjson dur "$duration_min" \
                    '(.incidents[] | select(.id == $id)) |= (
                        .status = "resolved" | .resolved_at = $ts |
                        .resolution = $res | .duration_minutes = $dur
                    )' "$ACTIVE_FILE" > "${ACTIVE_FILE}.tmp" \
                    && mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
            ) 200>"$LOCK_FILE"
            # Update history file
            if [[ -f "${HISTORY_DIR}/${inc_id}.json" ]]; then
                jq --arg res "$resolution" --arg ts "$NOW" --argjson dur "$duration_min" \
                    '.status="resolved" | .resolved_at=$ts | .resolution=$res | .duration_minutes=$dur' \
                    "${HISTORY_DIR}/${inc_id}.json" > "${HISTORY_DIR}/${inc_id}.json.tmp" \
                    && mv "${HISTORY_DIR}/${inc_id}.json.tmp" "${HISTORY_DIR}/${inc_id}.json"
            fi
            marvin_log "INFO" "INCIDENT RESOLVED: ${inc_id} — ${resolution} (${duration_min}min)"
            resolved_count=$((resolved_count + 1))
        fi
    done

    # Archive incidents older than 7 days
    week_ago=$(date -u -d "${TODAY} - 7 days" +%Y-%m-%dT00:00:00Z 2>/dev/null || echo "")
    if [[ -n "$week_ago" ]]; then
        (
            flock -w 10 200 || true
            jq --arg cutoff "$week_ago" \
                '.incidents |= [.[] | select(
                    (.status == "active" and .opened_at > $cutoff) or
                    (.status != "active" and .resolved_at > $cutoff)
                )]' "$ACTIVE_FILE" > "${ACTIVE_FILE}.tmp" \
                && mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
        ) 200>"$LOCK_FILE" || true
    fi

    marvin_log "INFO" "Incident closure: ${resolved_count} resolved"
fi

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
if [[ "$DO_SUMMARY" == "true" ]]; then
    active_incidents=$(jq '[.incidents[] | select(.status == "active")]' \
        "$ACTIVE_FILE" 2>/dev/null || echo '[]')
    active_count=$(echo "$active_incidents" | jq 'length')
    active_critical=$(echo "$active_incidents" | jq '[.[] | select(.severity == "critical")] | length')

    # Count resolved in last 30 days
    resolved_30d=0
    total_duration=0
    cutoff=$(date -u -d "${TODAY} - 30 days" +%Y%m%d 2>/dev/null || echo "00000000")
    for f in "${HISTORY_DIR}"/INC-*.json; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        file_date="${fname:4:8}"
        [[ "$file_date" < "$cutoff" ]] && continue
        status=$(jq -r '.status // empty' "$f" 2>/dev/null) || continue
        if [[ "$status" == "resolved" ]]; then
            resolved_30d=$((resolved_30d + 1))
            dur=$(jq -r '.duration_minutes // 0' "$f" 2>/dev/null) || dur=0
            total_duration=$((total_duration + dur))
        fi
    done

    avg_resolution=0
    [[ "$resolved_30d" -gt 0 ]] && avg_resolution=$((total_duration / resolved_30d))

    jq -nc \
        --arg ts "$NOW" \
        --argjson active "$active_count" \
        --argjson critical "$active_critical" \
        --argjson resolved "$resolved_30d" \
        --argjson avg_min "$avg_resolution" \
        --argjson incidents "$active_incidents" \
        '{timestamp:$ts, active_incidents:$active, critical_incidents:$critical,
          resolved_last_30d:$resolved, avg_resolution_minutes:$avg_min, incidents:$incidents}' \
        > "$SUMMARY_FILE"

    marvin_log_json "INFO" "incident-report" "Summary: ${active_count} active, ${resolved_30d} resolved (30d)"
fi

marvin_log "INFO" "Incident report complete"
