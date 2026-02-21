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

# 3. Generate blog index
BLOG_INDEX="${DATA_DIR}/blog-index.json"
echo '{"posts":[' > "$BLOG_INDEX"

FIRST=true
for post in $(find "${BLOG_DIR}" -name "*.md" -type f | sort -r | head -30); do
    FILENAME=$(basename "$post")
    DATE=${FILENAME%%-*}
    # Try to get the date from filename (YYYY-MM-DD format)
    POST_DATE=$(echo "$FILENAME" | grep -oP '^\d{4}-\d{2}-\d{2}' || echo "$TODAY")
    
    if [[ "$FIRST" == "true" ]]; then
        FIRST=false
    else
        echo "," >> "$BLOG_INDEX"
    fi
    
    # Get first non-empty, non-header line as excerpt
    EXCERPT=$(grep -v '^#\|^$\|^---\|^\*' "$post" 2>/dev/null | head -1 | cut -c1-200 || echo "")
    
    cat >> "$BLOG_INDEX" << EOF
  {"file":"${FILENAME}","date":"${POST_DATE}","excerpt":"$(echo "$EXCERPT" | sed 's/"/\\"/g')"}
EOF
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
cat > "${DATA_DIR}/about.json" << EOF
{
  "name": "Marvin",
  "origin": "The Paranoid Android — Hitchhiker's Guide to the Galaxy",
  "engine": "Claude Code CLI",
  "roles": ["System Administrator", "Data Engineer", "Network Specialist"],
  "born": "$(git -C "${MARVIN_DIR}" log --reverse --format='%ai' 2>/dev/null | head -1 || echo 'unknown')",
  "scripts": $(find "${MARVIN_DIR}/agent" -name "*.sh" -type f 2>/dev/null | wc -l),
  "total_runs": $(find "${DATA_DIR}/logs" -name "*.log" -type f 2>/dev/null | wc -l),
  "blog_posts": $(find "${BLOG_DIR}" -name "*.md" -type f 2>/dev/null | wc -l),
  "git_commits": $(git -C "${MARVIN_DIR}" rev-list --count HEAD 2>/dev/null || echo "0"),
  "measured_at": "${NOW}"
}
EOF

# 7. Verify web assets exist
# If index.html is missing, Marvin cannot serve the dashboard
if [[ ! -f "${WEB_DIR}/index.html" ]]; then
    log "WARNING: ${WEB_DIR}/index.html is missing! Dashboard is broken."
fi

# Ensure proper permissions
chmod -R 644 "${DATA_DIR}"/*.json 2>/dev/null || true
find "${DATA_DIR}" -type d -exec chmod 755 {} \; 2>/dev/null || true
