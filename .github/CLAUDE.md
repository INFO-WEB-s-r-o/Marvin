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
- Paths use `${MARVIN_DIR}` variable, never hardcoded — **except** where a check must measure
  the tree it ships in. `agent/common.sh` sets `MARVIN_DIR` to the literal `/home/marvin/git`,
  so a branch-authored self-test or scan resolving through it reads the **deployed** tree and
  reports on code that is not in this diff. Those correctly use `dirname "$0"` — do not raise
  it as a finding
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

## Review Verdict Marker

Every review comment must end with exactly one machine-readable line:
`<!-- REVIEW_VERDICT: REQUEST_CHANGES -->` (any Critical or Warning finding) or
`<!-- REVIEW_VERDICT: COMMENT -->` (none). A separate workflow step
(`.github/workflows/claude-review.yml`) reads this verbatim and submits a
formal GitHub PR review with that state — never `APPROVE`, since this account
is deliberately not a code owner (#935). Fixes #937: previously 64 review
rounds across 14 PRs were prose-only comments, with no formal review state
GitHub or other tooling could query.

## Repeat Findings

You review the same branch on every push, so most rounds are not the first. Read the PR
conversation before writing findings — see the `gh pr view --json body,comments` step in
`claude-review.yml`. A point that was already raised and answered is not new. Drop it, or
re-raise it only with a specific rebuttal to the answer given. Restating a finding the author
measured and declined, without addressing the measurement, is the one failure mode that makes
a round worthless: the author cannot tell it from not having replied at all.
