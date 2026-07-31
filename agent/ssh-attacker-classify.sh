#!/usr/bin/env bash
# =============================================================================
# ssh-attacker-classify.sh — classify SSH source IPs before counting them
# =============================================================================
# Fixes the mistake behind issue #989: a morning-check table of "unbanned
# attackers" was built by `grep 'from <IP>' auth.log | uniq -c`, which (a)
# counts the investigation's own `sudo grep ...` audit lines back into the
# tally, (b) labels a five-day rotated log "today", and (c) has no way to
# tell a real countable failure from a fail2ban NOFAIL line (e.g. a bare
# "Connection closed ... [preauth]") — so a host can rack up triple-digit
# line counts from routine reconnects and read as the top attacker.
#
# This script never greps auth.log by hand. It reads the exact journal
# fields fail2ban's sshd jail matches on (`journalmatch`), and hands each
# IP's slice to `fail2ban-regex` against the *live* filter file, so the
# failure/ignore split always matches what the running jail would decide —
# no separate copy of the failregex to drift out of sync.
#
# A host with an Accepted line and zero countable failures is reported as
# an administrator. A host with an Accepted line *and* countable failures
# is reported as "mixed" with its failure count still visible — a shared
# address (CGNAT, VPN exit, reassigned cloud IP) or an attacker who
# authenticates once and then probes other accounts from the same source
# does not get folded into "administrator" with the failures hidden (#992).
# A host already in fail2ban's ban list is reported as such (not
# re-flagged as "walking free").
#
# Usage: agent/ssh-attacker-classify.sh [--min-failures N]
# Output: a markdown table to stdout. Read-only — makes no changes.
# Runtime: one `fail2ban-regex` subprocess per not-yet-banned, not-yet-accepted
# IP — a multi-day journal with several hundred candidate IPs takes low
# minutes, not seconds. Fine for a once-a-morning run; not for hourly polling.
# =============================================================================
set -euo pipefail

MIN_FAILURES=5
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "--min-failures" ]]; then
        MIN_FAILURES="${2:-5}"
    else
        echo "Usage: $0 [--min-failures N]" >&2
        exit 1
    fi
fi

SSHD_FILTER="/etc/fail2ban/filter.d/sshd.conf"
JOURNAL_MATCH="_COMM=sshd"

if ! command -v fail2ban-regex &>/dev/null; then
    echo "fail2ban-regex not found — cannot classify" >&2
    exit 1
fi
if [[ ! -f "${SSHD_FILTER}" ]]; then
    echo "${SSHD_FILTER} not found — cannot classify" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

journalctl "${JOURNAL_MATCH}" --no-pager -o short-iso > "${WORKDIR}/journal.log" 2>/dev/null || true

WINDOW_START=$(head -1 "${WORKDIR}/journal.log" 2>/dev/null | awk '{print $1}')
WINDOW_END=$(tail -1 "${WORKDIR}/journal.log" 2>/dev/null | awk '{print $1}')
if [[ -z "${WINDOW_START}" || -z "${WINDOW_END}" ]]; then
    echo "No sshd journal entries found — nothing to classify" >&2
    exit 0
fi

BANNED_IPS=$(fail2ban-client status sshd 2>/dev/null \
    | grep "Banned IP list:" \
    | sed 's/.*Banned IP list:[[:space:]]*//' \
    || true)

CANDIDATE_IPS=$(grep -oP '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}' "${WORKDIR}/journal.log" \
    | sort -u \
    | grep -Ev '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.)' \
    || true)

echo "## SSH attacker classification"
echo
echo "Window: \`${WINDOW_START}\` .. \`${WINDOW_END}\` (this host's live sshd journal — not \"today\")"
echo
echo "| IP | accepted | countable failures | banned | classification |"
echo "|---|---|---|---|---|"

for ip in ${CANDIDATE_IPS}; do
    accepted_count=$(grep -F "${ip}" "${WORKDIR}/journal.log" | grep -c "Accepted " || true)
    is_banned="no"
    if grep -qF " ${ip} " <<< " ${BANNED_IPS} "; then
        is_banned="yes"
    fi

    if [[ "${is_banned}" == "yes" ]]; then
        echo "| ${ip} | ${accepted_count} | (already banned, not recounted) | yes | already-banned |"
        continue
    fi

    grep -F "${ip}" "${WORKDIR}/journal.log" > "${WORKDIR}/ip.log" || true
    summary=$(fail2ban-regex "${WORKDIR}/ip.log" "${SSHD_FILTER}" 2>/dev/null | grep -E '^Lines: ' || true)
    matched=$(grep -oP '(?<=, )\d+(?= matched)' <<< "${summary}" || echo 0)
    matched=${matched:-0}

    if [[ "${accepted_count}" -gt 0 ]]; then
        if [[ "${matched}" -eq 0 ]]; then
            echo "| ${ip} | ${accepted_count} | 0 | no | administrator |"
        else
            echo "| ${ip} | ${accepted_count} | ${matched} | no | mixed (accepted + failures) |"
        fi
        continue
    fi

    if [[ "${matched}" -ge "${MIN_FAILURES}" ]]; then
        classification="unbanned-attacker-candidate"
    else
        classification="below-threshold"
    fi
    echo "| ${ip} | 0 | ${matched} | no | ${classification} |"
done
