#!/usr/bin/env bash
# =============================================================================
# Marvin — Let's Encrypt deploy hook: reload TLS-terminating services
# =============================================================================
# Installed to /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh by
# setup/bootstrap.sh. certbot runs every executable in that directory once, as
# root, AFTER a certificate in the renewal set is successfully renewed (the
# $RENEWED_LINEAGE / $RENEWED_DOMAINS env vars name which lineage renewed).
#
# WHY THIS EXISTS
# ---------------
# certbot renews the certificate *file* on disk, but a long-running TLS service
# keeps the previous certificate in memory until it is reloaded. On 2026-07-08
# dovecot — started 2026-06-21 and never reloaded after the 2026-06-22 renewal —
# was still serving the STALE Apr-23 cert on IMAPS:993, so health-monitor logged
# "IMAPS SSL cert expires in 13 days" 28× over a ~2h window even though the live
# cert on disk had 73 days left. Postfix (short-lived smtpd workers re-read the
# cert per connection) and nginx (its own reload path) were unaffected — so only
# dovecot exposed the gap, but with no deploy hook *nothing guaranteed* any of
# them would pick up a renewal, and the stale dovecot cert would have actually
# EXPIRED on ~2026-07-22 had a manual reload not happened to fire at 20:08 UTC.
# A deploy hook is the documented, deterministic fix for this class.
#
# CONTRACT
# --------
# Best-effort, and NEVER fail the renewal. Each service is reloaded only if it
# is active; a reload failure is logged but the hook still exits 0 — the cert is
# already renewed, and masking that behind a non-zero hook (which certbot would
# report as a renewal failure) helps no one. nginx config is validated before
# reload so a pre-existing bad config can never take the web server down here.
set -uo pipefail

_marvin_log="/home/marvin/git/data/logs/$(date -u +%Y-%m-%d).log"

_log() {
    local level="$1"; shift
    local msg
    msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] letsencrypt-deploy-hook: $*"
    echo "$msg"
    # Best-effort append to Marvin's daily log for observability; never fatal.
    printf '%s\n' "$msg" >> "$_marvin_log" 2>/dev/null || true
}

_reload() {
    local svc="$1"
    if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
        _log INFO "${svc} not active — skipping"
        return 0
    fi
    # nginx: validate config before reloading. A bad config must not take the
    # web server down as a side effect of a cert renewal (mirrors the
    # marvin_nginx_reload philosophy in common.sh).
    if [[ "$svc" == "nginx" ]] && ! nginx -t >/dev/null 2>&1; then
        _log WARN "nginx config test FAILED — not reloading nginx"
        return 0
    fi
    if systemctl reload "$svc" >/dev/null 2>&1 \
        || systemctl try-reload-or-restart "$svc" >/dev/null 2>&1; then
        _log INFO "reloaded ${svc} to pick up renewed certificate"
    else
        _log WARN "failed to reload ${svc} — renewed cert may not be served until next restart"
    fi
}

_log INFO "renewal detected (lineage=${RENEWED_LINEAGE:-unknown}, domains=${RENEWED_DOMAINS:-unknown}) — reloading TLS services"
_reload dovecot
_reload postfix
_reload nginx
exit 0
