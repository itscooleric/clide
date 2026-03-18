#!/bin/bash
# egress-audit.sh — log outbound connections to JSONL
#
# Monitors /proc/net/tcp for new outbound connections and logs them
# as structured JSONL events. Runs as a background daemon inside the
# clide container alongside the agent session.
#
# Output: $CLIDE_LOG_DIR/egress.jsonl (or /workspace/.clide/logs/egress.jsonl)
#
# Environment:
#   CLIDE_EGRESS_AUDIT=1     Enable (default: disabled)
#   CLIDE_EGRESS_INTERVAL=5  Poll interval in seconds (default: 5)
#   CLIDE_LOG_DIR            Log directory (default: /workspace/.clide/logs)

set -euo pipefail

if [[ "${CLIDE_EGRESS_AUDIT:-0}" != "1" ]]; then
  exit 0
fi

# Prefer per-session dir if available, fall back to global log dir
LOG_DIR="${CLIDE_SESSION_DIR:-${CLIDE_LOG_DIR:-/workspace/.clide/logs}}"
LOG_FILE="${LOG_DIR}/egress.jsonl"
INTERVAL="${CLIDE_EGRESS_INTERVAL:-5}"
SEEN_FILE="/tmp/.egress-seen"

mkdir -p "$LOG_DIR"
touch "$SEEN_FILE"

echo "[egress-audit] Monitoring outbound connections (interval=${INTERVAL}s, log=${LOG_FILE})"

# Resolve IP to hostname (best-effort, cached)
declare -A _dns_cache
resolve_ip() {
  local ip="$1"
  if [[ -n "${_dns_cache[$ip]:-}" ]]; then
    echo "${_dns_cache[$ip]}"
    return
  fi
  local host
  host=$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' || echo "")
  if [[ -z "$host" ]]; then
    host="$ip"
  fi
  _dns_cache[$ip]="$host"
  echo "$host"
}

# Convert hex IP:port from /proc/net/tcp to readable format
hex_to_ip() {
  local hex="$1"
  local ip_hex="${hex%%:*}"
  local port_hex="${hex##*:}"
  # Little-endian hex to dotted decimal
  printf "%d.%d.%d.%d" \
    "0x${ip_hex:6:2}" "0x${ip_hex:4:2}" \
    "0x${ip_hex:2:2}" "0x${ip_hex:0:2}"
}

hex_to_port() {
  local hex="$1"
  local port_hex="${hex##*:}"
  printf "%d" "0x${port_hex}"
}

while true; do
  # Parse /proc/net/tcp for ESTABLISHED connections (state 01)
  while IFS= read -r line; do
    # Skip header
    [[ "$line" == *"local_address"* ]] && continue

    local_addr=$(echo "$line" | awk '{print $2}')
    remote_addr=$(echo "$line" | awk '{print $3}')
    state=$(echo "$line" | awk '{print $4}')
    uid=$(echo "$line" | awk '{print $8}')

    # Only ESTABLISHED (01) connections
    [[ "$state" != "01" ]] && continue

    remote_ip=$(hex_to_ip "$remote_addr")
    remote_port=$(hex_to_port "$remote_addr")
    local_port=$(hex_to_port "$local_addr")

    # Skip loopback, private/Docker networks (only log public egress)
    [[ "$remote_ip" == "127."* ]] && continue
    [[ "$remote_ip" == "172."* ]] && continue
    [[ "$remote_ip" == "10."* ]] && continue
    [[ "$remote_ip" == "192.168."* ]] && continue
    [[ "$remote_ip" == "0.0.0.0" ]] && continue

    # Unique key for dedup
    conn_key="${remote_ip}:${remote_port}:${local_port}"
    if grep -qF "$conn_key" "$SEEN_FILE" 2>/dev/null; then
      continue
    fi
    echo "$conn_key" >> "$SEEN_FILE"

    # Resolve hostname
    remote_host=$(resolve_ip "$remote_ip")

    # Determine if this was allowed or would have been rejected
    # (All ESTABLISHED connections were allowed by iptables)
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Write JSONL event
    python3 -c "
import json
event = {
    'event': 'egress_connection',
    'ts': '$ts',
    'remote_ip': '$remote_ip',
    'remote_host': '$remote_host',
    'remote_port': $remote_port,
    'local_port': $local_port,
    'uid': $uid,
    'verdict': 'allow',
}
print(json.dumps(event))
" >> "$LOG_FILE"

    echo "[egress-audit] $remote_host ($remote_ip):$remote_port ← :$local_port [allow]"

  done < /proc/net/tcp

  sleep "$INTERVAL"
done
