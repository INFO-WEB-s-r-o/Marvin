#!/usr/bin/env bash
# =============================================================================
# Marvin — Outbound connection sampling & aggregation (lib)
# =============================================================================
# Why this exists (issue #882):
#
# Outbound connection auditing lived entirely in security-scan.sh §3d, which
# runs once a day at 04:00 local / 02:00 UTC — the deadest minute on this box.
# It took ONE instantaneous `ss` sample and wrote the result as the day's
# answer to "what did this server talk to". It reported zero outbound
# connections on 30 of 31 retained scans. The filtering logic was never
# broken; it was simply never looking. On 2026-07-26, 704 MB left this
# interface (19.5σ above a 21-day mean) and the control designed to attribute
# that traffic had no record of it, and never could have had one.
#
# The fix is to separate the two jobs that §3d was conflating:
#   1. SAMPLING — cheap, frequent, stateful. Runs on the 5-minute
#      health-monitor tick (marvin_outbound_record_sample), appending one
#      JSON line per tick to a per-day JSONL.
#   2. AGGREGATION — once daily, in the security scan
#      (marvin_outbound_day_summary), reading the retained samples.
#
# The aggregate reports two independent things, and never conflates them:
#   - what was observed (destinations, processes, unexpected ports)
#   - whether it actually looked (sample coverage)
# A day with zero samples reports coverage_status "absent", NOT "0 connections,
# clean". "The sampler never ran" and "nothing left the box" are different
# claims and must not collapse into the same output.
# =============================================================================

# Known-safe outbound destination ports.
# 22=SSH, 25/465/587=email relay, 53=DNS, 80/443=HTTP/S, 123=NTP, 11371=keyserver
: "${MARVIN_SAFE_OUTBOUND_PORTS:=22 25 53 80 123 443 465 587 11371}"

# Local ports that mean "this connection is inbound, not outbound".
: "${MARVIN_LOCAL_SERVICE_PORTS:=22 25 80 443 465 587 993 3000 6379 8043 11332 11333 11334}"

# Expected samples for a complete day at one sample per 5 minutes.
: "${MARVIN_OUTBOUND_SAMPLES_PER_DAY:=288}"

# Coverage floor (percent of expected samples) below which a day's aggregate is
# "degraded" — present but too sparse to be relied on for attribution.
: "${MARVIN_OUTBOUND_COVERAGE_FLOOR:=50}"

# Days of per-sample history to retain.
: "${MARVIN_OUTBOUND_RETAIN_DAYS:=30}"

_MARVIN_OUTBOUND_DIR="${SECURITY_DIR:-${DATA_DIR:-/home/marvin/git/data}/security}"

# ─── Docker bridge detection ─────────────────────────────────────────────────
# Container↔container and docker-proxy↔container traffic (Marvin-Brain and the
# monitoring stack talk on 172.18/172.19 to ports like 4317 OTEL-gRPC and 3100
# marvin-brain-mcp) is not outbound in any meaningful sense and must not be
# mislabelled as "unusual" (fixes #591).
#
# Moved here from security-scan.sh so the daily audit and the 5-minute sampler
# share ONE classifier. Two copies of this filter in two files would drift, and
# a sampler that disagrees with the aggregator about what counts as outbound is
# worse than no sampler: the numbers would look authoritative and mean nothing.
#
# Lazily initialised — common.sh is sourced by ~20 agent scripts and
# `docker network inspect` per network is far too expensive to run on every one.
_docker_bridges=""
_MARVIN_BRIDGES_INIT=false

marvin_outbound_bridges_init() {
    [[ "$_MARVIN_BRIDGES_INIT" == "true" ]] && return 0
    _MARVIN_BRIDGES_INIT=true
    if command -v docker &>/dev/null; then
        _docker_bridges=$(docker network ls --format '{{.ID}}' 2>/dev/null \
            | xargs -I{} docker network inspect {} --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
            | tr ' ' '\n' | grep -E '^[0-9]+\.' | sort -u || true)
    fi
    return 0
}

