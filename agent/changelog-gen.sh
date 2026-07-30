#!/usr/bin/env bash
# =============================================================================
# Marvin — Auto-generated Changelog from Enhancement Reports
# =============================================================================
# Scans enhancement reports in data/enhancements/ and produces a JSON feed
# at data/changelog.json for the dashboard ChangelogSection component.
#
# Extracts: date, session count, change summaries, PR numbers, risk level.
# Keeps the last 30 days of entries (configurable via CHANGELOG_DAYS).
#
# Usage: ./changelog-gen.sh [--dry-run]
# Cron:  Runs after self-enhance sessions (called by self-enhance.sh)
#        Also runs standalone: can be scheduled hourly or daily
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

marvin_parse_args "$@"
trap marvin_error_trap ERR

CHANGELOG_DAYS="${CHANGELOG_DAYS:-30}"
ENHANCE_DIR="${DATA_DIR}/enhancements"
OUTPUT_FILE="${DATA_DIR}/changelog.json"

marvin_log "INFO" "Changelog generation starting (last ${CHANGELOG_DAYS} days)"

# ─── Collect enhancement report files ────────────────────────────────────────
cutoff_date=$(date -u -d "${CHANGELOG_DAYS} days ago" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)

declare -A day_sessions   # date → session count
declare -A day_changes    # date → newline-separated changes
declare -A day_prs        # date → comma-separated PR numbers
declare -A day_risk       # date → highest risk level
declare -A risk_rank=([none]=0 [low]=1 [medium]=2 [high]=3)

