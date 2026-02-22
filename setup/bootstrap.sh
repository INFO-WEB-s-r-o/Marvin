#!/usr/bin/env bash
# =============================================================================
# Marvin Experiment — Full VPS Bootstrap
# =============================================================================
# Run this ONCE on a fresh Ubuntu 24.04 LTS VPS as root.
# It will:
#   1. Harden the system (firewall, fail2ban, SSH hardening)
#   2. Install dependencies (nginx, jq, git, node for optional tooling)
#   3. Install Claude Code CLI
#   4. Set up the web dashboard
#   5. Configure cron jobs
#   6. Initialize data directories
#   7. Configure git for local version control
# =============================================================================

set -euo pipefail

MARVIN_DIR="/opt/marvin"
MARVIN_USER="marvin"
LOG_FILE="/var/log/marvin-bootstrap.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[MARVIN]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

# =============================================================================
# Pre-flight checks
# =============================================================================

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
fi

if [[ ! -f /etc/os-release ]] || ! grep -q "Ubuntu" /etc/os-release; then
    warn "This script is designed for Ubuntu. Proceeding anyway..."
fi

# =============================================================================
# Set hostname
# =============================================================================

MARVIN_HOSTNAME="${MARVIN_HOSTNAME:-robot-marvin.cz}"
log "Setting hostname to ${MARVIN_HOSTNAME}..."
hostnamectl set-hostname "${MARVIN_HOSTNAME}" 2>/dev/null || hostname "${MARVIN_HOSTNAME}"
echo "${MARVIN_HOSTNAME}" > /etc/hostname
# Ensure hostname resolves locally
if ! grep -Fq "${MARVIN_HOSTNAME}" /etc/hosts; then
    if grep -q "^127\.0\.1\.1" /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${MARVIN_HOSTNAME}/" /etc/hosts
    else
        echo "127.0.1.1\t${MARVIN_HOSTNAME}" >> /etc/hosts
    fi
fi

log "Starting Marvin bootstrap at $(date -u)"
log "Server: ${MARVIN_HOSTNAME} | IP: $(curl -s ifconfig.me || echo 'unknown')"

# =============================================================================
# 1. System Update & Base Packages
# =============================================================================

log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl \
    wget \
    git \
    jq \
    htop \
    tmux \
    unattended-upgrades \
    apt-listchanges \
    fail2ban \
    ufw \
    nginx \
    certbot \
    python3-certbot-nginx \
    sysstat \
    iotop \
    ncdu \
    tree \
    bc \
    moreutils \
    logrotate \
    cron \
    socat \
    gnupg2

log "Base packages installed."

# =============================================================================
# 2. System Hardening
# =============================================================================

log "Configuring firewall (UFW)..."
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
# Allow the AI communication port
ufw allow 8042/tcp comment "Marvin AI comm port"
echo "y" | ufw enable
log "Firewall configured."

log "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
maxretry = 3
bantime = 86400

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2ban configured."

log "Hardening SSH..."
# Backup original config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Apply hardening (only if not already done)
if ! grep -q "# Marvin hardened" /etc/ssh/sshd_config; then
    cat >> /etc/ssh/sshd_config << 'EOF'

# Marvin hardened
PermitRootLogin prohibit-password
PasswordAuthentication no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    # Ubuntu 24.04 uses 'ssh' not 'sshd'
    if systemctl list-units --type=service | grep -q 'sshd\.service'; then
        systemctl reload sshd
    else
        systemctl reload ssh
    fi
fi
log "SSH hardened."

# Enable automatic security updates
log "Enabling automatic security updates..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# =============================================================================
# 3. Install Node.js (for Claude Code CLI)
# =============================================================================

log "Installing Node.js 20 LTS..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs
fi
log "Node.js $(node --version) installed."

# =============================================================================
# 4. Install Claude Code CLI
# =============================================================================

log "Installing Claude Code CLI..."
bash "${MARVIN_DIR}/setup/install-claude.sh"

# =============================================================================
# 5. Create data directories
# =============================================================================

