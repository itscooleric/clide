#!/bin/bash
# notify.sh — Push notifications via ntfy for agent session events
#
# Sends notifications on session start, end, and errors.
# Approval-prompt detection requires structured output (SDK/stream-json)
# which is tracked separately — raw terminal transcripts are too noisy
# for reliable pattern matching.
#
# Environment:
#   CLIDE_NTFY_URL      — ntfy server URL (e.g. https://ntfy.lan.wubi.sh)
#   CLIDE_NTFY_TOPIC    — topic name (default: clide)
#   CLIDE_NTFY_DISABLED — set to 1 to disable notifications
#
# Usage: notify.sh <event> <session_id> <agent> [detail]
#   Events: start, end, error

set -uo pipefail

EVENT="${1:-}"
SESSION_ID="${2:-unknown}"
AGENT="${3:-claude}"
DETAIL="${4:-}"

NTFY_URL="${CLIDE_NTFY_URL:-}"
NTFY_TOPIC="${CLIDE_NTFY_TOPIC:-clide}"

# Bail if no ntfy configured or disabled
if [[ -z "$NTFY_URL" || "${CLIDE_NTFY_DISABLED:-}" == "1" ]]; then
  exit 0
fi

ENDPOINT="${NTFY_URL}/${NTFY_TOPIC}"

case "$EVENT" in
  start)
    curl -sf -X POST "$ENDPOINT" \
      -H "Title: ${AGENT}: Session started" \
      -H "Tags: robot" \
      -d "${SESSION_ID}" \
      >/dev/null 2>&1 || true
    ;;
  end)
    curl -sf -X POST "$ENDPOINT" \
      -H "Title: ${AGENT}: Session ended" \
      -H "Tags: robot" \
      -d "${SESSION_ID} — ${DETAIL:-exit 0}" \
      >/dev/null 2>&1 || true
    ;;
  error)
    curl -sf -X POST "$ENDPOINT" \
      -H "Title: ${AGENT}: Error" \
      -H "Priority: high" \
      -H "Tags: warning,robot" \
      -d "${SESSION_ID} — ${DETAIL:-unknown error}" \
      >/dev/null 2>&1 || true
    ;;
  *)
    # Unknown event — send generic notification
    curl -sf -X POST "$ENDPOINT" \
      -H "Title: ${AGENT}: ${EVENT}" \
      -H "Tags: robot" \
      -d "${SESSION_ID} ${DETAIL:-}" \
      >/dev/null 2>&1 || true
    ;;
esac
