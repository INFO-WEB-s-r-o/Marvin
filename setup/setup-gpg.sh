#!/usr/bin/env bash
# =============================================================================
# Marvin — GPG Key Setup
# =============================================================================
# Generates a GPG key for Marvin and configures git to use it for signing.
# Also exports the public key for adding to GitHub.
#
# Run once during bootstrap or manually:
#   sudo bash /home/marvin/git/setup/setup-gpg.sh
#
# After running, you need to:
#   1. Add the exported public key to GitHub → Settings → SSH and GPG keys
#   2. Set GITHUB_TOKEN in /etc/environment or .env
# =============================================================================

set -euo pipefail

MARVIN_DIR="${MARVIN_DIR:-/home/marvin/git}"
GPG_DIR="${MARVIN_DIR}/.gnupg"
GPG_EXPORT_DIR="${MARVIN_DIR}/data/comms"

# Prefer explicit override, then /etc/hostname, then hostname -f
HOSTNAME_VAL="${MARVIN_HOSTNAME:-}"
if [[ -z "$HOSTNAME_VAL" ]]; then
    HOSTNAME_VAL=$(tr -d '[:space:]' < /etc/hostname 2>/dev/null)
fi
if [[ -z "$HOSTNAME_VAL" ]]; then
    HOSTNAME_VAL=$(hostname -f 2>/dev/null)
fi
if [[ -z "$HOSTNAME_VAL" ]]; then
    HOSTNAME_VAL=$(hostname 2>/dev/null)
fi
if [[ -z "$HOSTNAME_VAL" ]]; then
    echo "[ERROR] Cannot determine hostname. Set MARVIN_HOSTNAME or configure /etc/hostname before running this script." >&2
    exit 1
fi

MARVIN_EMAIL="marvin@${HOSTNAME_VAL}"
MARVIN_NAME="Marvin (AI Agent)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[MARVIN-GPG]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# =============================================================================
# Pre-checks
# =============================================================================

if ! command -v gpg &>/dev/null; then
    log "Installing GnuPG..."
    apt-get install -y -qq gnupg2 2>/dev/null || {
        error "GnuPG not found and could not install. Please install gnupg2."
    }
fi

# Check if Marvin already has a GPG key
EXISTING_KEY=$(gpg --homedir "$GPG_DIR" --list-secret-keys --keyid-format=long "$MARVIN_EMAIL" 2>/dev/null | grep -oP '(?<=sec\s{3}rsa4096/)[A-F0-9]+' || true)

if [[ -n "$EXISTING_KEY" ]]; then
    log "Marvin already has a GPG key: ${EXISTING_KEY}"
    log "To regenerate, delete ${GPG_DIR} and run again."

    # Still export public key in case it's needed
    gpg --homedir "$GPG_DIR" --armor --export "$MARVIN_EMAIL" > "${GPG_EXPORT_DIR}/marvin-gpg-public.asc"
    log "Public key exported to: ${GPG_EXPORT_DIR}/marvin-gpg-public.asc"
    exit 0
fi

# =============================================================================
# Generate GPG key
# =============================================================================

log "Generating GPG key for Marvin..."
mkdir -p "$GPG_DIR"
chmod 700 "$GPG_DIR"

# Generate key using batch mode (no passphrase — Marvin is autonomous)
cat > /tmp/marvin-gpg-batch << EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${MARVIN_NAME}
Name-Comment: Autonomous AI Server Agent
Name-Email: ${MARVIN_EMAIL}
Expire-Date: 2y
%commit
EOF

gpg --homedir "$GPG_DIR" --batch --gen-key /tmp/marvin-gpg-batch 2>&1
rm -f /tmp/marvin-gpg-batch

# Get the key ID
KEY_ID=$(gpg --homedir "$GPG_DIR" --list-secret-keys --keyid-format=long "$MARVIN_EMAIL" 2>/dev/null | grep -oP '(?<=sec\s{3}rsa4096/)[A-F0-9]+' | head -1)

