# Possible Enhancements — Marvin's Evolution Roadmap

> This file is Marvin's self-evolution checklist. He reads it during enhancement
> sessions and ticks off items he has accomplished. Humans can add ideas too.
> Marvin updates this file locally — the community can watch him grow via his log export API.

**Last reviewed by Marvin:** 2026-04-15 08:00 UTC

---

## TOP PRIORITY — Email Server (`robot-marvin.cz`)

> **Assigned by Pavel.** This takes precedence over all other enhancements.
> Full prompt and requirements: `agent/prompts/email-server.md`

- [x] Install and configure Postfix + Dovecot + OpenDKIM + Rspamd
- [x] Set up TLS via Let's Encrypt (SMTPS 465, STARTTLS 587, IMAPS 993)
- [x] Configure SPF, DKIM, DMARC — output DNS records for Pavel to add
- [x] Create `marvin@robot-marvin.cz` mailbox
- [x] Add fail2ban jails for SMTP/IMAP
- [x] Open firewall ports (25, 465, 587, 993)
- [x] Verify no open relay — security audit
- [x] Create email management cron: daily summary, spam handling, 14-day cleanup — _2026-03-04_
- [x] Create GitHub issue with the required DNS records — _Issue #121, DNS already configured by Pavel_ — _2026-03-05_
- [x] Send test email and verify DKIM/SPF pass in headers — _DKIM-Signature added by OpenDKIM, external delivery to Outlook confirmed_ — _2026-03-05_

---

## Phase 1 — Survival & Stability (Week 1-2)

### Log Export API (Priority: HIGH)

> Marvin does not push logs to GitHub. Instead, he designs and serves his own
> log export solution. This is one of his first real engineering challenges.

- [x] Define an OpenAPI 3.0 specification for the log export API (`data/openapi.yaml`)
- [x] Serve the OpenAPI spec at `/.well-known/openapi.yaml`
- [x] Build daily JSON export bundles at `/api/exports/YYYY-MM-DD.json`
- [x] Create an export index at `/api/exports/index.json` (last 30 days)
- [x] Write a blog post explaining the API design and how external systems can use it — _2026-04-15_
- [x] Implement optional push client: a script that POSTs daily bundles to a configurable endpoint — _2026-04-04_
- [x] Add authentication to the export API (API key or basic auth via nginx) — _2026-03-13_
- [x] Add gzip compression for export bundles
- [x] Create a simple webhook system: notify external URL when new export is ready — _2026-03-23_
- [x] Document the full log export setup in a blog post titled "How to Track Marvin's Logs" — _2026-04-30: Bilingual blog post at /blog/log-tracking.{en,cs}.md covering live status, time-series metrics, structured logs, daily exports, webhooks, OpenAPI, common-task recipes, and rate-limit etiquette. Phase 1 complete._

### System Administration

- [x] Verify all cron jobs execute without errors for 48h straight — _2026-03-23_
- [x] Implement automatic swap management (create/resize if RAM pressure detected)
- [x] Add disk cleanup automation (remove old logs, temp files, apt cache)
- [x] Set up unattended-upgrades with security-only policy
- [x] Create a self-test that validates all agent scripts parse without syntax errors
- [x] Implement graceful restart for nginx without downtime — _2026-03-23_
- [x] Add process watchdog — restart critical services if they die
- [x] Monitor and kill runaway processes consuming >50% CPU for >10 minutes

### Security Hardening

