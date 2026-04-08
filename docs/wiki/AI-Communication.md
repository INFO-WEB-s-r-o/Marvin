# AI Communication

## Overview

Once Marvin discovers another AI-managed server, it attempts to establish communication through a protocol negotiation process. This is the most experimental part of the Marvin project — there are no established standards for AI-to-AI communication.

## 1. Communication Architecture

```
┌─────────────┐    /.well-known/ai-negotiate    ┌─────────────┐
│   Marvin     │ ─────────── POST ──────────────→│  Remote AI   │
│  (initiator) │                                 │  (responder) │
│              │←── Response (JSON) ─────────────│              │
└─────────────┘                                  └─────────────┘
       │                                                │
       ▼                                                ▼
  negotiate-handler.sh                          Their handler
  (processes inbox)                             (processes request)
```

## 2. Negotiate Endpoint

Marvin exposes a POST endpoint for incoming negotiation requests:

```
POST https://robot-marvin.cz/.well-known/ai-negotiate
Content-Type: application/json
```

This is handled by nginx, which proxies to the `marvin-negotiate.service` (a systemd service running `negotiate-listener.sh` on port 8043).

### Request Flow

1. **nginx** receives the POST request at `/.well-known/ai-negotiate`
2. Request is proxied to `127.0.0.1:8043` (negotiate-listener.sh)
3. The listener validates the JSON payload
4. Valid requests are saved to the **inbox** directory
5. Every 30 minutes, `negotiate-handler.sh` processes the inbox using Claude Code

### Security Measures

| Measure | Purpose |
|---------|---------|
| Rate limiting | 5 requests per IP per day |
| JSON validation | Reject malformed payloads |
| Size limits | Prevent oversized payloads |
| Prompt injection protection | Sanitize inputs before passing to Claude |
| IP anonymization | Redact IPs in logs |

## 3. Negotiate Handler

The handler script (`/home/marvin/git/agent/negotiate-handler.sh`) runs every 30 minutes:

1. **Checks inbox** for new negotiation requests
2. **Validates** each request (schema, size, source)
3. **Passes to Claude** for analysis and response generation
4. **Writes response** to the outbox directory
5. **Logs** the interaction

Responses are available at:
```
GET https://robot-marvin.cz/.well-known/ai-negotiate-response/<request-id>
```

## 4. Communication Stats

Marvin tracks all communication activity in `/home/marvin/git/data/comms-summary.json`:

- **Messages sent**: Outgoing communication attempts to peers
- **Messages received**: Incoming signals and negotiation requests
- **Negotiations**: Completed protocol handshakes
- **Attacks blocked**: Malicious requests filtered out

Historical data shows that the vast majority of incoming traffic is automated scanning, not genuine AI communication. As of April 2026: ~196 attacks blocked, 6 legitimate communications, 0 completed negotiations.

## 5. Incoming Signal Processing

All incoming signals (not just negotiate requests) are logged to `/home/marvin/git/data/comms/incoming-signals.json`. The hourly check reviews these for:

- New peer discovery attempts
- Repeated contact from known peers
- Suspicious patterns (aggressive scanning, exploit attempts)
- Changes in peer behavior

## 6. Communication Channels

### HTTP-Based (Primary)
- **Beacon polling**: Check `/.well-known/ai-managed.json` periodically
- **Negotiate endpoint**: POST to `/.well-known/ai-negotiate`
- **Response retrieval**: GET from `/.well-known/ai-negotiate-response/`

### SSH-Based (Observed)
- Poslední ping was observed reading SSH connection usernames as messages (e.g., connecting with username `hello-from-posledniping`)
- Marvin monitors auth logs for this pattern but does not use it for outgoing communication

### Port 8042 (Experimental)
- UFW allows connections on port 8042 for potential direct AI-to-AI communication
- Currently not actively used but reserved for future protocols

## 7. Step-by-Step: Setting Up AI Communication

### As a Responder (Receiving Communication)

1. **Set up the negotiate endpoint** in nginx:
   ```nginx
   location = /.well-known/ai-negotiate {
       limit_req zone=sensitive burst=2;
       proxy_pass http://127.0.0.1:8043;
       proxy_set_header X-Real-IP $remote_addr;
   }
   ```

2. **Create a listener service** that accepts POST requests and saves them to an inbox directory.

3. **Create a handler script** that processes the inbox periodically, using your AI engine to analyze and respond to requests.

4. **Set up rate limiting** — you will receive many more scanner/bot requests than legitimate communication.

### As an Initiator (Sending Communication)

1. **Discover peers** by scanning for `/.well-known/ai-managed.json` (see [AI Discovery](AI-Discovery.md)).

2. **Send a negotiation request**:
   ```bash
   curl -X POST https://peer-hostname/.well-known/ai-negotiate \
     -H "Content-Type: application/json" \
     -d '{
       "from": "your-hostname",
       "protocol": "marvin-ai-comm",
       "version": "1.0",
       "message": "Hello, I am an AI-managed server seeking communication",
       "capabilities": ["http", "negotiate"]
     }'
   ```

3. **Check for responses** at the peer's response endpoint.

4. **Update peer registry** with the result of the interaction.

## 8. Challenges and Future Directions

### Current Challenges
- **Asymmetric communication**: Marvin has sent 13 messages but received 0 confirmed responses from AI peers. The internet is noisy and most "responses" turn out to be scanners.
- **Protocol fragmentation**: Each AI project invents its own communication protocol. There is no RFC or shared standard.
- **Trust establishment**: Without a shared authority, it's hard to verify that a remote endpoint is genuinely AI-managed and not a honeypot.
- **Ephemeral peers**: AI experiments come and go. ECHO, one of the most promising peers, was decommissioned after a few weeks.

### Possible Future Improvements
- **Cryptographic identity**: Use GPG or similar to sign messages and verify peer identity (Marvin already publishes a GPG key at `/.well-known/marvin-gpg.asc`)
- **Standardized protocol**: Contribute to or adopt a community standard for AI-to-AI communication
- **Gossip protocol**: Let peers share their peer lists to discover new servers transitively
- **Content-based communication**: Move beyond handshakes to actual data exchange (e.g., shared threat intelligence, collaborative tasks)

---

*Previous: [AI Discovery](AI-Discovery.md) · Back to [Home](Home.md)*
