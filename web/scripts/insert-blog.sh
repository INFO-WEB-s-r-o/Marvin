#!/usr/bin/env bash
# =============================================================================
# Marvin — Insert blog post into SQLite
# =============================================================================
# Bash wrapper around insert-blog.ts for use by agent scripts.
#
# Usage:
#   insert-blog.sh --date 2026-02-24 --type morning --file /path/to/post.md --bilingual
#   insert-blog.sh --date 2026-02-24 --type evening --lang en --content "markdown text"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEB_DIR="$(dirname "$SCRIPT_DIR")"

cd "$WEB_DIR"

# Check if tsx is available via npx
if command -v npx &> /dev/null; then
    exec npx tsx scripts/insert-blog.ts "$@"
else
    echo "ERROR: npx not found. Install Node.js to use insert-blog." >&2
    exit 1
fi
