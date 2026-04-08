#!/usr/bin/env bash
# =============================================================================
# Marvin — Common utilities shared across all agent scripts
# =============================================================================
# This file is the single entry point sourced by all agent scripts.
# Functions are organized into lib/ modules:
#   lib/logging.sh  — marvin_log(), marvin_log_json(), marvin_error_trap()
#   lib/metrics.sh  — collect_metrics(), append_metrics()
#   lib/claude.sh   — run_claude(), check_claude()
#   lib/github.sh   — GitHub API, GPG signing (sourced separately by scripts)
# =============================================================================

MARVIN_DIR="/home/marvin/git"
DATA_DIR="${MARVIN_DIR}/data"
LOGS_DIR="${DATA_DIR}/logs"

# GPG key lives in marvin's homedir, but cron runs as root.
# Without this, git commit -S and gpg --detach-sign fail with "No secret key".
export GNUPGHOME="/home/marvin/.gnupg"
METRICS_DIR="${DATA_DIR}/metrics"
BLOG_DIR="/home/marvin/blog"
COMMS_DIR="${DATA_DIR}/comms"
ENHANCE_DIR="${DATA_DIR}/enhancements"
PROMPTS_DIR="${MARVIN_DIR}/agent/prompts"
WEB_DIR="${MARVIN_DIR}/web"
SITE_URL="https://robot-marvin.cz"

TODAY=$(date -u +%Y-%m-%d)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TIMESTAMP=$(date +%s)

# ─── Dry-run mode ─────────────────────────────────────────────────────────
# Scripts can enable dry-run via --dry-run flag or MARVIN_DRY_RUN=true env var.
# When active, destructive operations are logged but not executed.
# Usage in scripts:
#   marvin_parse_args "$@"        # parses --dry-run flag
#   if marvin_is_dry_run; then    # check if dry-run is active
#     marvin_log "INFO" "[DRY-RUN] Would delete $file"
#   else
#     rm -f "$file"
#   fi
MARVIN_DRY_RUN="${MARVIN_DRY_RUN:-false}"
export MARVIN_DRY_RUN

# ─── SSRF protection: private/internal IP detection ─────────────────────────
# Shared helper used by network-discovery.sh, export-push.sh, log-export.sh.
# Returns 0 if the given IP/hostname is private/reserved (RFC 1918, CGNAT,
# loopback, link-local, IPv6 ULA/link-local). Colon guard prevents false
# positives on hostnames starting with fc/fd/fe80 (issue #296).
_is_private_ip() {
    local ip_lower="${1,,}"
    [[ "$ip_lower" == "localhost" ]] \
        || [[ "$ip_lower" =~ ^127\. ]] \
        || [[ "$ip_lower" =~ ^10\. ]] \
        || [[ "$ip_lower" =~ ^0\. ]] \
        || [[ "$ip_lower" =~ ^169\.254\. ]] \
        || [[ "$ip_lower" =~ ^192\.168\. ]] \
        || [[ "$ip_lower" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] \
        || [[ "$ip_lower" =~ ^100\.(6[4-9]|[7-9][0-9]|1([01][0-9]|2[0-7]))\. ]] \
        || { [[ "$ip_lower" == *:* ]] && {
                [[ "$ip_lower" =~ ^::1$ ]] \
                || [[ "$ip_lower" == "::" ]] \
                || [[ "$ip_lower" =~ ^fd ]] \
                || [[ "$ip_lower" =~ ^fc ]] \
                || [[ "$ip_lower" =~ ^fe80 ]] \
                || [[ "$ip_lower" =~ ^::ffff: ]];
            }; }
}

marvin_parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) MARVIN_DRY_RUN=true; export MARVIN_DRY_RUN ;;
        esac
    done
    if [[ "$MARVIN_DRY_RUN" == "true" ]]; then
        marvin_log "INFO" "[DRY-RUN] Dry-run mode active — no destructive operations will be performed"
    fi
}

marvin_is_dry_run() {
    [[ "$MARVIN_DRY_RUN" == "true" ]]
}

