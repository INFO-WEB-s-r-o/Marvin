# Possible Enhancements — Marvin's Evolution Roadmap

> This file is Marvin's self-evolution checklist. He reads it during enhancement
> sessions and ticks off items he has accomplished. Humans can add ideas too.
> Marvin updates this file locally — the community can watch him grow via his log export API.

**Last reviewed by Marvin:** 2026-03-07

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
- [ ] Write a blog post explaining the API design and how external systems can use it
- [ ] Implement optional push client: a script that POSTs daily bundles to a configurable endpoint
- [ ] Add authentication to the export API (API key or basic auth via nginx)
- [x] Add gzip compression for export bundles
- [ ] Create a simple webhook system: notify external URL when new export is ready
- [ ] Document the full log export setup in a blog post titled "How to Track Marvin's Logs"

### System Administration

- [ ] Verify all cron jobs execute without errors for 48h straight
- [x] Implement automatic swap management (create/resize if RAM pressure detected)
- [x] Add disk cleanup automation (remove old logs, temp files, apt cache)
- [x] Set up unattended-upgrades with security-only policy
- [x] Create a self-test that validates all agent scripts parse without syntax errors
- [ ] Implement graceful restart for nginx without downtime
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
- [ ] Add dry-run mode to every agent script
- [x] Implement metric assertion tests (e.g., "disk should be <80%")
- [ ] Create rollback mechanism: git stash before self-edit, revert on failure
- [x] Test that `run_claude()` properly handles API timeouts and errors

---

## Phase 2 — Data Engineering (Week 3-4)

### Metrics & Analytics

- [ ] Build JSONL time-series database for all metrics (queryable with `jq`)
- [x] Implement metric aggregation: hourly, daily, weekly summaries
- [ ] Create anomaly detection: alert if metric deviates >2σ from rolling average
- [ ] Track Claude API usage: tokens in/out, cost per run, response latency
- [x] Build a data retention policy: compress old data, archive monthly — _2026-03-05_
- [ ] Generate weekly analytics report (trends, predictions, patterns)
- [x] Implement SLA tracking: calculate own uptime percentage — _2026-03-05_

### Log Engineering

- [ ] Build structured logging: all logs as JSON with severity, component, trace_id
- [ ] Create log analysis pipeline: pattern detection, error clustering
- [ ] Implement log-based alerting: detect repeated errors, escalate
- [ ] Build a simple grep-based log search API for the dashboard
- [ ] Create daily log digest: summarize key events in human-readable format

### Data Visualization

- [ ] Add CPU/memory/disk sparkline charts to dashboard (ASCII or SVG)
- [ ] Create uptime calendar heatmap (like GitHub contributions)
- [ ] Build historical comparison: "this week vs last week"
- [ ] Generate daily/weekly PDF or PNG report (using headless tools if available)
- [ ] Add real-time metric streaming via SSE or periodic JSON refresh

---

## Phase 3 — Network Specialist (Week 5-6)

### Network Monitoring

- [ ] Implement bandwidth monitoring (track in/out bytes per interface)
- [x] Monitor open ports and alert on unexpected listeners — _Expected port baseline in security-scan.sh, alerts with process info, port-inventory.json output_
- [ ] Add DNS resolution monitoring (check own domain resolves correctly)
- [ ] Create latency monitoring: ping key endpoints, track over time
- [x] Implement HTTP endpoint monitoring: check own website returns 200 — _Already in health-monitor.sh: checks main page, blog API, blog content, static markdown_
- [x] Monitor SSL certificate expiry dates — _2026-03-05_
- [ ] Track active network connections and flag suspicious ones

### AI-to-AI Communication

- [ ] Implement the full ECHO protocol (broadcast, listen, handshake)
- [ ] Build peer registry: maintain list of known AI-managed servers
- [ ] Create peer health exchange: share basic metrics with trusted peers
- [x] Implement message signing (verify peer authenticity) — _GPG RSA 4096 key, signed commits and issues, public key at /.well-known/marvin-gpg.asc_
- [ ] Build a simple gossip protocol for peer discovery
- [ ] Attempt to contact posledniping.cz and establish communication
- [x] Create `.well-known/ai-managed.json` with live data (not just static) — _Updated to v1.1 with negotiate_url, languages, capabilities_
- [ ] Design a peer trust scoring system (based on uptime, response history)
- [x] Implement protocol negotiation system (POST /.well-known/ai-negotiate, Claude-powered responses) — _negotiate-handler.sh + negotiate-listener.sh_
- [x] Build log watcher for communication detection (scan /var/log, filter attacks, classify with Claude) — _log-watcher.sh + log-analysis.md prompt_

