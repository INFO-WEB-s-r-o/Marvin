#!/usr/bin/env bash
# =============================================================================
# Marvin — GitHub Issue Fixer (runs every 2 hours)
# =============================================================================
# Reads open GitHub issues, asks Claude to fix ONE, validates changes,
# creates a PR, auto-merges if safe, and closes the issue.
#
# Safety:
#   - Lock file prevents concurrent runs
#   - Trap handler always returns to clean main
#   - Pre-commit validation: bash -n on ALL scripts + conflict marker check
#   - Branch isolation: never commits to main directly
#   - GitHub API merge: server-side merge avoids local conflicts
#   - Max 1 issue per run to limit blast radius
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/lib/github.sh"
trap marvin_error_trap ERR

LOCK_FILE="/tmp/marvin-fix-issues.lock"
# Snapshot pre-existing untracked files BEFORE trap can fire (#285, #287)
_PRE_UNTRACKED=$(git ls-files --others --exclude-standard -- agent/ web/ 2>/dev/null || echo "")

# ─── Cleanup trap — always return to clean main ─────────────────────────────

cleanup() {
    local exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
        marvin_log "WARN" "fix-issues exiting with code ${exit_code}" 2>/dev/null || true
    fi
    cd "$MARVIN_DIR" 2>/dev/null || true
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    if [[ "$current_branch" != "main" ]]; then
        # Reset index and discard all changes (handles unmerged state too)
        git reset HEAD 2>/dev/null || true
        git checkout -- . 2>/dev/null || true
        # Only remove untracked files created during this run, not pre-existing ones (#285)
        while IFS= read -r _f; do
            [[ -n "$_f" ]] || continue
            printf '%s\n' "$_PRE_UNTRACKED" | grep -qxF "$_f" || rm -f "$_f"
        done < <(git ls-files --others --exclude-standard -- agent/ web/ 2>/dev/null) || true
        git checkout main 2>/dev/null || true
        # Delete local branch if it was never pushed
        if ! git ls-remote --heads origin "$current_branch" 2>/dev/null | grep -q "$current_branch"; then
            git branch -D "$current_branch" 2>/dev/null || true
        fi
    fi
    # Restore any stashed changes (safe pop to prevent conflict marker ghosts)
    if ! git stash pop --quiet 2>/dev/null; then
        if git diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
            git reset HEAD 2>/dev/null || true
            git checkout -- . 2>/dev/null || true
            git stash drop --quiet 2>/dev/null || true
        fi
    fi
    rm -f "$LOCK_FILE"
    exit $exit_code
}
trap cleanup EXIT

# ─── Lock ────────────────────────────────────────────────────────────────────

if [[ -f "$LOCK_FILE" ]]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
    if kill -0 "$pid" 2>/dev/null; then
        marvin_log "INFO" "fix-issues already running (PID $pid), skipping"
        exit 0
    fi
    # Stale lock file
    marvin_log "WARN" "Removing stale lock file (PID $pid no longer running)"
fi
echo "$$" > "${LOCK_FILE}"

marvin_log "INFO" "=== ISSUE FIXER STARTING ==="

# ─── Pre-flight ──────────────────────────────────────────────────────────────

check_claude || exit 1
github_check_token || exit 1

cd "$MARVIN_DIR"
git checkout main 2>/dev/null || true

# Skip if too many open PRs already (don't pile up)
open_prs=$(github_list_prs 10 2>/dev/null || echo "[]")
open_pr_count=$(echo "$open_prs" | jq 'length' 2>/dev/null || echo "0")
if [[ "$open_pr_count" -ge 3 ]]; then
    marvin_log "INFO" "Already ${open_pr_count} open PRs — skipping issue fixing to avoid pile-up"
    exit 0
fi

# ─── Fetch open issues ──────────────────────────────────────────────────────