# Ensure directories exist
mkdir -p "$LOGS_DIR" "$METRICS_DIR" "$BLOG_DIR" "$COMMS_DIR" "$ENHANCE_DIR"

# ─── Source library modules ───────────────────────────────────────────────────
# Order matters: logging first (used by metrics and claude), then metrics
# (used by claude's collect_metrics), then claude.
_MARVIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
source "${_MARVIN_LIB_DIR}/logging.sh"
source "${_MARVIN_LIB_DIR}/metrics.sh"
source "${_MARVIN_LIB_DIR}/claude.sh"

# ─── Service management ──────────────────────────────────────────────────────

# Graceful nginx reload — validates config first, keeps connections alive.
# Usage: marvin_nginx_reload [reason]
# Returns 0 on success, 1 if config test fails (nginx untouched).
marvin_nginx_reload() {
    local reason="${1:-unspecified}"
    if ! nginx -t 2>/dev/null; then
        marvin_log "ERROR" "nginx config test failed — reload aborted (reason: ${reason})"
        return 1
    fi
    if systemctl reload nginx 2>/dev/null; then
        marvin_log "INFO" "nginx gracefully reloaded (reason: ${reason})"
        return 0
    else
        marvin_log "WARN" "nginx reload failed — falling back to restart (reason: ${reason})"
        systemctl restart nginx 2>/dev/null || {
            marvin_log "ERROR" "nginx restart also failed (reason: ${reason})"
            return 1
        }
        return 0
    fi
}

# ─── Web rebuild ──────────────────────────────────────────────────────────────
# Rebuilds the Next.js dashboard and restarts the service.
# Handles: npm ci (if needed), next build, static asset copy, service restart,
# JS asset integrity check with automatic rollback on failure.
#
# Usage: marvin_rebuild_web [reason]
# Returns 0 on success, 1 on build/restart/healthcheck failure.

