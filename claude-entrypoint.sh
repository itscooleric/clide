#!/bin/bash
set -euo pipefail

# Hardcode clide's home — avoids picking up /root when entrypoint runs as root.
HOME_DIR="/home/clide"
export HOME="$HOME_DIR"

# Install LAN CA certificate at runtime if not already done (entrypoint.sh may have
# already handled this for the web service). Graceful — never blocks startup.
if [[ -n "${CLIDE_CA_URL:-}" && ! -f /usr/local/share/ca-certificates/lan-ca.crt ]]; then
  if curl -fsSLk "${CLIDE_CA_URL}" -o /usr/local/share/ca-certificates/lan-ca.crt 2>/dev/null \
     && update-ca-certificates 2>/dev/null; then
    echo "clide: installed CA cert from ${CLIDE_CA_URL}"
  else
    echo "clide: WARNING - failed to install CA cert from ${CLIDE_CA_URL}; continuing without it"
  fi
fi

# Set up egress firewall (CLIDE_FIREWALL=0 to disable; CLIDE_ALLOWED_HOSTS to extend)
# Skip if a parent entrypoint already ran it for this container.
if [[ "${CLIDE_FIREWALL_DONE:-0}" != "1" ]]; then
  # firewall.sh always exits 0 (handles all error cases internally with warnings);
  # the || true is a defensive safety net so a truly unexpected failure never
  # prevents the container from starting.
  /usr/local/bin/firewall.sh || true
  export CLIDE_FIREWALL_DONE=1
fi

# Persistent data directory — stored inside the workspace bind mount so
# everything lives alongside the project (no Docker named volumes needed).
CLIDE_DIR="/workspace/.clide"
mkdir -p "$CLIDE_DIR"
chown clide:clide "$CLIDE_DIR" 2>/dev/null || {
  # chown may fail on bind mounts without CHOWN capability or on filesystems
  # that don't support ownership changes (NFS, FUSE, etc.).  Fall back to
  # world-writable so the clide user can still read/write the directory.
  chmod 777 "$CLIDE_DIR" 2>/dev/null || echo "warning: cannot set permissions on $CLIDE_DIR" >&2
}

# Symlink ~/.claude → /workspace/.clide so Claude Code reads/writes into the
# workspace-local directory.  Run as clide since /home/clide is owned by the
# clide user and root may lack DAC_OVERRIDE to write there.
# Remove any stale file/dir first (e.g. from a previous named-volume mount).
if [[ -L "$HOME_DIR/.claude" ]]; then
  # Already a symlink — verify target
  if [[ "$(readlink "$HOME_DIR/.claude")" != "$CLIDE_DIR" ]]; then
    gosu clide rm -f "$HOME_DIR/.claude"
    gosu clide ln -s "$CLIDE_DIR" "$HOME_DIR/.claude"
  fi
elif [[ -d "$HOME_DIR/.claude" ]]; then
  # Migrate existing data from old named-volume mount into workspace
  cp -a "$HOME_DIR/.claude/." "$CLIDE_DIR/" 2>/dev/null || true
  gosu clide rm -rf "$HOME_DIR/.claude"
  gosu clide ln -s "$CLIDE_DIR" "$HOME_DIR/.claude"
else
  gosu clide ln -s "$CLIDE_DIR" "$HOME_DIR/.claude"
fi

# Seed CLAUDE.md into the workspace if a template exists and no CLAUDE.md is present.
# This gives every session a baseline set of instructions without overwriting user edits.
# Template search order: /workspace/.clide/CLAUDE.md.template, then bundled default.
CLAUDE_MD="/workspace/CLAUDE.md"
if [[ ! -f "$CLAUDE_MD" ]]; then
  TEMPLATE=""
  if [[ -f "/workspace/.clide/CLAUDE.md.template" ]]; then
    TEMPLATE="/workspace/.clide/CLAUDE.md.template"
  elif [[ -f "/usr/local/share/clide/CLAUDE.md.template" ]]; then
    TEMPLATE="/usr/local/share/clide/CLAUDE.md.template"
  fi
  if [[ -n "$TEMPLATE" ]]; then
    cp "$TEMPLATE" "$CLAUDE_MD"
    chown clide:clide "$CLAUDE_MD" 2>/dev/null || true
    echo "claude: seeded CLAUDE.md from ${TEMPLATE}"
  fi
