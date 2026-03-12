#!/bin/bash
# session-logger.sh — Structured session logging for agent CLIs
#
# Wraps an agent CLI session with:
#   1. JSONL event logging (session start/end events)
#   2. Raw transcript capture via `script`
#   3. Secret scrubbing on all logged output
#   4. Log retention (prune old sessions)
#
# Usage:
#   session-logger.sh claude [args...]
#   session-logger.sh codex [args...]
#   session-logger.sh <any-command> [args...]
#
# Output:
#   $CLIDE_LOG_DIR/<session_id>/
#     events.jsonl      — structured session events
#     transcript.txt    — raw terminal I/O
#     transcript.txt.gz — compressed after session ends
#
# Environment:
#   CLIDE_LOG_DIR         — log root (default: /workspace/.clide/logs)
#   CLIDE_MAX_SESSIONS    — retention limit (default: 30)
#   CLIDE_LOG_DISABLED    — set to 1 to disable logging entirely

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────

LOG_DIR="${CLIDE_LOG_DIR:-/workspace/.clide/logs}"
MAX_SESSIONS="${CLIDE_MAX_SESSIONS:-30}"
SCHEMA_VERSION=1

# Skip logging entirely if disabled
if [[ "${CLIDE_LOG_DISABLED:-}" == "1" ]]; then
  exec "$@"
fi

# ── ULID-ish session ID ──────────────────────────────────────────

generate_session_id() {
  # Timestamp prefix (ms since epoch in base36) + random suffix
  local ts
  ts=$(python3 -c "import time,string; t=int(time.time()*1000); chars=string.digits+string.ascii_lowercase; r=''; 
while t>0: r=chars[t%36]+r; t//=36
print(r)" 2>/dev/null || date +%s)
  local rand
  rand=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)
  echo "clide-${ts}-${rand}"
}

SESSION_ID=$(generate_session_id)
SESSION_DIR="${LOG_DIR}/${SESSION_ID}"
EVENTS_FILE="${SESSION_DIR}/events.jsonl"
TRANSCRIPT_FILE="${SESSION_DIR}/transcript.txt"

mkdir -p "${SESSION_DIR}"

# ── Secret scrubbing ─────────────────────────────────────────────

# Blocklist of env var names whose values must be redacted
SECRET_NAMES=(
  GH_TOKEN GITHUB_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY
  CLAUDE_CODE_OAUTH_TOKEN TTYD_PASS TTYD_USER
  CLEM_WEB_SECRET SUPERVISOR_SECRET TEDDY_API_KEY
  TEDDY_WEB_PASSWORD GITLAB_TOKEN
)

scrub_secrets() {
  local text="$1"
  # Redact known secret env var values
  for name in "${SECRET_NAMES[@]}"; do
    local val="${!name:-}"
    if [[ -n "$val" && ${#val} -ge 4 ]]; then
      text="${text//$val/[REDACTED:${name}]}"
    fi
  done
  # Heuristic: redact env var assignments (KEY=value patterns)
  text=$(echo "$text" | sed -E 's/([A-Z_]{3,})=([^ "]{8,})/\1=[REDACTED]/g')
  echo "$text"
}

# ── Event emitter ─────────────────────────────────────────────────

emit_event() {
  local event_type="$1"
  shift
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build JSON — use python for reliable escaping
  python3 -c "
import json, sys
event = {
    'event': '$event_type',
    'ts': '$ts',
    'session_id': '${SESSION_ID}',
    'schema_version': ${SCHEMA_VERSION},
}
# Merge extra fields from args (key=value pairs)
for arg in sys.argv[1:]:
    if '=' in arg:
        k, v = arg.split('=', 1)
        # Try to parse as number or bool
        try:
            v = json.loads(v)
        except (json.JSONDecodeError, ValueError):
            pass
        event[k] = v
print(json.dumps(event))
" "$@" >> "${EVENTS_FILE}"
}

# ── Log retention ─────────────────────────────────────────────────

prune_sessions() {
  if [[ ! -d "${LOG_DIR}" ]]; then return; fi

  local sessions
  sessions=$(ls -1dt "${LOG_DIR}"/clide-* 2>/dev/null | tail -n +$((MAX_SESSIONS + 1)))

  if [[ -z "$sessions" ]]; then return; fi

  local count=0
  while IFS= read -r old_session; do
    rm -rf "$old_session"
    count=$((count + 1))
  done <<< "$sessions"

  if [[ $count -gt 0 ]]; then
    echo "[session-logger] Pruned ${count} old session(s) (keeping ${MAX_SESSIONS})"
  fi
}

# ── Detect agent and repo ─────────────────────────────────────────

detect_agent() {
  local cmd="${1:-unknown}"
  case "$cmd" in
    claude*) echo "claude" ;;
    codex*)  echo "codex" ;;
    copilot*) echo "copilot" ;;
    *)       echo "$cmd" ;;
  esac
}