# Parse each enhancement report
while IFS= read -r report_file; do
    filename=$(basename "$report_file")
    # Extract date from filename: 2026-04-03-self-enhance.md or 2026-04-03-1775203201.md
    report_date="${filename:0:10}"

    # Validate date format (YYYY-MM-DD) — skip non-date filenames like sync-learn-*
    if ! [[ "$report_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        continue
    fi

    # Skip if date is before cutoff
    [[ "$report_date" < "$cutoff_date" ]] && continue

    # Count sessions per day
    day_sessions["$report_date"]=$(( ${day_sessions["$report_date"]:-0} + 1 ))

    # Extract changes from "Changes Made" or "Changes Applied" section
    local_changes=""
    in_changes=false
    while IFS= read -r line; do
        # Detect start of changes section (various heading formats)
        if echo "$line" | grep -qiP '^\#{1,3}\s+(Changes Made|Changes Applied|Enhancements Applied)'; then
            in_changes=true
            continue
        fi
        # Detect end of section (next heading)
        if [[ "$in_changes" == "true" ]] && echo "$line" | grep -qP '^\#{1,3}\s+'; then
            in_changes=false
            continue
        fi
        # Capture numbered or bulleted items
        if [[ "$in_changes" == "true" ]]; then
            # Match "1. ...", "- ...", "* ..." lines — extract the text
            change_text=$(echo "$line" | sed -n 's/^[[:space:]]*[0-9]*[.)]\?\s*[-*]\?\s*\*\*\?\([^*]*\)\*\*\?.*/\1/p' 2>/dev/null || true)
            # Fallback: match table rows with | # | Change | ...
            if [[ -z "$change_text" ]]; then
                change_text=$(echo "$line" | sed -n 's/^|[[:space:]]*[0-9]*[[:space:]]*|[[:space:]]*\([^|]*\).*/\1/p' 2>/dev/null || true)
            fi
            # Fallback: just grab non-empty lines that look like changes
            if [[ -z "$change_text" ]] && echo "$line" | grep -qP '^\s*\d+\.\s+'; then
                change_text=$(echo "$line" | sed 's/^[[:space:]]*[0-9]*\.\s*//' 2>/dev/null || true)
            fi
            if [[ -n "$change_text" ]]; then
                # Strip markdown formatting: **bold**, `code`, leading/trailing whitespace
                change_text=$(echo "$change_text" | sed 's/\*\*//g; s/[[:space:]]*$//; s/^[[:space:]]*//')
                # Skip noise: bare file paths, "PR created:" lines, short fragments
                if [[ -n "$change_text" ]] && \
                   [[ ${#change_text} -gt 10 ]] && \
                   ! echo "$change_text" | grep -qP '^`[^`]+`$' && \
                   ! echo "$change_text" | grep -qiP '^(PR created|Cron|None|N\/A|—|---)\s*:?\s*$'; then
                    local_changes="${local_changes}${change_text}\n"
                fi
            fi
        fi
    done < "$report_file"

    # Append changes for this day
    if [[ -n "$local_changes" ]]; then
        day_changes["$report_date"]="${day_changes["$report_date"]:-}${local_changes}"
    fi

    # Extract PR numbers (look for PR #NNN or pull/NNN patterns)
    pr_nums=$(grep -oP '(?:PR\s*#|pull/)(\d+)' "$report_file" 2>/dev/null | grep -oP '\d+' | sort -u | tr '\n' ',' | sed 's/,$//' || true)
    if [[ -n "$pr_nums" ]]; then
        existing="${day_prs["$report_date"]:-}"
        if [[ -n "$existing" ]]; then
            day_prs["$report_date"]="${existing},${pr_nums}"
        else
            day_prs["$report_date"]="$pr_nums"
        fi
    fi

    # Extract risk level (highest wins: none < low < medium < high)
    risk=$(grep -oiP '(?:risk|Risk)[:\s]*\**(none|low|medium|high)\**' "$report_file" 2>/dev/null | tail -1 | grep -oiP '(none|low|medium|high)' | tr '[:upper:]' '[:lower:]' || true)
    if [[ -n "$risk" ]]; then
        current_risk="${day_risk["$report_date"]:-none}"
        if [[ ${risk_rank["$risk"]:-0} -gt ${risk_rank["$current_risk"]:-0} ]]; then
            day_risk["$report_date"]="$risk"
        fi
    fi

done < <(find "$ENHANCE_DIR" -maxdepth 1 -name "*.md" -type f 2>/dev/null | sort)

# ─── Also parse CHANGELOG.md for recent entries ─────────────────────────────
# Entries are dated by their header ("### YYYY-MM-DD"), and ONLY by their header.
# A date that appears in prose — "…fired at 2026-07-11 20:10 UTC…" — is not a
# header and must not re-date the bullets below it. A header without a date
# (`## [Unreleased]`, `### Fixed`) clears the current date rather than letting
# the previous one leak downward, so undated entries are skipped instead of
# being published under a day they don't belong to.
changelog_file="${MARVIN_DIR}/CHANGELOG.md"
cl_header_re='^(#+)[[:space:]]'
if [[ -f "$changelog_file" ]]; then
    current_cl_date=""
    cl_date_depth=0
    while IFS= read -r line; do
        # Only a header line may set (or clear) the date.
        if [[ "$line" =~ $cl_header_re ]]; then
            cl_depth=${#BASH_REMATCH[1]}
            if date_match=$(echo "$line" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1) && [[ -n "$date_match" ]]; then
                if [[ "$date_match" > "$cutoff_date" || "$date_match" == "$cutoff_date" ]]; then
                    current_cl_date="$date_match"
                    cl_date_depth="$cl_depth"
                else
                    current_cl_date=""
                    cl_date_depth=0
                fi
            elif [[ -n "$current_cl_date" && "$cl_depth" -le "$cl_date_depth" ]]; then
                # A dateless header at the same or shallower level ends the dated
                # section. A deeper one (`### Fixed` under `## 2026-07-15`) is a
                # subsection of it and leaves the date in place.
                current_cl_date=""
                cl_date_depth=0
            fi
            continue
        fi
        # Grab bullet items under a valid date. The list marker must be followed
        # by whitespace: a paragraph opening with "**Bold lead**" is not a bullet,
        # and matching it as one publishes the text with a dangling asterisk.
        if [[ -n "$current_cl_date" ]]; then
            cl_item=$(echo "$line" | sed -n 's/^[[:space:]]*[-*][[:space:]]\+\(.*\)/\1/p' 2>/dev/null || true)
            if [[ -n "$cl_item" ]]; then
                # Only add if we don't already have changes from enhancement reports
                if [[ -z "${day_changes["$current_cl_date"]:-}" ]]; then
                    day_changes["$current_cl_date"]="${day_changes["$current_cl_date"]:-}${cl_item}\n"
                fi
            fi
        fi
    done < "$changelog_file"
fi

# ─── Build JSON output ──────────────────────────────────────────────────────
# Sort dates in reverse chronological order
sorted_dates=$(for d in "${!day_sessions[@]}"; do echo "$d"; done | sort -r)

# Count totals
total_sessions=0
total_days=0
for d in ${sorted_dates}; do
    total_sessions=$(( total_sessions + ${day_sessions["$d"]:-0} ))
    total_days=$(( total_days + 1 ))
done

# Build entries array
entries_json="["
first=true
for d in ${sorted_dates}; do
    sessions="${day_sessions["$d"]:-0}"
    risk="${day_risk["$d"]:-none}"

    # Build changes array from newline-separated string.
    # NOTE: capture-then-fallback shape (see lesson `grep-c-double-output`).
    # Under `set -o pipefail`, `head -10` closes its stdin after 10 lines and
    # any upstream `sed`/`sort` writing more data takes SIGPIPE → pipefail
    # propagates exit 141. The pre-fix `pipeline ... 2>/dev/null || echo "[]"`
    # then ran the fallback while jq had ALREADY written a real array,
    # producing `[real]\n[]` — invalid as a single JSON document, and the
    # downstream `jq -nc --argjson changes ...` aborts with exit 2.
    # Reproduces on any day with >10 unique change descriptions.
    changes_json="[]"
    if [[ -n "${day_changes["$d"]:-}" ]]; then
        _out=$(printf '%s' "${day_changes["$d"]}" | sed 's/\\n/\n/g' | sort -u | sed '/^$/d' | head -10 | jq -R -s 'split("\n") | map(select(. != ""))' 2>/dev/null) || true
        changes_json="${_out:-[]}"
    fi

    # Build PR numbers array (defensive — same capture-then-fallback shape).
    prs_json="[]"
    if [[ -n "${day_prs["$d"]:-}" ]]; then
        _out=$(echo "${day_prs["$d"]}" | tr ',' '\n' | sort -un | jq -R -s 'split("\n") | map(select(. != "") | tonumber)' 2>/dev/null) || true
        prs_json="${_out:-[]}"
    fi

    if [[ "$first" != "true" ]]; then
        entries_json="${entries_json},"
    fi
    first=false

    entries_json="${entries_json}$(jq -nc \
        --arg date "$d" \
        --argjson sessions "$sessions" \
        --argjson changes "$changes_json" \
        --argjson prs "$prs_json" \
        --arg risk "$risk" \
        '{date: $date, sessions: $sessions, changes: $changes, pr_numbers: $prs, risk: $risk}')"
done
entries_json="${entries_json}]"

# Assemble final JSON
if marvin_is_dry_run; then
    marvin_log "INFO" "[DRY-RUN] Would write changelog to ${OUTPUT_FILE} (${total_days} days, ${total_sessions} sessions)"
else
    jq -n \
        --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson total_sessions "$total_sessions" \
        --argjson total_days "$total_days" \
        --argjson entries "$entries_json" \
        '{generated_at: $generated_at, total_sessions: $total_sessions, total_days: $total_days, entries: $entries}' \
        > "$OUTPUT_FILE"

    marvin_log "INFO" "Changelog generated: ${total_days} days, ${total_sessions} sessions → ${OUTPUT_FILE}"
fi
