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

MARVIN_DIR="/home/marvin/git"
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
        sed -i "s|^127\.0\.1\.1.*|127.0.1.1\t${MARVIN_HOSTNAME}|" /etc/hosts
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

# chkrootkit runs from chkrootkit.timer, and systemd starts services with an
# empty environment. Two of chkrootkit's checks — "zero-size shell history
# files" and "hardlinked shell history files" — are gated on $SHELL and $HOME
# being set, so under the timer they report "not tested" and never run. The
# drop-in supplies both. See setup/chkrootkit-service-override.conf for the
# full rationale, including the daily false-positive alert it also silences.
# Conditional: chkrootkit is not a bootstrap package, so a host without it
# simply skips this.
#
# The presence test is `list-unit-files` alone, deliberately. An earlier form
# also required `[[ -f /usr/lib/systemd/system/chkrootkit.service ]]`, which
# hardcodes one of several unit search paths: a host carrying the unit in
# /etc/systemd/system (a hand-installed or packaged-elsewhere chkrootkit)
# satisfies list-unit-files, fails the -f, and silently skips the drop-in —
# losing the fix on exactly the rebuild path this block exists to serve.
# `list-unit-files` searches every unit path and exits 1 when nothing matches
# (systemd 255; verified against a real /etc-only unit and a nonexistent one),
# so it is both more general and still a genuine gate. The drop-in directory
# below is correct regardless of where the base unit lives.
#
# `install` runs unconditionally — it is what repairs a drifted mode or a
# hand-edited copy, and it is cheap. The `daemon-reload` is what gets gated:
# systemd re-reads unit *content*, so a byte-identical drop-in has nothing to
# tell it, and reloading anyway is a side effect on every rerun that buys
# nothing. The comparison must happen BEFORE the install — afterwards the two
# files always match, and the test would be answering a question about its own
# side effect rather than about the host it found. `cmp` exits non-zero for
# both "differs" and "could not read" (missing destination, unreadable source),
# and both take the reload arm: an unanswerable comparison is not a match.
_ck_dropin_src="${MARVIN_DIR}/setup/chkrootkit-service-override.conf"
# The directory is named once and the file derived from it. It was previously
# spelled out twice — in this assignment and again as the `install -d` target —
# with nothing tying the copies together, so a future relocation that missed
# one would have created the drop-in directory in one place and written the
# override into another. Quoted per the repo convention; neither path contains
# whitespace or globs today, which is the reason to quote them now rather than
# after one does.
_ck_dropin_dir="/etc/systemd/system/chkrootkit.service.d"
_ck_dropin_dst="${_ck_dropin_dir}/override.conf"
if systemctl list-unit-files chkrootkit.service &>/dev/null; then
    _ck_dropin_changed=1
    cmp -s "${_ck_dropin_src}" "${_ck_dropin_dst}" && _ck_dropin_changed=0
    # `install -d -m 755`, not `mkdir -p`: mkdir takes its mode from whatever
    # umask the caller happened to have. 0022 — this host's, and cron's — gives
    # 755 either way, but 002 yields a group-writable systemd drop-in directory
    # and 077 yields 700. A directory whose mode depends on ambient state, one
    # line above an `install -m 644` that pins the file's mode precisely because
    # ambient state is not a specification.
    install -d -m 755 "${_ck_dropin_dir}"
    install -m 644 "${_ck_dropin_src}" "${_ck_dropin_dst}"
    if [[ "${_ck_dropin_changed}" -eq 1 ]]; then
        log "Installed chkrootkit systemd drop-in (restore history-file checks)."
        systemctl daemon-reload
    else
        log "chkrootkit systemd drop-in already current — no daemon-reload needed."
    fi
fi
unset _ck_dropin_src _ck_dropin_dir _ck_dropin_dst _ck_dropin_changed

# =============================================================================
# 3. Install Node.js (for Claude Code CLI)
# =============================================================================

log "Installing Node.js 20 LTS..."
if ! command -v node &> /dev/null; then
    # Use NodeSource signed apt repository instead of curl|bash
    apt-get install -y -qq ca-certificates curl gnupg
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq
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
mkdir -p "${MARVIN_DIR}/data/exports"
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

# Generate export API key for /api/exports/ authentication
log "Generating export API key..."
if [ -n "${EXPORT_API_KEY:-}" ]; then
    log "Using provided EXPORT_API_KEY from environment"
