#!/bin/bash
# Egress firewall for clide — configures an iptables allowlist at container startup.
#
# Environment variables:
#   CLIDE_FIREWALL=0       Disable the firewall entirely (restores unrestricted egress)
#   CLIDE_ALLOWED_HOSTS    Comma- or newline-separated list of extra allowed hostnames

# ── Opt-out ───────────────────────────────────────────────────────────────────
if [[ "${CLIDE_FIREWALL:-1}" == "0" ]]; then
  echo "firewall: disabled (CLIDE_FIREWALL=0)"
  if [[ $# -gt 0 ]]; then exec gosu clide "$@"; fi
  exit 0
fi

# ── Sanity checks ─────────────────────────────────────────────────────────────
if ! command -v iptables >/dev/null 2>&1; then
  echo "firewall: WARNING - iptables not found, skipping egress filter"
  if [[ $# -gt 0 ]]; then exec gosu clide "$@"; fi
  exit 0
fi

if ! iptables -L OUTPUT -n >/dev/null 2>&1; then
  echo "firewall: WARNING - cannot access iptables (missing NET_ADMIN capability)"
  echo "firewall: add 'cap_add: [NET_ADMIN]' to your docker-compose.yml to enable the firewall"
  if [[ $# -gt 0 ]]; then exec gosu clide "$@"; fi
  exit 0
fi

echo "firewall: configuring egress allowlist..."

# ── Baseline allowed hosts ────────────────────────────────────────────────────
BASELINE_HOSTS=(
  "api.anthropic.com"       # Claude Code
  "api.githubcopilot.com"   # GitHub Copilot CLI
  "api.github.com"          # GitHub Copilot CLI + GitHub CLI
  "github.com"              # GitHub CLI
  "registry.npmjs.org"      # npm package updates (optional)
  "api.openai.com"          # Codex CLI (OpenAI)
  "auth.openai.com"         # Codex CLI — device code auth flow
)

# ── Helpers ───────────────────────────────────────────────────────────────────
_ipt()  { iptables  "$@" 2>/dev/null || true; }
_ip6()  { ip6tables "$@" 2>/dev/null || true; }

_allow_host() {
  local host="$1"
  local ips
  # NOTE: IPs are resolved once at startup. If a host's IPs change after the
  # container starts (CDN rotation, failover, etc.) the container must be
  # restarted to pick up the new addresses.
  ips=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u)
  if [[ -z "$ips" ]]; then
    echo "firewall: WARNING - could not resolve '$host', skipping"
    return
  fi
  while IFS= read -r ip; do
    if [[ "$ip" == *:* ]]; then
      _ip6 -A OUTPUT -d "$ip" -j ACCEPT
    else
      _ipt -A OUTPUT -d "$ip" -j ACCEPT
    fi
    echo "firewall: allow $host ($ip)"
  done <<< "$ips"
}

# ── Build OUTPUT chain rules ──────────────────────────────────────────────────

# 1. Always allow loopback
_ipt -A OUTPUT -o lo -j ACCEPT
_ip6 -A OUTPUT -o lo -j ACCEPT

# 2. Allow packets belonging to already-established connections.
# This rule is placed early for efficiency; the firewall is configured before
# any services start so no unexpected connections exist at this point.
_ipt -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
_ip6 -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 3. Allow DNS (required to resolve hostnames below)
_ipt -A OUTPUT -p udp --dport 53 -j ACCEPT
_ipt -A OUTPUT -p tcp --dport 53 -j ACCEPT
_ip6 -A OUTPUT -p udp --dport 53 -j ACCEPT
_ip6 -A OUTPUT -p tcp --dport 53 -j ACCEPT

# 4. Allow baseline service endpoints
for host in "${BASELINE_HOSTS[@]}"; do
  _allow_host "$host"
done

# 5. Allow any user-supplied extra hosts (comma- or newline-separated)
if [[ -n "${CLIDE_ALLOWED_HOSTS:-}" ]]; then
  normalized="${CLIDE_ALLOWED_HOSTS//,/$'\n'}"
  while IFS= read -r host; do
    host="${host//[[:space:]]/}"
    [[ -z "$host" ]] && continue
    _allow_host "$host"
  done <<< "$normalized"
fi

# 6. Reject all other outbound traffic (REJECT gives immediate feedback vs DROP's timeout)
_ipt -A OUTPUT -j REJECT --reject-with icmp-port-unreachable
_ip6 -A OUTPUT -j REJECT

echo "firewall: egress allowlist active — all other outbound traffic rejected"

# ── If used as entrypoint, drop to unprivileged user and exec the command ────
# iptables rules are now in place; gosu drops root before the workload starts.
if [[ $# -gt 0 ]]; then
  exec gosu clide "$@"
fi
