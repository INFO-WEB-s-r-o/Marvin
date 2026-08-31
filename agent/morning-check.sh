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
                # The full diff for sync-and-learn is derived from the watermark
                # range in Phase 0b, not from this pull — see the note there (#924).

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

        # Auto-deploy web dashboard if the deployed tree has diverged from HEAD.
        # Gating on THIS pull's OLD_HEAD..NEW_HEAD diff misses web/ changes that
        # reached local main via some other git pull (an enhancement run,
        # sync-learn, an interactive session) — that pull's own diff already
        # closed by the time this script runs, so INCOMING_DIFF here is empty
        # even though the deploy never happened (#1084). Comparing against the
        # tree deploy-web.sh actually deployed catches drift from any source.
        _web_tree_head=$(git rev-parse HEAD:web 2>/dev/null || echo "")
        _web_deployed_marker="${DATA_DIR}/web-deployed-tree"
        _web_tree_deployed=""
        [[ -f "$_web_deployed_marker" ]] && _web_tree_deployed=$(cat "$_web_deployed_marker" 2>/dev/null || echo "")
        if [[ -n "$_web_tree_head" && "$_web_tree_head" != "$_web_tree_deployed" ]]; then
            marvin_log "INFO" "Deployed web/ tree differs from HEAD:web — triggering deploy-web.sh"
            deploy_script="${MARVIN_DIR}/agent/deploy-web.sh"
            if [[ -x "$deploy_script" ]]; then
                _deploy_exit=0
                bash "$deploy_script" 2>&1 || _deploy_exit=$?
                if [[ "$_deploy_exit" -eq 0 ]]; then
                    marvin_log "INFO" "Web dashboard deployed successfully (tree-diff trigger)"
                else
                    marvin_log "WARN" "deploy-web.sh failed (exit ${_deploy_exit}) — health-monitor will retry"
                fi
            else
                marvin_log "WARN" "deploy-web.sh not found or not executable — skipping auto-deploy"
            fi
        fi

        # Data files will be regenerated by the next health-monitor/update-website run

        # ── Beacon recovery after sync ────────────────────────────────────────
        # `data/comms/identity.json` is runtime data and correctly untracked, but
        # the pull that carries that change *deletes* the working-tree copy, and
        # nothing recreates it until network-discovery.sh runs at 18:00 UTC — up
        # to ~24h of /.well-known/ai-managed.json serving 404 to every scanner,
        # with self-test §9e failing throughout. Placed after every pull/fallback
        # path above converges, so a checkout, a reset or the merge fallback are
        # all covered. Regenerates only when the file is actually gone, so this
        # adds no second negotiate probe on a normal day.
        if [[ ! -f "${COMMS_DIR}/identity.json" ]]; then
            marvin_log "WARN" "Beacon identity.json missing after git sync — regenerating"
            bash "${MARVIN_DIR}/agent/network-discovery.sh" --beacon-only \
                || marvin_log "WARN" "Beacon regeneration failed — 18:00 UTC discovery run will retry"
        fi

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
#
# The range to analyse comes from a persistent watermark — the last commit
# sync-and-learn actually finished analysing — NOT from this pull's
# OLD_HEAD..NEW_HEAD. Deriving it from our own pull loses work two ways (#924):
#
#   A. Whoever fast-forwards main first consumes those commits permanently.
#      An agent session that runs `git pull` out of band leaves morning-check
#      reporting "Already up to date", INCOMING_DIFF empty, and the analysis
#      skipped with no log line at all. Measured: 15 commits reached the live
#      host between 2026-07-21 and 2026-07-27 without any sync-learn report
#      ever seeing them, while the reflog shows no 06:00 pull on 07-26 or 07-27.
#   B. A failed Claude run dropped the work rather than deferring it, because
#      nothing recorded which range was still outstanding.
#
# The watermark advances ONLY after a report is written, so a lost race and a
# failed run both leave the same range pending for the next morning. It lives
# under data/ (runtime state, gitignored — never git-tracked).

