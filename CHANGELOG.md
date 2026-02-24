# Changelog

All notable changes to the Marvin Experiment are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **Dashboard migrated from static HTML/CSS/JS to Next.js 14** (TypeScript, App Router) — nginx now proxies pages + blog API to Node.js on port 3000; static JSON APIs still served directly by nginx
- Blog posts now stored in **SQLite** (better-sqlite3) with calendar date picker for browsing morning/evening posts
- Agent scripts (morning-check, evening-report) now **dual-write** blog to both markdown files and SQLite
- Blog section header changed from `$ cat /var/log/marvin/blog` to `$ marvin --blog --calendar`
- CLAUDE.md updated to reflect Next.js architecture (replaces "no frameworks" convention)

### Added

- Terminal-themed calendar component for browsing blog posts by date
- Blog API routes: `GET /api/blog`, `GET /api/blog/[date]`, `POST /api/blog-insert`
- SQLite schema and migration script for importing existing markdown blog files
- `scripts/insert-blog.sh` — CLI tool for agent scripts to insert posts into SQLite
- Content-Security-Policy headers in Next.js config
- Input validation on all API route parameters (date, month format)

### Security

- Removed hardcoded fallback secret from blog-insert API — `BLOG_INSERT_SECRET` env var is now required

### Added

- `agent/disk-cleanup.sh` — automated disk hygiene: removes old compressed logs (>30d), apt cache, stale run logs (>14d), old metrics (>90d), temp files, and vacuums systemd journal to 7 days
- Runaway process monitoring in `health-monitor.sh` — tracks processes exceeding 50% CPU across health check intervals, auto-kills after 10 minutes sustained; excludes known-good processes (claude, apt, node)

### Fixed

- `log-export.sh`: added EXIT trap to always return git to `main` branch, preventing repo from being stranded on `data/*` branches after failures
- `common.sh`: `run_claude` now pipes prompt via stdin instead of shell argument, fixing "Argument list too long" error that broke log-analysis agent with large prompts
- `health-monitor.sh`: empty `ISSUES` array no longer produces `[""]` in `data/status.json`; correctly outputs `[]` when healthy
- Removed invalid `data/comms/log-analysis-2026-02-23.json` (contained raw log output from the failed agent run, not valid JSON)

### Added

- `agent/self-test.sh` — validates all scripts syntax, JSON files, services, metrics, and git health (34 automated checks, graded A-F)
- CLAUDE.md project instructions for Claude Code (root + .github/)
- Claude Code GitHub Action for automated PR code & security review
- CHANGELOG.md to track all project changes
- GPG signing for git commits (RSA 4096, autonomous)
- GitHub API integration (`agent/lib/github.sh`) for issues, PRs, comments
- GitHub interaction agent (`agent/github-interact.sh`) at 09:00/21:00 UTC
- Morning git pull + sync-and-learn cycle (`agent/prompts/sync-learn.md`)
- Protocol negotiation listener (`agent/negotiate-listener.sh`)
- Email server prompt for future VPS setup (`agent/prompts/email-server.md`)
- Log analysis prompt (`agent/prompts/log-analysis.md`)
- CODEOWNERS file (@pavelstancik)
- Pavel Stančík / INFO WEB s.r.o. credit on dashboard and README
- Czech (CS) i18n support for web dashboard

### Changed

- Log watcher: nginx logs now filtered through 3-phase pipeline (SSH/attacks, web noise, interest patterns) reducing Claude API waste from dashboard polling
- Self-enhance: dynamically includes all agent scripts in context instead of hardcoded 5, giving enhancement sessions full codebase visibility
- MARVIN_DIR moved from `/opt/marvin` to `/home/marvin/git`
- Hostname set to `robot-marvin.cz` via variable (not hardcoded)
- GPG wrapper uses interpolated `${MARVIN_DIR}` instead of hardcoded path
- `negotiate-listener.sh` sources `common.sh` instead of duplicating MARVIN_DIR
- Content-length validation hardened in negotiate listener (pre-read cap)
- Fixed executable permissions on agent and setup scripts
- claude-review.yml: review output now posted as PR comment

### Security

- Fine-grained GitHub PAT (repo-scoped, minimal permissions)
- Content-length validated before body read to prevent oversize payloads
- SSH excluded from inter-AI communication scanning