fi

gosu clide node <<'NODE'
const fs = require('fs');

const configPath = `${process.env.HOME}/.claude.json`;
const apiKey = process.env.ANTHROPIC_API_KEY || '';
const oauthToken = process.env.CLAUDE_CODE_OAUTH_TOKEN || '';

let current = {};
if (fs.existsSync(configPath)) {
  try {
    current = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch {
    current = {};
  }
}

const next = {
  ...current,
  theme: current.theme || 'dark',
  hasCompletedOnboarding: true,
  hasCompletedProjectOnboarding: true,
  projects: {
    ...(current.projects || {}),
    '/workspace': {
      ...((current.projects || {})['/workspace'] || {}),
      hasTrustDialogAccepted: true,
    },
  },
};

// Only inject API key if OAuth token is NOT set (OAuth takes priority)
if (!oauthToken && apiKey) {
  next.primaryApiKey = apiKey;
}

fs.writeFileSync(configPath, JSON.stringify(next, null, 2));
// Ensure config is owned by clide even when script runs as root
const { execSync } = require('child_process');
try { execSync(`chown clide:clide ${configPath}`); } catch (_) {}

// Report which auth method is active
if (oauthToken) {
  console.log('claude: using OAuth token (subscription limits)');
} else if (apiKey) {
  console.log('claude: using API key (API credits)');
} else {
  console.log('claude: no authentication pre-configured — run `claude /login` to authenticate interactively');
  console.log('  Or set CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY in .env for headless auth');
}
NODE

# Clear API key from env if OAuth token is set (avoid auth conflicts)
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "claude: clearing ANTHROPIC_API_KEY from env (OAuth token takes priority)"
  unset ANTHROPIC_API_KEY
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  unset ANTHROPIC_API_KEY
fi

# Wire glab auth — best-effort, missing token doesn't block startup.
if [[ -n "${GITLAB_TOKEN:-}" && -n "${GITLAB_HOST:-}" ]]; then
  gosu clide glab config set token "${GITLAB_TOKEN}" --host "${GITLAB_HOST}" 2>/dev/null \
    && echo "claude: glab authenticated for ${GITLAB_HOST}" \
    || echo "claude: WARNING - glab config failed; continuing without GitLab auth"
elif [[ -n "${GITLAB_TOKEN:-}" ]]; then
  gosu clide glab config set token "${GITLAB_TOKEN}" --host "gitlab.com" 2>/dev/null \
    && echo "claude: glab authenticated for gitlab.com" \
    || echo "claude: WARNING - glab config failed; continuing without GitLab auth"
fi

# Opt-in tmux wrapping for shell service (set CLIDE_TMUX=1 in .env)
# Web terminal always uses tmux via entrypoint.sh; this covers make cli / ./clide cli.
# Drop privileges to clide via gosu before exec so the workload never runs as root.

# Start intercepting proxy if enabled (captures all HTTP(S) traffic to JSONL).
# Must start before the agent so proxy env vars are inherited.
if [[ "${CLIDE_INTERCEPT:-0}" == "1" ]]; then
  /usr/local/bin/intercept-start.sh
  # Source the proxy env vars so the agent uses the proxy
  if [[ -f /tmp/.clide-proxy-env ]]; then
    # shellcheck disable=SC1091
    . /tmp/.clide-proxy-env
  fi
fi

# Wrap agent CLIs with session logger for structured logging + transcript capture.
# Set CLIDE_LOG_DISABLED=1 to skip. Logger is agent-agnostic — works with claude, codex, etc.
AGENT_CMD="${*:-claude}"
if [[ -x /usr/local/bin/session-logger.sh && "${CLIDE_LOG_DISABLED:-}" != "1" ]]; then
  AGENT_CMD="session-logger.sh ${AGENT_CMD}"
fi

if [[ -n "${CLIDE_TMUX:-}" ]]; then
  # shellcheck disable=SC2086
  exec gosu clide tmux new-session -A -s main ${AGENT_CMD}
fi

# shellcheck disable=SC2086
exec gosu clide ${AGENT_CMD}
