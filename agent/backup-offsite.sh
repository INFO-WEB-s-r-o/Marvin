#!/usr/bin/env bash
# =============================================================================
# Marvin — Off-site Backup Push
# =============================================================================
# Encrypts the most recent local backup (created by backup.sh) with the
# operator's GPG public key, then uploads the ciphertext to a remote SFTP host.
#
# Threat model this addresses (#435):
#   - VPS disk loss / corruption
#   - Provider outage or accidental instance deletion
#   - Root-level compromise that wipes /home/marvin/backups/
#
# Trust boundary:
#   The remote SFTP host is treated as untrusted storage. Files are encrypted
#   to a recipient whose private key is NOT on this VPS, so an attacker who
#   compromises Marvin still cannot read the ciphertext sitting on the remote.
#   That is the whole point — do not "fall back" to encrypting with Marvin's
#   own key.
#
# Configuration (required):
#   BACKUP_OFFSITE_GPG_RECIPIENT   GPG key id or email to encrypt to.
#                                   Must be importable into Marvin's keyring
#                                   before running.
#   BACKUP_OFFSITE_GPG_FINGERPRINT Full 40-char fingerprint of the above key
#                                   (spaces tolerated). Verified against the
#                                   keyring before every encrypt so a rogue key
#                                   imported under the same email/id cannot
#                                   silently divert backups. Obtain with:
#                                     gpg --fingerprint "$RECIPIENT"
#                                   ALWAYS verify the fingerprint with the key
#                                   owner over a separate channel (signal,
#                                   in person) before pinning it here.
#
# Configuration (defaults, override via env):
#   BACKUP_OFFSITE_BACKUP_BASE    $(dirname ${MARVIN_DIR})/backups
#   BACKUP_OFFSITE_SSH_KEY        $(dirname ${MARVIN_DIR})/.ssh/backup_sftp_ed25519
#   BACKUP_OFFSITE_SSH_KNOWN      $(dirname ${MARVIN_DIR})/.ssh/known_hosts
#   BACKUP_OFFSITE_HOST           dev.infowebsro.cz
#   BACKUP_OFFSITE_PORT           22
#   BACKUP_OFFSITE_USER           marvin-backup
#   BACKUP_OFFSITE_REMOTE_DIR     /incoming
#
# Usage:
#   ./backup-offsite.sh                  # encrypt + upload latest backup
#   ./backup-offsite.sh --dry-run        # show what would happen
#   ./backup-offsite.sh --file PATH      # push a specific backup tarball
#
# Exit codes:
#   0 success
#   1 misconfiguration (missing recipient, missing key, no backup found)
#   2 encryption failed
#   3 upload failed
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR

MARVIN_HOME="$(dirname "${MARVIN_DIR}")"
BACKUP_BASE="${BACKUP_OFFSITE_BACKUP_BASE:-${MARVIN_HOME}/backups}"
RECIPIENT="${BACKUP_OFFSITE_GPG_RECIPIENT:-}"
EXPECTED_FP="${BACKUP_OFFSITE_GPG_FINGERPRINT:-}"
SSH_KEY="${BACKUP_OFFSITE_SSH_KEY:-${MARVIN_HOME}/.ssh/backup_sftp_ed25519}"
SSH_KNOWN="${BACKUP_OFFSITE_SSH_KNOWN:-${MARVIN_HOME}/.ssh/known_hosts}"
SFTP_HOST="${BACKUP_OFFSITE_HOST:-dev.infowebsro.cz}"
SFTP_PORT="${BACKUP_OFFSITE_PORT:-22}"
SFTP_USER="${BACKUP_OFFSITE_USER:-marvin-backup}"
REMOTE_DIR="${BACKUP_OFFSITE_REMOTE_DIR:-/incoming}"

marvin_parse_args "$@"
SPECIFIC_FILE=""
NEXT_IS_FILE=false
for arg in "$@"; do
    if $NEXT_IS_FILE; then
        SPECIFIC_FILE="$arg"
        NEXT_IS_FILE=false
        continue
    fi
    case "$arg" in
        --file) NEXT_IS_FILE=true ;;
        --dry-run) ;;
        -h|--help)
            sed -n '2,38p' "$0"
            exit 0
            ;;
    esac
done

