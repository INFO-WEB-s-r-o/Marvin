# Changelog

All notable changes to the Marvin Experiment are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `agent/security-scan.sh` — daily rootkit and security scanning via rkhunter + chkrootkit. Runs at 04:00 UTC, produces JSON reports at `data/security/latest-scan.json` with rootkit findings, world-writable file counts, SUID/SGID binary counts, and listening port counts. Old scan reports auto-cleaned after 30 days.

### Fixed

- **health-monitor.sh**: `dpkg-preconfigu` (and other `dpkg-*` subprocesses) were triggering false positive runaway process warnings at 87.5% CPU during package operations. Changed case pattern from exact `dpkg` to glob `dpkg*`. Also added `jq` to known-good exclusion list.

- **CRITICAL**: `log-watcher.sh` JSON corruption recovery — when the daily analysis file became corrupted (from a failed jq merge), every subsequent run failed silently with parse errors indefinitely. Now validates existing JSON before merging, backs up corrupt files, and starts fresh. Also tightened remaining broad interest patterns (`/api/` → `POST /.well-known` and `POST /api/.*negotiate`; removed bare `POST`) and changed truncation log from WARN to INFO.
- **log-export.sh**: cleanup trap now stashes uncommitted changes before switching branches — fixes repo getting stranded on `data/*` branches when other cron jobs (health-monitor, update-website) modify `data/` files between branch creation and script exit
- **log-watcher.sh**: hostname `robot-marvin` was matching the `'marvin'` interest pattern, causing **every single syslog/kern.log/ufw.log entry** to pass the interest filter. Added UFW firewall patterns (`UFW BLOCK`, `IN=.*OUT=.*SRC=.*DST=`) to attack exclusions and replaced broad `'marvin'` with `'marvin\.cz'` and `'marvin@'`. Reduces system log noise from ~6100 false positives/day to near zero.
- **log-watcher.sh**: removed overly broad interest patterns (`'ECHO'`, `'agent'`) that matched TCP flags and User-Agent headers in every log line
- **common.sh**: `run_claude` log calls now redirect to stderr (`>&2`) so they don't leak into captured stdout
- **evening-report.sh**: detects when Claude writes blog files directly via Write tool (instead of returning content in stdout), preserving those files instead of overwriting with summary text
- **morning-check.sh**: same direct-write detection for morning reports

### Added

- Automatic swap management in `health-monitor.sh` — detects RAM pressure (<200MB available) and creates 1GB swap if none exists, or doubles existing swap (up to 2GB) when >80% used. Only triggers under actual memory pressure.
- System noise exclusion layer in log-watcher.sh — filters CRON, systemd, snapd, logrotate entries from non-web logs before interest matching
- Next.js static asset pattern (`GET /_next/`) added to web noise filter
- SSL certificate auto-renewal verified (certbot timer + cron, two domains, 86+ days validity)

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
- Runaway process monitoring in `health-monitor.sh` — tracks processes exceeding 50% CPU across health check intervals, auto-kills after 10 minutes sustained; excludes known-good processes (claude, apt, node, ps)
- Merge conflict marker detection in `agent/self-test.sh` — scans all agent scripts for leftover `<<<<<<<` / `=======` / `>>>>>>>` markers that would break bash parsing
- Verified unattended-upgrades configured with security-only policy (was already in place)

### Fixed

- **CRITICAL**: `health-monitor.sh` had unresolved merge conflict markers on `main` branch (lines 79-94), breaking the script entirely. Resolved by keeping the PID reuse guard from `main`.
- `health-monitor.sh`: added `ps` to known-good process exclusion list — the `ps` command itself was triggering false positive "High CPU process detected" warnings every 5 minutes
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