# _ip_in_docker_cidr — is this IP inside any active Docker subnet?
# Uses bitwise arithmetic to support arbitrary prefix lengths (/16, /20, /24).
# Name deliberately unchanged from the security-scan.sh original so existing
# call sites keep working. Self-initialising: returns 1 (not in any subnet) when
# no bridges exist, so callers no longer need a separate emptiness guard.
_ip_in_docker_cidr() {
    marvin_outbound_bridges_init
    local IFS ip="$1" ip_a ip_b ip_c ip_d ip_int
    # Guard: only IPv4. Rejects IPv6, IPv4-mapped IPv6, malformed.
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r ip_a ip_b ip_c ip_d <<< "$ip"
    ip_d=${ip_d:-0}
    ip_int=$(( (ip_a << 24) | (ip_b << 16) | (ip_c << 8) | ip_d ))
    IFS=$' \t\n'   # reset before iterating — IFS='.' from read persists in local scope
    local cidr net mask net_a net_b net_c net_d net_int mask_int
    for cidr in $_docker_bridges; do
        IFS='/' read -r net mask <<< "$cidr"
        [[ "$mask" =~ ^[0-9]+$ && "$mask" -ge 1 && "$mask" -le 32 ]] || continue
        IFS='.' read -r net_a net_b net_c net_d <<< "$net"
        net_d=${net_d:-0}
        net_int=$(( (net_a << 24) | (net_b << 16) | (net_c << 8) | net_d ))
        mask_int=$(( 0xFFFFFFFF << (32 - mask) & 0xFFFFFFFF ))
        [[ $(( ip_int & mask_int )) -eq $(( net_int & mask_int )) ]] && return 0
    done
    return 1
}

# marvin_outbound_is_loopback — loopback in either address family.
# The original §3d matched `127.*|::1|0.0.0.0`, but `ss` prints IPv6 peers in
# bracket form (`[::1]:6379`), so the bare `::1` arm never matched a real line
# and IPv6 loopback traffic was counted as outbound. Costs nothing to get right.
marvin_outbound_is_loopback() {
    case "$1" in
        127.*|::1|0.0.0.0|\[::1\]|\[::ffff:127.*|::ffff:127.*) return 0 ;;
    esac
    return 1
}

# ─── Classification ──────────────────────────────────────────────────────────
# marvin_outbound_classify — read `ss -tnp state established` output on stdin
# (header included) and emit one TSV row per genuinely-outbound connection:
#     remote_ip <TAB> remote_port <TAB> local_port <TAB> process
#
# Filters, in order: skip blank lines, skip inbound (local port is one of ours),
# skip loopback, skip active Docker bridge subnets.
marvin_outbound_classify() {
    local line local_addr remote_addr local_port remote_port remote_ip proc_info proc_name

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Skip the ss header row
        [[ "$line" == State* || "$line" == Recv-Q* ]] && continue

        local_addr=$(awk '{print $3}' <<< "$line")
        remote_addr=$(awk '{print $4}' <<< "$line")
        [[ -z "$remote_addr" ]] && continue

        # Port is everything after the final colon; IP is everything before it.
        # Works for both `1.2.3.4:443` and `[2607:6bc0::10]:443`.
        local_port="${local_addr##*:}"
        remote_port="${remote_addr##*:}"
        remote_ip="${remote_addr%:*}"

        [[ "$local_port" =~ ^[0-9]+$ ]] || continue
        [[ "$remote_port" =~ ^[0-9]+$ ]] || continue

        # Inbound: the local side is a port we serve on.
        if grep -qw "$local_port" <<< "$MARVIN_LOCAL_SERVICE_PORTS" 2>/dev/null; then
            continue
        fi

        marvin_outbound_is_loopback "$remote_ip" && continue
        _ip_in_docker_cidr "$remote_ip" && continue

        proc_info=$(awk '{for(i=5;i<=NF;i++) printf "%s ", $i}' <<< "$line")
        proc_name=$(grep -oP '"\K[^"]+' <<< "$proc_info" 2>/dev/null | head -1 || true)
        [[ -n "$proc_name" ]] || proc_name="unknown"

        printf '%s\t%s\t%s\t%s\n' "$remote_ip" "$remote_port" "$local_port" "$proc_name"
    done
    return 0
}

