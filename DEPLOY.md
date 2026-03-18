# Deployment Guide

## Local Development

### Quick start
1. Copy `.env.example` to `.env` and add credentials
2. `docker compose build`
3. `./clide web` or `make web`
4. Open http://localhost:7681

### Two services

| Service | What | Command |
|---------|------|---------|
| `web` | Browser terminal (ttyd + tmux) | `docker compose up -d web` |
| `cli` | Headless shell (all CLIs available) | `docker compose run --rm cli` |

All CLIs (claude, copilot, codex, gh, glab) are available from either — just type the command.

---

## Server Deployment (Caddy Docker Proxy)

Applies to Bernard, forge-edge, or any host running caddy-docker-proxy.

### Prerequisites
- Caddy Docker Proxy running on a `caddy` Docker network
- DNS or Tailscale MagicDNS for the hostname

### Step 1: Clone and configure
```bash
cd /opt/stacks/clide
git clone https://github.com/itscooleric/clide .
cp .env.example .env
nano .env
```

Required `.env` settings:
```env
GH_TOKEN=your_github_pat_here
CLAUDE_CODE_OAUTH_TOKEN=your_oauth_token   # or ANTHROPIC_API_KEY

# Auth via Caddy reverse proxy (required for iOS/mobile — see below)
TTYD_AUTH_PROXY=true

# ttyd credentials (used as fallback when NOT behind Caddy)
TTYD_USER=admin
TTYD_PASS=changeme
```

### Step 2: Create the Caddy override
```bash
cp docker-compose.override.yml.example docker-compose.override.yml
nano docker-compose.override.yml
```

Generate a password hash and update the override:
```bash
docker exec caddy caddy hash-password --plaintext 'yourpassword'
```

Example override:
```yaml
services:
  web:
    networks:
      - default
      - caddy
    labels: !override
      caddy: "http://clide.lan.wubi.sh:80"
      caddy.basic_auth: "*"
      caddy.basic_auth.admin: "$$2a$$14$$YOUR_HASH_HERE"
      caddy.reverse_proxy: "{{upstreams 7681}}"
      caddy.reverse_proxy.header_up: "X-Auth-User {http.auth.user.id}"

networks:
  caddy:
    external: true
```

> **Important:** Double `$$` in the hash — Docker Compose interpolates `$` signs.
> Use `!override` on labels to fully replace the base (otherwise base labels merge in).

### Step 3: Ensure caddy network exists
```bash
docker network ls | grep -E '\bcaddy\b' || docker network create caddy
```

### Step 4: Build and start
```bash
docker compose build
docker compose up -d web
docker compose logs -f web
```

### Step 5: Validate
```bash
# Without auth — should return 401
curl -s -o /dev/null -w '%{http_code}' http://clide.lan.wubi.sh/

# With auth — should return 200
curl -s -o /dev/null -w '%{http_code}' -u admin:yourpassword http://clide.lan.wubi.sh/
```

---

## Authentication

### Caddy basic auth (recommended)
Auth handled by Caddy reverse proxy. **Required for iOS/mobile** — ttyd's built-in
basic auth is broken on all WebKit browsers (Safari, Chrome on iOS, etc.) due to
Apple's NSURLSession WebSocket implementation (ttyd upstream #1437).

Setup: see [Server Deployment](#server-deployment-caddy-docker-proxy) above.

### ttyd basic auth (fallback)
Built-in auth for local/desktop use without Caddy. Add to `.env`:
```env
TTYD_USER=admin
TTYD_PASS=changeme
```

> **Warning:** Broken on iOS/Safari. Use Caddy auth proxy for mobile access.

### No auth
Only safe behind VPN/firewall:
```env
TTYD_NO_AUTH=true
```

---

## Usage

```bash
# Web terminal
./clide web           # or: make web, docker compose up -d web

# Headless shell
./clide cli           # or: make cli, docker compose run --rm cli

# Custom project directory
PROJECT_DIR=/path/to/repo docker compose up -d web
```

---

## Troubleshooting

### 502 Bad Gateway from Caddy
1. Container not on `caddy` network — check `docker-compose.override.yml`
2. ttyd not listening — check `docker compose logs web`
3. Wrong port — reverse_proxy should target 7681

```bash
docker inspect clide-web-1 --format '{{json .NetworkSettings.Networks}}'
docker compose logs web | tail -20
```

### 407 Proxy Authentication Required (direct port access)
Expected when `TTYD_AUTH_PROXY=true` — ttyd requires the `X-Auth-User` header
that only Caddy provides. Access through Caddy instead of the direct port.

### "Press Enter to Reconnect" on mobile
You're hitting ttyd directly (port 7681) instead of through Caddy.
Use the Caddy URL (e.g. `http://clide.lan.wubi.sh`).

### Claude keeps showing first-run setup prompts
```bash
docker compose down -v
docker compose build --no-cache
docker compose up -d web
```

---

## Backup

**What to backup:**
- `/opt/stacks/clide/.env` — tokens and config
- `/opt/stacks/clide/docker-compose.override.yml` — Caddy labels + host-specific config

**Restore:**
1. Restore files to same paths
2. `docker compose up -d web`

---

## Security Notes

- Default setup is **LAN/VPN-only**
- ttyd has `--writable` enabled (allows terminal input)
- **Always enable authentication** — Caddy basic auth (mobile-compatible) or ttyd basic auth (desktop only)
- Credentials stored in `.env` and `docker-compose.override.yml` (both gitignored)
- Egress firewall restricts outbound traffic to allowlisted API endpoints
