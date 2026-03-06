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

# Wire gh as git credential helper so git push/fetch work without token embedding.
# Best-effort: skip gracefully if GH_TOKEN is not set or gh is not authenticated.
if gh auth status >/dev/null 2>&1; then
  if ! gh auth setup-git; then
    echo "ttyd: WARNING - failed to configure gh as git credential helper; continuing without it"
  fi
else
  echo "ttyd: WARNING - GitHub CLI not authenticated (GH_TOKEN not set?); skipping gh auth setup-git"
fi

# Auth precedence: credentials take priority; TTYD_NO_AUTH=true is the explicit opt-out.
# Setting both TTYD_NO_AUTH=true and credentials is a configuration error.
if [[ "${TTYD_NO_AUTH:-}" == "true" && -n "${TTYD_USER:-}" && -n "${TTYD_PASS:-}" ]]; then
  echo "ttyd: ERROR - conflicting auth config: TTYD_NO_AUTH=true set while TTYD_USER/TTYD_PASS are also configured. Unset TTYD_NO_AUTH or remove credentials."
  exit 1
elif [[ -n "${TTYD_USER:-}" && -n "${TTYD_PASS:-}" ]]; then
  TTYD_ARGS+=("--credential" "${TTYD_USER}:${TTYD_PASS}")
  echo "ttyd: basic auth enabled for user '${TTYD_USER}'"
elif [[ "${TTYD_NO_AUTH:-}" == "true" ]]; then
  echo "ttyd: WARNING - unauthenticated access enabled (TTYD_NO_AUTH=true)"
else
  echo "ttyd: ERROR - no credentials configured. Set TTYD_USER and TTYD_PASS in .env, or set TTYD_NO_AUTH=true to explicitly disable auth."
  exit 1
fi

exec ttyd "${TTYD_ARGS[@]}" tmux new-session -A -s main
