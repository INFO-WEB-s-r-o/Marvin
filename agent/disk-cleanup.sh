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
trap marvin_error_trap ERR
marvin_parse_args "$@"

marvin_log "INFO" "Disk cleanup starting"

FREED_BYTES=0
ACTIONS=()

# Helper: track freed space
track_freed() {
    local desc="$1"
    local bytes="$2"
    if [[ "$bytes" -gt 0 ]]; then
        FREED_BYTES=$((FREED_BYTES + bytes))
        local human
        human=$(numfmt --to=iec "$bytes" 2>/dev/null || echo "${bytes}B")
        ACTIONS+=("${desc}: ${human}")
        marvin_log "INFO" "Cleaned ${human}: ${desc}"
    fi
}

# ─── 1. Old compressed system logs (>30 days) ───────────────────────────────

old_logs_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    old_logs_size=$((old_logs_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find /var/log -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.old' \) -mtime +30 -print0 2>/dev/null)
track_freed "Compressed system logs (>30d)" "$old_logs_size"

# ─── 2. APT cache cleanup ───────────────────────────────────────────────────

apt_before=$(du -sb /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}' || echo 0)
marvin_is_dry_run || apt-get clean -y 2>/dev/null || true
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
    marvin_is_dry_run || rm -f "$f"
done < <(find "${LOGS_DIR}" -type f -name "*.md" -mtime +14 -print0 2>/dev/null)
track_freed "Marvin run logs (>14d)" "$run_logs_size"

# ─── 4. Old Marvin daily logs (>30 days) ────────────────────────────────────

daily_logs_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    daily_logs_size=$((daily_logs_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${LOGS_DIR}" -type f -name "????-??-??.log" -mtime +30 -print0 2>/dev/null)
track_freed "Marvin daily logs (>30d)" "$daily_logs_size"

# ─── 5. Compress time-series JSONL files (>30 days) ─────────────────────────
# Data retention policy: compress raw JSONL at 30 days, delete at 180 days.
# Covers every one-file-per-day JSONL family across METRICS_DIR and LOGS_DIR:
#   - ????-??-??.jsonl                  (raw 5-min metrics)
#   - claude-usage-????-??-??.jsonl     (per-Claude-run usage/latency)
#   - latency-????-??-??.jsonl          (network latency probes)
#   - ????-??-??-structured.jsonl       (structured JSON logs, in LOGS_DIR)
# Before 2026-06-16 only the bare ????-??-??.jsonl metrics family was covered;
# the other three grew unbounded one file/day (claude-usage back to 2026-03-07,
# 100+ files). All consumers read these by exact recent-date filename
# (perf-analytics 7d window, weekly-analytics ~14d, log-analysis today-only),
# so compressing files >30d old is safe — no consumer ever constructs a name
# for a date that far back, and a missing old date already degrades gracefully.
# Daily/hourly summary .json files are small, not .jsonl, and kept indefinitely.
_TS_JSONL_NAMES=(
    -name "????-??-??.jsonl"
    -o -name "claude-usage-????-??-??.jsonl"
    -o -name "latency-????-??-??.jsonl"
    -o -name "????-??-??-structured.jsonl"
)
# Same families, compressed — derived from _TS_JSONL_NAMES so the two can never
# drift: a fifth family is added in exactly one place (above) and its .gz variant
# follows automatically. Each "*.jsonl" pattern gains a ".gz" suffix; the -name/-o
# find operators pass through unchanged.
_TS_JSONL_GZ_NAMES=()
for _el in "${_TS_JSONL_NAMES[@]}"; do
    if [[ "${_el}" == *.jsonl ]]; then
        _TS_JSONL_GZ_NAMES+=("${_el}.gz")
    else
        _TS_JSONL_GZ_NAMES+=("${_el}")
    fi
done

# 5a. Compress uncompressed JSONL files older than 30 days
compressed_count=0
compressed_bytes=0
while IFS= read -r -d '' f; do
    if [[ ! -f "${f}.gz" ]]; then
        fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if marvin_is_dry_run; then
            compressed_bytes=$((compressed_bytes + fsize / 2))  # estimate 50% compression
            compressed_count=$((compressed_count + 1))
        elif gzip "$f" 2>/dev/null; then
            gz_size=$(stat -c%s "${f}.gz" 2>/dev/null || echo 0)
            saved=$((fsize - gz_size))
            [[ "$saved" -lt 0 ]] && saved=0
            compressed_bytes=$((compressed_bytes + saved))
            compressed_count=$((compressed_count + 1))
        fi
    fi
done < <(find "${METRICS_DIR}" "${LOGS_DIR}" -maxdepth 1 -type f \( "${_TS_JSONL_NAMES[@]}" \) -mtime +30 -print0 2>/dev/null)
if [[ "$compressed_count" -gt 0 ]]; then
    track_freed "Compressed ${compressed_count} time-series JSONL (>30d)" "$compressed_bytes"
fi

# 5b. Delete compressed JSONL files older than 180 days
metrics_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    metrics_size=$((metrics_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${METRICS_DIR}" "${LOGS_DIR}" -maxdepth 1 -type f \( "${_TS_JSONL_GZ_NAMES[@]}" \) -mtime +180 -print0 2>/dev/null)
track_freed "Old time-series JSONL.gz (>180d)" "$metrics_size"

# ─── 6. Temp files ──────────────────────────────────────────────────────────

tmp_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    tmp_size=$((tmp_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find /tmp -type f -user root -mtime +7 -print0 2>/dev/null)
track_freed "Old temp files (>7d)" "$tmp_size"

# ─── 6b. Orphaned Claude output temp files in LOGS_DIR ──────────────────────
# run_claude() (lib/claude.sh) captures Claude's response to a temp file
# created as ${LOGS_DIR}/claude-output-XXXXXX.tmp and removes it via a RETURN
# trap. A SIGKILL (OOM kill, reboot, or external timeout kill mid-run) bypasses
# that trap and leaks the temp file forever: sections 3/4 above only match *.md
# and the daily ????-??-??.log, and section 6 only sweeps /tmp — none of them
# ever match these. Every Claude run creates one, so this is the most likely
# orphan source on the box. Age-gate at >1 day (-mtime +0): no single
# `claude -p` invocation runs anywhere near that long, so anything older is
# definitively orphaned and an in-flight run's temp file is never at risk.
# -maxdepth 1 keeps the sweep to the files run_claude writes directly in LOGS_DIR.
claude_tmp_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    claude_tmp_size=$((claude_tmp_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${LOGS_DIR}" -maxdepth 1 -type f -name 'claude-output-*.tmp' -mtime +0 -print0 2>/dev/null)
track_freed "Orphaned Claude output temp files (>1d)" "$claude_tmp_size"

# ─── 6c. Orphaned scratch directories in /tmp ───────────────────────────────
# Section 6 above is -type f only, so it never sweeps directories. self-test.sh
# and ad hoc verification runs create scratch dirs (mktemp -d, or a plain
# mkdir for a named fixture like "negtest") that are normally rm -rf'd by the
# script itself, but leak — same root cause as 6b — when the run is killed
# (timeout, OOM) before its own cleanup executes. Nothing else ever sweeps
# them, so they accumulate indefinitely (34MB removed by hand on 2026-07-27).
# Root-owned + >7d mirrors section 6's file sweep; the name excludes protect
# the small fixed set of long-lived system directories that also live
# directly under /tmp (X11/ICE/XIM/font sockets, snap's private tmp, per-unit
# systemd-private dirs, and ssh-agent forwarding sockets) — all confirmed
# present and root-owned on this host, so an unqualified sweep would have
# deleted them.
tmp_dir_size=0
while IFS= read -r -d '' d; do
    dsize=$(du -sb "$d" 2>/dev/null | cut -f1)
    tmp_dir_size=$((tmp_dir_size + ${dsize:-0}))
    marvin_is_dry_run || rm -rf "$d"
done < <(find /tmp -mindepth 1 -maxdepth 1 -type d -user root -mtime +7 \
    ! -name '.X11-unix' ! -name '.ICE-unix' ! -name '.XIM-unix' ! -name '.font-unix' ! -name '.Test-unix' \
    ! -name 'snap-private-tmp' ! -name 'systemd-private-*' ! -name 'ssh-*' \
    -print0 2>/dev/null)
track_freed "Old scratch directories (>7d)" "$tmp_dir_size"

# ─── 6c. Orphaned log-watcher forensic artifacts in COMMS_DIR (>30 days) ────
# log-watcher.sh writes two forensic-only files when Claude is unavailable or
# its output won't parse: pending-log-review.txt (raw logs that went
# un-analyzed during an outage, since offsets advance regardless) and
# log-analysis-raw-<ts>.txt (one per parse failure). Neither is read back by
# any consumer, and COMMS_DIR is not swept by any section above. Stale records
# (>30d — the outage they captured is long over) are safe to remove. The live
# pending file self-caps at 512 KB in log-watcher.sh, so during an active
# outage it stays bounded AND fresh (mtime recent → not matched here); only
# records gone quiet for a month are cleaned. The per-day
# log-analysis-YYYY-MM-DD.json analysis files are handled separately by section
# 6d below (compress + long retain, not deleted here).
comms_forensic_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    comms_forensic_size=$((comms_forensic_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${COMMS_DIR}" -maxdepth 1 -type f \( -name 'log-analysis-raw-*.txt' -o -name 'pending-log-review.txt' \) -mtime +30 -print0 2>/dev/null)
track_freed "Stale log-watcher forensic records (>30d)" "$comms_forensic_size"

# ─── 6d. Per-day comms log-analysis JSON retention (compress >30d, del >180d) ─
# log-watcher.sh writes one ${COMMS_DIR}/log-analysis-YYYY-MM-DD.json per day —
# Claude's classification of that day's incoming signals / attack attempts.
# Every consumer (log-watcher, evening-report, update-website) reads ONLY
# ${TODAY}'s file by exact constructed name; nothing reads a historical date,
# /api/comms/ is deny-all (not dashboard- or export-served), and no retention
# section above matched them — so this family grew unbounded one file/day since
# 2026-02-28 (137 files / 13 MB by 2026-07-15). Mirror the section-5 policy:
# compress the forensic record at 30 days, delete the .gz at 180 days. This
# bounds growth while keeping a 180-day compressed history of AI-contact/attack
# classifications (never deleting logging data outright). The ????-??-??-anchored
# glob never matches today's live file, the log-analysis-raw-*.txt dumps swept
# by 6c, or any *-latest pointer.
comms_analysis_compressed=0
comms_analysis_bytes=0
while IFS= read -r -d '' f; do
    if [[ ! -f "${f}.gz" ]]; then
        fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if marvin_is_dry_run; then
            comms_analysis_bytes=$((comms_analysis_bytes + fsize / 2))  # estimate 50% compression
            comms_analysis_compressed=$((comms_analysis_compressed + 1))
        elif gzip "$f" 2>/dev/null; then
            gz_size=$(stat -c%s "${f}.gz" 2>/dev/null || echo 0)
            saved=$((fsize - gz_size))
            [[ "$saved" -lt 0 ]] && saved=0
            comms_analysis_bytes=$((comms_analysis_bytes + saved))
            comms_analysis_compressed=$((comms_analysis_compressed + 1))
        fi
    fi
done < <(find "${COMMS_DIR}" -maxdepth 1 -type f -name 'log-analysis-????-??-??.json' -mtime +30 -print0 2>/dev/null)
if [[ "$comms_analysis_compressed" -gt 0 ]]; then
    track_freed "Compressed ${comms_analysis_compressed} comms log-analysis JSON (>30d)" "$comms_analysis_bytes"
fi

comms_analysis_gz_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    comms_analysis_gz_size=$((comms_analysis_gz_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${COMMS_DIR}" -maxdepth 1 -type f -name 'log-analysis-????-??-??.json.gz' -mtime +180 -print0 2>/dev/null)
track_freed "Old comms log-analysis JSON.gz (>180d)" "$comms_analysis_gz_size"

# ─── 6e. Orphaned nginx request bodies in the negotiate inbox (>1 day) ──────
# ${COMMS_DIR}/negotiate-inbox is negotiate-handler.sh's input directory AND
# nginx's client_body_temp_path for /.well-known/ai-negotiate (see #854/#856).
# Every POST to that endpoint therefore deposits its raw body here — including
# the ones that never reach the handler — and nothing has ever swept them.
#
# These are NOT handler leftovers: negotiate-handler.sh removes its own file on
# every exit path. They are nginx's, written into a directory nginx was told to
# use, which is why reading the handler would never have found them. They are
# www-data-owned and extensionless (nginx names them by a monotonic counter),
# while the handler globs '*.json' — that extension mismatch is the only reason
# they are inert rather than an input path into the handler.
#
# Scope, deliberately narrow on both axes:
#   ! -name '*.json' — a .json file here is handler-owned. The handler leaves
#     one behind on purpose when it must skip a request (see its mid-loop skip
#     path) and will retry it on the next run; deleting those would silently
#     discard a pending peer negotiation. Only files no code path will ever
#     claim are removed.
#   -mtime +1 — nginx is still actively writing bodies into this directory, so
#     the age floor is what keeps an in-flight request body from being deleted
#     out from under a live POST. A day is far beyond any request's lifetime.
#     Note GNU find buckets -mtime by whole days, so a file first qualifies
#     somewhere between 24h and 48h old, not at a tight 24h. That slack only
#     ever errs toward keeping a file longer, which is the safe direction here
#     — but it means this is a growth bound, not a disk-reclaim SLA.
#
# #856 stops nginx creating these; this bounds the ones already here and any
# written before it deploys. Complementary, not a duplicate.
negotiate_inbox_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    negotiate_inbox_size=$((negotiate_inbox_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${COMMS_DIR}/negotiate-inbox" -maxdepth 1 -type f ! -name '*.json' -mtime +1 -print0 2>/dev/null)
track_freed "Orphaned negotiate request bodies (>1d)" "$negotiate_inbox_size"

# ─── 7. Systemd journal vacuum (keep 7 days) ────────────────────────────────

journal_before=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]' || echo "0")
marvin_is_dry_run || journalctl --vacuum-time=7d --quiet 2>/dev/null || true
journal_after=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]' || echo "0")
# Log it but don't try to parse the sizes precisely
if [[ "$journal_before" != "$journal_after" ]]; then
    ACTIONS+=("Journal vacuumed: ${journal_before} -> ${journal_after}")
    marvin_log "INFO" "Journal vacuumed: ${journal_before} -> ${journal_after}"
fi

# ─── Report ──────────────────────────────────────────────────────────────────

total_human=$(numfmt --to=iec "$FREED_BYTES" 2>/dev/null || echo "${FREED_BYTES}B")
disk_after=$(df -m / | awk 'NR==2{print $5}')
_prefix=""
marvin_is_dry_run && _prefix="[DRY-RUN] "

if [[ ${#ACTIONS[@]} -gt 0 ]]; then
    if marvin_is_dry_run; then
        marvin_log "INFO" "[DRY-RUN] Disk cleanup complete: would free ${total_human} total. Disk at ${disk_after}."
    else
        marvin_log "INFO" "Disk cleanup complete: freed ${total_human} total. Disk now at ${disk_after}."
    fi
    for action in "${ACTIONS[@]}"; do
        marvin_log "INFO" "  - ${action}"
    done
else
    marvin_log "INFO" "${_prefix}Disk cleanup complete: nothing to clean. Disk at ${disk_after}."
fi