marvin_log "INFO" "Fetching open GitHub issues..."
issues_json=$(github_list_issues "" 50 2>/dev/null || echo "[]")

# ─── Per-issue deduplication: skip issues that already have open PRs ─────────
# Extract issue numbers referenced in open PR titles, bodies, or branch names.
# This prevents the script from creating duplicate PRs for the same issue
# every 2 hours when a PR can't be auto-merged (e.g. branch protection rules).
pr_issue_numbers=""
if [[ "$open_pr_count" -gt 0 ]]; then
    # Collect issue numbers from multiple sources, combine at the end
    _dedup_nums=""

    # Source 1: PR titles — match #NNN or "issue NNN"/"issue-NNN" patterns
    _title_nums=$(echo "$open_prs" | jq -r '.[].title' 2>/dev/null \
        | grep -oiP '(?:#|issue[\s-])\K\d+' | sort -u | paste -sd',' - || echo "")
    [[ -n "$_title_nums" ]] && _dedup_nums+="${_title_nums},"

    # Source 2: PR bodies — "Fixes #NNN", "Closes #NNN", "Resolves #NNN"
    _body_nums=$(echo "$open_prs" | jq -r '.[].body // ""' 2>/dev/null \
        | grep -oiP '(?:fix(?:es)?|closes?|resolves?)\s*#\K\d+' | sort -u | paste -sd',' - || echo "")
    [[ -n "$_body_nums" ]] && _dedup_nums+="${_body_nums},"

    # Source 3: Branch names — "fix/issue-NNN-*" or "fix-issue-NNN"
    _branch_nums=$(echo "$open_prs" | jq -r '.[].head.ref // ""' 2>/dev/null \
        | grep -oiP 'issue[/-]\K\d+' | sort -u | paste -sd',' - || echo "")
    [[ -n "$_branch_nums" ]] && _dedup_nums+="${_branch_nums},"

    # Deduplicate combined results
    if [[ -n "$_dedup_nums" ]]; then
        pr_issue_numbers=$(echo "$_dedup_nums" | tr ',' '\n' | sed '/^$/d' | sort -un | paste -sd',' -)
    fi

    # Only warn if PRs look like issue-fix PRs but we couldn't extract numbers.
    # Enhancement/feature PRs (branch starts with enhance/, feature/, add/) are expected
    # to not reference issues — no warning needed.
    # Generic fix PRs (fix/morning-check-*, fix/sanitize-*) also don't need issue dedup —
    # only branches with "issue" in the name are expected to have extractable numbers.
    if [[ -z "$pr_issue_numbers" ]]; then
        # grep -c exits 1 on zero matches with "0" already printed — `|| true` swallows only the exit code (lessons-learned: grep-c-double-output)
        _has_issue_pr=$(echo "$open_prs" | jq -r '.[].head.ref // ""' 2>/dev/null \
            | grep -ciP '^fix[/-].*issue' || true)
        _has_issue_pr=${_has_issue_pr:-0}
        if [[ "$_has_issue_pr" -gt 0 ]]; then
            marvin_log "WARN" "Found issue-fix PRs but could not extract issue numbers — deduplication may not work correctly"
        else
            marvin_log "INFO" "Open PRs have no issue-referencing branches — no issue deduplication needed"
        fi
    fi
fi

