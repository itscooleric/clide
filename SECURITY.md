# clide Security & Threat Model

This document describes the trust boundaries, attack surface, known threats, and mitigations for clide.

---

## Trust boundaries

```text
┌─────────────────────────────────────────────────────┐
│  Host Machine                                        │
│                                                      │
│  .env (secrets)  ──────────────────────────────┐    │
│  Project directory ─────────────────────────┐  │    │
│                                             │  │    │
│  ┌──────────────────────────────────────────▼──▼─┐  │
│  │  clide Container                               │  │
│  │  User: clide (uid=1000, non-root)              │  │
│  │                                                │  │
│  │  ┌──────────────────────────────────────────┐  │  │
│  │  │  firewall.sh (iptables egress allowlist) │  │  │
│  │  └──────────────────────────────────────────┘  │  │
│  │                          │                     │  │
│  │              (allowlisted endpoints only)       │  │
│  └──────────────────────────│────────────────────┘  │
│                             │                        │
└─────────────────────────────│────────────────────────┘
                              ▼
                    Internet (restricted)
                    api.anthropic.com
                    api.githubcopilot.com
                    api.github.com / github.com
                    registry.npmjs.org
```

### What the host trusts the container with
- **Read-write access to your project directory** — mounted at `/workspace`. The container can read, write, and delete files in this directory.
- **API credentials** — `GH_TOKEN`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, and `OPENAI_API_KEY` are passed in via `.env` and available as environment variables inside the container.
- **Network access** — restricted to the egress allowlist by default.

### What the container does NOT have
- Access to the rest of the host filesystem (only `/workspace` is mounted)
- Root privileges during normal operation (gosu drops to `clide` uid=1000 before any workload starts)
- Unrestricted internet access (egress firewall allowlist — when `NET_ADMIN` is available)
- Access to other containers or host services beyond what Docker networking exposes

---

## Attack surface

### Web terminal (ttyd)
- **Exposure:** ttyd binds to `0.0.0.0:7681` by default, exposing a full shell over HTTP.
- **Risk:** Anyone who can reach that port gets an interactive shell as `clide` with access to your project files and API credentials.
- **Mitigations:**
  - Basic auth enforced by default (`TTYD_USER` + `TTYD_PASS` required; container refuses to start without them unless `TTYD_NO_AUTH=true` is explicitly set)
  - Bind to `127.0.0.1` only if not using a reverse proxy (set `TTYD_PORT=127.0.0.1:7681` in `.env`)
  - Use a TLS-terminating reverse proxy (e.g. Caddy) in production — see `DEPLOY.md`

### Mounted workspace
- **Exposure:** The container has read-write access to everything under `PROJECT_DIR` (default: parent directory of the clide repo).
- **Risk:** A compromised or misbehaving AI agent could modify, delete, or exfiltrate source code and committed secrets.
- **Mitigations:**
  - Use git to track changes; review diffs before committing
  - Point `PROJECT_DIR` at a specific repo rather than a broad parent directory
  - The egress firewall limits where data can be sent

### API credentials in environment
- **Exposure:** Tokens (`GH_TOKEN`, `ANTHROPIC_API_KEY`, etc.) are present as environment variables inside the container.
- **Risk:** A process running inside the container can read and exfiltrate these tokens.
- **Mitigations:**
  - Egress firewall restricts outbound traffic to known endpoints — a stolen token can't easily be sent to an attacker's server
  - Use fine-grained PATs with minimal permissions (e.g. `GH_TOKEN` only needs "Copilot Requests")
  - Rotate tokens regularly; set expiry dates on PATs

### Egress / network
- **Exposure:** Containers can make outbound network requests.
- **Risk:** An AI agent could exfiltrate data, download malicious payloads, or establish reverse shells.
- **Mitigations:**
  - iptables egress allowlist restricts outbound to known good endpoints
  - `REJECT` (not `DROP`) so connection failures are immediate and visible
  - DNS is allowed (required for hostname resolution) — a motivated attacker could use DNS tunneling; this is a known limitation of IP-based egress filtering

### Container privilege
- **Exposure:** The entrypoint must start as root to apply iptables rules.
- **Risk:** A vulnerability in the startup scripts could allow privilege retention.
- **Mitigations:**
  - `gosu clide` is called before any user-facing workload; the process tree runs as uid=1000
  - `cap_drop: ALL` + `cap_add: NET_ADMIN` — only the firewall capability is retained, dropped after use
  - `no-new-privileges: true` — prevents setuid escalation
  - `pids_limit`, `mem_limit`, `cpus` — resource guardrails against runaway processes

---

## Threat scenarios

| Threat | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Unauthenticated web terminal access | Medium (if exposed on network) | High (full shell) | Basic auth required by default; use reverse proxy + TLS |
| AI agent exfiltrates source code | Low | High | Egress firewall limits destinations; review agent output |
| AI agent deletes project files | Low | Medium | Use git; review before committing |
| API token theft via network | Low | Medium | Egress firewall; token scoping; rotation |
| Container escape to host | Very Low | High | Non-root user; minimal capabilities; no privileged mode |
| Malicious dependency in npm install | Low | Medium | Pin versions (#7); review `package.json` |
| DNS tunneling for data exfiltration | Very Low | Low | Known limitation of IP-based egress filtering |

---

## Deployment hardening recommendations

For production or shared deployments (e.g. Bernard/Forge):

1. **Always use TLS** — put clide behind Caddy or another TLS-terminating proxy. Never expose ttyd directly over HTTP on a public network.
2. **Enable basic auth** — set `TTYD_USER` and `TTYD_PASS` in `.env`. Do not use `TTYD_NO_AUTH=true` in production.
3. **Scope `PROJECT_DIR`** — mount only the specific repo you're working on, not a broad parent directory.
4. **Use minimal-permission tokens** — create fine-grained PATs with only the permissions each CLI needs.
5. **Set token expiry** — don't create non-expiring tokens. Rotate on a schedule.
6. **Review egress** — if you need to add hosts to `CLIDE_ALLOWED_HOSTS`, understand why before adding them.
7. **Monitor logs** — `docker compose logs -f web` will show firewall warnings and auth events.

---

## Reporting security issues

Please report security vulnerabilities privately to the repository owner rather than opening a public issue.