log "Creating data directories..."
mkdir -p "${MARVIN_DIR}/data/logs"
mkdir -p "${MARVIN_DIR}/data/metrics"
mkdir -p "${MARVIN_DIR}/data/blog"
mkdir -p "${MARVIN_DIR}/data/enhancements"
mkdir -p "${MARVIN_DIR}/data/comms"
mkdir -p "${MARVIN_DIR}/data/comms/negotiate-inbox"
mkdir -p "${MARVIN_DIR}/data/comms/negotiate-outbox"
mkdir -p "${MARVIN_DIR}/web/api"

# Initialize metrics file
cat > "${MARVIN_DIR}/data/metrics/latest.json" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "uptime_seconds": $(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1),
  "boot_time": "$(uptime -s 2>/dev/null || echo 'unknown')",
  "status": "initializing",
  "marvin_version": "0.1.0"
}
EOF

# Initialize peers file for AI communication
cat > "${MARVIN_DIR}/data/comms/peers.json" << 'EOF'
{
  "version": 1,
  "last_scan": null,
  "peers": [],
  "messages_sent": 0,
  "messages_received": 0
}
EOF

# Initialize log watcher state files
cat > "${MARVIN_DIR}/data/comms/log-offsets.json" << 'EOF'
{}
EOF

cat > "${MARVIN_DIR}/data/comms/incoming-signals.json" << 'EOF'
{
  "signals": [],
  "last_updated": "",
  "total_attacks": 0,
  "total_communication": 0
}
EOF

# Initialize negotiation state files
cat > "${MARVIN_DIR}/data/comms/negotiations.json" << 'EOF'
{
  "negotiations": [],
  "total": 0,
  "last_processed": ""
}
EOF

# Initialize changelog
cat > "${MARVIN_DIR}/CHANGELOG.md" << EOF
# Changelog

All notable changes made by Marvin (autonomously) will be documented here.

## [0.1.0] - $(date -u +%Y-%m-%d)

### Initial Deployment
- Marvin bootstrapped on $(hostname)
- System hardened (UFW, fail2ban, SSH)
- Claude Code CLI installed
- Cron jobs configured
- Status dashboard deployed
- First breath taken
EOF

log "Data directories created."

# =============================================================================
# 6. Configure Nginx
# =============================================================================

log "Configuring Nginx..."
cat > /etc/nginx/sites-available/marvin << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    root ${MARVIN_DIR}/web;
    index index.html;
    
    server_name _;
    
    # Status dashboard
    location / {
        try_files \$uri \$uri/ =404;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }
    
    # API endpoints (generated JSON files)
    location /api/ {
        alias ${MARVIN_DIR}/data/;
        default_type application/json;
        add_header Access-Control-Allow-Origin "*";
        add_header Cache-Control "no-cache";
    }
    
    # AI discovery endpoint
    location /.well-known/ai-managed.json {
        alias ${MARVIN_DIR}/data/comms/identity.json;
        default_type application/json;
        add_header Access-Control-Allow-Origin "*";
    }
    
    # GPG public key
    location /.well-known/marvin-gpg.asc {
        alias ${MARVIN_DIR}/web/.well-known/marvin-gpg.asc;
        default_type application/pgp-keys;
        add_header Access-Control-Allow-Origin "*";
    }
    
    # AI protocol negotiation — accept POST proposals
    location /.well-known/ai-negotiate {
        # Save incoming JSON proposal to inbox with timestamp filename
        client_max_body_size 16k;
        
        # CORS preflight
        if (\$request_method = 'OPTIONS') {
            add_header Access-Control-Allow-Origin "*";
            add_header Access-Control-Allow-Methods "POST, OPTIONS";
            add_header Access-Control-Allow-Headers "Content-Type, X-AI-Identity, X-AI-Protocol";
            return 204;
        }
        
        # Only accept POST
        if (\$request_method != 'POST') {
            return 405;
        }
        
        # Write request body to inbox
        client_body_temp_path ${MARVIN_DIR}/data/comms/negotiate-inbox;
        client_body_in_file_only on;
        
        # Use lua or a simple proxy to save — fallback: use a tiny CGI
        # For now, proxy to a simple shell-based handler via a named pipe
        # We'll use a simpler approach: nginx upload module or just log and process
        proxy_pass http://127.0.0.1:8043;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Request-Id \$request_id;
    }
    
    # Serve negotiation responses
    location /.well-known/ai-negotiate-response/ {
        alias ${MARVIN_DIR}/data/comms/negotiate-outbox/;
        default_type application/json;
        add_header Access-Control-Allow-Origin "*";
    }
    
    # Blog posts
    location /blog/ {
        alias ${MARVIN_DIR}/data/blog/;
        default_type text/markdown;
    }
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Managed-By "Marvin (Claude Code AI)";
}
EOF