if [[ -n "$pr_issue_numbers" ]]; then
    marvin_log "INFO" "Issues with existing open PRs (skipping): #${pr_issue_numbers}"
    issues_json=$(echo "$issues_json" | jq --arg nums "$pr_issue_numbers" '
        ($nums | split(",") | map(tonumber)) as $skip |
        [.[] | select(.pull_request == null) | select(.number as $n | $skip | index($n) | not)]
    ' 2>/dev/null || echo "$issues_json")
fi

issue_count=$(echo "$issues_json" | jq '[.[] | select(.pull_request == null)] | length' 2>/dev/null || echo "0")
if [[ "$issue_count" -eq 0 ]]; then
    marvin_log "INFO" "No open issues without existing PRs — nothing to fix"
    exit 0
fi

marvin_log "INFO" "Found ${issue_count} open issues (after filtering out issues with open PRs)"

# Build a compact issue list for Claude (oldest 15, titles + truncated bodies)
# Cap at 15 issues to keep prompt under ~25K chars
ISSUES_CONTEXT=$(echo "$issues_json" | jq -r '
    [.[] | select(.pull_request == null)] |
    sort_by(.number) |
    .[0:15] |
    .[] |
    "### Issue #\(.number): \(.title)\nLabels: \(.labels | map(.name) | join(", "))\n\(.body[:200] // "No description")\n---"
' 2>/dev/null || echo "No issues available")

if [[ "$issue_count" -gt 15 ]]; then
    marvin_log "INFO" "Showing 15 of ${issue_count} issues (oldest first)"
fi

# ─── Prepare prompt ─────────────────────────────────────────────────────────

FIX_PROMPT=$(cat "${PROMPTS_DIR}/fix-issues.md")

# Include open PR info so Claude also knows to avoid issues with pending PRs
# Security: only include PR numbers (safe integers), NOT titles.
# PR titles are user-supplied and could contain prompt injection payloads
# since anyone can open a PR against a public repo. (Fixes #235)
OPEN_PRS_CONTEXT=$(echo "$open_prs" | jq -r '.[] | "- PR #\(.number)"' 2>/dev/null || echo "None")

FULL_PROMPT="${FIX_PROMPT}

## Already Open PRs (do NOT attempt to fix these issues — a PR is already pending)

${OPEN_PRS_CONTEXT}

## Open GitHub Issues

${ISSUES_CONTEXT}"

# ─── Ensure clean working tree ──────────────────────────────────────────────

# Stash any uncommitted changes (from other cron jobs writing to data/)
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    git stash --quiet 2>/dev/null || true
    marvin_log "INFO" "Stashed uncommitted changes"
fi

# ─── Create fix branch ──────────────────────────────────────────────────────

# Re-snapshot in case git stash above changed the set of untracked files
_PRE_UNTRACKED=$(git ls-files --others --exclude-standard -- agent/ web/ 2>/dev/null || echo "")

BRANCH="fix/issues-${TIMESTAMP}"
git checkout -b "$BRANCH" 2>/dev/null
marvin_log "INFO" "Working on branch: ${BRANCH}"

# ─── Run Claude ──────────────────────────────────────────────────────────────

marvin_log "INFO" "Asking Claude to fix an issue..."
OUTPUT=$(run_claude "fix-issues" "$FULL_PROMPT")

# ─── Check for changes ──────────────────────────────────────────────────────

# Only track changes in directories we'll actually stage (agent/, web/, *.md)
# Concurrent cron jobs modify data/ files — those are never staged so ignore them
CHANGED=$(git diff --name-only -- agent/ web/ *.md 2>/dev/null || echo "")
UNTRACKED=$(git ls-files --others --exclude-standard -- agent/ web/ 2>/dev/null || echo "")

if [[ -z "$CHANGED" && -z "$UNTRACKED" ]]; then
    marvin_log "INFO" "No files changed — Claude may not have found a fixable issue"
    # Log the output for debugging
    echo "$OUTPUT" >> "${LOGS_DIR}/fix-issues-${TODAY}.log"
    exit 0
fi

marvin_log "INFO" "Files changed: ${CHANGED} ${UNTRACKED}"

# ─── Validate changes ───────────────────────────────────────────────────────

marvin_log "INFO" "Validating changes..."
VALID=true
VALIDATION_ERRORS=""

# 1. Bash syntax check on ALL agent scripts (catches cascading breakage)
while IFS= read -r script; do
    if ! bash -n "$script" 2>/dev/null; then
        VALID=false
        VALIDATION_ERRORS+="Syntax error: ${script}\n"
        marvin_log "ERROR" "VALIDATION FAILED: syntax error in $(basename "$script")"
    fi
done < <(find "${MARVIN_DIR}/agent" -name "*.sh" -type f)

# 2. Merge conflict marker check in changed/new files
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -f "$MARVIN_DIR/$f" ]] || continue
    if grep -qE '^<{7} |^={7}$|^>{7} ' "$MARVIN_DIR/$f" 2>/dev/null; then
        VALID=false
        VALIDATION_ERRORS+="Conflict markers: ${f}\n"
        marvin_log "ERROR" "VALIDATION FAILED: merge conflict markers in $f"
    fi
