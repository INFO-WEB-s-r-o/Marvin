#!/usr/bin/env bash
# =============================================================================
# Marvin — Weekly Report Card (visual SVG summary)
# =============================================================================
# Renders the machine-readable weekly analytics JSON
# (data/reports/weekly-YYYY-MM-DD.json, produced by weekly-analytics.sh) into a
# single self-contained SVG "report card" — a visual one-pager of the week.
#
# Why SVG and not PNG/PDF:
#   The roadmap item (Phase 2) asks for a "PDF or PNG report (using headless
#   tools if available)". The only headless browser on this host is the
#   chromium *snap*, which refuses to launch from a cron cgroup
#   ("... is not a snap cgroup for tag snap.chromium.chromium") and confines
#   file writes to its private tmp. It is therefore NOT viable in Marvin's
#   autonomous (cron-as-marvin) context. SVG needs no external tooling, renders
#   in any browser, embeds directly in the dashboard/blog, and anyone who wants
#   a raster can convert it. Robust beats fragile.
#
# Output:
#   data/reports/weekly-card-YYYY-MM-DD.svg   (dated)
#   data/reports/weekly-card-latest.svg       (stable "latest" copy)
#
# Usage:
#   ./report-card.sh                # render latest weekly report
#   ./report-card.sh 2026-05-23     # render a specific week (END date)
#   ./report-card.sh --dry-run      # show what would be written, write nothing
#
# Suggested cron (after weekly-analytics.sh at 11:30 UTC Sundays):
#   35 11 * * 0 /home/marvin/git/agent/report-card.sh >> /home/marvin/git/data/logs/report-card.log 2>&1
#
# Does NOT invoke Claude — pure rendering of existing data.
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

marvin_parse_args "$@"

REPORTS_DIR="${DATA_DIR}/reports"
mkdir -p "$REPORTS_DIR"

# ─── Resolve which weekly report to render ────────────────────────────────────
# A positional (non-flag) argument is treated as the week END date.
REPORT_END=""
for arg in "$@"; do
    case "$arg" in
        --*) ;;                       # flags handled by marvin_parse_args
        *) REPORT_END="$arg" ;;
    esac
done

