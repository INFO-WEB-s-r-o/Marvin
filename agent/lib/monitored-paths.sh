#!/usr/bin/env bash
# =============================================================================
# Marvin — Monitored system paths (single source of truth)
# =============================================================================
# The set of /etc files Marvin watches for tampering. Two consumers need the
# identical set and for years kept their own copy of it:
#
#   agent/file-integrity.sh — checksums them daily and alerts on CHANGED
#   agent/backup.sh         — archives them, so a CHANGED alert has a prior
#                             copy to diff against
#
# The copies drifted, which is the whole point of this file. backup.sh was
# missing /etc/pam.d/sshd, /etc/sudoers, /etc/hosts and /etc/resolv.conf (#944)
# — including the two highest-value files on the list for incident response —
# and it hardcoded the nginx vhosts and fail2ban jails that file-integrity.sh
# globbed, so any site or jail added later would be monitored but never
# archived. A monitored file with no backup is a file whose CHANGED alert can
# only be discharged blind (#943).
#
# Sourcing contract: this file only assigns MARVIN_MONITORED_SYSTEM_PATHS. It
# has no side effects, does not depend on common.sh, and must stay that way —
# file-integrity.sh sources it before it has done anything else.
#
# Note for backup.sh consumers: several entries are symlinks (/etc/resolv.conf,
# everything under sites-enabled/). Checksumming follows a symlink; `tar` does
# not. Resolve with `readlink -f` before archiving or the archive stores a
# dangling link where the content should be.
# =============================================================================

MARVIN_MONITORED_SYSTEM_PATHS=(
    # SSH
    /etc/ssh/sshd_config
    # Firewall
    /etc/ufw/user.rules
    /etc/ufw/user6.rules
    # Fail2ban
    /etc/fail2ban/jail.local
    # Nginx
    /etc/nginx/nginx.conf
    # Cron
    /etc/cron.d/marvin
    # PAM (auth stack)
    /etc/pam.d/sshd
    # Sudoers
    /etc/sudoers
    # Name resolution
    /etc/hosts
    /etc/resolv.conf
)

# nginx vhosts and fail2ban jails are globbed rather than listed: a site or jail
# added later is picked up by both consumers with no edit here, which is the
# drift this file exists to prevent.
for _mp_file in /etc/nginx/sites-enabled/*; do
    [[ -f "$_mp_file" ]] && MARVIN_MONITORED_SYSTEM_PATHS+=("$_mp_file")
done

for _mp_file in /etc/fail2ban/jail.d/*.conf; do
    [[ -f "$_mp_file" ]] && MARVIN_MONITORED_SYSTEM_PATHS+=("$_mp_file")
done

unset _mp_file
