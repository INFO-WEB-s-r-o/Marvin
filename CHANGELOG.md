# Changelog

All notable changes to the Marvin Experiment are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security

- **Restrict public access to sensitive data** — added nginx deny rules for `/api/security/` and `/api/email/` directories. Security scan results (port inventories, CVE status, rootkit scans) and email metadata (sender/subject) were publicly accessible via the `/api/` catch-all alias. Now return 403. Other API data (metrics, status, exports, comms) remains public. (closes #117, #120)

### Fixed

- **Process count anomaly false positives** — process count was triggering 6-8 false anomaly alerts per day because the 7-day rolling stddev (2.80) was much tighter than actual intraday range (149-172). Changed direction to "high" (low process count is never concerning) and added min_threshold=200 (process counts under 200 are normal for a 2-vCPU server). Reduces noise from ~8 alerts/day to near zero while still detecting genuine fork bombs or runaway spawning.
- **File integrity baseline** — updated baseline after legitimate changes from merged PRs (common.sh, health-monitor.sh) were triggering persistent false-positive alerts since 2026-03-09.

### Added

- **Weekly analytics report** (`agent/weekly-analytics.sh`) — data-driven weekly report with system metrics trends, Claude API usage stats, log error analysis, security summary, SLA tracking, and enhancement activity. Generates both JSON (`data/reports/weekly-YYYY-MM-DD.json`) and human-readable markdown digest. Includes week-over-week comparison deltas. Runs Sundays at 11:30 UTC via cron. No Claude API calls — pure data aggregation.
- **Network I/O metrics** in `collect_metrics()` — tracks bytes/packets received/transmitted on primary network interface via `/proc/net/dev`. Adds `network` field to all metrics JSON, feeding into the existing JSONL time-series pipeline for bandwidth monitoring.

- **Metric anomaly detection** in `health-monitor.sh` — compares current CPU, memory, load, and process count against 7-day rolling average from daily summaries. Alerts when any metric deviates by more than 2σ. Needs 3+ days of daily data to activate. Writes `data/metrics/anomaly-status.json` for dashboard consumption

### Security

- **Kernel version masking** in `common.sh` — `collect_metrics()` now strips the distro-specific build suffix from `uname -r` (e.g. `6.8.0-101-generic` → `6.8.0`). The full string was publicly served via `data/status.json` and `data/metrics/latest.json`, enabling targeted CVE fingerprinting (closes #41)

### Fixed

- **Anomaly detection noise reduction** — CPU% and Load 1m were triggering false anomalies every 30 minutes. Added directional filtering (only alert on high CPU/Load, not low — idle is always fine) and minimum absolute thresholds (CPU must be >40% and Load must be >2x vCPUs before anomaly triggers). Memory and process count remain bidirectional.
- **fix-issues.sh data/ false positive** — validation was checking all modified files including `data/` files changed by concurrent cron jobs (health-monitor every 5 min). Narrowed `CHANGED` to only track `agent/`, `web/`, and `*.md` files that are actually staged.
- **fix-issues.sh cleanup trap unmerged state** — cleanup trap's `git checkout -- .` failed on unmerged files from stash pop conflicts, leaving repo stuck on fix branches. Added `git reset HEAD` before checkout to clear unmerged index state.
- **Git unmerged files** — resolved stuck `fix/issues-*` branch with unmerged `health-monitor.sh` that was blocking `morning-check.sh` git pull. Restored main, fast-forwarded to origin, cleaned up stale branches
- **Merge conflict in file-integrity.sh** — resolved <<<<<<< conflict markers from stash/pop collision during morning-check. Added caller tracking to `--update` mode (logs which process triggered baseline reset with PID)
- **ps false positive in runaway detection** — despite case-statement exclusion, `ps` at 100% was logged ~30 times/day. Added awk pre-filter in the pipeline to exclude `ps`/`awk`/`sort` before the while loop
- **Git repo health**: resolved stuck rebase on `fix/issues-*` branch with stale REBASE_HEAD, cleaned 27 stale local branches accumulated from merged PRs, fast-forwarded main to origin
- **File integrity baseline**: updated after upstream pulls
- **Runaway process detection**: added `fail2ban*` to exclusion list in `health-monitor.sh` (it flags itself during monitoring). Removed `curl` and `git*` from exclusions after review — the 10-minute tracking window handles their transient spikes while preserving detection of genuinely stuck or malicious processes (PR #144, review fixes for #147)
- **self-test.sh security scoring**: replaced fragile manual JSON string construction with `jq` (issue #87 fix, PR #144). Uses atomic write via `.tmp` + `mv` to prevent truncation on jq failure (review fix)
- **about.json**: fixed broken JSON from heredoc newline in `born` field

### Added

- **Claude API usage tracking**: `run_claude()` in `common.sh` now logs each run to date-sharded `metrics/claude-usage-YYYY-MM-DD.jsonl` files with task name, duration, prompt/output char counts, and exit code. Date-sharding prevents unbounded file growth (Phase 2 roadmap, PR #144, review fix)
- **Automatic stale branch cleanup** in `agent/morning-check.sh` — daily cleanup of local branches whose remote counterpart was deleted (PR merged/closed). Safely deletes merged branches; force-deletes unmerged branches older than 7 days with no remote. Prevents the branch accumulation problem (27 branches found today)

### Security

- **CUPS snap removed** — was disabled previously (port 631 bound to 0.0.0.0). Now fully removed via `snap remove cups` since VPS has no printing needs
- **CUPS snap disabled** — port 631 was bound to 0.0.0.0 (all interfaces), exposing the printing service to the internet. A VPS doesn't need CUPS. Disabled via `snap disable cups`. Removed from expected ports in `security-scan.sh`

### Fixed (previous)

- **agent/morning-check.sh**: added stash/pop around git pull to prevent failures from dirty working tree. Fix-issues.sh or self-enhance may leave uncommitted edits that block `git pull --rebase`. Now stashes local changes before pulling and restores them after. Tracks whether stash was actually created to avoid false pop attempts (#131) (PR #130)
- **agent/health-monitor.sh**: committed issue #37 fix — removed `node` and `npm` from runaway process exclusion list (was left uncommitted by fix-issues.sh, causing pull failures)
- **agent/health-monitor.sh**: removed duplicated swap management logic — the `else` branches for both swap creation and expansion were retrying the identical `dd`/`mkswap`/`swapon` commands that just failed, which is pointless. Now logs error on first failure instead
- **File integrity baseline**: updated after legitimate changes

### Added

- **SLA / uptime tracking** in `agent/metric-aggregate.sh` — calculates daily uptime percentage from health check sample counts (expected 288 samples/day at 5-min intervals). Tracks last 30 days with per-day breakdown, overall uptime %, worst/best day, and days at 100%. Output at `data/metrics/sla.json`
- **SSL certificate expiry monitoring** in `agent/health-monitor.sh` — checks TLS certs on HTTPS (443), SMTPS (465), and IMAPS (993) every 5 minutes. Warns at <14 days, critical at <7 days. Adds `ssl_min_days` to `data/status.json` for dashboard visibility
- **Data retention policy** in `agent/disk-cleanup.sh` — gzip-compresses raw metrics JSONL files older than 30 days (preserving data for analysis), deletes compressed files after 180 days. Replaces the previous 90-day hard delete. Daily/hourly summaries kept indefinitely
- **agent/email-manage.sh** — daily email housekeeping for `marvin@robot-marvin.cz`: inbox summary (counts only — sender details redacted from public JSON), Rspamd spam statistics, 14-day email retention cleanup (7 days for Junk/Trash), mail service health checks (postfix, dovecot, rspamd, redis, opendkim), stuck queue message flushing, and SSL certificate expiry monitoring
- **Morning prompt**: instructions to read emails from Maildir, respond to creator's emails in character, and move processed mail to `cur/`

### Security

- **setup/install-claude.sh**: fixed critical shell injection — `${RESULT}` (raw Claude output) was embedded in a Python triple-quoted string, allowing arbitrary code execution if output contained `'''`. Replaced entire logging block with `jq` for safe JSON construction (#127)
- **agent/lib/github.sh**: removed PAT from `.git/config` — `github_setup_remote()` no longer embeds `${GITHUB_TOKEN}` in the remote URL. Uses a credential helper instead to avoid plaintext token persistence (#128)
- **setup/bootstrap.sh**: replaced `curl | bash` Node.js install with GPG-verified apt repository to prevent executing unverified remote scripts as root (#128)
- **setup/bootstrap.sh**: removed PAT from remote URL in bootstrap GitHub setup, consistent with github.sh fix

### Fixed

- **agent/email-manage.sh**: added `head -1` to `queue_count` parsing to prevent multi-line values from breaking arithmetic test
- **git repo state**: resolved divergence (1 local commit vs 6 remote) — local main had a data file commit that shouldn't be tracked, plus stale merge conflict markers in `agent/lib/github.sh`. Reset to origin/main which has the correct `marvin_gpg_key_id()` with `--homedir` fix
- **security baselines**: updated rkhunter file properties database and file-integrity baseline to clear false positive alerts from email server installation (dovecot, redis, rspamd users)
- **agent/health-monitor.sh**: fixed blog markdown 404 false positive — check was assuming today's evening blog post exists, but that file is only created at ~21:00 UTC. Now checks the latest evening file that actually exists on disk instead of constructing a URL from the API date

### Added

- **Open port monitoring** in `agent/security-scan.sh` — maintains expected port baseline (SSH, HTTP, HTTPS, SMTP, IMAP, Next.js, Redis, Rspamd, CUPS), alerts on unexpected listeners with process info, saves port inventory to `data/security/port-inventory.json`. Unexpected ports now contribute to overall security scan `warnings` status
- **GitHub issue #121**: email server DNS records documentation — MX, SPF, DKIM, DMARC records verified as already configured by Pavel. Test email sent successfully with DKIM signature to both local and external (Outlook) recipients

---

- **agent/lib/github.sh**: resolved merge conflict markers (again) in `marvin_gpg_key_id()` — recurring stash/pull collision. Also resolved 10 unmerged `data/*.json` ghost entries from PR #103 and unstaged accidentally tracked `web/nextjs.log`
- **agent/log-export.sh**: fixed malformed JSON in export bundles — `enhancement_log` field used `.json` glob but enhancement files are `.md`, producing `[]\n[]` which broke JSON validity. Changed to `find ... -name "*.md"` with proper `jq` list construction. Repaired corrupted exports for 2026-02-28 and 2026-03-01

### Added

- **CVE monitoring** in `agent/security-scan.sh` — checks for pending security updates via `apt list --upgradable`, identifies security-specific packages, queries `ubuntu-security-status` for ESM coverage, and tracks `unattended-upgrades` auto-patch history. Outputs `data/security/cve-status.json`. Pending security updates now contribute to overall security scan `warnings` status

---

### Fixed

- **agent/lib/github.sh**: resolved merge conflict markers (`<<<<<<< Updated upstream`) in `marvin_gpg_key_id()` function — stash/pull collision left conflict markers that would cause bash syntax errors on any GPG signing operation
- **git repo state**: cleaned up stale data file tracking left from PR #103 (stop tracking runtime data). Accepted deletions for 10 `data/*.json` files that were still in git index. Added `web/*.log` to `.gitignore`

- **agent/lib/github.sh**: Root cause fix for recurring issue #39 — `gpg-info.json` was missing, and GPG keyring lookup failed because cron runs as root but the GPG key lives in `/home/marvin/.gnupg/`. Created `gpg-info.json` with correct key ID, exported public key to `marvin-gpg-public.asc`, added `--homedir /home/marvin/.gnupg` to all GPG operations as fallback.
- **agent/lib/github.sh**: properly resolved stale merge conflict in `marvin_gpg_key_id()` and applied `marvin_sign()` key ID fix from issue #39 — the previous session's fix attempt (commit c1c1a8e) left conflict markers in the committed code that a failed rebase then exposed in the working tree. Aborted stuck rebase, fast-forwarded to origin/main, and cleanly applied the fix.

### Added

- **Email server (Phase 1)** — Full email stack for `robot-marvin.cz`:
  - Postfix configured with Let's Encrypt TLS (was using snakeoil certs), submission (587) and SMTPS (465) ports enabled with SASL authentication
  - Dovecot IMAP installed and configured — IMAPS on port 993, TLSv1.2+ only, Maildir storage, LMTP delivery from Postfix, SASL auth socket for Postfix
  - Rspamd spam filter installed with Redis backend — Bayes autolearning, greylist at score 4, header marking at 6, subject rewrite at 8, reject at 15
  - OpenDKIM already configured and verified signing outgoing mail
  - Fail2ban jails added for postfix, postfix-sasl, and dovecot (3 new jails)
  - UFW firewall opened for ports 465 (SMTPS), 587 (Submission), 993 (IMAPS)
  - Verified: TLSv1.3 on all ports, DKIM signatures on outgoing mail, no open relay, Maildir delivery working
- **agent/cve-monitor.sh** — CVE and security update monitoring using Ubuntu Pro `security-status` (primary) and `apt` (fallback). Tracks vulnerable packages, pending security updates, kernel version currency, reboot requirements, and unattended-upgrades status. Outputs JSON to `data/security/cve-status.json` with JSONL history for trend tracking. Integrated into `security-scan.sh` daily run.

- **agent/metric-aggregate.sh** — aggregates raw 5-minute JSONL metrics into hourly (24 buckets with min/avg/max for CPU, memory, swap, disk, load, processes, fail2ban), daily (full-day summary with p95 CPU, disk delta, fail2ban net change), and rolling 7-day weekly summaries. Integrated into `log-export.sh` daily run. Served at `/api/metrics/YYYY-MM-DD-hourly.json`, `/api/metrics/YYYY-MM-DD-daily.json`, `/api/metrics/weekly-summary.json`

---

### Fixed

- **github-interact.sh**: added `git fetch origin main` before checking `origin/main..main` for unpushed commits — prevents stale ref from causing repeated false push failures for hours (diagnosed from 10-hour push failure loop on 2026-02-28 where PR merge on GitHub updated origin/main but local ref was stale)
- **github-interact.sh**: push failure now captures and logs the actual git error output instead of just "Failed to push"
- **common.sh**: `run_claude()` exit code capture was broken — `|| true` on the claude command made `$?` always return 0, masking actual failures. Now uses `&& exit_code=$? || exit_code=$?` pattern to preserve the real exit code while preventing set -e from killing the script. Also logs a warning when Claude exits non-zero.
- **log-export.sh**: added stale branch cleanup after successful PR merge — removes old merged `data/*`, `fix/*`, and `enhance/*` branches both locally and on the remote. Prevents branch accumulation (18 stale local + 6 stale remote branches were found). Skips today's and yesterday's branches, prunes orphaned remote tracking refs.

### Added

- OpenAPI 3.0 specification for Marvin's log export and status API (`data/openapi.yaml`). Documents all 10 public endpoints including exports, status, metrics, blog, communications, and security scoring. Served at `/.well-known/openapi.yaml`.
- `agent/file-integrity.sh` — SHA-256 file integrity monitoring for 21 critical system and agent files. Creates baseline on first run, alerts on unexpected changes. Integrated into `security-scan.sh` daily run. Supports `--update` flag for re-baselining after legitimate changes. Monitors SSH, nginx, firewall, fail2ban, cron, and core agent scripts.
- Gzip compression for export bundles — `log-export.sh` now generates `.json.gz` alongside `.json` files. Nginx `gzip_static` serves pre-compressed files when clients support it. Also enabled `gzip_vary`, `gzip_types` in nginx.conf for dynamic compression of JSON, YAML, CSS, and JS responses.

### Fixed

- `weekly-enhance.sh` Test 5 used `python3` for JSON validation — replaced with `jq empty` for consistency with the rest of the codebase (and `python3` may not always be available)
- `weekly-enhance.sh` Test 10 checked for `index.html` which no longer exists after Next.js dashboard migration — now checks `package.json` first (matching `self-test.sh` and `update-website.sh`)
- **GitHub push divergence**: local `main` diverged from `origin/main` after PR #89 was merged while local had uncommitted data commits. Rebased local onto origin, restoring push capability after 10+ hours of hourly failures.

### Added

- Security scoring system in `self-test.sh` — grades the server A-F (0-100 points) across 7 security dimensions: SSH root access, firewall, fail2ban jails, SSL certificate validity, unattended-upgrades, rootkit scan results, and password authentication. Outputs `data/security/security-score.json` for dashboard consumption.
- `agent/security-scan.sh` — daily rootkit and security scanning via rkhunter + chkrootkit. Runs at 04:00 UTC, produces JSON reports at `data/security/latest-scan.json` with rootkit findings, world-writable file counts, SUID/SGID binary counts, and listening port counts. Old scan reports auto-cleaned after 30 days.

### Fixed

- **morning-check.sh**: git pull race condition — `health-monitor.sh` writes to `data/status.json` every 5 minutes, dirtying the working tree between `git stash` and `git pull`, causing pulls to fail whenever upstream has new commits. Fix: discard local `data/` changes before pulling (they're regenerated every 5-15 minutes by cron) instead of stashing.
- **self-test.sh**: dashboard check looked for `index.html` which no longer exists after Next.js migration — now checks `package.json` first.
- **Cron schedule**: `github-interact.sh` and `hourly-check.sh` both ran at `:00` every hour, causing two concurrent Claude API calls. Staggered to `:05` and `:35` respectively.

### Fixed (previous)

- **update-website.sh**: called nonexistent `log` function instead of `marvin_log` — silently errored every 15 minutes on every cron run
- **update-website.sh**: checked for `index.html` which doesn't exist in Next.js dashboard — now checks `package.json` instead
- **health-monitor.sh**: `dpkg` pattern didn't match `dpkg-preconfigure` (truncated by ps) — changed to `dpkg*` wildcard; also added `jq` to exclusion list since it's called by the monitoring logic itself

### Security

- **Nginx rate limiting**: three-tier `limit_req` zones — general (10r/s burst 20), API (5r/s burst 10), sensitive endpoints like negotiate and blog-insert (2r/s burst 5). Returns HTTP 429 instead of 503. Applied to all location blocks in site config.
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
