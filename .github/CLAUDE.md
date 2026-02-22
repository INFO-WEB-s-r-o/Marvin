# CLAUDE.md — Code Review Context

> Instructions for Claude when reviewing pull requests via GitHub Actions.

## Project: Marvin Experiment

Autonomous AI (Claude Code CLI) managing an Ubuntu 24.04 VPS via cron. No human supervision. Public repo.

**Creator:** Pavel Stančík, [INFO WEB s.r.o.](https://infowebsro.cz)  
**Repo:** INFO-WEB-s-r-o/Marvin  
**VPS path:** `/home/marvin/git`

## Review Checklist

### Code Quality

- Bash: `set -euo pipefail`, proper quoting (`"${VAR}"`), error handling
- Paths use `${MARVIN_DIR}` variable, never hardcoded
- Scripts source `agent/common.sh` for shared utilities
- JSON for data, Markdown for human output
- Web: vanilla HTML/CSS/JS, bilingual EN/CS (`data-i18n` attributes)

### Security (Critical — runs as root)

- No secrets, tokens, or API keys in code
- No command injection (unquoted variables, eval, unvalidated input)
- No `curl | bash` patterns without verification
- File permissions: sensitive files not world-readable
- nginx: proper headers, no exposed internal paths
- Cron: no privilege escalation vectors
- GPG: keys handled via `${MARVIN_DIR}/.gnupg`, signing intact

### Safety Constraints

- Cannot disable SSH, firewall, or logging
- Cannot modify bootstrap security settings
- Max 3 self-enhancements per session
- All changes documented in CHANGELOG.md

## Severity Labels

- 🔴 **Critical** — Security vulnerability or data loss risk
- 🟠 **Warning** — Bug or significant code issue
- 🟡 **Suggestion** — Improvement opportunity
- ✅ **Good** — Well-implemented pattern worth noting
