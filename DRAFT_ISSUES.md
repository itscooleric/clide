# Draft Issues

Three features not yet tracked in the issue tracker. Ready to file as individual GitHub issues.

---

## Issue 1: tmux integration + terminal developer tooling bundle

**Labels:** `enhancement`

**Description:**

Currently, users get a single terminal pane when running `./clide shell` or the web terminal (`./clide web`). Heavy workflows — e.g., running Claude Code in one pane while watching logs or editing files in another — require opening multiple terminal tabs or separate `docker exec` sessions, which is awkward.

This issue covers tmux for multi-pane support, editors (vim/neovim/nano), and a small set of terminal tools that are near-universally useful in a coding environment and compose well together.

**Proposed approach:**

_tmux:_
- Install `tmux` in the Dockerfile.
- Ship a minimal `.tmux.conf`: mouse support, sensible prefix, 256-color.
- For the `web` service (ttyd), launch with `tmux new-session -A -s main` so browser tab refresh re-attaches rather than spawning a new shell.
- For `./clide shell`, wrap with tmux behind an opt-in env var (`CLIDE_TMUX=1`) so existing users aren't surprised.

_Editors:_
- Install `neovim`, `vim`, and `nano` via apt.
- Ship a minimal `/etc/vim/vimrc.local` (line numbers, syntax on, mouse support, 2-space indent) so vim/neovim aren't hostile out of the box.
- No default neovim plugin manager — keep it simple; power users can bring their own config via a volume mount.
- `CLIDE_EDITOR` env var sets `$EDITOR` / `$VISUAL` inside the container (default: `nvim`).

_Terminal tools:_
| Tool | Rationale |
|---|---|
| `fzf` | Fuzzy finder for files and shell history; integrates with vim, ripgrep, and tmux |
| `ripgrep` | Fast code search; neovim uses it as its native grep engine |
| `lazygit` | TUI git client; natural fit for a dedicated tmux pane alongside Claude Code |
| `jq` | JSON processing; useful when inspecting API responses from any bundled CLI |

Intentionally excluded from this issue: alternative shells (zsh, fish), LSP servers, plugin managers — those are personal preference and add significant complexity.

**Acceptance criteria:**
- [ ] `tmux` is available and `tmux -V` works.
- [ ] Web terminal (`./clide web`) launches inside a tmux session by default; refreshing the browser re-attaches rather than spawning a new shell.
- [ ] `./clide shell` can optionally launch in tmux via `CLIDE_TMUX=1`; single-pane remains the default.
- [ ] `nvim`, `vim`, and `nano` are all available in the container.
- [ ] A minimal shared vimrc is present so vim/neovim work sensibly with no user config.
- [ ] `CLIDE_EDITOR` env var controls `$EDITOR`/`$VISUAL`; defaults to `nvim`.
- [ ] `fzf`, `ripgrep` (`rg`), `lazygit`, and `jq` are all available in the container.
- [ ] Total image size increase from all tools in this issue is documented in the PR.
- [ ] README documents the tmux workflow (split panes, detach/attach) and lists the bundled tools.

---

## Issue 2: Network firewall / outbound allowlist for container egress

**Labels:** `enhancement`, `security`

**Description:**

The container currently has unrestricted outbound internet access. For users running clide against private or sensitive codebases, there is no way to limit which external hosts Claude Code, Copilot CLI, or other tools can reach. A configurable egress allowlist reduces the blast radius if a tool misbehaves or a supply-chain issue occurs.

The allowlist should cover the minimum endpoints needed for each bundled CLI to function, with the ability for users to extend it.

**Known required egress destinations (baseline):**
| Service | Hosts |
|---|---|
| Claude Code | `api.anthropic.com` |
| GitHub Copilot CLI | `api.githubcopilot.com`, `api.github.com` |
| GitHub CLI | `api.github.com`, `github.com` |
| Package updates (optional) | `registry.npmjs.org`, `pypi.org` (if needed) |

**Proposed approach:**
- Add an `iptables`/`nftables` egress filter script that runs at container startup (requires `NET_ADMIN` capability or an init container approach).
- Alternatively, use Docker network policies or a sidecar proxy (e.g., tinyproxy) if capability escalation is undesirable.
- Expose a `CLIDE_ALLOWED_HOSTS` env var (newline- or comma-separated) so users can append hosts without rebuilding.
- Default: allowlist only the baseline endpoints above; block everything else.
- Provide an opt-out (`CLIDE_FIREWALL=0`) for users who need unrestricted access.

**Acceptance criteria:**
- [ ] Container blocks outbound connections to arbitrary hosts by default.
- [ ] All bundled CLIs (Claude Code, Copilot, gh) continue to work normally with the default allowlist.
- [ ] `CLIDE_ALLOWED_HOSTS` env var correctly adds hosts to the allowlist at startup without requiring a rebuild.
- [ ] `CLIDE_FIREWALL=0` disables the firewall entirely, restoring current behaviour.
- [ ] README documents the firewall feature, default allowlist, and how to extend it.
- [ ] Threat model doc (issue #8) is updated to reflect this control.

---

## Issue 3: Codex CLI (OpenAI) support

**Labels:** `enhancement`

**Description:**

clide bundles multiple AI coding assistants; adding OpenAI's Codex CLI would make it a more complete multi-model toolkit. The primary challenge is authentication: Codex CLI uses a browser-based OAuth flow by default, which does not work in a headless container.

OpenAI supports **device code flow** (`--auth device`) as a browser-free alternative, making it viable in this environment.

**Proposed approach:**
- Add Codex CLI installation to the Dockerfile (via npm: `npm install -g @openai/codex` or the appropriate package once stable).
- Document the device code auth flow in the README:
  ```
  codex auth login --auth device
  # Follow the printed URL + code on your host browser
  ```
- Add `OPENAI_API_KEY` as an optional env var in `.env.example` for users who prefer API key auth.
- Add a `make codex` / `./clide codex` shortcut consistent with existing CLI shortcuts.
- Add `codex` to the "Included CLIs" table in README.

**Note on auth:** There is no browser inside the container, so the default OAuth redirect flow will not work. Device code flow must be used for interactive login. Users with a pre-issued API key can skip device flow entirely by setting `OPENAI_API_KEY` in `.env`.

**Acceptance criteria:**
- [ ] `codex` binary is available inside the container.
- [ ] Device code auth flow (`codex auth login --auth device` or equivalent) works inside the container — user visits a URL on their host browser to complete auth.
- [ ] `OPENAI_API_KEY` in `.env` is passed through to the container; setting it bypasses interactive auth.
- [ ] `./clide codex` and `make codex` shortcuts exist and work.
- [ ] README "Included CLIs" table includes Codex CLI with auth instructions.
- [ ] `.env.example` includes a commented-out `OPENAI_API_KEY` entry.
- [ ] No Claude API key / first-run setup flow is touched.
