#!/bin/bash
set -euo pipefail

mkdir -p /root

# Set up egress firewall (CLIDE_FIREWALL=0 to disable; CLIDE_ALLOWED_HOSTS to extend)
# Skip if a parent entrypoint already ran it for this container.
if [[ "${CLIDE_FIREWALL_DONE:-0}" != "1" ]]; then
  # firewall.sh always exits 0 (handles all error cases internally with warnings);
  # the || true is a defensive safety net so a truly unexpected failure never
  # prevents the container from starting.
  /usr/local/bin/firewall.sh || true
  export CLIDE_FIREWALL_DONE=1
fi

node <<'NODE'
const fs = require('fs');

const configPath = '/root/.claude.json';
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