else
    EXPORT_API_KEY=$(openssl rand -hex 32)
    log "Generated new export API key"
fi
cat > /etc/nginx/export-api-key.conf << APIEOF
# Marvin Export API Key — generated during bootstrap
# Format: key_value "valid"; (used by nginx map directive)
${EXPORT_API_KEY} "valid";
APIEOF
chmod 600 /etc/nginx/export-api-key.conf
chown root:www-data /etc/nginx/export-api-key.conf
log "Export API key written to /etc/nginx/export-api-key.conf"

# Create map directive for API key validation (consumed by auth_request in HTTPS block)
cat > /etc/nginx/conf.d/marvin-export-map.conf << MAPEOF
# Marvin export API key map — validates X-API-Key header
# Used by auth_request /auth/validate-export-key in the HTTPS server block
map_hash_bucket_size 128;
map \$http_x_api_key \$export_api_key_header {
    default "";
    include /etc/nginx/export-api-key.conf;
}
MAPEOF
log "Export API key map directive written to /etc/nginx/conf.d/marvin-export-map.conf"

# Write key to a location accessible by Marvin's agent scripts
echo "${EXPORT_API_KEY}" > "${MARVIN_DIR}/data/.export-api-key"
chown ${MARVIN_USER}:${MARVIN_USER} "${MARVIN_DIR}/data/.export-api-key"
chmod 600 "${MARVIN_DIR}/data/.export-api-key"
log "Export API key also written to ${MARVIN_DIR}/data/.export-api-key (marvin-readable)"

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
    
    # API endpoints (generated JSON files) — ALLOWLIST, not a denylist.
    # A bare `alias ${MARVIN_DIR}/data/` here publishes all of data/, including
    # security/, email/ and comms/, which the post-certbot site config denies.
    # This block is written by bootstrap, so a re-run must not silently reinstate
    # a wider surface than setup/nginx-site.conf serves. Keep the two in sync.
    location ~ ^/api/((?:about|blog-index|changelog|comms-summary|enhancements|external-domains|metrics-history|peer-health|peers-public|status|thoughts|uptime)\.json|(?:alerts/active-alerts|incidents/active-incidents|incidents/summary|metrics/recent|metrics/sla|peers/registry|security/security-score)\.json|reports/weekly-card-latest\.svg)\$ {
        alias ${MARVIN_DIR}/data/\$1;
        default_type application/json;
        add_header Access-Control-Allow-Origin "*";
        add_header Cache-Control "no-cache";
    }

    location /api/ {
        return 403;
    }

    # Export API — BLOCKED on plaintext HTTP (defense in depth)
    # The authenticated export endpoint is only available over HTTPS,
    # which is configured by Certbot post-bootstrap (certbot --nginx).
    # This prevents API keys from being transmitted in cleartext.
    location /api/exports/ {
        default_type application/json;
        return 403 '{"error":"forbidden","message":"Export API requires HTTPS."}';
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
        
        # Deliberately NO client_body_temp_path / client_body_in_file_only
        # (issue #854): negotiate-listener.sh reads the body from stdin, so
        # nginx writing it into the handler's inbox fed nothing — and
        # \`in_file_only on\` never removes the file, so every public POST
        # left a permanent raw body there. Keep this block in step with
        # setup/nginx-site.conf, which self-test §9d diffs against live.
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
    git remote add origin "https://github.com/${GITHUB_REPO}.git"
    git config credential.helper '!f() { echo "username=x-access-token"; echo "password=${GITHUB_TOKEN}"; }; f'
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
# 11b. Web application service
# =============================================================================
# Installed from the tracked unit (setup/marvin-web.service) rather than an
# inline heredoc, so there is a single source of truth and self-test.sh's
# config-drift check stays meaningful. Enabled (survives reboot) but not
# started here — the standalone build must exist first; deploy-web.sh /
# morning-check.sh perform the build + start and own the health check.

log "Installing web application systemd service..."
install -m 644 "${MARVIN_DIR}/setup/marvin-web.service" /etc/systemd/system/marvin-web.service
systemctl daemon-reload
systemctl enable marvin-web
log "Web application service installed and enabled (start deferred to first web deploy)."

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
    sed -i "s|server_name _;|server_name ${MARVIN_DOMAIN};|" /etc/nginx/sites-available/marvin
    nginx -t && systemctl reload nginx
    
    # Install certbot and get certificate
    apt-get install -y certbot python3-certbot-nginx -qq

    # Install the deploy hook that reloads TLS services after a renewal.
    # certbot renews the cert file but long-running services (notably dovecot)
    # keep the old cert in memory until reloaded — see the header of
    # setup/letsencrypt-deploy-hook.sh for the 2026-07-08 IMAPS stale-cert
    # incident this prevents. Installed from the tracked source so self-test.sh
    # §9d's config-drift check stays meaningful.
    log "Installing Let's Encrypt deploy hook (reload TLS services on renewal)..."
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    install -m 755 "${MARVIN_DIR}/setup/letsencrypt-deploy-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh

    if certbot --nginx -d "${MARVIN_DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email --redirect; then
        log "SSL certificate installed for ${MARVIN_DOMAIN}"

        # Update identity beacon with HTTPS URL
        sed -i "s|http://${SERVER_IP}/|https://${MARVIN_DOMAIN}/|" "${MARVIN_DIR}/data/comms/identity.json"

        # Enable auto-renewal timer
        systemctl enable --now certbot.timer 2>/dev/null || true

        # Patch HTTPS server block with authenticated export API
        # Certbot carries over the HTTP 403 block to HTTPS — replace it with auth_request
        NGINX_SITE="/etc/nginx/sites-available/marvin"

        # Add auth_request validation endpoint and error handler before the HTTPS /api/exports/ location
        # Find the HTTPS server block (listen 443) and inject auth locations
        if grep -q "listen 443 ssl" "${NGINX_SITE}"; then
            log "Patching HTTPS block with authenticated export API..."

            # Replace the 403 block in the HTTPS section with authenticated version
            # The HTTPS block is the one with "listen 443 ssl" — use a Python one-liner for reliable multi-line replacement
            python3 - "${NGINX_SITE}" "${MARVIN_DIR}" << 'PYEOF'
import sys, re

nginx_file = sys.argv[1]
marvin_dir = sys.argv[2]

with open(nginx_file, 'r') as f:
    content = f.read()

# Find the HTTPS server block (contains "listen 443 ssl")
# Replace the 403 export location in HTTPS with authenticated version
https_export_block = '''    # Export API — BLOCKED on plaintext HTTP (defense in depth)
    # The authenticated export endpoint is only available over HTTPS,
    # which is configured by Certbot post-bootstrap (certbot --nginx).
    # This prevents API keys from being transmitted in cleartext.
    location /api/exports/ {
        default_type application/json;
        return 403 '{"error":"forbidden","message":"Export API requires HTTPS."}';
    }'''

https_auth_block = f'''    # Export API key validation (internal auth_request endpoint)
    location = /auth/validate-export-key {{
        internal;
        if ($export_api_key_header != "valid") {{
            return 401;
        }}
        return 200;
    }}

    # Export API auth error handler
    location @export_auth_error {{
        internal;
        default_type application/json;
        return 401 '{{"error":"unauthorized","message":"API key required. Use X-API-Key header."}}';
    }}

    # Export API — requires X-API-Key header (auth_request pattern)
    location /api/exports/ {{
        auth_request /auth/validate-export-key;
        error_page 401 = @export_auth_error;
        alias {marvin_dir}/data/exports/;
        default_type application/json;
        gzip_static on;
        add_header Access-Control-Allow-Origin "*";
        add_header Cache-Control "no-cache";
    }}'''

# Split content into server blocks, find the HTTPS one (has "listen 443")
# and replace the 403 export block there
blocks = content.split('server {')
new_blocks = []
for i, block in enumerate(blocks):
    if 'listen 443 ssl' in block and 'return 403' in block and '/api/exports/' in block:
        block = block.replace(https_export_block, https_auth_block)
    new_blocks.append(block)

new_content = 'server {'.join(new_blocks)

with open(nginx_file, 'w') as f:
    f.write(new_content)
PYEOF

            # Verify config
            if nginx -t 2>/dev/null; then
                systemctl reload nginx
                log "HTTPS export API configured with auth_request pattern"
            else
                log "WARNING: nginx config test failed after patching — reverting"
                certbot --nginx -d "${MARVIN_DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email --redirect 2>/dev/null || true
            fi
        else
            log "WARNING: Could not find HTTPS block — export API will remain disabled until manually configured"
        fi
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