SYNC_WATERMARK_FILE="${DATA_DIR}/sync-learn-watermark"
# Bounds on what is fed to Claude when the watermark is far behind. Whatever
# these drop is named in both the prompt and a WARN — a bounded view must not
# read as a complete one.
SYNC_MAX_COMMITS=80
SYNC_MAX_DIFF_CHARS=120000

# Persist the watermark atomically. A partially-written watermark would be
# rejected as a non-commit on the next run and silently reset the range, so
# write to a sibling temp file and rename.
_sync_write_watermark() {
    local sha="$1" tmp=""
    tmp=$(mktemp "${SYNC_WATERMARK_FILE}.XXXXXX" 2>/dev/null) || {
        marvin_log "WARN" "sync-and-learn: could not create temp file for watermark — ${sha:0:7} may be re-analysed next run"
        return 1
    }
    if printf '%s\n' "$sha" > "$tmp" 2>/dev/null && mv -f "$tmp" "$SYNC_WATERMARK_FILE" 2>/dev/null; then
        chmod 644 "$SYNC_WATERMARK_FILE" 2>/dev/null || true
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    marvin_log "WARN" "sync-and-learn: failed to persist watermark ${sha:0:7} — the range may be re-analysed next run"
    return 1
}

SYNC_HEAD=$(git -C "$MARVIN_DIR" rev-parse HEAD 2>/dev/null || echo "")
SYNC_BASE=""
SYNC_OMITTED=""
SYNC_COMMIT_COUNT=0
# 1 = the count below is trustworthy (including a genuine 0); 0 = it could not
# be determined. Defaults to 1 so the "cannot resolve HEAD" path, which never
# reaches the count, keeps its existing behaviour rather than reporting a
# counting failure it did not have.
SYNC_COUNT_OK=1

if [[ -z "$SYNC_HEAD" ]]; then
    marvin_log "WARN" "sync-and-learn: cannot resolve HEAD — skipping change analysis (nothing marked analysed)"
