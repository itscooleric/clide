#!/bin/bash
set -e

# Print version at startup
CLIDE_VERSION="dev"
if [[ -f /etc/clide-version ]]; then
  CLIDE_VERSION=$(cat /etc/clide-version)
fi
echo "clide: starting v${CLIDE_VERSION}"

# Install LAN CA certificate at runtime (e.g. Caddy internal TLS root).
# Set CLIDE_CA_URL in .env to the URL of your CA cert. Uses -k for the
# initial fetch since the cert isn't trusted yet. Graceful — never blocks startup.
if [[ -n "${CLIDE_CA_URL:-}" ]]; then
  if curl -fsSLk "${CLIDE_CA_URL}" -o /usr/local/share/ca-certificates/lan-ca.crt 2>/dev/null \
     && update-ca-certificates 2>/dev/null; then
    echo "clide: installed CA cert from ${CLIDE_CA_URL}"
  else
    echo "clide: WARNING - failed to install CA cert from ${CLIDE_CA_URL}; continuing without it"
  fi
fi

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
  "--ping-interval" "${TTYD_PING_INTERVAL:-30}"
)

# ttyd 1.7.7 auto-reconnects by default. The "reconnect" client option is a
# DISABLE flag — any truthy value turns reconnect OFF. Only add it when the
# user explicitly wants to disable auto-reconnect.
if [[ "${TTYD_RECONNECT:-}" == "0" || "${TTYD_RECONNECT:-}" == "false" ]]; then
  TTYD_ARGS+=("--client-option" "reconnect=1")
  echo "ttyd: auto-reconnect disabled (TTYD_RECONNECT=${TTYD_RECONNECT})"
fi

# Wire gh as git credential helper so git push/fetch work without token embedding.
# Run as clide (user-scoped config); best-effort so missing GH_TOKEN doesn't block startup.
if gosu clide gh auth status >/dev/null 2>&1; then
  if ! gosu clide gh auth setup-git; then
    echo "ttyd: WARNING - failed to configure gh as git credential helper; continuing without it"
  fi
else
  echo "ttyd: WARNING - GitHub CLI not authenticated (GH_TOKEN not set?); skipping gh auth setup-git"
fi

# Wire glab auth for GitLab CLI — best-effort, missing token doesn't block startup.
if [[ -n "${GITLAB_TOKEN:-}" && -n "${GITLAB_HOST:-}" ]]; then
  gosu clide glab config set token "${GITLAB_TOKEN}" --host "${GITLAB_HOST}" 2>/dev/null \
    && echo "ttyd: glab authenticated for ${GITLAB_HOST}" \
    || echo "ttyd: WARNING - glab config failed; continuing without GitLab auth"
elif [[ -n "${GITLAB_TOKEN:-}" ]]; then
  gosu clide glab config set token "${GITLAB_TOKEN}" --host "gitlab.com" 2>/dev/null \
    && echo "ttyd: glab authenticated for gitlab.com" \
    || echo "ttyd: WARNING - glab config failed; continuing without GitLab auth"
else
  echo "ttyd: glab not configured (GITLAB_TOKEN not set — set in .env to enable)"
fi

# Auth modes (in priority order):
#   1. TTYD_AUTH_PROXY=true  — reverse proxy (Caddy/nginx) handles auth, ttyd uses --auth-header
#                              Fixes iOS/Safari WebSocket bug with ttyd's built-in basic auth.
#   2. TTYD_USER + TTYD_PASS — ttyd's built-in basic auth (broken on iOS/Safari WebKit browsers)
#   3. TTYD_NO_AUTH=true     — no auth (only safe behind VPN/firewall)
if [[ "${TTYD_AUTH_PROXY:-}" == "true" ]]; then
  # Proxy handles auth; ttyd trusts the X-Auth-User header from the proxy.
  # ttyd skips its own auth when --auth-header is set.
  TTYD_ARGS+=("--auth-header" "X-Auth-User")
  echo "ttyd: auth delegated to reverse proxy (--auth-header X-Auth-User)"
elif [[ "${TTYD_NO_AUTH:-}" == "true" && -n "${TTYD_USER:-}" && -n "${TTYD_PASS:-}" ]]; then
  echo "ttyd: ERROR - conflicting auth config: TTYD_NO_AUTH=true set while TTYD_USER/TTYD_PASS are also configured. Unset TTYD_NO_AUTH or remove credentials."
  exit 1
elif [[ -n "${TTYD_USER:-}" && -n "${TTYD_PASS:-}" ]]; then
  TTYD_ARGS+=("--credential" "${TTYD_USER}:${TTYD_PASS}")
  echo "ttyd: basic auth enabled for user '${TTYD_USER}' (WARNING: broken on iOS/Safari — use TTYD_AUTH_PROXY=true with Caddy instead)"
elif [[ "${TTYD_NO_AUTH:-}" == "true" ]]; then
  echo "ttyd: WARNING - unauthenticated access enabled (TTYD_NO_AUTH=true)"
else
  echo "ttyd: ERROR - no credentials configured. Set TTYD_USER and TTYD_PASS in .env, or set TTYD_NO_AUTH=true to explicitly disable auth."
  exit 1
fi

# Start intercepting proxy if enabled (must run before ttyd so all child processes inherit proxy env)
if [[ "${CLIDE_INTERCEPT:-0}" == "1" ]]; then
  /usr/local/bin/intercept-start.sh
  if [[ -f /tmp/.clide-proxy-env ]]; then
    # shellcheck disable=SC1091
    . /tmp/.clide-proxy-env
    echo "ttyd: proxy env vars set (HTTP_PROXY=${HTTP_PROXY:-})"
  fi
fi

# Drop privileges to clide before starting ttyd so the web terminal never runs as root.
# Note: ttyd logs the credential as base64 in its startup banner. This is only visible
# via `docker logs` (requires host access). We unset TTYD_PASS from the environment
# so child processes (tmux, shells, agents) can't read it.
unset TTYD_PASS
exec gosu clide ttyd "${TTYD_ARGS[@]}" tmux new-session -A -s main
