#!/bin/bash
# session-logger.sh — Structured session logging for agent CLIs
#
# Wraps an agent CLI session with:
#   1. JSONL event logging (session start/end events)
#   2. Conversation capture from Claude Code's native JSONL session logs
#   3. Raw terminal transcript via `script` (optional, for replay)
#   4. Secret scrubbing on all logged output
#   5. Log retention (prune old sessions)
#
# Usage:
#   session-logger.sh claude [args...]
#   session-logger.sh codex [args...]
#   session-logger.sh <any-command> [args...]
#
# Output:
#   $CLIDE_LOG_DIR/<session_id>/
#     events.jsonl        — clide session envelope events (start/end)
#     conversation.jsonl  — Claude Code's native conversation log (symlinked)
#     transcript.raw.gz   — raw terminal I/O (VT100 stream, for replay only)
#
# Environment:
#   CLIDE_LOG_DIR         — log root (default: /workspace/.clide/logs)
#   CLIDE_MAX_SESSIONS    — retention limit (default: 30)
#   CLIDE_LOG_DISABLED    — set to 1 to disable logging entirely
#   CLIDE_RAW_TRANSCRIPT  — set to 1 to also capture raw PTY via `script`

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────

LOG_DIR="${CLIDE_LOG_DIR:-/workspace/.clide/logs}"
MAX_SESSIONS="${CLIDE_MAX_SESSIONS:-30}"
SCHEMA_VERSION=1

# Skip logging entirely if disabled or if command is a no-op (e.g. entrypoint pre-seed)
if [[ "${CLIDE_LOG_DISABLED:-}" == "1" || "${1:-}" == "true" ]]; then
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
RAW_TRANSCRIPT="${SESSION_DIR}/transcript.raw"

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
  # shellcheck disable=SC2012
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

# ── Cleanup (runs on EXIT — covers clean exit, Ctrl+C, SIGTERM) ──

# Guard against the cleanup handler running more than once (e.g. a signal
# fires during cleanup itself).
_CLEANUP_DONE=0

