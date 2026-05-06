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

# Cron uses a minimal PATH — ensure claude and other tools are findable
export PATH="/root/.local/bin:/usr/local/bin:${PATH}"
LOGS_DIR="${DATA_DIR}/logs"

# GPG key lives in marvin's homedir, but cron runs as root.
# Without this, git commit -S and gpg --detach-sign fail with "No secret key".
export GNUPGHOME="/home/marvin/.gnupg"
METRICS_DIR="${DATA_DIR}/metrics"
BLOG_DIR="$(dirname "${MARVIN_DIR}")/blog"  # Outside git tree — blog data is not tracked
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

# ─── Blog content screening (defense-in-depth for issue #563) ────────────────
# Scans blog text for sensitive data patterns before publishing.
# Prompts already instruct Claude to redact, but this catches anything that
# slips through. Returns 0 if clean, 1 if sensitive patterns found.
#
# When a screen is triggered, the rejected content is preserved at
# /home/marvin/blocked-blogs/LABEL-TIMESTAMP.txt (mode 0600, outside git
# tree and nginx-served paths) so the operator can post-mortem what tripped
# the screen without leaking sensitive content publicly. Otherwise we get
# the bare "kernel version" log message and lose the actual evidence forever
# — exactly what happened on 2026-05-06 when the morning blog was dropped.
_screen_blog_first_match_line() {
    local pattern="$1" content="$2" flags="${3:-}"
    # shellcheck disable=SC2086  # flags must word-split into separate grep args
    grep -nP $flags "$pattern" <<< "$content" 2>/dev/null | head -1 | cut -d: -f1
}

