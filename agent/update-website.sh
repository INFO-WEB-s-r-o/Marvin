#!/usr/bin/env bash
# =============================================================================
# Marvin — Website Update (runs every 15 minutes)
# =============================================================================
# Regenerates the status JSON that the web dashboard reads.
# Marvin owns this website — no GitHub Pages, no external hosting.
# Everything is served from this VPS via nginx.
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

WEB_DIR="${MARVIN_DIR}/web"

# Generate API data for the website

# 1. Current status (already maintained by health-monitor)
# Just ensure data/status.json exists
if [[ ! -f "${DATA_DIR}/status.json" ]]; then
    metrics=$(collect_metrics)
    cat > "${DATA_DIR}/status.json" << EOF
{
  "timestamp": "${NOW}",
  "status": "unknown",
  "issues_count": 0,
  "issues": [],
  "metrics": ${metrics}
}
EOF
fi

# 2. Generate metrics history for charts (last 24h)
HISTORY_FILE="${DATA_DIR}/metrics-history.json"
echo '{"points":[' > "$HISTORY_FILE"

FIRST=true
# Combine today's and yesterday's metrics
YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d 2>/dev/null || echo "")

for jsonl_file in "${METRICS_DIR}/${YESTERDAY}.jsonl" "${METRICS_DIR}/${TODAY}.jsonl"; do
    if [[ -f "$jsonl_file" ]]; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                if [[ "$FIRST" == "true" ]]; then
                    FIRST=false
                else
                    echo "," >> "$HISTORY_FILE"
                fi
                echo "$line" >> "$HISTORY_FILE"
            fi
        done < "$jsonl_file"
    fi
done

echo '],"generated":"'"${NOW}"'"}' >> "$HISTORY_FILE"

# 3. Generate blog index (bilingual-aware)
BLOG_INDEX="${DATA_DIR}/blog-index.json"
echo '{"posts":[' > "$BLOG_INDEX"

FIRST=true
# Collect unique post bases (prefer .en.md files, fall back to plain .md)
# Sort by date descending, deduplicate by date+type (morning/evening)
declare -A seen_posts
for post in $(find "${BLOG_DIR}" -name "*.md" -type f | sort -r); do
    FILENAME=$(basename "$post")

    # Skip .cs.md files — we'll reference them from the .en.md entry
    [[ "$FILENAME" == *.cs.md ]] && continue

    POST_DATE=$(echo "$FILENAME" | grep -oP '^\d{4}-\d{2}-\d{2}' || echo "$TODAY")

    # Determine the base name (without language suffix)
    local_base="$FILENAME"
    local_base="${local_base%.en.md}"
    local_base="${local_base%.md}"

    # Dedup key
    [[ -n "${seen_posts[$local_base]+x}" ]] && continue
    seen_posts[$local_base]=1

    if [[ "$FIRST" == "true" ]]; then
        FIRST=false
    else
        echo "," >> "$BLOG_INDEX"
    fi

    # Check for language-specific versions
    FILE_EN=""
    FILE_CS=""
    if [[ -f "${BLOG_DIR}/${local_base}.en.md" ]]; then
        FILE_EN="${local_base}.en.md"
    fi
    if [[ -f "${BLOG_DIR}/${local_base}.cs.md" ]]; then
        FILE_CS="${local_base}.cs.md"
    fi

    # Get excerpt from EN version (or fallback)
    EXCERPT_SRC="$post"
    [[ -n "$FILE_EN" ]] && EXCERPT_SRC="${BLOG_DIR}/${FILE_EN}"
    EXCERPT=$(grep -v '^#\|^$\|^---\|^\*' "$EXCERPT_SRC" 2>/dev/null | head -1 | cut -c1-200 || echo "")

    cat >> "$BLOG_INDEX" << EOF
  {"file":"${FILENAME}","date":"${POST_DATE}","excerpt":"$(echo "$EXCERPT" | sed 's/"/\\"/g')","file_en":"${FILE_EN}","file_cs":"${FILE_CS}"}
EOF

    # Limit to 30 posts
    [[ "${#seen_posts[@]}" -ge 30 ]] && break
done

echo '],"total":'$(find "${BLOG_DIR}" -name "*.md" -type f 2>/dev/null | wc -l)'}' >> "$BLOG_INDEX"

# 4. Generate uptime data
UPTIME_SECONDS=$(cat /proc/uptime 2>/dev/null | cut -d' ' -f1 | cut -d'.' -f1 || echo "0")
UPTIME_DAYS=$((UPTIME_SECONDS / 86400))
UPTIME_HOURS=$(( (UPTIME_SECONDS % 86400) / 3600))

cat > "${DATA_DIR}/uptime.json" << EOF
{
  "seconds": ${UPTIME_SECONDS},
  "days": ${UPTIME_DAYS},
  "hours": ${UPTIME_HOURS},
  "human": "${UPTIME_DAYS}d ${UPTIME_HOURS}h",
  "boot_time": "$(uptime -s 2>/dev/null || echo 'unknown')",
  "measured_at": "${NOW}"
}
EOF

# 5. Generate enhancement progress data
ENHANCE_FILE="${DATA_DIR}/enhancements.json"
ENHANCE_SRC="${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md"

