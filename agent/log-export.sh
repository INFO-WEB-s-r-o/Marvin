#!/usr/bin/env bash
# =============================================================================
# Marvin — Log Export (runs daily at 23:00 UTC)
# =============================================================================
# Phase 1: Generate exportable log bundle for the /api/exports/ endpoint
# Phase 2: Commit data/ to a branch and open a Pull Request to main
# Phase 3: Auto-merge the PR so data is visible on main
#
# data/ (metrics, blog, comms, enhancements, exports) goes through a PR.
# Code files (agent/, web/, prompts/) must use a separate PR — never here.
# data/logs/ is gitignored — raw run logs are captured in the export bundle.
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

# Safety net: always return to main branch on exit, even if the script fails
# This prevents leaving the repo on a data/* branch which breaks other scripts
cleanup_branch() {
    local current_branch
    current_branch=$(git -C "${MARVIN_DIR}" branch --show-current 2>/dev/null || echo "")
    if [[ "$current_branch" != "main" && -n "$current_branch" ]]; then
        marvin_log "WARN" "Cleanup: returning to main from ${current_branch}"
        # Stash any uncommitted changes first — other cron scripts (health-monitor,
        # update-website) modify data/ files continuously, so `git checkout main`
        # will fail without this.
        git -C "${MARVIN_DIR}" stash --quiet 2>/dev/null || true
        git -C "${MARVIN_DIR}" checkout main 2>/dev/null || true
        git -C "${MARVIN_DIR}" stash pop --quiet 2>/dev/null || true
    fi
}
trap cleanup_branch EXIT

marvin_log "INFO" "=== LOG EXPORT STARTING ==="

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Generate exportable log bundle
# ─────────────────────────────────────────────────────────────────────────────
# Creates data/exports/YYYY-MM-DD.json — served at /api/exports/
# Done first so the bundle is included in the data PR.

EXPORT_DIR="${DATA_DIR}/exports"
mkdir -p "$EXPORT_DIR"

EXPORT_FILE="${EXPORT_DIR}/${TODAY}.json"

# Collect today's /var/log/marvin-*.log entries into a structured bundle
LOG_ENTRIES="[]"
for logfile in /var/log/marvin-*.log; do
    [[ -f "$logfile" ]] || continue
    LOGNAME=$(basename "$logfile" .log)
    TODAY_LINES=$(grep "${TODAY}" "$logfile" 2>/dev/null | tail -500 \
        | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}' || echo "")
    if [[ -n "$TODAY_LINES" ]]; then
        LOG_ENTRIES=$(echo "$LOG_ENTRIES" | jq \
            --arg name "$LOGNAME" --arg lines "$TODAY_LINES" \
            '. + [{"source": $name, "content": $lines}]' 2>/dev/null \
            || echo "$LOG_ENTRIES")
    fi
done

cat > "$EXPORT_FILE" << EOF
{
  "version": "1.0",
  "date": "${TODAY}",
  "host": "$(hostname)",
  "generated_at": "${NOW}",
  "metrics_file": "metrics/${TODAY}.jsonl",
  "log_sources": ${LOG_ENTRIES},
  "enhancement_log": $(cat "${ENHANCE_DIR}/${TODAY}"*.json 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]"),
  "blog_posts": $(find "${BLOG_DIR}" -name "${TODAY}*" -type f -exec basename {} \; 2>/dev/null \
      | jq -R -s 'split("\n") | map(select(. != ""))' 2>/dev/null || echo "[]")
}
EOF

# Regenerate export index (last 30 days)
{
    echo '{"exports":['
    FIRST=true
    for bundle in $(find "$EXPORT_DIR" -name "????-??-??.json" -type f | sort -r | head -30); do
        BUNDLE_NAME=$(basename "$bundle")
        BUNDLE_DATE=${BUNDLE_NAME%.json}
        BUNDLE_SIZE=$(stat -c%s "$bundle" 2>/dev/null || stat -f%z "$bundle" 2>/dev/null || echo "0")
        [[ "$FIRST" == "true" ]] && FIRST=false || echo ","
        echo "  {\"date\":\"${BUNDLE_DATE}\",\"file\":\"${BUNDLE_NAME}\",\"size\":${BUNDLE_SIZE}}"
    done
    echo "],"
    echo "\"generated\":\"${NOW}\"}"
} > "${EXPORT_DIR}/index.json"

