#!/bin/bash
set -euo pipefail

HOME_DIR="${HOME:-/home/clide}"
mkdir -p "$HOME_DIR"

export HOME="$HOME_DIR"

node <<'NODE'
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

# Opt-in tmux wrapping for shell service (set CLIDE_TMUX=1 in .env)
# Web terminal always uses tmux via entrypoint.sh; this covers make shell / ./clide shell.
if [[ -n "${CLIDE_TMUX:-}" ]]; then
  exec tmux new-session -A -s main "${@:-claude}"
fi

exec "${@:-claude}"
