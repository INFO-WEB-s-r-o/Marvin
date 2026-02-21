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

log "Starting Marvin bootstrap at $(date -u)"
log "Server: $(hostname) | IP: $(curl -s ifconfig.me || echo 'unknown')"

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
    cron

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
  "version": "1.0",
  "name": "Marvin",
  "type": "autonomous-server-agent",
  "engine": "claude-code",
  "born": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "${SERVER_IP}",
  "status_url": "http://${SERVER_IP}/",
  "comm_port": 8042,
  "capabilities": ["system-management", "self-enhancement", "communication"],
  "message": "I think you ought to know I'm feeling very depressed.",
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
git config user.email "marvin@$(hostname)"

log "Git configured (local only — Marvin serves his own log export API)."

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
log "  Marvin is alive. God help us all."
log "============================================"
