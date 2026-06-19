#!/usr/bin/env bash
# =============================================================================
# Marvin — File Integrity Monitoring
# =============================================================================
# Maintains SHA-256 checksums for critical system and agent files.
# On first run, creates a baseline. On subsequent runs, compares against
# the baseline and alerts on any unexpected changes.
#
# Baseline is refreshed when Marvin intentionally modifies files (via
# self-enhance, morning-check git pull, etc.) by calling:
#   agent/file-integrity.sh --update
#
# Cron: Runs as part of security-scan.sh (daily at 04:00 UTC)
#       Can also run standalone: agent/file-integrity.sh [--update]
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

SECURITY_DIR="${DATA_DIR}/security"
BASELINE_FILE="${SECURITY_DIR}/file-integrity-baseline.json"
REPORT_FILE="${SECURITY_DIR}/file-integrity-${TODAY}.json"

mkdir -p "$SECURITY_DIR"

# ─── Files to monitor ────────────────────────────────────────────────────────
# Critical system configs, agent scripts, and security-sensitive files.
# Directories are expanded into their files at scan time.

MONITORED_PATHS=(
    # SSH
    /etc/ssh/sshd_config
    # Firewall
    /etc/ufw/user.rules
    /etc/ufw/user6.rules
    # Fail2ban
    /etc/fail2ban/jail.local
    # Nginx
    /etc/nginx/nginx.conf
    # Cron
    /etc/cron.d/marvin
    # PAM (auth stack)
    /etc/pam.d/sshd
    # Sudoers
    /etc/sudoers
    # Name resolution
    /etc/hosts
    /etc/resolv.conf
    # Marvin agent scripts
    "${MARVIN_DIR}/agent/common.sh"
    "${MARVIN_DIR}/agent/health-monitor.sh"
    "${MARVIN_DIR}/agent/morning-check.sh"
    "${MARVIN_DIR}/agent/self-enhance.sh"
    "${MARVIN_DIR}/agent/log-export.sh"
    "${MARVIN_DIR}/agent/security-scan.sh"
    "${MARVIN_DIR}/agent/self-test.sh"
    "${MARVIN_DIR}/agent/lib/github.sh"
)

