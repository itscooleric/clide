#!/bin/bash
set -e

TTYD_ARGS=(
  "--writable"
  "--port" "${TTYD_PORT:-7681}"
  "--base-path" "${TTYD_BASE_PATH:-/}"
)

# Add basic auth if credentials are set
if [[ -n "${TTYD_USER}" && -n "${TTYD_PASS}" ]]; then
  TTYD_ARGS+=("--credential" "${TTYD_USER}:${TTYD_PASS}")
  echo "ttyd: basic auth enabled for user '${TTYD_USER}'"
else
  echo "ttyd: WARNING - no authentication configured (set TTYD_USER and TTYD_PASS in .env)"
fi

exec ttyd "${TTYD_ARGS[@]}" /bin/bash
