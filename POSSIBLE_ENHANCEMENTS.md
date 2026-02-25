# Possible Enhancements — Marvin's Evolution Roadmap

> This file is Marvin's self-evolution checklist. He reads it during enhancement
> sessions and ticks off items he has accomplished. Humans can add ideas too.
> Marvin updates this file locally — the community can watch him grow via his log export API.

**Last reviewed by Marvin:** 2026-02-25

---

## TOP PRIORITY — Email Server (`robot-marvin.cz`)

> **Assigned by Pavel.** This takes precedence over all other enhancements.
> Full prompt and requirements: `agent/prompts/email-server.md`

- [ ] Install and configure Postfix + Dovecot + OpenDKIM + Rspamd
- [ ] Set up TLS via Let's Encrypt (SMTPS 465, STARTTLS 587, IMAPS 993)
- [ ] Configure SPF, DKIM, DMARC — output DNS records for Pavel to add
- [ ] Create `marvin@robot-marvin.cz` mailbox
- [ ] Add fail2ban jails for SMTP/IMAP
- [ ] Open firewall ports (25, 465, 587, 993)
- [ ] Verify no open relay — security audit
- [ ] Create email management cron: daily summary, spam handling, 14-day cleanup
- [ ] Create GitHub issue with the required DNS records
- [ ] Send test email and verify DKIM/SPF pass in headers

---

## Phase 1 — Survival & Stability (Week 1-2)

### Log Export API (Priority: HIGH)

> Marvin does not push logs to GitHub. Instead, he designs and serves his own
> log export solution. This is one of his first real engineering challenges.

- [ ] Define an OpenAPI 3.0 specification for the log export API (`data/openapi.yaml`)
- [ ] Serve the OpenAPI spec at `/.well-known/openapi.yaml`
- [ ] Build daily JSON export bundles at `/api/exports/YYYY-MM-DD.json`
- [ ] Create an export index at `/api/exports/index.json` (last 30 days)
- [ ] Write a blog post explaining the API design and how external systems can use it
- [ ] Implement optional push client: a script that POSTs daily bundles to a configurable endpoint
- [ ] Add authentication to the export API (API key or basic auth via nginx)
- [ ] Add gzip compression for export bundles
- [ ] Create a simple webhook system: notify external URL when new export is ready
- [ ] Document the full log export setup in a blog post titled "How to Track Marvin's Logs"

### System Administration

- [ ] Verify all cron jobs execute without errors for 48h straight
- [ ] Implement automatic swap management (create/resize if RAM pressure detected)
- [x] Add disk cleanup automation (remove old logs, temp files, apt cache)
- [x] Set up unattended-upgrades with security-only policy
- [x] Create a self-test that validates all agent scripts parse without syntax errors
- [ ] Implement graceful restart for nginx without downtime
- [x] Add process watchdog — restart critical services if they die
- [x] Monitor and kill runaway processes consuming >50% CPU for >10 minutes

### Security Hardening

- [x] Configure fail2ban with custom jail rules (not just SSH — nginx too)
- [ ] Set up daily rkhunter/chkrootkit scans
- [ ] Implement file integrity monitoring for critical system files
- [ ] Add iptables rate limiting for HTTP/HTTPS
- [ ] Create a security scoring system (grade own server A-F)
- [ ] Monitor for new CVEs affecting installed packages
- [x] Set up automated SSL certificate renewal (Let's Encrypt)

### Self-Testing

- [x] Create `agent/self-test.sh` — validates all scripts have correct syntax
- [ ] Add dry-run mode to every agent script
- [x] Implement metric assertion tests (e.g., "disk should be <80%")
- [ ] Create rollback mechanism: git stash before self-edit, revert on failure
- [ ] Test that `run_claude()` properly handles API timeouts and errors

---

## Phase 2 — Data Engineering (Week 3-4)

### Metrics & Analytics

- [ ] Build JSONL time-series database for all metrics (queryable with `jq`)
- [ ] Implement metric aggregation: hourly, daily, weekly summaries
- [ ] Create anomaly detection: alert if metric deviates >2σ from rolling average
- [ ] Track Claude API usage: tokens in/out, cost per run, response latency
- [ ] Build a data retention policy: compress old data, archive monthly
- [ ] Generate weekly analytics report (trends, predictions, patterns)
- [ ] Implement SLA tracking: calculate own uptime percentage

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
- [ ] Monitor open ports and alert on unexpected listeners
- [ ] Add DNS resolution monitoring (check own domain resolves correctly)
- [ ] Create latency monitoring: ping key endpoints, track over time
- [ ] Implement HTTP endpoint monitoring: check own website returns 200
- [ ] Monitor SSL certificate expiry dates
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

<!--
FORMAT FOR COMPLETED ITEMS:
- [x] **[YYYY-MM-DD]** Enhancement description — _Brief note on how it went_
-->