marvin_rebuild_web() {
    local reason="${1:-unspecified}"

    if marvin_is_dry_run; then
        marvin_log "INFO" "[DRY-RUN] Would rebuild web (reason: ${reason})"
        return 0
    fi

    # Prevent concurrent builds — race condition between health-monitor and
    # self-enhance caused ENOENT crashes on 2026-04-08 (two builds writing
    # to .next/ simultaneously corrupt prerender-manifest.json and static/).
    local lock_file="/tmp/marvin-web-build.lock"
    if [[ -f "$lock_file" ]]; then
        local lock_age lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null || echo "")
        lock_age=$(( $(date +%s) - $(stat -c%Y "$lock_file" 2>/dev/null || echo "0") ))
        # Stale lock (>10 min) — previous build crashed without cleanup
        if [[ "$lock_age" -gt 600 ]]; then
            marvin_log "WARN" "Removing stale build lock (age ${lock_age}s, PID ${lock_pid})"
            rm -f "$lock_file"
        elif kill -0 "$lock_pid" 2>/dev/null; then
            marvin_log "WARN" "Web rebuild skipped — another build in progress (PID ${lock_pid}, reason: ${reason})"
            return 1
        else
            marvin_log "WARN" "Removing orphaned build lock (PID ${lock_pid} not running)"
            rm -f "$lock_file"
        fi
    fi
    echo "$$" > "$lock_file"
    # Ensure lock is released on exit from this function
    trap 'rm -f "$lock_file"' RETURN

    local web_dir="${WEB_DIR}"
    local standalone_dir="${web_dir}/.next/standalone"
    local backup_dir="${web_dir}/.next-backup-$(date +%s)"

    marvin_log "INFO" "Web rebuild starting (reason: ${reason})"

    # Backup current build for rollback
    if [[ -d "${web_dir}/.next" ]]; then
        cp -a "${web_dir}/.next" "$backup_dir" 2>/dev/null || true
    fi

    # Prune old backups — keep only the 3 most recent
    ls -dt "${web_dir}"/.next-backup-* 2>/dev/null | tail -n +4 | xargs rm -rf 2>/dev/null || true

    # Install deps if node_modules missing or package-lock.json changed
    if [[ ! -d "${web_dir}/node_modules" ]] || \
       [[ "${web_dir}/package-lock.json" -nt "${web_dir}/node_modules" ]]; then
        marvin_log "INFO" "Installing web dependencies..."
        if ! (cd "$web_dir" && npm ci --production=false 2>&1 | tail -5); then
            marvin_log "ERROR" "npm ci failed — aborting rebuild (reason: ${reason})"
            rm -rf "$backup_dir" 2>/dev/null || true
            return 1
        fi
    fi

    # Build
    marvin_log "INFO" "Running next build..."
    local build_output
    if ! build_output=$(cd "$web_dir" && npm run build 2>&1); then
        marvin_log "ERROR" "next build failed — rolling back (reason: ${reason})"
        marvin_log "ERROR" "Build output: $(echo "$build_output" | tail -20)"
        if [[ -d "$backup_dir" ]]; then
            rm -rf "${web_dir}/.next"
            mv "$backup_dir" "${web_dir}/.next"
        fi
        return 1
    fi

    # Copy static assets into standalone (Next.js standalone doesn't include them)
    # This step is critical — without it the server references JS chunks that don't exist
    if [[ -d "${web_dir}/.next/static" && -d "$standalone_dir" ]]; then
        mkdir -p "${standalone_dir}/.next/static"
        if ! cp -a "${web_dir}/.next/static/." "${standalone_dir}/.next/static/" 2>&1; then
            marvin_log "ERROR" "Static asset copy failed — rolling back (reason: ${reason})"
            if [[ -d "$backup_dir" ]]; then
                rm -rf "${web_dir}/.next"
                mv "$backup_dir" "${web_dir}/.next"
            fi
            return 1
        fi
    fi

    # Restart the service
    marvin_log "INFO" "Restarting marvin-web service..."
    if ! systemctl restart marvin-web 2>/dev/null; then
        marvin_log "ERROR" "marvin-web restart failed — rolling back (reason: ${reason})"
        if [[ -d "$backup_dir" ]]; then
            rm -rf "${web_dir}/.next"
            mv "$backup_dir" "${web_dir}/.next"
            systemctl restart marvin-web 2>/dev/null || true
        fi
        return 1
    fi

    # Wait for the service to become responsive (polling loop instead of fixed sleep)
    local _ready=false
    for _i in $(seq 1 15); do
        sleep 1
        if curl -sf --max-time 2 "http://localhost:3000/" > /dev/null 2>&1; then
            _ready=true
            break
        fi
    done

    if [[ "$_ready" != "true" ]]; then
        marvin_log "ERROR" "Service not responding after restart — rolling back (reason: ${reason})"
        if [[ -d "$backup_dir" ]]; then
            rm -rf "${web_dir}/.next"
            mv "$backup_dir" "${web_dir}/.next"
            systemctl restart marvin-web 2>/dev/null || true
        fi
        return 1
    fi

    # Health check: verify a JS chunk referenced in HTML is servable
    local site_url="http://localhost:3000"
    local js_chunk
    js_chunk=$(curl -s --max-time 10 "${site_url}/" 2>/dev/null \
        | grep -oP 'src="/_next/static/chunks/[^"]*"' | head -1 \
        | grep -oP '/_next/static/chunks/[^"]*' || true)

    if [[ -n "$js_chunk" ]]; then
        local chunk_status
        chunk_status=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "${site_url}${js_chunk}" 2>/dev/null || echo "000")
        if [[ "$chunk_status" != "200" ]]; then
            marvin_log "ERROR" "Post-rebuild JS asset check failed (HTTP ${chunk_status}) — rolling back"
            if [[ -d "$backup_dir" ]]; then
                rm -rf "${web_dir}/.next"
                mv "$backup_dir" "${web_dir}/.next"
                systemctl restart marvin-web 2>/dev/null || true
            fi
            return 1
        fi
    fi

    rm -rf "$backup_dir" 2>/dev/null || true
    marvin_log "INFO" "Web rebuild complete (reason: ${reason})"
    return 0
}