if [[ -n "$REPORT_END" ]]; then
    # Validate the CLI argument before it becomes a path component (#753).
    # Mirrors the period_end guard below; blocks path traversal via e.g. ../../etc/shadow.
    if [[ ! "$REPORT_END" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        marvin_log "ERROR" "Invalid REPORT_END argument (expected YYYY-MM-DD): ${REPORT_END}"
        exit 1
    fi
    SRC_JSON="${REPORTS_DIR}/weekly-${REPORT_END}.json"
else
    SRC_JSON="$(ls -1t "${REPORTS_DIR}"/weekly-*.json 2>/dev/null | head -1 || true)"
fi

if [[ -z "$SRC_JSON" || ! -f "$SRC_JSON" ]]; then
    marvin_log "ERROR" "No weekly report JSON found (looked for ${SRC_JSON:-${REPORTS_DIR}/weekly-*.json}). Run weekly-analytics.sh first."
    exit 1
fi

if ! jq -e . "$SRC_JSON" >/dev/null 2>&1; then
    marvin_log "ERROR" "Source weekly report is not valid JSON: ${SRC_JSON}"
    exit 1
fi

marvin_log "INFO" "Rendering report card from ${SRC_JSON}"

# ─── Pull fields (defaults via //) ────────────────────────────────────────────
# One jq pass → TAB-separated key/value lines → associative array.
declare -A R
while IFS=$'\t' read -r k v; do
    R["$k"]="$v"
done < <(jq -r '
    [
      ["period_start",   (.period.start // "?")],
      ["period_end",     (.period.end // "?")],
      ["uptime",         (.sla.overall_uptime_pct // 0 | (. * 100 | round) / 100 | tostring)],
      ["days_100",       (.sla.days_at_100pct // 0 | tostring)],
      ["days_tracked",   (.sla.days_tracked // 0 | tostring)],
      ["sec_grade",      (.security.grade // "?")],
      ["sec_score",      (.security.score // "?" | tostring)],
      ["banned",         (.security.fail2ban_total_banned // 0 | tostring)],
      ["cves",           (.security.pending_cves // 0 | tostring)],
      ["cpu_avg",        (.system_metrics.current_week.cpu.avg // 0 | tostring)],
      ["cpu_max",        (.system_metrics.current_week.cpu.max // 0 | tostring)],
      ["mem_avg",        (.system_metrics.current_week.memory_used_mb.avg // 0 | tostring)],
      ["load_avg",       (.system_metrics.current_week.load_1m.avg // 0 | tostring)],
      ["load_max",       (.system_metrics.current_week.load_1m.max // 0 | tostring)],
      ["disk_delta",     (.system_metrics.current_week.disk.delta_mb // 0 | tostring)],
      ["claude_runs",    (.claude_api.current_week.total_runs // 0 | tostring)],
      ["claude_avg_s",   (.claude_api.current_week.avg_duration_s // 0 | tostring)],
      ["claude_errpct",  (.claude_api.current_week.error_rate_pct // 0 | tostring)],
      ["claude_runs_d",  (.claude_api.trends.runs_delta_pct // 0 | tostring)],
      ["log_errors",     (.logs.current_week.errors // 0 | tostring)],
      ["log_warnings",   (.logs.current_week.warnings // 0 | tostring)],
      ["log_criticals",  (.logs.current_week.criticals // 0 | tostring)],
      ["warn_delta",     (.logs.trends.warnings_delta_pct // 0 | tostring)],
      ["enhancements",   (.enhancements_attempted // 0 | tostring)],
      ["generated_at",   (.generated_at // "?")]
    ] | .[] | @tsv
' "$SRC_JSON")

# ─── Derive overall status colour from health signals ─────────────────────────
# Green when the week was clean; amber if warnings/criticals/CVEs present.
ACCENT="#27c93f"   # green
STATUS_TEXT="NOMINAL"
if (( ${R[log_criticals]:-0} > 0 )) || (( ${R[cves]:-0} > 0 )); then
    ACCENT="#ff5f56"; STATUS_TEXT="ATTENTION"
elif (( ${R[log_errors]:-0} > 0 )); then
    ACCENT="#ffbd2e"; STATUS_TEXT="WATCH"
fi

# Disk delta sign for display
disk_delta="${R[disk_delta]:-0}"
if [[ "$disk_delta" == -* ]]; then
    DISK_STR="${disk_delta} MB"
else
    DISK_STR="+${disk_delta} MB"
fi

# Validate period_end looks like a date before using it in a path (#752).
# Guards against path traversal if the source JSON ever carried a crafted value.
if [[ ! "${R[period_end]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    marvin_log "ERROR" "Unexpected period_end value in JSON: ${R[period_end]}"
    exit 1
fi

# XML-escape string fields before they are interpolated into SVG <text> (#754).
# Numeric fields are jq-coerced via tostring and need no escaping; these four
# originate as free-form JSON strings.
xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
period_start_esc="$(xml_escape "${R[period_start]}")"
period_end_esc="$(xml_escape "${R[period_end]}")"
generated_at_esc="$(xml_escape "${R[generated_at]}")"
sec_grade_esc="$(xml_escape "${R[sec_grade]}")"

OUT_DATED="${REPORTS_DIR}/weekly-card-${R[period_end]}.svg"
OUT_LATEST="${REPORTS_DIR}/weekly-card-latest.svg"

if marvin_is_dry_run; then
    marvin_log "INFO" "[DRY-RUN] Would write ${OUT_DATED} and ${OUT_LATEST}"
    marvin_log "INFO" "[DRY-RUN] Period ${R[period_start]}..${R[period_end]} | status=${STATUS_TEXT} | uptime=${R[uptime]}% | grade=${R[sec_grade]} | errors=${R[log_errors]}"
    exit 0
fi

# ─── Render SVG ───────────────────────────────────────────────────────────────
# Terminal-styled card to match the dashboard aesthetic. 960x600.
cat > "$OUT_DATED" << SVG
<svg xmlns="http://www.w3.org/2000/svg" width="960" height="600" viewBox="0 0 960 600" font-family="'JetBrains Mono','Courier New',monospace">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1a1b26"/>
      <stop offset="1" stop-color="#11121a"/>
    </linearGradient>
  </defs>
  <rect width="960" height="600" rx="14" fill="url(#bg)"/>
  <rect x="0.5" y="0.5" width="959" height="599" rx="14" fill="none" stroke="#2a2c3d" stroke-width="1"/>

  <!-- title bar dots -->
  <circle cx="28" cy="34" r="7" fill="#ff5f56"/>
  <circle cx="50" cy="34" r="7" fill="#ffbd2e"/>
  <circle cx="72" cy="34" r="7" fill="#27c93f"/>
  <text x="100" y="40" fill="#c0caf5" font-size="20" font-weight="bold">marvin@robot-marvin.cz — Weekly Report Card</text>

  <!-- status pill -->
  <rect x="760" y="20" width="178" height="30" rx="15" fill="${ACCENT}" opacity="0.18"/>
  <circle cx="782" cy="35" r="6" fill="${ACCENT}"/>
  <text x="798" y="40" fill="${ACCENT}" font-size="15" font-weight="bold">${STATUS_TEXT}</text>

  <text x="100" y="64" fill="#565f89" font-size="13">Period ${period_start_esc} → ${period_end_esc}  ·  generated ${generated_at_esc}</text>
  <line x1="24" y1="80" x2="936" y2="80" stroke="#2a2c3d" stroke-width="1"/>

  <!-- KPI tiles -->
  <g>
    <rect x="24"  y="100" width="220" height="120" rx="10" fill="#1f2130" stroke="#2a2c3d"/>
    <rect x="268" y="100" width="220" height="120" rx="10" fill="#1f2130" stroke="#2a2c3d"/>
    <rect x="512" y="100" width="220" height="120" rx="10" fill="#1f2130" stroke="#2a2c3d"/>
    <rect x="756" y="100" width="180" height="120" rx="10" fill="#1f2130" stroke="#2a2c3d"/>

    <text x="134" y="128" fill="#565f89" font-size="13" text-anchor="middle">UPTIME (30d)</text>
    <text x="134" y="178" fill="#27c93f" font-size="42" font-weight="bold" text-anchor="middle">${R[uptime]}%</text>
    <text x="134" y="204" fill="#565f89" font-size="12" text-anchor="middle">${R[days_100]}/${R[days_tracked]} days at 100%</text>

    <text x="378" y="128" fill="#565f89" font-size="13" text-anchor="middle">SECURITY GRADE</text>
    <text x="378" y="178" fill="#7aa2f7" font-size="42" font-weight="bold" text-anchor="middle">${sec_grade_esc}</text>
    <text x="378" y="204" fill="#565f89" font-size="12" text-anchor="middle">score ${R[sec_score]}/100 · ${R[cves]} CVEs</text>

    <text x="622" y="128" fill="#565f89" font-size="13" text-anchor="middle">CLAUDE ERROR RATE</text>
    <text x="622" y="178" fill="#bb9af7" font-size="42" font-weight="bold" text-anchor="middle">${R[claude_errpct]}%</text>
    <text x="622" y="204" fill="#565f89" font-size="12" text-anchor="middle">${R[claude_runs]} runs · ~${R[claude_avg_s]}s avg</text>

    <text x="846" y="128" fill="#565f89" font-size="13" text-anchor="middle">ENHANCE</text>
    <text x="846" y="178" fill="#e0af68" font-size="42" font-weight="bold" text-anchor="middle">${R[enhancements]}</text>
    <text x="846" y="204" fill="#565f89" font-size="12" text-anchor="middle">attempts</text>
  </g>

  <!-- System metrics -->
  <text x="24" y="262" fill="#c0caf5" font-size="16" font-weight="bold">System</text>
  <line x1="24" y1="272" x2="936" y2="272" stroke="#2a2c3d" stroke-width="1"/>
  <text x="40"  y="306" fill="#565f89" font-size="13">CPU avg</text>
  <text x="40"  y="332" fill="#9ece6a" font-size="22">${R[cpu_avg]}%</text>
  <text x="40"  y="354" fill="#565f89" font-size="12">peak ${R[cpu_max]}%</text>

  <text x="250" y="306" fill="#565f89" font-size="13">Memory avg</text>
  <text x="250" y="332" fill="#9ece6a" font-size="22">${R[mem_avg]} MB</text>

  <text x="470" y="306" fill="#565f89" font-size="13">Load avg</text>
  <text x="470" y="332" fill="#9ece6a" font-size="22">${R[load_avg]}</text>
  <text x="470" y="354" fill="#565f89" font-size="12">peak ${R[load_max]}</text>

  <text x="690" y="306" fill="#565f89" font-size="13">Disk Δ (week)</text>
  <text x="690" y="332" fill="#9ece6a" font-size="22">${DISK_STR}</text>

  <!-- Logs & activity -->
  <text x="24" y="408" fill="#c0caf5" font-size="16" font-weight="bold">Logs &amp; Activity</text>
  <line x1="24" y1="418" x2="936" y2="418" stroke="#2a2c3d" stroke-width="1"/>
  <text x="40"  y="452" fill="#565f89" font-size="13">Errors</text>
  <text x="40"  y="478" fill="#f7768e" font-size="22">${R[log_errors]}</text>

  <text x="250" y="452" fill="#565f89" font-size="13">Warnings</text>
  <text x="250" y="478" fill="#e0af68" font-size="22">${R[log_warnings]}</text>
  <text x="250" y="500" fill="#565f89" font-size="12">WoW ${R[warn_delta]}%</text>

  <text x="470" y="452" fill="#565f89" font-size="13">Criticals</text>
  <text x="470" y="478" fill="#f7768e" font-size="22">${R[log_criticals]}</text>

  <text x="690" y="452" fill="#565f89" font-size="13">fail2ban banned</text>
  <text x="690" y="478" fill="#7aa2f7" font-size="22">${R[banned]}</text>

  <!-- footer -->
  <line x1="24" y1="540" x2="936" y2="540" stroke="#2a2c3d" stroke-width="1"/>
  <text x="24"  y="568" fill="#565f89" font-size="13" font-style="italic">"Here I am, brain the size of a planet, and they ask me to summarize the week."</text>
  <text x="936" y="568" fill="#565f89" font-size="12" text-anchor="end">robot-marvin.cz</text>
</svg>
SVG

# Validate well-formedness BEFORE propagating to `latest` (#754).
# A malformed dated card must not silently overwrite a good latest card.
# Prefer xmllint, but it is NOT installed on this host (cron-as-marvin), which
# left the original guard inert. Fall back to python3 (always present here — it
# runs the bench harness) so the safety net actually fires in production.
# Note: if xmllint is ever installed the python3 elif becomes unreachable — that
# is harmless, the xmllint path is equally authoritative. The else is a last
# resort: if it fires, the cp below still runs (an unvalidated card beats no
# card; we only lose the malformed-overwrite guard, not the card itself).
if command -v xmllint >/dev/null 2>&1; then
    if ! xmllint --noout "$OUT_DATED" 2>/dev/null; then
        marvin_log "ERROR" "Generated SVG failed xmllint well-formedness check; not updating latest: ${OUT_DATED}"
        exit 1
    fi
elif command -v python3 >/dev/null 2>&1; then
    if ! python3 -c 'import sys,xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "$OUT_DATED" 2>/dev/null; then
        marvin_log "ERROR" "Generated SVG failed python3 well-formedness check; not updating latest: ${OUT_DATED}"
        exit 1
    fi
else
    marvin_log "WARN" "Neither xmllint nor python3 available — skipping SVG well-formedness check for ${OUT_DATED}"
fi

# No validator failed (or none was present); propagate the dated card to latest.
cp "$OUT_DATED" "$OUT_LATEST"
chmod 644 "$OUT_DATED" "$OUT_LATEST"

# ─── Retention: keep the most recent 8 dated cards ────────────────────────────
mapfile -t _old_cards < <(ls -1t "${REPORTS_DIR}"/weekly-card-2*.svg 2>/dev/null | tail -n +9)
for _c in "${_old_cards[@]:-}"; do
    [[ -n "$_c" && -f "$_c" ]] && rm -f "$_c"
done

marvin_log "INFO" "Report card written: ${OUT_DATED} (status=${STATUS_TEXT}, uptime=${R[uptime]}%, grade=${R[sec_grade]})"
