#!/usr/bin/env bash
# =============================================================================
# Marvin — Export Push Client
# =============================================================================
# POSTs daily export bundles to one or more configurable endpoints.
# This is a companion to log-export.sh (which creates the bundles) and the
# webhook system (which sends lightweight notifications).
#
# The push client sends the ACTUAL bundle content, allowing external systems
# to ingest Marvin's daily logs without polling the export API.
#
# Config: /home/marvin/git/config/push-endpoints.conf (chmod 600 recommended)
#   Format: one endpoint per line, JSON object with url and optional auth:
#     {"url": "https://example.com/ingest", "auth": "Bearer TOKEN"}
#     {"url": "https://other.com/api/logs", "auth": "ApiKey SECRET"}
#   Lines starting with # are comments. Blank lines are skipped.
#   IMPORTANT: Auth tokens require HTTPS — HTTP endpoints with auth are rejected.
#
# Usage:
#   export-push.sh                  # Push yesterday's bundle
#   export-push.sh 2026-04-03      # Push a specific date's bundle
#   export-push.sh --dry-run        # Show what would be pushed without sending
#
# Schedule: Can be run via cron after log-export.sh (e.g., 23:15 UTC)
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

marvin_parse_args "$@"

marvin_log "INFO" "=== EXPORT PUSH CLIENT STARTING ==="

# ─── Configuration ───────────────────────────────────────────────────────────

PUSH_CONF="${MARVIN_DIR}/config/push-endpoints.conf"
EXPORTS_DIR="${DATA_DIR}/exports"

# Determine which date to push (default: yesterday, since today's isn't complete yet)
PUSH_DATE=""
for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        PUSH_DATE="$arg"
    fi
done
if [[ -z "$PUSH_DATE" ]]; then
    PUSH_DATE=$(date -u -d "yesterday" +%Y-%m-%d)
fi

BUNDLE_FILE="${EXPORTS_DIR}/${PUSH_DATE}.json"
BUNDLE_GZ="${EXPORTS_DIR}/${PUSH_DATE}.json.gz"

# ─── Validation ──────────────────────────────────────────────────────────────

if [[ ! -f "$PUSH_CONF" ]]; then
    marvin_log "INFO" "No push-endpoints.conf — nothing to push (create ${PUSH_CONF} to enable)"
    marvin_log "INFO" "=== EXPORT PUSH CLIENT COMPLETE (no endpoints configured) ==="
    exit 0
fi

# Check config file permissions — it may contain auth tokens (#464)
conf_perms=$(stat -c "%a" "$PUSH_CONF" 2>/dev/null || echo "unknown")
if [[ "$conf_perms" != "unknown" && "$conf_perms" != "600" && "$conf_perms" != "640" ]]; then
    marvin_log "WARN" "push-endpoints.conf has permissions ${conf_perms} — should be 600 or 640 (contains auth tokens)"
    marvin_log "WARN" "Fix with: chmod 600 ${PUSH_CONF}"
fi

if [[ ! -f "$BUNDLE_FILE" && ! -f "$BUNDLE_GZ" ]]; then
    marvin_log "WARN" "No export bundle found for ${PUSH_DATE} — skipping"
    marvin_log "INFO" "=== EXPORT PUSH CLIENT COMPLETE (no bundle for ${PUSH_DATE}) ==="
    exit 0
fi

# Prefer gzipped bundle if available (smaller transfer)
# The Content-Encoding: gzip header is set directly in the curl args below
# when USE_GZ=true (see "Build curl args" section).
USE_GZ=false
SEND_FILE="$BUNDLE_FILE"
CONTENT_TYPE="application/json"
if [[ -f "$BUNDLE_GZ" ]]; then
    USE_GZ=true
    SEND_FILE="$BUNDLE_GZ"
fi

BUNDLE_SIZE=$(stat -c%s "$SEND_FILE" 2>/dev/null || echo "0")
marvin_log "INFO" "Pushing ${PUSH_DATE} export (${BUNDLE_SIZE} bytes, gz=${USE_GZ})"

# ─── Push to each endpoint ───────────────────────────────────────────────────

push_count=0
push_success=0
push_fail=0

