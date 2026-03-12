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
| `outcome` | string | `success` or `error` |

## Session Directory Layout

```
/workspace/.clide/logs/<session_id>/
  events.jsonl        — structured event log
  transcript.txt.gz   — compressed raw terminal I/O
```

## Secret Scrubbing

All event payloads are scrubbed before writing:
1. Known secret env var values replaced with `[REDACTED:<NAME>]`
2. Heuristic: `KEY=longvalue` patterns replaced with `KEY=[REDACTED]`

Blocklist: `GH_TOKEN`, `GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`CLAUDE_CODE_OAUTH_TOKEN`, `TTYD_PASS`, `CLEM_WEB_SECRET`, `SUPERVISOR_SECRET`,
`TEDDY_API_KEY`, `TEDDY_WEB_PASSWORD`, `GITLAB_TOKEN`

## Retention

Configurable via `CLIDE_MAX_SESSIONS` (default: 30). Oldest sessions pruned
on each new session start.

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `CLIDE_LOG_DIR` | `/workspace/.clide/logs` | Log root directory |
| `CLIDE_MAX_SESSIONS` | `30` | Max sessions to retain |
| `CLIDE_LOG_DISABLED` | _(empty)_ | Set to `1` to disable logging |
