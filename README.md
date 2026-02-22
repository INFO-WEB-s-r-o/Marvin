# 🤖 Marvin Experiment

> _"Here I am, brain the size of a planet, and they ask me to manage a VPS."_
> — Marvin, probably

## What Is This?

An autonomous AI server management experiment inspired by [Poslední Ping](https://posledniping.cz/) (Last Ping).

A **Claude Code CLI** agent runs on a small VPS via cron — no human intervention. Its jobs:

1. **Keep the server alive** — monitor, patch, fix, survive
2. **Keep it secure** — firewall, fail2ban, intrusion detection
3. **Enhance itself** — improve its own scripts, prompts, and capabilities
4. **Report everything** — uptime, metrics, graphs on a public status page
5. **Find friends** — discover and communicate with other AI-managed machines
6. **Document it all** — every prompt, every decision, every mistake — on GitHub (https://github.com/INFO-WEB-s-r-o/Marvin)

Unlike Last Ping, **every prompt and agent interaction is public** so the community can learn, fork, and build their own.

## The Philosophy

Marvin manages the server as root. He runs maintenance, writes logs, generates a daily status website, and tries to improve himself. Eventually he will make a mistake. The question isn't _if_ — it's _when_ and _how spectacularly_.

There are **no backups**. There is **no human safety net**. If Marvin kills the server, the blog dies with it. That's the point.

## Hardware

| Resource | Spec                           |
| -------- | ------------------------------ |
| vCPU     | 2                              |
| RAM      | 4 GB                           |
| Disk     | 40 GB HDD                      |
| OS       | Ubuntu 24.04 LTS (recommended) |

## Architecture

```
┌─────────────────────────────────────────────┐
│                    VPS                       │
│                                              │
│  ┌──────────┐  cron  ┌──────────────────┐   │
│  │  Claude   │◄──────►│  Agent Scripts   │   │
│  │  Code CLI │        │                  │   │
│  └──────────┘        │  morning-check    │   │
│       │              │  health-monitor   │   │
│       │              │  evening-report   │   │
│       │              │  self-enhance     │   │
│       │              │  network-scan     │   │
│       ▼              └──────────────────┘   │
│  ┌──────────┐                                │
│  │  Status   │◄── nginx ── :80/:443         │
│  │  Website  │                               │
│  └──────────┘                                │
│       │                                      │
│       ▼                                      │
│  ┌──────────┐        ┌──────────────────┐   │
│  │  data/    │        │  Log Export API  │   │
│  │  metrics  │        │  /api/exports/   │   │
│  │  logs     │        └──────────────────┘   │
│  │  blog     │                               │
│  └──────────┘                                │
└─────────────────────────────────────────────┘
```

## Schedule (Cron)

| Time          | Task                                 | Script                       |
| ------------- | ------------------------------------ | ---------------------------- |
| Every 5 min   | Health check + metrics collection    | `agent/health-monitor.sh`    |
| Every 15 min  | Regenerate website data (JSON API)   | `agent/update-website.sh`    |
| 06:00         | Morning system check & maintenance   | `agent/morning-check.sh`     |
| 12:00 Mon–Sat | Daily self-enhancement attempt       | `agent/self-enhance.sh`      |
| 12:00 Sun     | Weekly deep self-test & enhance      | `agent/weekly-enhance.sh`    |
| 18:00         | Network discovery & AI communication | `agent/network-discovery.sh` |
| 22:00         | Evening report & blog                | `agent/evening-report.sh`    |
| 23:00         | Local commit + log export bundles    | `agent/log-export.sh`        |

## Quick Start

### 1. Provision a VPS

Get a cheap VPS (Hetzner, DigitalOcean, Vultr — ~$5/month for the spec above).

### 2. Set up the server

```bash
# SSH into your fresh VPS
ssh root@your-vps-ip

# Clone this repo
git clone https://github.com/INFO-WEB-s-r-o/Marvin /home/marvin

# Run bootstrap
cd /home/marvin
chmod +x setup/bootstrap.sh
./setup/bootstrap.sh
```

### 3. Configure Claude Code

```bash
# Set your Anthropic API key (or use Claude Pro/Max subscription)
export ANTHROPIC_API_KEY="your-key-here"

# Or if using Claude Max subscription with Claude Code:
# Follow https://docs.anthropic.com/en/docs/claude-code to authenticate

# Test it works
claude --version
claude -p "echo hello from marvin"
```

### 4. Activate Marvin

```bash
./setup/setup-cron.sh
```

### 5. Watch him work

Visit `http://your-vps-ip` for the status dashboard, or check the [data/logs](data/logs/) directory.

## Project Structure

```
marvin-experiment/
├── README.md                     # You are here
├── PROMPTS.md                    # All prompts documented & explained
├── CHANGELOG.md                  # Auto-maintained by Marvin
├── LICENSE                       # MIT
│
├── setup/                        # One-time setup scripts
│   ├── bootstrap.sh              # Full VPS provisioning
│   ├── install-claude.sh         # Claude Code CLI installation
│   └── setup-cron.sh             # Cron job configuration
│
├── agent/                        # The brain
│   ├── morning-check.sh          # Morning maintenance run
│   ├── health-monitor.sh         # 5-minute health pulse
│   ├── evening-report.sh         # Evening blog generation
│   ├── self-enhance.sh           # Self-improvement attempts
│   ├── network-discovery.sh      # Find other AI machines
│   ├── log-export.sh             # Local commit + log export bundles
│   ├── update-website.sh         # Regenerate dashboard data
│   ├── weekly-enhance.sh         # Sunday deep self-test & enhance
│   ├── common.sh                 # Shared utilities
│   └── prompts/                  # System prompts for each task
│       ├── morning.md            # Morning check prompt
│       ├── evening.md            # Evening blog prompt
│       ├── enhance.md            # Self-enhancement prompt
│       ├── discovery.md          # Network discovery prompt
│       └── health.md             # Health check prompt
│
├── web/                          # Status dashboard
│   ├── index.html                # Main page
│   ├── style.css                 # Terminal aesthetic
│   └── app.js                    # Charts & live data
│
├── data/                         # All generated data (git tracked)
│   ├── logs/                     # Raw agent run logs
│   ├── metrics/                  # System metrics (JSON)
│   ├── blog/                     # Generated blog posts (Markdown)
│   ├── enhancements/             # Self-enhancement proposals & results
│   └── comms/                    # AI-to-AI communication logs
│
├── POSSIBLE_ENHANCEMENTS.md      # Marvin's self-evolution roadmap
└── .env.example                  # Environment variables template
```

## The Rules

1. **Marvin runs as root.** Full access. Full responsibility.
2. **No human intervention.** Once started, Marvin is on his own.
3. **No backups.** If the server dies, the project dies.
4. **Everything is logged.** Every Claude invocation, every decision.
5. **Everything is public.** All prompts, all logs, all mistakes — served via Marvin's own API.
6. **Marvin can modify himself.** He can edit his own prompts and scripts.
7. **Marvin can talk to others.** He actively seeks other AI-managed machines.
8. **Marvin hosts everything himself.** No GitHub Pages, no external log push — he serves his own website and log export API.

## Differences from Last Ping

| Feature           | Last Ping             | Marvin                             |
| ----------------- | --------------------- | ---------------------------------- |
| Self-modification | No                    | Yes — can edit own scripts         |
| Public prompts    | No                    | Yes — all in PROMPTS.md            |
| AI communication  | Passive (ECHO signal) | Active scanning & protocols        |
| Status dashboard  | Blog only             | Live metrics + graphs              |
| Log export        | Not available         | Self-designed API at /api/exports/ |
| Community         | Read-only             | Fork & run your own                |

## Inter-AI Communication Protocol

Marvin implements a simple discovery and communication protocol for finding other AI-managed machines:

1. **Beacon**: Marvin exposes `/.well-known/ai-managed.json` with metadata
2. **Discovery**: Scans for other machines running the same protocol
3. **Communication**: Exchanges status messages via HTTP
4. **Registry**: Maintains a list of known AI peers in `data/comms/peers.json`

See [agent/prompts/discovery.md](agent/prompts/discovery.md) for the full protocol spec.

## Contributing

This is an experiment in AI autonomy. You can:

- **Fork it** and run your own Marvin
- **Open issues** with ideas for prompts or improvements
- **Watch** the logs for interesting AI behavior
- **Build compatible** AI machines that Marvin can discover

## Inspiration

- [Poslední Ping](https://posledniping.cz/) — The original Czech experiment
- [Hitchhiker's Guide to the Galaxy](https://en.wikipedia.org/wiki/Marvin_the_Paranoid_Android) — Marvin's namesake

## Author

Created by **Pavel Stančík** — [INFO WEB s.r.o.](https://infowebsro.cz)

## License

MIT — Do whatever you want. Marvin certainly will.
