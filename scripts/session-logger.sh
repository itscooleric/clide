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
#   CLIDE_MAX_SESSIONS    — retention limit (default: 0 = unlimited, no pruning)
#   CLIDE_LOG_DISABLED    — set to 1 to disable logging entirely
#   CLIDE_RAW_TRANSCRIPT  — set to 1 to also capture raw PTY via `script`

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────

LOG_DIR="${CLIDE_LOG_DIR:-/workspace/.clide/logs}"
MAX_SESSIONS="${CLIDE_MAX_SESSIONS:-0}"
SCHEMA_VERSION=1

# Skip logging entirely if disabled or if command is a no-op (e.g. entrypoint pre-seed)
if [[ "${CLIDE_LOG_DISABLED:-}" == "1" || "${1:-}" == "true" ]]; then
  exec "$@"
fi

# ── ULID-ish session ID ──────────────────────────────────────────

generate_session_id() {
  # Human-readable datetime prefix + random suffix for uniqueness
  local dt
  dt=$(date -u +"%Y%m%d-%H%M%S")
  local rand
  rand=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)
  echo "clide-${dt}-${rand}"
}

SESSION_ID=$(generate_session_id)
SESSION_DIR="${LOG_DIR}/${SESSION_ID}"
EVENTS_FILE="${SESSION_DIR}/events.jsonl"
RAW_TRANSCRIPT="${SESSION_DIR}/transcript.raw"

mkdir -p "${SESSION_DIR}"

# Export session dir so intercept-proxy and egress-audit can write per-session logs
export CLIDE_SESSION_DIR="${SESSION_DIR}"

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
  # Default: no pruning (MAX_SESSIONS=0 means unlimited).
  # Session data is research-critical and must never be auto-deleted.
  # If disk space is a concern, notify the user — don't silently prune.
  if [[ "${MAX_SESSIONS}" -le 0 ]]; then return; fi
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

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  if [[ "$_CLEANUP_DONE" == "1" ]]; then return; fi
  _CLEANUP_DONE=1

  # Kill the conversation watcher if still running
  if [[ -n "${_WATCHER_PID:-}" ]]; then
    kill "$_WATCHER_PID" 2>/dev/null || true
    wait "$_WATCHER_PID" 2>/dev/null || true
  fi

  # ── Compress raw transcript ──────────────────────────────────
  if [[ -f "${RAW_TRANSCRIPT}" && -s "${RAW_TRANSCRIPT}" ]]; then
    gzip -f "${RAW_TRANSCRIPT}" 2>/dev/null || true
  fi

  # ── Harvest Claude Code conversation log ─────────────────────
  # Claude Code saves structured JSONL at ~/.claude/projects/<proj>/<uuid>.jsonl
  # with full conversation: user messages, assistant responses (including
  # thinking), tool_use calls, and tool_results. This is the readable
  # session log — far superior to raw PTY capture.
  #
  # We copy (not symlink) the file so it's readable from the host and
  # other containers (e.g. Clem's file explorer). The background watcher
  # may have already been copying periodically — this is the final sync.
  CLAUDE_SESSION_ID=""
  if [[ "$AGENT" == "claude" && -d "$CLAUDE_PROJECTS_DIR" ]]; then
    # Try the source path saved by the background watcher first
    _CONV_SRC=""
    if [[ -f "${SESSION_DIR}/.conv_source" ]]; then
      _CONV_SRC=$(cat "${SESSION_DIR}/.conv_source" 2>/dev/null || true)
    fi

    # If watcher didn't find it, search now (covers cases where session
    # was too short for the watcher to catch it)
    if [[ -z "$_CONV_SRC" || ! -f "$_CONV_SRC" ]]; then
      CLAUDE_SESSIONS_AFTER=$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -name '*.jsonl' -newer "${EVENTS_FILE}" 2>/dev/null | sort || true)

      NEW_SESSION_FILES=""
      if [[ -n "$CLAUDE_SESSIONS_AFTER" ]]; then
        if [[ -n "$CLAUDE_SESSIONS_BEFORE" ]]; then
          NEW_SESSION_FILES=$(comm -13 <(echo "$CLAUDE_SESSIONS_BEFORE") <(echo "$CLAUDE_SESSIONS_AFTER") || true)
        else
          NEW_SESSION_FILES="$CLAUDE_SESSIONS_AFTER"
        fi
      fi

      if [[ -n "$NEW_SESSION_FILES" ]]; then
        _CONV_SRC=$(echo "$NEW_SESSION_FILES" | while read -r f; do
          echo "$(stat -c '%Y' "$f" 2>/dev/null || echo 0) $f"
        done | sort -rn | head -1 | cut -d' ' -f2-)
      fi
    fi

    # Final copy of conversation log
    if [[ -n "$_CONV_SRC" && -f "$_CONV_SRC" ]]; then
      cp -f "$_CONV_SRC" "${SESSION_DIR}/conversation.jsonl"
      chmod 644 "${SESSION_DIR}/conversation.jsonl" 2>/dev/null || true
      # Scrub secrets from the copied conversation log
      python3 /usr/local/bin/scrub-jsonl.py "${SESSION_DIR}/conversation.jsonl" 2>/dev/null || true
      CONV_LINES=$(wc -l < "${SESSION_DIR}/conversation.jsonl" 2>/dev/null || echo 0)
      CONV_SIZE=$(stat -c '%s' "${SESSION_DIR}/conversation.jsonl" 2>/dev/null || echo 0)
      echo "[session-logger] Copied conversation log: ${_CONV_SRC} (${CONV_LINES} messages, $(( CONV_SIZE / 1024 ))KB, scrubbed)"
      # Clean up source marker
      rm -f "${SESSION_DIR}/.conv_source"
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
  if [[ -f "${SESSION_DIR}/conversation.jsonl" ]]; then
    _end_args+=("has_conversation=true")

    # ── Token / cost tracking ──────────────────────────────────────
    # Parse the conversation log for token counts and estimated cost.
    # Uses the Python script for reliable JSON parsing + pricing math.
    COST_SCRIPT="$(dirname "$0")/token-cost.py"
    if [[ ! -x "$COST_SCRIPT" ]]; then
      COST_SCRIPT="/usr/local/bin/token-cost.py"
    fi
    if [[ -x "$COST_SCRIPT" || -f "$COST_SCRIPT" ]]; then
      _cost_json=$(python3 "$COST_SCRIPT" "${SESSION_DIR}/conversation.jsonl" 2>/dev/null || echo '{}')
      if [[ -n "$_cost_json" && "$_cost_json" != "{}" ]]; then
        # Extract fields and add to session_end args
        _input_tokens=$(echo "$_cost_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('input_tokens',0))" 2>/dev/null || echo 0)
        _output_tokens=$(echo "$_cost_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('output_tokens',0))" 2>/dev/null || echo 0)
        _total_tokens=$(echo "$_cost_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_tokens',0))" 2>/dev/null || echo 0)
        _cost_usd=$(echo "$_cost_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('estimated_cost_usd',0))" 2>/dev/null || echo 0)
        _turns=$(echo "$_cost_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('turns',0))" 2>/dev/null || echo 0)

        _end_args+=("input_tokens=${_input_tokens}")
        _end_args+=("output_tokens=${_output_tokens}")
        _end_args+=("total_tokens=${_total_tokens}")
        _end_args+=("estimated_cost_usd=${_cost_usd}")
        _end_args+=("turns=${_turns}")
        echo "[session-logger] Tokens: ${_input_tokens} in / ${_output_tokens} out (${_total_tokens} total) — \$${_cost_usd}"
      fi
    fi
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

