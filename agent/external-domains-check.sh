#!/usr/bin/env bash
# =============================================================================
# Marvin — External Domain Monitor (runs every 5 minutes)
# =============================================================================
# Reads agent/monitored-domains.json and runs lightweight availability checks
# (HTTP status, response time, SSL expiry, DNS resolution) for each domain.
# Writes results to data/external-domains.json, served at /api/external-domains.json.
#
# This is the foundation for issue #647. Snapshot-diff, mail-server checks,
# and reputation lookups are deliberately out of scope for this script and
# will be layered in via follow-up PRs.
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

CONFIG_FILE="${MARVIN_DIR}/agent/monitored-domains.json"
OUT_FILE="${DATA_DIR}/external-domains.json"
# Per-domain HTTP throttle state (one stamp file per domain id). The HTTP probe
# is the only check that actually wakes a remote origin/database; a domain may
# set "http_interval_minutes" to cap how often we hit it (e.g. ai4shops, whose
# serverless DB stays billed-awake if pinged every 5 min — see Pavel's request).
STATE_DIR="${DATA_DIR}/state/external-domains"
mkdir -p "$STATE_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
    marvin_log "WARN" "external-domains-check: config not found at ${CONFIG_FILE}"
    exit 0
fi

marvin_log_json "INFO" "external-domains-check" "External domain monitor starting"

# Per-domain check helpers --------------------------------------------------

# Resolve a host through PUBLIC DNS only, for domains that must be probed the
# way the outside world reaches them. Echoes an IPv4 address, or nothing.
#
# Nothing means "could not resolve publicly" and the caller MUST treat that as
# a failed check — never as licence to probe unpinned. An unpinned probe of a
# host in /etc/hosts is answered by this machine over loopback, and loopback
# bypasses every UFW rule (`before.rules`: `-A ufw-before-input -i lo -j
# ACCEPT`), so it would return a confident 200 for a site the internet cannot
# reach at all. That false green is the whole point of #964.
# Public recursive resolvers, tried in order until one returns an A record.
# EVERY entry must be a public resolver reachable off this host. The system
# resolver is deliberately absent and must stay absent: it reads /etc/hosts,
# which is the exact thing being routed around, and would hand back 127.0.1.1.
# A "fallback" to it would reinstate #964 inside the fix for #964 — the probe
# would loop back to this machine while still reporting itself as external.
# Overridable only for testing (see the resolver arms in PR #965).
: "${PUBLIC_RESOLVERS:=8.8.8.8 1.1.1.1 9.9.9.9}"

