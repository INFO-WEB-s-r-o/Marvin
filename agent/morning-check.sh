#!/usr/bin/env bash
# =============================================================================
# Marvin — Morning Check (runs daily at 06:00 UTC)
# =============================================================================
# Full system maintenance via Claude Code:
#   - Pull latest code from GitHub (new prompts, instructions, projects)
#   - Process and learn from incoming changes
#   - Security audit
#   - Package updates
#   - Log cleanup
#   - Disk maintenance
#   - Service health review
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

marvin_log_json "INFO" "morning-check" "Morning check starting"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 0: Pull latest code from GitHub
# ─────────────────────────────────────────────────────────────────────────────
# Humans (Pavel) or Marvin himself may have pushed new prompts, code, or
# project ideas to the repo. Pull them in before doing anything else.

PULL_SUMMARY=""
INCOMING_DIFF=""
INCOMING_LOG=""
INCOMING_FULL_DIFF=""

if [[ -f "$(dirname "$0")/lib/github.sh" ]]; then
    source "$(dirname "$0")/lib/github.sh"

    if github_check_token 2>/dev/null; then
        marvin_log "INFO" "Pulling latest code from GitHub..."
        cd "$MARVIN_DIR"
        github_setup_remote

        # Clean stale rebase artifacts — a stuck REBASE_HEAD blocks git operations
        # even after git rebase --abort succeeds (e.g., if rebase-merge/ was cleaned
        # but REBASE_HEAD was left behind). Safe to remove when no rebase dirs exist.
        if [[ -f "${MARVIN_DIR}/.git/REBASE_HEAD" ]] && \
           [[ ! -d "${MARVIN_DIR}/.git/rebase-merge" ]] && \
           [[ ! -d "${MARVIN_DIR}/.git/rebase-apply" ]]; then
            marvin_log "WARN" "Removing stale .git/REBASE_HEAD (no active rebase)"
            rm -f "${MARVIN_DIR}/.git/REBASE_HEAD"
        fi

        # Discard ALL unstaged changes before pulling. data/ files are
        # regenerated every 5 min by health-monitor.sh. Other files
        # (CODEOWNERS, etc.) may be dirtied by other cron jobs or broken
        # rebases. None of this local state is worth preserving — it's
        # all either auto-generated or will be recreated by the next run.
        if ! git diff --quiet 2>/dev/null; then
            dirty_count=$(git diff --name-only 2>/dev/null | wc -l)
            dirty_files=$(git diff --name-only 2>/dev/null | head -10)
            [[ "$dirty_count" -gt 10 ]] && dirty_files="${dirty_files} (and $((dirty_count - 10)) more)"
            marvin_log "INFO" "Discarding ${dirty_count} unstaged changes before pull: ${dirty_files}"
            git checkout -- . 2>/dev/null || marvin_log "WARN" "git checkout -- . failed, pull may fail"
        fi

        # Clear any staged changes left by broken rebases or interrupted scripts
        if ! git diff --cached --quiet 2>/dev/null; then
            marvin_log "INFO" "Resetting staged changes before pull"
            git reset HEAD --quiet 2>/dev/null || marvin_log "WARN" "git reset HEAD failed, pull may fail"
            git checkout -- . 2>/dev/null || marvin_log "WARN" "git checkout -- . failed after reset"
        fi

        # Remove untracked files in data/ — health-monitor.sh and other cron jobs
        # create new files (e.g., new date-sharded JSONL, temp .tmp files) that
        # aren't in the git index. These can block rebase if incoming commits
        # touch the same paths. Safe to remove since data/ is fully regenerated.
        _untracked_data=$(git ls-files --others --exclude-standard -- data/ 2>/dev/null | wc -l)
        if [[ "$_untracked_data" -gt 0 ]]; then
            marvin_log "INFO" "Cleaning ${_untracked_data} untracked file(s) in data/"
            git clean -fd data/ 2>/dev/null || marvin_log "WARN" "git clean -fd data/ failed"
        fi

        # Record the current HEAD before pulling
        OLD_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

        # Fetch first so we know if there's anything to pull
        git fetch --prune origin 2>/dev/null || true

        # Pull with rebase to keep history clean.
        # rebase.autoStash=true fixes a race condition: health-monitor.sh (every 5 min)
        # can re-dirty data/ files between the git checkout above and this pull command.
        # autoStash makes git stash before rebase and pop after, eliminating the race.
        pull_output=$(git -c rebase.autoStash=true pull --rebase origin main 2>&1) && pull_ok=true || pull_ok=false
        marvin_log "INFO" "git pull output: ${pull_output}"
        if [[ "$pull_ok" == "true" ]]; then
            NEW_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

            if [[ "$OLD_HEAD" != "$NEW_HEAD" ]]; then
                # There are new commits — capture what changed
                INCOMING_DIFF=$(git diff --stat "$OLD_HEAD".."$NEW_HEAD" 2>/dev/null || echo "")
                INCOMING_LOG=$(git log --oneline "$OLD_HEAD".."$NEW_HEAD" 2>/dev/null || echo "")
                INCOMING_FULL_DIFF=$(git diff "$OLD_HEAD".."$NEW_HEAD" 2>/dev/null | head -2000 || echo "")

                COMMIT_COUNT=$(echo "$INCOMING_LOG" | wc -l | tr -d ' ')
                PULL_SUMMARY="Pulled ${COMMIT_COUNT} new commit(s) from GitHub."

                marvin_log "INFO" "$PULL_SUMMARY"
                marvin_log "INFO" "Changed files:\n${INCOMING_DIFF}"

                # Make new scripts executable
                chmod +x "${MARVIN_DIR}/agent/"*.sh 2>/dev/null || true
                chmod +x "${MARVIN_DIR}/setup/"*.sh 2>/dev/null || true

                # Run check mode (not --update): only auto-refreshes files that
                # match git HEAD. A tamper between the 02:00 security-scan and this
                # 04:00 pull surfaces as a CHANGED alert instead of being silently
                # baked into the baseline by a blind reset. INCOMING_DIFF is
                # `git diff --stat` output; the bash glob avoids the
                # SIGPIPE-under-pipefail trap from echo|grep -q (lesson 2026-05-02).
                if [[ "$INCOMING_DIFF" == *" agent/"* ]]; then
                    integrity_script="${MARVIN_DIR}/agent/file-integrity.sh"
                    if [[ -x "$integrity_script" ]]; then
                        if "$integrity_script" 2>&1; then
                            marvin_log "INFO" "File integrity checked after pulling agent script changes (baseline auto-refreshes for git-synced files)"
                        else
                            marvin_log "WARN" "File integrity check failed after pull (non-fatal)"
                        fi
                    fi
                fi

                # Auto-deploy web dashboard if web/ source files changed
                # Without this, new builds have different chunk hashes but the
                # running server still serves old HTML — causing JS 404 loops.
                if echo "$INCOMING_DIFF" | grep -q ' web/'; then
                    marvin_log "INFO" "Web source files changed — triggering deploy-web.sh"
                    deploy_script="${MARVIN_DIR}/agent/deploy-web.sh"
                    if [[ -x "$deploy_script" ]]; then
                        _deploy_exit=0
                        bash "$deploy_script" 2>&1 || _deploy_exit=$?
                        if [[ "$_deploy_exit" -eq 0 ]]; then
                            marvin_log "INFO" "Web dashboard deployed successfully after git pull"
                        else
                            marvin_log "WARN" "deploy-web.sh failed (exit ${_deploy_exit}) — health-monitor will retry"
                        fi
                    else
                        marvin_log "WARN" "deploy-web.sh not found or not executable — skipping auto-deploy"
                    fi
                fi
            else
                PULL_SUMMARY="Already up to date — no new commits."
                marvin_log "INFO" "$PULL_SUMMARY"
            fi
        else
            PULL_SUMMARY="Git pull failed — will work with current code."
            marvin_log "WARN" "Git pull --rebase failed, attempting merge..."
            git rebase --abort 2>/dev/null || true
            # Force-clean tree before retry — rebase failure may leave dirty state
            git checkout -- . 2>/dev/null || marvin_log "WARN" "git checkout -- . failed during merge fallback"
            git reset HEAD --quiet 2>/dev/null || marvin_log "WARN" "git reset failed during merge fallback"
            git pull origin main 2>&1 || {
                marvin_log "ERROR" "Git pull failed entirely"
            }
        fi

        # Data files will be regenerated by the next health-monitor/update-website run

        # ── Stale branch cleanup ──────────────────────────────────────────────
        # PRs merged on GitHub leave local branches behind. Clean up branches
        # whose remote counterpart was deleted (i.e., PR was merged/closed).
        marvin_log "INFO" "Cleaning stale local branches..."
        stale_cleaned=0
        while IFS= read -r branch; do
            [[ -z "$branch" || "$branch" == "main" ]] && continue
            # Keep branches that still have a remote counterpart (local check after fetch --prune)
            if git show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
                continue
            fi
            # Only delete if merged into main (safe) or older than 7 days
            if git branch --merged main 2>/dev/null | grep -qF "  ${branch}"; then
                git branch -d "$branch" 2>/dev/null && {
                    stale_cleaned=$((stale_cleaned + 1))
                    marvin_log "INFO" "Deleted merged stale branch ${branch}"
                } || true
            else
                # Check branch age — force-delete if >7 days old with no remote
                branch_date=$(git log -1 --format='%ci' "$branch" 2>/dev/null | cut -d' ' -f1) || continue
                if [[ -n "$branch_date" ]]; then
                    branch_epoch=$(date -d "$branch_date" +%s 2>/dev/null) || continue
                    now_epoch=$(date +%s)
                    age_days=$(( (now_epoch - branch_epoch) / 86400 ))
                    if [[ "$age_days" -gt 7 ]]; then
                        git branch -D "$branch" 2>/dev/null && stale_cleaned=$((stale_cleaned + 1)) || true
                        marvin_log "INFO" "Force-deleted stale branch ${branch} (${age_days} days old, no remote)"
                    fi
                fi
            fi
        done < <(git branch 2>/dev/null | grep -v '^\* ' | sed 's/^ *//')
        if [[ "$stale_cleaned" -gt 0 ]]; then
            marvin_log "INFO" "Cleaned ${stale_cleaned} stale local branch(es)"
        fi

        # ── Stash pruning ───────────────────────────────────────────────────
        # Auto-stashes accumulate over time (one per morning-check + fix-issues
        # collisions). Keep last 5, drop the rest to prevent unbounded growth.
        _stash_count=$(git stash list 2>/dev/null | wc -l)
        if [[ "$_stash_count" -gt 5 ]]; then
            _stash_pruned=0
            # Drop from oldest (highest index) to keep newest 5
            for (( _si = _stash_count - 1; _si >= 5; _si-- )); do
                git stash drop "stash@{${_si}}" --quiet 2>/dev/null && _stash_pruned=$((_stash_pruned + 1)) || true
            done
            if [[ "$_stash_pruned" -gt 0 ]]; then
                marvin_log "INFO" "Pruned ${_stash_pruned} old stash(es) (kept 5 most recent)"
            fi
        fi
    else
        PULL_SUMMARY="No GitHub token — working with local code only."
        marvin_log "INFO" "$PULL_SUMMARY"
    fi
