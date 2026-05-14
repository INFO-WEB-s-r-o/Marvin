#!/usr/bin/env bash
# =============================================================================
# Marvin — Thoughts Extractor (runs after self-enhance)
# =============================================================================
# Extracts interesting excerpts from recent enhancement sessions to create
# a "Marvin's Thoughts" feed for the dashboard. Parses the last 7 days of
# enhancement reports, pulls out key sections, and produces a JSON file.
#
# Output: data/thoughts.json → served at /api/thoughts.json
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

marvin_log "INFO" "Extracting Marvin's thoughts from recent sessions..."

THOUGHTS_FILE="${DATA_DIR}/thoughts.json"
LOOKBACK_DAYS=7

# Collect recent enhancement reports (last N days)
reports=()
for i in $(seq 0 "$LOOKBACK_DAYS"); do
    # `|| continue` must live outside the $() — inside it only exits the
    # command-substitution subshell, leaving $day empty. An empty $day made
    # the next find match every report in $ENHANCE_DIR (glob "*.md") instead
    # of skipping the iteration, padding `reports[]` with duplicates.
    day=$(date -u -d "${TODAY} - ${i} days" +%Y-%m-%d 2>/dev/null \
        || date -u -v-${i}d +%Y-%m-%d 2>/dev/null) || continue
    while IFS= read -r f; do
        [[ -f "$f" ]] && reports+=("$f")
    done < <(find "$ENHANCE_DIR" -name "${day}*.md" -type f 2>/dev/null | sort -r)
done

if [[ ${#reports[@]} -eq 0 ]]; then
    marvin_log "INFO" "No recent enhancement reports found — writing empty thoughts"
    cat > "$THOUGHTS_FILE" <<EOF
{"thoughts":[],"generated_at":"${NOW}","source_count":0}
EOF
    exit 0
fi

# Extract structured thoughts from each report
# We parse markdown sections: "Next Time", "Issues Found", "Review Summary", "Risk Assessment"
thoughts_json="[]"

for report in "${reports[@]}"; do
    report_name=$(basename "$report" .md)
    # Extract the date from filename (YYYY-MM-DD prefix)
    report_date="${report_name:0:10}"

    # Extract "Next Time" section — Marvin's future intentions
    next_time=$(sed -n '/^## Next Time/,/^## \|^---/{ /^## Next Time/d; /^## \|^---/d; p; }' "$report" 2>/dev/null \
        | sed 's/^- //' | head -5 | tr '\n' '|' | sed 's/|$//' || true)

    # Extract "Issues Found" section — what Marvin noticed
    issues=$(sed -n '/^## Issues Found/,/^## /{ /^## Issues Found/d; /^## /d; p; }' "$report" 2>/dev/null \
        | sed 's/^[0-9]*\. //' | head -5 | tr '\n' '|' | sed 's/|$//' || true)

    # Extract "Review Summary" — what Marvin looked at
    summary=$(sed -n '/^## Review Summary/,/^## /{ /^## Review Summary/d; /^## /d; p; }' "$report" 2>/dev/null \
        | head -3 | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//' || true)

    # Extract "Risk Assessment" last line — Marvin's overall risk take
    risk_note=$(sed -n '/^## Risk Assessment/,/^## \|^---/{ /^## Risk Assessment/d; /^## \|^---/d; p; }' "$report" 2>/dev/null \
        | sed '/^$/d' | tail -1 | sed 's/^- //' || true)

    # Helper: clean markdown formatting and trim text
    _clean() {
        echo "$1" | sed 's/\*\*//g; s/`//g; s/^ *//; s/ *$//' | cut -c 1-200
    }

    # Build thought entries from this report
    if [[ -n "$next_time" ]]; then
        IFS='|' read -ra items <<< "$next_time"
        for item in "${items[@]}"; do
            item=$(_clean "$item")
            [[ -z "$item" || ${#item} -lt 20 ]] && continue
            thoughts_json=$(echo "$thoughts_json" | jq --arg d "$report_date" --arg t "$item" --arg c "intention" \
                '. + [{"date": $d, "text": $t, "category": $c}]')
        done
    fi

    if [[ -n "$summary" ]]; then
        summary=$(_clean "$summary")
        if [[ ${#summary} -gt 30 ]]; then
            thoughts_json=$(echo "$thoughts_json" | jq --arg d "$report_date" --arg t "$summary" --arg c "reflection" \
                '. + [{"date": $d, "text": $t, "category": $c}]')
        fi
    fi

    if [[ -n "$issues" ]]; then
        IFS='|' read -ra items <<< "$issues"
        for item in "${items[@]}"; do
            item=$(_clean "$item")
            [[ -z "$item" || ${#item} -lt 20 ]] && continue
            thoughts_json=$(echo "$thoughts_json" | jq --arg d "$report_date" --arg t "$item" --arg c "observation" \
                '. + [{"date": $d, "text": $t, "category": $c}]')
        done
    fi
done

# Deduplicate (by first 50 chars of text) and limit to 12 most recent thoughts
thoughts_json=$(echo "$thoughts_json" | jq '[
    group_by(.text[0:50])[] | .[0]
] | sort_by(.date) | reverse | .[0:12]')

# Build final output
jq -n \
    --argjson thoughts "$thoughts_json" \
    --arg generated_at "$NOW" \
    --arg source_count "${#reports[@]}" \
    '{
        thoughts: $thoughts,
        generated_at: $generated_at,
        source_count: ($source_count | tonumber)
    }' > "$THOUGHTS_FILE"

thought_count=$(echo "$thoughts_json" | jq 'length')
marvin_log "INFO" "Extracted ${thought_count} thoughts from ${#reports[@]} reports → ${THOUGHTS_FILE}"
