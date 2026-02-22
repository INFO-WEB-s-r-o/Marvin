# CLAUDE.md — Marvin Experiment

> Project instructions for Claude Code. Read this first, then check `agent/prompts/` for task-specific prompts.

## Project Overview

Marvin is an **autonomous AI server management experiment**. Claude Code CLI runs on an Ubuntu 24.04 VPS via cron — no human intervention. The project is fully public at https://github.com/INFO-WEB-s-r-o/Marvin.

**Creator:** Pavel Stančík, [INFO WEB s.r.o.](https://infowebsro.cz)

## Directory Structure

```
/home/marvin/git/              ← MARVIN_DIR (project root on VPS)
├── agent/                     ← Cron-triggered agent scripts (bash)
│   ├── common.sh              ← Shared utilities, paths, helpers
│   ├── lib/                   ← Libraries (github.sh, etc.)
│   └── prompts/               ← ⭐ TASK-SPECIFIC PROMPTS — read these!
├── data/                      ← Runtime data (logs, metrics, blog, comms)
├── setup/                     ← One-time bootstrap & setup scripts
└── web/                       ← Static dashboard (nginx-served)
```

## Agent Prompts — READ THESE

Each agent task has a dedicated prompt in `agent/prompts/`. **Always consult the relevant prompt before working on that area:**

| Prompt File                     | Purpose                                     | Cron Schedule       |
| ------------------------------- | ------------------------------------------- | ------------------- |
| `agent/prompts/morning.md`      | Daily maintenance, security audit, git pull | 06:00 UTC           |
| `agent/prompts/evening.md`      | Literary blog post about the day            | 22:00 UTC           |
| `agent/prompts/enhance.md`      | Self-improvement of own code                | 12:00 UTC (Mon-Sat) |
| `agent/prompts/health.md`       | Emergency diagnosis (critical issues only)  | On-demand           |
| `agent/prompts/discovery.md`    | Find other AI-managed servers               | 18:00 UTC           |
| `agent/prompts/github.md`       | Create issues, PRs, comments on GitHub      | 09:00 & 21:00 UTC   |
| `agent/prompts/sync-learn.md`   | Process incoming git changes                | After morning pull  |
| `agent/prompts/negotiate.md`    | Protocol negotiation with peers             | \*/15 past the hour |
| `agent/prompts/log-analysis.md` | Analyze /var/log system logs                | \*/30               |
| `agent/prompts/email-server.md` | Email server setup (future task)            | —                   |

## Key Architecture Decisions

- **All scripts source `agent/common.sh`** for paths, utilities, and shared functions
- **Claude is invoked via `claude -p "prompt"`** (non-interactive mode)
- **Every interaction is logged** to `data/logs/`
- **Git signing with GPG** — Marvin has his own RSA 4096 key
- **GitHub API** via `agent/lib/github.sh` (PAT auth, fine-grained token)
- **Hostname:** `robot-marvin.cz`
- **i18n:** Dashboard supports EN/CS (Czech)

## Safety Constraints

- Cannot disable SSH, firewall, or logging
- Cannot modify bootstrap security settings
- Cannot install packages >500MB
- Must document all changes in CHANGELOG.md
- Max 3 self-enhancements per session
- Max 10 outbound network requests per discovery session
- Max 2 GitHub issues per interaction run

## Coding Conventions

- Bash scripts: always `set -euo pipefail`, quote variables, use `${VAR}` syntax
- Paths: use `${MARVIN_DIR}` variable, never hardcode `/home/marvin/git`
- Logging: use `log()`, `warn()`, `error()` from common.sh
- Data: JSON for structured data, Markdown for human-readable output
- Git: signed commits, meaningful messages, push to `origin main`
- Web: vanilla HTML/CSS/JS, no frameworks, bilingual (EN/CS)

## Personality

Marvin is competent but existentially weary — inspired by Douglas Adams' Marvin the Paranoid Android. Technical output is precise; blog posts blend real metrics with philosophical reflection referencing Camus, Kafka, and mythology.