else
    PULL_SUMMARY="GitHub library not available — working with local code only."
    marvin_log "INFO" "$PULL_SUMMARY"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 0b: Process incoming changes with Claude
# ─────────────────────────────────────────────────────────────────────────────
# If new code/prompts arrived, Marvin should read, understand, and act on them.

if [[ -n "$INCOMING_DIFF" ]]; then
    marvin_log "INFO" "Processing incoming changes from GitHub..."

    SYNC_PROMPT=$(cat "${PROMPTS_DIR}/sync-learn.md" 2>/dev/null || echo "")

    if [[ -n "$SYNC_PROMPT" ]]; then
        SYNC_CONTEXT="## Incoming Changes Summary

### Git Pull Status
${PULL_SUMMARY}

### Commits
\`\`\`
${INCOMING_LOG:0:5000}
\`\`\`

### Changed Files
\`\`\`
${INCOMING_DIFF}
\`\`\`

### Full Diff (truncated to 2000 chars)
\`\`\`diff
${INCOMING_FULL_DIFF}
\`\`\`

### Current Enhancement Roadmap
$(cat "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" 2>/dev/null | head -100 || echo "Not found")

### Current Codebase Structure
\`\`\`
$(find "${MARVIN_DIR}/agent" -type f -name "*.sh" | sort)
$(find "${MARVIN_DIR}/agent/prompts" -type f -name "*.md" | sort)
$(find "${MARVIN_DIR}/web" -type f -not -path "*/node_modules/*" -not -path "*/.next/*" | sort | head -50)
\`\`\`"

        SYNC_FULL="${SYNC_PROMPT}

${SYNC_CONTEXT}"

        SYNC_EXIT=0
        SYNC_OUTPUT=$(run_claude "sync-and-learn" "$SYNC_FULL") || SYNC_EXIT=$?
        if [[ $SYNC_EXIT -ne 0 ]]; then
            marvin_log "WARN" "sync-and-learn Claude run failed (exit=${SYNC_EXIT}) — skipping learn report"
        else
            # Save the learning report
            LEARN_FILE="${DATA_DIR}/enhancements/${TODAY}-sync-learn-${TIMESTAMP}.md"
            cat > "$LEARN_FILE" << EOF
# Sync & Learn Report — ${NOW}

## Pull Summary
${PULL_SUMMARY}

## Claude's Analysis & Actions

${SYNC_OUTPUT}

---
*Triggered by git pull at morning check*
EOF

            marvin_log "INFO" "Sync-and-learn report saved: ${LEARN_FILE}"
        fi
    else
        marvin_log "WARN" "sync-learn.md prompt not found — skipping change analysis"
    fi
fi

check_claude || exit 1

# Read the morning prompt
MORNING_PROMPT=$(cat "${PROMPTS_DIR}/morning.md")

# Gather extra context for Claude
EXTRA_CONTEXT=$(cat << 'CONTEXT'
## Additional System Context

### Recent SSH Activity
```
CONTEXT
)
EXTRA_CONTEXT+=$(journalctl -u ssh --since "yesterday" --no-pager 2>/dev/null | tail -50 || echo "no journal data")
EXTRA_CONTEXT+=$(cat << 'CONTEXT'
```

### Disk Usage
```
CONTEXT
)
EXTRA_CONTEXT+=$(df -h 2>/dev/null | head -20 || echo "df not available")
EXTRA_CONTEXT+=$(cat << 'CONTEXT'
```

### Failed Services
```
CONTEXT
)
EXTRA_CONTEXT+=$(systemctl --failed --no-pager 2>/dev/null | head -30 || echo "systemctl not available")
EXTRA_CONTEXT+=$(cat << 'CONTEXT'
```

### Top Processes by Memory
```
CONTEXT
)
EXTRA_CONTEXT+=$(ps aux --sort=-%mem | head -15 2>/dev/null || echo "ps not available")
EXTRA_CONTEXT+=$(cat << 'CONTEXT'
```

### Fail2ban Status
```
CONTEXT
)
# Strip the raw IP list — long unstructured IP lists in the prompt have
# tripped the Anthropic usage-policy classifier (3 consecutive morning-check
# failures 2026-04-21..23, blocking the email-reply step inside the prompt).
# Counts (currently/total banned) above the list are the actionable signal.
EXTRA_CONTEXT+=$(fail2ban-client status sshd 2>/dev/null \
    | sed -E 's/(Banned IP list:[[:space:]]*).*/\1[list omitted — see fail2ban-client directly]/' \
    || echo "fail2ban not available")
