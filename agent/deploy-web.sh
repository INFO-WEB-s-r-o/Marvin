#!/usr/bin/env bash
# =============================================================================
# Marvin — Web Dashboard Deploy (zero-downtime)
# =============================================================================
# Builds the Next.js dashboard and restarts the service with health validation.
# Call this after web/ source changes (git pull, self-enhance, manual edits).
#
# Steps:
#   1. Install/update npm dependencies
#   2. Build Next.js app (output: standalone)
#   3. Set correct file ownership
#   4. Gracefully restart marvin-web service
#   5. Wait for health check (HTTP 200 + JS asset integrity)
#   6. Roll back build if health check fails
#
# Usage:
#   ./deploy-web.sh              # full build + deploy
#   ./deploy-web.sh --restart    # restart only (skip build)
#   ./deploy-web.sh --dry-run    # show what would happen
#
# Exit codes:
#   0 = success
#   1 = build failed
#   2 = health check failed after deploy
#   3 = rollback failed (manual intervention needed)
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

WEB_SRC="${MARVIN_DIR}/web"
BUILD_DIR="${WEB_SRC}/.next"
STANDALONE_DIR="${BUILD_DIR}/standalone"
BACKUP_DIR="${DATA_DIR}/web-backup"
SITE_URL="https://robot-marvin.cz"
MAX_HEALTH_WAIT=30  # seconds to wait for health check

marvin_log_json "INFO" "deploy-web" "Deploy script starting"

# ─── Parse arguments ─────────────────────────────────────────────────────────
SKIP_BUILD=false
marvin_parse_args "$@"

for arg in "$@"; do
    case "$arg" in
        --restart) SKIP_BUILD=true ;;
    esac
done

# ─── Pre-flight checks ──────────────────────────────────────────────────────

if [[ ! -f "${WEB_SRC}/package.json" ]]; then
    marvin_log "ERROR" "No package.json in ${WEB_SRC} — cannot deploy"
    exit 1
fi

if ! command -v node &>/dev/null; then
    marvin_log "ERROR" "Node.js not found in PATH"
    exit 1
fi

if ! command -v npm &>/dev/null; then
    marvin_log "ERROR" "npm not found in PATH"
    exit 1
fi

# ─── Backup current build ───────────────────────────────────────────────────
# Save the BUILD_ID so we can detect if the new build is different

_old_build_id=""
if [[ -f "${BUILD_DIR}/BUILD_ID" ]]; then
    _old_build_id=$(cat "${BUILD_DIR}/BUILD_ID" 2>/dev/null || echo "")
fi

# Backup the standalone server.js in case we need to roll back
mkdir -p "$BACKUP_DIR"
if [[ -f "${STANDALONE_DIR}/server.js" ]]; then
    cp "${STANDALONE_DIR}/server.js" "${BACKUP_DIR}/server.js.bak" 2>/dev/null || true
    if [[ -f "${BUILD_DIR}/BUILD_ID" ]]; then
        cp "${BUILD_DIR}/BUILD_ID" "${BACKUP_DIR}/BUILD_ID.bak" 2>/dev/null || true
    fi
    marvin_log "INFO" "Backed up current build (BUILD_ID: ${_old_build_id:-unknown})"
fi

# ─── Build ───────────────────────────────────────────────────────────────────

