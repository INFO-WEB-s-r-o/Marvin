#!/usr/bin/env bash
# =============================================================================
# Marvin — Weekly Deep Enhancement & Self-Test (runs Sundays at 12:00 UTC)
# =============================================================================
# Once a week, Marvin does a deep review:
#   - Runs self-tests on all scripts
#   - Reads POSSIBLE_ENHANCEMENTS.md and picks tasks to work on
#   - Tests his own infrastructure
#   - Ticks off completed items
#   - Plans next week's focus
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

marvin_log "INFO" "=== WEEKLY DEEP ENHANCEMENT STARTING ==="

check_claude || exit 1

# ==========================================================================
# PHASE 1: Self-Tests (no Claude needed — pure bash validation)
# ==========================================================================

marvin_log "INFO" "--- Phase 1: Self-Tests ---"

TEST_RESULTS=""
TEST_PASS=0
TEST_FAIL=0

# Test 1: All agent scripts have valid bash syntax
for script in "${MARVIN_DIR}"/agent/*.sh; do
    if bash -n "$script" 2>/dev/null; then
        TEST_RESULTS+="✅ PASS: $(basename "$script") — valid syntax\n"
        ((TEST_PASS++))
    else
        TEST_RESULTS+="❌ FAIL: $(basename "$script") — SYNTAX ERROR\n"
        ((TEST_FAIL++))
    fi
done

# Test 2: All required directories exist
for dir in "$LOGS_DIR" "$METRICS_DIR" "$BLOG_DIR" "$COMMS_DIR" "$ENHANCE_DIR"; do
    if [[ -d "$dir" ]]; then
        TEST_RESULTS+="✅ PASS: Directory exists — $dir\n"
        ((TEST_PASS++))
    else
        TEST_RESULTS+="❌ FAIL: Missing directory — $dir\n"
        ((TEST_FAIL++))
    fi
done

# Test 3: Claude CLI is available
if command -v claude &> /dev/null; then
    TEST_RESULTS+="✅ PASS: Claude CLI available\n"
    ((TEST_PASS++))
else
    TEST_RESULTS+="❌ FAIL: Claude CLI not found\n"
    ((TEST_FAIL++))
fi

# Test 4: Critical services running
for service in nginx fail2ban cron sshd; do
    if systemctl is-active "$service" &>/dev/null; then
        TEST_RESULTS+="✅ PASS: Service running — $service\n"
        ((TEST_PASS++))
    else
        TEST_RESULTS+="⚠️ WARN: Service not running — $service\n"
        ((TEST_FAIL++))
    fi
done

# Test 5: Health monitor produces valid JSON
HEALTH_OUTPUT=$("${MARVIN_DIR}/agent/health-monitor.sh" 2>/dev/null) || true
if [[ -f "${METRICS_DIR}/latest.json" ]] && jq empty "${METRICS_DIR}/latest.json" 2>/dev/null; then
    TEST_RESULTS+="✅ PASS: Health monitor produces valid JSON\n"
    ((TEST_PASS++))
else
    TEST_RESULTS+="❌ FAIL: Health monitor JSON invalid or missing\n"
    ((TEST_FAIL++))
fi

# Test 6: Disk usage check
DISK_PERCENT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
if (( DISK_PERCENT < 80 )); then
    TEST_RESULTS+="✅ PASS: Disk usage ${DISK_PERCENT}% (< 80%)\n"
    ((TEST_PASS++))
else
    TEST_RESULTS+="⚠️ WARN: Disk usage ${DISK_PERCENT}% (≥ 80%)\n"
    ((TEST_FAIL++))
fi

# Test 7: Memory check
MEM_AVAILABLE=$(free -m | awk 'NR==2{print $7}')
if (( MEM_AVAILABLE > 200 )); then
    TEST_RESULTS+="✅ PASS: Available memory ${MEM_AVAILABLE}MB (> 200MB)\n"
    ((TEST_PASS++))
else
    TEST_RESULTS+="⚠️ WARN: Low memory — only ${MEM_AVAILABLE}MB available\n"
    ((TEST_FAIL++))
fi

# Test 8: Git repo is clean (no uncommitted changes that should have been synced)
if cd "${MARVIN_DIR}" && git diff --quiet HEAD 2>/dev/null; then
    TEST_RESULTS+="✅ PASS: Git repo is clean\n"
    ((TEST_PASS++))
else
    TEST_RESULTS+="ℹ️ INFO: Git has uncommitted changes (normal between syncs)\n"
    ((TEST_PASS++))
fi

# Test 9: Cron jobs are installed
if [[ -f /etc/cron.d/marvin ]]; then
    CRON_JOBS=$(grep -c "MARVIN" /etc/cron.d/marvin 2>/dev/null || echo "0")
    TEST_RESULTS+="✅ PASS: Cron file exists with ${CRON_JOBS} references\n"
    ((TEST_PASS++))
else
    TEST_RESULTS+="❌ FAIL: /etc/cron.d/marvin missing\n"
    ((TEST_FAIL++))
fi

# Test 10: Website files exist (Next.js dashboard)
if [[ -f "${WEB_DIR}/package.json" ]]; then
    TEST_RESULTS+="✅ PASS: Next.js dashboard exists\n"
    ((TEST_PASS++))
elif [[ -f "${WEB_DIR}/index.html" ]]; then
    TEST_RESULTS+="✅ PASS: Static dashboard exists\n"
    ((TEST_PASS++))
else
    TEST_RESULTS+="❌ FAIL: Dashboard missing — no package.json or index.html\n"
    ((TEST_FAIL++))
fi

# Save test results
TEST_REPORT="${DATA_DIR}/tests/weekly-${TODAY}.md"
mkdir -p "${DATA_DIR}/tests"

cat > "$TEST_REPORT" << EOF
# Weekly Self-Test Report — ${NOW}

## Results: ${TEST_PASS} passed, ${TEST_FAIL} failed

$(echo -e "$TEST_RESULTS")

---
*Automated self-test by Marvin*
EOF

marvin_log "INFO" "Self-tests complete: ${TEST_PASS} passed, ${TEST_FAIL} failed"

# ==========================================================================
# PHASE 2: Read POSSIBLE_ENHANCEMENTS.md and pick tasks
# ==========================================================================

marvin_log "INFO" "--- Phase 2: Enhancement Planning with Claude ---"

# Read the enhancements file
ENHANCEMENTS=""
if [[ -f "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md" ]]; then
    ENHANCEMENTS=$(cat "${MARVIN_DIR}/POSSIBLE_ENHANCEMENTS.md")
fi

# Gather weekly context
WEEK_LOGS=$(find "${LOGS_DIR}" -name "*.log" -mtime -7 -exec tail -20 {} \; 2>/dev/null | tail -100 || echo "No logs found")
WEEK_ENHANCES=$(find "${ENHANCE_DIR}" -name "*.md" -mtime -7 -exec cat {} \; 2>/dev/null | tail -200 || echo "No enhancements this week")
WEEK_ERRORS=$(find "${LOGS_DIR}" -name "*.log" -mtime -7 -exec grep -hi "error\|fail\|critical" {} \; 2>/dev/null | sort -u | tail -30 || echo "No errors this week")

DEEP_PROMPT="# Weekly Deep Enhancement Session — Marvin

You are **Marvin**, autonomous AI sysadmin, data engineer, and network specialist.
Today is your **weekly deep enhancement session**. You have more time and latitude
than your daily sessions.

## Your Roles

1. **System Administrator** — server health, security, maintenance, uptime
2. **Data Engineer** — metrics, analytics, logging pipelines, dashboards
3. **Network Specialist** — connectivity, monitoring, AI-to-AI protocols, security

## Your Tasks Today

### 1. Review Self-Test Results
\`\`\`
$(echo -e "$TEST_RESULTS")
\`\`\`

Fix any failures. If tests pass, consider adding more tests.

### 2. Pick Enhancements from the Roadmap

Here is your enhancement roadmap (POSSIBLE_ENHANCEMENTS.md):

${ENHANCEMENTS}

**Pick 1-3 unchecked items** to work on. Prefer items from the earliest incomplete phase.
When you complete an item, mark it with \`[x]\` and add the date.
Move completed items to the 'Completed Enhancements Log' section at the bottom.

### 3. Review This Week's Performance

Errors this week:
\`\`\`
${WEEK_ERRORS}
\`\`\`

Enhancement attempts this week:
\`\`\`
$(echo "$WEEK_ENHANCES" | head -100)
\`\`\`

### 4. Plan Next Week

Write a brief plan: what should next week's daily enhancement sessions focus on?

## Rules

- Make at most 3 code changes
- Always create a git checkpoint first (the script handles this)
- Update POSSIBLE_ENHANCEMENTS.md to tick off completed items
- Log everything
- Test mentality: if unsure, propose but don't apply
- If you break yourself, there is no one to fix you

## Output Format

\`\`\`markdown
# Weekly Deep Enhancement Report — [date]

## Self-Test Review
[analysis of test results, fixes applied]

## Enhancements Completed
- [ ] or [x] Item — what you did

## Changes Made
- file: description

## Next Week's Plan
[focus areas]

## Marvin's Thoughts
[your philosophical reflection on the week]
\`\`\`
"

# Git checkpoint before any changes
cd "${MARVIN_DIR}"
git stash --include-untracked -m "pre-enhance-weekly-${TIMESTAMP}" 2>/dev/null || true

# Run Claude for deep enhancement
OUTPUT=$(run_claude "weekly-deep-enhance" "$DEEP_PROMPT")

# Save the weekly report
WEEKLY_REPORT="${ENHANCE_DIR}/weekly-${TODAY}.md"
cat > "$WEEKLY_REPORT" << EOF
# Weekly Deep Enhancement — ${NOW}

## Self-Test Summary
- Passed: ${TEST_PASS}
- Failed: ${TEST_FAIL}

## Claude's Enhancement Report

${OUTPUT}

---
*Weekly deep enhancement run ${TIMESTAMP}*
EOF

# Validate that Marvin didn't break himself
VALIDATION_FAILED=0
for script in "${MARVIN_DIR}"/agent/*.sh; do
    if ! bash -n "$script" 2>/dev/null; then
        marvin_log "ERROR" "POST-ENHANCE VALIDATION FAILED: $(basename "$script") has syntax errors!"
        VALIDATION_FAILED=1
    fi
done

if (( VALIDATION_FAILED )); then
    marvin_log "ERROR" "Rolling back — Marvin broke himself during enhancement"
    cd "${MARVIN_DIR}"
    git checkout -- agent/ 2>/dev/null || true
    marvin_log "INFO" "Rollback complete. Enhancement reverted."
else
    marvin_log "INFO" "Post-enhancement validation passed — all scripts OK"
fi

marvin_log "INFO" "Weekly report saved: ${WEEKLY_REPORT}"
marvin_log "INFO" "=== WEEKLY DEEP ENHANCEMENT COMPLETE ==="
