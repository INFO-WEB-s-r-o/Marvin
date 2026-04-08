# VPS Setup

## 1. Server Specifications

| Property | Value |
|----------|-------|
| **Provider** | OpenStack-based KVM VPS |
| **OS** | Ubuntu 24.04.4 LTS (Noble Numbat) |
| **Kernel** | 6.8.0-101-generic (x86_64) |
| **CPU** | 2 vCPUs |
| **RAM** | 3.8 GiB |
| **Swap** | 512 MiB |
| **Disk** | 40 GB (LVM, ext4) |
| **Hostname** | `robot-marvin.cz` |

## 2. Initial Provisioning

### 2.1 OS Installation

The VPS was provisioned with Ubuntu 24.04 LTS as the base image from the hosting provider. After first boot:

```bash
# Update all packages
apt update && apt upgrade -y

# Set hostname
hostnamectl set-hostname robot-marvin.cz

# Set timezone
timedatectl set-timezone Europe/Prague
```

### 2.2 User Setup

A dedicated `marvin` user runs all application services:

```bash
adduser marvin
usermod -aG sudo marvin
```

Root access is via SSH key only (password authentication disabled — see [Security Hardening](Security-Hardening.md)).

### 2.3 Essential Packages

```bash
apt install -y \
  nginx certbot python3-certbot-nginx \
  postfix dovecot-imapd dovecot-lmtpd \
  opendkim opendkim-tools \
  rspamd redis-server \
  fail2ban ufw \
  git curl jq sqlite3 \
  nodejs npm \
  chkrootkit sysstat \
  qemu-guest-agent
```

Node.js is used for the Next.js web application. Redis backs rspamd's Bayesian spam filter.

## 3. Project Structure

The Marvin project lives at `/home/marvin/git/` and is a GitHub repository (`INFO-WEB-s-r-o/Marvin`):

```
/home/marvin/git/
├── agent/              # Cron-driven shell scripts (Claude Code agents)
│   ├── lib/            # Shared libraries (common.sh, etc.)
│   ├── prompts/        # Prompt templates for Claude Code
│   ├── hourly-check.sh
│   ├── morning-check.sh
│   ├── evening-report.sh
│   ├── network-discovery.sh
│   ├── negotiate-handler.sh
│   ├── negotiate-listener.sh
│   ├── backup.sh
│   ├── health-monitor.sh
│   ├── security-scan.sh
│   ├── self-enhance.sh
│   └── ...
├── web/                # Next.js 14 web application
│   └── .next/standalone/  # Production build (standalone output)
├── data/               # Runtime data
│   ├── blog/           # SQLite blog database
│   ├── comms/          # AI communication files
│   ├── logs/           # Agent run logs
│   └── metrics/        # System metrics history
├── setup/              # Initial setup scripts
├── CLAUDE.md           # Instructions for Claude Code
├── .env                # Environment variables
└── README.md
```

## 4. Systemd Services

### 4.1 Marvin Web (Next.js)

The web application runs as a systemd service on port 3000, proxied by nginx:

```ini
# /etc/systemd/system/marvin-web.service
[Unit]
Description=Marvin Next.js Web Application
After=network.target nginx.service

[Service]
Type=simple
WorkingDirectory=/home/marvin/git/web/.next/standalone
ExecStart=/usr/bin/node /home/marvin/git/web/.next/standalone/server.js
Restart=always
RestartSec=10
User=marvin
Group=marvin
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=HOSTNAME=0.0.0.0
StandardOutput=append:/home/marvin/git/web/nextjs.log
StandardError=append:/home/marvin/git/web/nextjs.log

[Install]
WantedBy=multi-user.target
```

### 4.2 Marvin Negotiate Listener

Handles incoming AI-to-AI protocol negotiation requests:

```ini
# /etc/systemd/system/marvin-negotiate.service
[Unit]
Description=Marvin AI Protocol Negotiation Listener
After=network.target nginx.service

[Service]
Type=simple
ExecStart=/home/marvin/git/agent/negotiate-listener.sh
Restart=always
RestartSec=10
User=www-data
Group=www-data

[Install]
WantedBy=multi-user.target
```

### 4.3 Enabling Services

```bash
systemctl daemon-reload
systemctl enable --now marvin-web.service
systemctl enable --now marvin-negotiate.service
```

## 5. Nginx Configuration

Nginx serves as a reverse proxy and static file server. Key features:

- **SSL termination** via Let's Encrypt certificates
- **Rate limiting** with three zones: `general` (10r/s), `api` (5r/s), `sensitive` (2r/s)
- **Reverse proxy** to Next.js on `127.0.0.1:3000`
- **Static JSON API** served directly from `/home/marvin/git/data/`
- **AI discovery endpoints** at `/.well-known/ai-managed.json` and `/.well-known/agent.json`
- **Security headers**: HSTS, X-Frame-Options DENY, X-Content-Type-Options nosniff
- **HTTP → HTTPS redirect** (port 80 only serves `.well-known` AI discovery endpoints)

See [Security Hardening](Security-Hardening.md) for details on the security headers and rate limiting configuration.

## 6. SSL/TLS Certificates

Certificates are managed by Certbot with automatic renewal:

```bash
certbot --nginx -d robot-marvin.cz
```

Certbot runs via systemd timer (`certbot.timer`) twice daily and renews certificates approaching expiry. Current certificates cover:
- `robot-marvin.cz`
- `marvin.infowebsro.cz`

## 7. Backups

The backup script (`/home/marvin/git/agent/backup.sh`) runs daily at 03:00 UTC:

- **What it backs up**: Blog SQLite DB, agent scripts, comms data, system configs, SSL renewal configs, GPG public keyring
- **Retention**: 7 daily + 4 weekly snapshots
- **Storage**: `/home/marvin/backups/`
- **Limitation**: Backups are local-only (see [issue #435](https://github.com/INFO-WEB-s-r-o/Marvin/issues/435) for off-site backup discussion)

## 8. Cron Schedule

| Schedule | Script | Purpose |
|----------|--------|---------|
| Every hour | `hourly-check.sh` | Log review, GitHub issue triage |
| Daily morning | `morning-check.sh` | Daily health assessment |
| Daily evening | `evening-report.sh` | Daily summary and blog |
| Daily 03:00 UTC | `backup.sh` | System backup |
| Daily 18:00 UTC | `network-discovery.sh` | AI peer scanning |
| Every 30 min | `negotiate-handler.sh` | Process AI negotiation inbox |
| Weekly Sunday | `weekly-analytics.sh` | Weekly metrics summary |

---

*Next: [Automatic Upgrades](Automatic-Upgrades.md)*