cleanup() {
  if [[ "$_CLEANUP_DONE" == "1" ]]; then return; fi
  _CLEANUP_DONE=1

  # ── Compress raw transcript ──────────────────────────────────
  if [[ -f "${RAW_TRANSCRIPT}" && -s "${RAW_TRANSCRIPT}" ]]; then
    gzip -f "${RAW_TRANSCRIPT}" 2>/dev/null || true
  fi

  # ── Harvest Claude Code conversation log ─────────────────────
  # Claude Code saves structured JSONL at ~/.claude/projects/<proj>/<uuid>.jsonl
  # with full conversation: user messages, assistant responses (including
  # thinking), tool_use calls, and tool_results. This is the readable
  # session log — far superior to raw PTY capture.
  CLAUDE_SESSION_ID=""
  if [[ "$AGENT" == "claude" && -d "$CLAUDE_PROJECTS_DIR" ]]; then
    CLAUDE_SESSIONS_AFTER=$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -name '*.jsonl' -newer "${EVENTS_FILE}" 2>/dev/null | sort || true)

    # Find new JSONL files created during this session
    NEW_SESSION_FILES=""
    if [[ -n "$CLAUDE_SESSIONS_AFTER" ]]; then
      if [[ -n "$CLAUDE_SESSIONS_BEFORE" ]]; then
        NEW_SESSION_FILES=$(comm -13 <(echo "$CLAUDE_SESSIONS_BEFORE") <(echo "$CLAUDE_SESSIONS_AFTER") || true)
      else
        NEW_SESSION_FILES="$CLAUDE_SESSIONS_AFTER"
      fi
    fi

    # Pick the most recently modified new file (there should typically be exactly one)
    if [[ -n "$NEW_SESSION_FILES" ]]; then
      LATEST_SESSION=$(echo "$NEW_SESSION_FILES" | while read -r f; do
        echo "$(stat -c '%Y' "$f" 2>/dev/null || echo 0) $f"
      done | sort -rn | head -1 | cut -d' ' -f2-)

      if [[ -n "$LATEST_SESSION" && -f "$LATEST_SESSION" ]]; then
        # Symlink (not copy) to save disk — Claude manages its own retention
        ln -sf "$LATEST_SESSION" "${SESSION_DIR}/conversation.jsonl"
        CONV_LINES=$(wc -l < "$LATEST_SESSION" 2>/dev/null || echo 0)
        CONV_SIZE=$(stat -c '%s' "$LATEST_SESSION" 2>/dev/null || echo 0)
        echo "[session-logger] Linked conversation log: ${LATEST_SESSION} (${CONV_LINES} messages, $(( CONV_SIZE / 1024 ))KB)"
      fi
    fi

    # Also capture the Claude session ID if available from session files
    for sf in "${HOME}/.claude/sessions/"*.json; do
      if [[ -f "$sf" ]]; then
        _sid=$(python3 -c "
import json, sys
try:
    d = json.load(open('$sf'))
    if isinstance(d, dict) and d.get('sessionId'):
        print(d['sessionId'])
except: pass
" 2>/dev/null || true)
        if [[ -n "$_sid" ]]; then
          CLAUDE_SESSION_ID="$_sid"
        fi
      fi
    done
  fi

  # ── Emit session_end ───────────────────────────────────────────
  local _outcome
  _outcome=$([ "${EXIT_CODE}" -eq 0 ] && echo 'success' || echo 'error')

  # If we got here via signal (not clean exit), mark it
  if [[ -n "${_SIGNAL:-}" ]]; then
    _outcome="killed"
  fi

  local _end_args=(
    "agent=${AGENT}"
    "exit_code=${EXIT_CODE}"
    "outcome=${_outcome}"
  )
  if [[ -n "${_SIGNAL:-}" ]]; then
    _end_args+=("signal=${_SIGNAL}")
  fi
  if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    _end_args+=("claude_session_id=${CLAUDE_SESSION_ID}")
  fi
  if [[ -L "${SESSION_DIR}/conversation.jsonl" ]]; then
    _end_args+=("has_conversation=true")
  fi
  emit_event "session_end" "${_end_args[@]}"

  # ── Send end/error notification ────────────────────────────────
  if [[ -x "${NOTIFY_SCRIPT:-}" ]]; then
    if [[ ${EXIT_CODE} -eq 0 ]]; then
      "$NOTIFY_SCRIPT" end "${SESSION_ID}" "${AGENT}" "exit 0" &
    else
      "$NOTIFY_SCRIPT" error "${SESSION_ID}" "${AGENT}" "exit ${EXIT_CODE}" &
    fi
  fi

  echo "[session-logger] Session ${SESSION_ID} ended (exit=${EXIT_CODE})"
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

# Send start notification
NOTIFY_SCRIPT="$(command -v notify.sh 2>/dev/null || echo "$(dirname "$0")/notify.sh")"
if [[ -x "$NOTIFY_SCRIPT" ]]; then
  "$NOTIFY_SCRIPT" start "${SESSION_ID}" "${AGENT}" &
fi

# ── Snapshot Claude session list before run ──────────────────────
# We'll diff after the session to find the new conversation JSONL.
CLAUDE_PROJECTS_DIR="${HOME}/.claude/projects"
CLAUDE_SESSIONS_BEFORE=""
if [[ "$AGENT" == "claude" && -d "$CLAUDE_PROJECTS_DIR" ]]; then
  CLAUDE_SESSIONS_BEFORE=$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -name '*.jsonl' -newer "${EVENTS_FILE}" 2>/dev/null | sort || true)
fi

# ── Install cleanup trap ─────────────────────────────────────────
# Runs on normal exit (EXIT) and common kill signals so session_end +
# conversation harvesting happen even when the agent is Ctrl+C'd or
# the container is stopped.
EXIT_CODE=0
_SIGNAL=""
trap 'cleanup' EXIT
trap '_SIGNAL=INT;  EXIT_CODE=130; exit 130' INT
trap '_SIGNAL=TERM; EXIT_CODE=143; exit 143' TERM
trap '_SIGNAL=HUP;  EXIT_CODE=129; exit 129' HUP

# ── Run the agent ────────────────────────────────────────────────
# Raw PTY transcript is optional (VT100 byte stream — not human-readable
# for TUI agents like Claude Code, but useful for scriptreplay).
if [[ "${CLIDE_RAW_TRANSCRIPT:-0}" == "1" ]] && command -v script >/dev/null 2>&1; then
  script -q -f -c "$*" "${RAW_TRANSCRIPT}" || EXIT_CODE=$?
else
  "$@" || EXIT_CODE=$?
fi

# cleanup runs automatically via the EXIT trap
exit ${EXIT_CODE}
