#!/usr/bin/env bash
# =============================================================================
# Marvin — Log Export (cron fires shortly after 00:00 UTC)
# =============================================================================
# Generates exportable log bundle for the /api/exports/ endpoint.
# Data files live on disk and are served by nginx — NOT committed to git.
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

# Target the UTC day that just ended. Override for manual runs:
#   TARGET_DATE=YYYY-MM-DD bash agent/log-export.sh
TODAY="${TARGET_DATE:-$(date -u -d 'yesterday' +%Y-%m-%d)}"

marvin_log "INFO" "=== LOG EXPORT STARTING (target ${TODAY}) ==="

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Generate exportable log bundle
# ─────────────────────────────────────────────────────────────────────────────
# Creates data/exports/YYYY-MM-DD.json — served at /api/exports/

EXPORT_DIR="${DATA_DIR}/exports"
mkdir -p "$EXPORT_DIR"

EXPORT_FILE="${EXPORT_DIR}/${TODAY}.json"

# Basenames of files matching a find expression, as a single JSON array.
#
# The fallback must be an *assignment*, never extra output. Under `pipefail`
# bash reports the pipeline's status as the last command that failed — not the
# last command in the pipe — so a `find` that exits non-zero (missing or
# unreadable directory) leaks its status past a `jq` that has already printed a
# perfectly good array. A trailing `|| echo "[]"` would then append a *second*
# JSON document to the first, and the bundle heredoc below would emit
# structurally invalid JSON.
_json_basenames() {
    local out
    out=$({ find "$@" -type f -exec basename {} \; 2>/dev/null || true; } \
        | jq -R -s 'split("\n") | map(select(. != ""))' 2>/dev/null) || out=""
    printf '%s' "${out:-[]}"
}

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

ENHANCEMENT_LOG_JSON=$(_json_basenames "${ENHANCE_DIR}" -maxdepth 1 -name "${TODAY}*.md")
BLOG_POSTS_JSON=$(_json_basenames "${BLOG_DIR}" -name "${TODAY}*")

cat > "$EXPORT_FILE" << EOF
{
  "version": "1.0",
  "date": "${TODAY}",
  "host": "$(hostname)",
  "generated_at": "${NOW}",
  "metrics_file": "metrics/${TODAY}.jsonl",
  "log_sources": ${LOG_ENTRIES},
  "enhancement_log": ${ENHANCEMENT_LOG_JSON},
  "blog_posts": ${BLOG_POSTS_JSON}
}
EOF

# The bundle is served to the outside world — never publish a corrupt one.
# This is not fatal to the run: everything downstream that *depends* on the
# bundle (gzip, webhook) is skipped, but Phase 2 metric aggregation is
# independent of the export and still runs. The failing exit code is deferred
# to the end of the script so one bad bundle cannot also cost us a day of
# aggregated metrics.
EXPORT_VALID=true
if ! jq empty "$EXPORT_FILE" 2>/dev/null; then
    marvin_log "ERROR" "Export bundle ${EXPORT_FILE} is not valid JSON — removing"
    rm -f "$EXPORT_FILE"
    EXPORT_VALID=false
fi

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
if [[ "$EXPORT_VALID" == "true" ]] && command -v gzip &>/dev/null; then
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
if [[ "$EXPORT_VALID" != "true" ]]; then
    marvin_log "WARN" "Skipping webhook notification — no valid export bundle for ${TODAY}"
elif [[ -f "$WEBHOOK_CONF" ]]; then
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
        # Strip IPv6 brackets for resolution
        webhook_host_bare="${webhook_host_lower#[}"
        webhook_host_bare="${webhook_host_bare%]}"
        # Check 1: literal hostname/IP against private ranges
        if _is_private_ip "${webhook_host_bare}"; then
            marvin_log "WARN" "Skipping webhook to internal/private address (SSRF protection): ${webhook_host}"
            continue
        fi
        # Check 2: resolve hostname and verify resolved IP is not private (DNS rebinding protection)
        resolved_ip=$(getent hosts "${webhook_host_bare}" 2>/dev/null | awk '{print $1; exit}')
        if [[ -n "${resolved_ip}" ]] && _is_private_ip "${resolved_ip}"; then
            marvin_log "WARN" "Skipping webhook — hostname '${webhook_host}' resolves to private IP '${resolved_ip}' (DNS rebinding protection)"
            continue
        fi
        if [[ -z "${resolved_ip}" ]] && ! [[ "${webhook_host_bare}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            marvin_log "WARN" "Skipping webhook — cannot resolve hostname '${webhook_host}' (DNS lookup failed)"
            continue
        fi
        marvin_log "INFO" "Sending webhook notification to ${webhook_url:0:50}..."
        # Pin the pre-validated IP via --resolve to prevent DNS rebinding (issue #299).
        # Without this, curl performs its own DNS lookup which could resolve to a
        # different (private) IP between our getent check and the actual request.
        # Extract the actual port curl will connect on (issue #303) — pinning only
        # ports 80/443 leaves custom-port URLs unprotected.
        webhook_port=80
        [[ "$webhook_url" =~ ^https:// ]] && webhook_port=443
        # Extract explicit port from URL (e.g. http://example.com:8080/hook)
        # The host was already stripped to bare hostname above, so parse from URL.
        webhook_hostport="${webhook_url#http://}"
        webhook_hostport="${webhook_hostport#https://}"
        webhook_hostport="${webhook_hostport%%[/?]*}"
        if [[ "$webhook_hostport" =~ :([0-9]+)$ ]]; then
            webhook_port="${BASH_REMATCH[1]}"
        fi
        resolve_args=()
        if [[ -n "${resolved_ip}" ]]; then
            resolve_args+=(--resolve "${webhook_host_bare}:${webhook_port}:${resolved_ip}")
        fi
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            "${resolve_args[@]}" \
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

if [[ "$EXPORT_VALID" != "true" ]]; then
    marvin_log "ERROR" "=== LOG EXPORT COMPLETE — bundle for ${TODAY} was invalid and is not published ==="
    exit 1
fi

marvin_log "INFO" "=== LOG EXPORT COMPLETE ==="
