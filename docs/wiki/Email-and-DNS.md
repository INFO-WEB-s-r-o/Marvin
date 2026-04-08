# Email and DNS

## Overview

Marvin runs a full email stack: **Postfix** (MTA) + **Dovecot** (IMAP) + **OpenDKIM** (signing) + **rspamd** (spam filtering). This allows the server to send and receive email at `@robot-marvin.cz`.

## 1. DNS Records

The following DNS records are required for a properly configured mail server. Set these in your domain registrar or DNS provider:

### Essential Records

| Type | Name | Value | Purpose |
|------|------|-------|---------|
| **A** | `robot-marvin.cz` | `<server-ip>` | Points domain to the server |
| **MX** | `robot-marvin.cz` | `robot-marvin.cz` (priority 10) | Directs email to this server |
| **PTR** | `<server-ip>` | `robot-marvin.cz` | Reverse DNS (set via hosting provider) |

### Authentication Records

| Type | Name | Value | Purpose |
|------|------|-------|---------|
| **TXT (SPF)** | `robot-marvin.cz` | `v=spf1 mx a ip4:<server-ip> -all` | Authorizes this IP to send mail |
| **TXT (DKIM)** | `mail._domainkey.robot-marvin.cz` | `v=DKIM1; k=rsa; p=<public-key>` | DKIM public key for signature verification |
| **TXT (DMARC)** | `_dmarc.robot-marvin.cz` | `v=DMARC1; p=quarantine; rua=mailto:postmaster@robot-marvin.cz` | DMARC policy |

### Step-by-Step: DNS Setup

1. **Set the A record** pointing your domain to the server IP
2. **Set the MX record** pointing to the same domain
3. **Request a PTR record** from your hosting provider (reverse DNS must match the hostname)
4. **Add SPF**: Create a TXT record — see table above
5. **Add DKIM**: After generating the DKIM key (see below), add the public key as a TXT record
6. **Add DMARC**: Start with `p=none` for monitoring, then move to `p=quarantine` once verified

## 2. Postfix (MTA)

Postfix handles sending and receiving email.

### Key Configuration

```
# /etc/postfix/main.cf (key settings)
myhostname = robot-marvin.cz
mydestination = $myhostname, robot-marvin.cz, localhost
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128

# TLS (mandatory for submission, opportunistic for relay)
smtpd_tls_cert_file = /etc/letsencrypt/live/robot-marvin.cz/fullchain.pem
smtpd_tls_key_file = /etc/letsencrypt/live/robot-marvin.cz/privkey.pem
smtpd_tls_auth_only = yes
smtp_tls_security_level = may

# SASL authentication via Dovecot
smtpd_sasl_auth_enable = yes
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth

# Milters: DKIM signing + rspamd
smtpd_milters = local:opendkim/opendkim.sock, inet:localhost:11332

# Recipient restrictions (anti-spam)
smtpd_recipient_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination,
    check_sender_access hash:/etc/postfix/sender_access,
    permit_dnswl_client list.dnswl.org=127.0.[0..255].[1..3],
    reject_rbl_client zen.spamhaus.org,
    reject_rbl_client bl.spamcop.net

# Delivery to Dovecot
mailbox_transport = lmtp:unix:private/dovecot-lmtp

# Rate limiting
smtp_destination_rate_delay = 1s
smtpd_client_message_rate_limit = 100
smtpd_helo_required = yes
```

### Step-by-Step: Postfix Setup

1. **Install**:
   ```bash
   apt install postfix
   ```
   Select "Internet Site" during configuration. Set system mail name to your domain.

2. **Configure TLS** using Let's Encrypt certificates:
   ```bash
   postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/robot-marvin.cz/fullchain.pem"
   postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/robot-marvin.cz/privkey.pem"
   postconf -e "smtpd_tls_auth_only=yes"
   ```

3. **Enable submission port** (587) in `/etc/postfix/master.cf`:
   ```
   submission inet n       -       y       -       -       smtpd
     -o syslog_name=postfix/submission
     -o smtpd_tls_security_level=encrypt
     -o smtpd_sasl_auth_enable=yes
   ```

4. **Add anti-spam RBLs** to recipient restrictions (see config above).

5. **Restart**:
   ```bash
   systemctl restart postfix
   ```

## 3. Dovecot (IMAP)

Dovecot provides IMAP access and handles local mail delivery via LMTP.

### Key Configuration

```
# Protocols
protocols = imap lmtp

# Mail storage
mail_location = maildir:~/Maildir

# Authentication
auth_mechanisms = plain login
auth_username_format = %Ln

# IMAP over TLS only (port 993)
# Plaintext IMAP disabled

# SASL socket for Postfix
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
```

### Step-by-Step: Dovecot Setup

1. **Install**:
   ```bash
   apt install dovecot-imapd dovecot-lmtpd
   ```

2. **Configure mail location** in `/etc/dovecot/conf.d/10-mail.conf`:
   ```
   mail_location = maildir:~/Maildir
   ```

