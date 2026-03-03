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

## Setup

1. Add your GitHub token to `.env` (add `ANTHROPIC_API_KEY` only if using Claude Code):
   ```env
   GH_TOKEN=your_github_pat_here
   # ANTHROPIC_API_KEY=your_anthropic_key_here  # optional
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
