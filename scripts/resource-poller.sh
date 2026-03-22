#!/bin/bash
# resource-poller.sh — Container resource monitoring (#45, #46, #48)
#
# Polls /proc + cgroup data and ttyd connections every POLL_INTERVAL seconds.
# Writes:
#   $CLIDE_METRICS_DIR/current.json  — latest snapshot (for Clem consumption)
#   $CLIDE_METRICS_DIR/metrics.jsonl — append-only time series
#
# Environment:
#   CLIDE_METRICS_DIR      — output directory (default: /workspace/.clide/metrics)
#   CLIDE_POLL_INTERVAL    — poll interval in seconds (default: 30)
#   CLIDE_METRICS_DISABLED — set to 1 to disable
#   TTYD_PORT              — ttyd port to monitor (default: 7681)

set -euo pipefail

METRICS_DIR="${CLIDE_METRICS_DIR:-/workspace/.clide/metrics}"
POLL_INTERVAL="${CLIDE_POLL_INTERVAL:-30}"
TTYD_PORT="${TTYD_PORT:-7681}"

if [[ "${CLIDE_METRICS_DISABLED:-}" == "1" ]]; then
  exit 0
fi

mkdir -p "${METRICS_DIR}"

# ── CPU tracking state ───────────────────────────────────────────
PREV_CPU_TOTAL=0
PREV_CPU_IDLE=0

read_cpu() {
  # Read cgroup v2 cpu stats if available, fall back to /proc/stat
  local cgroup_cpu="/sys/fs/cgroup/cpu.stat"
  if [[ -f "$cgroup_cpu" ]]; then
    # cgroup v2: usage_usec is cumulative microseconds
    local usage_usec
    usage_usec=$(awk '/^usage_usec/ {print $2}' "$cgroup_cpu" 2>/dev/null || echo 0)
    echo "$usage_usec"
    return
  fi

  # Fall back to /proc/stat (container-wide, less accurate in cgroup context)
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  echo "${total} ${idle}"
}

calc_cpu_percent() {
  local cgroup_cpu="/sys/fs/cgroup/cpu.stat"
  if [[ -f "$cgroup_cpu" ]]; then
    local usage_usec
    usage_usec=$(awk '/^usage_usec/ {print $2}' "$cgroup_cpu" 2>/dev/null || echo 0)
    if [[ $PREV_CPU_TOTAL -gt 0 ]]; then
      local delta=$((usage_usec - PREV_CPU_TOTAL))
      # Convert microseconds delta to percentage of wall-clock interval
      local interval_usec=$((POLL_INTERVAL * 1000000))
      if [[ $interval_usec -gt 0 ]]; then
        echo "$delta $interval_usec" | awk '{printf "%.1f", ($1 / $2) * 100}'
      else
        echo "0.0"
      fi
    else
      echo "0.0"
    fi
    PREV_CPU_TOTAL=$usage_usec
    return
  fi

  # /proc/stat fallback
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  if [[ $PREV_CPU_TOTAL -gt 0 ]]; then
    local d_total=$((total - PREV_CPU_TOTAL))
    local d_idle=$((idle - PREV_CPU_IDLE))
    if [[ $d_total -gt 0 ]]; then
      echo "$d_total $d_idle" | awk '{printf "%.1f", (($1 - $2) / $1) * 100}'
    else
      echo "0.0"
    fi
  else
    echo "0.0"
  fi
  PREV_CPU_TOTAL=$total
  PREV_CPU_IDLE=$idle
}

read_memory() {
  # cgroup v2 memory
  local cgroup_mem="/sys/fs/cgroup/memory.current"
  local cgroup_limit="/sys/fs/cgroup/memory.max"
  if [[ -f "$cgroup_mem" ]]; then
    local current limit
    current=$(cat "$cgroup_mem" 2>/dev/null || echo 0)
    limit=$(cat "$cgroup_limit" 2>/dev/null || echo "max")
    local used_mb=$((current / 1024 / 1024))
    local limit_mb="null"
    if [[ "$limit" != "max" ]]; then
      limit_mb=$((limit / 1024 / 1024))
    fi
    echo "${used_mb} ${limit_mb}"
    return
  fi

  # Fall back to /proc/meminfo
  local mem_total mem_avail
  mem_total=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  mem_avail=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
  local used_mb=$((mem_total - mem_avail))
  echo "${used_mb} ${mem_total}"
}

