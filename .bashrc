# Wrap agent CLIs through session-logger for structured logging + notifications.
# Disable with CLIDE_LOG_DISABLED=1 in .env.
if command -v session-logger.sh >/dev/null 2>&1 && [[ "${CLIDE_LOG_DISABLED:-}" != "1" ]]; then
  claude()  { session-logger.sh claude "$@"; }
  codex()   { session-logger.sh codex "$@"; }
  copilot() { session-logger.sh copilot "$@"; }
fi
