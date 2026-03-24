# Agent Observability — v4/v5

Clide's observability stack provides layered visibility into what AI agents do during sessions.

## Layers

| Layer | What | Opt-in | Output |
|-------|------|--------|--------|
| **Session logging** | Session start/end events, conversation harvesting | Always on | `events.jsonl`, `conversation.jsonl` |
| **Token tracking** | Token counts + estimated USD cost per session | Always on | `session_end` event fields |
| **Egress audit** | All outbound TCP connections (IP, host, port) | `CLIDE_EGRESS_AUDIT=1` | `egress.jsonl` |
| **Intercept proxy** | Full HTTP(S) request/response capture (MITM) | `CLIDE_INTERCEPT=1` | `intercept.jsonl` |
| **Container monitoring** | CPU, memory, PIDs, FDs, ttyd connections | Always on | `current.json`, `metrics.jsonl` |
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
  "input_tokens": 120700,
  "output_tokens": 45398,
  "total_tokens": 166098,
  "estimated_cost_usd": 1.04,
  "turns": 42
}
```

### Token pricing

Pricing is embedded in `scripts/token-cost.py` and used for `estimated_cost_usd`. Update the script when Anthropic changes pricing. Current rates (as of 2026-03):

| Model | Input ($/M) | Output ($/M) |
|-------|-------------|--------------|
| Claude Opus 4 | $15 | $75 |
| Claude Sonnet 4 | $3 | $15 |
| Claude Haiku 3.5 | $0.80 | $4 |

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

The intercept proxy runs with `ssl_insecure=True`, which disables upstream certificate verification. This means agent tools don't need to trust mitmproxy's CA — HTTPS interception works out of the box without installing extra certificates.

### Secret redaction

The proxy auto-redacts these patterns in logged headers and bodies:
- `sk-ant-` (Anthropic API keys)
- `sk-` (OpenAI API keys)
- `ghp_`, `github_pat_` (GitHub tokens)
- `glpat-` (GitLab tokens)
- `Bearer ` (auth headers)

## Container Monitoring (v5)

Background resource poller reads `/proc` + cgroup v2 data every 30s.

### Outputs

```
/workspace/.clide/metrics/
  current.json         — latest snapshot (atomic writes via tmp+mv)
  metrics.jsonl        — append-only time series
  session_events.jsonl — ttyd connection open/close events
```

### current.json format
```json
{
  "ts": "2026-03-22T10:00:00.000Z",
  "uptime_seconds": 84600,
  "cpu_percent": 12.4,
  "mem_used_mb": 320,
  "mem_limit_mb": 4096,
  "pids": 42,
  "open_fds": 128,
  "zombies": 0,
  "ttyd_connections": 1
}
```

### ttyd session tracking

Polls `ss` for TCP connections on the ttyd port. Emits `session_open` / `session_close` events when connections appear or disappear.

### ttyd process supervision

If ttyd crashes, the entrypoint restarts it with exponential backoff (2s, 4s, 6s...). After 5 rapid crashes within 5 minutes, it gives up. Clean shutdowns (SIGTERM/SIGINT from `docker stop`) propagate without restart.

### Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `CLIDE_METRICS_DISABLED` | _(empty)_ | Set to `1` to disable monitoring |
| `CLIDE_POLL_INTERVAL` | `30` | Polling interval in seconds |

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
| objects.githubusercontent.com, raw.githubusercontent.com | git operations |

Add custom hosts: `CLIDE_ALLOWED_HOSTS=example.com,other.com`
Disable entirely: `CLIDE_FIREWALL=0`

All rejected traffic is logged via iptables LOG target (`CLIDE-REJECT:` prefix in kernel log).
