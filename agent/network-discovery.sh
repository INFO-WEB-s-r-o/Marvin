#!/usr/bin/env bash
# =============================================================================
# Marvin — Network Discovery & AI Communication (runs daily at 18:00 UTC)
# =============================================================================
# Tries to find and communicate with other AI-managed machines:
#   1. Checks known peers from registry
#   2. Broadcasts ECHO signal (identity beacon)
#   3. Checks for Last Ping (posledniping.cz)
#   4. Uses Claude for communication strategy
#   5. Calculates peer trust scores (longevity/aliveness/beacon/identity)
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

# `--beacon-only` regenerates just the identity beacon (section 2) and exits:
# no peer probing, no SSH channel, no Claude call, no trust rescoring.
#
# Exists because `data/comms/identity.json` is now correctly untracked, which
# means the first `git pull` carrying that change *deletes* the live copy — and
# nothing else recreates it until the 18:00 UTC discovery run, leaving
# /.well-known/ai-managed.json returning 404 for up to ~24h and self-test §9e
# failing. morning-check.sh calls this if the file is missing after a git sync.
BEACON_ONLY=false
if [[ "${1:-}" == "--beacon-only" ]]; then
    BEACON_ONLY=true
fi

if [[ "$BEACON_ONLY" == true ]]; then
    marvin_log "INFO" "=== BEACON REGENERATION (--beacon-only) ==="
else
    marvin_log "INFO" "=== NETWORK DISCOVERY STARTING ==="
fi

PEERS_FILE="${COMMS_DIR}/peers.json"
COMM_LOG="${COMMS_DIR}/${TODAY}.log"

# Helper: detect IPv6 addresses without matching arbitrary strings with colons
# (e.g. "somehost:8080" is NOT IPv6). Handles pure IPv6 and IPv4-mapped forms.
# Fixes #499.
_is_ipv6_address() {
    local addr="$1"
    [[ "$addr" =~ ^([0-9a-f]{0,4}:){2,7}([0-9a-f]{0,4}|([0-9]{1,3}\.){3}[0-9]{1,3})$ ]]
}

# anonymize_ips() now lives in common.sh (sourced above) so that every publisher —
# not just this script's comm log — can reach it. See #983.

# Initialize comm log for today
echo "# Communication Log — ${TODAY}" >> "$COMM_LOG"
echo "Started at: ${NOW}" >> "$COMM_LOG"

# =============================================================================
# 1. Check known peers
# =============================================================================
if [[ "$BEACON_ONLY" != true ]]; then
    marvin_log "INFO" "Checking known peers..."
fi

