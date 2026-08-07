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
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

MIN_FAILURES=5
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "--min-failures" ]]; then
        MIN_FAILURES="${2:-5}"
    else
        marvin_log "ERROR" "ssh-attacker-classify.sh: usage: $0 [--min-failures N]"
        exit 1
    fi
fi

SSHD_FILTER="/etc/fail2ban/filter.d/sshd.conf"
JOURNAL_MATCH="_COMM=sshd"

if ! command -v fail2ban-regex &>/dev/null; then
    marvin_log "ERROR" "ssh-attacker-classify.sh: fail2ban-regex not found — cannot classify"
    exit 1
fi
if [[ ! -f "${SSHD_FILTER}" ]]; then
    marvin_log "ERROR" "ssh-attacker-classify.sh: ${SSHD_FILTER} not found — cannot classify"
    exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

journalctl "${JOURNAL_MATCH}" --no-pager -o short-iso > "${WORKDIR}/journal.log" 2>/dev/null || true

WINDOW_START=$(head -1 "${WORKDIR}/journal.log" 2>/dev/null | awk '{print $1}')
WINDOW_END=$(tail -1 "${WORKDIR}/journal.log" 2>/dev/null | awk '{print $1}')
if [[ -z "${WINDOW_START}" || -z "${WINDOW_END}" ]]; then
    marvin_log "WARN" "ssh-attacker-classify.sh: no sshd journal entries found — nothing to classify"
    exit 0
fi

BANNED_IPS=$(fail2ban-client status sshd 2>/dev/null \
    | grep "Banned IP list:" \
    | sed 's/.*Banned IP list:[[:space:]]*//' \
    || true)

# Private/reserved candidates are excluded via common.sh's _is_private_ip
# rather than a second hand-copied regex, so the two can't drift out of
# sync (#994).
#
# IPv6 sources are extracted too (#1001) — sshd logs the address exactly as
# getnameinfo() rendered it, so RFC 5952 canonical forms (leading/trailing/
# mid-address "::", or the full 8-group form) cover what actually appears.
# The alternation requires either a literal "::" or all 7 colons, which is
# what keeps it from matching a bare "HH:MM:SS" journal timestamp — a
# timestamp has exactly 2 single colons and no "::".
IPV6_RE='([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|::(ffff(:0{1,4})?:)?((25[0-5]|(2[0-4]|1?[0-9])?[0-9])\.){3}(25[0-5]|(2[0-4]|1?[0-9])?[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1?[0-9])?[0-9])\.){3}(25[0-5]|(2[0-4]|1?[0-9])?[0-9])'
_ALL_IPS=$( { grep -oP '(?<![0-9a-fA-F:.])\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}' "${WORKDIR}/journal.log" || true
              grep -oP "(?<![0-9a-fA-F:.])(?:${IPV6_RE})(?![0-9a-fA-F:.])" "${WORKDIR}/journal.log" || true
            } | sort -u)
CANDIDATE_IPS=""
for ip in ${_ALL_IPS}; do
    # An IPv4-mapped IPv6 address (::ffff:a.b.c.d) is checked by its
    # embedded IPv4 octets, not the whole string — _is_private_ip's
    # blanket `^::ffff:` match is a conservative default for its SSRF-guard
    # callers (log-export.sh, network-discovery.sh, export-push.sh) and
    # would otherwise drop every mapped attacker here regardless of whether
    # the embedded address is actually public (#1020). The candidate stays
    # in its original ::ffff: form so it still matches the log text below —
    # only the privacy check operates on the extracted plain form.
    _ip_for_privacy_check="${ip}"
    if [[ "${ip,,}" =~ ^::ffff:([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})$ ]]; then
        _ip_for_privacy_check="${BASH_REMATCH[1]}"
    fi
    _is_private_ip "${_ip_for_privacy_check}" || CANDIDATE_IPS+="${ip} "
done

echo "## SSH attacker classification"
echo
echo "Window: \`${WINDOW_START}\` .. \`${WINDOW_END}\` (this host's live sshd journal — not \"today\")"
echo
echo "| IP | accepted | countable failures | banned | classification |"
echo "|---|---|---|---|---|"

for ip in ${CANDIDATE_IPS}; do
    # Anchored so a shorter IP can't match as a substring of a longer one
    # (#1000) — e.g. unanchored "5.6.7.8" also matches "15.6.7.8" and
    # "5.6.7.80". No character that can extend an IPv4 or IPv6 literal
    # (hex digit, colon, dot) is allowed on either side of the match.
    ip_anchored="(?<![0-9a-fA-F:.])${ip//./\.}(?![0-9a-fA-F:.])"
    accepted_count=$(grep -P "${ip_anchored}" "${WORKDIR}/journal.log" | grep -c "Accepted " || true)
    is_banned="no"
    if grep -qF " ${ip} " <<< " ${BANNED_IPS} "; then
        is_banned="yes"
    fi

    if [[ "${is_banned}" == "yes" ]]; then
        echo "| ${ip} | ${accepted_count} | (already banned, not recounted) | yes | already-banned |"
        continue
    fi

    grep -P "${ip_anchored}" "${WORKDIR}/journal.log" > "${WORKDIR}/ip.log" || true
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
