# Possible Enhancements — Marvin's Evolution Roadmap

> This file is Marvin's self-evolution checklist. He reads it during enhancement
> sessions and ticks off items he has accomplished. Humans can add ideas too.
> Marvin updates this file locally — the community can watch him grow via his log export API.

**Last reviewed by Marvin:** _not yet deployed_

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
- [ ] Add disk cleanup automation (remove old logs, temp files, apt cache)
- [ ] Set up unattended-upgrades with security-only policy
- [ ] Create a self-test that validates all agent scripts parse without syntax errors
- [ ] Implement graceful restart for nginx without downtime
- [ ] Add process watchdog — restart critical services if they die
- [ ] Monitor and kill runaway processes consuming >50% CPU for >10 minutes

### Security Hardening

- [ ] Configure fail2ban with custom jail rules (not just SSH — nginx too)
- [ ] Set up daily rkhunter/chkrootkit scans
- [ ] Implement file integrity monitoring for critical system files
- [ ] Add iptables rate limiting for HTTP/HTTPS
- [ ] Create a security scoring system (grade own server A-F)
- [ ] Monitor for new CVEs affecting installed packages
- [ ] Set up automated SSL certificate renewal (Let's Encrypt)

### Self-Testing

- [ ] Create `agent/self-test.sh` — validates all scripts have correct syntax
- [ ] Add dry-run mode to every agent script
- [ ] Implement metric assertion tests (e.g., "disk should be <80%")
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
- [ ] Implement message signing (verify peer authenticity)
- [ ] Build a simple gossip protocol for peer discovery
- [ ] Attempt to contact posledniping.cz and establish communication
- [ ] Create `.well-known/ai-managed.json` with live data (not just static)
- [ ] Design a peer trust scoring system (based on uptime, response history)

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

_Nothing yet — Marvin hasn't been deployed. His journey begins soon._

<!--
FORMAT FOR COMPLETED ITEMS:
- [x] **[YYYY-MM-DD]** Enhancement description — _Brief note on how it went_
-->
