# clide

Dockerized CLI toolkit with [GitHub Copilot CLI](https://github.com/github/copilot-cli), [GitHub CLI](https://cli.github.com/), and [Claude Code](https://www.anthropic.com/claude/code) — agentic terminal assistants in one container. Run against any local project without installing anything on your host. Access via terminal or browser-based web terminal.

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

- `make claude` and `./clide claude` force `CLAUDE_CODE_SIMPLE=1` for predictable container startup.
- The `claude` and `shell` services share a container entrypoint (`/usr/local/bin/claude-entrypoint.sh`) that pre-seeds Claude config to avoid repeated first-run setup prompts — so running `claude` from inside `make shell` works too.
- If you prefer full TUI mode, run compose directly with an override:
   ```bash
   CLAUDE_CODE_SIMPLE=0 docker compose run --rm claude
   ```

### Bundled terminal tooling

In addition to the CLIs above, the container includes an editor/tooling bundle aimed at tmux-based workflows:

| Tool | Command |
|---|---|
| Neovim | `nvim` |
| Vim | `vim` |
| Nano | `nano` |
| fzf | `fzf` |
| ripgrep | `rg` |
| lazygit | `lazygit` |
| jq | `jq` |

A minimal shared vim config is shipped at `/etc/vim/vimrc.local` and loaded by both vim and neovim (`/etc/xdg/nvim/sysinit.vim` sources it). Defaults include line numbers, syntax highlighting, mouse support, and 2-space indentation.

Set `CLIDE_EDITOR` to control `$EDITOR` and `$VISUAL` inside the container (default: `nvim`).

### tmux — multi-pane workflows

`tmux` is installed in the container and enabled by default in the **web terminal**. Every browser tab attaches to the same named session (`main`), so refreshing the page re-attaches rather than spawning a fresh shell.

For `make shell` / `./clide shell`, tmux is **opt-in** to avoid breaking existing workflows:
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
   make claude
   ```