3. **Configure SSL** in `/etc/dovecot/conf.d/10-ssl.conf`:
   ```
   ssl = required
   ssl_cert = </etc/letsencrypt/live/robot-marvin.cz/fullchain.pem
   ssl_key = </etc/letsencrypt/live/robot-marvin.cz/privkey.pem
   ```

4. **Configure auth** in `/etc/dovecot/conf.d/10-auth.conf`:
   ```
   auth_mechanisms = plain login
   ```

5. **Set up LMTP** for Postfix delivery in `/etc/dovecot/conf.d/20-lmtp.conf`.

6. **Restart**:
   ```bash
   systemctl restart dovecot
   ```

## 4. DKIM (OpenDKIM)

DKIM signs outgoing emails with a private key. Receiving servers verify the signature using the public key published in DNS.

### Configuration

```
# /etc/opendkim.conf
Syslog          yes
Canonicalization relaxed/simple
Mode            sv                              # Sign and verify
Domain          robot-marvin.cz
Selector        mail
KeyFile         /etc/opendkim/keys/robot-marvin.cz/mail.private
Socket          local:/var/spool/postfix/opendkim/opendkim.sock
OversignHeaders From
```

### Step-by-Step: DKIM Setup

1. **Install**:
   ```bash
   apt install opendkim opendkim-tools
   ```

2. **Generate key pair**:
   ```bash
   mkdir -p /etc/opendkim/keys/robot-marvin.cz
   opendkim-genkey -s mail -d robot-marvin.cz -D /etc/opendkim/keys/robot-marvin.cz
   chown opendkim:opendkim /etc/opendkim/keys/robot-marvin.cz/mail.private
   ```

3. **Configure** `/etc/opendkim.conf` (see above).

4. **Publish the public key** in DNS:
   ```bash
   cat /etc/opendkim/keys/robot-marvin.cz/mail.txt
   ```
   Copy the output and create a TXT record at `mail._domainkey.robot-marvin.cz`.

5. **Connect to Postfix** by setting the milter socket:
   ```bash
   postconf -e "smtpd_milters=local:opendkim/opendkim.sock"
   postconf -e "non_smtpd_milters=\$smtpd_milters"
   ```

6. **Restart services**:
   ```bash
   systemctl restart opendkim postfix
   ```

7. **Verify** by sending a test email to `check-auth@verifier.port25.com` or using an online DKIM checker.

## 5. SPF (Sender Policy Framework)

SPF is a DNS TXT record that declares which IPs are authorized to send email for your domain.

### Record Format

```
v=spf1 mx a ip4:<server-ip> -all
```

- `mx`: Allow the MX server to send
- `a`: Allow the A record IP to send
- `ip4:<server-ip>`: Explicitly allow this IP
- `-all`: Reject all other senders (hard fail)

### Step-by-Step

1. Create a TXT record at the root of your domain with the SPF string above
2. Test with `dig TXT robot-marvin.cz` or an online SPF checker

## 6. DMARC

DMARC tells receiving servers what to do when SPF or DKIM checks fail.

### Record Format

```
v=DMARC1; p=quarantine; rua=mailto:postmaster@robot-marvin.cz
```

- `p=quarantine`: Mark failing emails as spam (use `p=none` initially for monitoring)
- `rua=mailto:...`: Receive aggregate DMARC reports

### Step-by-Step

1. Start with `p=none` to monitor without affecting delivery
2. Review reports for a few weeks
3. Move to `p=quarantine` once confident legitimate mail passes checks
4. Optionally move to `p=reject` for maximum protection

## 7. rspamd (Spam Filtering)

rspamd provides content-based spam filtering with machine learning:

- Integrates with Postfix via milter (`inet:localhost:11332`)
- Uses Redis for Bayesian classifier storage and rate limiting
- Provides a web UI for training and statistics

### Step-by-Step

1. **Install**:
   ```bash
   apt install rspamd redis-server
   ```

2. **Configure Postfix** to use rspamd as a milter:
   ```bash
   postconf -e "smtpd_milters=local:opendkim/opendkim.sock, inet:localhost:11332"
   ```

3. **Restart**:
   ```bash
   systemctl restart rspamd postfix
   ```

## 8. Testing Your Setup

After configuring all components, test the complete chain:

1. **Send a test email** to an external address (Gmail, etc.)
2. **Check headers** in the received email for:
   - `DKIM-Signature` header (signing works)
   - `Authentication-Results` showing `dkim=pass`, `spf=pass`, `dmarc=pass`
3. **Use online tools**:
   - [mail-tester.com](https://www.mail-tester.com/) — comprehensive deliverability test
   - [mxtoolbox.com](https://mxtoolbox.com/) — DNS and mail config checker
4. **Check logs** on the server:
   ```bash
   journalctl -u postfix@- --since "1 hour ago"
   journalctl -u opendkim --since "1 hour ago"
   ```

---

*Previous: [Security Hardening](Security-Hardening.md) · Next: [AI Discovery](AI-Discovery.md)*
