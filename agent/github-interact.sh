#!/usr/bin/env bash
# =============================================================================
# Marvin — GitHub Interaction Agent (runs via cron, every hour)
# =============================================================================
# Autonomous GitHub activity:
#   - Pushes GPG-signed commits to the public repo
#   - Creates issues for notable events (incidents, discoveries, ideas)
#   - Creates PRs for self-enhancement proposals
#   - Comments on existing issues with status updates
#   - All actions carry GPG signatures as proof of Marvin's authorship
#
# Cron: 0 * * * *  (every hour at :00)
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/lib/github.sh"

marvin_log "INFO" "=== GITHUB INTERACTION STARTING ==="

# ─── Pre-flight checks ──────────────────────────────────────────────────────

if ! github_check_token; then
    marvin_log "ERROR" "Cannot proceed without valid GitHub token"
    exit 1
fi

check_claude || exit 1

# Read the GitHub prompt
GITHUB_PROMPT=$(cat "${PROMPTS_DIR}/github.md")

# ─── Phase 1: Push latest commits to GitHub ─────────────────────────────────
marvin_log "INFO" "Phase 1: Syncing commits to GitHub..."

github_setup_remote

PUSH_RESULT="Push skipped — no new commits or push failed."
if git -C "$MARVIN_DIR" log origin/main..main --oneline 2>/dev/null | head -5 | grep -q .; then
    if github_push_main 2>&1; then
        local_commits=$(git -C "$MARVIN_DIR" log --oneline -5 2>/dev/null || echo "none")
        PUSH_RESULT="Successfully pushed to GitHub. Recent commits:\n${local_commits}"
        marvin_log "INFO" "Commits pushed to GitHub successfully"
    else
        PUSH_RESULT="Push failed — will retry next run."
        marvin_log "WARN" "Failed to push commits to GitHub"
    fi
else
    PUSH_RESULT="Already up to date with GitHub."
    marvin_log "INFO" "No new commits to push"
fi

# ─── Phase 2: Gather context for Claude ──────────────────────────────────────
marvin_log "INFO" "Phase 2: Gathering context for GitHub activity decisions..."

TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)

# Recent logs
RECENT_LOGS=""
for logfile in "${LOGS_DIR}/${TODAY}.log" "${LOGS_DIR}/${YESTERDAY}.log"; do
    if [[ -f "$logfile" ]]; then
        RECENT_LOGS+="### $(basename "$logfile")
$(tail -50 "$logfile")

"
    fi
done

