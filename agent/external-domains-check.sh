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

_http_check() {
    # Echoes: "<http_code> <time_total_ms>"
    local url="$1"
    local out code rt_s rt_ms
    out=$(curl -so /dev/null -w '%{http_code} %{time_total}' \
              --max-time 15 -L "$url" 2>/dev/null) || out="000 0"
    [[ -z "$out" ]] && out="000 0"
    code="${out%% *}"
    rt_s="${out##* }"
    rt_ms=$(awk -v t="$rt_s" 'BEGIN{printf "%.0f", t * 1000}' 2>/dev/null) || rt_ms="0"
    echo "$code $rt_ms"
}

_ssl_days() {
    local host="$1" port="${2:-443}"
    local expiry_date expiry_epoch now_epoch
    expiry_date=$(echo \
        | timeout 10 openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null \
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
    local host="$1" ip
    if ! command -v dig &>/dev/null; then
        echo "skipped"
        return
    fi
    ip=$(dig +short +time=3 +tries=1 "$host" A @8.8.8.8 2>/dev/null | tail -1)
    if [[ -n "$ip" ]]; then
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
        else
            http_pair=$(_http_check "$url")
            http_code="${http_pair%% *}"
            http_ms="${http_pair##* }"
            echo "$now_epoch" > "$stamp_file"
        fi
    fi
    if jq -e --arg c ssl 'index($c)' <<<"$checks" >/dev/null; then
        ssl_days=$(_ssl_days "$host")
    fi
    if jq -e --arg c dns 'index($c)' <<<"$checks" >/dev/null; then
        dns_status=$(_dns_resolves "$host")
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
        '{
            id: $id,
            name: $name,
            host: $host,
            url: $url,
            status: $st,
            http_code: (if $http == "null" then null else ($http | tonumber) end),
            response_ms: (if $ms == "null" then null else ($ms | tonumber) end),
            ssl_days: (if $ssl == "null" or $ssl == "skipped" then null else ($ssl | tonumber) end),
            dns: $dns
        }' >> "$results_jsonl"
done

# Aggregate output ---------------------------------------------------------
mkdir -p "$(dirname "$OUT_FILE")"
tmp="${OUT_FILE}.tmp"
jq -s --arg ts "$NOW" '{timestamp: $ts, count: length, domains: .}' "$results_jsonl" \
    > "$tmp" && mv "$tmp" "$OUT_FILE"

marvin_log_json "INFO" "external-domains-check" "External domain monitor complete" \
    "$(jq -nc --argjson n "$domain_count" '{checked: $n}')"