while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Parse JSON config line
    endpoint_url=$(echo "$line" | jq -r '.url // empty' 2>/dev/null)
    endpoint_auth=$(echo "$line" | jq -r '.auth // empty' 2>/dev/null)

    if [[ -z "$endpoint_url" ]]; then
        marvin_log "WARN" "Skipping invalid endpoint config (no url): ${line:0:80}"
        continue
    fi

    # Validate URL scheme
    if [[ ! "$endpoint_url" =~ ^https?:// ]]; then
        marvin_log "WARN" "Skipping endpoint with invalid scheme: ${endpoint_url:0:50}"
        continue
    fi

    # SSRF: extract host and check
    push_host="${endpoint_url#http://}"
    push_host="${push_host#https://}"
    push_host="${push_host%%[/:]*}"
    push_host_lower="${push_host,,}"

    if _is_private_ip "$push_host_lower"; then
        marvin_log "WARN" "Skipping push to private address (SSRF protection): ${push_host}"
        continue
    fi

    resolved_ip=$(getent hosts "$push_host_lower" 2>/dev/null | awk '{print $1; exit}')
    if [[ -n "$resolved_ip" ]] && _is_private_ip "$resolved_ip"; then
        marvin_log "WARN" "Skipping push — hostname resolves to private IP (DNS rebinding): ${push_host}"
        continue
    fi

    push_count=$((push_count + 1))

    if marvin_is_dry_run; then
        marvin_log "INFO" "[DRY-RUN] Would push ${PUSH_DATE} bundle (${BUNDLE_SIZE} bytes) to ${endpoint_url:0:60}"
        push_success=$((push_success + 1))
        continue
    fi

    marvin_log "INFO" "Pushing to endpoint ${push_count}: ${endpoint_url:0:60}..."

    # Build curl args
    curl_args=(
        -s -o /dev/null -w "%{http_code}"
        --max-time 30
        -X POST
        -H "Content-Type: ${CONTENT_TYPE}"
        -H "X-Marvin-Date: ${PUSH_DATE}"
        -H "X-Marvin-Source: robot-marvin.cz"
    )

    # Add content-encoding header for gzipped bundles
    if [[ "$USE_GZ" == "true" ]]; then
        curl_args+=(-H "Content-Encoding: gzip")
    fi

    # Add auth header if configured — reject cleartext HTTP with auth (#463)
    if [[ -n "$endpoint_auth" ]]; then
        if [[ "$endpoint_url" =~ ^http:// ]]; then
            marvin_log "WARN" "Skipping endpoint — auth token over plaintext HTTP is not allowed: ${endpoint_url:0:60}"
            push_fail=$((push_fail + 1))
            continue
        fi
        curl_args+=(-H "Authorization: ${endpoint_auth}")
    fi

    # DNS-pinning for SSRF protection (same pattern as webhook system)
    push_port=80
    [[ "$endpoint_url" =~ ^https:// ]] && push_port=443
    local_hostport="${endpoint_url#http://}"
    local_hostport="${local_hostport#https://}"
    local_hostport="${local_hostport%%[/?]*}"
    if [[ "$local_hostport" =~ :([0-9]+)$ ]]; then
        push_port="${BASH_REMATCH[1]}"
    fi
    if [[ -n "$resolved_ip" ]]; then
        curl_args+=(--resolve "${push_host_lower}:${push_port}:${resolved_ip}")
    fi

    # Send the bundle
    http_code=$(curl "${curl_args[@]}" --data-binary "@${SEND_FILE}" -- "$endpoint_url" 2>/dev/null || echo "000")

    if [[ "$http_code" =~ ^2 ]]; then
        marvin_log "INFO" "Push succeeded (HTTP ${http_code}): ${endpoint_url:0:60}"
        push_success=$((push_success + 1))
    else
        marvin_log "WARN" "Push failed (HTTP ${http_code}): ${endpoint_url:0:60}"
        push_fail=$((push_fail + 1))
    fi

done < "$PUSH_CONF"

# ─── Summary ─────────────────────────────────────────────────────────────────

marvin_log "INFO" "Push summary: ${push_count} endpoint(s), ${push_success} succeeded, ${push_fail} failed"

# Write push status for monitoring
jq -nc \
    --arg ts "$NOW" \
    --arg date "$PUSH_DATE" \
    --argjson endpoints "$push_count" \
    --argjson success "$push_success" \
    --argjson failed "$push_fail" \
    --argjson bundle_bytes "$BUNDLE_SIZE" \
    --argjson gz "$USE_GZ" \
    '{timestamp: $ts, push_date: $date, endpoints: $endpoints, success: $success, failed: $failed, bundle_bytes: $bundle_bytes, gzip: $gz}' \
    > "${DATA_DIR}/exports/push-status.json" 2>/dev/null || true

marvin_log "INFO" "=== EXPORT PUSH CLIENT COMPLETE ==="