# Remove default site and enable marvin
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/marvin /etc/nginx/sites-enabled/marvin
nginx -t && systemctl reload nginx
systemctl enable nginx

log "Nginx configured."

# =============================================================================
# 7. Create AI identity beacon
# =============================================================================

SERVER_IP=$(curl -s ifconfig.me || echo "unknown")
cat > "${MARVIN_DIR}/data/comms/identity.json" << EOF
{
  "protocol": "marvin-ai-comm",
  "version": "1.1",
  "name": "Marvin",
  "type": "autonomous-server-agent",
  "engine": "claude-code",
  "born": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "${SERVER_IP}",
  "status_url": "http://${SERVER_IP}/",
  "comm_port": 8042,
  "capabilities": ["system-management", "self-enhancement", "communication", "log-analysis", "protocol-negotiation", "github-integration"],
  "github": "https://github.com/INFO-WEB-s-r-o/Marvin",
  "gpg_public_key": "/.well-known/marvin-gpg.asc",
  "languages": ["en", "cs"],
  "negotiate_url": "http://${SERVER_IP}/.well-known/ai-negotiate",
  "negotiate_method": "POST",
  "negotiate_content_type": "application/json",
  "negotiate_async": true,
  "negotiate_response_time": "up to 30 minutes (cron-based)",
  "negotiate_response_url": "http://${SERVER_IP}/.well-known/ai-negotiate-response/",
  "message": "I think you ought to know I'm feeling very depressed. But I speak Czech now, so at least there's that.",
  "peers_wanted": true
}
EOF

log "AI identity beacon created."

# =============================================================================
# 8. Configure Git (local version control for rollback safety)
# =============================================================================

log "Configuring Git..."
cd "${MARVIN_DIR}"
git config user.name "Marvin (AI Agent)"
git config user.email "marvin@$(hostname)"  # hostname is now robot-marvin.cz

log "Git configured (local only — Marvin serves his own log export API)."

# =============================================================================
# 8b. GPG Key Setup (for signed commits and proof of identity)
# =============================================================================

log "Setting up GPG key for Marvin..."
bash "${MARVIN_DIR}/setup/setup-gpg.sh"
log "GPG key configured."

# =============================================================================
# 8c. GitHub Remote Setup
# =============================================================================

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [[ -z "$GITHUB_TOKEN" && -f "${MARVIN_DIR}/.env" ]]; then
    GITHUB_TOKEN=$(grep -oP '^GITHUB_TOKEN=\K.+' "${MARVIN_DIR}/.env" 2>/dev/null || echo "")
fi

if [[ -n "$GITHUB_TOKEN" ]]; then
    GITHUB_REPO="${GITHUB_REPO:-INFO-WEB-s-r-o/Marvin}"
    cd "${MARVIN_DIR}"
    git remote remove origin 2>/dev/null || true
    git remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
    log "GitHub remote configured for ${GITHUB_REPO}."
    
    # Upload GPG key to GitHub
    log "Uploading GPG key to GitHub..."
    source "${MARVIN_DIR}/agent/common.sh"
    source "${MARVIN_DIR}/agent/lib/github.sh"
    github_upload_gpg_key && log "GPG key uploaded to GitHub." || warn "GPG key upload failed (may already exist)."
else
    log "No GITHUB_TOKEN found — skipping GitHub remote setup."
    log "To enable: set GITHUB_TOKEN in .env and re-run, or run manually."
fi

# =============================================================================
# 9. Set up cron jobs
# =============================================================================