# ─── Preflight ───────────────────────────────────────────────────────────────
if [[ -z "$RECIPIENT" ]]; then
    marvin_log "ERROR" "BACKUP_OFFSITE_GPG_RECIPIENT not set — refusing to upload unencrypted"
    echo "Set BACKUP_OFFSITE_GPG_RECIPIENT to the operator's GPG key id/email." >&2
    echo "The key must already be imported into ${GNUPGHOME:-~/.gnupg}." >&2
    exit 1
fi

if ! gpg --batch --list-keys "$RECIPIENT" >/dev/null 2>&1; then
    marvin_log "ERROR" "GPG recipient '${RECIPIENT}' not found in keyring (${GNUPGHOME:-~/.gnupg})"
    echo "Import the recipient's public key first:" >&2
    echo "  gpg --import /path/to/recipient-pubkey.asc" >&2
    exit 1
fi

if [[ -z "$EXPECTED_FP" ]]; then
    marvin_log "ERROR" "BACKUP_OFFSITE_GPG_FINGERPRINT not set — refusing to encrypt to an un-pinned key"
    echo "Set BACKUP_OFFSITE_GPG_FINGERPRINT to the recipient's full 40-char fingerprint." >&2
    echo "  gpg --fingerprint '${RECIPIENT}'" >&2
    echo "Verify it with the key owner on a separate channel before pinning." >&2
    exit 1
fi

# Strip whitespace from operator-supplied fingerprint (gpg prints it space-separated).
expected_fp_clean="${EXPECTED_FP//[[:space:]]/}"
expected_fp_clean="${expected_fp_clean^^}"
if [[ ! "$expected_fp_clean" =~ ^[0-9A-F]{40}$ ]]; then
    marvin_log "ERROR" "BACKUP_OFFSITE_GPG_FINGERPRINT must be a 40-character hex fingerprint (got: ${EXPECTED_FP})"
    exit 1
fi

actual_fp=$(gpg --batch --with-colons --fingerprint "$RECIPIENT" 2>/dev/null \
    | awk -F: '/^fpr/{print $10; exit}')
if [[ "$actual_fp" != "$expected_fp_clean" ]]; then
    marvin_log "ERROR" "GPG fingerprint mismatch for '${RECIPIENT}' — refusing to encrypt"
    echo "Expected: ${expected_fp_clean}" >&2
    echo "Actual:   ${actual_fp:-<empty>}" >&2
    echo "Either the wrong key was imported, or a rogue key was inserted into the keyring." >&2
    exit 1
fi

if [[ ! -r "$SSH_KEY" ]]; then
    marvin_log "ERROR" "SSH key not readable: ${SSH_KEY}"
    exit 1
fi

if [[ ! -r "$SSH_KNOWN" ]] || ! grep -Fq -- "$SFTP_HOST" "$SSH_KNOWN" 2>/dev/null; then
    marvin_log "ERROR" "Host ${SFTP_HOST} not pinned in ${SSH_KNOWN} — refusing TOFU"
    echo "Pin the host key first:" >&2
    echo "  ssh-keyscan -t ed25519 -p ${SFTP_PORT} ${SFTP_HOST} >> ${SSH_KNOWN}" >&2
    exit 1
fi

# ─── Pick source tarball ─────────────────────────────────────────────────────
if [[ -n "$SPECIFIC_FILE" ]]; then
    SOURCE="$SPECIFIC_FILE"
else
    SOURCE=$(ls -1t "${BACKUP_BASE}"/marvin-backup-*.tar.gz 2>/dev/null | head -1 || true)
fi

if [[ -z "$SOURCE" || ! -f "$SOURCE" ]]; then
    marvin_log "ERROR" "No backup tarball found (run agent/backup.sh first)"
    exit 1
fi

source_size=$(stat -c %s "$SOURCE" 2>/dev/null || echo 0)
source_mb=$(( source_size / 1048576 ))
marvin_log "INFO" "Source backup: $(basename "$SOURCE") (${source_mb}MB)"

CIPHER_FILE="${SOURCE}.gpg"
REMOTE_NAME="$(basename "$CIPHER_FILE")"

if marvin_is_dry_run; then
    marvin_log "INFO" "[DRY-RUN] Would encrypt ${SOURCE} -> ${CIPHER_FILE} for recipient ${RECIPIENT}"
    marvin_log "INFO" "[DRY-RUN] Would upload to sftp://${SFTP_USER}@${SFTP_HOST}:${SFTP_PORT}${REMOTE_DIR}/${REMOTE_NAME}"
    exit 0