chmod 644 "${EXPORT_DIR}"/*.json 2>/dev/null || true
marvin_log "INFO" "Export bundle created: ${EXPORT_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: Commit data/ to a branch
# ─────────────────────────────────────────────────────────────────────────────
# data/ (metrics, blog, comms, enhancements, exports) goes through a PR.
# data/logs/ is gitignored — handled by the export bundle above.
# Code changes (agent/, web/, etc.) MUST use a separate PR.

cd "${MARVIN_DIR}"

# Warn if there are uncommitted code files — they do NOT belong here
DIRTY_CODE=$(git diff --name-only HEAD 2>/dev/null \
    | grep -E "^(agent|web|setup|CHANGELOG|PROMPTS|POSSIBLE_ENHANCEMENTS)" || true)
if [[ -n "$DIRTY_CODE" ]]; then
    marvin_log "WARN" "Uncommitted code changes found — these need their own PR, not log-export:"
    marvin_log "WARN" "${DIRTY_CODE}"
fi

# Ensure we start from a clean main — stash first since other cron jobs
# may have modified data/ files since the last checkout
git stash --quiet 2>/dev/null || true
git checkout main 2>/dev/null || true
git stash pop --quiet 2>/dev/null || true

# Pick a unique branch name
DATA_BRANCH="data/${TODAY}"
if git ls-remote --exit-code --heads origin "${DATA_BRANCH}" &>/dev/null \
   || git show-ref --verify --quiet "refs/heads/${DATA_BRANCH}" 2>/dev/null; then
    DATA_BRANCH="data/${TODAY}-${TIMESTAMP}"
fi

git checkout -b "${DATA_BRANCH}"

# Stage data/ only
git add data/ 2>/dev/null || true

if git diff --cached --quiet 2>/dev/null; then
    marvin_log "INFO" "No data changes to commit — nothing to PR."
    git checkout main 2>/dev/null || true
    git branch -d "${DATA_BRANCH}" 2>/dev/null || true
    marvin_log "INFO" "=== LOG EXPORT COMPLETE (no changes) ==="
    exit 0
fi

# Build commit message
METRICS_COUNT=$(wc -l < "${METRICS_DIR}/${TODAY}.jsonl" 2>/dev/null || echo "0")
BLOG_COUNT=$(find "${BLOG_DIR}" -name "${TODAY}*" -type f 2>/dev/null | wc -l)
ENHANCE_COUNT=$(find "${ENHANCE_DIR}" -name "${TODAY}*" -type f 2>/dev/null | wc -l)
COMMIT_MSG="data: ${TODAY} — ${METRICS_COUNT} metrics, ${BLOG_COUNT} blog posts, ${ENHANCE_COUNT} enhancements"

# GPG-signed commit
git commit -S -m "${COMMIT_MSG}" 2>&1 || git commit -m "${COMMIT_MSG}" 2>&1
marvin_log "INFO" "Data branch committed: ${DATA_BRANCH}"

# Return to main — branch stays locally until PR is merged
git checkout main 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Push branch, open PR, auto-merge
# ─────────────────────────────────────────────────────────────────────────────

if [[ ! -f "$(dirname "$0")/lib/github.sh" ]]; then
    marvin_log "WARN" "GitHub library not found — data committed locally but not pushed."
    marvin_log "INFO" "=== LOG EXPORT COMPLETE (local only) ==="
    exit 0
fi

source "$(dirname "$0")/lib/github.sh"

if ! github_check_token 2>/dev/null; then
    marvin_log "INFO" "No GitHub token — data committed locally but not pushed."
    marvin_log "INFO" "=== LOG EXPORT COMPLETE (local only) ==="
    exit 0
fi

github_setup_remote

# Push the data branch — stash/unstash around checkout to handle
# concurrent data/ modifications from other cron jobs
git stash --quiet 2>/dev/null || true
git checkout "${DATA_BRANCH}"
if ! git push origin "${DATA_BRANCH}" 2>&1; then
    marvin_log "ERROR" "Failed to push data branch ${DATA_BRANCH}"
    git checkout main 2>/dev/null || true
    git stash pop --quiet 2>/dev/null || true
    exit 1
fi
git checkout main 2>/dev/null || true
git stash pop --quiet 2>/dev/null || true
marvin_log "INFO" "Pushed branch ${DATA_BRANCH} to GitHub"

PR_BODY="Automated daily data export.

| | |
|---|---|
| **Date** | ${TODAY} |
| **Metrics** | ${METRICS_COUNT} data points |
| **Blog posts** | ${BLOG_COUNT} |
| **Enhancements** | ${ENHANCE_COUNT} |
| **Export bundle** | \`data/exports/${TODAY}.json\` |

*Generated by Marvin at ${NOW}. No code was changed — data only.*"

PR_RESPONSE=$(github_create_pr \
    "${DATA_BRANCH}" \
    "data: ${TODAY}" \
    "${PR_BODY}" \
    "main" 2>/dev/null || echo "")

if [[ -z "$PR_RESPONSE" ]]; then
    marvin_log "WARN" "Failed to create data PR — branch ${DATA_BRANCH} is pushed, create PR manually."
    marvin_log "INFO" "=== LOG EXPORT COMPLETE (PR creation failed) ==="
    exit 0
fi

PR_NUMBER=$(echo "$PR_RESPONSE" | jq -r '.number' 2>/dev/null || echo "")
PR_URL=$(echo "$PR_RESPONSE" | jq -r '.html_url' 2>/dev/null || echo "")
marvin_log "INFO" "Data PR #${PR_NUMBER} created: ${PR_URL}"

# Auto-merge — data PRs require no human review
if github_merge_pr "${PR_NUMBER}" "${COMMIT_MSG}"; then
    marvin_log "INFO" "Data PR #${PR_NUMBER} merged into main"

    # Sync local main with the merged commit
    git pull --rebase origin main 2>/dev/null || git pull origin main 2>/dev/null || true

    # Clean up the local branch
    git branch -d "${DATA_BRANCH}" 2>/dev/null || true

    # ─── Stale branch cleanup ────────────────────────────────────────────
    # After a successful merge, clean up old data/* branches that have
    # already been merged into main. This prevents branch accumulation
    # (18 stale local + 6 stale remote branches were found on 2026-02-28).
    marvin_log "INFO" "Cleaning up stale merged branches..."

    # Local: delete data/* branches already merged into main
    stale_local=0
    while IFS= read -r branch; do
        branch=$(echo "$branch" | xargs)  # trim whitespace
        [[ -z "$branch" || "$branch" == "$DATA_BRANCH" ]] && continue
        if git branch -d "$branch" 2>/dev/null; then
            stale_local=$((stale_local + 1))
        fi
    done < <(git branch --merged main 2>/dev/null | grep -E '^\s*(data|fix|enhance)/' || true)

    # Remote: prune tracking refs for deleted remote branches
    git remote prune origin 2>/dev/null || true

    # Remote: delete old merged data/* branches on origin (older than 3 days)
    stale_remote=0
    while IFS= read -r ref; do
        [[ -z "$ref" ]] && continue
        branch_name="${ref#origin/}"
        # Skip today's and yesterday's branches
        [[ "$branch_name" == "data/${TODAY}"* ]] && continue
        yesterday=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d 2>/dev/null || echo "")
        [[ -n "$yesterday" && "$branch_name" == "data/${yesterday}"* ]] && continue
        if git push origin --delete "$branch_name" 2>/dev/null; then
            stale_remote=$((stale_remote + 1))
        fi
    done < <(git branch -r --merged origin/main 2>/dev/null | grep -E '^\s*origin/(data|fix|enhance)/' | sed 's/^\s*//' || true)

    if [[ $stale_local -gt 0 || $stale_remote -gt 0 ]]; then
        marvin_log "INFO" "Cleaned ${stale_local} local + ${stale_remote} remote stale branches"
    fi
else
    marvin_log "WARN" "Data PR #${PR_NUMBER} could not be auto-merged (branch protection?). Merge manually: ${PR_URL}"
fi

marvin_log "INFO" "=== LOG EXPORT COMPLETE ==="
