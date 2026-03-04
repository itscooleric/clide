# clide

Dockerized CLI toolkit with [GitHub Copilot CLI](https://github.com/github/copilot-cli), [GitHub CLI](https://cli.github.com/), and [Claude Code](https://www.anthropic.com/claude/code) — agentic terminal assistants in one container. Run against any local project without installing anything on your host. Access via terminal or browser-based web terminal.

## Prerequisites

- Docker + Docker Compose
- A GitHub fine-grained PAT with the **"Copilot Requests"** permission
  - Create one at: https://github.com/settings/personal-access-tokens/new
- An Anthropic API key (optional, only needed for Claude Code)
  - Create one at: https://console.anthropic.com/settings/keys

## Included CLIs

| CLI | Command | Auth env var |
|---|---|---|
| GitHub Copilot CLI | `copilot` | `GH_TOKEN` |
| GitHub CLI | `gh` | `GH_TOKEN` |
| Claude Code | `claude` | `ANTHROPIC_API_KEY` |

### Claude startup behavior

- `make claude` and `./clide claude` force `CLAUDE_CODE_SIMPLE=1` for predictable container startup.
- The `claude` and `shell` services share a container entrypoint (`/usr/local/bin/claude-entrypoint.sh`) that pre-seeds Claude config to avoid repeated first-run setup prompts — so running `claude` from inside `make shell` works too.
- If you prefer full TUI mode, run compose directly with an override:
   ```bash
   CLAUDE_CODE_SIMPLE=0 docker compose run --rm claude
   ```

## Setup

1. Copy the example env file and fill in your values:
   ```bash
   cp .env.example .env
   ```
   Required:
   ```env
   GH_TOKEN=your_github_pat_here
   ```
   Optional but recommended:
   ```env
   # Claude Code
   ANTHROPIC_API_KEY=your_anthropic_key_here

   # Git identity — keeps authorship consistent across container runs
   GIT_AUTHOR_NAME=Your Name
   GIT_AUTHOR_EMAIL=you@users.noreply.github.com
   GIT_COMMITTER_NAME=Your Name
   GIT_COMMITTER_EMAIL=you@users.noreply.github.com
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
./clide shell     # interactive shell with all CLIs
./clide copilot   # run GitHub Copilot CLI
./clide claude    # run Claude Code CLI
./clide gh repo view  # run GitHub CLI with args
./clide help      # show all commands
```

### Make
```bash
make web          # start web terminal
make shell        # interactive shell
make copilot      # run copilot
make claude       # run Claude Code CLI
make help         # show all targets
```

### VS Code tasks
Use `Ctrl+Shift+P` → **Run Task**:
- **Start web terminal (ttyd)** → access all CLIs at http://localhost:7681
- **Run copilot (default project)** → run Copilot CLI directly
- **Open interactive shell (all CLIs)** → bash with all CLIs available

### Docker Compose directly
```bash
docker compose run --rm shell
docker compose run --rm copilot
docker compose up -d web
```

Run against a different project:
```bash
PROJECT_DIR=/path/to/specific/repo docker compose run --rm shell
```

Your project is mounted at `/workspace` inside the container.

### Bernard/Forge deployment
See [`DEPLOY.md`](./DEPLOY.md) for Caddy Docker Proxy integration. Uses `docker-compose.override.yml` (gitignored) for reverse proxy config that persists across git pulls.

## Notes

- Tokens don't expire unless you set an expiry — set them once in `.env` and you're done.
- `.env` is gitignored. Don't commit it.
- To rebuild with latest CLI versions:
  ```bash
  docker compose build --no-cache
  ```

- If Claude gets stuck in setup prompts again after local changes, reset and rebuild:
   ```bash
   docker compose down -v
   docker compose build --no-cache
   make claude
   ```
