#!/bin/bash
set -euo pipefail

CLAUDE_CONFIG="/root/.claude.json"

mkdir -p /root

node <<'NODE'
const fs = require('fs');

const configPath = '/root/.claude.json';
const apiKey = process.env.ANTHROPIC_API_KEY || '';

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

if (apiKey) {
  next.primaryApiKey = apiKey;
}

fs.writeFileSync(configPath, JSON.stringify(next, null, 2));
NODE

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  unset ANTHROPIC_API_KEY
fi

exec claude "$@"