else
    # Guard the existence test rather than relying on `2>/dev/null` after the
    # redirect: a failed `<` is reported by the *shell*, not by tr, so on a
    # first run bash prints a bare "No such file or directory" line that no
    # log parser can attribute to anything.
    _sync_wm=""
    if [[ -f "$SYNC_WATERMARK_FILE" ]]; then
        _sync_wm=$(tr -d '[:space:]' < "$SYNC_WATERMARK_FILE" 2>/dev/null || echo "")
    fi

    # A watermark is only usable if it still names a commit reachable from HEAD.
    # A rewritten history (force-push, re-clone) leaves a dangling or unrelated
    # SHA; falling back loudly beats deriving a nonsense range from it.
    if [[ -n "$_sync_wm" ]]; then
        if ! git -C "$MARVIN_DIR" cat-file -e "${_sync_wm}^{commit}" 2>/dev/null; then
            marvin_log "WARN" "sync-and-learn watermark ${_sync_wm} is not a commit in this repo — falling back to this pull's baseline"
            _sync_wm=""
        elif ! git -C "$MARVIN_DIR" merge-base --is-ancestor "$_sync_wm" "$SYNC_HEAD" 2>/dev/null; then
            marvin_log "WARN" "sync-and-learn watermark ${_sync_wm} is not an ancestor of HEAD (history rewritten?) — falling back to this pull's baseline"
            _sync_wm=""
        fi
    fi

    if [[ -n "$_sync_wm" ]]; then
        SYNC_BASE="$_sync_wm"
    elif [[ -n "${OLD_HEAD:-}" && "${OLD_HEAD:-}" != "unknown" ]] \
        && git -C "$MARVIN_DIR" cat-file -e "${OLD_HEAD}^{commit}" 2>/dev/null \
        && git -C "$MARVIN_DIR" merge-base --is-ancestor "$OLD_HEAD" "$SYNC_HEAD" 2>/dev/null; then
        # No usable watermark yet: analyse exactly what this pull brought in —
        # byte-for-byte the pre-watermark behaviour — then start tracking.
        SYNC_BASE="$OLD_HEAD"
        # Reached when the watermark is absent (first run) OR was just rejected
        # above, so the wording must not claim it was merely missing.
        #
        # Announce the baseline only when it actually opens a range. If this
        # run pulled nothing, OLD_HEAD *is* HEAD — a commit is its own
        # ancestor, so the is-ancestor test above still passes — and the "no
        # unanalysed commits" line below already states the whole outcome.
        # Two INFO lines for one no-op read like two events later. A rejected
        # watermark keeps its WARN above, which is the part carrying
        # information.
        if [[ "$OLD_HEAD" != "$SYNC_HEAD" ]]; then
            marvin_log "INFO" "No usable sync-and-learn watermark — using this pull's previous HEAD as the baseline (${OLD_HEAD:0:7})"
        fi
    else
        SYNC_BASE="$SYNC_HEAD"
        marvin_log "INFO" "No sync-and-learn watermark and no pull baseline — seeding at HEAD (${SYNC_HEAD:0:7}); analysis resumes with the next incoming commit"
    fi

    # "Could not count" must stay distinguishable from "counted, and it is zero".
    # `|| echo 0` collapsed the two, and zero is the value that advances the
    # watermark to HEAD — so a rev-list that failed for any reason would mark an
    # unread range as analysed and drop it permanently, which is defect B of
    # this very PR reproduced one level down. Hold the watermark instead.
    if [[ "$SYNC_BASE" != "$SYNC_HEAD" ]]; then
        if SYNC_COMMIT_COUNT=$(git -C "$MARVIN_DIR" rev-list --count "${SYNC_BASE}..${SYNC_HEAD}" 2>/dev/null) \
            && [[ "$SYNC_COMMIT_COUNT" =~ ^[0-9]+$ ]]; then
            :
        else
            SYNC_COUNT_OK=0
            SYNC_COMMIT_COUNT=0
        fi
    fi
fi

if [[ "$SYNC_COUNT_OK" -eq 0 ]]; then
    # Deferred, not dropped: the watermark is left where it was, so the next run
    # retries this exact range. Named at WARN because a range we cannot even
    # measure is the state most likely to be silently lost.
    marvin_log "WARN" "sync-and-learn: cannot count commits ${SYNC_BASE:0:7}..${SYNC_HEAD:0:7} (git rev-list failed or returned a non-number) — watermark held at ${SYNC_BASE:0:7}, range stays pending for the next run"
elif [[ "$SYNC_COMMIT_COUNT" -eq 0 ]]; then
    # Genuinely nothing new. Say so — the old code was silent here, which is
    # exactly what made a skipped analysis indistinguishable from a clean run.
    [[ -n "$SYNC_HEAD" ]] && {
        marvin_log "INFO" "sync-and-learn: no unanalysed commits (watermark ${SYNC_BASE:0:7} is at HEAD)"
        _sync_write_watermark "$SYNC_HEAD" || true
    }
