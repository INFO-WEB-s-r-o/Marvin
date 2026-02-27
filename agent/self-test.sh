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

# ─── 1b. Merge conflict marker check ─────────────────────────────────────────
# Detects leftover <<<<<<< / ======= / >>>>>>> markers that break scripts

marvin_log "INFO" "Self-test: checking for merge conflict markers"

while IFS= read -r script; do
    if grep -qE '^<{7} |^={7}$|^>{7} ' "$script" 2>/dev/null; then
        test_fail "merge conflict markers: $(basename "$script")"
    else
        test_pass "no conflict markers: $(basename "$script")"
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
    if ! command -v jq >/dev/null 2>&1; then
        test_warn "jq not installed; skipping metric threshold checks"
    else
        disk_pct_raw=$(jq -r '.metrics.disk.percent // "0%"' "${DATA_DIR}/status.json" 2>/dev/null || true)
        disk_pct=$(printf '%s' "$disk_pct_raw" | tr -d '%')
        mem_avail=$(jq -r '.metrics.memory.available // 0' "${DATA_DIR}/status.json" 2>/dev/null || true)

        if ! [[ "$disk_pct" =~ ^[0-9]+$ ]]; then
            test_warn "disk usage metric missing or invalid in status.json"
        else
            if [[ "$disk_pct" -lt 80 ]]; then
                test_pass "disk usage ${disk_pct}% (< 80%)"
            elif [[ "$disk_pct" -lt 95 ]]; then
                test_warn "disk usage ${disk_pct}% (warning threshold)"
            else
                test_fail "disk usage ${disk_pct}% (critical!)"
            fi
        fi

        if ! [[ "$mem_avail" =~ ^[0-9]+$ ]]; then
            test_warn "memory available metric missing or invalid in status.json"
        else
            if [[ "$mem_avail" -gt 200 ]]; then
                test_pass "memory available ${mem_avail}MB (> 200MB)"
            else
                test_warn "memory available ${mem_avail}MB (low)"
            fi
        fi
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

if [[ -f "${WEB_DIR}/package.json" ]]; then
    test_pass "Next.js dashboard exists"
elif [[ -f "${WEB_DIR}/index.html" ]]; then
    test_pass "static dashboard exists"
else
    test_fail "dashboard missing — no package.json or index.html"
fi

# ─── 8. Git repo health ──────────────────────────────────────────────────────

if git -C "${MARVIN_DIR}" status --porcelain >/dev/null 2>&1; then
    test_pass "git repository accessible"
elif [[ -d "${MARVIN_DIR}/.git" ]]; then
    test_pass "git directory exists (possible safe.directory restriction)"
else
    test_fail "git repository inaccessible"
fi

# ─── 9. Security scoring system ───────────────────────────────────────────────
# Grades the server A-F across multiple security dimensions

marvin_log "INFO" "Self-test: computing security score"

SEC_SCORE=100
SEC_DETAILS=()

# 9a. SSH root access (rkhunter flags this as a warning)
if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null; then
    SEC_DETAILS+=("ssh_root_login: disabled (+0)")
elif grep -q "^PermitRootLogin prohibit-password" /etc/ssh/sshd_config 2>/dev/null; then
    SEC_DETAILS+=("ssh_root_login: key-only (-5)")
    SEC_SCORE=$((SEC_SCORE - 5))
else
    SEC_DETAILS+=("ssh_root_login: allowed (-15)")
    SEC_SCORE=$((SEC_SCORE - 15))
fi

# 9b. Firewall active
if ufw status 2>/dev/null | grep -q "Status: active"; then
    SEC_DETAILS+=("firewall: active (+0)")
else
    SEC_DETAILS+=("firewall: inactive (-20)")
    SEC_SCORE=$((SEC_SCORE - 20))
fi

# 9c. Fail2ban running with jails
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    jail_count=$(fail2ban-client status 2>/dev/null | grep -oP 'Number of jail:\s+\K\d+' || echo 0)
    if [[ "$jail_count" -ge 2 ]]; then
        SEC_DETAILS+=("fail2ban: ${jail_count} jails active (+0)")
    else
        SEC_DETAILS+=("fail2ban: only ${jail_count} jail (-5)")
        SEC_SCORE=$((SEC_SCORE - 5))
    fi
else
    SEC_DETAILS+=("fail2ban: not running (-15)")
    SEC_SCORE=$((SEC_SCORE - 15))
fi

