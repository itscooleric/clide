# Draft Issues

Three features not yet tracked in the issue tracker. Ready to file as individual GitHub issues.

---

## Issue 1: tmux integration for multi-pane workflows inside the container

**Labels:** `enhancement`

**Description:**

Currently, users get a single terminal pane when running `./clide shell` or the web terminal (`./clide web`). Heavy workflows — e.g., running Claude Code in one pane while watching logs or editing files in another — require opening multiple terminal tabs or separate `docker exec` sessions, which is awkward.

Adding tmux to the container and configuring it as the default shell entrypoint for the `shell` and `web` services would give users native multi-pane support without any host-side tooling.

**Proposed approach:**
- Install `tmux` in the Dockerfile.
- Optionally include a default `.tmux.conf` (sensible key bindings, mouse support).
- For the `web` service (ttyd), launch ttyd with `tmux new-session -A -s main` as the command instead of bare `bash`, so every browser tab attaches to or creates a shared session.
- For `make shell` / `./clide shell`, consider wrapping with `tmux new-session -A -s main` behind an opt-in env var (e.g., `CLIDE_TMUX=1`) so existing users aren't surprised.

**Acceptance criteria:**
- [ ] `tmux` is available inside the container (`tmux -V` works).
- [ ] Web terminal (`./clide web`) launches inside a tmux session by default; refreshing the browser re-attaches rather than spawning a new shell.
- [ ] Interactive shell (`./clide shell`) can optionally launch in tmux via an env var or flag.
- [ ] Existing behaviour (single-pane) is preserved as the default for `make shell` / `./clide shell` so current users are not broken.
- [ ] README documents the tmux workflow (split panes, detach/attach).

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