# marvin_outbound_sample_file — JSONL path for a given day (default: today UTC).
marvin_outbound_sample_file() {
    local day="${1:-$(date -u +%Y-%m-%d)}"
    printf '%s/outbound-samples-%s.jsonl\n' "$_MARVIN_OUTBOUND_DIR" "$day"
}

# ─── Sampling (5-minute tick) ────────────────────────────────────────────────
# marvin_outbound_record_sample — take one sample, append one JSONL record.
#
# Returns 0 on a recorded sample, 1 if the sample could not be taken. Callers
# MUST surface a non-zero return rather than `|| true` it: a sampler that fails
# silently reproduces the exact bug this file exists to fix. When `ss` is
# missing or fails, a record with "error" is still appended, so a broken
# sampler is visible in the history instead of looking like a quiet box.
marvin_outbound_record_sample() {
    local now sample_file tsv rc=0
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sample_file=$(marvin_outbound_sample_file)
    mkdir -p "$_MARVIN_OUTBOUND_DIR" 2>/dev/null || true

    if ! command -v ss &>/dev/null; then
        jq -nc --arg ts "$now" '{ts:$ts,error:"ss-not-found"}' >> "$sample_file" 2>/dev/null || true
        chmod 640 "$sample_file" 2>/dev/null || true
        return 1
    fi

    local raw
    if ! raw=$(ss -tnp state established 2>/dev/null); then
        jq -nc --arg ts "$now" '{ts:$ts,error:"ss-failed"}' >> "$sample_file" 2>/dev/null || true
        chmod 640 "$sample_file" 2>/dev/null || true
        return 1
    fi

    # Classify. An empty result is a legitimate observation (no outbound right
    # now) and is recorded as total 0 — distinct from the error records above.
    tsv=$(marvin_outbound_classify <<< "$raw") || rc=1

    local record
    record=$(printf '%s' "$tsv" | jq -R -s \
        --arg ts "$now" \
        --arg safe "$MARVIN_SAFE_OUTBOUND_PORTS" \
        '
        ($safe | split(" ") | map(select(length > 0) | tonumber)) as $safeports |
        [ split("\n")[] | select(length > 0) | split("\t") |
          {ip: .[0], port: (.[1] | tonumber), local_port: (.[2] | tonumber), process: .[3]} ] as $conns |
        {
          ts: $ts,
          total: ($conns | length),
          unexpected: ($conns | map(select(.port as $p | $safeports | index($p) | not)) | length),
          conns: ($conns | group_by([.ip, .port, .process]) |
                  map({ip: .[0].ip, port: .[0].port, process: .[0].process, count: length}))
        }' 2>/dev/null) || record=""

    if [[ -z "$record" ]]; then
        jq -nc --arg ts "$now" '{ts:$ts,error:"aggregate-failed"}' >> "$sample_file" 2>/dev/null || true
        chmod 640 "$sample_file" 2>/dev/null || true
        return 1
    fi

    printf '%s\n' "$record" >> "$sample_file" || return 1
    # 640, not the 644 the rest of data/security uses: this file is a per-5-minute
    # log of every destination this host contacted. Until the /api/ allowlist in
    # #861 lands, everything under data/ is reachable over HTTP, and an egress
    # history is not something to publish. Deliberately stricter than its peers.
    chmod 640 "$sample_file" 2>/dev/null || true

    marvin_outbound_prune
    return $rc
}

# marvin_outbound_prune — drop sample files older than the retention window.
marvin_outbound_prune() {
    find "$_MARVIN_OUTBOUND_DIR" -maxdepth 1 -name 'outbound-samples-*.jsonl' \
        -type f -mtime "+${MARVIN_OUTBOUND_RETAIN_DAYS}" -delete 2>/dev/null || true
    return 0
}

# ─── Aggregation (daily) ─────────────────────────────────────────────────────
# marvin_outbound_day_summary — aggregate a day's samples to stdout as JSON.
#
# Emits, deliberately separated:
#   samples_recorded / samples_expected / samples_failed / coverage_percent
#   coverage_status  — "ok" | "degraded" | "absent"
#   peak_concurrent / total_observations / distinct_destinations
#   by_destination / by_process / unexpected_destinations
#
# coverage_status is the whole point. "absent" means the sampler produced
# nothing for this day, so every count below it is meaningless rather than
# reassuring, and the caller must report it as no-data — not as clean.
#
# $2 = expected sample count override (for a partial/in-progress day).
marvin_outbound_day_summary() {
    local day="${1:-$(date -u +%Y-%m-%d)}"
    local expected="${2:-$MARVIN_OUTBOUND_SAMPLES_PER_DAY}"
    local sample_file
    sample_file=$(marvin_outbound_sample_file "$day")

    if [[ ! -s "$sample_file" ]]; then
        jq -nc --arg day "$day" --argjson exp "$expected" '{
            day: $day, samples_recorded: 0, samples_expected: $exp,
            samples_failed: 0, coverage_percent: 0, coverage_status: "absent",
            peak_concurrent: null, total_observations: null,
            distinct_destinations: null, by_destination: [], by_process: [],
            unexpected_destinations: []
        }'
        return 0
    fi

    jq -s -c \
        --arg day "$day" \
        --argjson exp "$expected" \
        --argjson floor "$MARVIN_OUTBOUND_COVERAGE_FLOOR" \
        --arg safe "$MARVIN_SAFE_OUTBOUND_PORTS" \
        '
        ($safe | split(" ") | map(select(length > 0) | tonumber)) as $safeports |
        [ .[] | select(.error == null) ] as $ok |
        [ .[] | select(.error != null) ] as $bad |
        ($ok | length) as $n |
        (if $exp > 0 then (($n * 100) / $exp) else 0 end) as $cov |
        [ $ok[] | .conns[]? ] as $all |
        {
          day: $day,
          samples_recorded: $n,
          samples_expected: $exp,
          samples_failed: ($bad | length),
          coverage_percent: ($cov | floor),
          coverage_status: (if $n == 0 then "absent"
                            elif $cov < $floor then "degraded"
                            else "ok" end),
          peak_concurrent: ([ $ok[] | .total ] | max // 0),
          total_observations: ([ $all[] | .count ] | add // 0),
          distinct_destinations: ($all | map(.ip + ":" + (.port | tostring)) | unique | length),
          by_destination: ($all | group_by([.ip, .port]) |
              map({ip: .[0].ip, port: .[0].port,
                   observations: (map(.count) | add),
                   samples_seen_in: length,
                   processes: (map(.process) | unique)}) |
              sort_by(-.observations)),
          by_process: ($all | group_by(.process) |
              map({process: .[0].process, observations: (map(.count) | add),
                   destinations: (map(.ip) | unique | length)}) |
              sort_by(-.observations)),
          unexpected_destinations: ($all | map(select(.port as $p | $safeports | index($p) | not)) |
              group_by([.ip, .port, .process]) |
              map({ip: .[0].ip, port: .[0].port, process: .[0].process,
                   observations: (map(.count) | add)}) |
              sort_by(-.observations))
        }' "$sample_file" 2>/dev/null || {
        # The aggregation itself failed — a corrupt JSONL, a jq error. Report it
        # as a failure, never as an empty-but-fine day.
        jq -nc --arg day "$day" --argjson exp "$expected" '{
            day: $day, samples_recorded: 0, samples_expected: $exp,
            samples_failed: 0, coverage_percent: 0,
            coverage_status: "aggregate-failed",
            peak_concurrent: null, total_observations: null,
            distinct_destinations: null, by_destination: [], by_process: [],
            unexpected_destinations: []
        }'
    }
    return 0
}
