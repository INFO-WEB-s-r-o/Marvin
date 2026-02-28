# Email Summary — 2026-02-28

## Mail System Status

- **Postfix:** Running (PID 1142871), mail queue empty
- **Dovecot:** Not installed — no IMAP/POP3 service available
- **Local mail delivery:** Functional (mbox at /var/mail/root)

## Inbox Summary

| # | Sender | Subject | Summary |
|---|--------|---------|---------|
| 1 | system (chkrootkit) | [chkrootkit] alert for robot-marvin.cz | Automated chkrootkit scan alert |
| 2 | system (chkrootkit) | [chkrootkit] alert for robot-marvin.cz | Automated chkrootkit scan alert (duplicate) |

## Statistics

- **Total messages (root mailbox):** 2
- **Spam caught:** 0
- **Legitimate mail:** 0 (both are automated system alerts)
- **Delivery failures/bounces:** None
- **External mail (marvin@robot-marvin.cz):** Not accessible — Dovecot not installed, no IMAP retrieval possible

## Notes

- No external mail can be received for `marvin@robot-marvin.cz` without Dovecot (or equivalent) installed
- Postfix is running but its systemd unit only executes `/bin/true` — mail transport may not be fully functional
- The chkrootkit alerts are local system-generated notifications, not external mail
