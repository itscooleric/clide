#!/bin/bash
# intercept-start.sh — start the intercepting proxy for agent traffic capture
#
# Environment:
#   CLIDE_INTERCEPT=1          Enable intercepting proxy (default: disabled)
#   CLIDE_INTERCEPT_PORT=8080  Proxy listen port (default: 8080)
#   CLIDE_INTERCEPT_BODIES=0   Capture request/response bodies (default: 0)
#   CLIDE_LOG_DIR              Log directory (default: /workspace/.clide/logs)

set -euo pipefail

if [[ "${CLIDE_INTERCEPT:-0}" != "1" ]]; then
  exit 0
fi

PORT="${CLIDE_INTERCEPT_PORT:-8080}"
SCRIPT_DIR="$(dirname "$0")"
ADDON="${SCRIPT_DIR}/intercept-proxy.py"
if [[ ! -f "$ADDON" ]]; then
  ADDON="/usr/local/bin/intercept-proxy.py"
fi

if ! command -v mitmdump >/dev/null 2>&1; then
  echo "[intercept] ERROR: mitmdump not found. Install with: pip install mitmproxy"
  exit 1
fi

echo "[intercept] Starting proxy on port ${PORT} (bodies=${CLIDE_INTERCEPT_BODIES:-0})"

# Start mitmdump in background
mitmdump \
  --listen-port "$PORT" \
  --set ssl_insecure=true \
  --set block_global=false \
  -s "$ADDON" \
  --quiet &

PROXY_PID=$!
echo "[intercept] Proxy started (pid ${PROXY_PID})"

# Export proxy env vars so child processes (claude, codex, etc.) use the proxy
export HTTP_PROXY="http://127.0.0.1:${PORT}"
export HTTPS_PROXY="http://127.0.0.1:${PORT}"
export http_proxy="http://127.0.0.1:${PORT}"
export https_proxy="http://127.0.0.1:${PORT}"

# Write env vars to a file that session-logger can source
ENV_FILE="/tmp/.clide-proxy-env"
cat > "$ENV_FILE" << EOF
export HTTP_PROXY=http://127.0.0.1:${PORT}
export HTTPS_PROXY=http://127.0.0.1:${PORT}
export http_proxy=http://127.0.0.1:${PORT}
export https_proxy=http://127.0.0.1:${PORT}
EOF

echo "[intercept] Proxy env written to ${ENV_FILE}"
echo "[intercept] Logs: \${CLIDE_LOG_DIR:-/workspace/.clide/logs}/intercept.jsonl"