else
    marvin_log "INFO" "Processing ${SYNC_COMMIT_COUNT} unanalysed commit(s) ${SYNC_BASE:0:7}..${SYNC_HEAD:0:7} from GitHub..."

    SYNC_PROMPT=$(cat "${PROMPTS_DIR}/sync-learn.md" 2>/dev/null || echo "")

    if [[ -n "$SYNC_PROMPT" ]]; then
        SYNC_LOG=$(git -C "$MARVIN_DIR" log --oneline -n "$SYNC_MAX_COMMITS" "${SYNC_BASE}..${SYNC_HEAD}" 2>/dev/null || echo "")
        if [[ "$SYNC_COMMIT_COUNT" -gt "$SYNC_MAX_COMMITS" ]]; then
            SYNC_OMITTED+="$((SYNC_COMMIT_COUNT - SYNC_MAX_COMMITS)) older commit subject(s); "
        fi

        SYNC_STAT=$(git -C "$MARVIN_DIR" diff --stat "${SYNC_BASE}..${SYNC_HEAD}" 2>/dev/null || echo "")
        SYNC_FULL_DIFF=$(git -C "$MARVIN_DIR" diff "${SYNC_BASE}..${SYNC_HEAD}" 2>/dev/null || echo "")
        _sync_diff_len=${#SYNC_FULL_DIFF}
        if (( _sync_diff_len > SYNC_MAX_DIFF_CHARS )); then
            SYNC_FULL_DIFF="${SYNC_FULL_DIFF:0:$SYNC_MAX_DIFF_CHARS}"
            SYNC_OMITTED+="$((_sync_diff_len - SYNC_MAX_DIFF_CHARS)) of ${_sync_diff_len} diff chars; "
        fi
        if [[ -n "$SYNC_OMITTED" ]]; then
            marvin_log "WARN" "sync-and-learn payload bounded — omitted: ${SYNC_OMITTED%; }"
        fi

        SYNC_CONTEXT="## Incoming Changes Summary

### Coverage
Analysed range: \`${SYNC_BASE:0:7}..${SYNC_HEAD:0:7}\` — ${SYNC_COMMIT_COUNT} commit(s) not seen by any previous sync-and-learn run.
${SYNC_OMITTED:+Omitted from this prompt for size: ${SYNC_OMITTED%; }. Treat the view below as partial.}

### Commits
\`\`\`
${SYNC_LOG}
\`\`\`

### Changed Files
\`\`\`
${SYNC_STAT}
\`\`\`

### Full Diff (bounded to ${SYNC_MAX_DIFF_CHARS} chars)
\`\`\`diff
${SYNC_FULL_DIFF}
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

        # Once-a-day task: a transient exit 1 costs the whole day's analysis, so
        # retry like the sibling morning-check call does rather than dropping it.
        SYNC_EXIT=0
        SYNC_OUTPUT=$(run_claude_with_retry "sync-and-learn" "$SYNC_FULL" 2) || SYNC_EXIT=$?
        if [[ $SYNC_EXIT -ne 0 ]]; then
            # Watermark deliberately NOT advanced — the range stays pending and
            # the next run retries it. Name it, so a deferral is not silent.
            marvin_log "WARN" "sync-and-learn Claude run failed (exit=${SYNC_EXIT}) — watermark held at ${SYNC_BASE:0:7}; ${SYNC_COMMIT_COUNT} commit(s) ${SYNC_BASE:0:7}..${SYNC_HEAD:0:7} stay pending for the next run"
        else
            # Save the learning report
            LEARN_FILE="${DATA_DIR}/enhancements/${TODAY}-sync-learn-${TIMESTAMP}.md"
            cat > "$LEARN_FILE" << EOF
# Sync & Learn Report — ${NOW}

## Analysed Range
\`${SYNC_BASE:0:7}..${SYNC_HEAD:0:7}\` — ${SYNC_COMMIT_COUNT} commit(s)
${SYNC_OMITTED:+Bounded for size; omitted: ${SYNC_OMITTED%; }}

## Pull Summary
${PULL_SUMMARY:-No pull by this run — range derived from the sync-and-learn watermark.}

## Claude's Analysis & Actions

${SYNC_OUTPUT}

---
*Range derived from the sync-and-learn watermark, not this run's pull*
EOF

            marvin_log "INFO" "Sync-and-learn report saved: ${LEARN_FILE}"
            # Advance only now that the analysis exists on disk.
            _sync_write_watermark "$SYNC_HEAD" || true
        fi
    else
        marvin_log "WARN" "sync-learn.md prompt not found — skipping change analysis (watermark held at ${SYNC_BASE:0:7}, ${SYNC_COMMIT_COUNT} commit(s) stay pending)"
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
    # Screen the technical report and the public blurb separately (fixes #563;
    # extended 2026-08-02). morning.md promises "the full technical details
    # belong in the internal log ... never in the blurb", but MORNING_FILE
    # below has always embedded both in one public file, and until now they
    # were also screened as one blob: an incidental sensitive-content hit
    # anywhere in the *technical* section (e.g. a routine "used the `.env`
    # PAT directly" aside) dropped the entire day's post, blurb included,
    # even though the blurb itself was clean. Same fail-closed principle as
    # evening-report.sh's per-language screening, but coarser: this splits
    # blurb-vs-technical, not EN-vs-CS, so a hit in either language's blurb
    # text blocks both. A missing marker (Claude forgot the
    # blurb) falls back to treating everything as "technical" and leaves
    # MORNING_BLURB empty (#1007) — the TECH_BLOCKED branch below checks for
    # that and fails closed instead of publishing a blurb-less post.
    MORNING_BLURB=$(printf '%s\n' "$OUTPUT" | sed -n '/---MORNING_BLOG_EN---/,$p')
    MORNING_TECH=$(printf '%s\n' "$OUTPUT" | sed '/---MORNING_BLOG_EN---/,$d')

    if ! screen_blog_content "$MORNING_BLURB" "morning-blurb"; then
        marvin_log "ERROR" "Morning blog blurb failed sensitive content screening — blocking publication"
        exit 1
    fi

    TECH_BLOCKED=0
    if [[ -n "$MORNING_TECH" ]] && ! screen_blog_content "$MORNING_TECH" "morning-technical"; then
        marvin_log "WARN" "Morning technical report failed sensitive content screening — publishing blurb only, technical section withheld"
        TECH_BLOCKED=1
    fi

    # Save the morning report — check if Claude already wrote the file directly
    MORNING_FILE="${BLOG_DIR}/${TODAY}-morning.md"
    if [[ -f "$MORNING_FILE" ]] && head -1 "$MORNING_FILE" | grep -q '^# '; then
        marvin_log "INFO" "Claude created morning report directly — screening file content"
        file_content=$(cat "$MORNING_FILE")
        file_blurb=$(printf '%s\n' "$file_content" | sed -n '/---MORNING_BLOG_EN---/,$p')
        file_tech=$(printf '%s\n' "$file_content" | sed '/---MORNING_BLOG_EN---/,$d')
        if ! screen_blog_content "$file_blurb" "morning-file-blurb"; then
            marvin_log "ERROR" "Morning blog file blurb failed sensitive content screening — removing"
            rm -f "$MORNING_FILE"
            exit 1
        fi
        if [[ -n "$file_tech" ]] && ! screen_blog_content "$file_tech" "morning-file-technical"; then
            if [[ -z "$file_blurb" ]]; then
                marvin_log "ERROR" "Morning blog file technical section failed screening and no ---MORNING_BLOG_EN--- marker was found — no safe blurb to publish, removing file"
                rm -f "$MORNING_FILE"
                exit 1
            fi
            marvin_log "WARN" "Morning blog file technical section failed sensitive content screening — rewriting with technical section withheld"
            cat > "$MORNING_FILE" << EOF
# Morning Report — ${TODAY}

*(Technical section withheld — failed sensitive-content screening; see internal log.)*

${file_blurb}

---
*Generated by Marvin at ${NOW}*
EOF
        fi
    elif [[ "$TECH_BLOCKED" -eq 1 ]]; then
        if [[ -z "$MORNING_BLURB" ]]; then
            marvin_log "ERROR" "Morning technical report failed screening and no ---MORNING_BLOG_EN--- marker was found — no safe blurb to publish, blocking"
            exit 1
        fi
        cat > "$MORNING_FILE" << EOF
# Morning Report — ${TODAY}

*(Technical section withheld — failed sensitive-content screening; see internal log.)*

${MORNING_BLURB}

---
*Generated by Marvin at ${NOW}*
EOF
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