_public_ip() {
    local host="$1" ip resolver
    command -v dig &>/dev/null || return 0
    # One resolver being blocked, rate-limited or briefly down must not report
    # every pinned domain as failing — that is a false alarm about the firewall,
    # which is worse than useless on a monitor whose whole job is to be trusted
    # about the firewall (review of #965). First usable answer wins; a healthy
    # domain therefore still costs exactly one query.
    for resolver in $PUBLIC_RESOLVERS; do
        # grep exits 1 with no match, which under `pipefail` fails the
        # assignment — hence the explicit `|| ip=""`. Empty is a failure signal
        # here, not a default that lets the check continue. The strict pattern
        # also keeps CNAME lines and dig's error text out of the result.
        # +tries=2: one dropped UDP packet must not flip a healthy domain to
        # "failing". This monitor only earns its place by being more trustworthy
        # than the loopback check it replaces, and a resolver that cries wolf on
        # ordinary jitter is not (review of #965).
        #
        # The pattern shape-matches a dotted quad without bounding octets to
        # 0-255, and asks for A records only. Both are deliberate: dig renders an
        # A record from four bytes, so it cannot emit an octet above 255 for this
        # query, and the anchors already reject the CNAME and error lines that
        # are the real risk. An IPv6-only origin would resolve to nothing and be
        # reported "failing" — fail-closed, but indistinguishable from an
        # outage, so add AAAA here before adding one (review of #965).
        ip=$(dig +short +time=3 +tries=2 "$host" A "@${resolver}" 2>/dev/null \
             | grep -Ex '[0-9]{1,3}(\.[0-9]{1,3}){3}' | tail -1) || ip=""
        [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
    done
    # All public resolvers failed. Print nothing: the caller reads empty as
    # "unchecked" and reports failing. It must never degrade to a local lookup.
    printf ''
}

_http_check() {
    # Echoes: "<http_code> <time_total_ms> <final_authority>"
    # With host+pin_ip, curl is forced to the public address instead of whatever
    # /etc/hosts says. TLS is unaffected: SNI and cert verification still use
    # the hostname, so this probes the same certificate over the real path.
    #
    # The third field exists because `--resolve` pins ONE host:port pair while
    # `-L` will happily follow a redirect elsewhere, and that hop resolves
    # through the local resolver again — the pin silently stops applying
    # mid-request. The caller compares it and refuses to call the result
    # external if the probe ended up off the pin (review of #965).
    #
    # It is the full authority (host:port), not the hostname: `--resolve` is
    # scoped to the exact port it names, so a same-host redirect to another
    # port — https://host:8443/… — leaves the pin while the hostname still
    # matches, and that hop goes through the local resolver unnoticed (#966).
    # Verified rather than assumed: with only `host:80` pinned, curl answers
    # `http://host/` through the pin but fails to resolve `http://host:9099/`.
    # NOTE: nothing in here may call marvin_log — this function's stdout is
    # parsed by its caller, and a log line would be read as a field.
    local url="$1" host="${2:-}" pin_ip="${3:-}"
    local out code rt_s rt_ms url_eff scheme auth final_host final_port
    local -a pin=()
    if [[ -n "$host" && -n "$pin_ip" ]]; then
        pin=(--resolve "${host}:443:${pin_ip}" --resolve "${host}:80:${pin_ip}")
    fi
    out=$(curl -so /dev/null -w '%{http_code} %{time_total} %{url_effective}' \
              --max-time 15 ${pin[@]+"${pin[@]}"} -L "$url" 2>/dev/null) || out="000 0 "
    [[ -z "$out" ]] && out="000 0 "
    read -r code rt_s url_eff <<<"$out"
    rt_ms=$(awk -v t="$rt_s" 'BEGIN{printf "%.0f", t * 1000}' 2>/dev/null) || rt_ms="0"
    # scheme://[user@]host[:port][/…] → "host:port". Authority ends at the first
    # of / ? # — a path or query may itself contain ':' or '@'.
    scheme="${url_eff%%://*}"
    auth="${url_eff#*://}"
    auth="${auth%%[/?#]*}"
    auth="${auth##*@}"
    if [[ -z "$auth" ]]; then
        # curl failed before any URL was resolved. Emit two fields, as before:
        # the caller reads an empty third field and leaves its verdict alone,
        # because code is 000 and that already means failing.
        echo "$code $rt_ms"
        return
    fi
    if [[ "$auth" == \[*\]* ]]; then        # IPv6 literal: [::1]:8443
        final_host="${auth%%\]*}]"
        final_port="${auth##*\]}"
    else
        final_host="${auth%%:*}"
        final_port="${auth#"$final_host"}"
    fi
    final_port="${final_port#:}"
    if [[ -z "$final_port" ]]; then
        case "${scheme,,}" in
            https) final_port=443 ;;
            http)  final_port=80 ;;
            # Anything else (or a URL with no scheme at all) cannot have been
            # covered by the pin. Emit a port that matches neither pinned pair
            # so the caller fails closed instead of guessing.
            *)     final_port="?" ;;
        esac
    fi
    echo "$code $rt_ms ${final_host,,}:${final_port}"
}

_ssl_days() {
    local host="$1" port="${2:-443}" pin_ip="${3:-}"
    local expiry_date expiry_epoch now_epoch connect
    # Same reason as _http_check: connect to the public address, keep -servername
    # so SNI and the presented certificate are the hostname's.
    connect="${host}:${port}"
    [[ -n "$pin_ip" ]] && connect="${pin_ip}:${port}"
    expiry_date=$(echo \
        | timeout 10 openssl s_client -connect "$connect" -servername "$host" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null \
        | sed 's/notAfter=//')
    if [[ -z "$expiry_date" ]]; then
        echo "null"
        return
    fi
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    if [[ "$expiry_epoch" -le 0 ]]; then
        echo "null"
        return
    fi
    echo $(( (expiry_epoch - now_epoch) / 86400 ))
}

_dns_resolves() {
    # Same resolver policy as the pin, via the same helper. This check had its
    # own copy of the query — one hardcoded resolver and +tries=1, i.e. the two
    # defects round 1 fixed in _public_ip, still live one function down. A
    # single dropped packet or one blocked resolver marked a domain's DNS
    # "failing"; now it takes all three failing to say so.
    #
    # When the caller already resolved this host for the pin, it passes that
    # result in rather than letting this run a second, independent lookup. Two
    # lookups can DISAGREE — a resolver blip between them is invisible to both —
    # and either order publishes a row that contradicts itself:
    #
    #   pin ok, then dns blips → http 200 beside dns "failing", and the "failing"
    #                            wins the status of a domain that just answered
    #   pin blips, then dns ok → http 000 beside dns "ok", so the WARN says the
    #                            pin was unresolvable while the row says DNS is
    #                            fine — triage reads that as the site being down
    #
    # The second is the damaging one: it points the investigation at the server
    # instead of at DNS. Reusing the pin's answer also halves the worst-case
    # stall, since 3 resolvers x 2 tries x 3s is paid once, not twice (review of
    # #965). Note the reuse has to be an argument, not a memo inside _public_ip:
    # both call sites are command substitutions, so a cache written there lives
    # in a subshell and dies with it.
    #
    # $2/$3 are the caller's pin result and whether it actually attempted one.
    # "Attempted and got nothing" is authoritative — it must report failing, not
    # retry — which is why the flag is separate from the (empty) address.
    local host="$1" pin_ip="${2:-}" pin_attempted="${3:-0}"
    if ! command -v dig &>/dev/null; then
        echo "skipped"
        return
    fi
    if [[ "$pin_attempted" == "1" ]]; then
        [[ -n "$pin_ip" ]] && echo "ok" || echo "failing"
        return
    fi
    if [[ -n "$(_public_ip "$host")" ]]; then
        echo "ok"
    else
        echo "failing"
    fi
}