# ── Early-copy conversation log ──────────────────────────────────
# Claude Code creates its conversation JSONL within seconds of starting.
# This background watcher finds it and copies it into the session dir
# so the log is readable from the host / other containers (symlinks
# would point inside this container and break on the host).
# After the initial copy, it re-syncs every 30s so external viewers
# (e.g. Clem file explorer) can see updates during long sessions.
_WATCHER_PID=""
_CONV_SOURCE=""   # set by watcher, read by cleanup for final copy
if [[ "$AGENT" == "claude" && -d "$CLAUDE_PROJECTS_DIR" ]]; then
  (
    # Poll up to 60s for a new conversation file to appear
    for _i in $(seq 1 30); do
      sleep 2
      _after=$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -name '*.jsonl' -newer "${EVENTS_FILE}" 2>/dev/null | sort || true)
      _new=""
      if [[ -n "$_after" ]]; then
        if [[ -n "$CLAUDE_SESSIONS_BEFORE" ]]; then
          _new=$(comm -13 <(echo "$CLAUDE_SESSIONS_BEFORE") <(echo "$_after") || true)
        else
          _new="$_after"
        fi
      fi
      if [[ -n "$_new" ]]; then
        # Pick most recently modified
        _latest=$(echo "$_new" | while read -r f; do
          echo "$(stat -c '%Y' "$f" 2>/dev/null || echo 0) $f"
        done | sort -rn | head -1 | cut -d' ' -f2-)
        if [[ -n "$_latest" && -f "$_latest" ]]; then
          cp -f "$_latest" "${SESSION_DIR}/conversation.jsonl"
          chmod 644 "${SESSION_DIR}/conversation.jsonl" 2>/dev/null || true
          python3 /usr/local/bin/scrub-jsonl.py "${SESSION_DIR}/conversation.jsonl" 2>/dev/null || true
          # Write source path so cleanup can do a final copy
          echo "$_latest" > "${SESSION_DIR}/.conv_source"
          echo "[session-logger] Copied conversation log: ${_latest} (scrubbed)"
          # Periodic re-sync while session is active
          while true; do
            sleep 30
            cp -f "$_latest" "${SESSION_DIR}/conversation.jsonl" 2>/dev/null || break
            chmod 644 "${SESSION_DIR}/conversation.jsonl" 2>/dev/null || true
            python3 /usr/local/bin/scrub-jsonl.py "${SESSION_DIR}/conversation.jsonl" 2>/dev/null || true
          done
        fi
        break
      fi
    done
  ) &
  _WATCHER_PID=$!
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