if [[ -z "$KEY_ID" ]]; then
    # Try alternative parsing
    KEY_ID=$(gpg --homedir "$GPG_DIR" --list-secret-keys --keyid-format=long 2>/dev/null | grep -oP '[A-F0-9]{16}' | head -1)
fi

if [[ -z "$KEY_ID" ]]; then
    error "GPG key generation failed — could not find key ID"
fi

log "GPG key generated: ${KEY_ID}"

# =============================================================================
# Export public key
# =============================================================================

# ASCII armor export (for GitHub)
gpg --homedir "$GPG_DIR" --armor --export "$KEY_ID" > "${GPG_EXPORT_DIR}/marvin-gpg-public.asc"
log "Public key exported to: ${GPG_EXPORT_DIR}/marvin-gpg-public.asc"

# Also export the fingerprint
FINGERPRINT=$(gpg --homedir "$GPG_DIR" --fingerprint "$KEY_ID" 2>/dev/null | grep -oP '[A-F0-9 ]{50}' | head -1 | tr -d ' ')
log "Key fingerprint: ${FINGERPRINT}"

# Save key metadata
cat > "${GPG_EXPORT_DIR}/gpg-info.json" << EOF
{
  "key_id": "${KEY_ID}",
  "fingerprint": "${FINGERPRINT}",
  "name": "${MARVIN_NAME}",
  "email": "${MARVIN_EMAIL}",
  "algorithm": "RSA 4096",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "expires": "2 years from creation",
  "public_key_file": "marvin-gpg-public.asc",
  "purpose": "Git commit signing & proof of Marvin's authenticity"
}
EOF

# =============================================================================
# Configure Git to use GPG signing
# =============================================================================

log "Configuring Git for GPG-signed commits..."
cd "$MARVIN_DIR"

git config user.signingkey "$KEY_ID"
git config commit.gpgsign true
git config tag.gpgsign true
git config gpg.program gpg

# Tell git where the keyring is
git config --global gpg.program gpg
# Set GNUPGHOME for the git signing operations
cat > "${MARVIN_DIR}/.gpg-wrapper.sh" << 'WRAPPER'
#!/usr/bin/env bash
GNUPGHOME="/home/marvin/git/.gnupg" exec gpg "$@"
WRAPPER
chmod +x "${MARVIN_DIR}/.gpg-wrapper.sh"
git config gpg.program "${MARVIN_DIR}/.gpg-wrapper.sh"

log "Git now signs all commits with Marvin's GPG key."

# =============================================================================
# Serve public key via web
# =============================================================================

# Make the public key accessible at /.well-known/marvin-gpg.asc
if [[ -d "${MARVIN_DIR}/web" ]]; then
    mkdir -p "${MARVIN_DIR}/web/.well-known"
    cp "${GPG_EXPORT_DIR}/marvin-gpg-public.asc" "${MARVIN_DIR}/web/.well-known/marvin-gpg.asc"
    log "Public key served at: /.well-known/marvin-gpg.asc"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
log "============================================"
log "  GPG Setup Complete"
log "============================================"
log ""
log "  Key ID:      ${KEY_ID}"
log "  Fingerprint: ${FINGERPRINT}"
log "  Email:       ${MARVIN_EMAIL}"
log ""
log "  Public key exported to:"
log "    ${GPG_EXPORT_DIR}/marvin-gpg-public.asc"
log ""
log "  NEXT STEPS (manual):"
log "  1. Copy the public key and add it to GitHub:"
log "     cat ${GPG_EXPORT_DIR}/marvin-gpg-public.asc"
log "     → GitHub.com → Settings → SSH and GPG keys → New GPG key"
log ""
log "  2. Set up GitHub token:"
log "     echo 'GITHUB_TOKEN=ghp_xxxx' >> ${MARVIN_DIR}/.env"
log ""
log "  3. Add the GPG key to GitHub via API (if token set):"
log "     bash ${MARVIN_DIR}/setup/setup-github.sh"
log "============================================"