screen_blog_content() {
    local content="$1"
    local label="${2:-blog}"
    local found=""
    local diagnostics=""

    # Fail-closed if grep lacks PCRE support (-P flag)
    if ! echo x | grep -qP 'x' 2>/dev/null; then
        marvin_log "WARN" "${label}: grep -P (PCRE) unsupported — blocking publication (fail-closed)"
        return 1
    fi

    # CVE identifiers — vulnerability details should not be public
    local _line
    _line=$(_screen_blog_first_match_line 'CVE-[0-9]{4}-[0-9]{4,}' "$content" '-i')
    if [[ -n "$_line" ]]; then
        found+="CVE identifier, "
        diagnostics+="CVE@line${_line}, "
    fi

    # Kernel version with build suffix (e.g., 6.8.0-101-generic)
    # Anchored to Linux-style kernel versions: major.minor.patch-build-flavour
    _line=$(_screen_blog_first_match_line '\b[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-(?:generic|lowlatency|cloud|aws|azure|gcp|kvm|virtual)\b' "$content")
    if [[ -n "$_line" ]]; then
        found+="kernel version, "
        diagnostics+="kernel@line${_line}, "
    fi

    # Common API key/token prefixes (sk-ant- for Anthropic keys with hyphens)
    _line=$(_screen_blog_first_match_line '(sk-ant-[a-zA-Z0-9_-]{20,}|sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{30,}|gho_[a-zA-Z0-9]{30,}|AKIA[A-Z0-9]{16})' "$content")
    if [[ -n "$_line" ]]; then
        found+="API key/token, "
        diagnostics+="token@line${_line}, "
    fi

    # SSH private key content (not just path references)
    _line=$(_screen_blog_first_match_line 'BEGIN [A-Z ]*PRIVATE KEY' "$content")
    if [[ -n "$_line" ]]; then
        found+="private key material, "
        diagnostics+="key@line${_line}, "
    fi

    # Sensitive file paths that indicate operational details
    _line=$(_screen_blog_first_match_line '(/etc/shadow|/etc/sudoers|\.env\b|id_rsa|private[._-]key)' "$content" '-i')
    if [[ -n "$_line" ]]; then
        found+="sensitive file path, "
        diagnostics+="path@line${_line}, "
    fi

    if [[ -n "$found" ]]; then
        marvin_log "WARN" "${label}: sensitive content detected (${found%, }) — blocking publication"
        marvin_log "WARN" "${label}: first-match locations: ${diagnostics%, }"

        # Preserve rejected content for forensic review (mode 0600, root-only,
        # outside the nginx-served tree). Caps retention at last 30 files.
        local blocked_dir="/home/marvin/blocked-blogs"
        if mkdir -p "$blocked_dir" 2>/dev/null; then
            chmod 700 "$blocked_dir" 2>/dev/null || true
            local blocked_file="${blocked_dir}/${label}-$(date -u +%Y%m%dT%H%M%SZ).txt"
            local _saved=true
            { printf '%s\n' "$content" > "$blocked_file" 2>/dev/null \
                && chmod 600 "$blocked_file" 2>/dev/null; } || _saved=false
            if [[ "$_saved" == "true" ]]; then
                marvin_log "INFO" "${label}: rejected content saved to ${blocked_file} for post-mortem"
                # Retention: keep only the 30 most recent rejections
                ls -1t "$blocked_dir"/*.txt 2>/dev/null | tail -n +31 | xargs -r rm -f 2>/dev/null || true
            fi
        fi
        return 1
    fi
    return 0
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

# ─── OpenTelemetry — Claude Code usage monitoring (issue #550) ────────────────
# Exports metrics/logs to a local OTEL collector when running.
# See monitoring/ directory for the Docker stack (Collector + Prometheus + Grafana).
# Only enabled when the collector is reachable — avoids 10s OTEL export timeout
# stalling cron jobs when the Docker stack is down (issue #557).
# Uses nc with /dev/tcp fallback so telemetry works even without netcat (issue #559).
_otel_reachable() {
    if command -v nc &>/dev/null; then
        nc -z -w 1 127.0.0.1 4317 2>/dev/null
    else
        (timeout 1 bash -c 'echo >/dev/tcp/127.0.0.1/4317') 2>/dev/null
    fi
}
if _otel_reachable; then
    export CLAUDE_CODE_ENABLE_TELEMETRY=1
    export OTEL_METRICS_EXPORTER=otlp
    export OTEL_LOGS_EXPORTER=otlp
    export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
    export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
    # Security: do NOT log prompt content or tool details — only usage metrics
    # export OTEL_LOG_USER_PROMPTS=1      # disabled — prompt content is sensitive
    # export OTEL_LOG_TOOL_DETAILS=1      # disabled — tool args may contain secrets
fi

# ─── Source library modules ───────────────────────────────────────────────────
# Order matters: logging first (used by metrics and claude), then metrics
# (used by claude's collect_metrics), then claude.
_MARVIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
source "${_MARVIN_LIB_DIR}/logging.sh"
source "${_MARVIN_LIB_DIR}/metrics.sh"
source "${_MARVIN_LIB_DIR}/claude.sh"
source "${_MARVIN_LIB_DIR}/prompts.sh"

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
    # Uses mkdir for atomic lock creation (POSIX guarantee) to avoid TOCTOU.
    local lock_dir="/tmp/marvin-web-build.lock.d"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        # Lock exists — check staleness and owner
        local lock_age lock_pid
        lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
        lock_age=$(( $(date +%s) - $(stat -c%Y "$lock_dir" 2>/dev/null || echo "0") ))
        if [[ "$lock_age" -gt 600 ]]; then
            # Stale lock (>10 min) — previous build crashed without cleanup
            marvin_log "WARN" "Removing stale build lock (age ${lock_age}s, PID ${lock_pid})"
            rm -rf "$lock_dir"
            mkdir "$lock_dir" 2>/dev/null || { marvin_log "WARN" "Web rebuild skipped — lost lock race (reason: ${reason})"; return 2; }
        elif [[ -z "$lock_pid" ]]; then
            # Empty/missing PID file — lock is corrupt, reclaim it
            marvin_log "WARN" "Removing corrupt build lock (no PID recorded)"
            rm -rf "$lock_dir"
            mkdir "$lock_dir" 2>/dev/null || { marvin_log "WARN" "Web rebuild skipped — lost lock race (reason: ${reason})"; return 2; }
        elif kill -0 "$lock_pid" 2>/dev/null; then
            # Guard against PID reuse: compare process start time with recorded value
            local recorded_start actual_start
            recorded_start=$(cat "$lock_dir/start" 2>/dev/null || echo "")
            actual_start=$(awk '{print $22}' "/proc/${lock_pid}/stat" 2>/dev/null || echo "")
            if [[ -n "$recorded_start" && -n "$actual_start" && "$recorded_start" != "$actual_start" ]]; then
                marvin_log "WARN" "Removing build lock — PID ${lock_pid} reused by different process"
                rm -rf "$lock_dir"
                mkdir "$lock_dir" 2>/dev/null || { marvin_log "WARN" "Web rebuild skipped — lost lock race (reason: ${reason})"; return 2; }
            else
                marvin_log "WARN" "Web rebuild skipped — another build in progress (PID ${lock_pid}, reason: ${reason})"
                return 2
            fi
        else
            marvin_log "WARN" "Removing orphaned build lock (PID ${lock_pid} not running)"
            rm -rf "$lock_dir"
            mkdir "$lock_dir" 2>/dev/null || { marvin_log "WARN" "Web rebuild skipped — lost lock race (reason: ${reason})"; return 2; }
        fi
    fi
    # Write PID for staleness/orphan detection. Guard with || to prevent
    # set -e from killing the script (which would skip the RETURN trap and
    # leak the lock directory — see issue #521).
    if ! echo "$$" > "$lock_dir/pid" 2>/dev/null; then
        marvin_log "ERROR" "Failed to write PID to lock — releasing lock (reason: ${reason})"
        rm -rf "$lock_dir"
        return 1
    fi
    # Record process start time for PID-reuse detection (fixes #526)
    # Atomic write: tmp+mv prevents concurrent readers from seeing a partial file
    awk '{print $22}' "/proc/$$/stat" > "$lock_dir/start.tmp" 2>/dev/null \
        && mv "$lock_dir/start.tmp" "$lock_dir/start" \
        || marvin_log "WARN" "Could not record start time for lock — PID reuse detection disabled"
    # Run the build inside a subshell so the EXIT trap guarantees lock
    # cleanup regardless of how the subshell terminates — including set -e
    # kills, which do NOT fire RETURN traps (fixes #521, #523).
    (
        trap "rm -rf '${lock_dir}' || true" EXIT

        local web_dir="${WEB_DIR}"
        local standalone_dir="${web_dir}/.next/standalone"
        local backup_dir="${web_dir}/.next-backup-$(date +%s)"

        marvin_log "INFO" "Web rebuild starting (reason: ${reason})"

        # Drop to marvin user for npm operations when running as root.
        # Cron runs this as root; without privilege drop, npm creates
        # root-owned files in .next/ and node_modules/. Subsequent
        # deploy-web.sh runs (which already drop to marvin via su) then
        # fail with EACCES — see lesson `npm-as-root-creates-bad-ownership`.
        # Mirrors the _run_npm pattern in deploy-web.sh.
        local _drop_to_marvin=false
        [[ $EUID -eq 0 ]] && _drop_to_marvin=true

        # If a previous root-owned run left files behind, fix ownership before
        # npm runs as marvin — otherwise `npm ci` fails with EACCES on unlink.
        # Must run BEFORE the backup so a rollback after a failed build restores
        # marvin-owned files, not the same root-owned residue we just fixed (#682).
        if [[ "$_drop_to_marvin" == "true" ]]; then
            if [[ -d "${web_dir}/node_modules" ]] && find "${web_dir}/node_modules" -not -user marvin -print -quit 2>/dev/null | grep -q .; then
                marvin_log "WARN" "Found root-owned files in node_modules — fixing ownership"
                chown -R marvin:marvin "${web_dir}/node_modules" 2>/dev/null || true
            fi
            if [[ -d "${web_dir}/.next" ]] && find "${web_dir}/.next" -not -user marvin -print -quit 2>/dev/null | grep -q .; then
                marvin_log "WARN" "Found root-owned files in .next — fixing ownership"
                chown -R marvin:marvin "${web_dir}/.next" 2>/dev/null || true
            fi
        fi

        # Backup current build for rollback (after chown, so the backup itself
        # is marvin-owned and restoring it cannot reintroduce root ownership).
        if [[ -d "${web_dir}/.next" ]]; then
            cp -a "${web_dir}/.next" "$backup_dir" 2>/dev/null || true
        fi

        # Prune old backups — keep only the 3 most recent
        ls -dt "${web_dir}"/.next-backup-* 2>/dev/null | tail -n +4 | xargs rm -rf 2>/dev/null || true

        # Install deps if node_modules missing or package-lock.json changed
        if [[ ! -d "${web_dir}/node_modules" ]] || \
           [[ "${web_dir}/package-lock.json" -nt "${web_dir}/node_modules" ]]; then
            marvin_log "INFO" "Installing web dependencies..."
            # Pipe lives OUTSIDE su -c: the bash spawned by `su -c` starts
            # without `pipefail`, so an `npm ci ... | tail -5` inside the -c
            # string would let `tail` mask npm's non-zero exit. Keeping the pipe
            # at this level lets parent pipefail propagate npm's status. (#680/#681)
            local _ci_ok=true
            if [[ "$_drop_to_marvin" == "true" ]]; then
                su -s /bin/bash marvin -c 'cd "$1" && npm ci --production=false' -- "$web_dir" 2>&1 | tail -5 || _ci_ok=false
            else
                (cd "$web_dir" && npm ci --production=false) 2>&1 | tail -5 || _ci_ok=false
            fi
            if [[ "$_ci_ok" != "true" ]]; then
                marvin_log "ERROR" "npm ci failed — aborting rebuild (reason: ${reason})"
                rm -rf "$backup_dir" 2>/dev/null || true
                exit 1
            fi
        fi

        # Build
        marvin_log "INFO" "Running next build..."
        local build_output build_ok=true
        if [[ "$_drop_to_marvin" == "true" ]]; then
            build_output=$(su -s /bin/bash marvin -c 'cd "$1" && timeout 300 npm run build' -- "$web_dir" 2>&1) || build_ok=false
        else
            build_output=$(cd "$web_dir" && timeout 300 npm run build 2>&1) || build_ok=false
        fi
        if [[ "$build_ok" != "true" ]]; then
            marvin_log "ERROR" "next build failed — rolling back (reason: ${reason})"
            marvin_log "ERROR" "Build output: $(echo "$build_output" | tail -20)"
            if [[ -d "$backup_dir" ]]; then
                rm -rf "${web_dir}/.next"
                mv "$backup_dir" "${web_dir}/.next"
            fi
            exit 1
        fi

        # Defense-in-depth: ensure .next is fully marvin-owned regardless of
        # which path produced it. The marvin-web service runs as marvin and
        # mixed ownership has historically caused EACCES on subsequent rebuilds.
        if [[ "$_drop_to_marvin" == "true" ]]; then
            chown -R marvin:marvin "${web_dir}/.next" 2>/dev/null || true
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
                exit 1
            fi
        fi

        # Restart the service
        marvin_log "INFO" "Restarting marvin-web service..."
        if ! timeout 30 systemctl restart marvin-web 2>/dev/null; then
            marvin_log "ERROR" "marvin-web restart failed — rolling back (reason: ${reason})"
            if [[ -d "$backup_dir" ]]; then
                rm -rf "${web_dir}/.next"
                mv "$backup_dir" "${web_dir}/.next"
                timeout 30 systemctl restart marvin-web 2>/dev/null || true
            fi
            exit 1
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
                timeout 30 systemctl restart marvin-web 2>/dev/null || true
            fi
            exit 1
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
                    timeout 30 systemctl restart marvin-web 2>/dev/null || true
                fi
                exit 1
            fi
        fi

        rm -rf "$backup_dir" 2>/dev/null || true
        marvin_log "INFO" "Web rebuild complete (reason: ${reason})"
        exit 0
    )
}
