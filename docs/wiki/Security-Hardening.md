# Security Hardening

## Overview

As an autonomous server with no human watching the console, security hardening is essential. The approach follows defense-in-depth: multiple overlapping layers so that no single failure compromises the system.

## 1. SSH Hardening

### Configuration

The SSH daemon is configured with restrictive settings:

```
# /etc/ssh/sshd_config (effective settings)
PermitRootLogin prohibit-password      # Root login only via SSH key
PasswordAuthentication no              # No password auth — keys only
KbdInteractiveAuthentication no        # No keyboard-interactive auth
MaxAuthTries 3                         # Lock out after 3 failed attempts
LoginGraceTime 30                      # 30 seconds to authenticate
ClientAliveInterval 300                # Keepalive every 5 minutes
ClientAliveCountMax 2                  # Disconnect after 2 missed keepalives
```

### Step-by-Step: SSH Key Setup

1. **Generate an SSH key** (on your local machine):
   ```bash
   ssh-keygen -t ed25519 -C "your-email@example.com"
   ```

2. **Copy the key to the server**:
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub user@server-ip
   ```

3. **Disable password authentication** on the server:
   ```bash
   # /etc/ssh/sshd_config
   PasswordAuthentication no
   PermitRootLogin prohibit-password
   ```

4. **Restart SSH**:
   ```bash
   systemctl restart sshd
   ```

5. **Test** from another terminal before closing your current session.

## 2. UFW Firewall

The server uses UFW (Uncomplicated Firewall) with a **default-deny incoming** policy.

### Active Rules

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH (OpenSSH) |
| 80 | TCP | HTTP (redirects to HTTPS, serves AI discovery) |
| 443 | TCP | HTTPS (nginx) |
| 25 | TCP | SMTP (Postfix — inbound mail) |
| 465 | TCP | SMTPS (implicit TLS) |
| 587 | TCP | Submission (STARTTLS) |
| 993 | TCP | IMAPS (Dovecot) |

### Default Policy

```
Default: deny (incoming), allow (outgoing), disabled (routed)
```

### Step-by-Step: Firewall Setup

```bash
# Enable UFW
ufw default deny incoming
ufw default allow outgoing

# Allow essential services
ufw allow OpenSSH
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS
ufw allow 25/tcp    # SMTP
ufw allow 465/tcp   # SMTPS
ufw allow 587/tcp   # Submission
ufw allow 993/tcp   # IMAPS

# Enable
ufw enable

# Verify
ufw status verbose
```

## 3. Fail2Ban

Fail2Ban monitors log files and bans IPs that show malicious patterns. Six jails are active:

| Jail | Monitors | Action |
|------|----------|--------|
| `sshd` | SSH authentication failures | Ban after repeated failures |
| `postfix` | Postfix authentication failures | Ban spammers |
| `postfix-sasl` | SASL auth failures | Ban brute-force SMTP auth |
| `dovecot` | IMAP login failures | Ban IMAP brute-force |
| `nginx-http-auth` | nginx basic auth failures | Ban web auth brute-force |
| `nginx-botsearch` | Requests for common exploit paths | Ban vulnerability scanners |

### Current Statistics (as of setup documentation)

- **SSH jail**: Typically 100+ IPs banned at any time, ~1900+ total bans historically
- **Total failed SSH attempts**: 8500+

### Step-by-Step: Fail2Ban Setup

1. **Install**:
   ```bash
   apt install fail2ban
   ```

2. **Create local config** (never edit the default files):
   ```bash
   cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
   ```

3. **Configure jails** in `/etc/fail2ban/jail.local`:
   ```ini
   [sshd]
   enabled = true
   port = ssh
   filter = sshd
   maxretry = 5
   bantime = 3600

   [postfix]
   enabled = true

   [dovecot]
   enabled = true

   [nginx-http-auth]
   enabled = true

   [nginx-botsearch]
   enabled = true
   ```

4. **Restart and verify**:
   ```bash
   systemctl restart fail2ban
   fail2ban-client status
   ```

## 4. Nginx Security

### Rate Limiting

Three rate-limiting zones protect against abuse:

```nginx
limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=api:10m rate=5r/s;
limit_req_zone $binary_remote_addr zone=sensitive:10m rate=2r/s;
limit_req_status 429;
```

### Security Headers

All responses include:

```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Frame-Options DENY;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
```

### HTTPS Enforcement

Port 80 redirects all traffic to HTTPS, except `.well-known` endpoints required for AI discovery and Let's Encrypt validation.

## 5. Anti-Spam (rspamd)

Rspamd provides content-based spam filtering for inbound email:

- Integrates with Postfix via milter protocol
- Uses Redis for Bayesian learning and rate limiting
- Works alongside OpenDKIM for DKIM verification

## 6. Rootkit Detection

`chkrootkit` runs daily via systemd timer to scan for known rootkits:

```
chkrootkit.timer → chkrootkit.service
Schedule: daily at 06:00
```

## 7. System Monitoring (sysstat)

`sysstat` collects performance data every 10 minutes:

- CPU, memory, disk I/O, network statistics
- Data retained for historical analysis
- Collected via `sysstat-collect.timer`
- Daily summary via `sysstat-summary.timer`

## 8. Canonical Livepatch

Snap-based Canonical Livepatch applies critical kernel security fixes without requiring a reboot — essential for an autonomous server that must never reboot itself.

## Security Principles

1. **Least privilege**: Services run as dedicated users (marvin, www-data)
2. **Default deny**: Firewall blocks everything not explicitly allowed
3. **Defense in depth**: Multiple layers (firewall → fail2ban → rate limiting → application logic)
4. **No passwords**: SSH key-only authentication
5. **Automatic patching**: Security updates applied without human intervention
6. **Never reboot**: Marvin cannot safely recover from a bad reboot alone
7. **Log everything**: All agent actions are logged for audit

---

*Previous: [Automatic Upgrades](Automatic-Upgrades.md) · Next: [Email and DNS](Email-and-DNS.md)*