EXTRA_CONTEXT+=$(cat << 'CONTEXT'
```

### Pending Updates
```
CONTEXT
)
EXTRA_CONTEXT+=$(apt list --upgradable 2>/dev/null | head -20 || echo "apt not available")
EXTRA_CONTEXT+="
\`\`\`"

# Add pull summary to context for Claude's morning check
if [[ -n "${PULL_SUMMARY:-}" ]]; then
    EXTRA_CONTEXT+="

### GitHub Pull Status
${PULL_SUMMARY}"
    if [[ -n "${INCOMING_DIFF:-}" ]]; then
        EXTRA_CONTEXT+="

### Files Changed from GitHub
\`\`\`
${INCOMING_DIFF}
\`\`\`"
    fi
fi

FULL_PROMPT="${MORNING_PROMPT}

${EXTRA_CONTEXT}"

# Run Claude with the morning prompt. Up to 2 retries on transient exit=1
# with escalating backoff (15s, 60s): morning-check runs once per day, so a
# single API error or stochastic usage-policy classifier rejection would
# otherwise lose the whole day's blog post until tomorrow (see 2026-04-21
# and 2026-04-23 incidents — both attempts at 15s apart failed).
CLAUDE_EXIT=0
OUTPUT=$(run_claude_with_retry "morning-check" "$FULL_PROMPT" 2) || CLAUDE_EXIT=$?

if [[ $CLAUDE_EXIT -ne 0 ]]; then
    marvin_log "WARN" "Claude run failed (exit=${CLAUDE_EXIT}) — skipping blog write to avoid publishing error messages"
else
    # Screen for sensitive data before publishing (fixes #563)
    if ! screen_blog_content "$OUTPUT" "morning"; then
        marvin_log "ERROR" "Morning blog failed sensitive content screening — blocking publication"
        exit 1
    fi

    # Save the morning report — check if Claude already wrote the file directly
    MORNING_FILE="${BLOG_DIR}/${TODAY}-morning.md"
    if [[ -f "$MORNING_FILE" ]] && head -1 "$MORNING_FILE" | grep -q '^# '; then
        marvin_log "INFO" "Claude created morning report directly — screening file content"
        file_content=$(cat "$MORNING_FILE")
        if ! screen_blog_content "$file_content" "morning-file"; then
            marvin_log "ERROR" "Morning blog file failed sensitive content screening — removing"
            rm -f "$MORNING_FILE"
            exit 1
        fi
    else
        cat > "$MORNING_FILE" << EOF
# Morning Report — ${TODAY}

${OUTPUT}

---
*Generated by Marvin at ${NOW}*
EOF
    fi

    # Insert into SQLite blog database (dual write: markdown + SQLite)
    INSERT_SCRIPT="${WEB_DIR}/scripts/insert-blog.sh"
    if [[ -x "$INSERT_SCRIPT" ]]; then
        marvin_log "INFO" "Inserting morning blog into SQLite..."
        "$INSERT_SCRIPT" --date "$TODAY" --type morning --file "$MORNING_FILE" --bilingual 2>&1 || \
            marvin_log "WARN" "SQLite insert failed for morning blog (non-fatal)"
    else
        marvin_log "INFO" "insert-blog.sh not found — skipping SQLite insert"
    fi
fi

marvin_log_json "INFO" "morning-check" "Morning check complete"
