#!/usr/bin/env bash
# =============================================================================
# Marvin — Log Export (runs daily at 23:00 UTC)
# =============================================================================
# Generates exportable log bundle for the /api/exports/ endpoint.
# Data files live on disk and are served by nginx — NOT committed to git.
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

marvin_log "INFO" "=== LOG EXPORT STARTING ==="

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Generate exportable log bundle
# ─────────────────────────────────────────────────────────────────────────────
# Creates data/exports/YYYY-MM-DD.json — served at /api/exports/

EXPORT_DIR="${DATA_DIR}/exports"
mkdir -p "$EXPORT_DIR"

EXPORT_FILE="${EXPORT_DIR}/${TODAY}.json"

# Collect today's /var/log/marvin-*.log entries into a structured bundle
LOG_ENTRIES="[]"
for logfile in /var/log/marvin-*.log; do
    [[ -f "$logfile" ]] || continue
    LOGNAME=$(basename "$logfile" .log)
    TODAY_LINES=$(grep "${TODAY}" "$logfile" 2>/dev/null | tail -500 \
        | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}' || echo "")
    if [[ -n "$TODAY_LINES" ]]; then
        LOG_ENTRIES=$(echo "$LOG_ENTRIES" | jq \
            --arg name "$LOGNAME" --arg lines "$TODAY_LINES" \
            '. + [{"source": $name, "content": $lines}]' 2>/dev/null \
            || echo "$LOG_ENTRIES")
    fi
done

cat > "$EXPORT_FILE" << EOF
{
  "version": "1.0",
  "date": "${TODAY}",
  "host": "$(hostname)",
  "generated_at": "${NOW}",
  "metrics_file": "metrics/${TODAY}.jsonl",
  "log_sources": ${LOG_ENTRIES},
  "enhancement_log": $(find "${ENHANCE_DIR}" -maxdepth 1 -name "${TODAY}*.md" -type f -exec basename {} \; 2>/dev/null \
      | jq -R -s 'split("\n") | map(select(. != ""))' 2>/dev/null || echo "[]"),
  "blog_posts": $(find "${BLOG_DIR}" -name "${TODAY}*" -type f -exec basename {} \; 2>/dev/null \
      | jq -R -s 'split("\n") | map(select(. != ""))' 2>/dev/null || echo "[]")
}
EOF

# Regenerate export index (last 30 days)
{
    echo '{"exports":['
    FIRST=true
    for bundle in $(find "$EXPORT_DIR" -name "????-??-??.json" -type f | sort -r | head -30); do
        BUNDLE_NAME=$(basename "$bundle")
        BUNDLE_DATE=${BUNDLE_NAME%.json}
        BUNDLE_SIZE=$(stat -c%s "$bundle" 2>/dev/null || stat -f%z "$bundle" 2>/dev/null || echo "0")
        BUNDLE_GZ_SIZE=0
        if [[ -f "${bundle}.gz" ]]; then
            BUNDLE_GZ_SIZE=$(stat -c%s "${bundle}.gz" 2>/dev/null || echo "0")
        fi
        [[ "$FIRST" == "true" ]] && FIRST=false || echo ","
        echo "  {\"date\":\"${BUNDLE_DATE}\",\"file\":\"${BUNDLE_NAME}\",\"size\":${BUNDLE_SIZE},\"gzip_size\":${BUNDLE_GZ_SIZE}}"
    done
    echo "],"
    echo "\"generated\":\"${NOW}\"}"
} > "${EXPORT_DIR}/index.json"

