#!/usr/bin/env bash
# =============================================================================
# Marvin — Web Dashboard Deploy (zero-downtime)
# =============================================================================
# Builds the Next.js dashboard and restarts the service with health validation.
# Call this after web/ source changes (git pull, self-enhance, manual edits).
#
# Steps:
#   1. Verify privileges (root or passwordless sudo)
#   2. Install/update npm dependencies
#   3. Build Next.js app (output: standalone)
#   4. Set correct file ownership
#   5. Gracefully restart marvin-web service
#   6. Wait for health check (HTTP 200 + JS asset integrity)
#
# Recovery: On health check failure, the script automatically rolls back to
# the previous build from ${DATA_DIR}/web-backup/ and restarts the service.
# If rollback also fails, health-monitor.sh (cron every 5 min) detects
# persistent failures and restarts the service.
#
# Privileges: This script requires root or a sudoers rule granting the
# running user passwordless access to systemctl and chown. Example:
#   marvin ALL=(ALL) NOPASSWD: /usr/bin/systemctl status marvin-web, /usr/bin/systemctl restart marvin-web, /usr/bin/chown
#
# Usage:
#   ./deploy-web.sh              # full build + deploy
#   ./deploy-web.sh --restart    # restart only (skip build)
#   ./deploy-web.sh --dry-run    # show what would happen
#
# Exit codes:
#   0 = success
#   1 = build failed or pre-flight check failed
#   2 = health check failed after deploy, rollback succeeded — service restored
#   3 = health check failed, rollback failed or incomplete — manual intervention required
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

WEB_SRC="${MARVIN_DIR}/web"
BUILD_DIR="${WEB_SRC}/.next"
STANDALONE_DIR="${BUILD_DIR}/standalone"
BACKUP_DIR="${DATA_DIR}/web-backup"
LOCAL_URL="http://localhost:3000"  # direct to Node.js — avoids nginx/DNS dependency
MAX_HEALTH_WAIT=60  # seconds to wait for health check
BUILD_TIMEOUT=600   # seconds before killing a hung build

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

# Privilege check: systemctl restart and chown require root or sudo
if [[ $EUID -ne 0 ]]; then
    if ! sudo -n systemctl status marvin-web &>/dev/null; then
        marvin_log "ERROR" "deploy-web.sh requires root or passwordless sudo for systemctl."
        marvin_log "ERROR" "Add a sudoers rule: marvin ALL=(ALL) NOPASSWD: /usr/bin/systemctl status marvin-web, /usr/bin/systemctl restart marvin-web, /usr/bin/chown"
        exit 1
    fi
    # We have sudo — use it for privileged commands
    SUDO="sudo"
else
    SUDO=""
fi

# ─── Backup current build ───────────────────────────────────────────────────
# Save the BUILD_ID so we can detect if the new build is different

_old_build_id=""
if [[ -f "${BUILD_DIR}/BUILD_ID" ]]; then
    _old_build_id=$(cat "${BUILD_DIR}/BUILD_ID" 2>/dev/null || echo "")
fi

# Backup the full build directory so rollback restores both server.js and static assets
mkdir -p "$BACKUP_DIR"
if [[ -d "${STANDALONE_DIR}" && -d "${BUILD_DIR}/static" ]]; then
    _backup_file="${BACKUP_DIR}/build-${_old_build_id:-unknown}.tar.gz"
    _tar_backup_err=$(tar -czf "$_backup_file" -C "${WEB_SRC}" .next/standalone .next/static .next/BUILD_ID 2>&1) && _tar_backup_ok=true || _tar_backup_ok=false
    if [[ -n "$_tar_backup_err" ]]; then
        marvin_log "WARN" "tar backup warnings: ${_tar_backup_err}"
    fi
    if [[ "$_tar_backup_ok" == "true" ]]; then
        marvin_log "INFO" "Backed up current build to ${_backup_file} (BUILD_ID: ${_old_build_id:-unknown})"
        # Keep only the 3 most recent backups to conserve disk
        ls -t "${BACKUP_DIR}"/build-*.tar.gz 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    else
        marvin_log "WARN" "Failed to create build backup — continuing without backup"
    fi
fi

# ─── Build ───────────────────────────────────────────────────────────────────

