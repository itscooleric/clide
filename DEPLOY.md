# Deployment Guide

## Local Development (IDE)

### Quick start
1. Copy `.env.example` to `.env` and add your `GH_TOKEN`
2. Run **Build copilot-cli image** task
3. Run **Start web terminal (ttyd)** task
4. Open http://localhost:7681 in your browser

### Available tasks
- **Build copilot-cli image** — build the Docker image
- **Run copilot (default project)** — run GitHub Copilot CLI
- **Run GitHub CLI (gh)** — run GitHub CLI with custom args
- **Run Claude Code** — run Claude Code CLI
- **Open interactive shell (all CLIs)** — bash with all CLIs available
- **Start web terminal (ttyd)** — web-based terminal at http://localhost:7681
- **Stop web terminal** — stop the web terminal service

---

## Bernard/Forge Deployment (Caddy Docker Proxy)

### Prerequisites
- Caddy Docker Proxy running
- External Docker network `caddy` exists
- DNS record: `clide.lan.wubi.sh` → Bernard LAN IP

### Step 1: Create directories
```bash
SERVICE="clide"
sudo mkdir -p "/opt/stacks/$SERVICE"
sudo mkdir -p "/srv/$SERVICE/projects"
sudo chown -R "$USER":"$USER" "/opt/stacks/$SERVICE" "/srv/$SERVICE"
```

### Step 2: Clone/copy files
```bash
cd /opt/stacks/clide
# Copy Dockerfile, docker-compose.yml, and .env here
```

### Step 3: Configure `.env`
```bash
cd /opt/stacks/clide
cp .env.example .env
nano .env
```

Update:
```env
GH_TOKEN=your_github_pat_here

# Optional: Set default project directory
PROJECT_DIR=/srv/clide/projects/default

# Caddy proxy settings (hostname for labels)
CADDY_HOSTNAME=clide.lan.wubi.sh
CADDY_TLS=internal
```

### Step 3b: Enable Caddy proxy mode
```bash
cp docker-compose.override.yml.example docker-compose.override.yml
```

This override file (gitignored) will:
- Add the `web` service to the `caddy` network
- Remove port exposure (Caddy proxies directly to container)

### Step 4: Ensure external network exists
```bash
docker network ls | grep -E '\bcaddy\b' || docker network create caddy
```

### Step 5: Build and start
```bash
cd /opt/stacks/clide
docker compose build
docker compose up -d web
docker logs -n 50 clide-web-1
```

### Step 6: Validate
From a LAN/VPN client:
```bash
curl -Ik https://clide.lan.wubi.sh
```

Should return `200 OK`. Access the web terminal at:
- **https://clide.lan.wubi.sh**

---

## Usage Patterns

### Local development (port mode)
```bash
docker compose up -d web
# Access at http://localhost:7681
```

### Bernard deployment (proxy mode)
- Copy `docker-compose.override.yml.example` to `docker-compose.override.yml`
- Access at `https://clide.lan.wubi.sh`
- No port exposure needed (override removes it)

### Run CLIs directly (no web UI)
```bash
# Interactive shell
docker compose run --rm shell

# Specific CLI
docker compose run --rm copilot
docker compose run --rm gh repo view
docker compose run --rm claude
```

### Custom project directory
```bash
PROJECT_DIR=/path/to/specific/repo docker compose up -d web
# Or set PROJECT_DIR in .env
```

---

## Authentication

Two layers of authentication are available. Use either or both.

### ttyd basic auth (built-in)
Protects the web terminal directly. Works in both local and proxy mode.

Add to `.env`:
```env
TTYD_USER=admin
TTYD_PASS=changeme
```

The browser will prompt for credentials before opening the terminal. If unset, ttyd runs without auth (a warning is printed on startup).

### Caddy basicauth (proxy layer)
Protects the web terminal at the reverse proxy level. Only applies in Caddy proxy mode.

1. Generate a bcrypt password hash:
   ```bash
   docker run --rm caddy:latest caddy hash-password --plaintext 'yourpassword'
   ```

2. Add to `.env`:
   ```env
   CADDY_BASICAUTH_USER=admin
   CADDY_BASICAUTH_HASH=$2a$14$xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   ```

3. In `docker-compose.override.yml`, uncomment the `labels` block with the `caddy.basicauth` entries.

Both auth methods are configured via `.env` (gitignored) so credentials are never committed.

---

## Troubleshooting

### 502 Bad Gateway from Caddy
**Most common causes:**
1. Wrong port in reverse_proxy (should be 7681)
2. Container not on `caddy` network (check that `docker-compose.override.yml` exists)
3. ttyd not listening (check logs)

**Quick checks:**
```bash
docker inspect clide-web-1 --format '{{json .NetworkSettings.Networks}}'
docker logs -n 100 clide-web-1
docker exec -it clide-web-1 ss -tulpn | grep 7681
```

### ttyd works locally but not via hostname
- Verify DNS: `clide.lan.wubi.sh` resolves to Bernard IP
- Check Caddy logs: `docker logs caddy-proxy`
- Verify labels: `docker inspect clide-web-1 --format '{{json .Config.Labels}}'`

### Permission errors on project directory
```bash
sudo chown -R $USER:$USER /srv/clide/projects
```

---

## Backup

**What to backup:**
- `/opt/stacks/clide/.env` — tokens and config
- `/opt/stacks/clide/docker-compose.yml` — service definition
- `/srv/clide/projects/` — your project files (if stored here)

**Restore:**
1. Restore files to same paths
2. `docker compose up -d web`

---

## Security Notes

- Default setup is **LAN/VPN-only** (`*.lan.wubi.sh`)
- ttyd has `--writable` enabled (allows file editing in terminal)
- **Enable authentication** (see [Authentication](#authentication)) — ttyd basic auth and/or Caddy basicauth
- GitHub tokens are passed via environment variables (secure for Docker)
- Web terminal has full access to all CLIs and mounted projects
- All auth credentials are stored in `.env` (gitignored)