chmod 644 "${EXPORT_DIR}"/*.json 2>/dev/null || true

# Gzip compress the export bundle for efficient delivery
# Keeps the original .json for direct API access; .json.gz for bandwidth savings
if command -v gzip &>/dev/null; then
    gzip -kf "$EXPORT_FILE" 2>/dev/null || true
    chmod 644 "${EXPORT_FILE}.gz" 2>/dev/null || true
    gz_size=$(stat -c%s "${EXPORT_FILE}.gz" 2>/dev/null || echo "?")
    orig_size=$(stat -c%s "${EXPORT_FILE}" 2>/dev/null || echo "?")
    marvin_log "INFO" "Export bundle compressed: ${orig_size}B -> ${gz_size}B (${EXPORT_FILE}.gz)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1b: Webhook notification
# ─────────────────────────────────────────────────────────────────────────────
# If a webhook URL is configured, POST a notification that a new export is ready.
# Config file: /home/marvin/git/config/webhook.conf (one URL per line, # comments)
# Stored outside data/ to prevent nginx from serving it (webhook URLs may contain secrets)

WEBHOOK_CONF="${MARVIN_DIR}/config/webhook.conf"
if [[ -f "$WEBHOOK_CONF" ]]; then
    export_size=$(stat -c%s "$EXPORT_FILE" 2>/dev/null || echo "0")
    webhook_payload=$(jq -nc \
        --arg event "export_ready" \
        --arg date "$TODAY" \
        --arg file "${TODAY}.json" \
        --argjson size "$export_size" \
        --arg ts "$NOW" \
        '{event: $event, date: $date, file: $file, size_bytes: $size, generated_at: $ts, host: "robot-marvin.cz"}')

    while IFS= read -r webhook_url; do
        # Skip blank lines and comments
        [[ -z "$webhook_url" || "$webhook_url" =~ ^[[:space:]]*# ]] && continue
        # Validate URL starts with http:// or https:// (prevents curl flag injection)
        if [[ ! "$webhook_url" =~ ^https?:// ]]; then
            marvin_log "WARN" "Skipping invalid webhook URL (must start with http:// or https://): ${webhook_url:0:50}"
            continue
        fi
        # Block requests to internal/private network addresses (SSRF protection)
        webhook_host="${webhook_url#http://}"
        webhook_host="${webhook_host#https://}"
        if [[ "$webhook_host" == "["* ]]; then
            webhook_host="${webhook_host%%]*}]"
        else
            webhook_host="${webhook_host%%[/:]*}"
        fi
        webhook_host_lower="${webhook_host,,}"
        if [[ "$webhook_host_lower" == "localhost" ]] \
            || [[ "$webhook_host_lower" =~ ^127\. ]] \
            || [[ "$webhook_host_lower" =~ ^10\. ]] \
            || [[ "$webhook_host_lower" =~ ^0\. ]] \
            || [[ "$webhook_host_lower" =~ ^169\.254\. ]] \
            || [[ "$webhook_host_lower" =~ ^192\.168\. ]] \
            || [[ "$webhook_host_lower" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] \
            || [[ "$webhook_host_lower" =~ ^\[?::1\]?$ ]] \
            || [[ "$webhook_host_lower" =~ ^\[?fd ]] \
            || [[ "$webhook_host_lower" =~ ^\[?fe80 ]]; then
            marvin_log "WARN" "Skipping webhook to internal/private address (SSRF protection): ${webhook_host}"
            continue
        fi
        marvin_log "INFO" "Sending webhook notification to ${webhook_url:0:50}..."
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -X POST -H "Content-Type: application/json" \
            -d "$webhook_payload" -- "$webhook_url" 2>/dev/null || echo "000")
        if [[ "$http_code" =~ ^2 ]]; then
            marvin_log "INFO" "Webhook delivered (HTTP ${http_code})"
        else
            marvin_log "WARN" "Webhook failed (HTTP ${http_code}): ${webhook_url:0:50}"
        fi
    done < "$WEBHOOK_CONF"
else
    marvin_log "INFO" "No webhook.conf — skipping notifications (create ${MARVIN_DIR}/config/webhook.conf to enable)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: Aggregate metrics into hourly/daily/weekly summaries
# ─────────────────────────────────────────────────────────────────────────────
AGGREGATE_SCRIPT="$(dirname "$0")/metric-aggregate.sh"
if [[ -x "$AGGREGATE_SCRIPT" ]]; then
    marvin_log "INFO" "Running metric aggregation..."
    bash "$AGGREGATE_SCRIPT" "$TODAY" 2>&1 || \
        marvin_log "WARN" "Metric aggregation failed (non-fatal)"
fi

marvin_log "INFO" "=== LOG EXPORT COMPLETE ==="