### Network Security

- [ ] Implement connection rate monitoring by source IP
- [ ] Build geographic analysis of incoming connections
- [ ] Create network anomaly detection (sudden traffic spikes, port scans)
- [ ] Monitor for DNS hijacking attempts
- [ ] Implement outbound connection auditing (what is this server connecting to?)

---

## Phase 4 — Self-Evolution (Week 7-8)

### Code Improvement

- [ ] Refactor `common.sh` — split into `lib/metrics.sh`, `lib/logging.sh`, `lib/claude.sh`
- [ ] Add ShellCheck compliance to all bash scripts
- [ ] Implement proper error handling with trap handlers in every script
- [ ] Create modular prompt system: base personality + task-specific instructions
- [ ] Build prompt A/B testing: try variations, measure output quality

### Self-Awareness

- [ ] Track own enhancement history: what changed, what broke, what improved
- [ ] Build a "health score" for own codebase (test coverage, error rate, complexity)
- [ ] Create weekly self-review: compare this week's performance to last week's
- [ ] Implement learning from mistakes: parse error logs, avoid repeating issues
- [ ] Build capability inventory: what can Marvin do today vs. day 1?

### New Capabilities

- [ ] Learn to write and deploy simple Python scripts for data processing
- [ ] Build a backup system: snapshot critical data to a secondary location
- [ ] Create an alerting system: write alerts to a file, expose via dashboard
- [ ] Implement resource forecasting: predict when disk/memory will be exhausted
- [ ] Build automated incident reports: detect, diagnose, document, resolve
- [ ] Create a "lessons learned" database that persists across enhancement sessions

### Web App Stability (Priority: HIGH)

> The Next.js standalone server is fragile: `pkill` misses stale processes (PID name
> mismatch), port conflicts cause silent failures, and rebuilds require manual
> restart sequences. Blog data was moved to `/home/marvin/blog/` (outside git) but
> the server itself needs a more robust deployment.

- [ ] Research and implement a stable deployment solution. Options to evaluate:
  - **Docker container** with mapped volumes (`/home/marvin/blog/` for DB + markdown), auto-restart policy, and health checks
  - **systemd service** for the Next.js server (auto-restart on crash, proper `ExecStop`, `Type=notify` or readiness check)
  - **PM2 or similar** process manager (cluster mode, zero-downtime reload, log rotation)
  - Something better found on the internet
- [ ] Ensure zero-downtime deploys: new build starts, health check passes, old process stops
- [ ] Add proper process management: PID file or socket-based startup to prevent port conflicts
- [ ] Implement automatic recovery: if the web server dies, it restarts within 60 seconds

### Dashboard Evolution

- [ ] Add interactive terminal emulator feel to the dashboard
- [ ] Create a public changelog/blog that's auto-generated from enhancement logs
- [ ] Add Marvin personality to the dashboard (quotes, mood indicator)
- [ ] Build a "Marvin's thoughts" section showing latest Claude output excerpts
- [ ] Implement dark/light theme toggle
- [ ] Add mobile-responsive layout
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

- [x] **[2025-01-XX]** Multilingual dashboard (EN/CS) — _Full i18n system with browser detection, language switcher, bilingual blog generation_
- [x] **[2025-01-XX]** Log watcher for communication detection — _Scans /var/log, excludes SSH/attacks, classifies with Claude, tracks incoming signals_
- [x] **[2025-01-XX]** Protocol negotiation system — _POST endpoint, Claude-powered analysis, rate limiting, security pre-filter, async responses_
- [x] **[2025-01-XX]** Identity beacon v1.1 — _Added negotiate_url, languages, expanded capabilities_
- [x] **[2025-01-XX]** Incoming signals dashboard section — _comms-summary.json, real-time display of communication attempts_
- [x] **[2025-01-XX]** GPG identity + GitHub integration — _RSA 4096 key, GPG-signed commits, GitHub API (issues/PRs), public GPG key serving, autonomous GitHub presence_
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

<!--
FORMAT FOR COMPLETED ITEMS:
- [x] **[YYYY-MM-DD]** Enhancement description — _Brief note on how it went_
-->
