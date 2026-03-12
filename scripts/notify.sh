#!/bin/bash
# notify.sh — Push notifications via ntfy when agent needs attention
#
# Monitors the running agent's transcript for approval prompts and sends
# push notifications so you can approve from your phone.
#
# Environment:
#   CLIDE_NTFY_URL     — ntfy server URL (e.g. https://ntfy.lan.wubi.sh)
#   CLIDE_NTFY_TOPIC   — topic name (default: clide)
#   CLIDE_NTFY_DISABLED — set to 1 to disable notifications
#
# Called from session-logger.sh as a background watcher on the transcript.
# Usage: notify.sh <transcript_file> <session_id> <agent>

set -uo pipefail

TRANSCRIPT="$1"
SESSION_ID="$2"
AGENT="${3:-claude}"

NTFY_URL="${CLIDE_NTFY_URL:-}"
NTFY_TOPIC="${CLIDE_NTFY_TOPIC:-clide}"

# Bail if no ntfy configured or disabled
if [[ -z "$NTFY_URL" || "${CLIDE_NTFY_DISABLED:-}" == "1" ]]; then
  exit 0
fi

ENDPOINT="${NTFY_URL}/${NTFY_TOPIC}"

# Cooldown: don't spam — at most one notification every 30 seconds
COOLDOWN=30
LAST_NOTIFY=0

send_notification() {
  local title="$1"
  local message="$2"
  local priority="${3:-default}"
  local tags="${4:-robot}"

  local now
  now=$(date +%s)
  local elapsed=$(( now - LAST_NOTIFY ))
  if [[ $elapsed -lt $COOLDOWN ]]; then
    return
  fi
  LAST_NOTIFY=$now

  curl -sf -X POST "$ENDPOINT" \
    -H "Title: ${title}" \
    -H "Priority: ${priority}" \
    -H "Tags: ${tags}" \
    -d "${message}" \
    >/dev/null 2>&1 || true
}

# Wait for transcript to appear
for i in {1..10}; do
  [[ -f "$TRANSCRIPT" ]] && break
  sleep 1
done
[[ ! -f "$TRANSCRIPT" ]] && exit 0

# Tail the transcript and watch for approval patterns
# Claude Code shows these patterns when it needs approval:
#   "Allow <tool>?"
#   "Do you want to proceed?"
#   "Press Enter to allow"
#   "Allow once" / "Allow always"
#   "yes/no"
#   "Bash: <command>" (with permission prompt)
tail -f "$TRANSCRIPT" 2>/dev/null | while IFS= read -r line; do
  # Strip ANSI escape sequences for matching
  clean=$(echo "$line" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')

  case "$clean" in
    *"Allow once"*|*"Allow always"*)
      send_notification \
        "🔐 ${AGENT}: Approval needed" \
        "Permission request waiting — ${SESSION_ID}" \
        "high" \
        "lock,robot"
      ;;
    *"Do you want to"*|*"Press Enter"*)
      send_notification \
        "❓ ${AGENT}: Input needed" \
        "Waiting for your response — ${SESSION_ID}" \
        "default" \
        "question,robot"
      ;;
    *"error"*[Ee]"rror"*|*"FAILED"*|*"fatal:"*)
      send_notification \
        "❌ ${AGENT}: Error" \
        "${clean:0:200}" \
        "high" \
        "warning,robot"
      ;;
    *"Task completed"*|*"Completed in"*)
      send_notification \
        "✅ ${AGENT}: Done" \
        "${clean:0:200}" \
        "default" \
        "white_check_mark,robot"
      ;;
  esac
done