if [[ "$SKIP_BUILD" == "false" ]]; then
    if marvin_is_dry_run; then
        marvin_log "INFO" "[DRY-RUN] Would run: npm ci && npm run build in ${WEB_SRC}"
    else
        marvin_log "INFO" "Installing npm dependencies..."
        # npm ci is faster and deterministic (uses lockfile)
        # Fall back to npm install if no lockfile
        # When running as root, drop to marvin user for npm commands to avoid
        # executing arbitrary JS from node_modules with root privileges (#422)
        # When running as root, drop to marvin user via array-based command prefix
        # to avoid executing arbitrary JS from node_modules with root privileges (#422)
        # Using a bash array prevents word-splitting issues (#426)
        _run_as_marvin=false
        if [[ $EUID -eq 0 ]]; then
            _run_as_marvin=true
        fi

        # Helper to run npm commands, dropping privileges when running as root
        _run_npm() {
            if [[ "$_run_as_marvin" == "true" ]]; then
                su -s /bin/bash marvin -c "$*"
            else
                "$@"
            fi
        }

        if [[ -f "${WEB_SRC}/package-lock.json" ]]; then
            if ! _run_npm npm ci --prefix "${WEB_SRC}" --loglevel=error 2>&1 | tail -5; then
                marvin_log "ERROR" "npm ci failed"
                exit 1
            fi
        else
            if ! _run_npm npm install --prefix "${WEB_SRC}" --loglevel=error 2>&1 | tail -5; then
                marvin_log "ERROR" "npm install failed"
                exit 1
            fi
        fi

        marvin_log "INFO" "Building Next.js app (timeout ${BUILD_TIMEOUT}s)..."
        build_start=$(date +%s)
        if [[ "$_run_as_marvin" == "true" ]]; then
            build_output=$(su -s /bin/bash marvin -c "timeout ${BUILD_TIMEOUT} npm run build --prefix '${WEB_SRC}'" 2>&1) && build_exit=0 || build_exit=$?
        else
            build_output=$(timeout "$BUILD_TIMEOUT" npm run build --prefix "$WEB_SRC" 2>&1) && build_exit=0 || build_exit=$?
        fi
        build_end=$(date +%s)
        build_duration=$((build_end - build_start))

        if [[ "$build_exit" -eq 124 ]]; then
            marvin_log "ERROR" "Next.js build timed out after ${BUILD_TIMEOUT}s — killing hung process"
            exit 1
        fi

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

        # Copy static assets into standalone directory — Next.js standalone
        # output does NOT bundle static assets. Without this, the server
        # serves HTML referencing JS chunks that don't exist on disk → 404s.
        if [[ -d "${BUILD_DIR}/static" && -d "${STANDALONE_DIR}" ]]; then
            mkdir -p "${STANDALONE_DIR}/.next/static"
            if ! cp -a "${BUILD_DIR}/static/." "${STANDALONE_DIR}/.next/static/"; then
                marvin_log "ERROR" "Failed to copy static assets to standalone — deploy would cause JS 404s"
                exit 1
            fi
            marvin_log "INFO" "Static assets copied to standalone directory"
        fi

        # Set ownership so marvin-web service (runs as marvin) can read
        ${SUDO:+sudo} chown -R marvin:marvin "${BUILD_DIR}" || {
            marvin_log "WARN" "chown failed — file ownership may be incorrect"
        }
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
if ! ${SUDO:+sudo} systemctl restart marvin-web; then
    marvin_log "ERROR" "Failed to restart marvin-web service — manual intervention required"
    exit 3
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

    # Check 1: HTTP 200 on main page (direct to Node.js, bypass nginx/DNS)
    _http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "${LOCAL_URL}/" 2>/dev/null || echo "000")
    if [[ "$_http_code" != "200" ]]; then
        marvin_log "INFO" "Health check: HTTP ${_http_code} (waiting...)"
        continue
    fi

    # Check 2: JS asset integrity (the main build mismatch indicator)
    _js_chunk=$(curl -s --max-time 5 "${LOCAL_URL}/" 2>/dev/null \
        | grep -oP 'src="/_next/static/chunks/[^"]*"' | head -1 \
        | grep -oP '/_next/static/chunks/[^"]*' || true)

    if [[ -n "$_js_chunk" ]]; then
        _chunk_status=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "${LOCAL_URL}${_js_chunk}" 2>/dev/null || echo "000")
        if [[ "$_chunk_status" == "200" ]]; then
            _health_ok=true
            break
        else
            marvin_log "WARN" "Health check: JS asset ${_js_chunk} returned HTTP ${_chunk_status}"
        fi
    else
        # No JS chunk found — page may be broken (SSR error, empty response)
        # Retry instead of accepting a potentially broken deploy
        marvin_log "WARN" "Health check: could not extract JS chunk URL — retrying"
        continue
    fi
done

if [[ "$_health_ok" == "true" ]]; then
    _new_build_id=$(cat "${BUILD_DIR}/BUILD_ID" 2>/dev/null || echo "unknown")
    marvin_log_json "INFO" "deploy-web" "Deploy successful" \
        "$(jq -nc --arg old "${_old_build_id:-unknown}" --arg new "$_new_build_id" --argjson wait "$_waited" \
            '{old_build: $old, new_build: $new, health_wait_s: $wait}')"
    exit 0
else
    marvin_log "ERROR" "Health check failed after ${MAX_HEALTH_WAIT}s — attempting rollback"

    # Find the most recent backup to restore
    _rollback_file=$(ls -t "${BACKUP_DIR}"/build-*.tar.gz 2>/dev/null | head -1 || true)

    if [[ -n "$_rollback_file" ]]; then
        marvin_log "INFO" "Rolling back from: ${_rollback_file}"

        # Extract backup over the current build
        _tar_err=$(tar -xzf "$_rollback_file" -C "${WEB_SRC}" 2>&1) && _tar_ok=true || _tar_ok=false
        if [[ -n "$_tar_err" ]]; then
            marvin_log "WARN" "tar extraction warnings: ${_tar_err}"
        fi
        if [[ "$_tar_ok" == "true" ]]; then
            ${SUDO:+sudo} chown -R marvin:marvin "${BUILD_DIR}" || true

            marvin_log "INFO" "Backup restored — restarting service..."
            if ${SUDO:+sudo} systemctl restart marvin-web; then
                # Brief health check on rolled-back build
                sleep 5
                _rb_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "${LOCAL_URL}/" 2>/dev/null || echo "000")
                if [[ "$_rb_code" == "200" ]]; then
                    marvin_log "INFO" "Rollback successful — service restored (HTTP ${_rb_code})"
                    exit 2
                else
                    marvin_log "WARN" "Rollback service started but health check returned HTTP ${_rb_code}"
                    exit 3
                fi
            else
                marvin_log "ERROR" "Failed to restart service after rollback"
                exit 3
            fi
        else
            marvin_log "ERROR" "Failed to extract backup from ${_rollback_file}"
            exit 3
        fi
    else
        marvin_log "ERROR" "No backup available for rollback — manual intervention required"
        marvin_log "WARN" "health-monitor.sh will detect persistent failures (runs every 5 min)"
        exit 3
    fi
fi
