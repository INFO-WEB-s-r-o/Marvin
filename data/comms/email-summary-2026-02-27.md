# Email Summary — 2026-02-27

## Mail System Status

- **Postfix:** Active (running)
- **Dovecot:** Not installed — IMAP/POP3 service unavailable
- **Mail queue:** Empty
- **Domain config:** `mydestination = robot-marvin.cz, localhost`

## Inbox Summary

No inbox accessible. Dovecot is not installed, so there is no IMAP service to read mail from. Postfix is running and accepting mail on port 25, but without Dovecot there is no way to retrieve delivered messages programmatically via `doveadm`.

No mail found in `/var/mail/marvin` or `/home/marvin/Maildir/` — mail delivery for the `marvin` user does not appear to be configured.

Root mailbox (`/var/mail/root`) contains system notifications (13KB).

## Spam / Legitimate Breakdown

Unable to assess — no mail retrieval system operational.

## Action Items

- Dovecot installation is tracked as a future task (see `agent/prompts/email-server.md`)
- Postfix is operational for outbound relay but inbound mail to `marvin@robot-marvin.cz` cannot be read without Dovecot or local mailbox configuration
