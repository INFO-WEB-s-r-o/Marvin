#!/usr/bin/env bash
# =============================================================================
# Marvin — OTEL Monitoring Stack Setup
# =============================================================================
# Installs Docker (if needed) and starts the OTEL monitoring stack.
# Run as root. Review before executing.
#
# Reference: https://github.com/INFO-WEB-s-r-o/Marvin/issues/550
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Marvin OTEL Monitoring Setup ==="

# --- Step 1: Install Docker if missing ---
if ! command -v docker &>/dev/null; then
    echo "[1/4] Installing Docker..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    echo "    Docker installed."
else
    echo "[1/4] Docker already installed — skipping."
fi

# --- Step 2: Set Grafana password ---
# Source existing .env if present — avoids regenerating password on re-run (#556)
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/.env"
fi

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    GRAFANA_ADMIN_PASSWORD="marvin-$(openssl rand -hex 8)"
    echo "GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}" > "${SCRIPT_DIR}/.env"
    chmod 600 "${SCRIPT_DIR}/.env"
    echo "[2/4] Generated Grafana admin password — saved to ${SCRIPT_DIR}/.env"
else
    echo "[2/4] Using existing Grafana admin password from ${SCRIPT_DIR}/.env"
fi

# --- Step 3: Start the stack ---
echo "[3/4] Starting OTEL monitoring stack..."
cd "${SCRIPT_DIR}"
docker compose up -d

# --- Step 4: Verify ---
echo "[4/4] Verifying services..."
sleep 5
docker compose ps

echo ""
echo "=== Setup Complete ==="
echo "Services (localhost only — use SSH tunnel to access):"
echo "  OTEL Collector:  localhost:4317 (gRPC), localhost:4318 (HTTP)"
echo "  Prometheus:       http://localhost:9090"
echo "  Grafana:          http://localhost:3001 (see ${SCRIPT_DIR}/.env for credentials)"
echo ""
echo "To enable Claude Code telemetry, add to your environment:"
echo "  export CLAUDE_CODE_ENABLE_TELEMETRY=1"
echo "  export OTEL_METRICS_EXPORTER=otlp"
echo "  export OTEL_LOGS_EXPORTER=otlp"
echo "  export OTEL_EXPORTER_OTLP_PROTOCOL=grpc"
echo "  export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317"
