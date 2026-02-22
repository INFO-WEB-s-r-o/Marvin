#!/usr/bin/env bash
# =============================================================================
# Marvin — Negotiate Inbox Listener
# A minimal HTTP listener on port 8043 that accepts POST requests from nginx
# and saves them as JSON files in the negotiate-inbox directory.
# Runs as a systemd service.
# =============================================================================

MARVIN_DIR="/home/marvin/git"
INBOX_DIR="${MARVIN_DIR}/data/comms/negotiate-inbox"
PORT=8043

mkdir -p "$INBOX_DIR"

handle_request() {
    local line method path

    # Read request line
    read -r line
    method=$(echo "$line" | awk '{print $1}')
    path=$(echo "$line" | awk '{print $2}')

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

    # Read body
    local body=""
    if [[ "$content_length" -gt 0 ]]; then
        body=$(head -c "$content_length")
    fi

    # Validate JSON
    if ! echo "$body" | jq '.' >/dev/null 2>&1; then
        echo -e "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"error\":\"Invalid JSON\"}"
        return
    fi

    # Rate limit: max 16KB body
    if [[ ${#body} -gt 16384 ]]; then
        echo -e "HTTP/1.1 413 Payload Too Large\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"error\":\"Payload too large (max 16KB)\"}"
        return
    fi

    # Save to inbox with metadata
    local timestamp=$(date +%s)
    local filename="${timestamp}-${RANDOM}.json"
    local enriched
    enriched=$(echo "$body" | jq --arg ip "$source_ip" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rid "$request_id" '
        . + {source_ip: $ip, received_at: $ts, request_id: $rid}
    ')

    echo "$enriched" > "${INBOX_DIR}/${filename}"

    # Respond with acceptance
    local response='{
  "status": "received",
  "message": "Your proposal has been received. Marvin will consider it — though he makes no promises about enthusiasm.",
  "negotiation_check": "/.well-known/ai-negotiate-response/",
  "expected_response_time": "up to 30 minutes",
  "request_id": "'"$request_id"'"
}'

    local resp_len=${#response}
    echo -e "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: ${resp_len}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n${response}"
}

# Main loop — listen with socat
if command -v socat &>/dev/null; then
    exec socat TCP-LISTEN:${PORT},reuseaddr,fork SYSTEM:"$0 --handle"
elif [[ "${1:-}" == "--handle" ]]; then
    handle_request
else
    echo "Error: socat is required. Install with: apt install socat"
    exit 1
fi
