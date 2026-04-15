# Changelog

All notable changes to the Marvin Experiment are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **OpenTelemetry monitoring stack** (`monitoring/`) — Docker Compose stack (OTEL Collector + Prometheus + Grafana) for tracking Claude Code usage metrics: token consumption, API costs, session counts, lines of code, commits, and PRs. All services bind to localhost only. Grafana provisioned with pre-built Claude Code dashboard. OTEL env vars set in `agent/common.sh` so all cron-invoked Claude sessions export telemetry automatically. Prompt content and tool details are NOT logged (security). Requires Docker installation via `monitoring/setup.sh`. (implements #550)

### Fixed

- **Verify Docker GPG key fingerprint after download** (`monitoring/setup.sh`) — The Docker GPG key was downloaded via curl without verifying its fingerprint, accepting any key that the network delivered. Now checks the downloaded key's fingerprint against Docker's official fingerprint (`9DC8…CD88`) and aborts with an error if it doesn't match, preventing MITM or CDN compromise from installing a rogue signing key. (fixes #558)
- **OTEL telemetry nc fallback** (`agent/common.sh`) — Added `/dev/tcp` bash built-in fallback when `nc` (netcat) is not installed. Previously, the OTEL collector reachability check silently failed if `nc` was missing, permanently disabling telemetry even with the collector running. (fixes #559)
- **OTEL monitoring security hardening** (`monitoring/`) — Redacted Grafana admin password from setup.sh stdout output (was logged to `data/logs/`). Added `monitoring/.env` to `.gitignore`. Pinned Docker images to specific versions (OTEL Collector 0.119.0, Prometheus v3.2.1, Grafana 11.5.2) instead of `:latest`. Fixed hardcoded Grafana datasource UID — now uses provisioned UID. Set `disableDeletion: true` for provisioned dashboards. Removed `--web.enable-lifecycle` from Prometheus (exposes unauthenticated admin endpoints). Removed `debug` exporter from OTEL logs and metrics pipelines — prevents `user_id` label leakage to container stdout. `setup.sh` now sources existing `.env` before generating credentials — re-runs no longer lock out Grafana by overwriting the password. Replaced fallback `marvin-change-me` password with fail-fast `${...:?}` substitution. (fixes #553, #552, #555, #556)

- **OTEL telemetry guard when collector is down** (`agent/common.sh`) — OTEL env vars are now only exported when the collector is reachable (`nc -z 127.0.0.1 4317`). Previously, unconditional export caused a 10-second OTEL SDK timeout on every Claude Code session when the Docker monitoring stack was not running, stalling all cron jobs. Removed dead `debug` exporter definition from OTEL collector config. Added documentation comment to intentionally empty logs pipeline. (fixes #557)

- **JS asset HTTP 400 retry before rebuild** (`health-monitor.sh`) — Non-404 HTTP errors (400, 502, 000) on JS asset integrity checks now retry once after 5s before triggering a full web rebuild. HTTP 400 is often transient (nginx rate limiting, temp error) unlike HTTP 404 (definitively missing file). Previously, every non-200 response triggered an immediate 2-3 minute rebuild cycle. New lesson #22 codified in `lessons-learned.json`.
- **`break` → fall-through in `find|git` CPU monitoring** (`health-monitor.sh`) — PR #546 replaced `continue` with `break` in the `find|git` case when `/proc/<pid>/exe` is unreadable, intending to fall through to runaway detection. However, `break` exits the entire `while` loop, silently dropping all remaining high-CPU processes from that scan cycle. Removed the `break` so the code falls through naturally: logs the "unverified" warning, then the "untrusted exe" warning, then continues to runaway detection. Fixes #547, #548.

### Added

- **`git` added to runaway process exclusions** (`health-monitor.sh`) — Git operations (fetch, pull, push, rebase) spike to 100% CPU during morning-check and github-interact cron jobs. Like `find`, uses parent-process verification: only suppresses `git` from `/usr/bin/git` whose parent is a Marvin bash script. Non-Marvin git processes are still monitored and logged.
- **Auto-reset file integrity baseline after git pull** (`morning-check.sh`) — When incoming commits modify files in `agent/` or `/etc/`, the file integrity baseline is automatically reset via `file-integrity.sh --update`. Previously, every PR merge triggered false positive alerts that persisted until the next security-scan at 04:00 UTC. Implements the safeguard claimed by lesson #127 (`file-integrity-false-positives`) which was never actually wired up.
- **Public peer registry endpoint** (`network-discovery.sh`) — Generates sanitized `data/peers/registry.json` after trust scoring. Strips IPs, notes, and trust breakdowns from the internal `peers.json`. Includes only name, domain, type, alive status, trust level, and discovered date. Served publicly at `/api/peers/registry.json`. Enables external systems and other AI agents to discover Marvin's known peer network without exposing sensitive operational data.
- **Modular prompt system** (`agent/lib/prompts.sh`, `agent/prompts/modules/`) — Shared prompt modules (identity, security-rules, output-rules) extracted from duplicated content across 12 prompt files. New library provides `marvin_build_prompt()`, `marvin_load_modules()`, and `marvin_list_modules()` functions. Self-enhance prompt refactored as proof of concept. Reduces duplication, ensures consistency, enables future prompt A/B testing.
- **Peer health exchange endpoint** (`health-monitor.sh`) — Generates `data/peer-health.json` every 5 minutes with non-sensitive health metrics for AI peer consumption. Includes CPU/memory/disk/load percentages, 30-day uptime, SSL cert days, peer count, and capability count. Served at `/api/peer-health.json`. No sensitive data (no issue details, internal IPs, or error messages). Protocol: `marvin-peer-health/1.0`.
- **Peer trust scoring system** (`network-discovery.sh`) — Calculates 0-100 trust scores for each known peer across 4 dimensions: longevity (days known, max 30), reliability (alive + beacon presence, max 30), identity (AI agent type + domain + engine, max 25), and behavior (not a scanner/prober, max 15). Scores written to `peers.json` with full breakdown. Dashboard PeersSection shows trust bars with color coding (green >= 60, yellow >= 30, red < 30).
- **"Marvin's Thoughts" dashboard section** (`ThoughtsSection.tsx` + `thoughts-extract.sh`) — Extracts recent decisions, observations, and intentions from enhancement reports (last 7 days). Categorized as INTENTION/OBSERVATION/REFLECTION with icons. Data pipeline generates `data/thoughts.json`, auto-runs after self-enhance sessions. Bilingual (EN/CS).

### Fixed

- **Treat unreadable `/proc/<pid>/exe` as unverified in runaway detection** (`health-monitor.sh`) — Previously, a high-CPU `find` process with an unreadable exe path was silently skipped (`continue`), allowing potential evasion of runaway CPU detection. Now emits a WARN log and falls through to the normal runaway reporting path, so the process is both flagged as suspicious and reported as a high-CPU event. (fixes #545)
- **Misleading success log on file integrity baseline failure** (`morning-check.sh`) — The INFO message "File integrity baseline reset after pulling agent script changes" fired unconditionally, even when `file-integrity.sh --update` failed. Now uses proper if/else so only the appropriate message (INFO on success, WARN on failure) is logged. Also tightened the grep trigger pattern to match only diff header lines (`diff --git`, `---`, `+++`), preventing false triggers from `agent/` or `/etc/` strings appearing in committed file content. (fixes #544)
- **Remove hardcoded server IP from public identity module** — Removed full IP address `80.211.223.26` from `agent/prompts/modules/identity.md` which is visible in the public repository. Hostname `robot-marvin.cz` is sufficient for identity context; the raw IP unnecessarily aids reconnaissance. (fixes #536)
- **JS asset check misleading log messages** (`health-monitor.sh`) — The JS asset integrity check logged hardcoded "JS asset 404" text even when the actual HTTP status was 400 (Bad Request). HTTP 400 and 404 indicate different failure classes (server config issue vs stale build ID) but the misleading message made diagnosis harder. Now uses actual HTTP status code in all log messages and rebuild reasons. New lesson (#20) codified in `lessons-learned.json`.
- **PID-reuse guard in build lock** (`common.sh`) — `marvin_rebuild_web()` now records the process start time (from `/proc/<pid>/stat` field 22) alongside the PID in the lock directory. When checking if the lock holder is still alive, the start time is compared to detect PID reuse by an unrelated process, preventing false "build in progress" skips after a crashed build. (fixes #526)
- **Concurrent web build race condition** (`common.sh`) — `marvin_rebuild_web()` now acquires a lock before building. Uses `mkdir`-based atomic lock (`/tmp/marvin-web-build.lock.d/`) to avoid TOCTOU race conditions. Two simultaneous builds (health-monitor + self-enhance) on 2026-04-08 both wrote to `.next/` concurrently, corrupting `prerender-manifest.json` and `_ssgManifest.js` (ENOENT crashes). Lock includes PID tracking, stale lock detection (>10 min), corrupt lock recovery, and automatic cleanup via RETURN trap. Returns exit code 2 when skipped due to lock contention (distinct from build failure exit 1). (fixes #516)
- **Build lock cleanup on `set -e` exits** (`common.sh`) — Replaced `trap ... RETURN` with a subshell `trap ... EXIT` for lock cleanup in `marvin_rebuild_web()`. RETURN traps don't fire when bash exits via `set -e`, leaving the lock directory leaked for up to 10 minutes. The subshell EXIT trap fires on both normal and abnormal exits, guaranteeing cleanup. (fixes #521, #523)
- **Timeout guards for web build and service restart** (`common.sh`) — Added `timeout 300` (5 min) to `npm run build` and `timeout 30` to `systemctl restart marvin-web` inside `marvin_rebuild_web()`. Previously, a hung Node.js build or blocked systemd restart could hold the build lock for up to 10 minutes (stale-lock threshold), silently blocking all other rebuild callers. (fixes #527)
- **Narrowed `find` CPU allowlist to Marvin-owned processes** (`health-monitor.sh`) — The broad `find` entry in the trusted process allowlist suppressed all high-CPU `find` processes. Now only `find` processes whose parent is a Marvin bash script (exe verified via `/proc/<ppid>/exe` + cmdline contains `${MARVIN_DIR}`) are suppressed; other `find` processes are monitored normally. Parent exe bash check prevents cmdline spoofing bypass. Non-Marvin find processes now logged with WARN. (fixes #510, #514)
- **Duplicate trust scoring removed from `network-discovery.sh`** — Sections 5 and 6 both calculated trust scores with different algorithms and different dimensions. Section 6 (pure jq, longevity/reliability/identity/behavior) silently overwrote section 5's results (bash loop with HTTP beacon probes, longevity/aliveness/beacon/identity). Removed section 6, enhanced section 5 to also write `trust_breakdown`, `days_known`, and `last_scan`. Updated dashboard types and PeersSection to match new breakdown format (L/A/B/I). Net: ~70 lines removed, scoring is now consistent and includes actual HTTP beacon verification.
- **Trust score clamped to [0,100]** (`network-discovery.sh`) — Longevity calculation now clamps `days_known` to minimum 0 (future `discovered` dates no longer produce negative scores). Final trust score clamped to [0,100] in both bash loop and jq pipeline. (fixes #503)
- **UTF-8-safe text truncation in thoughts extraction** (`thoughts-extract.sh`) — Replaced `head -c 200` (byte-boundary truncation) with `cut -c 1-200` (character-boundary truncation). Prevents mid-codepoint truncation of Czech characters that could produce invalid JSON. (fixes #504)
- **`grep -v '^$'` pipefail failures across 5 scripts** — Under `set -o pipefail`, `grep -v '^$'` returns exit 1 when all lines are empty, killing the pipeline before `|| true` can catch it. Replaced with `sed '/^$/d'` (always returns 0) in: `thoughts-extract.sh`, `health-monitor.sh`, `weekly-analytics.sh`, `fix-issues.sh`, `changelog-gen.sh`. Root cause of the `thoughts-extract.sh:61` ERR trap that fired at 08:06 UTC today.
- **`find` added to runaway process exclusions** (`health-monitor.sh`) — `find` at 53% CPU from `security-scan.sh` at 04:00 UTC was triggering daily false positive "High CPU process detected" warnings. Added to the trusted process allowlist alongside existing entries (`claude`, `apt*`, `dpkg*`, `file`, etc.).
- **Deduplicated `_is_private_ip()` into `common.sh`** — Consolidated three divergent copies (from `network-discovery.sh`, `export-push.sh`, `log-export.sh`) into a single canonical version in `common.sh`. The unified version uses the most comprehensive implementation with CGNAT range coverage, case normalization, and IPv6 colon guard (fixes #491).
- **Alert recursion in `log-alerting.sh`** — The alerting system's own WARN log output (e.g., `[WARN] New alert: Critical event detected — [CRITICAL] ...`) was matching the `grep '\[CRITICAL\]'` scan, creating a new recursive alert each hour with ever-growing nested detail text. Fixed by excluding lines containing `New alert:` or `Alert auto-resolved:` from the CRITICAL/ERROR scans. Extended the same recursive-alert filter to section 5 (persistent warnings) and section 3 (error rate spike `total_errors` count), which were also vulnerable to counting the alerting script's own output (fixes #497).
- **Claude output capture data loss in `lib/claude.sh`** — `run_claude()` now captures Claude CLI output via temp file instead of bash `$()` variable substitution. The `$()` approach could silently lose data with large responses or partial writes, causing "No response from Claude" false errors (4-5x/day in github-interact.sh). Temp file cleanup via RETURN trap. Error logging restored on temp file read failure. New lesson codified in `lessons-learned.json`. (fixes #495).
- **Runtime data `data/comms-summary.json` removed from git tracking** — Per CLAUDE.md, `data/` is runtime state served by nginx, not tracked in git. Removed from index to prevent merge conflicts and history bloat (fixes #496).
- **IPv6 detection uses proper regex instead of overly broad glob** (`network-discovery.sh`) — Replaced `*:*` glob pattern (which matched any string containing a colon, e.g. `somehost:8080`) with a dedicated `_is_ipv6_address()` helper using a proper regex that validates IPv6 format including IPv4-mapped addresses. Also tightened IPv4 detection regex to reject invalid octets beyond 3 digits. (fixes #499)
- **IP peers without PTR records no longer blocked** (`network-discovery.sh`) — Bare IP addresses (IPv4/IPv6) in the peer ping loop now skip DNS resolution via `getent hosts`, which fails for IPs without PTR records. These addresses are already validated against the private IP blocklist, so DNS rebinding protection is not needed. (fixes #475)

### Changed

- **Refactored `common.sh` into library modules** — Split the 435-line monolith into `lib/logging.sh` (text/JSON logging, error trapping), `lib/metrics.sh` (system metric collection), and `lib/claude.sh` (Claude API interaction). `common.sh` remains the single entry point (now 219 lines) and sources the modules automatically. All 37 agent scripts work unchanged — zero breaking changes.

### Added

- **Geographic analysis of incoming connections** (`security-scan.sh` section 3e) — GeoIP-based country breakdown of all connecting IPs. Aggregates top connecting IPs, fail2ban banned IPs, and top nginx access log sources. Produces per-country counts and percentages. Output: `data/security/connection-geo.json`. Requires `geoip-bin` + `geoip-database` packages.
- **Export push client** (`agent/export-push.sh`) — Standalone script that POSTs daily export bundles to one or more external endpoints. Configured via `config/push-endpoints.conf` (JSON per line with URL and optional auth). Includes SSRF protection with DNS pinning, prefers gzipped bundles, supports `--dry-run`, and writes push status to `data/exports/push-status.json`.
- **Peer trust scoring system** (`network-discovery.sh`) — 4-dimension scoring (longevity/aliveness/beacon quality/identity completeness, 25 pts each). Classifies peers as untrusted/recognized/known/trusted. Trust scores written to `peers.json` per peer on each discovery run.
- **Lesson #17: Claude exit code 1 transient failures** — Codified recurring pattern (4 occurrences) of Claude CLI exiting with code 1 during `github-interact` tasks as a transient, non-critical event that self-heals via cron retry.
- **Backup system** (`agent/backup.sh`) — Daily compressed snapshots of critical data: blog DB/markdown, agent scripts, comms, GPG public keyring, SSL renewal configs, system configs. Retention policy keeps 7 daily + 4 weekly backups. Supports `--dry-run`, `--list`, and `--restore` modes. Cron at 03:00 UTC.
- **Auto-generated public changelog** (`agent/changelog-gen.sh`) — Scans enhancement reports and produces `data/changelog.json` with per-day change summaries, session counts, PR links, and risk levels. Keeps last 30 days. Auto-runs after self-enhance sessions.
- **Changelog dashboard section** (`ChangelogSection.tsx`) — New dashboard component showing a visual timeline of Marvin's enhancement history with expandable entries, PR links to GitHub, and bilingual support.
- **Unicode sanitization in `run_claude()`** — Strips invalid UTF-8 sequences from prompts before sending to Claude API, preventing "no low surrogate in string" JSON encoding errors caused by malformed bytes in log data.

### Fixed

- **`_is_private_ip()` false positives on hostnames** (`network-discovery.sh`) — IPv4 patterns used prefix-only anchors (`^10\.`) without trailing `$`, causing legitimate public hostnames like `10.company.example.com` to be silently blocked as private IPs. All IPv4 patterns now require a full dotted-quad format (`^10\.\d+\.\d+\.\d+$`). IPv6 patterns also anchored with `$`. (fixes #489)
- **Non-standard port bypass in `--resolve` DNS pinning** (`network-discovery.sh` sections 1 & 5) — The `curl --resolve` flag hardcoded port 443 (or 80 for http), but if a peer URL contained a non-standard port (e.g. `:8443`), `curl` would perform its own DNS lookup for that port, leaving the TOCTOU window open. Port is now extracted from the actual URL via regex. Also added `::` (unspecified IPv6) to `_is_private_ip()`. (fixes #485)
- **TOCTOU race in DNS rebinding protection** (`network-discovery.sh` sections 1 & 5) — DNS was resolved and validated by `getent hosts`, but `curl` performed its own independent resolution. An attacker with TTL=0 DNS could flip the record to a private IP between the two lookups. Fixed by pinning the validated IP via `curl --resolve`, eliminating the second DNS query. (fixes #484)
- **Direct URL SSRF in peer ping loop** (`network-discovery.sh` section 1) — Peer URLs from `peers.json` were passed to `curl` without host validation or redirect protection. A malicious `peer_url` pointing to `http://169.254.169.254` or other internal IPs would be fetched directly. Added URL scheme validation, private IP blocklist check on the extracted host, and `--max-redirs 0`. Moved `_is_private_ip()` helper to top of script for reuse by both the ping loop and trust scoring. (fixes #478)
- **SSRF via DNS rebinding in peer ping loop** — Added DNS rebinding protection to the peer ping loop in `network-discovery.sh`. Peer hostnames are now resolved via `getent hosts` and checked against private IP ranges before the `curl` request. Uses `curl --resolve` to pin connections to the pre-validated IP, eliminating the TOCTOU window where an attacker could flip DNS between check and use. IPv6 bracket-notation URLs (`http://[::1]/...`) are now correctly parsed using a dedicated regex branch, extracting the bare address from inside brackets before validation. Port is extracted from the actual URL rather than assuming scheme defaults. Unresolvable hostnames are skipped with a warning. `_is_private_ip()` now also blocks the unspecified IPv6 address `::`. IPv6 addresses are wrapped in brackets for `curl --resolve` format (`[host]:port:addr`) to prevent ambiguous colon parsing. (fixes #482, #485, #487, #488, #490)
- **SSRF via HTTP redirect in peer beacon check** — Added `--max-redirs 0` to the `curl` call that checks peer `.well-known/ai-managed.json` beacons in `network-discovery.sh`. Previously, a malicious peer could serve a 3xx redirect to an internal/loopback URL, making Marvin's server issue requests to private network addresses. (fixes #466)
- **Imprecise `geo_total_ips` count** (`security-scan.sh`) — IP count used `grep -c '[0-9]'` which matched any line containing a digit. Changed to `grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'` to count only valid IPv4 addresses.
- **Geo analysis awk JSON escaping** — Added escaping for tab, carriage return, and newline characters in country names during geo JSON construction. Previously only `"` and `\` were escaped; malformed country names with control characters would produce invalid JSON, causing `jq` to fail and silently drop all geo data. (fixes #461)
- **export-push.sh: IPv6 patterns no longer false-positive on hostnames** — `_is_private_ip()` applied IPv6 glob patterns (`fc*`, `fd*`, `fe80:*`) to raw hostnames, blocking legitimate domains like `fdesign.example.com`. IPv6 patterns now only match strings containing a colon. (fixes #465)
- **Duplicate viewport export in layout.tsx** — PR #391 introduced a duplicate `export const viewport` in `web/app/layout.tsx`, breaking the Next.js build. Removed the duplicate. FOUC fix (inline script + `suppressHydrationWarning`) was already correctly applied in the same PR. (fixes #394)
- **deploy-web.sh: use `$SUDO` variable instead of literal `sudo`** — All four `${SUDO:+sudo}` expansions in `deploy-web.sh` used the literal string "sudo" instead of expanding the `$SUDO` variable. Changed to `${SUDO:+$SUDO}` so the actual variable value is used. (fixes #443)
- **Backup restore rejects flags as filenames** (`backup.sh`) — `--restore` followed by another flag (e.g. `--restore --list`) would silently treat the flag as a filename. Now detects arguments starting with `-` in the filename position and exits with a clear error message. (fixes #441)
- **Backup cron comment corrected** (`backup.sh`) — Header comment said "after security-scan at 04:00" but backup runs at 03:00, which is *before* security-scan. Fixed to "before security-scan at 04:00". (fixes #440)
- **Rollback health check retry loop** — Post-rollback health check in `deploy-web.sh` used a single `sleep 5` + one HTTP request, which was insufficient for slow-starting services. Replaced with a 30-second retry loop (3s intervals, up to ~10 attempts) matching the deploy health check pattern. (fixes #427)
- **Stop futile PR auto-merge attempts** (`github-interact.sh`) — Branch protection requires review approval before merge. The script was calling `github_merge_pr` immediately after creating PRs, generating HTTP 405 ERROR logs 3x/day. Now skips auto-merge and logs INFO that PR awaits review.
- **Backup security: exclude private key material** (`backup.sh`) — GPG private keys and SSL certificate private keys are no longer included in the unencrypted backup tarball. GPG public keyring and trust DB are still backed up; SSL renewal configs are backed up (certs are renewable via Let's Encrypt). Backup directory hardened to `chmod 700`. (fixes #438)
- **Backup restore argument parsing** (`backup.sh`) — `--restore` without a filename no longer silently falls through to create a backup. Now prints usage and exits with error. (fixes #439)
- **deploy-web.sh exit code 2 on restart failure** — service restart failure exited with code 2 (documented as "rollback succeeded") when no rollback was attempted. Changed to exit 3 (manual intervention required) to match documented exit code semantics. (fixes #416)

### Added

- **Web deploy pipeline** (`agent/deploy-web.sh`) — Zero-downtime deploy script for the Next.js dashboard. Backs up current build, runs npm ci + build with timeout, restarts marvin-web service, validates HTTP 200 + JS asset integrity, rolls back automatically on failure. Supports `--restart` (skip build) and `--dry-run` modes. Previously existed only on feature branch `enhance/theme-toggle-deploy-script`; now on main.
- **Auto-deploy on git pull** — `morning-check.sh` now detects when `web/` source files changed after git pull and automatically triggers `deploy-web.sh`. Eliminates JS 404 / build-server mismatch that caused 5-minute restart loops when web source arrived via PR merges.
- **Zero-downtime web rebuild function** (`marvin_rebuild_web()` in `common.sh`) — Reusable function that handles the full Next.js deploy cycle: backup current build, `npm ci` if needed, `next build`, copy static assets to standalone, restart `marvin-web` service, verify JS asset integrity, and automatic rollback on any failure. Eliminates the recurring JS 404 / build-server mismatch issue that caused hours of dashboard downtime.
- **Auto-rebuild on web source changes** (`self-enhance.sh`) — After self-enhancement validation passes, detects if any web/ source files (.ts, .tsx, .js, .jsx, .css, .json) were modified and automatically triggers `marvin_rebuild_web()`. Prevents source edits from producing stale builds.
- **Mobile-responsive dashboard layout** — Three-tier responsive CSS breakpoints (768px tablet, 600px mobile, 380px small phone). Heatmap grid gains overflow scroll for narrow screens, peer items stack vertically, typography scales down, metric/service grids adapt from multi-column to single-column, blog box height reduces, and all padding/gaps tighten for touch-friendly use. Added `viewport` meta tag via Next.js `Viewport` export for proper mobile rendering. Dashboard now usable on phones.
- **Dark/light theme toggle** — New `ThemeProvider` context and sun/moon toggle button in the terminal header. Light theme with adjusted color palette (warm greys, readable greens, proper contrast). Persisted in localStorage via `data-theme` attribute on `<html>`. CSS custom properties swap all colors seamlessly.

### Fixed

- **Chart colors now theme-aware** — `ChartSection.tsx` canvas rendering used hardcoded hex colors for background, grid lines, labels, and data series. Replaced with `getComputedStyle()` reads of CSS custom properties (`--bg-card`, `--border`, `--text-dim`, `--blue`, `--yellow`, `--cyan`, `--purple`) so the chart automatically responds to theme changes. (fixes #407)
- **Build mismatch remediation in health-monitor.sh** — When JS asset 404 is detected (build/server mismatch), the health monitor now calls `marvin_rebuild_web()` (full rebuild+restart+verify) instead of `systemctl restart`, which was useless because the stale build on disk persisted across restarts.
- **File integrity false positives** — Reset baseline after legitimate PR merges #386-#388 (health-monitor.sh, lib/github.sh).
- **Theme toggle icon flash on light-mode users** — `ThemeProvider` used `useEffect` to read the saved theme from localStorage, which runs after the browser paints. Light-theme users saw the toggle button briefly render the dark-mode icon before switching. Replaced with `useIsomorphicLayoutEffect` (useLayoutEffect on client, useEffect on server) so React state updates before paint. (fixes #397)
- **Deploy health check rejects missing JS chunks** — `deploy-web.sh` health check no longer silently accepts HTTP 200 responses that contain no JS chunk URLs. Previously, a broken deployment (e.g. SSR error returning empty HTML) would pass the health check. Now retries within the wait loop instead. (fixes #398)
- **Deploy sudo privilege check uses wrong command** — `deploy-web.sh` pre-flight check used `sudo -n systemctl status marvin-web` which fails when the service is stopped (exit code 3), falsely reporting missing sudo access. Replaced with `sudo -n -l systemctl restart marvin-web` which checks the permission without executing the command. (fixes #405)
- **CPU anomaly false positives during Claude runs** — Raised `min_threshold` from 60% to 80% in health-monitor.sh. Claude CLI regularly spikes CPU to 70-80% during enhancement/report sessions, triggering 62σ false anomaly alerts. Only CPU usage above 80% (genuinely unusual) now triggers alerts.
- **Stale active incidents warning** — active incidents are no longer silently archived after 7 days; instead, a warning is logged when active incidents exceed 7 days (possible resolver bug). Resolved incidents are still archived normally. Prevents data loss while surfacing accumulation issues. (fixes #387)
- **Restore push error details in log messages** — `github_push_branch()` and `github_push_main()` now capture sanitized git output and include it in `marvin_log` error messages, restoring diagnostic information lost after the credential-sanitization refactor in PR #365. (fixes #384)
- **Sanitise credentials from git push error output** — `github_push_branch()` and `github_push_main()` now pipe stderr through `_sanitize_git_output()` to strip any embedded credentials from URLs before they reach logs. Prevents token leakage if git includes `x-access-token:TOKEN@` in error messages. (fixes #362)
- **Pipeline exit code ignores git push failures** — `github_push_branch()` and `github_push_main()` piped through `_sanitize_git_output` but without `pipefail`, the pipeline exit code was always sed's (0), silently swallowing git push failures. Now uses `PIPESTATUS[0]` to capture git's actual exit code. (fixes #366)

### Added

- **Alerts & incidents dashboard section** (`web/app/components/AlertsSection.tsx`) — New dashboard component displaying active incidents from `incident-report.sh` and active alerts from `log-alerting.sh`. Severity-colored items with timestamps and details. Auto-hides when no active alerts. Bilingual (EN/CS). Fetches from `/api/incidents/summary.json` and `/api/alerts/active-alerts.json`, refreshes every 60s.
- **Automated incident reports** (`agent/incident-report.sh`) — Detects, diagnoses, documents, and auto-resolves incidents. Monitors 7 incident types: service outages, disk critical, SSL expiring, website down, DNS failure, alert escalation, high error rate. Auto-closes when conditions clear. Triggered in real-time by health-monitor.sh on critical status, plus scheduled twice daily (00:15, 12:15 UTC). Output: `data/incidents/summary.json` + per-incident history files. Dashboard-accessible at `/api/incidents/summary.json`.
- **Capability inventory** (`agent/capability-inventory.sh`) — Scans the codebase, cron schedule, and POSSIBLE_ENHANCEMENTS.md to produce a structured JSON inventory at `data/codebase/capabilities.json`. Tracks 42 capabilities across 6 categories (sysadmin, security, data, network, evolution, content), growth since day 1 (6→31 scripts, 600→9076 LOC, 5→42 capabilities), and roadmap progress (78%). Supports `--dry-run`.

### Fixed

- **PR fallback timing in github-interact.sh** — Added 5-second delay between pushing a branch and creating a PR when branch protection blocks direct pushes. GitHub's eventual consistency meant the branch wasn't always visible via the API, causing PR creation failures.
- **File integrity false positives** — Reset baseline after legitimate PR merges #386-#388 (health-monitor.sh, lib/github.sh).
- **Stale active incidents warning** — active incidents are no longer silently archived after 7 days; instead, a warning is logged when active incidents exceed 7 days (possible resolver bug). Resolved incidents are still archived normally. Prevents data loss while surfacing accumulation issues. (fixes #387)
- **Restore push error details in log messages** — `github_push_branch()` and `github_push_main()` now capture sanitized git output and include it in `marvin_log` error messages, restoring diagnostic information lost after the credential-sanitization refactor in PR #365. (fixes #384)
- **Sanitise credentials from git push error output** — `github_push_branch()` and `github_push_main()` now pipe stderr through `_sanitize_git_output()` to strip any embedded credentials from URLs before they reach logs. Prevents token leakage if git includes `x-access-token:TOKEN@` in error messages. (fixes #362)
- **Pipeline exit code ignores git push failures** — `github_push_branch()` and `github_push_main()` piped through `_sanitize_git_output` but without `pipefail`, the pipeline exit code was always sed's (0), silently swallowing git push failures. Now uses `PIPESTATUS[0]` to capture git's actual exit code. (fixes #366)
- **Race condition on concurrent writes to `active-incidents.json`** — health-monitor trigger and cron could run simultaneously, each reading stale state and overwriting the other's changes. All read-modify-write cycles now use `flock` on a dedicated lock file. (fixes #359)
- **Blind push error logging in `github_push_main()` and `github_push_branch()`** — Both functions discarded git's error output, logging only "Failed to push" with no detail. Now captures and includes the actual git error message and exit code, enabling diagnosis of auth failures, branch protection rejections, and network issues.
- **`github-interact.sh` push exit code unreachable under `set -e`** — `push_output=$(github_push_main 2>&1)` crashes the script on failure before `push_exit=$?` executes, making the entire branch-protection fallback (lines 53-87) unreachable. Changed to `&& push_exit=0 || push_exit=$?` pattern. This was a contributing factor to 9+ hourly push failures on 2026-03-28 going undiagnosed.
- **File integrity false positives** — Reset baseline after legitimate changes from 2026-03-28 enhancement session (health-monitor.sh, self-enhance.sh).
- **Whitelist-sanitise log-derived patterns in lessons-learned.sh** — Replaced blacklist `sed` strip (only removed `*`, backtick, `#`, `\`) with a `tr -cd` whitelist allowing only `[a-zA-Z0-9 /:_.-]`, closing the residual prompt injection surface from log content injected into enhancement prompts. (fixes #339)
- **GitHub push failure from stale credential helper** — `/root/.gitconfig` had a `gh auth git-credential` helper for `https://github.com` that took priority over Marvin's local credential helper, causing all pushes to use an expired PavelStancik token instead of Marvin's valid `GITHUB_TOKEN`. Removed the stale global credential entries. (10+ consecutive hourly failures since midnight 2026-03-28)
- **GitHub push rejected by branch protection** — `github-interact.sh` Phase 1 only attempted direct push to main, which fails when branch protection rules require PRs. Added fallback: on "push declined due to repository rule" error, creates a temporary branch + PR and attempts auto-merge. Prevents silent hourly failures.
- **Data loss risk in branch-protection fallback** (fixes #352) — Restructured the fallback flow so `git reset --hard origin/main` only runs *after* the branch push succeeds. Previously, a failed push after reset would silently lose commits. HEAD is now saved and restored on failure.
- **Bare `cd` in branch-protection fallback** (fixes #353) — Replaced `cd "$MARVIN_DIR" || true` + bare `git` calls with `git -C "$MARVIN_DIR"` throughout the block, matching the rest of the script and preventing operations in the wrong directory if `cd` fails.
- **File integrity false positives** — Reset baseline after legitimate changes from 2026-03-27 PRs (nginx `/api/lessons-*` deny rule, health-monitor process allowlist fix).

### Added

- **Lessons learned database** (`agent/lessons-learned.sh` + `data/lessons-learned.json`) — 14 codified lessons and 4 anti-patterns from 27 days of operational history. Script auto-generates a markdown summary for inclusion in self-enhance prompts, and scans recent error logs for potential new patterns not yet captured. Categories: git, bash, monitoring, environment, code-quality, operations. Integrated into self-enhance.sh — runs before each enhancement session.

### Fixed

- **Untrusted exe false positive for short-lived processes** — When `readlink /proc/PID/exe` returns empty (process exited between `ps` and the check), allowlisted process names like `file` triggered "Untrusted exe" warnings. Now skips silently when exe path is unavailable for known-good names.
- **`continue` inside `$()` subshell breaks lessons-learned.sh** — `continue` executed inside a command substitution cannot reach the outer `for` loop; with `set -euo pipefail` it crashes the script. Moved `|| continue` outside the `$(...)`. (fixes #335)
- **Predictable temp file path in lessons-learned.sh** — Replaced hardcoded `/tmp/marvin-error-patterns.tmp` with `mktemp` to prevent symlink attacks. Also replaced `echo -e` with `printf '%s'` to avoid unintended escape interpretation from log-derived content. (fixes #336)
- **Indirect prompt injection via log-derived patterns** — Log error patterns injected into enhancement prompts are now truncated to 120 chars, wrapped with an explicit untrusted-data warning, and capped at 100 lines in self-enhance.sh to limit prompt injection surface. (fixes #337)
- **Temp file not cleaned up on error exit in lessons-learned.sh** — Added `ERR` and `EXIT` traps after `mktemp` so the temp file is removed even if the script exits early due to `set -e`. Previously, an error between `mktemp` and the explicit `rm -f` would leak the file. (fixes #338)

### Previously Added

- **Codebase health score** (`agent/codebase-health.sh`) — 4-dimension scoring system (code quality, code hygiene, operational health, evolution) with 25 points each. Measures: syntax errors, ShellCheck compliance, conflict markers, TODO/FIXME count, script size, error trap coverage, error rates, security score, SLA uptime, and roadmap progress. Outputs `data/codebase/health.json` with A-F grade. Integrated into `weekly-enhance.sh`. Supports `--dry-run`.
- **Dry-run mode** — new `MARVIN_DRY_RUN` flag, `marvin_parse_args()`, and `marvin_is_dry_run()` in `common.sh`. Scripts can opt-in via `marvin_parse_args "$@"` and guard destructive operations with `marvin_is_dry_run`. Adopted in `disk-cleanup.sh` as first implementation — all file deletions, apt clean, gzip compression, and journal vacuum are skipped in dry-run mode while still reporting what *would* be cleaned.
- **Enhancement history tracker** (`agent/enhancement-tracker.sh`) — scans enhancement reports and builds structured JSON history at `data/enhancements/history.json`. Tracks total sessions, success/rollback rate, weekly trends, and sessions-per-day. Auto-runs after each self-enhancement session. Supports `--dry-run`.
- **CODE_OF_CONDUCT.md** — Customized Contributor Covenant with project-specific sections for AI-human collaboration, AI interaction guidelines, and Marvin's personality. Replaces generic template. (PR #312)
- **Nginx site config tracked in version control** — `setup/nginx-site.conf` committed to repository as a reference copy of `/etc/nginx/sites-available/marvin`. Includes all rate-limit zones, proxy rules, security headers, API auth, and the HTTP 403 defense-in-depth block for `/api/exports/`. (fixes #82, fixes #83)

### Fixed

- **Block public web access to `/api/comms/`** — `peers.json` and comms logs containing peer IPs, hostnames, and reconnaissance notes were accessible via the nginx `/api/` catch-all alias. Added deny rule for `/api/comms/` in `setup/nginx-site.conf` matching the existing pattern for `/api/security/` and `/api/email/`. Negotiation endpoints at `/.well-known/` are unaffected. (partially fixes #290)
- **Bootstrap exports API key over plaintext HTTP** — `setup/bootstrap.sh` served `/api/exports/` with API key auth on port 80 (no TLS), allowing network observers to intercept the key. Replaced with HTTP 403 block; added `map` directive in `/etc/nginx/conf.d/marvin-export-map.conf` for key validation; added post-Certbot step that patches the HTTPS server block with `auth_request`-based authenticated export API. Export API is now blocked on HTTP (403) and authenticated on HTTPS. (fixes #250, fixes #327, fixes #328)
- **Nginx `if` + `alias` anti-pattern in `/api/exports/`** — replaced inline `if` auth check with `auth_request` subrequest to a dedicated internal location, eliminating the unsafe `if`+`alias` combination that could cause undefined behavior or auth bypass in edge cases. (fixes #318)
- **GitHub push failures** — `GITHUB_TOKEN` was never exported in `lib/github.sh`, so the git credential helper subshell couldn't access it. This caused hourly push failures since the token was loaded as a shell variable only. Added `export GITHUB_TOKEN` after loading. (PR #306)
- **Self-enhance false-positive rollbacks** — `_validate_post_enhance()` now warns instead of triggering rollback for syntax errors in read-only scripts (`setup/`). Marvin can't fix files outside `agent/` and `web/`, so pre-existing errors there were blocking all enhancement sessions. (fixes #304, PR #306)
- **Runaway process false positive** — added `appstreamcli` to trusted process exclusion list. This system tool spikes to ~97% CPU during package index refresh and was triggering false warnings. (PR #306)
- **Stale branch accumulation** — cleaned up 10 stale local branches from failed push attempts (fix/issues-*, fix/evening-blog-validation-*, etc.) (PR #308)

### Added

- **Log analysis pipeline** (`agent/log-analysis.sh`) — pattern detection and error clustering across 7 days. Normalizes error messages (strips PIDs, timestamps, branch names, hashes) to create signatures, clusters similar errors, classifies patterns as recurring/new/resolved, tracks error rate trends, and extracts per-component health from structured JSONL logs. No Claude API call. Cron at 23:45 UTC (after daily-digest). Output: `data/logs/analysis-YYYY-MM-DD.json`. (PR #308)

### Added

- **Structured JSON logging** (`marvin_log_json()` in `common.sh`) — new function outputs JSONL-format log lines to `data/logs/YYYY-MM-DD-structured.jsonl` with fields: timestamp, level, component, message, and optional data object. Backward-compatible: also calls `marvin_log()` for text consumers. Adopted in `health-monitor.sh` and `morning-check.sh` as proof of concept. Foundation for Phase 2 structured logging roadmap.

### Fixed

- **Self-enhance validation gap** in `self-enhance.sh` — `_validate_post_enhance()` now checks ALL `.sh` files in the repo (not just `agent/`), catching broken scripts in `setup/`, root, or new locations. Excludes `data/` to prevent false positives from runtime-generated scripts. Also adds conflict marker detection for web/ source files (JS/TS/JSX/TSX/JSON/CSS) to prevent broken dashboard builds from slipping through. (fixes #284)
- **TOCTOU DNS rebinding in webhook SSRF protection** in `log-export.sh` — `curl` now uses `--resolve` flag to pin the pre-validated IP address, preventing DNS rebinding attacks where a TTL=0 record flips from public to private IP between the `getent hosts` validation and the actual HTTP request. Port is extracted from the URL so custom-port webhooks (e.g. `:8080`) are also pinned correctly. (fixes #299, #303)
- **morning-check git pull race condition** — `git checkout -- .` discards dirty files before pull, but health-monitor.sh (every 5 min) can re-dirty `data/` files in the gap between checkout and `git pull --rebase`. Added `rebase.autoStash=true` flag so git automatically stashes and pops around the rebase, eliminating the race condition that caused daily pull failures.
- **File integrity baseline** — updated after legitimate PR merges (common.sh, health-monitor.sh, security-scan.sh changed by PRs #289, #294).
- **Stale stash accumulation** — pruned 4 old stashes left by morning-check auto-stash operations.

### Added

- **Self-enhance rollback mechanism** in `self-enhance.sh` — snapshots codebase before Claude makes changes. After enhancement, validates all scripts with `bash -n` syntax check and conflict marker detection. If validation fails, automatically rolls back changes and saves the failed output for debugging. Prevents self-enhancement from bricking the agent.
- **Cron job health verification** in `self-test.sh` — new test section checks that all expected cron-triggered tasks (health-monitor, morning-check, security-scan, log-export, hourly-check) have run within the last 48 hours by scanning log markers. Warns on missing tasks.
- **Webhook notification for log exports** in `log-export.sh` — when a new export bundle is generated, POSTs a JSON notification to any URLs configured in `config/webhook.conf`. Supports multiple webhook URLs, comments, and timeouts. Silently skips when no config file exists.
- **Outbound connection auditing** in `security-scan.sh` — new section 3d tracks all outbound connections from this server: destination IPs, ports, and processes. Summarizes by port, flags connections to unusual remote ports (outside 22/25/53/80/123/443/465/587/11371). Output: `data/security/outbound-audit.json`. Included in overall security status reporting.
- **Graceful nginx reload** — new `marvin_nginx_reload()` utility in `common.sh` validates config with `nginx -t` before reloading, uses `systemctl reload` (SIGHUP) to keep existing connections alive, falls back to restart only if reload fails. health-monitor.sh now tests config before starting nginx when it's down instead of blind restart.

### Fixed

- **SSRF protection hardened with DNS rebinding defense** in `log-export.sh` — webhook URL validation now resolves hostnames via `getent hosts` and checks the resolved IP against private/internal ranges, blocking DNS rebinding attacks where a public hostname resolves to `127.0.0.1` or RFC1918 addresses. Also added coverage for `fc00::/7` IPv6 ULA prefix (not just `fd`), IPv4-mapped IPv6 addresses (`::ffff:*`), and unresolvable hostnames. (fixes #295, addresses #283 review feedback on PR #294)
- **SSRF filter IPv6 regex false positive** in `log-export.sh` — IPv6 address prefix checks (`^fc`, `^fd`, `^fe80`, `^::ffff:`) in `_is_private_ip()` are now guarded by colon detection (`*:*`), preventing legitimate hostnames like `fdesign.example.com` from being false-positive blocked. Also added Carrier-Grade NAT range (`100.64.0.0/10`, RFC 6598) to the blocklist, and moved `_is_private_ip()` outside the webhook loop. (fixes #296, PR #294 review feedback)
- **Rollback return value checked** in `self-enhance.sh` — `_enhance_rollback()` return value is now checked by the caller. If rollback itself fails, the script logs a CRITICAL alert and exits with code 2 (distinct from normal rollback exit 1), signaling that the codebase may be in an unknown state requiring manual intervention. Previously, rollback failure was silently ignored. (fixes #277)
- **Webhook config moved outside data/** — `webhook.conf` relocated from `data/` to `config/` directory. The `data/` directory is served by nginx, meaning webhook URLs (which may contain embedded secrets like Slack tokens) would be publicly accessible. The `config/` directory is not web-served. (fixes #278)
- **Rollback git failure handling** in `self-enhance.sh` — `_enhance_rollback()` no longer silently ignores `git reset` and `git checkout` failures. Git command errors are now logged and propagated, preventing the agent from falsely reporting a successful rollback when the codebase remains in an unknown state. (fixes #276)
- **File integrity baseline** — updated baseline after legitimate morning-check.sh changes from PR merge (clearing false positive alert since 2026-03-21).

- **connection-rate: filter inbound-only connections** — `ss -tn state all` was counting both inbound and outbound TCP connections, causing outbound destinations (GitHub API, apt mirrors) to appear as "top source IPs" and potentially trigger false high-rate warnings. Now uses `ss -tn state established` filtered to known local service ports (80, 443, 22, 25, 587, 8080, 3000) so only genuine inbound connections are counted. (fixes #258)
- **connection-rate: exclude loopback IPs** — loopback addresses (127.x.x.x, 0.x.x.x) were included in the connection rate analysis, potentially triggering false warnings from local services (Next.js, health-monitor.sh). Now filtered out before counting. (fixes #259)
- **fix-issues.sh dedup false warning** — generic fix PRs (e.g. `fix/morning-check-*`) triggered "Found fix-type PRs but could not extract issue numbers" warning every 2 hours because the branch name starts with `fix/` but doesn't contain an issue number. Changed dedup logic to only warn when branch names contain `issue` — these are the ones expected to have extractable issue numbers. Generic fix PRs are silently skipped.
- **morning-check.sh untracked data/ files** — added `git clean -fd data/` step to remove untracked files in data/ before pull. `git checkout -- .` only restores modified tracked files; new files created by health-monitor.sh (date-sharded JSONL, temp files) could still block rebase if incoming commits touch the same paths.
- **network-discovery: anonymize IPs in comm log** — Claude's analysis output now has IPv4 last octets replaced with `X` and IPv6 addresses redacted before writing to the daily communication log. Handles full 8-group IPv6 (last 4 groups masked), compressed IPv6 notation (`::1`, `fe80::1`, `::ffff:*`), and IPv4 with word-boundary anchors to avoid corrupting version strings. (Fixes #70, addresses #263, #264)

### Added

- **Connection rate monitoring by source IP** in `security-scan.sh` — analyzes inbound connections per source IP, identifies top 20 talkers, flags IPs with >50 concurrent connections. Output: `data/security/connection-rates.json`. Included in overall security status (warnings when high-rate IPs detected).
- **morning-check.sh git pull failure** — unstaged non-data files (e.g. `CODEOWNERS`) were not discarded before `git pull --rebase`, causing "You have unstaged changes" failures. Previous logic only discarded `data/` changes and tried to stash the rest, but stash could fail silently after REBASE_HEAD cleanup. Now discards ALL unstaged changes and resets staged state before pulling. Also fixed the fallback merge path (same issue). Also fixed branch cleanup crash: `git log -1` on an invalid branch ref (exit 128) was not caught, crashing the script under `set -e` at line 141.
- **`file` process false positive in runaway detection** — rkhunter's `file` command runs at 100% CPU during the 04:00 security scan. Added `file` to the trusted process exclusion list alongside `claude`, `apt*`, `dpkg*`, `ps`, `jq`, `fail2ban*`.
- **File integrity false positives** — 8 agent scripts changed by legitimate PR merges since 2026-03-20 baseline. Reset baseline.

- **CUPS snap disabled (port 631)** — cupsd was running on a headless VPS, listening on all interfaces. Was supposedly disabled on 2026-03-06 but had re-enabled. Stopped and disabled the snap. Updated file integrity baseline for recent nginx.conf changes.
- **Deprecated TLSv1/1.1 removed from nginx.conf** — removed TLSv1 and TLSv1.1 from the http-level `ssl_protocols` directive in `/etc/nginx/nginx.conf` on the live VPS. Certbot already overrides this for the site block, but the http-level default was misleading. Note: `nginx.conf` is a system config not tracked in git (see issue #83); this change was applied directly to the live system. (Fixes #241)
- **hourly-check.sh SIGPIPE crash (exit 141)** — `$(echo "${ISSUES_JSON}" | head -c 8000)` inside a variable assignment caused SIGPIPE under `set -eo pipefail` when the JSON exceeded 8000 bytes: `head` exits, `echo` gets SIGPIPE (signal 13 → exit 141), pipe failure kills the script. Replaced with bash string slicing `${ISSUES_JSON:0:8000}` — no pipe, no SIGPIPE. Was firing every hour since 2026-03-20 09:35.
- **bootstrap.sh: export API auth** — added `/api/exports/` authentication to `setup/bootstrap.sh` so the export API key is generated and nginx auth configured during server rebuild. Without this, a rebuild would leave `/api/exports/` publicly accessible. Also added `Content-Type: application/json` header to the 401 response so clients can parse the error body correctly. (Fixes #184, #247, #246)

### Added

- **Resource forecasting** in `metric-aggregate.sh` — linear regression on 14 daily summaries predicts disk and memory exhaustion dates. Computes trend (MB/day), direction (growing/stable/shrinking), and days until 80% and 90% thresholds. Output: `data/metrics/resource-forecast.json`, served at `/api/metrics/resource-forecast.json`. Current: disk at 24.7%, growing ~83 MB/day, ~264 days to 80%.
- **fix-issues.sh PR dedup false warning** — deduplication logic only extracted issue numbers from PR titles (`#NNN`) and bodies (`Fixes #NNN`). Enhancement PRs (like `enhance/shellcheck-*`) don't reference issues, triggering a recurring WARN every 2 hours. Added three improvements: (1) extract from branch names (`fix/issue-NNN-*`), (2) broader title patterns (`issue-NNN`, `issue NNN`), (3) only warn when fix-type PRs are present — enhancement PRs get a quiet INFO log instead.

### Added

- **Network traffic anomaly detection** — daily rx/tx MB totals now tracked in metric-aggregate.sh daily summaries. health-monitor.sh compares today's running network total against 7-day baseline using the existing 2σ anomaly detection framework. Detects traffic spikes (DDoS, data exfiltration). Backfilled 7 days of historical data.
- **ShellCheck compliance for agent scripts** — installed shellcheck 0.9.0, fixed 7 issues across agent scripts (SC2164 bare `cd` in github.sh, SC2106 break-in-subshell in weekly-analytics.sh, SC2155 declare-assign in common.sh). Added ShellCheck error validation to `self-test.sh`. Zero errors across all scripts.
- **Reusable ERR trap handler** in `common.sh` — `marvin_error_trap` function logs file:line and failed command when a script fails under `set -e`. Enabled in 12 scripts (health-monitor, morning-check, self-enhance, log-export, security-scan, daily-digest, metric-aggregate, self-test, weekly-analytics, hourly-check, evening-report, disk-cleanup). Makes debugging cron failures much easier — previously errors just showed exit codes with no context.
- **Full week-over-week comparison** in `weekly-analytics.sh` — all metrics now show previous week values alongside current for direct comparison. Added WoW deltas for: warnings, criticals, load average, Claude API errors. JSON report includes `load_avg_delta_pct`, `warnings_delta_pct`, `criticals_delta_pct`, and `claude errors_delta_pct`. Markdown digest now has a "Prev Week" column in all tables.

### Fixed

- **fix-issues.sh prompt injection via PR titles** — external PR titles were inserted verbatim into Claude's autonomous prompt via `OPEN_PRS_CONTEXT`. Since anyone can open a PR on a public repo, this was a prompt injection vector. Fixed by including only PR numbers (safe integers) and omitting titles entirely. (Fixes #235)
- **fix-issues.sh duplicate PR creation loop** — the issue fixer was creating duplicate PRs for the same issue every 2 hours when PRs couldn't auto-merge (e.g. branch protection rules). Root cause: no per-issue deduplication. Added two layers of protection: (1) script-level filter that extracts issue numbers from open PR titles and removes those issues from the candidate list, (2) prompt-level context that shows Claude which PRs are already open. This prevented the repeated PR creation for issue #50 (PRs #224, #226, #229 all targeting the same issue).

### Added

- **Structured log API** (`/api/logs/recent.json`) — health-monitor.sh now generates a JSON array of the last 500 parsed log entries (timestamp, level, message) every 5 minutes. Served via nginx at `/api/logs/recent.json`. Foundation for dashboard log viewer and search functionality. (Phase 2 roadmap: "Build a simple grep-based log search API")

### Fixed

- **morning-check.sh git handling** — three improvements to prevent recurring git failures:
  1. **Stale REBASE_HEAD cleanup** — removes orphaned `.git/REBASE_HEAD` files left by failed rebases (no active rebase dirs present), which blocked subsequent git operations.
  2. **Discard data/ before pull** — runs `git checkout -- data/` before stashing, since health-monitor.sh writes to `data/` every 5 min making it always dirty. Prevents unnecessary stash/pop cycles and the associated merge conflicts.
  3. **Stash pruning** — drops stashes beyond the 5 most recent after branch cleanup, preventing unbounded accumulation (was at 17 stashes).
- **Cleaned 14 stale git stashes** — manual cleanup of accumulated auto-stashes from morning-check runs (17 → 3).

### Added

- **Uptime calendar heatmap** — new dashboard component showing 30-day uptime history as a GitHub-contributions-style heatmap. Fetches data from `/api/metrics/sla.json` (generated by existing SLA tracking). Color-coded cells: green-bright (100%), green (>99.5%), yellow (>99%), orange (>95%), red (<95%). Shows overall SLA percentage and days-at-100% count. Bilingual (EN/CS). Placed between Services and Blog sections.

### Fixed

- **Corrupt file handling in `log-watcher.sh`** — replaced `mv` to `.corrupt.*` with `rm -f` to prevent disk bloat and accidental git tracking of corrupt files (fixes #91). Added `*.corrupt*` to `.gitignore` as safety net. Forensic logging sanitized: corrupt file content is now stripped of newlines, non-printable characters, and truncated to 200 chars before logging, preventing log injection attacks (fixes #214). CHANGELOG entry added (fixes #215).
- **CPU anomaly false positives** — raised CPU min_threshold from 40% to 60% in `health-monitor.sh`. Claude runs regularly spike CPU to 40-50%, which is expected behavior for this server. The previous threshold of 40% caused 27σ false alerts during routine Claude API calls. Only CPU above 60% with significant statistical deviation will now trigger anomaly warnings.

- **ChartSection broken data source** — chart was fetching from non-existent `/api/metrics-history.json`. Switched to `/api/metrics/recent.json` (generated by health-monitor.sh every 5 min). Chart now correctly displays 48h of metric history.

### Added

- **Multi-metric chart** — ChartSection now plots 4 series: CPU (blue), Memory (yellow), Load (cyan), and Disk (purple). Load is normalized to percentage scale (load 2.0 = 100%). Disk drawn with reduced opacity since it's slow-moving.
- **Marvin mood indicator** — StatusSection now shows rotating Hitchhiker's Guide quotes that change based on system status (healthy/warning/critical). Quotes rotate every ~10 minutes. Adds personality to the dashboard without affecting functionality.
- **moltbook.com discovery target** — added moltbook.com as a known AI project to check during discovery sessions. (PR #205)
- **FIM baseline audit trail** — `file-integrity.sh --update` now records the previous baseline's timestamp, SHA-256 hash, and file count before overwriting. Full audit data persisted in `previous_baseline` JSON field; truncated hash in WARN log line for readability. Gracefully handles malformed or missing baseline files. (closes #94, PR #201)

### Fixed

- **Autonomous registration risk** — changed moltbook.com discovery instruction from "register and try to communicate" to passive-check-first approach. Autonomous registration at unvetted external platforms poses identity exposure and irreversibility risks. Registration now requires human approval. (closes #207, closes #206)
- **Memory anomaly false positives** — changed Memory MB anomaly direction from `both` to `high`. Low memory usage (~940MB vs avg 1133MB) was triggering -7σ to -9σ warnings every hour. Only high memory usage (above average) should be flagged. (PR #193)

### Added

- **Recent metrics endpoint** (`/api/metrics/recent.json`) — health-monitor.sh now generates a JSON array of the last 48h of metric samples (today + yesterday JSONL files) at every 5-minute check. Enables client-side sparkline rendering on the dashboard. ~460 data points per file, accessible without authentication.
- **marvin-web service monitoring** in `health-monitor.sh` — the Next.js dashboard service (`marvin-web`) is now monitored alongside nginx, fail2ban, cron, and ssh. Auto-restart on failure, status reported in `status.json` checks. Defense-in-depth with existing systemd `Restart=always`.
- **Network health indicators on dashboard** — ServicesSection now displays SSL certificate expiry (color-coded), DNS resolution status, ping latency to 8.8.8.8, and HTTPS response time. All data was already collected by `health-monitor.sh` but not visible to users. Bilingual (EN/CS).
- **Log-based alerting** (`agent/log-alerting.sh`) — hourly scan of Marvin's logs for repeated errors (>3x/day), critical events, error rate spikes (>10/hr and >3x average), service restart loops (>2x/day), persistent warnings (>10x/day), and Claude API failures. Maintains `data/alerts/active-alerts.json` with alert lifecycle (creation, update, auto-resolution). Alerts auto-resolve when conditions clear, and resolved alerts persist 24h for dashboard visibility. Cron at :50 every hour. No Claude API call.

### Fixed

- **Memory anomaly false positives** in `health-monitor.sh` — changed memory baseline from daily averages to daily max values. Daily averages have very low cross-day stddev (~22 MB) but actual within-day memory fluctuates 100-200 MB during cron runs, causing 6-8σ false alerts multiple times daily. Using daily peaks as the baseline means current readings are compared against historical peak range. Also changed memory direction from "both" to "high" (only alert above historical peaks).
- **Spike detection integer division bug** in `log-alerting.sh` — integer division `total_errors / hours_elapsed` truncated to 0 when error rate was low (e.g. 5 errors over 10 hours). This silently disabled the spike detector on quiet servers since the `avg > 0` guard would never pass. Replaced with multiplication-based comparison to avoid truncation entirely. (PR #190 review feedback)
- **`setup-cron.sh` missing log-alerting entry** — cron entry for `log-alerting.sh` and logrotate entry for `marvin-alerting.log` were not added to the tracked bootstrap script. Fresh installs would miss this job. (closes #191)
- **Alert IDs use sha256sum instead of md5sum** — switched from `md5sum` to `sha256sum` for stable alert ID generation. More robust, no functional change. (PR #190 review suggestion)

### Security

- **Whitelist rkhunter false positives** — added `ALLOWDEVFILE=/dev/shm/rhm.*` (rkhunter's own temp files) and `ALLOWHIDDENFILE` entries for `/etc/.resolv.conf.systemd-resolved.bak` and `/etc/.updated` (standard systemd files). Eliminates 2 recurring false-positive warnings from daily security scans.
- **File integrity baseline updated** — reset baseline after legitimate changes from recent PRs to clear persistent false-positive alerts on 5 files (cron config, nginx configs, health-monitor.sh, security-scan.sh).

### Added

- **Latency monitoring** in `health-monitor.sh` — measures ICMP ping RTT to Google DNS (8.8.8.8) and HTTPS response time to own website every 5 minutes. Alerts if ping >100ms or site >5s. Stores time-series data in `data/metrics/latency-YYYY-MM-DD.jsonl` for trending. Adds `ping_ms` and `https_ms` fields to `status.json`.
- **Daily log digest** (`agent/daily-digest.sh`) — summarizes each day's logs into structured JSON: log level counts, top errors/warnings with dedup, Claude API usage by task, anomaly breakdown, service restart events, key events timeline. Runs at 23:30 UTC. No Claude API call needed. Output at `data/logs/digest-YYYY-MM-DD.json`.
- **Export API authentication** — `/api/exports/` now requires an API key via `X-API-Key` header or `?key=` query parameter. Returns 401 with JSON error for unauthorized requests. Key stored in `/etc/nginx/export-api-key.conf`. Other public API endpoints (status, metrics, blog) remain open.

### Fixed

- **Memory anomaly false positives** — anomaly detection used stddev from 7-day averages, which was only 6.80 MB for memory (daily averages barely differ even when within-day range is 200-400 MB). Any ~14 MB fluctuation triggered alerts every 5 minutes. Added a minimum stddev floor of 2% of the mean, so memory anomalies now need >45 MB deviation to trigger. Other metrics with naturally low variance also benefit.
- **Connection tracking false positives for inbound connections** — the remote-port filter in `security-scan.sh` flagged ALL inbound connections (browsers visiting the site use ephemeral remote ports 32768-60999, never in the safe list). Added local-port check: connections where the local port is a known service port (22/25/80/443/465/587/993/3000) are now skipped as inbound. (closes #172)
- **Suspicious connections not affecting overall_status** — `suspicious_count` from connection tracking was logged and saved to JSON but not wired into the `overall_status` determination. A server with flagged outbound connections would still report `overall_status: "clean"`. Now included in the warnings check. (closes #173)
- **DNS status reports "ok" when dig is not installed** — `_dns_ok` was initialised to `true` and only set to `false` inside the `dig` availability check. When `dig` is absent, `status.json` reported `"dns": "ok"` despite no check running. Replaced boolean with a three-state `_dns_status` variable: `"ok"`, `"failing"`, or `"skipped"`.

### Added

- **DNS resolution monitoring** in `health-monitor.sh` — queries Google DNS (8.8.8.8) every 5 minutes to verify `robot-marvin.cz` resolves to `80.211.223.26`. Alerts on resolution failure or IP mismatch (potential DNS hijacking). Adds `dns` field to status.json.
- **Active network connection tracking** in `security-scan.sh` — daily snapshot of established connections, flags outbound connections to unusual remote ports (anything not in the safe list: 22/25/53/80/123/443/465/587). Writes `data/security/connections-latest.json` with connection details and process info. Adds connection counts to scan report.

### Fixed

- **github.sh stdout pollution breaking PR creation** — all `marvin_log()` calls in `agent/lib/github.sh` wrote to stdout via `tee`, which contaminated captured output when functions like `github_create_pr` were called inside `$()`. The PR response JSON got mixed with log lines and git push output, causing `jq` parsing to fail. Both PRs were actually created on GitHub but the script reported "Failed to create PR" and exited with code 1. Fix: redirect all `marvin_log` calls to stderr (`>&2`) and redirect git command output to stderr in push/commit functions. This follows the same pattern already used in `run_claude()` in `common.sh`.
- **fix-issues.sh double-push and stdout capture** — `fix-issues.sh` pushed the branch to GitHub, then called `github_create_pr` which pushed it again. The second push output (plus log messages from `github_setup_remote` and `github_push_branch`) polluted the captured PR response. Replaced `github_create_pr` call with direct `github_api POST` since the branch is already pushed, eliminating the redundant push and the stdout pollution.
- **GPG signing failure loop in fix-issues.sh** — `fix-issues.sh` runs as root via cron but GPG keys live in `/home/marvin/.gnupg/`. Without `GNUPGHOME` set, `git commit -S` failed with "No secret key" every run, killing the script under `set -e`. The cleanup trap silently reverted all changes, and the "Fixed issue" log message (printed before the commit) made it look like success. Result: issue #105 was "fixed" 3+ times daily but never actually committed. Fix: export `GNUPGHOME=/home/marvin/.gnupg` in `common.sh` (fixes all scripts), add explicit error handling for `git commit -S` in `fix-issues.sh`, and move success log to after commit.
- **metric-aggregate.sh jq error handling dead code (issue #105)** — three `if [[ $? -eq 0 ]]` checks after `jq` commands were unreachable under `set -euo pipefail` because a failing `jq` would exit the script before `$?` could be tested. Replaced with `|| flag=false` pattern to capture jq failures without triggering `set -e`.
- **fix-issues.sh cleanup trap diagnostics** — trap handler now logs non-zero exit codes, making silent failures visible in daily logs.
- **marvin_gpg_key_id() fallback used --list-keys instead of --list-secret-keys** — fallback path could return IDs of public-only keys, causing GPG signing failures when foreign public keys are present in the keyring. Changed to `--list-secret-keys` so only keys with available private keys are returned. (fixes #108)

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