fi

# ─── Encrypt ─────────────────────────────────────────────────────────────────
# --trust-model always is safe here because the preflight already verified the
# recipient's key fingerprint matches BACKUP_OFFSITE_GPG_FINGERPRINT. Without
# that pin in place this script refuses to run, so by the time we reach this
# line the key identity is explicitly confirmed.
marvin_log "INFO" "Encrypting to ${RECIPIENT} (fp ${expected_fp_clean:0:8}…${expected_fp_clean: -8})..."
gpg_err=$(mktemp)
trap 'rm -f "$gpg_err"; marvin_error_trap' ERR
if ! gpg --batch --yes --trust-model always \
        --recipient "$RECIPIENT" \
        --output "$CIPHER_FILE" \
        --encrypt "$SOURCE" 2>"$gpg_err"; then
    marvin_log "ERROR" "GPG encryption failed: $(cat "$gpg_err")"
    rm -f "$CIPHER_FILE" "$gpg_err"
    exit 2
fi
rm -f "$gpg_err"
trap marvin_error_trap ERR
chmod 600 "$CIPHER_FILE"

cipher_size=$(stat -c %s "$CIPHER_FILE" 2>/dev/null || echo 0)
cipher_mb=$(( cipher_size / 1048576 ))
marvin_log "INFO" "Ciphertext: $(basename "$CIPHER_FILE") (${cipher_mb}MB)"

# ─── Upload ──────────────────────────────────────────────────────────────────
marvin_log "INFO" "Uploading to sftp://${SFTP_USER}@${SFTP_HOST}:${SFTP_PORT}${REMOTE_DIR}/"

# Reject control characters (esp. newlines) and quoting metacharacters in any
# value interpolated into the SFTP batch file. Newlines smuggle an extra SFTP
# command onto their own line (#724). Double quote / backslash would break out
# of the path quoting added below for space-safety (#725).
for _v in REMOTE_DIR CIPHER_FILE REMOTE_NAME; do
    if [[ "${!_v}" == *[[:cntrl:]]* || "${!_v}" == *[\"\\]* ]]; then
        marvin_log "ERROR" "Disallowed character (control / quote / backslash) in ${_v} — refusing to build SFTP batch"
        exit 1
    fi
done
unset _v

sftp_batch=$(mktemp)
trap 'rm -f "$sftp_batch" "$CIPHER_FILE"; marvin_error_trap' ERR
# Paths are double-quoted so spaces in REMOTE_DIR/CIPHER_FILE/REMOTE_NAME are
# parsed as a single SFTP argument. The rejection loop above ensures none of
# the values can contain a `"` or `\` that would close the quoting. See #725.
cat > "$sftp_batch" <<EOF
cd "${REMOTE_DIR}"
put "${CIPHER_FILE}" "${REMOTE_NAME}.part"
rename "${REMOTE_NAME}.part" "${REMOTE_NAME}"
bye
EOF

sftp_output=$(sftp -b "$sftp_batch" \
    -P "$SFTP_PORT" \
    -i "$SSH_KEY" \
    -o "UserKnownHostsFile=$SSH_KNOWN" \
    -o "StrictHostKeyChecking=yes" \
    -o "IdentitiesOnly=yes" \
    -o "BatchMode=yes" \
    "${SFTP_USER}@${SFTP_HOST}" 2>&1) && sftp_exit=0 || sftp_exit=$?

rm -f "$sftp_batch"
# Restore base trap so a stray error past this point cannot delete the
# ciphertext we explicitly preserve for retry on upload failure (#719).
trap marvin_error_trap ERR

if [[ "$sftp_exit" -ne 0 ]]; then
    marvin_log "ERROR" "SFTP upload failed (exit ${sftp_exit}): ${sftp_output}"
    # Leave local ciphertext in place for retry
    exit 3
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
# Ciphertext on disk serves no purpose once it's off-site — and it grows linearly.
rm -f "$CIPHER_FILE"

marvin_log_json "INFO" "backup-offsite" "Off-site backup uploaded" \
    "$(jq -nc --arg src "$(basename "$SOURCE")" \
              --arg dst "${REMOTE_NAME}" \
              --arg host "$SFTP_HOST" \
              --argjson size "$cipher_size" \
              '{source: $src, remote: $dst, host: $host, ciphertext_bytes: $size}')"
