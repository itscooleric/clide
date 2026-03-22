# shellcheck shell=bash

# Ensure pyenv (pip, pytest, ruff) and workspace tools are on PATH.
# Docker ENV PATH isn't always propagated through gosu → tmux → bash.
export PATH="/home/clide/.local/bin:/opt/pyenv/bin:${PATH}"

# Source workspace addon activators — lets tools self-inject into the
# shell environment without clide needing to know about them.
# Each addon provides its own bin/activate.sh (e.g. clidesdale, clidetext).
for _activator in /workspace/*/bin/activate.sh; do
  [[ -f "$_activator" ]] && . "$_activator"
done
unset _activator

# Show splash on first interactive login (web terminal / tmux session).
# Guard with CLIDE_SPLASH_SHOWN so it only prints once per session, not on
# every new pane/window split.
if [[ $- == *i* && -z "${CLIDE_SPLASH_SHOWN:-}" ]]; then
  export CLIDE_SPLASH_SHOWN=1
  CLIDE_VERSION="dev"
  if [[ -f /etc/clide-version ]]; then
    CLIDE_VERSION=$(cat /etc/clide-version)
  fi
  echo ""
  echo "  ██████╗██╗     ██╗██████╗ ███████╗"
  echo " ██╔════╝██║     ██║██╔══██╗██╔════╝"
  echo " ██║     ██║     ██║██║  ██║█████╗  "
  echo " ██║     ██║     ██║██║  ██║██╔══╝  "
  echo " ╚██████╗███████╗██║██████╔╝███████╗"
  echo "  ╚═════╝╚══════╝╚═╝╚═════╝ ╚══════╝"
  echo ""
  echo "  CLI Development Environment  (${CLIDE_VERSION})"
  echo "  Copilot · GitHub CLI · Claude Code · Codex CLI"
  echo ""
fi

# Wrap agent CLIs through session-logger for structured logging + notifications.
# Disable with CLIDE_LOG_DISABLED=1 in .env.
if command -v session-logger.sh >/dev/null 2>&1 && [[ "${CLIDE_LOG_DISABLED:-}" != "1" ]]; then
  claude()  { session-logger.sh claude "$@"; }
  codex()   { session-logger.sh codex "$@"; }
  copilot() { session-logger.sh copilot "$@"; }
fi
