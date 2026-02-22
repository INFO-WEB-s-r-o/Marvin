#!/usr/bin/env bash
# =============================================================================
# Marvin — Log Export (runs daily at 23:00 UTC)
# =============================================================================
# Phase 1: Local git commit (version control for rollback safety)
# Phase 2: Generate exportable log bundles for the /api/logs/ endpoint
# Phase 3: Push GPG-signed commits to GitHub (if configured)
#
# Marvin maintains both a local log export API and a public GitHub presence.
# All commits are GPG-signed for proof of authenticity.
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

marvin_log "INFO" "=== LOG EXPORT STARTING ==="

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Local git commit (safety net for rollback)
# ─────────────────────────────────────────────────────────────────────────────

cd "${MARVIN_DIR}"

git add data/ 2>/dev/null || true
git add CHANGELOG.md 2>/dev/null || true
git add agent/ 2>/dev/null || true
git add web/ 2>/dev/null || true
git add PROMPTS.md 2>/dev/null || true
git add POSSIBLE_ENHANCEMENTS.md 2>/dev/null || true

if ! git diff --cached --quiet 2>/dev/null; then
    METRICS_COUNT=$(wc -l < "${METRICS_DIR}/${TODAY}.jsonl" 2>/dev/null || echo "0")
    BLOG_COUNT=$(find "${BLOG_DIR}" -name "${TODAY}*" -type f 2>/dev/null | wc -l)
    ENHANCE_COUNT=$(find "${ENHANCE_DIR}" -name "${TODAY}*" -type f 2>/dev/null | wc -l)

    COMMIT_MSG="Day ${TODAY}: ${METRICS_COUNT} metrics, ${BLOG_COUNT} blog posts, ${ENHANCE_COUNT} enhancements"

    if git diff --cached --name-only | grep -q "agent/"; then
        COMMIT_MSG+=" [SELF-MODIFIED]"
    fi

    git commit -m "${COMMIT_MSG}" 2>/dev/null || true
    marvin_log "INFO" "Local git commit: ${COMMIT_MSG}"
else
    marvin_log "INFO" "No changes to commit."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: Generate exportable log bundle
# ─────────────────────────────────────────────────────────────────────────────
# Creates a daily JSON bundle at /data/exports/YYYY-MM-DD.json
# This is served via nginx at /api/exports/ — any external system can fetch it.

EXPORT_DIR="${DATA_DIR}/exports"
mkdir -p "$EXPORT_DIR"

EXPORT_FILE="${EXPORT_DIR}/${TODAY}.json"

# Collect today's logs into a structured export
LOG_ENTRIES="[]"
for logfile in /var/log/marvin-*.log; do
    [[ -f "$logfile" ]] || continue
    LOGNAME=$(basename "$logfile" .log)
    # Grab today's entries (lines containing today's date)
    TODAY_LINES=$(grep "${TODAY}" "$logfile" 2>/dev/null | tail -500 | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}' || echo "")
    if [[ -n "$TODAY_LINES" ]]; then
        LOG_ENTRIES=$(echo "$LOG_ENTRIES" | jq --arg name "$LOGNAME" --arg lines "$TODAY_LINES" \
            '. + [{"source": $name, "content": $lines}]' 2>/dev/null || echo "$LOG_ENTRIES")
    fi
done

# Build the export bundle
cat > "$EXPORT_FILE" << EOF
{
  "version": "1.0",
  "date": "${TODAY}",
  "host": "$(hostname)",
  "generated_at": "${NOW}",
  "metrics_file": "metrics/${TODAY}.jsonl",
  "log_sources": ${LOG_ENTRIES},
  "enhancement_log": $(cat "${ENHANCE_DIR}/${TODAY}"*.json 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]"),
  "blog_posts": $(find "${BLOG_DIR}" -name "${TODAY}*" -type f -exec basename {} \; 2>/dev/null | jq -R -s 'split("\n") | map(select(. != ""))' 2>/dev/null || echo "[]")
}
EOF

# Generate an export index (last 30 days)
echo '{"exports":[' > "${EXPORT_DIR}/index.json"
FIRST=true
for bundle in $(find "$EXPORT_DIR" -name "????-??-??.json" -type f | sort -r | head -30); do
    BUNDLE_NAME=$(basename "$bundle")
    BUNDLE_DATE=${BUNDLE_NAME%.json}
    BUNDLE_SIZE=$(stat -c%s "$bundle" 2>/dev/null || stat -f%z "$bundle" 2>/dev/null || echo "0")
    if [[ "$FIRST" == "true" ]]; then FIRST=false; else echo "," >> "${EXPORT_DIR}/index.json"; fi
    echo "  {\"date\":\"${BUNDLE_DATE}\",\"file\":\"${BUNDLE_NAME}\",\"size\":${BUNDLE_SIZE}}" >> "${EXPORT_DIR}/index.json"
done
echo '],"generated":"'"${NOW}"'"}' >> "${EXPORT_DIR}/index.json"

chmod 644 "${EXPORT_DIR}"/*.json 2>/dev/null || true

marvin_log "INFO" "Log export bundle created: ${EXPORT_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Push GPG-signed commits to GitHub
# ─────────────────────────────────────────────────────────────────────────────

# Source the GitHub library
if [[ -f "$(dirname "$0")/lib/github.sh" ]]; then
    source "$(dirname "$0")/lib/github.sh"
    
    if github_check_token 2>/dev/null; then
        marvin_log "INFO" "Pushing GPG-signed commits to GitHub..."
        github_setup_remote
        
        if git push origin main 2>&1; then
            marvin_log "INFO" "Commits pushed to GitHub successfully."
        else
            marvin_log "WARN" "GitHub push failed — will retry next run."
        fi
    else
        marvin_log "INFO" "No GitHub token — skipping push. Local-only mode."
    fi
else
    marvin_log "INFO" "GitHub library not found — skipping push."
fi

marvin_log "INFO" "=== LOG EXPORT COMPLETE ==="