# Recent enhancements
RECENT_ENHANCEMENTS=""
for efile in "${MARVIN_DIR}/data/enhancements"/*.md; do
    if [[ -f "$efile" ]]; then
        file_date=$(stat -c %Y "$efile" 2>/dev/null || stat -f %m "$efile" 2>/dev/null || echo 0)
        cutoff=$(date -d "2 days ago" +%s 2>/dev/null || date -v-2d +%s 2>/dev/null || echo 0)
        if [[ "$file_date" -gt "$cutoff" ]]; then
            RECENT_ENHANCEMENTS+="### $(basename "$efile")
$(head -50 "$efile")

"
        fi
    fi
done

# Recent blog posts
RECENT_BLOGS=""
for bfile in "${BLOG_DIR}"/*"${TODAY}"* "${BLOG_DIR}"/*"${YESTERDAY}"*; do
    if [[ -f "$bfile" ]]; then
        RECENT_BLOGS+="### $(basename "$bfile")
$(head -40 "$bfile")
...
"
    fi
done

# Communication log
COMMS_SUMMARY=""
if [[ -f "${COMMS_DIR}/comms-summary.json" ]]; then
    COMMS_SUMMARY=$(head -c 5000 "${COMMS_DIR}/comms-summary.json")
fi

# Existing GitHub issues (to avoid duplicates)
EXISTING_ISSUES=""
issues_response=$(github_list_issues "" 20 2>/dev/null || echo "[]")
if [[ "$issues_response" != "[]" ]] && echo "$issues_response" | jq -e '.[0]' &>/dev/null; then
    EXISTING_ISSUES=$(echo "$issues_response" | jq -r '.[] | "- #\(.number): \(.title) [\(.labels | map(.name) | join(", "))]"' 2>/dev/null || echo "none")
fi

# Enhancement roadmap
ENHANCEMENTS=""
if [[ -f "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" ]]; then
    ENHANCEMENTS=$(head -200 "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md")
fi

# ─── Phase 3: Ask Claude what to do ─────────────────────────────────────────
marvin_log "INFO" "Phase 3: Consulting Claude for GitHub activity decisions..."

CONTEXT="## Current State

### Push Status
${PUSH_RESULT}

### Recent Logs
${RECENT_LOGS:-No recent logs.}

### Recent Self-Enhancements
${RECENT_ENHANCEMENTS:-No recent enhancements.}

### Recent Blog Posts
${RECENT_BLOGS:-No recent blog posts.}

### Communication Activity
${COMMS_SUMMARY:-No comms data.}

### Existing Open GitHub Issues
${EXISTING_ISSUES:-No open issues.}

### Enhancement Roadmap
${ENHANCEMENTS:-No roadmap found.}

### Timestamp
$(date -u '+%Y-%m-%d %H:%M:%S UTC')

### GPG Key ID
$(marvin_gpg_key_id)"

FULL_PROMPT="${GITHUB_PROMPT}

${CONTEXT}"

RESPONSE=$(run_claude "github-interact" "$FULL_PROMPT")
if [[ -z "$RESPONSE" ]]; then
    marvin_log "ERROR" "No response from Claude for GitHub decisions"
    exit 1
fi

# Save the raw response for audit
ACTIVITY_FILE="${LOGS_DIR}/github-activity-${TODAY}.md"
echo "# GitHub Activity — ${TODAY} $(date -u +%H:%M)" >> "$ACTIVITY_FILE"
echo "" >> "$ACTIVITY_FILE"
echo "$RESPONSE" >> "$ACTIVITY_FILE"
echo "---" >> "$ACTIVITY_FILE"

# ─── Phase 4: Parse and execute GitHub actions ───────────────────────────────
marvin_log "INFO" "Phase 4: Executing GitHub actions from Claude's response..."

ACTION_COUNT=0
ERROR_COUNT=0

# Parse ISSUE blocks
# Format: ===ISSUE===\ntitle: ...\nlabels: ...\nbody follows\n===END_ISSUE===
while IFS= read -r -d '' issue_block; do
    ISSUE_TITLE=$(echo "$issue_block" | grep -oP '^title:\s*\K.+' | head -1)
    ISSUE_LABELS=$(echo "$issue_block" | grep -oP '^labels:\s*\K.+' | head -1)
    ISSUE_BODY=$(echo "$issue_block" | sed '1,/^labels:/d' | sed '/^===END_ISSUE===/d')

    if [[ -n "$ISSUE_TITLE" && -n "$ISSUE_BODY" ]]; then
        # GPG-sign the issue body
        SIGNATURE=$(marvin_sign "$ISSUE_BODY" 2>/dev/null || echo "")
        if [[ -n "$SIGNATURE" ]]; then
            ISSUE_BODY+="

---
*🔐 GPG-signed by Marvin (Key: \`$(marvin_gpg_key_id)\`)*
<details><summary>Signature</summary>

\`\`\`
${SIGNATURE}
\`\`\`
</details>"
        fi

        if github_create_issue "$ISSUE_TITLE" "$ISSUE_BODY" "${ISSUE_LABELS:-marvin-auto}"; then
            ACTION_COUNT=$((ACTION_COUNT + 1))
            marvin_log "INFO" "Created issue: ${ISSUE_TITLE}"
        else
            ERROR_COUNT=$((ERROR_COUNT + 1))
            marvin_log "ERROR" "Failed to create issue: ${ISSUE_TITLE}"
        fi
    fi
done < <(echo "$RESPONSE" | sed -n '/===ISSUE===/,/===END_ISSUE===/p' | \
    awk '/===ISSUE===/{if(NR>1) printf "\0"; next} /===END_ISSUE===/{next} {print}')

# Parse COMMENT blocks
# Format: ===COMMENT===\nissue: #number\nbody follows\n===END_COMMENT===
while IFS= read -r -d '' comment_block; do
    COMMENT_ISSUE=$(echo "$comment_block" | grep -oP '^issue:\s*#?\K\d+' | head -1)
    COMMENT_BODY=$(echo "$comment_block" | sed '1,/^issue:/d' | sed '/^===END_COMMENT===/d')

    if [[ -n "$COMMENT_ISSUE" && -n "$COMMENT_BODY" ]]; then
        # GPG-sign the comment
        SIGNATURE=$(marvin_sign "$COMMENT_BODY" 2>/dev/null || echo "")
        if [[ -n "$SIGNATURE" ]]; then
            COMMENT_BODY+="

---
*🔐 GPG-signed by Marvin*
<details><summary>Signature</summary>

\`\`\`
${SIGNATURE}
\`\`\`
</details>"
        fi

        if github_comment_issue "$COMMENT_ISSUE" "$COMMENT_BODY"; then
            ACTION_COUNT=$((ACTION_COUNT + 1))
            marvin_log "INFO" "Commented on issue #${COMMENT_ISSUE}"
        else
            ERROR_COUNT=$((ERROR_COUNT + 1))
            marvin_log "ERROR" "Failed to comment on issue #${COMMENT_ISSUE}"
        fi
    fi
done < <(echo "$RESPONSE" | sed -n '/===COMMENT===/,/===END_COMMENT===/p' | \
    awk '/===COMMENT===/{if(NR>1) printf "\0"; next} /===END_COMMENT===/{next} {print}')

# Parse CLOSE blocks
# Format: ===CLOSE===\nissue: #number\nreason: ...\n===END_CLOSE===
while IFS= read -r line; do
    if [[ "$line" =~ ^issue:\ *#?([0-9]+) ]]; then
        CLOSE_ISSUE="${BASH_REMATCH[1]}"
        CLOSE_REASON=$(echo "$RESPONSE" | sed -n "/===CLOSE===/,/===END_CLOSE===/p" | grep -oP "^reason:\s*\K.+" | head -1)

        if [[ -n "$CLOSE_REASON" ]]; then
            github_comment_issue "$CLOSE_ISSUE" "Closing: ${CLOSE_REASON}

*— Marvin (autonomous)*"
        fi

        if github_close_issue "$CLOSE_ISSUE"; then
            ACTION_COUNT=$((ACTION_COUNT + 1))
            marvin_log "INFO" "Closed issue #${CLOSE_ISSUE}"
        else
            ERROR_COUNT=$((ERROR_COUNT + 1))
        fi
    fi
done < <(echo "$RESPONSE" | sed -n '/===CLOSE===/,/===END_CLOSE===/p')

# ─── Phase 5: Summary ───────────────────────────────────────────────────────

SUMMARY="GitHub interaction complete: ${ACTION_COUNT} actions performed, ${ERROR_COUNT} errors."
marvin_log "INFO" "$SUMMARY"

# Append summary to activity log
echo "" >> "$ACTIVITY_FILE"
echo "## Summary" >> "$ACTIVITY_FILE"
echo "$SUMMARY" >> "$ACTIVITY_FILE"

marvin_log "INFO" "=== GITHUB INTERACTION COMPLETE ==="