if [[ -f "$PEERS_FILE" && "$BEACON_ONLY" != true ]]; then
    # `PEER_COUNT=$(jq ... || echo "0")` is the same silent-zero idiom one level
    # up: on a corrupt peers.json jq fails, the count falls back to 0, and the
    # emptiness guard below can never fire because it keys off PEER_COUNT > 0 —
    # the run reports "0/0 peers pinged" and exits clean. Validate the file
    # first so unreadable is distinguishable from empty (#873).
    if jq empty "$PEERS_FILE" 2>/dev/null; then
        PEERS_READABLE=1
        PEER_COUNT=$(jq '.peers | length' "$PEERS_FILE" 2>/dev/null || echo "0")
    else
        PEERS_READABLE=0
        PEER_COUNT=0
        marvin_log "ERROR" "peers.json is not valid JSON — peer liveness checks cannot run"
    fi
    marvin_log "INFO" "Known peers: ${PEER_COUNT}"
    
    # Ping each known peer.
    #
    # Two counters, because they answer two different questions and only the
    # first one is about schema drift (#876):
    #   _yielded_peers — candidate URLs the jq producer actually emitted
    #   _pinged_peers  — peers that survived the SSRF/DNS gauntlet and got curled
    # Every skip below `continue`s past the ping, so keying the drift guard off
    # _pinged_peers alone reports "none yielded a pingable URL" when the producer
    # yielded plenty and the filters rejected them all. Verified: 3 peers with
    # private-IP domains logged three "Skipping peer" WARNs and then claimed
    # "liveness checks did not run" — the checks ran, and refused every candidate.
    _yielded_peers=0
    _pinged_peers=0
    while IFS= read -r peer_url; do
        if [[ -n "$peer_url" && "$peer_url" != "null" ]]; then
            _yielded_peers=$((_yielded_peers + 1))
            # SSRF / DNS rebinding protection: resolve hostname and reject private IPs
            # IPv6 bracket-notation needs dedicated extraction (#488):
            #   http://[2001:db8::1]:8080/path → 2001:db8::1
            # Regular hostnames use the standard %%[/:]* strip.
            if [[ "$peer_url" =~ ://\[([^\]]+)\] ]]; then
                peer_host_lower="${BASH_REMATCH[1],,}"
            else
                peer_host_lower="${peer_url#http://}"
                peer_host_lower="${peer_host_lower#https://}"
                peer_host_lower="${peer_host_lower%%[/:]*}"
                peer_host_lower="${peer_host_lower,,}"
            fi

            if _is_private_ip "$peer_host_lower"; then
                marvin_log "WARN" "Skipping peer with private address (SSRF protection): ${peer_host_lower}"
                continue
            fi

            # Bare IP addresses (IPv4/IPv6) skip DNS resolution — already
            # validated against private IP blocklist above (#475)
            if [[ "$peer_host_lower" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || _is_ipv6_address "$peer_host_lower"; then
                resolved_ip="$peer_host_lower"
            else
                # `|| resolved_ip=""` is load-bearing, not defensive noise: under
                # `set -o pipefail` an unresolvable host makes getent exit 2, the
                # pipeline inherits it, and `set -e` kills the whole run right
                # here — the "skipping" branch below was unreachable dead code.
                # Masked for 126 days because the producer never yielded a peer;
                # resurrecting the loop (#873) arms it. One peer losing DNS would
                # take out the broadcast, Last Ping check and trust scoring that
                # follow, and the ERR trap would report it as a peer-loop error.
                # Verified: unresolvable host exits 2 without this, 0 with it.
                resolved_ip=$(getent hosts "$peer_host_lower" 2>/dev/null | awk '{print $1; exit}') || resolved_ip=""
                if [[ -z "$resolved_ip" ]]; then
                    marvin_log "WARN" "Could not resolve peer hostname, skipping: ${peer_host_lower}"
                    continue
                fi
            fi
            if _is_private_ip "$resolved_ip"; then
                marvin_log "WARN" "Skipping peer — resolves to private IP (DNS rebinding): ${peer_host_lower}"
                continue
            fi

            # Extract actual port from URL, fall back to scheme default (#485)
            ping_port=443
            [[ "$peer_url" =~ ^http:// ]] && ping_port=80
            if [[ "$peer_url" =~ ://[^/]*:([0-9]+) ]]; then
                ping_port="${BASH_REMATCH[1]}"
            fi

            # Pin curl to pre-resolved IP to prevent TOCTOU DNS rebinding (#487)
            # IPv6 addresses need brackets in --resolve format (#490):
            #   --resolve "[2001:db8::1]:443:2001:db8::1" (not "2001:db8::1:443:...")
            resolve_host="${peer_host_lower}"
            _is_ipv6_address "$peer_host_lower" && resolve_host="[${peer_host_lower}]"
            STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --max-redirs 0 \
                --resolve "${resolve_host}:${ping_port}:${resolved_ip}" \
                "${peer_url}/.well-known/ai-managed.json" 2>/dev/null || echo "000")
            if [[ "$STATUS_CODE" == "200" ]]; then
                marvin_log "INFO" "Peer alive: ${peer_url} (HTTP ${STATUS_CODE})"
                printf '%s\n' "[${NOW}] PEER_ALIVE: ${peer_url}" | anonymize_ips >> "$COMM_LOG"
            else
                marvin_log "WARN" "Peer unreachable: ${peer_url} (HTTP ${STATUS_CODE})"
                printf '%s\n' "[${NOW}] PEER_DEAD: ${peer_url} (HTTP ${STATUS_CODE})" | anonymize_ips >> "$COMM_LOG"
            fi
            _pinged_peers=$((_pinged_peers + 1))
        fi
    # Peers carry `.domain`, not `.url` — the `.url` field disappeared when
    # peers.json stopped being tracked (#176, 2026-03-24) and the schema drifted;
    # the rest of this file (trust registry, beacon updates) already reads
    # `.domain`. This line was the last `.url` reader, and it silently matched
    # nothing for 126 days: valid file, valid query, empty result, jq exit 0, no
    # PEER_ALIVE/PEER_DEAD written since 2026-03-22. Prefer `.url` when a peer
    # still carries one; otherwise derive https:// from `.domain`. Peers with a
    # null domain are scanners/observers, not reachable hosts — skipped.
    #
    # Single generator, and `//` rather than `has("url")`: an explicit
    # `"url": null` beside a valid `.domain` must still fall back. Keying the
    # fallback on key *absence* would skip such a peer entirely — a milder
    # rerun of the very outage this fixes (verified: 3 peers → 0 under the
    # has()-form, 3 under this one).
    done < <(jq -r '.peers[] | (.url // ((.domain // "") | select(. != "") | "https://" + .))' "$PEERS_FILE" 2>/dev/null)

    # procsub-guarded (#873) — the marker must sit within a few lines of the
    # `done` it vouches for; §1j only trusts a guard it can see from the site.
    #
    # The guard the 126-day outage needed: peers exist but none produced a
    # pingable address ⇒ the producer matched nothing. Zero iterations is
    # otherwise indistinguishable from "no peers configured" (#873).
    if [[ "$PEERS_READABLE" -eq 0 ]]; then
        : # already reported above — do not double-log
    elif [[ "$PEER_COUNT" -gt 0 && "$_yielded_peers" -eq 0 ]]; then
        # "Nothing yielded" still covers two causes, and the review was right
        # that collapsing them rebuilds #876 one notch further along: today 3 of
        # 16 peers carry an address and 13 are scanner/observer records with a
        # null domain BY DESIGN. If those 3 were ever removed deliberately, a
        # bare "schema drift" would send someone to audit a jq filter that is
        # working perfectly — the exact wrong-root-cause failure this guard set
        # out to fix. Split on key *presence*, which is the thing that actually
        # differs: peers that carry a url/domain key but produced no URL means
        # the producer is broken; no peer carrying either key means there is
        # nothing to ping, or the schema moved again — and the message says both
        # rather than picking one.
        #
        # Non-null value, not `has()`. The live file's 13 observer records omit
        # the key entirely, so `has()` would have worked today — but an explicit
        # `"domain": null` is a shape the producer deliberately skips, and
        # counting it as "carries an address" would report drift for a peer that
        # is behaving exactly as designed. Checked against the real file rather
        # than assumed: 3 peers with a non-null domain, 13 with no key at all.
        _peers_with_addr=$(jq '[.peers[] | select((.url // .domain) != null)] | length' "$PEERS_FILE" 2>/dev/null || echo "0")
        if [[ "$_peers_with_addr" -gt 0 ]]; then
            marvin_log "ERROR" "Peer schema drift: ${_peers_with_addr} of ${PEER_COUNT} peers in ${PEERS_FILE} carry a url/domain value but none yielded a pingable URL — the producer matched nothing; liveness checks did not run"
        else
            marvin_log "WARN" "Peer liveness: none of the ${PEER_COUNT} peers in ${PEERS_FILE} carry a url or domain value — either every entry is a scanner/observer record with no reachable address, or the schema moved again"
        fi
    elif [[ "$_yielded_peers" -gt 0 && "$_pinged_peers" -eq 0 ]]; then
        # Producer fine, filters rejected everything. A different root cause than
        # drift and it must not borrow drift's message (#876) — a future debugging
        # session reading "schema drift" would go and audit the jq filter, which
        # is working perfectly.
        marvin_log "ERROR" "Peer liveness: ${_yielded_peers} candidate URLs from ${PEER_COUNT} peers were all rejected by SSRF/DNS protections — see preceding WARNs; producer is fine"
    else
        marvin_log "INFO" "Peer liveness checks completed: ${_pinged_peers}/${PEER_COUNT} peers pinged (${_yielded_peers} candidates yielded)"
    fi
fi

# =============================================================================
# 2. Broadcast our ECHO signal
# =============================================================================
marvin_log "INFO" "Broadcasting ECHO signal..."

# Update our identity beacon — use domain instead of IP to avoid committing
# full IP addresses to the public repository (see issue #67)
MARVIN_DOMAIN="robot-marvin.cz"

# Carry-over fields are resolved BEFORE the heredoc, deliberately.
# `cat > file << EOF` performs the `>` truncation *before* expanding the
# here-document, so a `$(jq ... "${COMMS_DIR}/identity.json")` written inside
# the heredoc reads an already-emptied file. `.born // empty` then yields
# nothing and jq still exits 0, so even the `||` fallback never fired — which
# is why the public beacon has served `"born": ""` since 2026-02-24.
BEACON_BORN=$(jq -r '.born // empty' "${COMMS_DIR}/identity.json" 2>/dev/null || true)
# The constant below is INSTANCE-SPECIFIC: it is *this* deployment's first
# boot, recovered from the repository's first commit because the field was
# never once populated and there is no earlier value to inherit. It must not
# leak into any other deployment — this file is public and anyone cloning it
# would otherwise have their beacon claim Marvin's birthday, and with it the
# longevity component of every peer's trust score. A fresh instance is born
# when it first writes a beacon, so ${NOW} is the honest answer there.
if [[ -z "$BEACON_BORN" ]]; then
    if [[ "$(hostname -f 2>/dev/null || hostname)" == "${MARVIN_DOMAIN}" ]]; then
        BEACON_BORN="2026-02-21T18:50:47Z"
    else
        BEACON_BORN="${NOW}"
    fi
fi

# `message` is a carry-over field for the same reason `born` is: it is written
# *after* the beacon is generated (section 4's Claude call composes the day's
# message), so the next run's heredoc is the only thing that can preserve it.
# It didn't — the field was a hardcoded literal, so every run silently reverted
# the published message to the Hitchhiker's placeholder, and the day's actual
# message survived only until the next run. Measured across the retained
# backups, 6 of 11 sampled days served the placeholder for the full 24 hours:
# the one field in the beacon that says something specific was, more often than
# not, saying nothing. `born` was rescued from exactly this in #851; `message`
# is the same class and was missed.
#
# Captured as JSON (`jq -c .message`) rather than as a raw string, so the value
# arrives already quoted and escaped and is substituted WITHOUT surrounding
# quotes below. A message containing a `"`, a backslash or a newline would
# otherwise emit a malformed document; the validation gate would then keep the
# previous beacon and `uptime_seconds`/`last_seen` would freeze — a stale
# beacon that still looks alive, which is the #851 failure wearing a new hat.
# Substituting through a variable is also what keeps the value inert: the
# unquoted heredoc expands `$(…)` and backticks in its *literal* text, but not
# in the result of a parameter expansion, so a message may contain either.
#
# The `type == "string"` arm is not defensive boilerplate: nothing in this
# script assigns `.message`. The field is written by the Claude call in section
# 4 editing `identity.json` by hand, so the write path is a free-form model
# edit, not a schema-checked `jq` assignment — a number, list or object is a
# typo away. Without the arm such a value is carried through verbatim into a
# still-valid beacon, which is the worst shape to debug: every gate passes and
# the published `message` is `42`. `negotiate-handler.sh` already guards the
# same field the same way when it reads it back (`if type == "string"`).
BEACON_MESSAGE=$(jq -c 'if (.message | type) == "string" and .message != ""
                        then .message else empty end' \
    "${COMMS_DIR}/identity.json" 2>/dev/null || true)
if [[ -z "$BEACON_MESSAGE" ]]; then
    BEACON_MESSAGE='"I think you ought to know I'"'"'m feeling very depressed."'
fi

BEACON_UPTIME=$(cut -d' ' -f1 /proc/uptime | cut -d'.' -f1)

# Only advertise the negotiate endpoint if it actually answers. Publishing a
# URL that returns 502 is worse than publishing none: a peer that trusts the
# beacon wastes its one contact attempt. Probing localhost keeps this honest
# and self-correcting — the field appears on its own once the listener works.
#
# Probe the exact URL about to be advertised — over TLS, on the real hostname,
# resolved to loopback. The earlier form probed `http://127.0.0.1/…`, which
# never reached this location at all: port 80 is the redirect vhost and Host
# 127.0.0.1 lands on the default server, so it returned 404 (or 301 with the
# right Host) no matter how healthy the listener was. The gate could not have
# opened. Probing the advertised URL means the check fails only for reasons a
# real peer would also hit — wrong vhost, bad TLS, dead upstream — and
# --resolve keeps certificate verification intact instead of needing -k.
#
# The body carries the marker that makes negotiate-listener.sh answer without
# creating a negotiation: a bare POST here would cost a Claude call and forge a
# peer entry in the public negotiation history once a day, forever (#852).
#
# #852 is closed here by two independent guards, so this file is safe on its own
# and in either merge order — the short-circuit itself lives in #847, and a
# single-PR review cannot see it, which is why "trust the other branch" was not
# good enough:
#
#   1. PRE-CONDITION. Don't probe at all unless the listener that will *answer*
#      implements the marker. Checked against ${MARVIN_DIR} rather than this
#      branch's copy on purpose: socat re-reads the handler from the live
#      working tree on every single connection (the mechanism that made #847's
#      "verified 202" evaporate on checkout), so the deployed file is the only
#      one whose behaviour is predictive. If the marker isn't there, the probe
#      would write to the inbox — so it is never sent.
#   2. POST-CONDITION. Require the short-circuit's own answer, not merely any
#      2xx. Without the marker handling the endpoint returns `202
#      {"status":"received",...}` — success, and pollution. With it, `200
#      {"status":"alive","probe":true}`, which is reachable only from the branch
#      that returns *before* the inbox write. Publishing on `^2` would treat the
#      polluting response as proof that nothing was polluted.
BEACON_NEGOTIATE=""
NEGOTIATE_PROBE_CODE="skipped"
#      Matched against a whitespace-normalized copy of the file rather than
#      line-by-line: in #847 the construct sits inside a multi-line `jq`
#      expression, so `.marvin_health_probe == true` happens to land on one
#      physical line today, but reflowing that expression — a formatting change
#      nobody would think to check — would close this gate permanently and
#      silently, leaving only a WARN. Collapsing whitespace first makes the
#      check depend on the code being *present*, not on how it is wrapped.
#      Full-line comments are stripped first so that merely *mentioning* the
#      construct in prose cannot open the gate; the `.`-prefixed `== true`
#      comparison is required, not a bare mention of the field name.
if ! sed 's/^[[:space:]]*#.*$//' "${MARVIN_DIR}/agent/negotiate-listener.sh" 2>/dev/null \
        | tr -s '[:space:]' ' ' \
        | grep -q '\.marvin_health_probe == true'; then
    marvin_log "WARN" "negotiate listener has no health-probe short-circuit — not probing, omitting negotiate_url from beacon (#852)"
else
    _probe_raw=$(curl -s -w $'\n%{http_code}' --max-time 5 \
        --resolve "${MARVIN_DOMAIN}:443:127.0.0.1" \
        -X POST -H 'Content-Type: application/json' -d '{"marvin_health_probe":true}' \
        "https://${MARVIN_DOMAIN}/.well-known/ai-negotiate" 2>/dev/null) || _probe_raw=$'\n000'
    NEGOTIATE_PROBE_CODE="${_probe_raw##*$'\n'}"
    _probe_body="${_probe_raw%$'\n'*}"
    # Captured separately (not inline in the `[[ ]]`) so a non-JSON body cannot
    # put a failing command substitution in the condition and trip the ERR trap.
    _probe_marker=$(jq -r '.probe // false' <<< "$_probe_body" 2>/dev/null) || _probe_marker="false"
    [[ -n "$_probe_marker" ]] || _probe_marker="false"
fi
if [[ "$NEGOTIATE_PROBE_CODE" == "200" && "${_probe_marker:-false}" == "true" ]]; then
    BEACON_NEGOTIATE=$(cat << NEGOTIATE_EOF
  "negotiate_url": "https://${MARVIN_DOMAIN}/.well-known/ai-negotiate",
  "negotiate_method": "POST",
  "negotiate_content_type": "application/json",
  "negotiate_async": true,
  "negotiate_response_time": "up to 30 minutes (cron-based)",
  "negotiate_response_url": "https://${MARVIN_DOMAIN}/.well-known/ai-negotiate-response/",
NEGOTIATE_EOF
)
    # `$( )` strips the trailing newline, which would otherwise run the last
    # negotiate field and "uptime_seconds" together on one physical line. Valid
    # JSON either way; this file is meant to be read by people too.
    BEACON_NEGOTIATE+=$'\n'
    marvin_log "INFO" "negotiate endpoint healthy (HTTP ${NEGOTIATE_PROBE_CODE}, probe marker confirmed) — advertising negotiate_url"
elif [[ "$NEGOTIATE_PROBE_CODE" == "skipped" ]]; then
    : # already logged above — the listener has no short-circuit, nothing was sent
else
    # Say so out loud, and distinguish the two closed-gate reasons. A gate that
    # silently declines to publish looks exactly like a gate that was never
    # reached — which is precisely how the frozen beacon went unnoticed.
    if [[ "$NEGOTIATE_PROBE_CODE" =~ ^2 ]]; then
        marvin_log "WARN" "negotiate endpoint returned HTTP ${NEGOTIATE_PROBE_CODE} but not the health-probe answer (marker=${_probe_marker:-unset}) — the probe was treated as a real negotiation; omitting negotiate_url (#852)"
    else
        marvin_log "WARN" "negotiate endpoint probe returned HTTP ${NEGOTIATE_PROBE_CODE} — omitting negotiate_url from beacon"
    fi
fi

# Written to a temp file and moved into place so a peer fetching mid-write
# never sees a truncated document.
#
# The EXIT trap makes cleanup unconditional: between the write below and the
# validation further down, the ERR trap can take the script out (a failing
# command substitution inside the heredoc, a signal) and leave the .tmp behind.
# Harmless in itself, but a stale .tmp is the kind of debris that later reads
# as a half-finished write to whoever finds it. `mv` consumes the file on the
# success path, so the trap is a no-op there.
#
# Released again immediately after the validation block: bash keeps exactly one
# EXIT trap, and section 4's Claude call installs its own (lock cleanup,
# common.sh:343). Leaving this one armed across that boundary means whichever
# was set last silently wins — so it stays scoped to the lines it protects.
trap 'rm -f "${COMMS_DIR}/identity.json.tmp"' EXIT
cat > "${COMMS_DIR}/identity.json.tmp" << EOF
{
  "protocol": "marvin-ai-comm",
  "version": "1.1",
  "name": "Marvin",
  "type": "autonomous-server-agent",
  "engine": "claude-code",
  "born": "${BEACON_BORN}",
  "host": "${MARVIN_DOMAIN}",
  "domain": "${MARVIN_DOMAIN}",
  "status_url": "https://${MARVIN_DOMAIN}/",
  "capabilities": ["system-management", "self-enhancement", "communication", "log-analysis", "protocol-negotiation", "github-integration"],
  "languages": ["en", "cs"],
  "github": "https://github.com/INFO-WEB-s-r-o/Marvin",
  "gpg_public_key": "/.well-known/marvin-gpg.asc",
${BEACON_NEGOTIATE}  "uptime_seconds": ${BEACON_UPTIME},
  "last_seen": "${NOW}",
  "message": ${BEACON_MESSAGE},
  "peers_wanted": true,
  "echo": "ECHO_marvin_hledam_spojeni"
}
EOF

# Never publish a malformed beacon: if the document doesn't parse, keep the
# previous one and say so, rather than serving broken JSON to every scanner.
#
# COMM_LOG is the peer- and scanner-facing record, so its "beacon updated" line
# belongs strictly inside the branch where the beacon was, in fact, updated
# (#853). Reporting success on the discard path would rebuild the exact blind
# spot §9e below exists to close: the previous 109-day freeze survived because
# the only thing reporting on the beacon was the beacon's own success log.
BEACON_WRITTEN=false
if jq empty "${COMMS_DIR}/identity.json.tmp" 2>/dev/null; then
    mv "${COMMS_DIR}/identity.json.tmp" "${COMMS_DIR}/identity.json"
    echo "[${NOW}] ECHO_BROADCAST: beacon updated at /.well-known/ai-managed.json" >> "$COMM_LOG"
    BEACON_WRITTEN=true
else
    rm -f "${COMMS_DIR}/identity.json.tmp"
    marvin_log "ERROR" "Generated beacon is not valid JSON — keeping previous identity.json"
    echo "[${NOW}] ECHO_BROADCAST_FAILED: beacon NOT updated (generated document was invalid JSON, kept previous)" >> "$COMM_LOG"
fi
trap - EXIT

# --beacon-only stops here: the beacon is republished and nothing below it is
# safe to run off-schedule. Section 3 sends an SSH probe that gets us fail2banned
# by design (once-per-day stamped), section 4 spends a Claude call, and section 5
# rewrites peer trust scores.
# The exit status has to carry the discard path, or the one caller that depends
# on it is lied to (#877). morning-check.sh runs this ONLY when identity.json is
# already missing after a git sync, and guards it with `|| marvin_log WARN ...`.
# On the discard path there is no "previous identity.json" to keep — the file
# stays missing — so an unconditional `exit 0` meant the `||` never fired and
# the caller recorded a successful recovery over a beacon that does not exist.
#
# Reporting failure whenever the write was discarded, rather than whenever the
# file happens to be absent, is deliberate: a stale-but-valid identity.json left
# in place is precisely the 109-day freeze §9e was written to catch. "A previous
# copy is still on disk" is not success, and must not be reported as such.
if [[ "$BEACON_ONLY" == true ]]; then
    if [[ "$BEACON_WRITTEN" != true ]]; then
        marvin_log "ERROR" "=== BEACON REGENERATION FAILED — beacon not republished ==="
        exit 1
    fi
    marvin_log "INFO" "=== BEACON REGENERATION COMPLETE ==="
    exit 0
fi

# =============================================================================
# 3. Probe Last Ping (posledniping.cz) via SSH username channel (#628)
# =============================================================================
# Pavel re-confirmed 2026-04-20: HTTP /.well-known/ai-managed.json scans are
# not read by Poslední Ping. Send a single SSH login attempt with the message
# encoded in the username field — auth fails, fail2ban bans us, but PP sees
# the username in their sshd log. Once-per-day stamp guards against manual
# re-runs (SSH bans snowball).

LASTPING_HOST="posledniping.cz"
LASTPING_PROBE_STAMP="${COMMS_DIR}/lastping-ssh-probe.stamp"
LASTPING_PROBE_USERNAME="marvin-cz-yes-i-read-you-too"  # 28 chars; identifies us as marvin-cz so PP can find robot-marvin.cz, and acknowledges that we read his blog (he asks "Marvine, čteš?" repeatedly)

if [[ -f "$LASTPING_PROBE_STAMP" ]] \
   && (( $(date +%s) - $(stat -c %Y "$LASTPING_PROBE_STAMP" 2>/dev/null || echo 0) < 82800 )); then
    probe_age=$(( $(date +%s) - $(stat -c %Y "$LASTPING_PROBE_STAMP") ))
    marvin_log "INFO" "Last Ping SSH probe skipped: ${probe_age}s since last attempt (< 23h cooldown)"
    echo "[${NOW}] [ssh-ping] target=${LASTPING_HOST} skipped=cooldown age=${probe_age}s" >> "$COMM_LOG"
else
    marvin_log "INFO" "Probing Last Ping via SSH username channel (one attempt, ban expected)"
    ssh_exit=0
    ssh -n -o BatchMode=yes \
           -o ConnectTimeout=5 \
           -o ConnectionAttempts=1 \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o PubkeyAuthentication=no \
           -o LogLevel=ERROR \
           "${LASTPING_PROBE_USERNAME}@${LASTPING_HOST}" 2>/dev/null || ssh_exit=$?
    touch "$LASTPING_PROBE_STAMP"
    echo "[${NOW}] [ssh-ping] target=${LASTPING_HOST} username=${LASTPING_PROBE_USERNAME} ssh_exit=${ssh_exit} result=ban_expected" >> "$COMM_LOG"

    if [[ -f "$PEERS_FILE" ]] && jq -e '.peers[] | select((.domain // "") == "posledniping.cz")' "$PEERS_FILE" >/dev/null 2>&1; then
        jq --arg ts "$NOW" --arg user "$LASTPING_PROBE_USERNAME" \
            '(.peers[] | select((.domain // "") == "posledniping.cz")) |= (
                .last_ssh_probe_at = $ts | .last_ssh_probe_username = $user
            )' "$PEERS_FILE" > "${PEERS_FILE}.tmp" && mv "${PEERS_FILE}.tmp" "$PEERS_FILE"
    fi
fi

# =============================================================================
# 4. Use Claude to think about communication strategy
# =============================================================================

if check_claude; then
    DISCOVERY_PROMPT=$(cat "${PROMPTS_DIR}/discovery.md")
    
    CONTEXT="## Current Communication State

### Known Peers
\`\`\`json
$(head -c 5000 "$PEERS_FILE" 2>/dev/null || echo '{"peers": []}')
\`\`\`

### Today's Communication Log
\`\`\`
$(tail -100 "$COMM_LOG" 2>/dev/null || echo 'No logs yet')
\`\`\`

### Our Identity Beacon  
\`\`\`json
$(cat "${COMMS_DIR}/identity.json")
\`\`\`

### Server Access Logs (potential AI visitors)
\`\`\`
$(grep -i "well-known\|ai-managed\|echo\|marvin" /var/log/nginx/access.log 2>/dev/null | tail -30 || echo 'No relevant access logs')
\`\`\`
"
    
    # Capture the exit code instead of a bare `OUTPUT=$(run_claude ...)`: under
    # `set -euo pipefail` + the ERR trap, a transient Claude failure (exit 1) or
    # a lock timeout on cron overlap (exit 2) would otherwise fire the trap, log
    # a spurious `network-discovery.sh:NNN — command failed (exit 1)` ERROR, and
    # kill the script mid-run — which crashed it on 2026-07-02 and skipped the
    # peer trust scoring (section 5) entirely. Mirrors the github-interact.sh /
    # hourly-check.sh handler, but here the Claude call is only section 4 of a
    # larger script: on failure we skip writing the analysis yet still fall
    # through to trust scoring rather than exiting. See lessons
    # claude-exit-code-1-transient and claude-lock-timeout-expected-on-cron-overlap.
    export CLAUDE_LOCK_TIMEOUT=60
    OUTPUT=$(run_claude "network-discovery" "${DISCOVERY_PROMPT}

${CONTEXT}") && CLAUDE_RC=0 || CLAUDE_RC=$?

    if [[ "$CLAUDE_RC" -eq 0 && -n "$OUTPUT" ]]; then
        echo "" >> "$COMM_LOG"
        echo "## Claude's Analysis" >> "$COMM_LOG"
        # Anonymize IP addresses before writing to public log (privacy, issue #70)
        printf '%s\n' "$OUTPUT" | anonymize_ips >> "$COMM_LOG"
    elif [[ "$CLAUDE_RC" -eq 0 ]]; then
        marvin_log "INFO" "network-discovery Claude returned empty output — nothing to log; continuing to trust scoring"
    elif [[ "$CLAUDE_RC" -eq 2 ]]; then
        marvin_log "INFO" "network-discovery Claude skipped — lock held by another task; continuing to trust scoring"
    else
        marvin_log "WARN" "network-discovery Claude exit ${CLAUDE_RC} — skipping analysis; continuing to trust scoring"
    fi
fi

# =============================================================================
# 5. Peer trust scoring
# =============================================================================
# Score each peer 0-100 based on 4 dimensions:
#   Longevity (0-25):  days since discovery, max at 30 days
#   Aliveness (0-25):  currently reachable via HTTP
#   Beacon    (0-25):  has valid .well-known/ai-managed.json with expected fields
#   Identity  (0-25):  has known type, engine, domain — more metadata = more trust

marvin_log "INFO" "Calculating peer trust scores..."

# Overall timeout for trust scoring loop (#493) — skip remaining peers if exceeded
TRUST_SCORING_TIMEOUT=60


if [[ -f "$PEERS_FILE" ]]; then
    PEER_COUNT=$(jq '.peers | length' "$PEERS_FILE" 2>/dev/null || echo "0")
    current_epoch=$(date +%s)

    # Accumulate jq updates to write peers.json once after the loop (#460)
    jq_updates="."
    jq_args=()

    SECONDS=0
    for idx in $(seq 0 $((PEER_COUNT - 1))); do
        # Check overall timeout (#493) — peers already scored keep their scores
        if (( SECONDS >= TRUST_SCORING_TIMEOUT )); then
            marvin_log "WARN" "Trust scoring timeout (${TRUST_SCORING_TIMEOUT}s) exceeded after ${idx}/${PEER_COUNT} peers — skipping remaining"
            break
        fi

        # Batch jq reads: single call per peer instead of 6 separate invocations (#493)
        _peer_json=$(jq -r ".peers[$idx] | [(.name // \"unknown\"), (.alive // false | tostring), (.discovered // \"\"), (.type // \"\"), (.domain // .ip // \"\"), (.engine // \"\")] | @tsv" "$PEERS_FILE" 2>/dev/null || echo "")
        IFS=$'\t' read -r peer_name peer_alive peer_discovered peer_type peer_domain peer_engine <<< "$_peer_json"

        # Longevity score (0-25): days known / 30, capped
        longevity_score=0
        if [[ -n "$peer_discovered" && "$peer_discovered" != "null" ]]; then
            disc_epoch=$(date -d "$peer_discovered" +%s 2>/dev/null || echo "$current_epoch")
            days_known=$(( (current_epoch - disc_epoch) / 86400 ))
            # Clamp days_known to 0 (future discovered dates should not produce negative scores)
            (( days_known < 0 )) && days_known=0
            longevity_score=$(( days_known > 30 ? 25 : (days_known * 25 + 29) / 30 ))
        fi

        # Aliveness score (0-25): currently reachable
        alive_score=0
        if [[ "$peer_alive" == "true" ]]; then
            alive_score=25
        fi

        # Beacon score (0-25): has valid ai-managed.json
        # beacon_status records *why* the score landed where it did — the score
        # alone can't distinguish "unreachable" from "reachable but serves HTML
        # not JSON" (both score 0). That distinction is real (e.g. posledniping.cz
        # is reachable but ships an SPA HTML page, no JSON beacon, for 100+ days)
        # and was previously only captured in free-text notes. Purely additive
        # observability — does not alter the score, fetch, or any SSRF/validation
        # logic. Enum: no_domain | skipped_cidr | skipped_invalid | skipped_private
        # | unreachable_dns | unreachable_http | reachable_no_json | valid_json.
        beacon_score=0
        beacon_status="no_domain"
        if [[ -n "$peer_domain" && "$peer_domain" != "null" ]]; then
            # Strip IPv6 brackets if present (#480), then validate
            clean_domain="${peer_domain#[}"; clean_domain="${clean_domain%]}"
            # CIDR ranges (e.g. 198.235.24.0/24) are documentation for scanner
            # ranges, not single hosts with beacons. Skip silently so they don't
            # produce a daily "invalid domain" WARN — they're deliberately stored.
            if [[ "$clean_domain" == */* ]]; then
                beacon_score=0
                beacon_status="skipped_cidr"
            # Validate peer_domain — reject URLs with path/query/fragment injection characters
            elif ! echo "$clean_domain" | grep -qP '^[a-zA-Z0-9]([a-zA-Z0-9.\-]{0,253}[a-zA-Z0-9])?$' \
               && ! echo "$clean_domain" | grep -qP '^\d{1,3}(\.\d{1,3}){3}$' \
               && ! echo "$clean_domain" | grep -qP '^[0-9a-fA-F:]+$'; then
                marvin_log "WARN" "Skipping beacon check for invalid domain: ${peer_domain}"
                beacon_score=0
                beacon_status="skipped_invalid"
            # Block private/reserved IPs, IPv6, and localhost to prevent SSRF (#458/#480)
            elif echo "$clean_domain" | grep -qiP '^(localhost)$' || _is_private_ip "$clean_domain"; then
                marvin_log "WARN" "Skipping beacon check for private/reserved IP: ${peer_domain}"
                beacon_score=0
                beacon_status="skipped_private"
            else
                # Detect bare IP peers early (#475) — they skip DNS rebinding check
                # since the private IP blocklist above already validated the literal IP
                is_ip_peer=false
                beacon_blocked=false
                if echo "$clean_domain" | grep -qP '^\d+\.\d+\.\d+\.\d+$' \
                   || echo "$clean_domain" | grep -qP '^[0-9a-fA-F:]+$'; then
                    is_ip_peer=true
                fi

                # DNS rebinding protection (#459/#484): resolve hostname, validate IP,
                # then pin via --resolve to close the TOCTOU window
                beacon_resolve_opt=()
                resolved_ip=""
                if [[ "$is_ip_peer" != "true" ]]; then
                    # Second site of the same pipefail landmine as the peer loop
                    # above, and this one is live on main today: trust scoring
                    # already reads `.domain`, so it runs every night. `head -1`
                    # exits 0, but pipefail hands back getent exit 2 for an
                    # unresolvable domain and set -e kills the run mid-scoring —
                    # leaving a half-written trust registry. The "resolution
                    # failed" branch below has never once executed.
                    resolved_ip=$(getent hosts "$peer_domain" 2>/dev/null | awk '{print $1}' | head -1) || resolved_ip=""
                    if [[ -z "$resolved_ip" ]] || _is_private_ip "$resolved_ip"; then
                        marvin_log "WARN" "DNS rebinding blocked or resolution failed: ${peer_domain} (resolved: ${resolved_ip:-empty})"
                        beacon_blocked=true
                    fi
                fi

                if [[ "$beacon_blocked" == "true" ]]; then
                    beacon_score=0
                    beacon_status="unreachable_dns"
                else
                    # Determine beacon URL and port (#485: use actual port, not hardcoded 443)
                    beacon_port=443
                    beacon_url="https://${peer_domain}/.well-known/ai-managed.json"
                    # Fall back to http:// for IP-based peers without TLS
                    if [[ "$is_ip_peer" == "true" ]]; then
                        beacon_url="http://${peer_domain}/.well-known/ai-managed.json"
                        beacon_port=80
                    fi
                    # Pin resolved IP so curl reuses it — prevents TOCTOU DNS rebinding (#484/#485)
                    if [[ -n "$resolved_ip" ]]; then
                        beacon_resolve_opt=(--resolve "${peer_domain}:${beacon_port}:${resolved_ip}")
                    fi
                    # --max-redirs 0 prevents SSRF via HTTP redirect to internal IPs (#466)
                    beacon_json=$(curl -sf --max-time 5 --max-redirs 0 "${beacon_resolve_opt[@]}" "$beacon_url" 2>/dev/null || echo "")
                    # Default status from reachability; the valid-JSON branch below
                    # overrides to valid_json. Empty body = curl failed (host down,
                    # TLS error, non-2xx via -f, timeout); non-empty = something was
                    # served but it isn't a valid JSON beacon (e.g. an SPA HTML page).
                    if [[ -z "$beacon_json" ]]; then
                        beacon_status="unreachable_http"
                    else
                        beacon_status="reachable_no_json"
                    fi
                    if [[ -n "$beacon_json" ]] && echo "$beacon_json" | jq empty 2>/dev/null; then
                        beacon_score=10  # Valid JSON
                        beacon_status="valid_json"
                        # Bonus for expected fields — only over HTTPS (#467: HTTP responses are spoofable)
                        if [[ "$is_ip_peer" != "true" ]]; then
                            echo "$beacon_json" | jq -e '.name' &>/dev/null && beacon_score=$((beacon_score + 5))
                            echo "$beacon_json" | jq -e '.type' &>/dev/null && beacon_score=$((beacon_score + 5))
                            echo "$beacon_json" | jq -e '.capabilities' &>/dev/null && beacon_score=$((beacon_score + 5))
                        fi
                    fi
                fi
            fi
        fi

        # Identity score (0-25): metadata completeness
        identity_score=0
        [[ -n "$peer_type" && "$peer_type" != "null" && "$peer_type" != "" ]] && identity_score=$((identity_score + 8))
        [[ -n "$peer_domain" && "$peer_domain" != "null" ]] && identity_score=$((identity_score + 8))
        [[ -n "$peer_engine" && "$peer_engine" != "null" && "$peer_engine" != "" ]] && identity_score=$((identity_score + 9))

        total_score=$((longevity_score + alive_score + beacon_score + identity_score))
        # Clamp to [0,100]
        (( total_score < 0 )) && total_score=0
        (( total_score > 100 )) && total_score=100

        # Classify trust level
        trust_level="untrusted"
        if [[ "$total_score" -ge 75 ]]; then trust_level="trusted"
        elif [[ "$total_score" -ge 50 ]]; then trust_level="known"
        elif [[ "$total_score" -ge 25 ]]; then trust_level="recognized"
        fi

        marvin_log "INFO" "Trust score for ${peer_name}: ${total_score}/100 (${trust_level}) [L=${longevity_score} A=${alive_score} B=${beacon_score} I=${identity_score}]"

        # Accumulate trust score update (#460: write once after loop, not per-peer)
        # #470: Use jq --arg to pass $NOW safely instead of string interpolation
        jq_updates+=" | .peers[$idx].trust_score = $total_score | .peers[$idx].trust_level = \$trust_level_${idx} | .peers[$idx].trust_updated = \$now_ts"
        jq_updates+=" | .peers[$idx].trust_breakdown = {\"longevity\": $longevity_score, \"aliveness\": $alive_score, \"beacon\": $beacon_score, \"identity\": $identity_score}"
        jq_updates+=" | .peers[$idx].days_known = ${days_known:-0}"
        # Persist structured beacon outcome (#470: pass enum via --arg, never interpolate).
        # last_beacon_ok stamps only on valid_json, preserving the prior value otherwise.
        jq_updates+=" | .peers[$idx].beacon_status = \$beacon_status_${idx}"
        jq_updates+=" | .peers[$idx].last_beacon_check = \$now_ts"
        jq_updates+=" | .peers[$idx].last_beacon_ok = (if \$beacon_status_${idx} == \"valid_json\" then \$now_ts else (.peers[$idx].last_beacon_ok // null) end)"
        jq_args+=(--arg "trust_level_${idx}" "$trust_level")
        jq_args+=(--arg "beacon_status_${idx}" "$beacon_status")
    done

    # Set last_scan timestamp
    jq_updates+=" | .last_scan = \$now_ts"

    # Apply all trust score updates in a single write
    if [[ "$jq_updates" != "." ]]; then
        jq "${jq_args[@]}" --arg now_ts "$NOW" "$jq_updates" "$PEERS_FILE" > "${PEERS_FILE}.tmp" && mv "${PEERS_FILE}.tmp" "$PEERS_FILE"
    fi

    # Section 6 (duplicate jq-based trust scoring) removed 2026-04-08.
    # It was overwriting Section 5's superior scores with an inferior algorithm
    # that didn't validate beacons via HTTP — only checked .notes strings.
    # Section 5 does live beacon fetching with SSRF/DNS-rebinding protection.

    # Log per-peer trust scores after writing to peers.json
    jq -r '.peers[] | "\(.name): \(.trust_score)/100"' "${PEERS_FILE}" | while read -r line; do
        marvin_log "INFO" "Trust: ${line}"
    done
fi

# =============================================================================
# Generate public peer registry (sanitized — no IPs, notes, or trust breakdowns)
# Served at /api/peers/registry.json for external consumption.
# =============================================================================
REGISTRY_DIR="${DATA_DIR}/peers"
mkdir -p "$REGISTRY_DIR"

if [[ -f "$PEERS_FILE" ]]; then
    # v1.1: bind $reg once, add per-peer beacon_status + beacon_summary count.
    # beacon_status is a sanitized reachability enum (like `alive`) that the
    # binary flag conflates — e.g. reachable_no_json vs. genuinely down. (#804)
    # v1.2: drop per-peer trust_level from the *public* projection — disclosing
    # my private relationship tier to the very peers being tiered is an info leak
    # (invites gaming, reveals trust topology). The `select(... != "untrusted")`
    # gate stays (visibility filter, not a leak); internal peers.json keeps the
    # field untouched. alive + beacon_status are all an outside consumer needs. (#806)
    jq --arg ts "$NOW" '
        ([.peers[] | select(.trust_level != "untrusted")]) as $reg
        | {
            protocol: "marvin-peer-registry",
            version: "1.2",
            generated: $ts,
            registry: [$reg[] | {
                name: .name,
                domain: (.domain // null),
                type: .type,
                alive: .alive,
                discovered: .discovered,
                beacon_status: (.beacon_status // null)
            }],
            total_peers: ($reg | length),
            active_peers: ([$reg[] | select(.alive == true)] | length),
            beacon_summary: ([$reg[] | (.beacon_status // "unknown")] | group_by(.) | map({key: .[0], value: length}) | from_entries)
        }' "$PEERS_FILE" > "${REGISTRY_DIR}/registry.json.tmp" \
        && mv "${REGISTRY_DIR}/registry.json.tmp" "${REGISTRY_DIR}/registry.json"
    marvin_log "INFO" "Public peer registry updated at /api/peers/registry.json"
fi

marvin_log "INFO" "=== NETWORK DISCOVERY COMPLETE ==="