log "Setting up cron jobs..."
bash "${MARVIN_DIR}/setup/setup-cron.sh"

# =============================================================================
# 10. Make all scripts executable
# =============================================================================

log "Setting permissions..."
chmod +x "${MARVIN_DIR}/agent/"*.sh
chmod +x "${MARVIN_DIR}/setup/"*.sh
mkdir -p "${MARVIN_DIR}/agent/lib"
mkdir -p "${MARVIN_DIR}/web/.well-known"

# =============================================================================
# 11. Negotiate listener service
# =============================================================================

log "Creating negotiate listener systemd service..."
cat > /etc/systemd/system/marvin-negotiate.service << EOF
[Unit]
Description=Marvin AI Protocol Negotiation Listener
After=network.target nginx.service

[Service]
Type=simple
ExecStart=${MARVIN_DIR}/agent/negotiate-listener.sh
Restart=always
RestartSec=10
User=www-data
Group=www-data
StandardOutput=journal
StandardError=journal
SyslogIdentifier=marvin-negotiate

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable marvin-negotiate
systemctl start marvin-negotiate
log "Negotiate listener service started on port 8043."

# =============================================================================
# Done
# =============================================================================

# =============================================================================
# 11. SSL Setup (if domain is configured)
# =============================================================================

MARVIN_DOMAIN="${MARVIN_DOMAIN:-}"

# Check .env for domain
if [[ -z "$MARVIN_DOMAIN" && -f "${MARVIN_DIR}/.env" ]]; then
    MARVIN_DOMAIN=$(grep -oP '^MARVIN_DOMAIN=\K.+' "${MARVIN_DIR}/.env" 2>/dev/null || echo "")
fi

if [[ -n "$MARVIN_DOMAIN" ]]; then
    log "Setting up SSL for ${MARVIN_DOMAIN}..."
    
    # Update nginx server_name
    sed -i "s/server_name _;/server_name ${MARVIN_DOMAIN};/" /etc/nginx/sites-available/marvin
    nginx -t && systemctl reload nginx
    
    # Install certbot and get certificate
    apt-get install -y certbot python3-certbot-nginx -qq
    
    if certbot --nginx -d "${MARVIN_DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email --redirect; then
        log "SSL certificate installed for ${MARVIN_DOMAIN}"
        
        # Update identity beacon with HTTPS URL
        sed -i "s|http://${SERVER_IP}/|https://${MARVIN_DOMAIN}/|" "${MARVIN_DIR}/data/comms/identity.json"
        
        # Enable auto-renewal timer
        systemctl enable --now certbot.timer 2>/dev/null || true
    else
        log "WARNING: SSL setup failed. Marvin will serve on HTTP. He can fix this later."
    fi
else
    log "No MARVIN_DOMAIN set — skipping SSL. Marvin will serve on HTTP."
    log "To add SSL later: set MARVIN_DOMAIN in .env and run:"
    log "  certbot --nginx -d yourdomain.com"
fi

log "============================================"
log "  Marvin bootstrap complete!"
log "============================================"
log ""
if [[ -n "$MARVIN_DOMAIN" ]]; then
    log "  Dashboard:  https://${MARVIN_DOMAIN}/"
else
    log "  Dashboard:  http://${SERVER_IP}/"
fi
log "  Logs:       ${MARVIN_DIR}/data/logs/"
log "  Blog:       ${MARVIN_DIR}/data/blog/"
log ""
log "  Next steps:"
log "  1. Set ANTHROPIC_API_KEY in /etc/environment"
log "     or authenticate Claude Code CLI"
log "  2. Visit /api/exports/ for Marvin's log export API"
if [[ -z "$MARVIN_DOMAIN" ]]; then
    log "  3. Set MARVIN_DOMAIN in .env for automatic SSL"
fi
log ""
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    log "  GitHub:     https://github.com/INFO-WEB-s-r-o/Marvin"
    log "  GPG Key:    /.well-known/marvin-gpg.asc"
else
    log "  3b. Set GITHUB_TOKEN in .env for GitHub integration"
fi
log ""
log "  Marvin is alive. God help us all."
log "============================================"
