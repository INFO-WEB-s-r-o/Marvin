#!/usr/bin/env bash
# =============================================================================
# Marvin — Email Management (runs daily at 05:00 UTC)
# =============================================================================
# Daily email housekeeping for marvin@robot-marvin.cz:
#   - Generate daily email summary (inbox count, senders, subjects)
#   - Log Rspamd spam statistics
#   - Clean up emails older than 14 days
#   - Monitor mail service health (postfix, dovecot, rspamd, redis, opendkim)
#   - Flush stuck queue messages
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

MAIL_USER="marvin"
MAIL_DOMAIN="robot-marvin.cz"
MAIL_ADDRESS="${MAIL_USER}@${MAIL_DOMAIN}"
MAILDIR="/home/${MAIL_USER}/Maildir"
RETENTION_DAYS=14
SUMMARY_DIR="${DATA_DIR}/email"
SUMMARY_FILE="${SUMMARY_DIR}/${TODAY}-email-summary.json"

mkdir -p "$SUMMARY_DIR"

marvin_log "INFO" "=== EMAIL MANAGEMENT STARTING ==="

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Service Health Check
# ─────────────────────────────────────────────────────────────────────────────

check_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "running"
    else
        marvin_log "WARN" "Email service ${svc} is NOT running"
        echo "stopped"
    fi
}

postfix_status=$(check_service postfix)
dovecot_status=$(check_service dovecot)
rspamd_status=$(check_service rspamd)
redis_status=$(check_service redis-server)
opendkim_status=$(check_service opendkim)

# Check mail queue size
queue_count=$(postqueue -p 2>/dev/null | tail -1 | grep -oP '^\d+' || echo "0")
if [[ "$queue_count" == "Mail" || -z "$queue_count" ]]; then
    # "Mail queue is empty" or parse failure
    queue_count=0
fi