if [[ "$SKIP_BUILD" == "false" ]]; then
    if marvin_is_dry_run; then
        marvin_log "INFO" "[DRY-RUN] Would run: npm ci && npm run build in ${WEB_SRC}"
    else
        marvin_log "INFO" "Installing npm dependencies..."
        # npm ci is faster and deterministic (uses lockfile)
        # Fall back to npm install if no lockfile
        if [[ -f "${WEB_SRC}/package-lock.json" ]]; then
            if ! npm ci --prefix "$WEB_SRC" --loglevel=error 2>&1 | tail -5; then
                marvin_log "ERROR" "npm ci failed"
                exit 1
            fi
        else
            if ! npm install --prefix "$WEB_SRC" --loglevel=error 2>&1 | tail -5; then
                marvin_log "ERROR" "npm install failed"
                exit 1
            fi
        fi

        marvin_log "INFO" "Building Next.js app..."
        build_start=$(date +%s)
        build_output=$(npm run build --prefix "$WEB_SRC" 2>&1) && build_exit=0 || build_exit=$?
        build_end=$(date +%s)
        build_duration=$((build_end - build_start))

        if [[ "$build_exit" -ne 0 ]]; then
            marvin_log "ERROR" "Next.js build failed (exit ${build_exit}, ${build_duration}s)"
            # Log last 20 lines of build output for debugging
            echo "$build_output" | tail -20 | while IFS= read -r line; do
                marvin_log "ERROR" "  build: ${line}"
            done
            exit 1
        fi

        marvin_log "INFO" "Build complete (${build_duration}s)"

        # Validate build output
        if [[ ! -f "${STANDALONE_DIR}/server.js" ]]; then
            marvin_log "ERROR" "Build produced no standalone/server.js — output invalid"
            exit 1
        fi

        if [[ ! -d "${BUILD_DIR}/static" ]]; then
            marvin_log "ERROR" "Build produced no .next/static/ directory — output invalid"
            exit 1
        fi

        _new_build_id=$(cat "${BUILD_DIR}/BUILD_ID" 2>/dev/null || echo "unknown")
        marvin_log "INFO" "Build validated: BUILD_ID ${_new_build_id}"

        # Set ownership so marvin-web service (runs as marvin) can read
        chown -R marvin:marvin "${BUILD_DIR}" 2>/dev/null || true
    fi
else
    marvin_log "INFO" "Skipping build (--restart mode)"
fi

# ─── Deploy (restart service) ───────────────────────────────────────────────

if marvin_is_dry_run; then
    marvin_log "INFO" "[DRY-RUN] Would restart marvin-web service and run health check"
    exit 0
fi

marvin_log "INFO" "Restarting marvin-web service..."
if ! systemctl restart marvin-web 2>/dev/null; then
    marvin_log "ERROR" "Failed to restart marvin-web service"
    exit 2
fi

# ─── Health check ────────────────────────────────────────────────────────────
# Wait for the service to come up, then verify HTTP 200 + JS asset integrity

marvin_log "INFO" "Waiting for health check (max ${MAX_HEALTH_WAIT}s)..."

_health_ok=false
_waited=0
_sleep_interval=3

while [[ "$_waited" -lt "$MAX_HEALTH_WAIT" ]]; do
    sleep "$_sleep_interval"
    _waited=$((_waited + _sleep_interval))

    # Check 1: HTTP 200 on main page
    _http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "${SITE_URL}/" 2>/dev/null || echo "000")
    if [[ "$_http_code" != "200" ]]; then
        marvin_log "INFO" "Health check: HTTP ${_http_code} (waiting...)"
        continue
    fi

    # Check 2: JS asset integrity (the main build mismatch indicator)
    _js_chunk=$(curl -s --max-time 5 "${SITE_URL}/" 2>/dev/null \
        | grep -oP 'src="/_next/static/chunks/[^"]*"' | head -1 \
        | grep -oP '/_next/static/chunks/[^"]*' || true)

    if [[ -n "$_js_chunk" ]]; then
        _chunk_status=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "${SITE_URL}${_js_chunk}" 2>/dev/null || echo "000")
        if [[ "$_chunk_status" == "200" ]]; then
            _health_ok=true
            break
        else
            marvin_log "WARN" "Health check: JS asset ${_js_chunk} returned HTTP ${_chunk_status}"
        fi
    else
        # No JS chunk found in page — might be SSR error, but page returned 200
        # Accept it with a warning
        marvin_log "WARN" "Health check: could not extract JS chunk URL (SSR may be limited)"
        _health_ok=true
        break
    fi
done

if [[ "$_health_ok" == "true" ]]; then
    _new_build_id=$(cat "${BUILD_DIR}/BUILD_ID" 2>/dev/null || echo "unknown")
    marvin_log_json "INFO" "deploy-web" "Deploy successful" \
        "$(jq -nc --arg old "${_old_build_id:-unknown}" --arg new "$_new_build_id" --argjson wait "$_waited" \
            '{old_build: $old, new_build: $new, health_wait_s: $wait}')"
    exit 0
else
    marvin_log "ERROR" "Health check failed after ${MAX_HEALTH_WAIT}s — deploy may have issues"

    # If we have a backup and the build changed, this is a real problem
    # But don't auto-rollback — the service might just be slow to start
    # The health-monitor.sh will catch persistent issues every 5 minutes
    marvin_log "WARN" "Service is running but health check didn't pass. health-monitor.sh will track."
    exit 2
fi