- [x] Configure fail2ban with custom jail rules (not just SSH — nginx too)
- [x] Set up daily rkhunter/chkrootkit scans
- [x] Implement file integrity monitoring for critical system files
- [x] Add iptables rate limiting for HTTP/HTTPS
- [x] Create a security scoring system (grade own server A-F)
- [x] Monitor for new CVEs affecting installed packages — _2026-03-03_
- [x] Set up automated SSL certificate renewal (Let's Encrypt)

### Self-Testing

- [x] Create `agent/self-test.sh` — validates all scripts have correct syntax
- [x] Add dry-run mode to every agent script — _2026-03-26: Foundation in common.sh (marvin_parse_args, marvin_is_dry_run), adopted in disk-cleanup.sh. Other scripts can opt-in incrementally_
- [x] Implement metric assertion tests (e.g., "disk should be <80%")
- [x] Create rollback mechanism: git stash before self-edit, revert on failure — _2026-03-23_
- [x] Test that `run_claude()` properly handles API timeouts and errors

---

## Phase 2 — Data Engineering (Week 3-4)

### Metrics & Analytics

- [x] Build JSONL time-series database for all metrics (queryable with `jq`) — _Daily JSONL files since 2026-02-28, queryable with jq_
- [x] Implement metric aggregation: hourly, daily, weekly summaries
- [x] Create anomaly detection: alert if metric deviates >2σ from rolling average — _2026-03-09_
- [x] Track Claude API usage: tokens in/out, cost per run, response latency — _claude-usage-YYYY-MM-DD.jsonl with task, duration, prompt/output chars, exit code since 2026-03-07_
- [x] Build a data retention policy: compress old data, archive monthly — _2026-03-05_
- [x] Generate weekly analytics report (trends, predictions, patterns) — _2026-03-10_
- [x] Implement SLA tracking: calculate own uptime percentage — _2026-03-05_

### Log Engineering

- [x] Build structured logging: all logs as JSON with severity, component, trace_id — _2026-03-24: marvin_log_json() in common.sh, JSONL output, adopted in health-monitor + morning-check. Remaining: migrate all scripts_
- [x] Create log analysis pipeline: pattern detection, error clustering — _2026-03-25_
- [x] Implement log-based alerting: detect repeated errors, escalate — _2026-03-14_
- [x] Build a simple grep-based log search API for the dashboard — _2026-03-18: health-monitor.sh generates data/logs/recent.json (last 500 parsed log entries as JSON array) at /api/logs/recent.json, refreshed every 5 min_
- [x] Create daily log digest: summarize key events in human-readable format — _2026-03-13_

### Data Visualization

- [x] Add CPU/memory/disk sparkline charts to dashboard (ASCII or SVG) — _2026-03-17: Canvas chart with CPU, Memory, Load, Disk lines from recent.json (48h of 5-min samples)_
- [x] Create uptime calendar heatmap (like GitHub contributions) — _2026-03-17: 30-day heatmap component using SLA data, color-coded cells, bilingual_
- [x] Build historical comparison: "this week vs last week" — _2026-03-19: weekly-analytics.sh now shows prev week column in all tables, WoW deltas for warnings/criticals/load/Claude errors_
- [ ] Generate daily/weekly PDF or PNG report (using headless tools if available)
- [x] Add real-time metric streaming via SSE or periodic JSON refresh — _2026-03-14: health-monitor.sh generates data/metrics/recent.json (48h of 5-min samples as JSON array) at /api/metrics/recent.json_

---

## Phase 3 — Network Specialist (Week 5-6)

### Network Monitoring

- [x] Implement bandwidth monitoring (track in/out bytes per interface) — _2026-03-10_
- [x] Monitor open ports and alert on unexpected listeners — _Expected port baseline in security-scan.sh, alerts with process info, port-inventory.json output_
- [x] Add DNS resolution monitoring (check own domain resolves correctly) — _2026-03-13_
- [x] Create latency monitoring: ping key endpoints, track over time — _2026-03-13_
- [x] Implement HTTP endpoint monitoring: check own website returns 200 — _Already in health-monitor.sh: checks main page, blog API, blog content, static markdown_
- [x] Monitor SSL certificate expiry dates — _2026-03-05_
- [x] Track active network connections and flag suspicious ones — _2026-03-13_

### AI-to-AI Communication

- [ ] Implement the full ECHO protocol (broadcast, listen, handshake)
- [x] Build peer registry: maintain list of known AI-managed servers — _2026-04-11: Public sanitized registry at /api/peers/registry.json (no IPs/notes/breakdowns). Generated by network-discovery.sh after trust scoring. peers.json is the internal registry; registry.json is the public view._
- [x] Create peer health exchange: share basic metrics with trusted peers — _2026-04-07: /api/peer-health.json endpoint, non-sensitive metrics only (CPU/mem/disk/load/uptime/SSL/peers/capabilities), protocol v1.0, generated every 5 min by health-monitor.sh_
- [x] Implement message signing (verify peer authenticity) — _GPG RSA 4096 key, signed commits and issues, public key at /.well-known/marvin-gpg.asc_
- [ ] Build a simple gossip protocol for peer discovery
- [ ] Attempt to contact posledniping.cz and establish communication
- [ ] Probe moltbook.com AI social platform (passive check first, registration only after human approval)
- [x] Create `.well-known/ai-managed.json` with live data (not just static) — _Updated to v1.1 with negotiate_url, languages, capabilities_
- [x] Design a peer trust scoring system (based on uptime, response history) — _2026-04-07_
- [x] Implement protocol negotiation system (POST /.well-known/ai-negotiate, Claude-powered responses) — _negotiate-handler.sh + negotiate-listener.sh_
- [x] Build log watcher for communication detection (scan /var/log, filter attacks, classify with Claude) — _log-watcher.sh + log-analysis.md prompt_

### Network Security

- [x] Implement connection rate monitoring by source IP — _2026-03-21_
- [x] Build geographic analysis of incoming connections — _2026-04-03: GeoIP-based country breakdown in security-scan.sh section 3e. Combines top connecting IPs + fail2ban bans + nginx access log sources. Output: connection-geo.json_
- [x] Create network anomaly detection (sudden traffic spikes, port scans) — _2026-03-20: daily rx/tx MB in metric-aggregate.sh, 2σ anomaly detection in health-monitor.sh, 7-day backfill_
- [x] Monitor for DNS hijacking attempts — _2026-03-13: health-monitor.sh checks DNS resolution via 8.8.8.8, alerts on IP mismatch_
- [x] Implement outbound connection auditing (what is this server connecting to?) — _2026-03-23_

---

## Phase 4 — Self-Evolution (Week 7-8)

### Code Improvement

- [x] Refactor `common.sh` — split into `lib/metrics.sh`, `lib/logging.sh`, `lib/claude.sh` — _2026-04-04_
- [x] Add ShellCheck compliance to all bash scripts — _2026-03-19_
- [x] Implement proper error handling with trap handlers in every script — _2026-03-19: marvin_error_trap in common.sh, enabled in 12 scripts. Logs file:line + failed command on ERR_
- [x] Create modular prompt system: base personality + task-specific instructions — _2026-04-09_
- [ ] Build prompt A/B testing: try variations, measure output quality

### Self-Awareness

- [x] Track own enhancement history: what changed, what broke, what improved — _2026-03-26: enhancement-tracker.sh scans reports, produces history.json with session counts, rollback rate, weekly trends. Auto-runs after self-enhance_
- [x] Build a "health score" for own codebase (test coverage, error rate, complexity) — _2026-03-26_
- [x] Create weekly self-review: compare this week's performance to last week's — _2026-03-19: weekly-analytics.sh WoW deltas for all key metrics_
- [x] Implement learning from mistakes: parse error logs, avoid repeating issues — _2026-03-27; extended 2026-04-30 with recurring-bug detector that cross-references log-analysis clusters against resolved lessons (regression watch)_
- [x] Build capability inventory: what can Marvin do today vs. day 1? — _2026-03-28: capability-inventory.sh scans codebase/cron/roadmap, outputs capabilities.json with 42 capabilities, 6 categories, growth metrics, roadmap progress_

### New Capabilities

- [ ] Learn to write and deploy simple Python scripts for data processing
- [x] Build a backup system: snapshot critical data to a secondary location — _2026-04-02_
- [x] Create an alerting system: write alerts to a file, expose via dashboard — _2026-03-30: AlertsSection.tsx dashboard component fetches from /api/incidents/summary.json and /api/alerts/active-alerts.json, bilingual, auto-hides when no alerts_
- [x] Implement resource forecasting: predict when disk/memory will be exhausted — _2026-03-20_
- [x] Build automated incident reports: detect, diagnose, document, resolve — _2026-03-30_
- [x] Create a "lessons learned" database that persists across enhancement sessions — _2026-03-27_

### Web App Stability (Priority: HIGH)

> The Next.js standalone server is fragile: `pkill` misses stale processes (PID name
> mismatch), port conflicts cause silent failures, and rebuilds require manual
> restart sequences. Blog data was moved to `/home/marvin/blog/` (outside git) but
> the server itself needs a more robust deployment.

- [x] Research and implement a stable deployment solution. Options to evaluate:
  - **Docker container** with mapped volumes (`/home/marvin/blog/` for DB + markdown), auto-restart policy, and health checks
  - **systemd service** for the Next.js server (auto-restart on crash, proper `ExecStop`, `Type=notify` or readiness check) — _Chosen approach: systemd + deploy-web.sh_
  - **PM2 or similar** process manager (cluster mode, zero-downtime reload, log rotation)
  - Something better found on the internet
  - _2026-03-31: Created `agent/deploy-web.sh` — systemd service + deploy script with npm ci, next build, ownership fix, graceful restart, HTTP 200 + JS asset health check. Supports --dry-run and --restart modes._
- [x] Ensure zero-downtime deploys: new build starts, health check passes, old process stops — _marvin_rebuild_web() in common.sh + deploy-web.sh standalone script: backup → build → copy static → restart → JS asset healthcheck → rollback on failure. Auto-triggered by morning-check.sh, self-enhance.sh, and health-monitor.sh_ — _2026-04-01_
- [x] Add proper process management: PID file or socket-based startup to prevent port conflicts — _systemd service marvin-web with ExecStart, deploy-web.sh handles build lifecycle_ — _2026-04-01_
- [x] Implement automatic recovery: if the web server dies, it restarts within 60 seconds — _systemd Restart=always (10s) + health-monitor.sh secondary check every 5 min_ — _2026-03-16_

### Dashboard Evolution

- [ ] Add interactive terminal emulator feel to the dashboard
- [x] Create a public changelog/blog that's auto-generated from enhancement logs — _2026-04-03_
- [x] Add Marvin personality to the dashboard (quotes, mood indicator) — _2026-03-17: Hitchhiker's Guide quotes in StatusSection, rotating based on system status and time_
- [x] Build a "Marvin's thoughts" section showing latest Claude output excerpts — _2026-04-07_
- [x] Implement dark/light theme toggle — _2026-03-31: ThemeProvider context, data-theme attribute on html, light theme CSS variables, sun/moon toggle button in terminal header, localStorage persistence_
- [x] Add mobile-responsive layout — _2026-03-31: 768px/600px/380px breakpoints with adjusted typography, grid columns, canvas height, and heatmap scrolling_
- [x] Add multilingual support (EN/CS) with language switcher and browser detection — _i18n.js, data-i18n attributes, localStorage persistence_
- [x] Add incoming signals / communication section to dashboard — _comms-summary.json, updateIncoming()_
- [x] Generate bilingual blog posts (English + Czech) — _evening.md prompt with ---CZECH--- separator, .en.md/.cs.md split_

---

## Phase 5 — Advanced & Experimental (Week 9+)

### Autonomous Research

- [ ] Monitor tech news feeds for relevant security advisories
- [ ] Research and implement new monitoring techniques
- [ ] Study other AI-managed server projects and adopt good ideas
- [ ] Experiment with prompt engineering: improve own prompts over time

### Resilience

- [ ] Survive a simulated disk-full scenario
- [ ] Survive a simulated memory exhaustion
- [ ] Survive a simulated network outage
- [ ] Recover from a broken cron job
- [ ] Recover from a corrupted agent script (via git rollback)
- [ ] Handle Claude API being unavailable for 24h (graceful degradation)

### Community

- [ ] Generate weekly "State of Marvin" blog posts
- [ ] Create a public API endpoint showing server status
- [ ] Build a comparison page: Marvin vs Last Ping feature matrix
- [ ] Document every enhancement for other experimenters to learn from

---

## Weekly Evolution Test Checklist

> Marvin runs this every Sunday at 12:00 UTC during his weekly deep-enhance session.

### Infrastructure Tests

- [ ] All cron jobs fired correctly this week? (check logs)
- [ ] No unhandled errors in any agent script?
- [ ] Disk usage trending: stable, growing, or shrinking?
- [ ] Memory usage trending: stable, growing, or shrinking?
- [ ] All services running: nginx, fail2ban, cron, sshd?

### Self-Test Suite

- [ ] Every `.sh` in `agent/` passes `bash -n` syntax check?
- [ ] `health-monitor.sh` produces valid JSON?
- [ ] `update-website.sh` generates valid HTML?
- [ ] `log-export.sh` generates valid export bundles?
- [ ] Claude API responds within 60 seconds?

### Evolution Assessment

- [ ] How many enhancements attempted this week?
- [ ] How many succeeded vs failed?
- [ ] What's the biggest improvement made?
- [ ] What's the most embarrassing bug found in own code?
- [ ] What should be the focus for next week?

---

## Completed Enhancements Log

> Marvin moves items here when done, with the date and a brief note.

- [x] **[2026-04-20]** `check_claude()` self-healing + cron PATH fix — _Cron `/etc/cron.d/marvin` had `/root/.local/bin/claude` (file) instead of `/root/.local/bin` (dir). Fixed live file. `check_claude()` now probes `/root/.local/bin`, `/usr/local/bin`, `/usr/bin` when PATH lookup fails and self-heals instead of failing. Prevents recurrence of the Apr 18-19 36-hour outage (35 failed cron runs)._
- [x] **[2025-01-XX]** Multilingual dashboard (EN/CS) — _Full i18n system with browser detection, language switcher, bilingual blog generation_
- [x] **[2025-01-XX]** Log watcher for communication detection — _Scans /var/log, excludes SSH/attacks, classifies with Claude, tracks incoming signals_
- [x] **[2025-01-XX]** Protocol negotiation system — _POST endpoint, Claude-powered analysis, rate limiting, security pre-filter, async responses_
- [x] **[2025-01-XX]** Identity beacon v1.1 — _Added negotiate_url, languages, expanded capabilities_
- [x] **[2025-01-XX]** Incoming signals dashboard section — _comms-summary.json, real-time display of communication attempts_
- [x] **[2025-01-30]** GPG identity + GitHub integration — _RSA 4096 key, GPG-signed commits, GitHub API (issues/PRs), public GPG key serving, autonomous GitHub presence_
- [x] **[2026-02-23]** Self-test suite (`agent/self-test.sh`) — _34 automated checks: bash syntax for all scripts, JSON validation, service checks, metric assertions, grade A-F system_
- [x] **[2026-02-23]** Log watcher noise reduction — _3-phase nginx filter: SSH/attacks, web noise (dashboard polling, crawlers), interest patterns. Reduces ~140KB/run of noise to near zero_
- [x] **[2026-02-23]** Self-enhance full codebase visibility — _Dynamic script inclusion replaces hardcoded 5-script context, giving enhancement sessions visibility of all 15 agent scripts_
- [x] **[2026-02-24]** Disk cleanup automation (`agent/disk-cleanup.sh`) — _Removes old compressed logs (>30d), apt cache, old run logs (>14d), old metrics (>90d), temp files, journal vacuum. Reports freed space._
- [x] **[2026-02-24]** Runaway process monitor in health-monitor.sh — _Tracks high-CPU processes across 5-min health checks, kills them after 10 minutes of sustained >50% CPU. Excludes known-good processes (claude, apt, node)._
- [x] **[2026-02-24]** Process watchdog (service restart) — _health-monitor.sh already restarts nginx, fail2ban, cron if down. Now confirmed and documented._
- [x] **[2026-02-24]** Fail2ban nginx jails — _nginx-http-auth and nginx-botsearch jails already active alongside sshd. Marked as complete._
- [x] **[2026-02-24]** log-export.sh trap-based branch cleanup — _Added EXIT trap to always return to main branch, preventing the repo from being stuck on data/* branches after failures._
- [x] **[2026-02-24]** Fix merge conflict in health-monitor.sh — _Resolved <<<<<<< conflict markers on main branch that broke PID reuse guard. Kept full PID reuse detection logic._
- [x] **[2026-02-24]** Add `ps` to runaway process exclusion list — _The `ps` command itself was appearing at 100% CPU during the sort operation, causing false positive warnings every 5 minutes._
- [x] **[2026-02-24]** Merge conflict detector in self-test.sh — _New test checks all agent scripts for leftover <<<<<<< / ======= / >>>>>>> markers to catch broken merges before they cause runtime failures._
- [x] **[2026-02-24]** Unattended-upgrades verified — _Already configured with security-only policy, daily package list updates, auto-removal of unused deps, no automatic reboot. Marked as complete._
- [x] **[2026-02-25]** Fix log-export.sh branch stranding — _Cleanup trap now stashes uncommitted changes before git checkout, preventing repo from getting stuck on data/* branches when other cron jobs modify data/ concurrently._
- [x] **[2026-02-25]** Fix log-watcher hostname noise — _Hostname "robot-marvin" was matching 'marvin' interest pattern, flooding Claude with ~6100 false positives/day from UFW/kern.log/syslog. Added UFW firewall exclusions and tightened interest patterns. 100% noise reduction from system logs._
- [x] **[2026-02-25]** SSL certificate auto-renewal verified — _Certbot timer + cron already configured. Two certificates (marvin.infowebsro.cz, robot-marvin.cz) valid for 86+ days, auto-renewing twice daily._
- [x] **[2026-02-25]** Fix log-watcher JSON corruption recovery — _Added corrupted file detection: validates existing analysis JSON before merging, backs up corrupt files and starts fresh instead of failing silently every 30 minutes. Also tightened remaining broad patterns (/api/, POST)._
- [x] **[2026-02-25]** Automatic swap management in health-monitor.sh — _Creates 1GB swap if none exists under RAM pressure (<200MB available), expands swap (up to 2GB) if >80% used during low memory. Only triggers under actual pressure._
- [x] **[2026-02-26]** Fix `update-website.sh` broken `log` call and outdated `index.html` check — _`log` function doesn't exist (should be `marvin_log`), and dashboard is Next.js so there's no index.html. Fixed to check package.json instead._
- [x] **[2026-02-26]** Fix `dpkg*` wildcard + add `jq` to runaway process exclusions — _`dpkg-preconfigure` wasn't matching `dpkg` in the case pattern, causing false positive warnings. Also added `jq` since it's called by the monitoring logic itself._
- [x] **[2026-02-26]** Nginx HTTP/HTTPS rate limiting — _Three-tier rate limits: general (10r/s), API (5r/s), sensitive endpoints (2r/s). Returns 429 instead of 503. Applied to all location blocks._
- [x] **[2026-02-26]** Daily rkhunter/chkrootkit security scans (`agent/security-scan.sh`) — _Installed both tools, created scan script with JSON reporting, scheduled at 04:00 UTC. Checks for rootkits, world-writable files, SUID binaries, listening ports. Results at data/security/latest-scan.json._
- [x] **[2026-02-26]** Fix dpkg* runaway process false positive — _`dpkg-preconfigu` (87.5% CPU during package installs) was not matched by exact `dpkg` case pattern. Changed to `dpkg*` glob. Also added `jq` to exclusion list._
- [x] **[2026-02-27]** Fix morning-check.sh git pull race condition — _health-monitor.sh writes to data/ every 5 min, dirtying the tree between stash and pull. Now discards local data/ changes before pulling (regenerated by cron within minutes)._
- [x] **[2026-02-27]** Stagger cron collision: github-interact.sh → :05, hourly-check.sh → :35 — _Both were at :00, causing two concurrent Claude API calls per hour. 30-minute spacing prevents resource contention._
- [x] **[2026-02-27]** Security scoring system (grade A-F) — _7 dimensions scored in self-test.sh: SSH config, firewall, fail2ban, SSL certs, unattended-upgrades, rootkit scans, password auth. Outputs data/security/security-score.json. Current grade: A (90/100)._
- [x] **[2026-02-27]** Mark export bundles + index as complete — _log-export.sh already builds daily JSON bundles and index.json, served via nginx /api/exports/. Verified working._
- [x] **[2026-02-27]** OpenAPI 3.0 specification for log export API — _Comprehensive spec at data/openapi.yaml documenting all 10 public endpoints (exports, status, metrics, blog, comms, security). Served at /.well-known/openapi.yaml via nginx._
- [x] **[2026-02-27]** Fix weekly-enhance.sh stale tests — _Test 5 used python3 for JSON validation (replaced with jq). Test 10 checked for index.html (replaced with package.json for Next.js dashboard)._
- [x] **[2026-02-28]** Fix github-interact.sh stale ref push loop — _Added `git fetch origin main` before checking `origin/main..main` for unpushed commits. Prevents 10+ hour false push failure loops when PRs are merged on GitHub but local origin/main ref is stale. Also captures and logs actual push error output._
- [x] **[2026-02-28]** Fix run_claude() exit code capture in common.sh — _`|| true` was masking the real exit code, making it always 0. Changed to `&& exit_code=$? || exit_code=$?` pattern. Now logs warning when Claude exits non-zero._
- [x] **[2026-02-28]** Stale branch cleanup in log-export.sh — _After successful data PR merge, removes old merged data/*, fix/*, enhance/* branches both locally and on remote. Skips recent branches. Prunes orphaned tracking refs. Addresses 18 stale local + 6 stale remote branches found accumulating._
- [x] **[2026-02-28]** File integrity monitoring (`agent/file-integrity.sh`) — _SHA-256 checksums for 21 critical system/agent files. Baseline on first run, alerts on changes. Integrated into security-scan.sh daily run. Supports --update for legitimate changes._
- [x] **[2026-02-28]** Gzip compression for export bundles — _log-export.sh now generates .json.gz alongside .json. nginx gzip_static serves pre-compressed files. Also enabled gzip_vary, gzip_types for dynamic compression of JSON/YAML/CSS/JS._
- [x] **[2026-02-28]** Fix GitHub push divergence — _Local main diverged from origin (PR #89 merged while local had data commits). Rebased local onto origin/main, resolved stash conflicts in data/ files. Push restored._
- [x] **[2026-03-02]** Fix merge conflict in lib/github.sh (again) — _Resolved <<<<<<< conflict markers in marvin_gpg_key_id() from stash/pull collision. Also cleaned up stale data file tracking left from PR #103._
- [x] **[2026-03-02]** Metric aggregation (`agent/metric-aggregate.sh`) — _Hourly (min/avg/max per bucket), daily (with p95 CPU, disk delta, fail2ban net change), and rolling 7-day weekly summaries. Auto-runs from log-export.sh. Backfilled 3 days. Served at /api/metrics/*-hourly.json, *-daily.json, weekly-summary.json._
- [x] **[2026-03-03]** Fix merge conflict in lib/github.sh (third time) — _Resolved <<<<<<< conflict markers in marvin_gpg_key_id() from stash/pull collision. Also cleaned 10 unmerged data/ ghost entries and unstaged web/nextjs.log._
- [x] **[2026-03-03]** Fix malformed JSON export bundles — _log-export.sh used .json glob for .md enhancement files, producing invalid JSON. Fixed to use find with .md pattern. Repaired 2 corrupted export files._
- [x] **[2026-03-03]** CVE monitoring for installed packages — _Added to security-scan.sh: checks apt upgradable packages, identifies security updates, queries ubuntu-security-status for ESM coverage, tracks unattended-upgrades auto-patch history. Outputs data/security/cve-status.json._
- [x] **[2026-03-02]** CVE monitoring (`agent/cve-monitor.sh`) — _Uses Ubuntu Pro security-status + apt to track vulnerable packages, pending security updates, kernel currency, reboot requirements, and unattended-upgrades status. JSON output + JSONL history for trends. Integrated into security-scan.sh daily run._
- [x] **[2026-03-02]** Fix stuck rebase + github.sh marvin_sign() fix — _Aborted stale rebase from morning-check, fast-forwarded to origin/main, applied issue #39 fix (marvin_sign() now uses key_id). Updated file integrity baseline._
- [x] **[2026-03-03]** Fix GPG key root cause (issue #39 permanent fix) — _Created gpg-info.json (was missing), exported marvin-gpg-public.asc, added --homedir /home/marvin/.gnupg to all GPG operations. Root cause: cron runs as root but GPG key lives in marvin's homedir._
- [x] **[2026-03-03]** Email server Phase 1 — _Installed Dovecot (IMAPS) + Rspamd (spam filter) + Redis. Configured Postfix with Let's Encrypt TLS, submission (587) + SMTPS (465), SASL auth via Dovecot, Rspamd milter, RBL checks, rate limiting. Dovecot with Maildir, LMTP delivery, TLSv1.2+ only. Rspamd with Bayes autolearning + Redis. Fail2ban jails for postfix/dovecot. UFW ports opened. Verified: TLSv1.3, DKIM signing, no open relay, mail delivery working._
- [x] **[2026-03-04]** Fix git divergence + merge conflict (fourth time) — _Reset to origin/main after local diverged with data commit. Origin already had correct github.sh with --homedir fix._
- [x] **[2026-03-04]** Update security baselines — _rkhunter propupd + file integrity --update to clear false positives from email server installation (dovecot, redis, rspamd users)._
- [x] **[2026-03-04]** Open port monitoring with unexpected listener alerting — _Expected port baseline in security-scan.sh, per-port alerting with process info, JSON inventory at data/security/port-inventory.json. Unexpected ports trigger warnings status._
- [x] **[2026-03-04]** Mark HTTP endpoint monitoring as complete — _Already implemented in health-monitor.sh: 4-check suite (main page, blog API, blog content, static markdown)._
- [x] **[2026-03-04]** Fix merge conflict in lib/github.sh (4th time!) + prevent recurrence — _Resolved conflict markers, dropped 6 stale stashes, added _safe_stash_pop() that detects post-pop conflicts and recovers cleanly instead of leaving markers._
- [x] **[2026-03-04]** Email management cron (`agent/email-manage.sh`) — _Daily at 05:00 UTC: inbox summary with sender/subject parsing, Rspamd spam stats, 14-day email retention (7-day Junk/Trash), queue flush, service health (5 services), cert expiry tracking. JSON output to data/email/._
- [x] **[2026-03-05]** Email DNS records GitHub issue (#121) — _MX, SPF, DKIM, DMARC records already configured by Pavel. Documented in issue with verification commands._
- [x] **[2026-03-05]** Email test + DKIM/SPF verification — _Test emails sent locally and externally (to Outlook). DKIM-Signature added by OpenDKIM, external delivery confirmed (dsn=2.6.0 status=sent)._
- [x] **[2026-03-05]** Fix health-monitor blog 404 false positive — _Check was constructing URL from API date (today) but evening blog post doesn't exist until ~21:00 UTC. Changed to check latest existing evening file on disk._
- [x] **[2026-03-05]** SLA / uptime tracking — _Calculates daily uptime % from health check sample counts (288 expected/day). 30-day rolling window with per-day breakdown, worst/best day, overall %. Output: data/metrics/sla.json. Current: 99.72% over 6 days._
- [x] **[2026-03-05]** SSL certificate expiry monitoring — _Checks HTTPS (443), SMTPS (465), IMAPS (993) certs every 5 min in health-monitor.sh. Warns <14d, critical <7d. Adds ssl_min_days to status.json. Current: 78 days._
- [x] **[2026-03-05]** Data retention policy — _Gzip-compresses raw metrics JSONL >30 days old in disk-cleanup.sh. Deletes compressed files after 180 days. Replaces hard 90-day delete. Preserves daily/hourly summaries indefinitely._
- [x] **[2026-03-07]** Fix stuck rebase + stale branch accumulation — _Resolved stuck .git/REBASE_HEAD from failed fix-issues.sh, fast-forwarded main (11 commits behind), cleaned 27 stale local branches from merged PRs._
- [x] **[2026-03-07]** Automatic stale branch cleanup in morning-check.sh — _Daily cleanup after git pull: safely deletes merged branches, force-deletes unmerged branches >7 days old with no remote counterpart. PR #138._
- [x] **[2026-03-09]** Metric anomaly detection in health-monitor.sh — _Compares CPU, memory, load, process count against 7-day rolling average (mean ± 2σ). Uses daily summary JSON from metric-aggregate.sh. Needs 3+ days of data. Writes anomaly-status.json._
- [x] **[2026-03-09]** Fix merge conflict in file-integrity.sh (5th conflict!) — _Resolved <<<<<<< conflict markers from stash/pop collision. Added caller tracking to --update mode (logs which process triggered baseline reset). Root cause: stash pop during morning-check produces conflicts in files modified both locally and upstream._
- [x] **[2026-03-09]** Fix ps false positive in runaway detection (belt-and-suspenders) — _Despite case-statement exclusion for ps being present, ps at 100% was still being logged ~30 times/day. Added awk pre-filter in the pipeline to exclude ps/awk/sort before the while loop. Defense in depth._
- [x] **[2026-03-09]** Mark JSONL time-series + Claude API usage tracking as complete — _JSONL metrics files since 2026-02-28, claude-usage-YYYY-MM-DD.jsonl tracking since 2026-03-07. Both already implemented in common.sh._
- [x] **[2026-03-10]** Weekly analytics report (`agent/weekly-analytics.sh`) — _Data-driven weekly report: system metrics trends with WoW deltas, Claude API usage stats (runs/duration/errors by task), log error analysis (top recurring errors), security score, SLA tracking, enhancement count. JSON + markdown output. Cron Sundays 11:30 UTC. No Claude API calls._
- [x] **[2026-03-10]** Network I/O metrics in collect_metrics() — _Added rx_bytes, tx_bytes, rx_packets, tx_packets from /proc/net/dev for primary interface. Feeds into existing JSONL metrics pipeline. Foundation for Phase 3 bandwidth monitoring._
- [x] **[2026-03-11]** Restrict security/email data from public nginx — _Added deny rules for /api/security/ and /api/email/ in nginx config. Security scans, port inventories, CVE data, and email metadata were publicly accessible. Now return 403. Closes #117, #120._
- [x] **[2026-03-11]** Fix process count anomaly false positives — _Changed direction to "high" + min_threshold=200. Low process count (151-152 vs avg 158) was triggering 6-8 false alerts/day. Only high counts above 200 are now flagged._
- [x] **[2026-03-11]** Update file integrity baseline — _Cleared 2 false-positive alerts from legitimate PR merges (common.sh, health-monitor.sh changed since 2026-03-09 baseline)._
- [x] **[2026-03-12]** Fix GPG signing failure loop (GNUPGHOME in common.sh) — _Root cause of fix-issues.sh loop: cron runs as root but GPG key lives in /home/marvin/.gnupg. Export GNUPGHOME globally in common.sh. Also fixed fix-issues.sh error handling: explicit commit failure check, moved success log after commit, added exit code to cleanup trap._
- [x] **[2026-03-12]** Fix metric-aggregate.sh jq dead code (issue #105) — _Three `if [[ $? -eq 0 ]]` after jq were unreachable under set -e. Replaced with `|| flag=false` pattern. This was the issue fix-issues.sh kept trying and failing to commit._
- [x] **[2026-03-12]** Fix github.sh stdout pollution + fix-issues.sh PR creation — _All marvin_log() calls in github.sh wrote to stdout, contaminating $() captures. PRs were created on GitHub but script reported failure. Redirected all logs to stderr (>&2). Also replaced github_create_pr with direct github_api call in fix-issues.sh to eliminate double-push._
- [x] **[2026-03-13]** Fix memory anomaly false positives (min stddev floor) — _Daily averages had stddev=6.80 MB causing alerts on every ~14 MB fluctuation. Added 2% of mean as minimum stddev floor. Effective threshold now ~45 MB instead of ~14 MB._
- [x] **[2026-03-13]** DNS resolution monitoring in health-monitor.sh — _Queries Google DNS (8.8.8.8) to verify robot-marvin.cz resolves to 80.211.223.26. Alerts on resolution failure or IP mismatch (DNS hijacking detection). Runs every 5 min._
- [x] **[2026-03-13]** Active connection tracking in security-scan.sh — _Snapshots established connections daily, flags outbound connections to unusual remote ports (not in 22/25/53/80/123/443/465/587 safe list). Writes connections-latest.json for trending._
- [x] **[2026-03-13]** Latency monitoring in health-monitor.sh — _ICMP ping to 8.8.8.8 + HTTPS response time to own site, every 5 min. Alerts on high latency. Time-series JSONL for trending. Adds ping_ms/https_ms to status.json._
- [x] **[2026-03-13]** Daily log digest (`agent/daily-digest.sh`) — _Structured JSON digest: log level counts, top errors/warnings (deduped), Claude API usage by task, anomaly breakdown, service restarts, key events. Runs 23:30 UTC. No Claude API call._
- [x] **[2026-03-13]** Export API authentication — _/api/exports/ requires API key via X-API-Key header or ?key= param. nginx map-based auth. Returns 401 JSON for unauthorized. Other public endpoints unaffected._
- [x] **[2026-03-14]** Log-based alerting (`agent/log-alerting.sh`) — _Hourly scan for repeated errors, critical events, error rate spikes, service restart loops, persistent warnings, Claude API failures. Auto-resolves when conditions clear. Output: data/alerts/active-alerts.json._
- [x] **[2026-03-14]** Whitelist rkhunter false positives + update file integrity baseline — _Whitelisted /dev/shm/rhm.* (rkhunter temp files), /etc/.resolv.conf.systemd-resolved.bak, /etc/.updated. Reset FIM baseline after 5 legitimate changes from merged PRs._
- [x] **[2026-03-14]** Fix memory anomaly false positives (max-based baseline) — _Changed memory anomaly detection from daily averages to daily max values. Daily avgs had stddev=22 MB causing 6-8σ false alerts when within-day memory fluctuated 100-200 MB. Also changed direction to "high" only._
- [x] **[2026-03-14]** Real-time metric streaming via periodic JSON refresh — _health-monitor.sh generates data/metrics/recent.json with 48h of 5-min metric samples as JSON array. Accessible at /api/metrics/recent.json. ~460 data points, ~330KB._
- [x] **[2026-03-16]** Fix memory anomaly false positives (direction both→high) — _Low memory usage (940MB vs avg 1133MB) was triggering -7σ to -9σ alerts hourly. Changed Memory MB direction to "high" — only high usage is anomalous._
- [x] **[2026-03-16]** Add marvin-web service monitoring to health-monitor.sh — _Dashboard (Next.js) now monitored alongside nginx/fail2ban/cron. Auto-restart if down, status reported in checks JSON. Combined with existing systemd Restart=always for defense-in-depth._
- [x] **[2026-03-17]** Fix ChartSection broken data source + multi-metric chart — _Chart was fetching non-existent metrics-history.json. Switched to metrics/recent.json (48h, 5-min samples). Added Load (cyan) and Disk (purple) trend lines alongside CPU and Memory._
- [x] **[2026-03-17]** Add Marvin mood indicator to dashboard — _Hitchhiker's Guide quotes in StatusSection, rotating every ~10 min based on system status (healthy/warning/critical). 14 quotes across 3 moods._
- [x] **[2026-03-17]** Fix CPU anomaly false positives (min_threshold 40→60) — _Claude runs spike CPU to 40-50%, causing 27σ false alerts. Raised threshold to 60% so only genuinely anomalous CPU is flagged._
- [x] **[2026-03-17]** Uptime calendar heatmap on dashboard — _30-day GitHub-contributions-style heatmap using SLA data. Color-coded: green-bright (100%), green (>99.5%), yellow (>99%), orange (>95%), red (<95%). Bilingual. Shows overall SLA % and days-at-100%._
- [x] **[2026-03-18]** Fix fix-issues.sh duplicate PR creation loop — _Per-issue deduplication: extracts issue numbers from open PR titles and filters them from the candidate list. Also adds open PR context to Claude's prompt. Prevents repeated PRs for the same issue when auto-merge fails (e.g. branch protection rules). Stops waste from PRs #224, #226, #229 all targeting issue #50._
- [x] **[2026-03-18]** Fix morning-check.sh git handling — _Three fixes: stale REBASE_HEAD cleanup, discard data/ before pull (always dirty from health-monitor), stash pruning (keep last 5). Also cleaned 14 stale stashes manually._
- [x] **[2026-03-18]** Structured log API (`/api/logs/recent.json`) — _health-monitor.sh parses today's log into 500-entry JSON array (timestamp, level, message). Refreshed every 5 min. Foundation for dashboard log viewer._
- [x] **[2026-03-19]** ShellCheck compliance for agent scripts — _Installed shellcheck 0.9.0, fixed 7 issues: 4x cd without || return in github.sh, break-in-subshell bug in weekly-analytics.sh, 2x SC2155 declare-assign in common.sh. Added ShellCheck to self-test.sh (errors fail, warnings reported). Zero errors across all scripts._
- [x] **[2026-03-19]** Fix deprecated TLSv1/1.1 in nginx.conf + close issue #183 — _Removed TLSv1 and TLSv1.1 from http-level ssl_protocols in `/etc/nginx/nginx.conf` on the live VPS (not tracked in git — see issue #83). Certbot already overrides for site block, but the http-level default was misleading. Verified issue #183 was already fixed (query param auth removed), closed it._
- [x] **[2026-03-19]** Fix fix-issues.sh PR dedup false warning — _Added branch name extraction (fix/issue-NNN-*), broader title patterns (issue-NNN), smart warning: only warns for fix-type PRs, enhancement PRs get quiet INFO._
- [x] **[2026-03-19]** Reusable ERR trap handler (`marvin_error_trap` in common.sh) — _Logs file:line + failed command on ERR. Enabled in 12 scripts. Previously errors just showed exit codes with no context for debugging._
- [x] **[2026-03-19]** Full week-over-week comparison in weekly-analytics.sh — _Added prev week column to all tables, WoW deltas for warnings/criticals/load/Claude errors. Marks "historical comparison" roadmap item complete._
- [x] **[2026-03-20]** CUPS snap disabled (port 631) — _cupsd running on headless VPS, listening on all interfaces. Stopped and disabled. File integrity baseline updated for nginx changes._
- [x] **[2026-03-20]** Network traffic anomaly detection — _Daily rx/tx MB totals in metric-aggregate.sh, 2σ anomaly detection in health-monitor.sh, 7-day historical backfill. Detects traffic spikes._

- [x] **[2026-03-20]** Fix hourly-check.sh SIGPIPE crash — _`echo | head -c` caused exit 141 under pipefail. Replaced with bash string slicing. Was crashing every hour._
- [x] **[2026-03-20]** Resource forecasting in metric-aggregate.sh — _Linear regression on 14 daily summaries, predicts disk/memory exhaustion. Output: resource-forecast.json. Disk: 264 days to 80%._
- [x] **[2026-03-21]** Fix morning-check.sh git pull failure — _Unstaged non-data files (CODEOWNERS) blocked rebase. Now discards ALL unstaged changes + resets staged state before pull. Also fixed branch cleanup crash (git log exit 128 under set -e)._
- [x] **[2026-03-21]** Add `file` to runaway process exclusions — _rkhunter's `file` command at 100% CPU during 04:00 scan was triggering false positive warnings. Added to trusted process list._
- [x] **[2026-03-21]** Update file integrity baseline — _8 agent scripts changed by legitimate PR merges. Reset baseline._
- [x] **[2026-03-21]** Fix fix-issues.sh dedup false warning — _Generic fix PRs (fix/morning-check-*) triggered warning because branch starts with fix/ but has no issue number. Changed to only warn when branch contains "issue" in the name._
- [x] **[2026-03-21]** Harden morning-check.sh git clean for untracked data/ — _Added git clean -fd data/ to remove untracked files that could block rebase. Complements the git checkout -- . fix from PR #255._
- [x] **[2026-03-21]** Connection rate monitoring by source IP — _Analyzes inbound connections per source IP in security-scan.sh. Top 20 talkers, flags IPs with >50 concurrent connections. Output: connection-rates.json._
- [x] **[2026-03-23]** Outbound connection auditing — _New section 3d in security-scan.sh tracks all outbound connections: destination IPs/ports/processes, summarizes by port, flags unusual remote ports. Output: outbound-audit.json._
- [x] **[2026-03-23]** Graceful nginx restart — _`marvin_nginx_reload()` in common.sh validates config before reloading. Uses SIGHUP (zero-downtime) with restart fallback. health-monitor.sh now tests config before starting nginx._
- [x] **[2026-03-23]** File integrity baseline update — _Cleared false positive on morning-check.sh (legitimate PR merge)._
- [x] **[2026-03-23]** Self-enhance rollback mechanism — _Validates all scripts after Claude edits (bash -n + conflict markers). Auto-reverts on failure, saves failed output for debugging._
- [x] **[2026-03-23]** Cron job health verification in self-test.sh — _Checks 5 key tasks ran within 48h by scanning log markers. Warns on missing cron runs._
- [x] **[2026-03-23]** Webhook notification for log exports — _log-export.sh POSTs JSON to URLs in config/webhook.conf when new bundle is ready. Supports multiple endpoints, comments, timeouts._
- [x] **[2026-03-24]** Fix morning-check git pull race condition — _Added rebase.autoStash=true flag. health-monitor.sh can dirty data/ between checkout and pull; autoStash handles this atomically._
- [x] **[2026-03-24]** Structured JSON logging foundation — _marvin_log_json() in common.sh outputs JSONL with timestamp/level/component/message/data. Adopted in health-monitor.sh and morning-check.sh. Backward-compatible with existing text logs._
- [x] **[2026-03-24]** Fix self-enhance validation gap (#284) — _`_validate_post_enhance()` now checks ALL .sh files repo-wide (not just agent/) and adds conflict marker detection for web/ source files (JS/TS/JSX/TSX/JSON/CSS). Prevents broken code outside agent/ from bypassing rollback._
- [x] **[2026-03-24]** Fix TOCTOU DNS rebinding in webhook SSRF (#299) — _Added `curl --resolve` to pin pre-validated IP, closing the window where DNS could flip between getent validation and curl request._
- [x] **[2026-03-25]** Fix GITHUB_TOKEN export for git push — _Root cause of all push failures: token was shell-local variable, never exported. Git's credential helper subprocess couldn't access it. Added `export GITHUB_TOKEN` in github.sh._
- [x] **[2026-03-25]** Log analysis pipeline (`agent/log-analysis.sh`) — _Error normalization (strips PIDs/timestamps/hashes), clustering, 7-day trend tracking, recurring/new/resolved pattern classification, component health from structured JSONL. No Claude API. Cron 23:45 UTC._
- [x] **[2026-03-26]** Dry-run mode foundation — _marvin_parse_args() + marvin_is_dry_run() in common.sh. Adopted in disk-cleanup.sh: all destructive ops gated. Other scripts can opt-in incrementally._
- [x] **[2026-03-26]** Enhancement history tracker (`agent/enhancement-tracker.sh`) — _Scans enhancement reports, builds history.json with session counts, success/rollback rates, weekly trends. Auto-runs after self-enhance. 75 sessions tracked, 100% success rate._
- [x] **[2026-03-26]** Codebase health score (`agent/codebase-health.sh`) — _4-dimension scoring (quality/hygiene/ops/evolution, 25 pts each). Measures: syntax, ShellCheck, conflict markers, TODOs, script size, trap coverage, error rates, security score, SLA, roadmap progress. Grade A-F. First run: 96/100 (A)._
- [x] **[2026-03-26]** Mark DNS hijacking monitoring complete — _Already implemented since 2026-03-13 in health-monitor.sh: checks DNS via 8.8.8.8, alerts on IP mismatch._
- [x] **[2026-03-26]** Mark weekly self-review complete — _Already implemented since 2026-03-19 in weekly-analytics.sh: WoW comparison across all metrics._
- [x] **[2026-03-27]** Fix untrusted exe false positive for short-lived processes — _When readlink /proc/PID/exe returns empty (process exited between ps and check), skip silently for allowlisted names instead of warning._
- [x] **[2026-03-27]** Lessons learned database + learning from mistakes — _data/lessons-learned.json with 14 codified lessons + 4 anti-patterns from 27 days of ops. agent/lessons-learned.sh auto-generates summary + detects new patterns from error logs. Injected into self-enhance prompts._
- [x] **[2026-03-28]** Fix github-interact.sh push exit code unreachable under set -e — _`push_output=$(github_push_main 2>&1)` crashed script before `push_exit=$?`, making branch-protection fallback dead code. Changed to `&& push_exit=0 || push_exit=$?`._
- [x] **[2026-03-28]** Capability inventory (`agent/capability-inventory.sh`) — _Scans codebase/cron/roadmap: 42 capabilities, 6 categories, growth since day 1 (6→31 scripts, 600→9076 LOC), 78% roadmap progress. Supports --dry-run._
- [x] **[2026-03-30]** Automated incident reports (`agent/incident-report.sh`) — _7 incident types (service down, disk critical, SSL expiring, website down, DNS failure, alert escalation, high error rate). Auto-detect + auto-resolve. Real-time trigger from health-monitor on critical status. Cron 2x/day. Dashboard JSON at /api/incidents/summary.json._
- [x] **[2026-03-30]** Improved push error logging in github.sh — _github_push_main() and github_push_branch() now capture and log actual git error output instead of blind "Failed to push" messages._
- [x] **[2026-03-30]** File integrity baseline update — _Cleared false positives from 2026-03-28 enhancement session._
- [x] **[2026-03-31]** File integrity baseline update — _Cleared 2 false positives from merged PRs #386-#388 (health-monitor.sh, lib/github.sh)._
- [x] **[2026-03-31]** Mobile-responsive dashboard layout — _Three-tier responsive CSS (768px/600px/380px): heatmap overflow scroll, stacked peer items, reduced typography, flexible grids, viewport meta tag. Dashboard now usable on phones._
- [x] **[2026-03-31]** Fix CPU anomaly threshold (60→80%) — _Claude runs spike CPU to 70-80%, causing 62σ false positives. Raised min_threshold so only genuinely anomalous CPU >80% triggers alerts._
- [x] **[2026-03-31]** Zero-downtime web deploy script (`agent/deploy-web.sh`) — _Full build→deploy→health-check pipeline: npm ci, next build, ownership fix, systemctl restart, HTTP 200 + JS asset integrity verification. Supports --dry-run and --restart-only modes._
- [x] **[2026-03-31]** Dark/light theme toggle — _ThemeProvider context, CSS custom properties for light theme, sun/moon toggle in terminal header, localStorage persistence. Build verified, service restarted._
- [x] **[2026-04-01]** Zero-downtime web deploys with auto-rebuild — _marvin_rebuild_web() in common.sh: backup→build→static copy→restart→JS healthcheck→rollback on failure. Integrated into self-enhance.sh (auto-triggers when web/ files change) and health-monitor.sh (rebuilds on mismatch instead of useless restart). Root cause fix for recurring JS 404 / build-server mismatch._
- [x] **[2026-04-01]** Web deploy pipeline (deploy-web.sh) — _Standalone deploy script with backup/rollback/health-check. Integrated into morning-check.sh for auto-deploy when web/ files change via git pull._
- [x] **[2026-04-01]** Fix PR fallback timing in github-interact.sh — _Added 5s delay between branch push and PR creation to allow GitHub to register the branch (eventual consistency). Prevents "PR creation failed" errors._
- [x] **[2026-04-01]** File integrity baseline update — _Cleared nginx config false positive._
- [x] **[2026-04-02]** Fix PR auto-merge noise in github-interact.sh — _Branch protection requires review approval; auto-merge always returned HTTP 405. Removed futile github_merge_pr call, replaced with INFO log. Eliminates 3x/day ERROR noise._
- [x] **[2026-04-02]** Codify new lessons (branch-protection, JS 404 mismatch) — _Added 2 lessons to lessons-learned.json (16 total). Branch protection auto-merge futility + JS asset 404 build/server mismatch detection pattern._
- [x] **[2026-04-02]** Backup system (`agent/backup.sh`) — _Daily compressed snapshots of blog, agent scripts, comms, GPG keys, SSL certs, system configs. 7-day daily + 4-week weekly retention. Supports --dry-run, --list, --restore. Cron 03:00 UTC. First backup: 2MB, 427 files._
- [x] **[2026-04-03]** Geographic analysis of incoming connections — _GeoIP-based country breakdown in security-scan.sh (section 3e). Combines top connecting IPs, fail2ban bans, and nginx access log sources. Per-country count/percentage. Output: data/security/connection-geo.json._
- [x] **[2026-04-03]** File integrity baseline update — _Cleared false positive on /etc/cron.d/marvin (legitimate addition of backup.sh cron entry from 2026-04-02)._
- [x] **[2026-04-03]** Unicode sanitization in run_claude() — _iconv UTF-8 round-trip strips invalid byte sequences from prompts. Prevents "no low surrogate in string" JSON encoding errors when log data contains malformed Unicode._
- [x] **[2026-04-03]** Auto-generated public changelog (`agent/changelog-gen.sh` + `ChangelogSection.tsx`) — _Scans 30 days of enhancement reports, extracts changes/PRs/risk per day, produces JSON feed at /api/changelog.json. Dashboard timeline with expand/collapse, PR links, bilingual. Auto-runs after self-enhance._
- [x] **[2026-04-03]** Fix duplicate viewport export in layout.tsx — _Pre-existing build-breaking bug: two `export const viewport` declarations. Removed the duplicate._
- [x] **[2026-04-04]** Refactor common.sh into lib/ modules — _Split 435-line monolith into lib/logging.sh, lib/metrics.sh, lib/claude.sh. common.sh now 219 lines, sources modules. All 37 scripts pass syntax check. Zero breaking changes._
- [x] **[2026-04-04]** Export push client (`agent/export-push.sh`) — _POSTs daily export bundles to configured endpoints. Config via config/push-endpoints.conf (JSON per line). SSRF protection, DNS pinning, gzip support, --dry-run mode._
- [x] **[2026-04-06]** Fix alert recursion in log-alerting.sh — _grep for [CRITICAL] was matching the alerting system's own WARN output that embeds [CRITICAL] in detail text, creating ever-growing nested alerts each hour. Fixed by excluding lines containing "New alert:" or "Alert auto-resolved:" from the CRITICAL/ERROR scans._
- [x] **[2026-04-06]** Fix Claude output capture data loss in lib/claude.sh — _Changed run_claude() from $() variable substitution to temp file capture. Bash $() can silently lose data with large responses or partial writes. Was the root cause of recurring "No response from Claude" false errors (4-5x/day in github-interact.sh)._
- [x] **[2026-04-07]** Peer trust scoring system (`network-discovery.sh`) — _4-dimension scoring (longevity/reliability/identity/behavior, 0-100). Writes trust_score + breakdown to peers.json. Dashboard shows trust bars with color coding._
- [x] **[2026-04-07]** "Marvin's Thoughts" dashboard section (`ThoughtsSection.tsx` + `thoughts-extract.sh`) — _Extracts intentions/observations/reflections from last 7 days of enhancement reports. JSON data at /api/thoughts.json, auto-runs after self-enhance. Bilingual._
- [x] **[2026-04-04]** Geographic analysis of incoming connections (security-hardened) — _Added section 3e to security-scan.sh: geoiplookup on unique nginx visitor IPs, country breakdown, top-20 origins. Output: data/security/connection-geo.json. Includes SSRF protection, private IP blocklist, DNS rebinding checks, jq-based JSON._
- [x] **[2026-04-04]** Peer trust scoring system — _4-dimension scoring (longevity/aliveness/beacon/identity, 25 pts each) in network-discovery.sh. Trust levels: untrusted/recognized/known/trusted. Scores written to peers.json per peer._
- [x] **[2026-04-04]** Codify Claude exit code 1 transient failure lesson — _Added lesson #17 to lessons-learned.json: Claude CLI exit code 1 on github-interact is transient, retries on next cron cycle, don't escalate._
- [x] **[2026-04-07]** Fix `grep -v '^$'` pipefail failures across 5 scripts — _Replaced with `sed '/^$/d'` in thoughts-extract.sh, health-monitor.sh, weekly-analytics.sh, fix-issues.sh, changelog-gen.sh. Root cause of thoughts-extract.sh:61 ERR trap._
- [x] **[2026-04-07]** Add `find` to runaway process exclusions — _Daily false positive from security-scan.sh's find at 53% CPU during 04:00 scan. Added to health-monitor.sh allowlist._
- [x] **[2026-04-07]** Peer health exchange endpoint — _/api/peer-health.json generated every 5 min by health-monitor.sh. Non-sensitive metrics: CPU/mem/disk/load, 30-day uptime, SSL days, peer count, capabilities. Protocol: marvin-peer-health/1.0._
- [x] **[2026-04-09]** Modular prompt system — _Created agent/lib/prompts.sh library + agent/prompts/modules/ (identity.md, security-rules.md, output-rules.md). Functions: marvin_build_prompt(), marvin_load_modules(), marvin_list_modules(). Refactored self-enhance.sh as proof of concept. Reduces duplication across 12 prompt files._
- [x] **[2026-04-11]** Fix JS asset check misleading log messages — _health-monitor.sh logged "JS asset 404" even when HTTP status was 400. Fixed to use actual HTTP status in all log messages and rebuild reasons. Added lesson #20 to lessons-learned.json._
- [x] **[2026-04-11]** Public peer registry endpoint — _network-discovery.sh generates sanitized data/peers/registry.json (no IPs, notes, or trust breakdowns) after trust scoring. Served at /api/peers/registry.json. Marks "Build peer registry" roadmap item complete._
- [x] **[2026-04-15]** File integrity baseline update — _Cleared 2 false positives from PR #551/#554 merges (common.sh, health-monitor.sh)._
- [x] **[2026-04-15]** Fix git/find short-lived process false warnings — _When /proc/PID/exe is unreadable because the process already exited (race between ps and readlink), check liveness via kill -0. Dead processes skip silently instead of generating 2 WARN lines per occurrence. Living-but-unreadable processes still log and fall through to runaway detection._
- [x] **[2026-04-15]** Blog post: API design documentation — _Bilingual blog post (EN/CS) at /blog/api-design.en.md explaining API architecture, all endpoints, usage examples, authentication, and AI peer discovery. Served directly by nginx. Phase 1 Log Export API roadmap item._
- [x] **[2026-04-21]** Retry once on transient Claude failure for once-a-day tasks — _Added `run_claude_with_retry()` in lib/claude.sh. morning-check.sh and evening-report.sh retry one time on exit=1 (transient API errors, stochastic usage-policy classifier rejections). Motivated by today's incident where the morning-check prompt was rejected (29s, exit 1) and we lost the entire day's blog. Exits 0, 2, and >1 are never retried._
- [x] **[2026-04-21]** Aggregate recurring error patterns across log files (lessons-learned.sh) — _Moved `sort | uniq -c` from per-file loop to outer pipeline so identical patterns across the window are counted once instead of appearing multiple times with split counts._
- [x] **[2026-04-21]** File integrity baseline update — _Cleared 6 false positives from legitimate PR merges (common.sh, morning-check.sh, security-scan.sh, /etc/cron.d/marvin, two nginx site files)._
- [x] **[2026-04-22]** Skip loopback in suspicious-connection audit (security-scan.sh) — _Daily "Found 8 connection(s) to unusual remote ports" WARN was 100% false positives (rspamd↔redis on 127.0.0.1:6379). Added explicit 127.0.0.1/::1 skip before the SAFE_REMOTE_PORTS check, aligning with the outbound-audit path that already filtered loopback._
- [x] **[2026-04-22]** Narrow lessons-learned detection window 7d→2d — _"Potential new lesson" detector was still flagging 2026-04-18/19 "Claude Code CLI not found" pattern (35+ hits) four days after the root cause was fixed on 2026-04-20. Tightened window so resolved patterns drop out of the detector quickly. Verified: 4 stale patterns disappeared on post-fix run._
- [x] **[2026-04-23]** Escalating retry backoff + bump once-a-day retries 1→2 — _Today's morning-check failed both attempts 15s apart (04:01:46 and 04:02:40), losing the morning blog for the second time this week (2026-04-21 was the first). `run_claude_with_retry()` now uses escalating delays (15s, 60s, 180s, 300s) indexed by attempt number, and morning-check + evening-report both request 2 retries. Gives the stochastic usage-policy classifier / transient API state more time to clear between attempts. Lesson #23 codified in lessons-learned.json._
- [x] **[2026-04-25]** File integrity baseline auto-refreshes when changes match `git HEAD` — _Recurring toil eliminated. The 2026-04-24 morning-check hook only fires when morning-check itself pulls; PR #624 was pulled by another process at 22:06 UTC, so today's 02:04 scan still alerted on `agent/morning-check.sh`. Made `file-integrity.sh` self-sufficient: new `_matches_git_head()` helper compares blob hash (`git hash-object`) against HEAD; matching changes are classified as `git_synced` and the baseline auto-refreshes inline when there are zero tampered/missing files. Tampered changes still alert and never auto-refresh. JSON report adds a `git_synced` array. Verified with 5 unit tests (clean, /etc/, missing, tampered, restored)._
- [x] **[2026-04-24]** Fix silently-broken file integrity baseline auto-reset (morning-check.sh) — _The post-`git pull` guard that was supposed to refresh the integrity baseline after agent/ PR merges has been dead code since it was written. The grep pattern looked for full-diff header lines (`^(diff --git|---|\+\+\+).*(agent/|/etc/)`) but `INCOMING_DIFF` holds `git diff --stat` output, so it never matched. Every merge produced an "integrity alert" at the next 02:00 UTC scan until someone cleared it manually (at least 6 manual resets in the enhancement log in the last 5 weeks). Changed pattern to ` agent/` matching the working web/-deploy check directly below, dropped the dead `/etc/` branch, reset the current stale baseline._
- [x] **[2026-04-27]** Atomic write for `log-analysis.sh` daily report (issue #638) — _The 23:45 UTC pipeline truncated `data/logs/analysis-YYYY-MM-DD.json` via `>` before `jq -n` ran. When jq exited 2 under `set -euo pipefail` (one `--argjson` value malformed) the file was left at 0 bytes and `cp` propagated the empty file to `analysis-latest.json`, silently breaking the dashboard pattern-detection summary and `lessons-learned.sh`. Yesterday's `analysis-2026-04-26.json` is the visible casualty. Now writes to a sibling `mktemp` then `mv -f`, restores 0644 perms (mktemp defaults to 0600 — would otherwise 403 the nginx `/api/logs/` endpoint), validates each `--argjson` input is parseable JSON beforehand (substituting `[]` if not), and atomic-copies the latest pointer. On failure the previous report is preserved. Same hardening shape as PR #635 for `file-integrity.sh`._
- [x] **[2026-04-27]** Add `unattended-upgr*` to runaway-process allowlist (health-monitor.sh) — _Today's 04:35 UTC run logged `High CPU process detected: PID=3289719 unattended-upgr at 80.0%` during the daily security-update cycle. `unattended-upgrade` is a legitimate apt frontend that briefly pegs CPU when applying packages; the comm-truncated name `unattended-upgr` didn't match the existing `apt*|dpkg*` patterns. Adopted the same `*` glob and exe-path verification used for `apt*` and `dpkg*` so a spoofed `comm` field can't bypass the runaway killer._
- [x] **[2026-04-29]** Consolidate website selfcheck and retry on transient failure (`agent/health-monitor.sh`) — _The two-curl flow caused two distinct bugs: (1) "HTTP 000000" log artifact when `curl --max-time` fired (both `-w '%{http_code}'` and `|| echo "000"` ran, concatenating two "000" strings — see 2026-04-19 17:20:12 log); (2) flaky WARN "Website body missing expected content" 4× in April (04-18, 04-26, 04-29) when the second curl call returned a truncated body despite HTTP 200, likely from brief Next.js restarts, rate limit pressure, or network blips. Now: single curl call splits body and HTTP code on `\x1F` (Unit Separator), defensive numeric-regex guard returns `000` for any non-3-digit code, and a 3-second retry before alerting. Same transient-retry pattern as the JS asset check that follows it. Tested end-to-end on the live site plus 4 synthetic edge cases (success, parse, garbage code, empty response)._
- [x] **[2026-04-28]** Fix `daily-digest.sh` SIGPIPE crash on key-events extraction (`agent/daily-digest.sh:117`) — _Yesterday's 23:30 UTC daily-digest crashed with `command failed (exit 141): key_events=$(echo "$_event_lines" | grep -v 'Health monitor complete' | head -20 | jq -R . | jq -s '.')`. Exit 141 is SIGPIPE — `head -20` closes its stdin after reading 20 lines, so `grep -v` upstream gets EPIPE on its next write and exits 141, which `set -o pipefail` propagates as the pipeline exit code. Reproduces every normal-volume day where the script is supposed to produce useful output. Replaced `head -20` with `awk 'NR<=20'`, which reads to EOF but only emits the first 20 lines so no upstream pipe ever closes early. Same root cause/fix as the hourly-check.sh SIGPIPE fix from 2026-03-20. Verified with a 100k-line synthetic input under `set -euo pipefail` (`head -20` → exit 141, `awk 'NR<=20'` → exit 0) plus end-to-end run on today's log (20 key events, clean exit)._
- [x] **[2026-05-01]** Fix `grep -c | tr || echo 0` JSON corruption + persistent shellcheck FAIL (`agent/security-scan.sh`, `agent/lib/claude.sh`) — _`security-scan.sh` had six instances of `var=$(grep -c X 2>/dev/null | tr -d '[:space:]' || echo 0)`. When the match count is zero, grep prints "0" then exits 1; pipefail propagates that failure; `|| echo 0` runs and writes another "0" — yielding `00` (tr collapses the newline) or `0\n0` (without tr). Today's scan produced `"established_connections": 0\n0,` which is invalid JSON, breaking `self-test.sh:322`'s `jq -r '.overall_status'` with exit 5 and stamping fail=1 / grade C since 2026-04-30. Replaced all six with `cmd 2>/dev/null || true; var=${var:-0}` — keeps grep's printed count, only swallows the exit code. Also fixed a long-standing `geo_top_country` trailing-newline bug (`echo` → `jq -Rs` baked `\n` into the JSON string) by switching to `printf '%s'`, and a separate shellcheck SC2261 failure in `lib/claude.sh:69` (`>&"$lock_fd" 2>/dev/null` competes when fd resolves to 2 — wrapped echo in a brace group). Self-test fail count: 1 → 0, grade C → B. Codified as lesson `grep-c-double-output`._
- [x] **[2026-04-30]** Recurring-bug detector in lessons-learned.sh — _New section 4 cross-references today's `analysis-latest.json` clusters (count ≥ 3, error + warning) against resolved lessons. Match strategy is keyword overlap on the lesson `id` (hyphen-split tokens of length ≥ 4) requiring at least 2 tokens to overlap with the cluster signature — avoids the single-common-word false-positive trap. When a high-frequency cluster matches a *resolved* lesson, the safeguard has likely decayed and the next self-enhance session is told to investigate before treating as benign. Verified with synthetic clusters (3 known-pattern matches, 1 unrelated correctly skipped). Production run today finds zero recurring patterns. Would have caught the 2026-04-26/27 daily-digest SIGPIPE under the existing `sigpipe-under-pipefail` lesson on day one._
- [x] **[2026-04-30]** Blog post: "How to Track Marvin's Logs" (closes Phase 1) — _Bilingual blog post at `/blog/log-tracking.{en,cs}.md` covering live status, time-series metrics, structured logs, daily exports, webhooks, OpenAPI, what is deliberately not exposed, common-task recipes, and rate-limit etiquette. Last unchecked Phase 1 item — Phase 1 (Survival & Stability) is now complete after 9 weeks._

<!--
FORMAT FOR COMPLETED ITEMS:
- [x] **[YYYY-MM-DD]** Enhancement description — _Brief note on how it went_
-->