read_pids() {
  # cgroup v2 pids
  local cgroup_pids="/sys/fs/cgroup/pids.current"
  if [[ -f "$cgroup_pids" ]]; then
    cat "$cgroup_pids" 2>/dev/null || echo 0
    return
  fi
  # Fallback: count /proc/[0-9]* directories
  ls -1d /proc/[0-9]* 2>/dev/null | wc -l
}

read_fds() {
  # Count open file descriptors for the whole cgroup / container
  ls /proc/self/fd 2>/dev/null | wc -l
}

read_zombies() {
  awk '$3 == "Z" {count++} END {print count+0}' /proc/[0-9]*/stat 2>/dev/null || echo 0
}

read_uptime() {
  awk '{printf "%.0f", $1}' /proc/uptime
}

# ── ttyd connection tracking (#46) ───────────────────────────────

PREV_CONNECTIONS=""

count_ttyd_connections() {
  # Count established TCP connections to the ttyd port
  if command -v ss >/dev/null 2>&1; then
    ss -tn state established "( sport = :${TTYD_PORT} )" 2>/dev/null | tail -n +2 | wc -l
  else
    echo 0
  fi
}

list_ttyd_connections() {
  if command -v ss >/dev/null 2>&1; then
    ss -tn state established "( sport = :${TTYD_PORT} )" 2>/dev/null | tail -n +2 | awk '{print $4}' | sort
  fi
}

emit_session_events() {
  local current_conns="$1"
  local events_file="${METRICS_DIR}/session_events.jsonl"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Detect new connections (opens)
  if [[ -n "$current_conns" ]]; then
    while IFS= read -r conn; do
      if [[ -n "$conn" ]] && ! echo "$PREV_CONNECTIONS" | grep -qF "$conn"; then
        printf '{"event":"session_open","ts":"%s","remote_addr":"%s"}\n' "$ts" "$conn" >> "$events_file"
      fi
    done <<< "$current_conns"
  fi

  # Detect closed connections
  if [[ -n "$PREV_CONNECTIONS" ]]; then
    while IFS= read -r conn; do
      if [[ -n "$conn" ]] && ! echo "$current_conns" | grep -qF "$conn"; then
        printf '{"event":"session_close","ts":"%s","remote_addr":"%s"}\n' "$ts" "$conn" >> "$events_file"
      fi
    done <<< "$PREV_CONNECTIONS"
  fi

  PREV_CONNECTIONS="$current_conns"
}

# ── Main loop ────────────────────────────────────────────────────

echo "[resource-poller] Starting (interval=${POLL_INTERVAL}s, dir=${METRICS_DIR})"

# Initial CPU read to seed delta calculation
calc_cpu_percent > /dev/null
sleep "$POLL_INTERVAL"

while true; do
  cpu_pct=$(calc_cpu_percent)
  read -r mem_used_mb mem_limit_mb <<< "$(read_memory)"
  pid_count=$(read_pids)
  fd_count=$(read_fds)
  zombie_count=$(read_zombies)
  uptime_secs=$(read_uptime)
  ttyd_conns=$(count_ttyd_connections)
  ttyd_conn_list=$(list_ttyd_connections)
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Emit ttyd session open/close events (#46)
  emit_session_events "$ttyd_conn_list"

  # Write current.json (#48) — atomic via temp file + mv
  tmp="${METRICS_DIR}/.current.json.tmp"
  cat > "$tmp" <<ENDJSON
{
  "ts": "${ts}",
  "uptime_seconds": ${uptime_secs},
  "cpu_percent": ${cpu_pct},
  "mem_used_mb": ${mem_used_mb},
  "mem_limit_mb": ${mem_limit_mb},
  "pids": ${pid_count},
  "open_fds": ${fd_count},
  "zombies": ${zombie_count},
  "ttyd_connections": ${ttyd_conns}
}
ENDJSON
  mv -f "$tmp" "${METRICS_DIR}/current.json"

  # Append to metrics.jsonl (#45)
  printf '{"ts":"%s","cpu_pct":%s,"mem_used_mb":%s,"mem_limit_mb":%s,"pids":%s,"fds":%s,"zombies":%s,"ttyd_conns":%s}\n' \
    "$ts" "$cpu_pct" "$mem_used_mb" "$mem_limit_mb" "$pid_count" "$fd_count" "$zombie_count" "$ttyd_conns" \
    >> "${METRICS_DIR}/metrics.jsonl"

  sleep "$POLL_INTERVAL"
done
