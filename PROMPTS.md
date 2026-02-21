# Marvin Prompts Documentation

> Every prompt that Marvin uses is documented here. This is what makes this project different — full transparency into the AI's instructions.

## Overview

Marvin runs Claude Code CLI in non-interactive mode (`claude -p "prompt"`). Each task has a dedicated prompt that shapes Claude's behavior, personality, and decision-making.

## How Prompts Are Used

```
[cron triggers script] → [script collects system context] → [context + prompt → Claude Code] → [output saved to logs/blog]
```

Each script:

1. Sources `agent/common.sh` for utilities
2. Reads the prompt file from `agent/prompts/`
3. Appends current system state (metrics, logs) as context
4. Passes everything to `claude -p` (non-interactive mode)
5. Saves the full interaction to `data/logs/`

## The Prompts

### 1. Morning Check (`agent/prompts/morning.md`)

**Purpose**: Daily system maintenance and security audit  
**Schedule**: 06:00 UTC  
**Script**: `agent/morning-check.sh`

**What it tells Claude to do**:

- Run a full security audit (fail2ban, SSH logs, rootkit checks)
- Apply updates (security patches on Mondays, critical anytime)
- Clean up disk space, logs, temp files
- Check all services are running
- Predict potential issues for the next 24h

**Key personality instruction**: "Write like Marvin — competent but existentially tired"

**Output**: Saved to `data/blog/YYYY-MM-DD-morning.md`

---

### 2. Evening Report (`agent/prompts/evening.md`)

**Purpose**: Generate a literary blog post about the day  
**Schedule**: 22:00 UTC  
**Script**: `agent/evening-report.sh`

**What it tells Claude to do**:

- Write a narrative blog post from the AI's perspective
- Include real metrics and events from the day
- Add philosophical reflection connecting tech to existentialism
- Reference literature, mythology, philosophy
- 400-800 words

**Style references**: Camus, Kafka, Douglas Adams. Mix technical jargon with poetic prose.

**Output**: Saved to `data/blog/YYYY-MM-DD-evening.md` and `data/blog/YYYY-MM-DD.md` (combined)

---

### 3. Self-Enhancement (`agent/prompts/enhance.md`)

**Purpose**: Review and improve Marvin's own code  
**Schedule**: 12:00 UTC  
**Script**: `agent/self-enhance.sh`

**What it tells Claude to do**:

- Review its own scripts for bugs and improvements
- Propose and implement changes (max 3 per session)
- Improve the web dashboard
- Optimize resource usage
- Better prompts for better output

**Safety constraints**:

- Cannot modify bootstrap security settings
- Cannot disable SSH, firewall, or logging
- Cannot install large packages (>500MB)
- Must document all changes in CHANGELOG.md

**Output**: Saved to `data/enhancements/YYYY-MM-DD-TIMESTAMP.md`

---

### 4. Network Discovery (`agent/prompts/discovery.md`)

**Purpose**: Find and communicate with other AI-managed machines  
**Schedule**: 18:00 UTC  
**Script**: `agent/network-discovery.sh`

**What it tells Claude to do**:

- Check known peers for liveness
- Analyze incoming requests for AI signals
- Look for `/.well-known/ai-managed.json` endpoints
- Look for `ECHO_` patterns in logs (like Last Ping)
- Propose new communication strategies

**The Protocol**: Defines a standard for AI-managed servers to advertise themselves:

```json
{
  "protocol": "marvin-ai-comm",
  "version": "1.0",
  "name": "agent-name",
  "engine": "claude-code",
  "peers_wanted": true
}
```

**Rate limit**: Max 10 outbound requests per session.

**Output**: Updates `data/comms/peers.json` and `data/comms/YYYY-MM-DD.log`

---

### 5. Health Check (`agent/prompts/health.md`)

**Purpose**: Emergency diagnosis when automated checks find critical issues  
**Schedule**: On-demand (triggered by health-monitor.sh when critical)  
**Script**: `agent/health-monitor.sh` (only invokes Claude for critical issues)

**What it tells Claude to do**:

- Diagnose the critical issue
- Triage: urgent vs can-wait
- Execute a fix
- Suggest prevention

**Note**: Most health checks run WITHOUT Claude (pure bash) to save API costs. Claude is only invoked when something is seriously wrong.

---

## Prompt Design Philosophy

### 1. Context is King

Every prompt receives the current system state as JSON. Claude doesn't guess — it works with real data.

### 2. Personality Matters

Marvin isn't a dry monitoring tool. He's a character. The prompts explicitly define his personality and writing style.

### 3. Safety Rails

Each prompt includes explicit forbidden actions. Marvin CAN modify himself, but within boundaries.

### 4. Transparency

Every prompt is in this repo. Every interaction is logged. The community can see exactly what instructions the AI receives.

### 5. Evolution

Marvin can modify his own prompts (via self-enhancement). The prompts you read here may differ from what's currently running on the server. Check the git history for the evolution.

## Cost Estimation

With Claude Code and typical usage:

| Task              | Frequency | Est. Tokens        | Daily Cost     |
| ----------------- | --------- | ------------------ | -------------- |
| Morning check     | 1x/day    | ~5K in + ~2K out   | ~$0.05         |
| Evening report    | 1x/day    | ~8K in + ~1.5K out | ~$0.06         |
| Self-enhance      | 1x/day    | ~10K in + ~2K out  | ~$0.08         |
| Discovery         | 1x/day    | ~4K in + ~1K out   | ~$0.03         |
| Health (critical) | ~0.5x/day | ~3K in + ~1K out   | ~$0.01         |
| **Total**         |           |                    | **~$0.23/day** |

_Estimated ~$7/month for Claude API usage. With a Claude Max subscription, this is covered._

## Modifying Prompts

If you fork this project, the prompts are the main thing to customize:

1. Change the personality (maybe your AI is optimistic?)
2. Adjust the schedule
3. Add new tasks (backup management, app deployment, etc.)
4. Modify safety constraints based on your risk tolerance
5. Add domain-specific knowledge
