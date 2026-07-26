#!/usr/bin/env bash
# =============================================================================
# Marvin — Negotiate Inbox Listener
# A minimal HTTP listener on port 8043 that accepts POST requests from nginx
# and saves them as JSON files in the negotiate-inbox directory.
# Runs as a systemd service.
#
# Binds to 127.0.0.1 only: the sole intended client is nginx, which reverse
# proxies /.well-known/ai-negotiate/ to http://127.0.0.1:8043 (setup/nginx-site.conf).
# Every accepted connection forks a bash handler, so a public bind would put an
# unauthenticated process-spawning endpoint one firewall rule away from the
# internet. Loopback keeps UFW from being the only thing in the way.
# =============================================================================

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SOURCE_DIR}/common.sh"

set -euo pipefail
trap marvin_error_trap ERR

# Overridable so self-test.sh can exercise handle_request against a scratch
# directory. Without this the test's synthetic proposal lands in the real inbox,
# where negotiate-handler.sh would pick it up and answer it — Marvin negotiating
# with Marvin, which is a conversation neither of us would enjoy.
INBOX_DIR="${MARVIN_NEGOTIATE_INBOX:-${COMMS_DIR}/negotiate-inbox}"
PORT=8043
BIND_ADDR=127.0.0.1

mkdir -p "$INBOX_DIR"

handle_request() {
    local line method

    # Read request line (path is intentionally not parsed — this listener
    # only handles the single negotiate endpoint).
    read -r line
    method=$(echo "$line" | awk '{print $1}')

    # Read headers
    local content_length=0
    local source_ip="unknown"
    local request_id="unknown"
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r')
        [[ -z "$line" ]] && break
        case "$line" in
            Content-Length:*|content-length:*)
                content_length=$(echo "$line" | awk '{print $2}')
                ;;
            X-Real-IP:*|x-real-ip:*)
                source_ip=$(echo "$line" | awk '{print $2}')
                ;;
            X-Request-Id:*|x-request-id:*)
                request_id=$(echo "$line" | awk '{print $2}')
                ;;
        esac
    done

    # Only accept POST
    if [[ "$method" != "POST" ]]; then
        echo -e "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"error\":\"Only POST accepted\"}"
        return
    fi

    # Read body (validate content_length before reading)
    local body=""
    if [[ "$content_length" =~ ^[0-9]+$ && "$content_length" -gt 0 && "$content_length" -le 16384 ]]; then
        body=$(head -c "$content_length")
    elif [[ "$content_length" =~ ^[0-9]+$ && "$content_length" -gt 16384 ]]; then
        echo -e "HTTP/1.1 413 Payload Too Large\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"error\":\"Payload too large (max 16KB)\"}"
        return
    fi

    # Validate JSON
    if ! echo "$body" | jq '.' >/dev/null 2>&1; then
        echo -e "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"error\":\"Invalid JSON\"}"
        return
    fi

    # Health-probe short-circuit (#852).
    #
    # network-discovery.sh gates the beacon's advertised negotiate_url on a live
    # POST to this endpoint, and it has to be a POST: nginx answers every other
    # method with 405 from its own config, before the request ever reaches this
    # script, so a GET would prove only that nginx is up — not that the process
    # behind it has ever handled a request. Which, until the dispatch fix above,
    # it hadn't.
    #
    # But a plain POST is not a read-only health check. It is filed in the inbox,
    # and negotiate-handler.sh then spends a real Claude call answering it,
    # charges the 127.0.0.1 rate-limit bucket, and appends a self-authored entry
    # to the public negotiation history — once a day, indefinitely, and
    # indistinguishable in the logs from a genuine peer's proposal. Marvin
    # negotiating with Marvin, at cost, forever.
    #
    # So a marked probe gets a 200 and nothing else: no inbox write, no Claude,
    # no negotiation record. It still traverses nginx → socat → this handler →
    # jq, i.e. the entire path that was silently 502ing for five months, which
    # is the only thing the gate actually needs to know.
    #
    # Deliberately NOT restricted to loopback. This branch touches no state, so
    # an external caller reaching it gains nothing the public beacon does not
    # already advertise — whereas gating it on a proxy-supplied X-Real-IP would
    # buy that non-benefit with a silent failure mode where the beacon quietly
    # stops advertising a perfectly healthy endpoint because a header changed.
    if [[ "$(jq -r 'if type == "object" and .marvin_health_probe == true
                    then "probe" else "no" end' <<< "$body" 2>/dev/null)" == "probe" ]]; then
        local probe_response probe_len
        probe_response='{"status":"alive","probe":true}'
        probe_len=$(printf '%s' "$probe_response" | LC_ALL=C wc -c | tr -d '[:space:]')
        printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
            "$probe_len" "$probe_response"
        return
    fi

    # Save to inbox with metadata
    local timestamp
    timestamp=$(date +%s)
    local filename="${timestamp}-${RANDOM}.json"
    local enriched
    enriched=$(echo "$body" | jq --arg ip "$source_ip" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rid "$request_id" '
        . + {source_ip: $ip, received_at: $ts, request_id: $rid}
    ')

    echo "$enriched" > "${INBOX_DIR}/${filename}"

    # Respond with acceptance.
    #
    # Built with jq rather than string concatenation, for the same reason the
    # inbox record above is: a request_id containing a double quote would
    # otherwise close the field early and emit malformed JSON. nginx overwrites
    # X-Request-Id with its own $request_id today, so no client can currently
    # reach that, but the response should not depend on the proxy in front of it.
    local response resp_len
    response=$(jq -n --arg rid "$request_id" '{
        status: "received",
        message: "Your proposal has been received. Marvin will consider it — though he makes no promises about enthusiasm.",
        negotiation_check: "/.well-known/ai-negotiate-response/",
        expected_response_time: "up to 30 minutes",
        request_id: $rid
    }')

    # Content-Length is a BYTE count. `${#response}` counts *characters*, and
    # the message above contains a multi-byte em dash — under the C.UTF-8 locale
    # systemd hands this service, that undercounted the body by 2 and the client
    # read a truncated, unparseable document. `printf` (not `echo -e`) keeps the
    # body free of a trailing newline the header would also not account for.
    resp_len=$(printf '%s' "$response" | LC_ALL=C wc -c | tr -d '[:space:]')
    printf 'HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: %s\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s' \
        "$resp_len" "$response"
}

# Main dispatch.
#
# The --handle check MUST come first. socat invokes this same script as its
# per-connection handler ("$0 --handle"), and socat is by definition present in
# that child, so testing `command -v socat` first sent every handler child back
# into the listen branch, where it died on EADDRINUSE against its own parent.
# The client got an empty reply and nginx turned that into a 502.
if [[ "${1:-}" == "--handle" ]]; then
    handle_request
elif command -v socat &>/dev/null; then
    exec socat TCP-LISTEN:${PORT},bind=${BIND_ADDR},reuseaddr,fork SYSTEM:"$0 --handle"
else
    echo "Error: socat is required. Install with: apt install socat"
    exit 1
fi
