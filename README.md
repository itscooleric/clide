# clide

```text

   ██████ ██      ██ ██████  ███████
  ██      ██      ██ ██   ██ ██
  ██      ██      ██ ██   ██ █████
  ██      ██      ██ ██   ██ ██
   ██████ ███████ ██ ██████  ███████

  sandboxed agentic terminal        v3
  ──────────────────────────────────────

  your project ──bind mount──► /workspace
  .env secrets ──env vars────► container
  browser :7681 ──ttyd───────► web shell

  ┌────────────────────────────────────┐
  │  claude  copilot  codex  gh  bash  │
  │          web (ttyd + tmux)         │
  └──────────────┬─────────────────────┘
          MITM intercept proxy
            firewall.sh
           egress allowlist
                 │
        ┌────────┼────────┐
        ▼        ▼        ▼
   intercept  egress   session
    .jsonl    .jsonl    events
                 │
                 ▼
     api.anthropic.com    claude
     api.githubcopilot.com copilot
     api.github.com        gh
     api.openai.com        codex
     *everything else      REJECT

  ──────────────────────────────────────
  every request captured. every
  connection logged. nothing leaves
  without a record.

```

A sandboxed environment for running AI coding agents ([Claude Code](https://www.anthropic.com/claude/code), [GitHub Copilot CLI](https://github.com/github/copilot-cli), [Codex CLI](https://github.com/openai/codex), [GitHub CLI](https://cli.github.com/)) that captures **structured interaction data** from every session. CLIDE is a research instrument: it intercepts API traffic between agents and providers, logs all outbound connections, and records session events — producing machine-readable datasets for studying how AI agents interact with codebases.

## Data & Observability

CLIDE captures three streams of structured data from every agent session. This is the core value proposition — not just sandboxing, but complete observability over agent behavior.

### intercept.jsonl — API request/response capture

MITM proxy intercepts all traffic between the agent and its provider API. Every prompt, every completion, every tool call — captured with full request and response bodies.

```
/var/log/clide/intercept.jsonl
```

Each line is a JSON object:

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | ISO 8601 | When the request was made |
| `method` | string | HTTP method (`POST`, `GET`, etc.) |
| `url` | string | Full request URL |
| `request_headers` | object | Request headers (auth tokens redacted) |
| `request_body` | object | Full request payload — prompts, messages, tool definitions |
| `response_status` | int | HTTP status code |
| `response_headers` | object | Response headers |
| `response_body` | object | Full response — completions, tool calls, token counts |
| `duration_ms` | int | Round-trip time |

### egress.jsonl — outbound connection log

Every outbound network connection the agent attempts, whether allowed or blocked by the firewall.

```
/var/log/clide/egress.jsonl
```

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | ISO 8601 | Connection attempt time |
| `destination` | string | Hostname or IP |
| `port` | int | Destination port |
| `protocol` | string | `tcp`, `udp` |
| `action` | string | `ALLOW` or `REJECT` |
| `rule` | string | Which firewall rule matched |

This tells you exactly what the agent tried to reach — and whether it was permitted. Rejected connections are especially interesting: they reveal what the agent *wanted* to do but couldn't.

### Session events — tool use, edits, commands

Agent tool invocations, file edits, and shell commands are captured as structured events:

```
/var/log/clide/session-events.jsonl
```

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | ISO 8601 | Event time |
| `event_type` | string | `tool_use`, `file_edit`, `command`, `file_read` |
| `agent` | string | Which CLI produced the event |
| `detail` | object | Event-specific payload (tool name, file path, command, etc.) |

### Research applications

With these three streams you can reconstruct complete agent sessions:
- **Token economics** — measure prompt/completion token counts per task
- **Tool use patterns** — which tools agents reach for, in what order, how often
- **Egress behavior** — what external resources agents try to access (and what happens when blocked)
- **Latency profiling** — provider response times under different prompt sizes
- **Comparative analysis** — run the same task across Claude, Copilot, and Codex; diff the data

## Egress Firewall (Research Control)

The iptables egress allowlist isn't just security — it's an **experimental control**. You decide exactly what the agent can reach, creating reproducible conditions for studying agent behavior under different network constraints.

### Default allowlist

| Host | Used by |
|------|---------|
| `api.anthropic.com` | Claude Code |
| `api.githubcopilot.com` | GitHub Copilot CLI |
| `api.github.com` | GitHub Copilot CLI, GitHub CLI |
| `github.com` | GitHub CLI |
| `registry.npmjs.org` | npm package updates |
| `api.openai.com` | Codex CLI |
| `auth.openai.com` | Codex CLI — device code auth |

DNS (port 53) and loopback traffic are always allowed.

### Modifying the allowlist

Add hosts via `CLIDE_ALLOWED_HOSTS` in `.env`:
```env
CLIDE_ALLOWED_HOSTS=pypi.org,files.pythonhosted.org
```

Disable the firewall entirely with `CLIDE_FIREWALL=0` (unrestricted egress — no rejected connections logged).

The firewall uses `iptables` and requires the `NET_ADMIN` capability (already set in `docker-compose.yml`). If unavailable, it degrades gracefully with a warning.

## Architecture

> **Trust boundary:** the host trusts the container with a read-write mount of your project directory and your API credentials via `.env`. The container cannot reach the internet beyond the allowlisted endpoints (when `NET_ADMIN` is available). See [`SECURITY.md`](./SECURITY.md) for the full threat model.

## Quick Start

1. Clone and configure credentials:
   ```bash
   git clone https://github.com/itscooleric/clide
   cd clide
   cp .env.example .env   # then edit with your tokens
   ```

2. Add your tokens to `.env`:
   ```env
   GH_TOKEN=your_github_pat_here

   # Claude auth — pick one:
   CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxxxx   # subscription (recommended)
   # ANTHROPIC_API_KEY=sk-ant-xxxxx              # API credits
   ```

3. Build and run:
   ```bash
   docker compose build
   ./clide web       # web terminal at http://localhost:7681
   ./clide claude    # Claude Code CLI
   ./clide shell     # interactive shell with all CLIs
   ```

Your project is mounted at `/workspace` inside the container. Data logs appear in `/var/log/clide/`.

## Included CLIs

| CLI | Command | Auth env var |
|-----|---------|--------------|
| Claude Code | `claude` | `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` |
| GitHub Copilot CLI | `copilot` | `GH_TOKEN` |
| GitHub CLI | `gh` | `GH_TOKEN` |
| Codex CLI (OpenAI) | `codex` | `OPENAI_API_KEY` |
| GitLab CLI | `glab` | `GITLAB_TOKEN` + `GITLAB_HOST` |

### Claude Code auth

**OAuth token (recommended):** Uses your Claude Pro/Max subscription — no API credits consumed. Generate with `claude setup-token` on any machine with a browser, valid for 1 year.

**API key:** Pay-per-use. Create at https://console.anthropic.com/settings/keys.

Set one (not both) in `.env`. If both are present, OAuth takes priority.

### Codex CLI auth

Set `OPENAI_API_KEY` in `.env`, or use device code flow inside the container:
```bash
codex auth login --auth device
```

## Usage

### Wrapper script
```bash
./clide web       # start web terminal at http://localhost:7681
./clide shell     # interactive shell with all CLIs
./clide claude    # run Claude Code CLI
./clide copilot   # run GitHub Copilot CLI
./clide codex     # run Codex CLI
./clide gh repo view  # run GitHub CLI with args
./clide help      # show all commands
```

### Make targets
```bash
make web          # start web terminal
make shell        # interactive shell
make claude       # Claude Code CLI
make codex        # Codex CLI
make help         # show all targets
```

### Docker Compose directly
```bash
docker compose run --rm shell
docker compose up -d web
PROJECT_DIR=/path/to/repo docker compose run --rm shell
```

### VS Code tasks
`Ctrl+Shift+P` > **Run Task** > choose from web terminal, copilot, or shell targets.

## tmux — Multi-Agent Workflows

`tmux` is installed and enabled by default in the web terminal. Run multiple agents side-by-side: Claude in one pane, Copilot in another, monitoring data logs in a third.

Every browser tab attaches to the same named session (`main`), so refreshing re-attaches rather than spawning a new shell.

For `make shell` / `./clide shell`, tmux is opt-in:
```env
CLIDE_TMUX=1
```

| Key | Action |
|-----|--------|
| `Ctrl-b \|` | Split pane horizontally |
| `Ctrl-b -` | Split pane vertically |
| `Ctrl-b <arrow>` | Move between panes |
| `Ctrl-b d` | Detach (session stays alive) |
| Mouse | Click to focus, scroll, drag to resize |

## Python Dev Tooling

The container includes a Python 3 virtualenv at `/opt/pyenv` with `pytest` and `ruff` pre-installed. The venv is clide-owned — `pip install` works without sudo.

> **Note:** `pip install` requires outbound PyPI access. Add `pypi.org,files.pythonhosted.org` to `CLIDE_ALLOWED_HOSTS` if the firewall is enabled.

## Git Workspace

`safe.directory = *` is pre-configured so volume-mounted repos work without ownership errors. Appropriate for a single-user sandbox — see [`SECURITY.md`](./SECURITY.md) for caveats.

## Additional Docs

| Doc | Contents |
|-----|----------|
| [`SECURITY.md`](./SECURITY.md) | Threat model, trust boundaries, attack surface, hardening |
| [`RUNBOOK.md`](./RUNBOOK.md) | Health checks, logs, rebuilds, credential rotation, troubleshooting |
| [`DEPLOY.md`](./DEPLOY.md) | Production deployment with Caddy reverse proxy |

## Compatibility

### Host OS

| OS | Status | Notes |
|----|--------|-------|
| Linux | Supported | Native Docker — full functionality including egress firewall |
| macOS (Apple Silicon) | Supported | Docker Desktop required; `arm64` builds natively |
| macOS (Intel) | Supported | Docker Desktop required |
| Windows (WSL2) | Supported | Docker Desktop with WSL2 backend required |
| Windows (no WSL2) | Partial | Egress firewall requires `NET_ADMIN`; availability varies |

### Requirements

| Component | Minimum |
|-----------|---------|
| Docker Engine | 20.10+ |
| Docker Compose | v2.0+ (`docker compose`, not `docker-compose`) |
| CPU | `amd64` or `arm64` |
| Browser (web terminal) | Chrome, Firefox, Safari, Edge |

<details>
<summary><strong>Environment Variable Reference</strong></summary>

### CLIDE_* variables

| Variable | Where set | Default | Description |
|----------|-----------|---------|-------------|
| `CLIDE_UID` | Build arg | `1000` | UID for `clide` user. Set to `$(id -u)` to match host. |
| `CLIDE_GID` | Build arg | `1000` | GID for `clide` group. Set to `$(id -g)` to match host. |
| `CLIDE_FIREWALL` | Runtime `.env` | `1` | Set to `0` to disable egress allowlist. |
| `CLIDE_ALLOWED_HOSTS` | Runtime `.env` | *(empty)* | Additional hostnames for egress allowlist. |
| `CLIDE_TMUX` | Runtime `.env` | *(off)* | Set to `1` to enable tmux in shell mode. |

### Auth variables

| Variable | Description |
|----------|-------------|
| `GH_TOKEN` | GitHub PAT with Copilot Requests permission |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude OAuth token (subscription) |
| `ANTHROPIC_API_KEY` | Anthropic API key (pay-per-use) |
| `OPENAI_API_KEY` | OpenAI API key for Codex CLI |
| `GITLAB_TOKEN` | GitLab PAT |
| `GITLAB_HOST` | GitLab instance URL |
| `GIT_AUTHOR_NAME` / `GIT_COMMITTER_NAME` | Git authorship inside container |
| `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_EMAIL` | Git email inside container |
| `TTYD_USER` / `TTYD_PASS` | Web terminal authentication |

**Build args** are baked in at `docker compose build`. **Runtime vars** take effect on container start — no rebuild needed.

</details>

## Notes

- Tokens don't expire unless you set an expiry. OAuth tokens from `claude setup-token` are valid for 1 year.
- `.env` is gitignored. Don't commit it.
- Rebuild with latest CLI versions: `docker compose build --no-cache`
- Data logs persist across container restarts when `/var/log/clide/` is volume-mounted.
