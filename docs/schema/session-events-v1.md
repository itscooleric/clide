# Session Event Schema v1

All events are written as newline-delimited JSON (JSONL) to:
```
/workspace/.clide/logs/<session_id>/events.jsonl
```

Every event includes:
| Field | Type | Description |
|-------|------|-------------|
| `event` | string | Event type (see below) |
| `ts` | string | ISO 8601 timestamp (UTC) |
| `session_id` | string | `clide-<timestamp>-<random>` |
| `schema_version` | int | Always `1` |

## Event Types

### `session_start`
Emitted when an agent session begins.

| Field | Type | Description |
|-------|------|-------------|
| `agent` | string | `claude`, `codex`, `copilot`, or command name |
| `repo` | string | `owner/repo` from git remote |
| `model` | string | Model identifier |
| `command` | string | Full command (secrets scrubbed) |
| `cwd` | string | Working directory |

### `session_end`
Emitted when the agent session exits.

| Field | Type | Description |
|-------|------|-------------|
| `agent` | string | Same as session_start |
| `exit_code` | int | Process exit code |
| `outcome` | string | `success`, `error`, or `killed` |
| `signal` | string | Signal name if killed (e.g. `INT`, `TERM`) — optional |
| `claude_session_id` | string | Claude Code's internal session ID — optional |
| `has_conversation` | bool | Whether conversation.jsonl was captured |
| `input_tokens` | int | Input tokens consumed — optional |
| `output_tokens` | int | Output tokens consumed — optional |
| `total_tokens` | int | Total tokens — optional |
| `estimated_cost_usd` | float | Estimated cost in USD — optional |
| `turns` | int | Number of conversation turns — optional |

## Session Directory Layout

```
/workspace/.clide/logs/<session_id>/
  events.jsonl        — structured event log
  conversation.jsonl  — Claude Code conversation log (copied from internal storage)
  transcript.raw.gz   — compressed raw terminal I/O (optional, CLIDE_RAW_TRANSCRIPT=1)
```

## Secret Scrubbing

All event payloads are scrubbed before writing:
1. Known secret env var values replaced with `[REDACTED:<NAME>]`
2. Heuristic: `KEY=longvalue` patterns replaced with `KEY=[REDACTED]`

Blocklist: `GH_TOKEN`, `GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`CLAUDE_CODE_OAUTH_TOKEN`, `TTYD_PASS`, `CLEM_WEB_SECRET`, `SUPERVISOR_SECRET`,
`TEDDY_API_KEY`, `TEDDY_WEB_PASSWORD`, `GITLAB_TOKEN`

## Retention

Configurable via `CLIDE_MAX_SESSIONS` (default: `0` = unlimited, no auto-pruning).
When set to a positive number, oldest sessions are pruned on each new session start.

## Notifications

Session start, end, and error events trigger push notifications via ntfy
when `CLIDE_NTFY_URL` is configured. Notifications are fire-and-forget
(failures are silent and never block the session).

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `CLIDE_LOG_DIR` | `/workspace/.clide/logs` | Log root directory |
| `CLIDE_MAX_SESSIONS` | `0` | Max sessions to retain (`0` = unlimited) |
| `CLIDE_LOG_DISABLED` | _(empty)_ | Set to `1` to disable logging |
| `CLIDE_NTFY_URL` | _(empty)_ | ntfy server URL |
| `CLIDE_NTFY_TOPIC` | `clide` | ntfy topic name |
| `CLIDE_NTFY_DISABLED` | _(empty)_ | Set to `1` to disable notifications |
| `CLIDE_CA_URL` | _(empty)_ | LAN CA certificate URL (installed at startup) |
