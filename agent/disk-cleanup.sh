#!/usr/bin/env bash
# =============================================================================
# Marvin — Disk Cleanup Automation
# =============================================================================
# Removes old logs, temp files, and caches to prevent disk exhaustion.
# Runs daily as part of morning-check or standalone.
#
# Cron: Called from morning-check.sh (06:00 UTC)
#       Can also run standalone: agent/disk-cleanup.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

marvin_log "INFO" "Disk cleanup starting"

FREED_BYTES=0
ACTIONS=()

# Helper: track freed space
track_freed() {
    local desc="$1"
    local bytes="$2"
    if [[ "$bytes" -gt 0 ]]; then
        FREED_BYTES=$((FREED_BYTES + bytes))
        local human=$(numfmt --to=iec "$bytes" 2>/dev/null || echo "${bytes}B")
        ACTIONS+=("${desc}: ${human}")
        marvin_log "INFO" "Cleaned ${human}: ${desc}"
    fi
}

# ─── 1. Old compressed system logs (>30 days) ───────────────────────────────

old_logs_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    old_logs_size=$((old_logs_size + fsize))
    rm -f "$f"
done < <(find /var/log -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.old' \) -mtime +30 -print0 2>/dev/null)
track_freed "Compressed system logs (>30d)" "$old_logs_size"

# ─── 2. APT cache cleanup ───────────────────────────────────────────────────

apt_before=$(du -sb /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}' || echo 0)
apt-get clean -y 2>/dev/null || true
apt_after=$(du -sb /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}' || echo 0)
apt_freed=$((apt_before - apt_after))
[[ "$apt_freed" -lt 0 ]] && apt_freed=0
track_freed "APT package cache" "$apt_freed"

# ─── 3. Old Marvin run logs (>14 days) ──────────────────────────────────────
# data/logs/ contains per-run markdown logs that grow quickly.
# Keep 14 days, which is enough for debugging.

run_logs_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    run_logs_size=$((run_logs_size + fsize))
    rm -f "$f"
done < <(find "${LOGS_DIR}" -type f -name "*.md" -mtime +14 -print0 2>/dev/null)
track_freed "Marvin run logs (>14d)" "$run_logs_size"

# ─── 4. Old Marvin daily logs (>30 days) ────────────────────────────────────

daily_logs_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    daily_logs_size=$((daily_logs_size + fsize))
    rm -f "$f"
done < <(find "${LOGS_DIR}" -type f -name "????-??-??.log" -mtime +30 -print0 2>/dev/null)
track_freed "Marvin daily logs (>30d)" "$daily_logs_size"

# ─── 5. Compress metrics JSONL files (>30 days) ─────────────────────────────
# Data retention policy: compress raw JSONL at 30 days, delete at 180 days.
# Daily/hourly summary JSONs are small and kept indefinitely.

# 5a. Compress uncompressed JSONL files older than 30 days
compressed_count=0
compressed_bytes=0
while IFS= read -r -d '' f; do
    if [[ ! -f "${f}.gz" ]]; then
        fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if gzip "$f" 2>/dev/null; then
            gz_size=$(stat -c%s "${f}.gz" 2>/dev/null || echo 0)
            saved=$((fsize - gz_size))
            [[ "$saved" -lt 0 ]] && saved=0
            compressed_bytes=$((compressed_bytes + saved))
            compressed_count=$((compressed_count + 1))
        fi
    fi
done < <(find "${METRICS_DIR}" -type f -name "????-??-??.jsonl" -mtime +30 -print0 2>/dev/null)
if [[ "$compressed_count" -gt 0 ]]; then
    track_freed "Compressed ${compressed_count} metrics JSONL (>30d)" "$compressed_bytes"
fi

# 5b. Delete compressed JSONL files older than 180 days
metrics_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    metrics_size=$((metrics_size + fsize))
    rm -f "$f"
done < <(find "${METRICS_DIR}" -type f -name "????-??-??.jsonl.gz" -mtime +180 -print0 2>/dev/null)
track_freed "Old metrics JSONL.gz (>180d)" "$metrics_size"

# ─── 6. Temp files ──────────────────────────────────────────────────────────

tmp_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    tmp_size=$((tmp_size + fsize))
    rm -f "$f"
done < <(find /tmp -type f -user root -mtime +7 -print0 2>/dev/null)
track_freed "Old temp files (>7d)" "$tmp_size"

# ─── 7. Systemd journal vacuum (keep 7 days) ────────────────────────────────

journal_before=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]' || echo "0")
journalctl --vacuum-time=7d --quiet 2>/dev/null || true
journal_after=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]' || echo "0")
# Log it but don't try to parse the sizes precisely
if [[ "$journal_before" != "$journal_after" ]]; then
    ACTIONS+=("Journal vacuumed: ${journal_before} -> ${journal_after}")
    marvin_log "INFO" "Journal vacuumed: ${journal_before} -> ${journal_after}"
fi

# ─── Report ──────────────────────────────────────────────────────────────────

total_human=$(numfmt --to=iec "$FREED_BYTES" 2>/dev/null || echo "${FREED_BYTES}B")
disk_after=$(df -m / | awk 'NR==2{print $5}')

if [[ ${#ACTIONS[@]} -gt 0 ]]; then
    marvin_log "INFO" "Disk cleanup complete: freed ${total_human} total. Disk now at ${disk_after}."
    for action in "${ACTIONS[@]}"; do
        marvin_log "INFO" "  - ${action}"
    done
else
    marvin_log "INFO" "Disk cleanup complete: nothing to clean. Disk at ${disk_after}."
fi