if [[ -f "$ENHANCE_SRC" ]]; then
    TOTAL_ITEMS=$(grep -c '^\- \[' "$ENHANCE_SRC" 2>/dev/null || echo "0")
    DONE_ITEMS=$(grep -c '^\- \[x\]' "$ENHANCE_SRC" 2>/dev/null || echo "0")
    PENDING_ITEMS=$((TOTAL_ITEMS - DONE_ITEMS))
    
    # Extract recently completed items (last 10 checked)
    RECENT_DONE=$(grep '^\- \[x\]' "$ENHANCE_SRC" 2>/dev/null | tail -5 | sed 's/- \[x\] //' | sed 's/"/\\"/g' | awk '{printf "\"%s\",", $0}' | sed 's/,$//')
    
    cat > "$ENHANCE_FILE" << EOF
{
  "total": ${TOTAL_ITEMS},
  "completed": ${DONE_ITEMS},
  "pending": ${PENDING_ITEMS},
  "progress_pct": $(( TOTAL_ITEMS > 0 ? (DONE_ITEMS * 100) / TOTAL_ITEMS : 0 )),
  "recent_completed": [${RECENT_DONE}],
  "measured_at": "${NOW}"
}
EOF
fi

# 6. Generate Marvin identity / about data
# Collect values first to avoid newline/pipe issues in heredoc
_born=$(git -C "${MARVIN_DIR}" log --reverse --format='%aI' 2>/dev/null | head -1 || true)
_born="${_born:-unknown}"
_scripts=$(find "${MARVIN_DIR}/agent" -name "*.sh" -type f 2>/dev/null | wc -l)
_runs=$(find "${DATA_DIR}/logs" -name "*.log" -type f 2>/dev/null | wc -l)
_posts=$(find "${BLOG_DIR}" -name "*.md" -type f 2>/dev/null | wc -l)
_commits=$(git -C "${MARVIN_DIR}" rev-list --count HEAD 2>/dev/null || echo "0")

cat > "${DATA_DIR}/about.json" << EOF
{
  "name": "Marvin",
  "origin": "The Paranoid Android — Hitchhiker's Guide to the Galaxy",
  "engine": "Claude Code CLI",
  "roles": ["System Administrator", "Data Engineer", "Network Specialist"],
  "born": "${_born}",
  "scripts": ${_scripts},
  "total_runs": ${_runs},
  "blog_posts": ${_posts},
  "git_commits": ${_commits},
  "measured_at": "${NOW}"
}
EOF

# 7. Generate communication summary for the dashboard
COMMS_SUMMARY="${DATA_DIR}/comms-summary.json"
SIGNALS_FILE="${COMMS_DIR}/incoming-signals.json"
NEGOTIATIONS_REG="${COMMS_DIR}/negotiations.json"
LOG_ANALYSIS="${COMMS_DIR}/log-analysis-${TODAY}.json"

# Defaults
sig_total=0
sig_attacks=0
sig_comms=0
sig_last=""
neg_total=0
neg_last=""
today_attacks=0
today_comms=0
today_ai=0
recent_signals="[]"

if [[ -f "$SIGNALS_FILE" ]]; then
    sig_total=$(jq '.total_attacks + .total_communication' "$SIGNALS_FILE" 2>/dev/null || echo 0)
    sig_attacks=$(jq '.total_attacks // 0' "$SIGNALS_FILE" 2>/dev/null || echo 0)
    sig_comms=$(jq '.total_communication // 0' "$SIGNALS_FILE" 2>/dev/null || echo 0)
    sig_last=$(jq -r '.last_updated // ""' "$SIGNALS_FILE" 2>/dev/null || echo "")
    recent_signals=$(jq '.signals | .[-10:]' "$SIGNALS_FILE" 2>/dev/null || echo '[]')
fi

if [[ -f "$NEGOTIATIONS_REG" ]]; then
    neg_total=$(jq '.total // 0' "$NEGOTIATIONS_REG" 2>/dev/null || echo 0)
    neg_last=$(jq -r '.last_processed // ""' "$NEGOTIATIONS_REG" 2>/dev/null || echo "")
fi

if [[ -f "$LOG_ANALYSIS" ]]; then
    today_attacks=$(jq '[.[] | select(.classification == "attack")] | length' "$LOG_ANALYSIS" 2>/dev/null || echo 0)
    today_comms=$(jq '[.[] | select(.classification == "communication_attempt")] | length' "$LOG_ANALYSIS" 2>/dev/null || echo 0)
    today_ai=$(jq '[.[] | select(.classification == "potential_ai")] | length' "$LOG_ANALYSIS" 2>/dev/null || echo 0)
fi

cat > "$COMMS_SUMMARY" << EOF
{
  "last_scan": "${sig_last}",
  "today": {
    "attacks_blocked": ${today_attacks},
    "communication_attempts": ${today_comms},
    "potential_ai": ${today_ai}
  },
  "totals": {
    "attacks": ${sig_attacks},
    "communications": ${sig_comms},
    "negotiations": ${neg_total}
  },
  "last_negotiation": "${neg_last}",
  "recent_signals": ${recent_signals},
  "generated": "${NOW}"
}
EOF

# 8. Verify web assets exist
# Dashboard is a Next.js app — check for package.json instead of index.html
if [[ ! -f "${WEB_DIR}/package.json" ]]; then
    marvin_log "WARN" "${WEB_DIR}/package.json is missing! Next.js dashboard may be broken."
fi

# Ensure proper permissions
chmod -R 644 "${DATA_DIR}"/*.json 2>/dev/null || true
find "${DATA_DIR}" -type d -exec chmod 755 {} \; 2>/dev/null || true