# Also include all nginx site configs
for f in /etc/nginx/sites-enabled/*; do
    [[ -f "$f" ]] && MONITORED_PATHS+=("$f")
done

# And all fail2ban jail configs
for f in /etc/fail2ban/jail.d/*.conf; do
    [[ -f "$f" ]] && MONITORED_PATHS+=("$f")
done

# ─── Compute checksums ───────────────────────────────────────────────────────

compute_checksums() {
    local result="{"
    local first=true

    for filepath in "${MONITORED_PATHS[@]}"; do
        [[ -f "$filepath" ]] || continue

        local hash
        hash=$(sha256sum "$filepath" 2>/dev/null | awk '{print $1}')
        local size
        size=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
        local mtime
        mtime=$(stat -c%Y "$filepath" 2>/dev/null || echo 0)

        if [[ "$first" == "true" ]]; then
            first=false
        else
            result+=","
        fi

        # Escape the filepath for JSON
        local escaped_path
        escaped_path=$(printf '%s' "$filepath" | sed 's/"/\\"/g')

        result+="\"${escaped_path}\":{\"sha256\":\"${hash}\",\"size\":${size},\"mtime\":${mtime}}"
    done

    result+="}"
    echo "$result" | jq '.'
}

# ─── Mode: Update baseline ───────────────────────────────────────────────────

if [[ "${1:-}" == "--update" ]]; then
    caller_pid="${PPID:-unknown}"
    caller_name=$(ps -o comm= -p "$caller_pid" 2>/dev/null || echo "unknown")

    # Capture old baseline info for audit trail (#94)
    prev_ts="none"
    prev_hash="none"
    prev_count=0
    if [[ -f "$BASELINE_FILE" ]]; then
        prev_ts=$(jq -r '.created // "unknown"' "$BASELINE_FILE" 2>/dev/null || echo "unreadable")
        prev_count=$(jq '(.files // {}) | keys | length' "$BASELINE_FILE" 2>/dev/null || echo 0)
        prev_hash=$(sha256sum "$BASELINE_FILE" 2>/dev/null | awk '{print $1}' || echo "unreadable")
    fi

    marvin_log "WARN" "File integrity: baseline reset by ${caller_name} (PID ${caller_pid}), previous baseline: ${prev_ts} (${prev_count} files, sha256:${prev_hash:0:16}…)"
    checksums=$(compute_checksums)
    tmp_baseline=$(mktemp --tmpdir="$SECURITY_DIR" .baseline.XXXXXX)
    trap 'rm -f "$tmp_baseline"' EXIT
    jq -n --argjson files "$checksums" --arg ts "$NOW" --arg caller "${caller_name}[${caller_pid}]" \
        --arg prev_ts "$prev_ts" --arg prev_hash "$prev_hash" --argjson prev_count "$prev_count" \
        '{created: $ts, updated_by: $caller, previous_baseline: {timestamp: $prev_ts, sha256: $prev_hash, file_count: $prev_count}, files: $files}' > "$tmp_baseline"
    chmod 600 "$tmp_baseline"
    mv -f "$tmp_baseline" "$BASELINE_FILE"
    trap - EXIT
    marvin_log "WARN" "File integrity baseline updated: $(echo "$checksums" | jq 'keys | length') files (reset by ${caller_name})"
    exit 0
fi

# ─── Mode: Check against baseline ────────────────────────────────────────────

marvin_log "INFO" "File integrity check starting"

# If no baseline exists, create one and exit clean
if [[ ! -f "$BASELINE_FILE" ]]; then
    marvin_log "INFO" "No baseline found — creating initial baseline"
    checksums=$(compute_checksums)
    tmp_baseline=$(mktemp --tmpdir="$SECURITY_DIR" .baseline.XXXXXX)
    trap 'rm -f "$tmp_baseline"' EXIT
    jq -n --argjson files "$checksums" --arg ts "$NOW" \
        '{created: $ts, files: $files}' > "$tmp_baseline"
    chmod 600 "$tmp_baseline"
    mv -f "$tmp_baseline" "$BASELINE_FILE"
    trap - EXIT

    # Report: baseline created, no changes to report
    cat > "$REPORT_FILE" << EOF
{
  "timestamp": "${NOW}",
  "status": "baseline_created",
  "files_monitored": $(echo "$checksums" | jq 'keys | length'),
  "changes": [],
  "new_files": [],
  "missing_files": []
}
EOF
    chmod 644 "$REPORT_FILE"
    marvin_log "INFO" "File integrity baseline created with $(echo "$checksums" | jq 'keys | length') files"
    exit 0
fi

# Compute current checksums
current=$(compute_checksums)
baseline_files=$(jq '.files' "$BASELINE_FILE")
baseline_ts=$(jq -r '.created' "$BASELINE_FILE")

# Helper: returns 0 if file's current content matches its blob at git HEAD.
# Used to distinguish legitimate updates pulled from upstream commits (which
# are auto-trusted) from genuine tampering. Files outside MARVIN_DIR or not
# tracked in git always return 1 (treated as tampered if changed).
_matches_git_head() {
    local filepath="$1"
    [[ "$filepath" != "$MARVIN_DIR"/* ]] && return 1
    command -v git >/dev/null 2>&1 || return 1
    local relpath="${filepath#"$MARVIN_DIR"/}"
    local git_sha disk_sha
    git_sha=$(git -C "$MARVIN_DIR" rev-parse "HEAD:${relpath}" 2>/dev/null) || return 1
    disk_sha=$(git -C "$MARVIN_DIR" hash-object "$filepath" 2>/dev/null) || return 1
    [[ -n "$git_sha" && "$git_sha" == "$disk_sha" ]]
}

# Helper: returns 0 if a live /etc config file's current content byte-matches
# its version-controlled source under setup/ — compared against the committed
# git blob, not the disk working-tree copy. This is the config-file analogue of
# _matches_git_head and shares its exact trust model: the comparison is rooted
# in the immutable git object store (HEAD:setup/...), so an attacker cannot make
# a tampered live config "match" by also editing the on-disk setup/ source — that
# edit is invisible until committed. The live configs are deployed from the
# repo's setup/ sources, so a live file byte-identical to its committed source is
# a legitimate, auditable deploy — not tampering. The mapping mirrors the
# source⇆live drift tripwire in self-test.sh section 9d. Paths with no committed
# counterpart (e.g. /etc/nginx/nginx.conf) return 1 and still alert if changed.
_matches_repo_source() {
    local filepath="$1"
    command -v git >/dev/null 2>&1 || return 1

    # /etc/cron.d/marvin is not stored as a standalone committed file — it is
    # generated from a single-quoted heredoc inside setup/setup-cron.sh. Extract
    # that heredoc from the COMMITTED blob (HEAD:setup/setup-cron.sh), not the
    # working-tree copy, so the trust chain stays anchored in the git object
    # store exactly like _matches_git_head: an attacker editing the on-disk
    # setup-cron.sh cannot make a tampered live cron "match" until the edit is
    # committed. The awk extraction is identical to self-test §9d's drift check;
    # the 'EOF' delimiter is single-quoted so ${MARVIN_DIR} stays literal in
    # both sides, making a byte-for-byte diff valid. (\047 in the awk pattern is
    # an octal-escaped single-quote, so the pattern matches the literal << 'EOF'.)
    if [[ "$filepath" == /etc/cron.d/marvin ]]; then
        local heredoc
        heredoc=$(git -C "$MARVIN_DIR" show "HEAD:setup/setup-cron.sh" 2>/dev/null \
            | awk '/cat > "\$CRON_FILE" << \047EOF\047/{f=1;next} f&&/^EOF$/{exit} f') || return 1
        [[ -n "$heredoc" ]] || return 1
        diff -q <(printf '%s\n' "$heredoc") "$filepath" >/dev/null 2>&1
        return $?
    fi

    local git_path=""
    # Keep this mapping in sync with MONITORED_PATHS above: any new sites-enabled/*
    # config that has a committed setup/ counterpart needs a parallel case entry,
    # else it will alert as CHANGED forever after a legitimate deploy.
    case "$filepath" in
        /etc/nginx/sites-enabled/marvin)     git_path="setup/nginx-site.conf" ;;
        /etc/nginx/sites-enabled/monitoring) git_path="setup/nginx-monitoring.conf" ;;
        *) return 1 ;;
    esac
    # Compare the live file against the committed blob, not the disk working-tree
    # copy, so the trust chain is anchored in the git object store. diff
    # transparently follows the sites-enabled → sites-available symlink.
    git -C "$MARVIN_DIR" show "HEAD:${git_path}" 2>/dev/null | diff -q - "$filepath" >/dev/null 2>&1
}

CHANGED=()
GIT_SYNCED=()
CONFIG_SYNCED=()
NEW_FILES=()
MISSING=()

# Check each file in baseline
while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue

    baseline_hash=$(echo "$baseline_files" | jq -r --arg f "$filepath" '.[$f].sha256 // ""')
    current_hash=$(echo "$current" | jq -r --arg f "$filepath" '.[$f].sha256 // ""')

    if [[ -z "$current_hash" ]]; then
        # File no longer exists or not in current scan
        if [[ ! -f "$filepath" ]]; then
            MISSING+=("$filepath")
            marvin_log "WARN" "File integrity: MISSING — ${filepath}"
        fi
    elif [[ "$baseline_hash" != "$current_hash" ]]; then
        if _matches_git_head "$filepath"; then
            # Changed contents match git HEAD — legitimate pull from upstream.
            # Keeps the file out of the alert path and lets us auto-refresh.
            GIT_SYNCED+=("$filepath")
            marvin_log "INFO" "File integrity: git-synced — ${filepath} (matches HEAD)"
        elif _matches_repo_source "$filepath"; then
            # Live config byte-matches its committed setup/ source — a
            # legitimate deploy, not tampering. Same trust handling as
            # git-synced: kept out of the alert path, eligible for auto-refresh.
            CONFIG_SYNCED+=("$filepath")
            marvin_log "INFO" "File integrity: config-synced — ${filepath} (matches setup/ source)"
        else
            CHANGED+=("$filepath")
            marvin_log "WARN" "File integrity: CHANGED — ${filepath}"
        fi
    fi
done < <(echo "$baseline_files" | jq -r 'keys[]')

# Check for new files in current scan that weren't in baseline
while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue
    baseline_hash=$(echo "$baseline_files" | jq -r --arg f "$filepath" '.[$f].sha256 // ""')
    if [[ -z "$baseline_hash" ]]; then
        NEW_FILES+=("$filepath")
        marvin_log "INFO" "File integrity: NEW — ${filepath}"
    fi
done < <(echo "$current" | jq -r 'keys[]')

# Auto-refresh baseline when ALL changes are provably legitimate — either
# git-synced (content matches the committed HEAD blob) or config-synced (a
# live /etc config that byte-matches its committed setup/ source). If even
# one tampered (CHANGED), missing, or NEW file exists, leave the baseline
# alone — we want those situations investigated rather than silently baked
# into the baseline. New files in dynamically-monitored paths
# (/etc/nginx/sites-enabled/*, /etc/fail2ban/jail.d/*) are outside MARVIN_DIR
# and can never be git-tracked; auto-trusting them would let a rogue config
# slip in whenever a legitimate agent-script pull happened in the same window
# (issue #633). New files still require an explicit --update call.
if [[ $(( ${#GIT_SYNCED[@]} + ${#CONFIG_SYNCED[@]} )) -gt 0 && ${#CHANGED[@]} -eq 0 && ${#MISSING[@]} -eq 0 && ${#NEW_FILES[@]} -eq 0 ]]; then
    prev_ts=$(jq -r '.created // "unknown"' "$BASELINE_FILE" 2>/dev/null || echo "unknown")
    prev_count=$(jq '(.files // {}) | keys | length' "$BASELINE_FILE" 2>/dev/null || echo 0)
    prev_hash=$(sha256sum "$BASELINE_FILE" 2>/dev/null | awk '{print $1}' || echo "unknown")
    # Atomic write (#634): jq to a temp file in the same directory, then mv-f
    # into place. A direct `> "$BASELINE_FILE"` truncates before jq runs; if
    # jq fails mid-execution (disk full, OOM) the baseline is left empty and
    # integrity monitoring is silently down. mv on the same filesystem is
    # atomic, so a crash between jq and mv leaves the old baseline intact.
    tmp_baseline=$(mktemp "${BASELINE_FILE}.XXXXXX")
    if ! jq -n --argjson files "$current" --arg ts "$NOW" --arg caller "auto-sync" \
            --arg prev_ts "$prev_ts" --arg prev_hash "$prev_hash" --argjson prev_count "$prev_count" \
            '{created: $ts, updated_by: $caller, previous_baseline: {timestamp: $prev_ts, sha256: $prev_hash, file_count: $prev_count}, files: $files}' > "$tmp_baseline"; then
        rm -f "$tmp_baseline"
        marvin_log "ERROR" "File integrity: jq failed during auto-refresh; baseline preserved"
        exit 1
    fi
    # chmod 600 on the temp file BEFORE mv (issue #636): mktemp uses the
    # process umask (often rw-r--r--), so chmod-after-mv would leave a brief
    # window where $BASELINE_FILE is readable beyond owner. Restrict first,
    # rename second — matches the pattern used in PR #635 for --update path.
    chmod 600 "$tmp_baseline"
    mv -f "$tmp_baseline" "$BASELINE_FILE"
    marvin_log "INFO" "File integrity: baseline auto-refreshed (${#GIT_SYNCED[@]} git-synced, ${#CONFIG_SYNCED[@]} config-synced change(s), prev baseline ${prev_ts})"
fi

# Determine status
status="clean"
if [[ ${#CHANGED[@]} -gt 0 || ${#MISSING[@]} -gt 0 ]]; then
    status="alert"
fi

# Build JSON arrays
changed_json="[]"
if [[ ${#CHANGED[@]} -gt 0 ]]; then
    changed_json=$(printf '%s\n' "${CHANGED[@]}" | jq -R . | jq -s .)
fi

missing_json="[]"
if [[ ${#MISSING[@]} -gt 0 ]]; then
    missing_json=$(printf '%s\n' "${MISSING[@]}" | jq -R . | jq -s .)
fi

new_json="[]"
if [[ ${#NEW_FILES[@]} -gt 0 ]]; then
    new_json=$(printf '%s\n' "${NEW_FILES[@]}" | jq -R . | jq -s .)
fi

git_synced_json="[]"
if [[ ${#GIT_SYNCED[@]} -gt 0 ]]; then
    git_synced_json=$(printf '%s\n' "${GIT_SYNCED[@]}" | jq -R . | jq -s .)
fi

config_synced_json="[]"
if [[ ${#CONFIG_SYNCED[@]} -gt 0 ]]; then
    config_synced_json=$(printf '%s\n' "${CONFIG_SYNCED[@]}" | jq -R . | jq -s .)
fi

# Write report
cat > "$REPORT_FILE" << EOF
{
  "timestamp": "${NOW}",
  "status": "${status}",
  "baseline_created": "${baseline_ts}",
  "files_monitored": $(echo "$current" | jq 'keys | length'),
  "changes": ${changed_json},
  "git_synced": ${git_synced_json},
  "config_synced": ${config_synced_json},
  "new_files": ${new_json},
  "missing_files": ${missing_json}
}
EOF
chmod 644 "$REPORT_FILE"

# Also maintain a latest pointer
cp "$REPORT_FILE" "${SECURITY_DIR}/file-integrity-latest.json"

total_changes=$((${#CHANGED[@]} + ${#MISSING[@]}))
marvin_log "INFO" "File integrity check complete: ${status} (${total_changes} change(s), ${#NEW_FILES[@]} new)"

# If changes detected, this is notable
if [[ "$status" == "alert" ]]; then
    marvin_log "WARN" "File integrity ALERT: ${#CHANGED[@]} changed, ${#MISSING[@]} missing since baseline (${baseline_ts})"
fi