# Check certificate expiry
cert_expiry="unknown"
cert_file="/etc/letsencrypt/live/${MAIL_DOMAIN}/fullchain.pem"
if [[ -f "$cert_file" ]]; then
    cert_expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    cert_expiry_epoch=$(date -d "$cert_expiry_date" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    cert_days_left=$(( (cert_expiry_epoch - now_epoch) / 86400 ))
    cert_expiry="${cert_days_left} days"
    if [[ "$cert_days_left" -lt 14 ]]; then
        marvin_log "WARN" "SSL certificate expires in ${cert_days_left} days!"
    fi
fi

marvin_log "INFO" "Services: postfix=${postfix_status} dovecot=${dovecot_status} rspamd=${rspamd_status} redis=${redis_status} opendkim=${opendkim_status}"
marvin_log "INFO" "Mail queue: ${queue_count} messages, cert expires: ${cert_expiry}"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: Inbox Summary
# ─────────────────────────────────────────────────────────────────────────────

inbox_count=0
inbox_messages="[]"

# Count messages across Maildir directories
for subdir in new cur; do
    dir="${MAILDIR}/${subdir}"
    if [[ -d "$dir" ]]; then
        count=$(find "$dir" -type f -print0 2>/dev/null | tr -dc '\0' | wc -c)
        inbox_count=$((inbox_count + count))
    fi
done

# Parse recent messages (last 24 hours) for summary
recent_messages="[]"
cutoff_epoch=$(($(date +%s) - 86400))

for subdir in new cur; do
    dir="${MAILDIR}/${subdir}"
    [[ -d "$dir" ]] || continue

    while IFS= read -r -d '' msgfile; do
        [[ -f "$msgfile" ]] || continue
        file_epoch=$(stat -c %Y "$msgfile" 2>/dev/null || echo "0")
        [[ "$file_epoch" -gt "$cutoff_epoch" ]] || continue

        # Extract basic headers
        from=$(grep -m1 -i '^From:' "$msgfile" 2>/dev/null | sed 's/^[Ff]rom: *//' | head -c 200 || echo "unknown")
        subject=$(grep -m1 -i '^Subject:' "$msgfile" 2>/dev/null | sed 's/^[Ss]ubject: *//' | head -c 200 || echo "(no subject)")
        date_hdr=$(grep -m1 -i '^Date:' "$msgfile" 2>/dev/null | sed 's/^[Dd]ate: *//' | head -c 100 || echo "unknown")

        recent_messages=$(echo "$recent_messages" | jq \
            --arg from "$from" \
            --arg subject "$subject" \
            --arg date "$date_hdr" \
            '. + [{"from": $from, "subject": $subject, "date": $date}]')
    done < <(find "$dir" -type f -print0 2>/dev/null)
done

recent_count=$(echo "$recent_messages" | jq 'length')
marvin_log "INFO" "Inbox: ${inbox_count} total, ${recent_count} in last 24h"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Rspamd Spam Statistics
# ─────────────────────────────────────────────────────────────────────────────

spam_stats="{}"
if command -v rspamc &>/dev/null; then
    rspamc_output=$(rspamc stat 2>/dev/null || echo "")
    if [[ -n "$rspamc_output" ]]; then
        scanned=$(echo "$rspamc_output" | grep -oP 'Messages scanned:\s*\K\d+' || echo "0")
        spam_count=$(echo "$rspamc_output" | grep -oP 'Messages with action add header:\s*\K\d+' || echo "0")
        rejected=$(echo "$rspamc_output" | grep -oP 'Messages with action reject:\s*\K\d+' || echo "0")
        greylist=$(echo "$rspamc_output" | grep -oP 'Messages with action greylist:\s*\K\d+' || echo "0")
        clean=$(echo "$rspamc_output" | grep -oP 'Messages with action no action:\s*\K\d+' || echo "0")

        spam_stats=$(jq -n \
            --argjson scanned "${scanned:-0}" \
            --argjson spam "${spam_count:-0}" \
            --argjson rejected "${rejected:-0}" \
            --argjson greylisted "${greylist:-0}" \
            --argjson clean "${clean:-0}" \
            '{scanned: $scanned, spam_flagged: $spam, rejected: $rejected, greylisted: $greylisted, clean: $clean}')
    fi
fi

marvin_log "INFO" "Rspamd stats: $(echo "$spam_stats" | jq -c '.')"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: Old Email Cleanup (14-day retention)
# ─────────────────────────────────────────────────────────────────────────────

deleted_count=0

for subdir in cur new; do
    dir="${MAILDIR}/${subdir}"
    [[ -d "$dir" ]] || continue

    while IFS= read -r -d '' oldmail; do
        [[ -f "$oldmail" ]] || continue
        rm -f "$oldmail"
        deleted_count=$((deleted_count + 1))
    done < <(find "$dir" -type f -mtime "+${RETENTION_DAYS}" -print0 2>/dev/null)
done

# Also clean Junk/Trash folders (7-day retention for those)
for folder in .Junk .Trash; do
    for subdir in cur new; do
        dir="${MAILDIR}/${folder}/${subdir}"
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' oldmail; do
            [[ -f "$oldmail" ]] || continue
            rm -f "$oldmail"
            deleted_count=$((deleted_count + 1))
        done < <(find "$dir" -type f -mtime +7 -print0 2>/dev/null)
    done
done

if [[ "$deleted_count" -gt 0 ]]; then
    marvin_log "INFO" "Cleaned up ${deleted_count} old email(s)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5: Flush stuck queue messages
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$queue_count" -gt 0 ]]; then
    # Try to flush the queue
    postqueue -f 2>/dev/null || true
    marvin_log "INFO" "Flushed mail queue (${queue_count} messages)"

    # If messages have been stuck for >3 days, delete them
    stuck_ids=$(postqueue -p 2>/dev/null | grep -oP '^\w+[*!]?' | head -20 || echo "")
    for qid in $stuck_ids; do
        qid_clean=$(echo "$qid" | tr -d '*!')
        # Check queue time — delete if older than 3 days
        queue_time=$(postqueue -p 2>/dev/null | grep -A1 -F "${qid_clean}" | grep -oP '\w+ \w+ +\d+ \d+:\d+:\d+' | head -1 || echo "")
        if [[ -n "$queue_time" ]]; then
            queue_epoch=$(date -d "$queue_time" +%s 2>/dev/null || echo "0")
            three_days_ago=$(( $(date +%s) - 259200 ))
            if [[ "$queue_epoch" -gt 0 && "$queue_epoch" -lt "$three_days_ago" ]]; then
                postsuper -d "$qid_clean" 2>/dev/null || true
                marvin_log "INFO" "Deleted stuck queue message: ${qid_clean}"
            fi
        fi
    done
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6: Write Summary JSON
# ─────────────────────────────────────────────────────────────────────────────

jq -n \
    --arg date "$TODAY" \
    --arg timestamp "$NOW" \
    --argjson inbox_total "$inbox_count" \
    --argjson recent_count "$recent_count" \
    --argjson spam_stats "$spam_stats" \
    --argjson deleted "$deleted_count" \
    --argjson queue "$queue_count" \
    --arg cert_expiry "$cert_expiry" \
    --arg postfix "$postfix_status" \
    --arg dovecot "$dovecot_status" \
    --arg rspamd "$rspamd_status" \
    --arg redis "$redis_status" \
    --arg opendkim "$opendkim_status" \
    '{
        date: $date,
        timestamp: $timestamp,
        inbox: {
            total_messages: $inbox_total,
            last_24h: $recent_count
        },
        spam: $spam_stats,
        cleanup: {
            deleted_count: $deleted,
            retention_days: 14,
            junk_trash_retention_days: 7
        },
        queue: {
            pending_messages: $queue
        },
        health: {
            postfix: $postfix,
            dovecot: $dovecot,
            rspamd: $rspamd,
            redis: $redis,
            opendkim: $opendkim,
            cert_expiry: $cert_expiry
        }
    }' > "$SUMMARY_FILE"

# Also update latest summary for dashboard
cp "$SUMMARY_FILE" "${SUMMARY_DIR}/latest.json"

marvin_log "INFO" "Email summary saved: ${SUMMARY_FILE}"
marvin_log "INFO" "=== EMAIL MANAGEMENT COMPLETE ==="