detect_repo() {
  git remote get-url origin 2>/dev/null \
    | sed -E 's|.*[:/]([^/]+/[^/]+?)(\.git)?$|\1|' \
    || echo "unknown"
}

detect_model() {
  local agent="$1"
  case "$agent" in
    claude) echo "${CLAUDE_MODEL:-claude-sonnet-4-20250514}" ;;
    codex)  echo "${CODEX_MODEL:-codex}" ;;
    *)      echo "unknown" ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────

AGENT=$(detect_agent "${1:-}")
REPO=$(detect_repo)
MODEL=$(detect_model "$AGENT")

# Prune old sessions before starting
prune_sessions

# Emit session_start
emit_event "session_start" \
  "agent=${AGENT}" \
  "repo=${REPO}" \
  "model=${MODEL}" \
  "command=$(scrub_secrets "$*")" \
  "cwd=$(pwd)"

echo "[session-logger] Session ${SESSION_ID} started (agent=${AGENT}, logs=${SESSION_DIR})"

# Start notification watcher in background (if ntfy is configured)
NOTIFY_PID=""
NOTIFY_SCRIPT="$(command -v notify.sh 2>/dev/null || echo "$(dirname "$0")/notify.sh")"
if [[ -x "$NOTIFY_SCRIPT" && -n "${CLIDE_NTFY_URL:-}" && "${CLIDE_NTFY_DISABLED:-}" != "1" ]]; then
  "$NOTIFY_SCRIPT" "${TRANSCRIPT_FILE}" "${SESSION_ID}" "${AGENT}" &
  NOTIFY_PID=$!
  echo "[session-logger] Notifications enabled (ntfy topic: ${CLIDE_NTFY_TOPIC:-clide})"
fi

# Run the agent inside `script` for transcript capture
# -q: quiet (no "Script started" banner)
# -f: flush after each write
# -c: command to run
EXIT_CODE=0
if command -v script >/dev/null 2>&1; then
  script -q -f -c "$*" "${TRANSCRIPT_FILE}" || EXIT_CODE=$?
else
  # Fallback: no transcript, just run directly
  "$@" || EXIT_CODE=$?
fi

# Stop notification watcher
if [[ -n "${NOTIFY_PID}" ]]; then
  kill "$NOTIFY_PID" 2>/dev/null || true
  wait "$NOTIFY_PID" 2>/dev/null || true
fi

# Compress transcript
if [[ -f "${TRANSCRIPT_FILE}" && -s "${TRANSCRIPT_FILE}" ]]; then
  gzip -f "${TRANSCRIPT_FILE}" 2>/dev/null || true
fi

# Emit session_end
emit_event "session_end" \
  "agent=${AGENT}" \
  "exit_code=${EXIT_CODE}" \
  "outcome=$([ $EXIT_CODE -eq 0 ] && echo 'success' || echo 'error')"

echo "[session-logger] Session ${SESSION_ID} ended (exit=${EXIT_CODE})"

exit ${EXIT_CODE}