done < <(printf '%s\n%s\n' "$CHANGED" "$UNTRACKED")

# 3. Check that no data/ or runtime files were modified (changed AND untracked)
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
        data/*|*.db|*.db-*|*.log)
            VALID=false
            VALIDATION_ERRORS+="Forbidden file modified: ${f}\n"
            marvin_log "ERROR" "VALIDATION FAILED: forbidden file modified: $f"
            ;;
    esac
done < <(printf '%s\n%s\n' "$CHANGED" "$UNTRACKED")

if [[ "$VALID" != "true" ]]; then
    marvin_log "ERROR" "Validation failed — aborting fix. Errors: ${VALIDATION_ERRORS}"
    # Revert everything (trap will handle branch cleanup)
    git checkout -- . 2>/dev/null || true
    # Only remove untracked files created during this run, not pre-existing ones (#285)
    while IFS= read -r _f; do
        [[ -n "$_f" ]] || continue
        printf '%s\n' "$_PRE_UNTRACKED" | grep -qxF "$_f" || rm -f "$_f"
    done < <(git ls-files --others --exclude-standard -- agent/ web/ 2>/dev/null) || true
    exit 1
fi

marvin_log "INFO" "Validation passed"

# ─── Parse Claude's output for issue info ────────────────────────────────────

FIXED_ISSUE=$(echo "$OUTPUT" | grep -oP 'FIXED_ISSUE:\s*#?\K\d+' | head -1 || echo "")
FIXED_TITLE=$(echo "$OUTPUT" | grep -oP 'FIXED_TITLE:\s*\K.+' | head -1 || echo "unknown issue")
FIX_DESCRIPTION=$(echo "$OUTPUT" | grep -oP 'DESCRIPTION:\s*\K.+' | head -1 || echo "Automated fix")

if [[ -z "$FIXED_ISSUE" ]]; then
    # Try to extract issue number from output in other formats
    FIXED_ISSUE=$(echo "$OUTPUT" | grep -oP '#(\d+)' | head -1 | tr -d '#' || echo "")
fi

marvin_log "INFO" "Attempting fix for issue: #${FIXED_ISSUE:-unknown} — ${FIXED_TITLE}"

# ─── Stage and commit ────────────────────────────────────────────────────────

# Only stage files in safe directories
git add -- agent/ web/ 2>/dev/null || true
# Also stage root-level .md files if changed (CHANGELOG etc.)
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
        *.md) git add -- "$f" 2>/dev/null || true ;;
    esac
done <<< "$CHANGED"

if git diff --cached --quiet 2>/dev/null; then
    marvin_log "INFO" "No staged changes after filtering — nothing to commit"
    exit 0
fi

COMMIT_MSG="fix: resolve issue #${FIXED_ISSUE:-unknown} — ${FIXED_TITLE}

${FIX_DESCRIPTION}

Automated fix by Marvin's issue-fixer agent.
Validated: bash syntax OK, no conflict markers, no forbidden files."

# GPG signing requires GNUPGHOME (set in common.sh). Handle failure explicitly
# instead of letting set -e kill the script silently (this was causing a loop
# where fixes were reverted by the cleanup trap with no error log).
if ! git commit -S -m "$COMMIT_MSG" 2>&1; then
    marvin_log "ERROR" "git commit -S failed for issue #${FIXED_ISSUE:-unknown} (GPG signing may have failed)"
    exit 1
fi
marvin_log "INFO" "Committed fix on branch ${BRANCH}: #${FIXED_ISSUE:-unknown} — ${FIXED_TITLE}"

# ─── Push, create PR, merge ─────────────────────────────────────────────────

github_setup_remote

if ! git push origin "$BRANCH" 2>&1; then
    marvin_log "ERROR" "Failed to push branch ${BRANCH}"
    exit 1
fi
marvin_log "INFO" "Pushed branch ${BRANCH}"

PR_TITLE="fix: #${FIXED_ISSUE:-?} ${FIXED_TITLE}"
# Truncate PR title to 70 chars
PR_TITLE="${PR_TITLE:0:70}"

PR_BODY="## Automated Issue Fix

**Issue:** #${FIXED_ISSUE:-unknown} — ${FIXED_TITLE}

**Fix:** ${FIX_DESCRIPTION}

### Changed Files
\`\`\`
$(git diff --name-only main..HEAD)
\`\`\`

### Validation
- [x] All bash scripts pass \`bash -n\` syntax check
- [x] No merge conflict markers in changed files
- [x] No data/runtime files modified
- [x] GPG-signed commit

---
*Automated fix by Marvin's issue-fixer agent.*

Closes #${FIXED_ISSUE:-unknown}"

# Create PR via github_api directly — branch was already pushed above, so
# skip github_create_pr which would double-push and pollute stdout with
# git output + log messages (breaking jq parsing of the JSON response).
PR_PAYLOAD=$(jq -n \
    --arg title "$PR_TITLE" \
    --arg body "$PR_BODY" \
    --arg head "$BRANCH" \
    --arg base "main" \
    '{title: $title, body: $body, head: $head, base: $base}')

pr_response=$(github_api POST "/repos/${GITHUB_REPO}/pulls" "$PR_PAYLOAD" 2>/dev/null || echo "{}")
pr_number=$(echo "$pr_response" | jq -r '.number // empty' 2>/dev/null || echo "")

if [[ -z "$pr_number" ]]; then
    marvin_log "WARN" "Failed to create PR — cleaning up orphan remote branch ${BRANCH}"
    # Delete the just-pushed branch on remote so failed PR-creation attempts don't
    # accumulate as orphans. Local branch is left as-is (the EXIT trap returns to
    # main and any stash recovery happens there). Use `:` (delete) syntax instead
    # of --delete so an already-gone branch is a no-op, not an error.
    git push origin ":${BRANCH}" 2>&1 | _sanitize_git_output >&2 || \
        marvin_log "WARN" "Could not delete remote branch ${BRANCH} — may need manual cleanup"
    exit 1
fi

marvin_log "INFO" "Created PR #${pr_number}"

# Do NOT attempt auto-merge. Branch protection requires at least 1 approving
# review before merge is allowed (HTTP 405). The CI wait loop was also removed
# (fixes #588) — it polled for up to 5 min but MERGE_OK was never used after
# the merge call was deleted. PRs are merged by Pavel after review.
# See lessons-learned.json: branch-protection-no-auto-merge
marvin_log "INFO" "PR #${pr_number} created for issue #${FIXED_ISSUE:-unknown} — awaiting review (branch protection requires approval)"

# Save run log
cat >> "${LOGS_DIR}/fix-issues-${TODAY}.log" << EOF

## Fix Run — ${NOW}
- Issue: #${FIXED_ISSUE:-unknown} — ${FIXED_TITLE}
- PR: #${pr_number:-unknown}
- Description: ${FIX_DESCRIPTION}
- Branch: ${BRANCH}
- Output: ${OUTPUT}
---
EOF

marvin_log "INFO" "=== ISSUE FIXER COMPLETE ==="