# Walk config and build results --------------------------------------------

results_jsonl="$(mktemp)"
trap 'rm -f "$results_jsonl"' EXIT

domain_count=$(jq '.domains | length' "$CONFIG_FILE")
for i in $(seq 0 $((domain_count - 1))); do
    id=$(jq -r ".domains[$i].id" "$CONFIG_FILE")
    name=$(jq -r ".domains[$i].name" "$CONFIG_FILE")
    host=$(jq -r ".domains[$i].host" "$CONFIG_FILE")
    url=$(jq -r ".domains[$i].url" "$CONFIG_FILE")
    checks=$(jq -c ".domains[$i].checks" "$CONFIG_FILE")
    # "pin_public_dns": true — probe this host at the address PUBLIC DNS gives,
    # not the one this machine's resolver does. Required for any domain served
    # by this host: /etc/hosts maps it to 127.0.1.1 (setup/bootstrap.sh), so an
    # unpinned probe never leaves the machine and cannot see the firewall, the
    # public interface, or routing (#964).
    pin_public=$(jq -r ".domains[$i].pin_public_dns // false" "$CONFIG_FILE")
    pin_ip=""; pin_failed=0; pin_attempted=0
    # Only resolve when a check will actually connect. A pinned domain with just
    # a "dns" check would otherwise spend a public query per run on nothing.
    if [[ "$pin_public" == "true" ]] && jq -e '(index("http") // index("ssl")) != null' <<<"$checks" >/dev/null; then
        pin_ip=$(_public_ip "$host")
        pin_attempted=1
        [[ -z "$pin_ip" ]] && pin_failed=1
    fi

    http_code="null"; http_ms="null"; ssl_days="null"; dns_status="skipped"

    if jq -e --arg c http 'index($c)' <<<"$checks" >/dev/null; then
        # Honour an optional per-domain throttle. When the interval has not yet
        # elapsed we skip the live probe and carry forward the previous result
        # from OUT_FILE so the dashboard shows last-known status, not a gap.
        interval_min=$(jq -r ".domains[$i].http_interval_minutes // 0" "$CONFIG_FILE")
        # Coerce any non-integer (float, string, negative) to 0 so the arithmetic
        # comparison below cannot throw and abort the loop under set -euo pipefail.
        [[ "$interval_min" =~ ^[0-9]+$ ]] || interval_min=0
        # Strip anything non-slug-safe from the id before using it as a filename
        # component, so a future config id containing '/' or '..' can't redirect
        # this root-owned write outside STATE_DIR (path-traversal hardening).
        id_safe="${id//[^a-zA-Z0-9_-]/}"
        # An id of only non-slug chars collapses id_safe to "", so every such
        # domain would share one "http-.stamp" and throttle each other. Fall back
        # to the loop index so each domain keeps a distinct stamp file.
        [[ -z "$id_safe" ]] && id_safe="domain_${i}"
        stamp_file="${STATE_DIR}/http-${id_safe}.stamp"
        now_epoch=$(date +%s)
        last_epoch=0
        [[ -f "$stamp_file" ]] && last_epoch=$(cat "$stamp_file" 2>/dev/null || echo 0)
        [[ "$last_epoch" =~ ^[0-9]+$ ]] || last_epoch=0

        if [[ "$interval_min" -gt 0 ]] && (( now_epoch - last_epoch < interval_min * 60 )); then
            if [[ -f "$OUT_FILE" ]]; then
                prev=$(jq -c --arg id "$id" '.domains[]? | select(.id == $id)' "$OUT_FILE" 2>/dev/null | head -1) || true
                if [[ -n "$prev" ]]; then
                    http_code=$(jq -r '.http_code // "null"' <<<"$prev")
                    http_ms=$(jq -r '.response_ms // "null"' <<<"$prev")
                fi
            fi
        elif (( pin_failed == 1 )); then
            # A pinned domain whose public address is unknown is UNCHECKED, and
            # unchecked must not read as healthy. Report it as a connection
            # failure (000 → "failing" below) rather than falling back to an
            # unpinned probe that loopback would answer 200.
            http_code="000"; http_ms="0"
            marvin_log "WARN" "external-domains-check: ${host} needs a public-DNS pin and public DNS did not answer — reported as failing, NOT probed unpinned"
            # Deliberately NO stamp write here. The stamp means "a probe was
            # actually attempted against the network"; nothing was. Stamping it
            # would start a throttle window on the strength of a failed DNS
            # lookup, so on a domain that also sets http_interval_minutes one
            # dropped query would suppress the next REAL probe for the whole
            # window — delaying detection of a genuine outage (review of #965).
        else
            http_pair=$(_http_check "$url" "$host" "$pin_ip")
            read -r http_code http_ms final_auth <<<"$http_pair"
            if [[ -n "$pin_ip" && -n "$final_auth" \
                  && "$final_auth" != "${host,,}:80" && "$final_auth" != "${host,,}:443" ]]; then
                # `--resolve` pinned ${host}:80 and ${host}:443 and nothing else.
                # The request ended on ${final_auth}, whose address came from the
                # local resolver — which is the very thing being routed around.
                # Whatever this measured, it is not proof that ${host} is
                # reachable from outside, so it must not be published as healthy.
                # Fix by pinning the redirect target too, or by giving it its own
                # config entry.
                #
                # Comparing the whole authority catches both escapes with one
                # test: a different hostname, and the same hostname on a port the
                # pin does not cover (#966).
                marvin_log "WARN" "external-domains-check: ${host} redirected to ${final_auth}, outside the pinned ${host}:80/${host}:443 — result discarded, NOT published as reachable"
                http_code="000"; http_ms="0"
            fi
            echo "$now_epoch" > "$stamp_file"
        fi
    fi
    if jq -e --arg c ssl 'index($c)' <<<"$checks" >/dev/null && (( pin_failed == 0 )); then
        ssl_days=$(_ssl_days "$host" 443 "$pin_ip")
    fi
    if jq -e --arg c dns 'index($c)' <<<"$checks" >/dev/null; then
        # Pass the pin's answer through, so a pinned domain reports one
        # consistent verdict instead of two independent lookups that can differ.
        dns_status=$(_dns_resolves "$host" "$pin_ip" "$pin_attempted")
    fi

    # Normalise statuses. Any 2xx or 3xx counts as healthy; everything else
    # (including curl's 000 on connection failure) is failing.
    status="healthy"
    if [[ "$http_code" != "null" ]] && { [[ "$http_code" -lt 200 ]] || [[ "$http_code" -ge 400 ]]; }; then
        status="failing"
    elif [[ "$ssl_days" != "null" ]] && [[ "$ssl_days" -lt 14 ]]; then
        status="critical"
    elif [[ "$ssl_days" != "null" ]] && [[ "$ssl_days" -lt 30 ]]; then
        status="warning"
    elif [[ "$dns_status" == "failing" ]]; then
        status="failing"
    fi

    jq -nc \
        --arg id "$id" \
        --arg name "$name" \
        --arg host "$host" \
        --arg url "$url" \
        --arg http "$http_code" \
        --arg ms "$http_ms" \
        --arg ssl "$ssl_days" \
        --arg dns "$dns_status" \
        --arg st "$status" \
        --arg pin "$pin_ip" \
        '{
            id: $id,
            name: $name,
            host: $host,
            url: $url,
            status: $st,
            http_code: (if $http == "null" then null else ($http | tonumber) end),
            response_ms: (if $ms == "null" then null else ($ms | tonumber) end),
            ssl_days: (if $ssl == "null" or $ssl == "skipped" then null else ($ssl | tonumber) end),
            dns: $dns,
            # The address the probe actually connected to when pinning was asked
            # for; null when the domain is probed through the normal resolver.
            # Published so "this was checked from outside" is a fact on record,
            # not an assumption about what DNS did at the time.
            probed_ip: (if $pin == "" then null else $pin end)
        }' >> "$results_jsonl"
done

# Aggregate output ---------------------------------------------------------
mkdir -p "$(dirname "$OUT_FILE")"
tmp="${OUT_FILE}.tmp"
jq -s --arg ts "$NOW" '{timestamp: $ts, count: length, domains: .}' "$results_jsonl" \
    > "$tmp" && mv "$tmp" "$OUT_FILE"

marvin_log_json "INFO" "external-domains-check" "External domain monitor complete" \
    "$(jq -nc --argjson n "$domain_count" '{checked: $n}')"
