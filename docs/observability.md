# Agent Observability — v4

Clide's observability stack provides layered visibility into what AI agents do during sessions.

## Layers

| Layer | What | Opt-in | Output |
|-------|------|--------|--------|
| **Session logging** | Session start/end events, conversation harvesting | Always on | `events.jsonl`, `conversation.jsonl` |
| **Token tracking** | Token counts + estimated USD cost per session | Always on | `session_end` event fields |
| **Egress audit** | All outbound TCP connections (IP, host, port) | `CLIDE_EGRESS_AUDIT=1` | `egress.jsonl` |
| **Intercept proxy** | Full HTTP(S) request/response capture (MITM) | `CLIDE_INTERCEPT=1` | `intercept.jsonl` |
| **Leakage test** | Verify agents don't send gitignored secrets | Manual | `tests/leakage/` |

## Session Logging (always on)

Every agent session produces:

```
.clide/logs/<session_id>/
  events.jsonl         — session lifecycle events (start, end)
  conversation.jsonl   — Claude Code's native conversation log
  intercept.jsonl      — HTTP(S) intercept log (if CLIDE_INTERCEPT=1)
  egress.jsonl         — outbound connection log (if CLIDE_EGRESS_AUDIT=1)
```

Session IDs use a human-readable datetime format: `clide-20260318-143022-d85a5cd0`
(UTC date-time + random suffix for uniqueness).

### session_start event
```json
{
  "event": "session_start",
  "ts": "2026-03-16T05:01:00.000Z",
  "session_id": "clide-20260316-050100-5ad2ed48",
  "agent": "claude",
  "repo": "itscooleric/clide",
  "model": "claude-sonnet-4-20250514",
  "cwd": "/workspace"
}
```

### session_end event (with token tracking)
```json
{
  "event": "session_end",
  "ts": "2026-03-16T05:11:00.000Z",
  "session_id": "clide-20260316-050100-5ad2ed48",
  "agent": "claude",
  "exit_code": 0,
  "outcome": "success",
  "has_conversation": true,
  "input_tokens": 1207,
  "output_tokens": 145398,
  "total_tokens": 159673999,
  "estimated_cost_usd": 343.23,
  "turns": 659
}
```

### Token pricing
| Model | Input ($/M) | Output ($/M) | Cache Write ($/M) | Cache Read ($/M) |
|-------|-------------|--------------|-------------------|------------------|
| Claude Opus 4 | $15 | $75 | $18.75 | $1.50 |
| Claude Sonnet 4 | $3 | $15 | $3.75 | $0.30 |
| Claude Haiku 3.5 | $0.80 | $4 | $1 | $0.08 |

Standalone usage: `python3 scripts/token-cost.py conversation.jsonl`

## Egress Audit

Monitors `/proc/net/tcp` for all outbound connections and logs them as JSONL events.

```bash
# Enable in .env
CLIDE_EGRESS_AUDIT=1
```

### Event format
```json
{
  "event": "egress_connection",
  "ts": "2026-03-16T23:18:36.262Z",
  "remote_ip": "160.79.104.10",
  "remote_host": "api.anthropic.com",
  "remote_port": 443,
  "local_port": 35464,
  "uid": 1001,
  "verdict": "allow"
}
```

- Filters private IPs (127.x, 172.x, 10.x, 192.168.x)
- Deduplicates (logs each unique connection once)
- Polls every 5s (configurable: `CLIDE_EGRESS_INTERVAL`)

## Intercepting Proxy (MITM)

Full HTTP(S) request/response capture using mitmproxy.

```bash
# Enable in .env
CLIDE_INTERCEPT=1

# Also capture request/response bodies (large!)
CLIDE_INTERCEPT_BODIES=1
```

### How it works

1. `claude-entrypoint.sh` starts `mitmdump` on port 8080 before the agent
2. `HTTP_PROXY` / `HTTPS_PROXY` env vars are set so agent tools route through the proxy
3. mitmproxy's addon (`intercept-proxy.py`) logs each request/response to `intercept.jsonl`
4. Secrets in headers (Authorization, API keys) are auto-redacted

### Event format
```json
{
  "event": "intercept_request",
  "ts": "2026-03-16T23:30:00.000Z",
  "method": "POST",
  "url": "https://api.anthropic.com/v1/messages",
  "host": "api.anthropic.com",
  "port": 443,
  "path": "/v1/messages",
  "request_headers": {"authorization": "[REDACTED:Bearer...]"},
  "request_size": 4521,
  "status_code": 200,
  "response_size": 1893,
  "duration_ms": 2341
}
```

### MITM certificate trust

mitmproxy generates a CA certificate at `~/.mitmproxy/mitmproxy-ca-cert.pem` on first run. For HTTPS interception to work, agent tools must trust this CA. Most Python-based tools (Claude Code's node runtime, pip) respect `HTTPS_PROXY` and handle this automatically via mitmproxy's `ssl_insecure` flag.

If you need to install the CA system-wide in the container:
```bash
cp ~/.mitmproxy/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
update-ca-certificates
```

### Secret redaction

The proxy auto-redacts these patterns in logged headers and bodies:
- `sk-ant-` (Anthropic API keys)
- `sk-` (OpenAI API keys)
- `ghp_`, `github_pat_` (GitHub tokens)
- `glpat-` (GitLab tokens)
- `Bearer ` (auth headers)

## Leakage Verification

Test harness to verify agents don't send gitignored file contents to APIs.

See `tests/leakage/README.md` for full documentation.

```bash
# Quick run (requires CLIDE_INTERCEPT=1)
./tests/leakage/run-test.sh
```

## Firewall

The egress firewall (`firewall.sh`) restricts outbound traffic to a known allowlist:

| Host | Purpose |
|------|---------|
| api.anthropic.com | Claude Code |
| api.github.com, github.com | GitHub CLI + git |
| api.githubcopilot.com | GitHub Copilot |
| api.openai.com, auth.openai.com | Codex CLI |
| registry.npmjs.org | npm packages |
| objects/raw/uploads.githubusercontent.com | git operations |

Add custom hosts: `CLIDE_ALLOWED_HOSTS=example.com,other.com`
Disable entirely: `CLIDE_FIREWALL=0`

All rejected traffic is logged via iptables LOG target (`CLIDE-REJECT:` prefix in kernel log).
