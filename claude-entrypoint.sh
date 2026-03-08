#!/bin/bash
set -euo pipefail

# Hardcode clide's home — avoids picking up /root when entrypoint runs as root.
HOME_DIR="/home/clide"
export HOME="$HOME_DIR"

# Set up egress firewall (CLIDE_FIREWALL=0 to disable; CLIDE_ALLOWED_HOSTS to extend)
# Skip if a parent entrypoint already ran it for this container.
if [[ "${CLIDE_FIREWALL_DONE:-0}" != "1" ]]; then
  # firewall.sh always exits 0 (handles all error cases internally with warnings);
  # the || true is a defensive safety net so a truly unexpected failure never
  # prevents the container from starting.
  /usr/local/bin/firewall.sh || true
  export CLIDE_FIREWALL_DONE=1
fi

# Seed CLAUDE.md into the workspace if a template exists and no CLAUDE.md is present.
# This gives every session a baseline set of instructions without overwriting user edits.
# Template search order: /workspace/.claude/CLAUDE.md.template, then bundled default.
CLAUDE_MD="/workspace/CLAUDE.md"
if [[ ! -f "$CLAUDE_MD" ]]; then
  TEMPLATE=""
  if [[ -f "/workspace/.claude/CLAUDE.md.template" ]]; then
    TEMPLATE="/workspace/.claude/CLAUDE.md.template"
  elif [[ -f "/usr/local/share/clide/CLAUDE.md.template" ]]; then
    TEMPLATE="/usr/local/share/clide/CLAUDE.md.template"
  fi
  if [[ -n "$TEMPLATE" ]]; then
    cp "$TEMPLATE" "$CLAUDE_MD"
    chown clide:clide "$CLAUDE_MD"
    echo "claude: seeded CLAUDE.md from ${TEMPLATE}"
  fi
fi

# Ensure the persistent volume directory is owned by clide (first-run fix for named volumes)
chown -R clide:clide "$HOME_DIR/.claude" 2>/dev/null || true

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
  console.log('claude: WARNING - no authentication configured');
  console.log('  Set CLAUDE_CODE_OAUTH_TOKEN (subscription) or ANTHROPIC_API_KEY (API credits) in .env');
  console.log('  To generate an OAuth token: claude setup-token (on a machine with a browser)');
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
# Web terminal always uses tmux via entrypoint.sh; this covers make shell / ./clide shell.
# Drop privileges to clide via gosu before exec so the workload never runs as root.
if [[ -n "${CLIDE_TMUX:-}" ]]; then
  exec gosu clide tmux new-session -A -s main "${@:-claude}"
fi

exec gosu clide "${@:-claude}"