# 9d. SSL certificates valid
cert_days=0
if [[ -f /etc/letsencrypt/live/robot-marvin.cz/fullchain.pem ]]; then
    cert_expiry=$(openssl x509 -enddate -noout -in /etc/letsencrypt/live/robot-marvin.cz/fullchain.pem 2>/dev/null | cut -d= -f2)
    if [[ -n "$cert_expiry" ]]; then
        cert_epoch=$(date -d "$cert_expiry" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        cert_days=$(( (cert_epoch - now_epoch) / 86400 ))
    fi
fi
if [[ "$cert_days" -gt 30 ]]; then
    SEC_DETAILS+=("ssl_cert: valid ${cert_days}d (+0)")
elif [[ "$cert_days" -gt 7 ]]; then
    SEC_DETAILS+=("ssl_cert: expiring in ${cert_days}d (-5)")
    SEC_SCORE=$((SEC_SCORE - 5))
elif [[ "$cert_days" -gt 0 ]]; then
    SEC_DETAILS+=("ssl_cert: critical — ${cert_days}d left (-15)")
    SEC_SCORE=$((SEC_SCORE - 15))
else
    SEC_DETAILS+=("ssl_cert: expired or missing (-25)")
    SEC_SCORE=$((SEC_SCORE - 25))
fi

# 9e. Unattended upgrades enabled
if dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
    SEC_DETAILS+=("unattended_upgrades: enabled (+0)")
else
    SEC_DETAILS+=("unattended_upgrades: missing (-10)")
    SEC_SCORE=$((SEC_SCORE - 10))
fi

# 9f. Security scan results (from security-scan.sh)
LATEST_SCAN="${DATA_DIR}/security/latest-scan.json"
if [[ -f "$LATEST_SCAN" ]]; then
    scan_status=$(jq -r '.overall_status // "unknown"' "$LATEST_SCAN" 2>/dev/null)
    scan_infected=$(($(jq -r '.rkhunter.infected // 0' "$LATEST_SCAN" 2>/dev/null) + $(jq -r '.chkrootkit.infected // 0' "$LATEST_SCAN" 2>/dev/null)))
    world_writable=$(jq -r '.file_integrity.world_writable_count // 0' "$LATEST_SCAN" 2>/dev/null)

    if [[ "$scan_infected" -gt 0 ]]; then
        SEC_DETAILS+=("rootkit_scan: INFECTED (-40)")
        SEC_SCORE=$((SEC_SCORE - 40))
    elif [[ "$scan_status" == "warnings" ]]; then
        SEC_DETAILS+=("rootkit_scan: warnings (-5)")
        SEC_SCORE=$((SEC_SCORE - 5))
    else
        SEC_DETAILS+=("rootkit_scan: clean (+0)")
    fi

    if [[ "$world_writable" -gt 0 ]]; then
        SEC_DETAILS+=("world_writable_files: ${world_writable} (-5)")
        SEC_SCORE=$((SEC_SCORE - 5))
    else
        SEC_DETAILS+=("world_writable_files: none (+0)")
    fi
else
    SEC_DETAILS+=("rootkit_scan: no data (-10)")
    SEC_SCORE=$((SEC_SCORE - 10))
fi

# 9g. Password authentication disabled for SSH
if grep -qE "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
    SEC_DETAILS+=("ssh_password_auth: disabled (+0)")
else
    SEC_DETAILS+=("ssh_password_auth: enabled (-10)")
    SEC_SCORE=$((SEC_SCORE - 10))
fi

# Clamp score to 0-100
[[ "$SEC_SCORE" -lt 0 ]] && SEC_SCORE=0

# Grade
if [[ "$SEC_SCORE" -ge 90 ]]; then
    SEC_GRADE="A"
elif [[ "$SEC_SCORE" -ge 80 ]]; then
    SEC_GRADE="B"
elif [[ "$SEC_SCORE" -ge 65 ]]; then
    SEC_GRADE="C"
elif [[ "$SEC_SCORE" -ge 50 ]]; then
    SEC_GRADE="D"
else
    SEC_GRADE="F"
fi

test_pass "security score: ${SEC_SCORE}/100 (grade ${SEC_GRADE})"

# Write security score JSON
SECURITY_DIR="${DATA_DIR}/security"
mkdir -p "$SECURITY_DIR"
{
    echo "{"
    echo "  \"timestamp\": \"${NOW}\","
    echo "  \"score\": ${SEC_SCORE},"
    echo "  \"grade\": \"${SEC_GRADE}\","
    echo "  \"details\": ["
    local_first=true
    for detail in "${SEC_DETAILS[@]}"; do
        if [[ "$local_first" == "true" ]]; then
            local_first=false
        else
            echo ","
        fi
        printf '    "%s"' "$(echo "$detail" | sed 's/"/\\"/g')"
    done
    echo ""
    echo "  ]"
    echo "}"
} > "${SECURITY_DIR}/security-score.json"
chmod 644 "${SECURITY_DIR}/security-score.json"

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
echo " Security Score: ${SEC_SCORE}/100 (Grade: ${SEC_GRADE})"
echo "═══════════════════════════════════════════"

# Save report as JSON
cat > "${DATA_DIR}/self-test.json" << EOF
{
  "timestamp": "${NOW}",
  "total": ${TOTAL},
  "pass": ${PASS},
  "fail": ${FAIL},
  "warn": ${WARN},
  "grade": "$(if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then echo "A"; elif [[ $FAIL -eq 0 ]]; then echo "B"; elif [[ $FAIL -lt 3 ]]; then echo "C"; else echo "F"; fi)",
  "security_score": ${SEC_SCORE},
  "security_grade": "${SEC_GRADE}"
}
EOF

marvin_log "INFO" "Self-test complete: ${PASS} pass, ${FAIL} fail, ${WARN} warn | Security: ${SEC_GRADE} (${SEC_SCORE}/100)"

# Exit with failure if any test failed
[[ "$FAIL" -eq 0 ]]
