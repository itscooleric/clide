#!/bin/bash
set -e

# Pre-seed Claude config (auth, onboarding flags) — same as claude-entrypoint.sh
# This ensures CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY from .env are wired up
# before any shell session in the web terminal runs `claude`.
# Pass CLIDE_TMUX= (blank) so the tmux opt-in branch in claude-entrypoint.sh is
# skipped — the web terminal always manages its own tmux session via ttyd below.
CLIDE_TMUX='' /usr/local/bin/claude-entrypoint.sh true

# Mirror the env cleanup from claude-entrypoint.sh — the subprocess call above
# runs unset in its own shell so it doesn't propagate here. We replicate it so
# ttyd and all bash sessions it spawns see the same env as `make shell`.
# Keep in sync with the cleanup block in claude-entrypoint.sh.
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ttyd: clearing ANTHROPIC_API_KEY from env (OAuth token takes priority)"
  unset ANTHROPIC_API_KEY
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  unset ANTHROPIC_API_KEY
fi

TTYD_ARGS=(
  "--writable"
  "--port" "${TTYD_PORT:-7681}"
  "--base-path" "${TTYD_BASE_PATH:-/}"
)

# Wire gh as git credential helper so git push/fetch work without token embedding
gh auth setup-git

# Auth is required by default; set TTYD_NO_AUTH=true to explicitly allow unauthenticated access
if [[ "${TTYD_NO_AUTH:-}" == "true" ]]; then
  echo "ttyd: WARNING - unauthenticated access enabled (TTYD_NO_AUTH=true)"
elif [[ -n "${TTYD_USER}" && -n "${TTYD_PASS}" ]]; then
  TTYD_ARGS+=("--credential" "${TTYD_USER}:${TTYD_PASS}")
  echo "ttyd: basic auth enabled for user '${TTYD_USER}'"
else
  echo "ttyd: ERROR - no credentials configured. Set TTYD_USER and TTYD_PASS in .env, or set TTYD_NO_AUTH=true to explicitly disable auth."
  exit 1
fi

exec ttyd "${TTYD_ARGS[@]}" tmux new-session -A -s main
