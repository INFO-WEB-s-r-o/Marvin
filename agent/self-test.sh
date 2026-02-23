#!/usr/bin/env bash
# =============================================================================
# Marvin — Self-Test Suite
# =============================================================================
# Validates that all agent scripts and data files are healthy.
# Can run standalone or be called by weekly-enhance.sh.
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

PASS=0
FAIL=0
WARN=0
RESULTS=()

# ─── Test helpers ─────────────────────────────────────────────────────────────

test_pass() {
    PASS=$((PASS + 1))
    RESULTS+=("  PASS: $1")
}

test_fail() {
    FAIL=$((FAIL + 1))
    RESULTS+=("  FAIL: $1")
}

test_warn() {
    WARN=$((WARN + 1))
    RESULTS+=("  WARN: $1")
}

# ─── 1. Bash syntax check for all agent scripts ──────────────────────────────

marvin_log "INFO" "Self-test: checking bash script syntax"

while IFS= read -r script; do
    if bash -n "$script" 2>/dev/null; then
        test_pass "syntax ok: $(basename "$script")"
    else
        test_fail "syntax error: $(basename "$script")"
    fi
done < <(find "${MARVIN_DIR}/agent" -name "*.sh" -type f | sort)

# ─── 2. JSON data file validation ────────────────────────────────────────────

marvin_log "INFO" "Self-test: validating JSON data files"

for json_file in "${DATA_DIR}/status.json" \
                 "${DATA_DIR}/uptime.json" \
                 "${DATA_DIR}/blog-index.json" \
                 "${DATA_DIR}/about.json" \
                 "${DATA_DIR}/comms-summary.json" \
                 "${DATA_DIR}/metrics-history.json" \
                 "${COMMS_DIR}/identity.json" \
                 "${COMMS_DIR}/incoming-signals.json" \
                 "${COMMS_DIR}/peers.json"; do
    if [[ ! -f "$json_file" ]]; then
        test_warn "missing: $(basename "$json_file")"
        continue
    fi
    if jq empty "$json_file" 2>/dev/null; then
        test_pass "valid json: $(basename "$json_file")"
    else
        test_fail "invalid json: $(basename "$json_file")"
    fi
done

# ─── 3. Critical service checks ──────────────────────────────────────────────

marvin_log "INFO" "Self-test: checking critical services"

for service in nginx fail2ban cron ssh; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        test_pass "service running: $service"
    else
        test_fail "service down: $service"
    fi
done

# ─── 4. Metric assertion tests ───────────────────────────────────────────────

marvin_log "INFO" "Self-test: checking metric thresholds"

if [[ -f "${DATA_DIR}/status.json" ]]; then
    disk_pct=$(jq -r '.metrics.disk.percent // "0%"' "${DATA_DIR}/status.json" 2>/dev/null | tr -d '%')
    mem_avail=$(jq -r '.metrics.memory.available // 0' "${DATA_DIR}/status.json" 2>/dev/null)

    if [[ "$disk_pct" -lt 80 ]]; then
        test_pass "disk usage ${disk_pct}% (< 80%)"
    elif [[ "$disk_pct" -lt 95 ]]; then
        test_warn "disk usage ${disk_pct}% (warning threshold)"
    else
        test_fail "disk usage ${disk_pct}% (critical!)"
    fi

    if [[ "$mem_avail" -gt 200 ]]; then
        test_pass "memory available ${mem_avail}MB (> 200MB)"
    else
        test_warn "memory available ${mem_avail}MB (low)"
    fi
fi

# ─── 5. health-monitor.sh produces valid JSON ────────────────────────────────

marvin_log "INFO" "Self-test: verifying collect_metrics output"

metrics_output=$(collect_metrics 2>/dev/null || echo "")
if [[ -n "$metrics_output" ]] && echo "$metrics_output" | jq empty 2>/dev/null; then
    test_pass "collect_metrics produces valid JSON"
else
    test_fail "collect_metrics output is not valid JSON"
fi

# ─── 6. Claude CLI availability ──────────────────────────────────────────────

if command -v claude &>/dev/null; then
    test_pass "claude CLI found in PATH"
else
    test_fail "claude CLI not found"
fi

# ─── 7. Web dashboard exists ─────────────────────────────────────────────────

if [[ -f "${WEB_DIR}/index.html" ]]; then
    test_pass "index.html exists"
else
    test_fail "index.html missing — dashboard broken"
fi

# ─── 8. Git repo health ──────────────────────────────────────────────────────

if git -C "${MARVIN_DIR}" status --porcelain 2>/dev/null; then
    test_pass "git repository accessible"
elif git -C "${MARVIN_DIR}" rev-parse --git-dir &>/dev/null; then
    test_pass "git repository exists (safe.directory restriction)"
elif [[ -d "${MARVIN_DIR}/.git" ]]; then
    test_pass "git directory exists"
else
    test_fail "git repository inaccessible"
fi

# ─── Report ───────────────────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL + WARN))

echo ""
echo "═══════════════════════════════════════════"
echo " Marvin Self-Test Report — ${NOW}"
echo "═══════════════════════════════════════════"
echo ""
for r in "${RESULTS[@]}"; do
    echo "$r"
done
echo ""
echo "───────────────────────────────────────────"
echo " Total: ${TOTAL} | Pass: ${PASS} | Fail: ${FAIL} | Warn: ${WARN}"
echo "═══════════════════════════════════════════"

# Save report as JSON
cat > "${DATA_DIR}/self-test.json" << EOF
{
  "timestamp": "${NOW}",
  "total": ${TOTAL},
  "pass": ${PASS},
  "fail": ${FAIL},
  "warn": ${WARN},
  "grade": "$(if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then echo "A"; elif [[ $FAIL -eq 0 ]]; then echo "B"; elif [[ $FAIL -lt 3 ]]; then echo "C"; else echo "F"; fi)"
}
EOF

marvin_log "INFO" "Self-test complete: ${PASS} pass, ${FAIL} fail, ${WARN} warn"

# Exit with failure if any test failed
[[ "$FAIL" -eq 0 ]]
