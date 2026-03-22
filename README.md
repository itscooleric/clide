# clide

```text

   ██████ ██      ██ ██████  ███████
  ██      ██      ██ ██   ██ ██
  ██      ██      ██ ██   ██ █████
  ██      ██      ██ ██   ██ ██
   ██████ ███████ ██ ██████  ███████

  sandboxed agentic terminal        v4
  ──────────────────────────────────────

  your project ──bind mount──► /workspace
  .env secrets ──env vars────► container
  browser :7681 ──ttyd───────► web shell

  ┌────────────────────────────────────┐
  │  claude  copilot  codex  gh  bash  │
  │          web (ttyd + tmux)         │
  └──────────────┬─────────────────────┘
            firewall.sh
           egress allowlist
                 │
                 ▼
     api.anthropic.com    claude
     api.githubcopilot.com copilot
     api.github.com        gh
     api.openai.com        codex
     *everything else      REJECT

  ──────────────────────────────────────
  non-root. network-restricted.
  nothing installed on your host.

```

Dockerized CLI toolkit — [Claude Code](https://www.anthropic.com/claude/code), [GitHub Copilot CLI](https://github.com/github/copilot-cli), [Codex CLI](https://github.com/openai/codex), and [GitHub CLI](https://cli.github.com/) in one sandboxed container with egress firewall and browser-based web terminal.

## Architecture

> **Trust boundary:** the host trusts the container with a read-write mount of your project directory and your API credentials via `.env`. The container cannot reach the internet beyond the allowlisted endpoints (when `NET_ADMIN` is available). See [`SECURITY.md`](./SECURITY.md) for the full threat model.

## Prerequisites

- Docker + Docker Compose
- A GitHub fine-grained PAT with the **"Copilot Requests"** permission
  - Create one at: https://github.com/settings/personal-access-tokens/new
- Claude Code authentication (optional, choose one):
  - **OAuth token** (recommended) — uses your Claude Pro/Max subscription limits
  - **Anthropic API key** — uses pay-per-use API credits

## Included CLIs

| CLI | Command | Auth env var |
|---|---|---|
| GitHub Copilot CLI | `copilot` | `GH_TOKEN` |
| GitHub CLI | `gh` | `GH_TOKEN` |
| Claude Code | `claude` | `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` |
| Codex CLI (OpenAI) | `codex` | `OPENAI_API_KEY` (or device code flow) |
| GitLab CLI | `glab` | `GITLAB_TOKEN` + `GITLAB_HOST` |

### Claude Code authentication

Two auth methods are supported. **Do not set both** — if both are present, the OAuth token takes priority and the API key is ignored.

#### Option 1: OAuth token (recommended for subscription users)

Uses your Claude Pro/Max subscription limits — no API credits consumed. Generate a token on any machine with a browser:
```bash
claude setup-token
```
This produces a long-lived token (valid for 1 year). Add it to `.env`:
```env
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxxxx
```

#### Option 2: Anthropic API key

Uses pay-per-use API credits. Create a key at https://console.anthropic.com/settings/keys and add to `.env`:
```env
ANTHROPIC_API_KEY=sk-ant-xxxxx
```

### Claude startup behavior

- The container entrypoint (`/usr/local/bin/claude-entrypoint.sh`) pre-seeds Claude config to avoid repeated first-run setup prompts. Just type `claude` from any shell.
- To authenticate interactively, run `claude /login` from the bash session. Auth subcommands bypass session-logger and run directly.
- Set `CLAUDE_CODE_SIMPLE=1` in `.env` if you prefer simplified (non-TUI) output.

### Codex CLI (OpenAI) authentication

Two auth methods are supported:

#### Option 1: API key (recommended)

Set `OPENAI_API_KEY` in `.env` to skip interactive auth entirely:
```env
OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

#### Option 2: Device code flow (browser-free OAuth)

There is no browser inside the container, so the default OAuth redirect flow will not work.
Use device code flow instead — it prints a URL and code that you visit on your **host** browser:
```bash
codex auth login --auth device
# Open the printed URL in your host browser and enter the code
```

### tmux — multi-pane workflows

`tmux` is installed in the container and enabled by default in the **web terminal**. Every browser tab attaches to the same named session (`main`), so refreshing the page re-attaches rather than spawning a fresh shell. The web terminal auto-reconnects after network drops (enabled by default; set `TTYD_RECONNECT=0` to disable). The WebSocket ping interval (`TTYD_PING_INTERVAL`, default 30s) is tuned for mobile browsers that may pause connections during tab switches or screen lock.

For `make cli` / `./clide cli`, tmux is **opt-in** to avoid breaking existing workflows:
```env
# .env
CLIDE_TMUX=1
```

**Useful shortcuts (web terminal):**

| Key | Action |
|-----|--------|
| `Ctrl-b \|` | Split pane horizontally |
| `Ctrl-b -` | Split pane vertically |
| `Ctrl-b <arrow>` | Move between panes |
| `Ctrl-b d` | Detach (session stays alive) |
| `Ctrl-b r` | Reload tmux config |
| `F12` | Toggle mouse mode on/off (useful for mobile) |
| Mouse | Click to focus, scroll to scroll, drag to resize |

## Setup

1. Add your GitHub token and Claude auth to `.env`:
   ```env
   GH_TOKEN=your_github_pat_here

   # Choose ONE:
   CLAUDE_CODE_OAUTH_TOKEN=your_oauth_token_here   # subscription
   # ANTHROPIC_API_KEY=your_api_key_here            # API credits

   # Optional — keeps git authorship consistent inside the container:
   # GIT_AUTHOR_NAME=Your Name
   # GIT_AUTHOR_EMAIL=you@users.noreply.github.com
   # GIT_COMMITTER_NAME=Your Name
   # GIT_COMMITTER_EMAIL=you@users.noreply.github.com
   ```

2. (Optional) Enable web terminal authentication:
   ```env
   TTYD_USER=admin
   TTYD_PASS=changeme
   ```

3. Build the image:
   ```bash
   docker compose build
   ```

## Usage

### Wrapper script (easiest)
```bash
./clide web       # start web terminal at http://localhost:7681
./clide cli       # interactive shell — run claude, copilot, codex, gh from here
./clide help      # show all commands
```

### Make
```bash
make web          # start web terminal
make cli          # interactive shell
make help         # show all targets
```

### Docker Compose directly
```bash
docker compose up -d web            # web terminal
docker compose run --rm cli         # headless shell
```

Run against a different project:
```bash
PROJECT_DIR=/path/to/specific/repo docker compose run --rm cli
```

Your project is mounted at `/workspace` inside the container.

### Bernard/Forge deployment
See [`DEPLOY.md`](./DEPLOY.md) for Caddy Docker Proxy integration. Uses `docker-compose.override.yml` (gitignored) for reverse proxy config that persists across git pulls.

## Session logging

Every agent session is automatically logged with structured events and a raw terminal transcript. Typing `claude`, `codex`, or `copilot` in any shell goes through `session-logger.sh` automatically.

```text
/workspace/.clide/logs/<session_id>/
  events.jsonl        — structured JSONL events (start, end, errors)
  transcript.txt.gz   — compressed raw terminal I/O
```

All logged output is scrubbed for secrets (API keys, tokens, passwords) before writing. See [`docs/schema/session-events-v1.md`](./docs/schema/session-events-v1.md) for the event format.

| Env var | Default | Description |
|---------|---------|-------------|
| `CLIDE_LOG_DISABLED` | _(empty)_ | Set to `1` to disable logging |
| `CLIDE_MAX_SESSIONS` | `30` | Max sessions retained (oldest pruned on new session) |

## Push notifications (ntfy)

Get notified when agent sessions start, end, or error. Works with any [ntfy](https://ntfy.sh) instance (self-hosted or public).

```env
# .env
CLIDE_NTFY_URL=https://ntfy.example.com
CLIDE_NTFY_TOPIC=clide
```

Subscribe to notifications on your phone via the ntfy app, or open `https://ntfy.example.com/clide` in a browser tab.

| Env var | Default | Description |
|---------|---------|-------------|
| `CLIDE_NTFY_URL` | _(empty)_ | ntfy server URL (notifications disabled if unset) |
| `CLIDE_NTFY_TOPIC` | `clide` | ntfy topic name |
| `CLIDE_NTFY_DISABLED` | _(empty)_ | Set to `1` to disable notifications |

## LAN CA certificate

If your internal services use TLS with a private CA (e.g. Caddy internal certs), the container can trust it at startup:

```env
# .env
CLIDE_CA_URL=https://fs.example.com/root-ca.crt
```

The cert is downloaded and installed on each container start. If the download fails, startup continues without it.

## Additional docs

| Doc | Contents |
|---|---|
| [`SECURITY.md`](./SECURITY.md) | Threat model, trust boundaries, attack surface, hardening recommendations |
| [`RUNBOOK.md`](./RUNBOOK.md) | Operational runbook — health checks, logs, rebuilds, credential rotation, troubleshooting |
| [`DEPLOY.md`](./DEPLOY.md) | Production deployment with Caddy reverse proxy |
| [`docs/schema/session-events-v1.md`](./docs/schema/session-events-v1.md) | Session event JSONL schema |

## Notes

- Tokens don't expire unless you set an expiry — set them once in `.env` and you're done. OAuth tokens from `claude setup-token` are valid for 1 year.
- `.env` is gitignored. Don't commit it.
- To rebuild with latest CLI versions:
  ```bash
  docker compose build --no-cache
  ```

- If Claude gets stuck in setup prompts again after local changes, reset and rebuild:
   ```bash
   docker compose down -v
   docker compose build --no-cache
   make cli
   ```

## Compatibility

### Host OS

| OS | Status | Notes |
|---|---|---|
| Linux | ✅ Supported | Native Docker — full functionality including egress firewall |
| macOS (Apple Silicon) | ✅ Supported | Docker Desktop required; `arm64` image builds natively |
| macOS (Intel) | ✅ Supported | Docker Desktop required |
| Windows (WSL2) | ✅ Supported | Docker Desktop with WSL2 backend required |
| Windows (no WSL2) | ⚠️ Partial | Egress firewall requires `NET_ADMIN`; availability varies by runtime |

### Docker

| Requirement | Minimum |
|---|---|
| Docker Engine | 20.10+ |
| Docker Compose | v2.0+ (`docker compose`, not `docker-compose`) |

### CPU architecture

| Arch | Status |
|---|---|
| `amd64` (x86_64) | ✅ Supported |
| `arm64` (Apple Silicon, Graviton) | ✅ Supported |

### Web terminal browser support

| Browser | Status |
|---|---|
| Chrome / Chromium | ✅ Supported |
| Firefox | ✅ Supported |
| Safari | ✅ Supported |
| Edge | ✅ Supported |

### Egress firewall support

The `iptables` egress firewall requires the `NET_ADMIN` capability and a Linux kernel with `iptables` support. It works out of the box on Linux hosts and Docker Desktop (macOS/Windows). If unavailable, the firewall degrades gracefully — a warning is printed and egress is unrestricted.

## Egress firewall

By default every clide container applies an **iptables egress allowlist** at startup, restricting outbound traffic to the known service endpoints.  All bundled CLIs continue to work normally within these defaults.

### Default allowlist

| Host | Used by |
|---|---|
| `api.anthropic.com` | Claude Code |
| `api.githubcopilot.com` | GitHub Copilot CLI |
| `api.github.com` | GitHub Copilot CLI · GitHub CLI |
| `github.com` | GitHub CLI |
| `registry.npmjs.org` | npm package updates |
| `api.openai.com` | Codex CLI |
| `auth.openai.com` | Codex CLI — device code auth |

DNS (port 53) and loopback traffic are always allowed.

### Adding hosts

Set `CLIDE_ALLOWED_HOSTS` in `.env` to a comma- or newline-separated list of extra hostnames:
```env
CLIDE_ALLOWED_HOSTS=pypi.org,files.pythonhosted.org
```

The hostnames are resolved to IPs at container startup — no rebuild required.

### Disabling the firewall

Set `CLIDE_FIREWALL=0` to restore unrestricted egress:
```env
CLIDE_FIREWALL=0
```

### Requirements

The firewall uses `iptables` and requires the `NET_ADMIN` capability, which is already set in `docker-compose.yml`.  If the capability is unavailable (e.g. a restricted runtime), the script emits a warning and continues without blocking any traffic.

## Python dev tooling

The container includes a Python 3 **virtualenv** at `/opt/pyenv` (note: this is a plain `python3 -m venv`, not the pyenv version manager) with the following tools pre-installed and on `PATH`:

| Tool | Purpose |
|------|---------|
| `pytest` | Test runner — `pytest tests/` |
| `ruff` | Linter + formatter — `ruff check .` / `ruff format .` |

The venv is **clide-owned** — `pip install` works without `sudo` or a container rebuild. To install workspace project dependencies:

```bash
pip install -r /workspace/<repo>/requirements.txt
```

The venv is at `/opt/pyenv`; `pip`, `pytest`, and `ruff` are all directly callable without activation.

> **Note:** `pip install` requires outbound access to PyPI. Add these to `CLIDE_ALLOWED_HOSTS` if the egress firewall is enabled:
> ```env
> CLIDE_ALLOWED_HOSTS=pypi.org,files.pythonhosted.org
> ```

## Git workspace repos

`safe.directory = *` is pre-configured in the clide user's gitconfig at image build time. Volume-mounted repos cloned from GitHub are often owned by the host UID rather than `clide:1000`, which normally causes git to refuse to operate with a "detected dubious ownership" error. This is eliminated entirely — `git status`, `git log`, and all other git operations work from the first prompt without any `git config` boilerplate.

> **Security note:** `safe.directory = *` trusts all directories unconditionally. This is appropriate for a single-user dev sandbox where you control what gets mounted, but it means git will operate in any directory regardless of ownership. If you share the container or mount untrusted paths, consider replacing `*` with the specific paths you use (e.g. `/workspace`).

## Ecosystem

| Project | What |
|---------|------|
| **clide** | CLI Development Environment (you are here) |
| [clidesdale](https://github.com/itscooleric/clidesdale) | CLI client — SSH access to remote VPSes for agents |
| [clidestable](https://github.com/itscooleric/clidestable) | VPS-side server — dashboard, stall management, split terminal view |
