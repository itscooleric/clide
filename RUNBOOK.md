# clide Operational Runbook

Day-to-day operational reference for running and troubleshooting clide.

---

## Health checks

### Check if the web terminal is running
```bash
docker compose ps
```
Look for `web` with status `running (healthy)`. If status is `unhealthy`, check logs:
```bash
docker compose logs web
```

### Manually probe the web terminal endpoint
```bash
curl -f http://localhost:7681/
# Expect: HTTP 200 (or 401 if auth is enabled)
```

### Check container resource usage
```bash
# Docker stats (external)
docker stats clide-web-1

# clide metrics snapshot (from inside container or via docker exec)
docker compose exec web cat /workspace/.clide/metrics/current.json
```

---

## Starting and stopping

### Start the web terminal (background)
```bash
make web
# or
docker compose up -d web
```

### Stop the web terminal
```bash
docker compose down web
# or to stop all services:
docker compose down
```

### Restart the web terminal
```bash
docker compose restart web
```

---

## Logs

### Tail web terminal logs
```bash
make logs
# or
docker compose logs -f web
```

### View logs for CLI sessions
```bash
docker compose logs -f cli
```

### View recent logs without following
```bash
docker compose logs --tail=50 web
```

---

## Rebuilding

### Rebuild after a git pull (picks up Dockerfile changes)
```bash
git pull
docker compose build
docker compose up -d web
```

### Full rebuild (no cache — picks up new CLI versions)
```bash
docker compose build --no-cache
docker compose up -d web
```

### Reset everything (remove containers, volumes, orphans)
```bash
docker compose down -v --remove-orphans
docker compose build
```

---

## Credential rotation

### Rotate GitHub token (`GH_TOKEN`)
1. Generate a new fine-grained PAT at https://github.com/settings/personal-access-tokens/new with **"Copilot Requests"** permission.
2. Update `GH_TOKEN` in `.env`.
3. Restart the container — no rebuild required:
   ```bash
   docker compose down && docker compose up -d web
   ```

### Rotate Claude authentication
**Option A — Interactive (recommended):**
1. In a running container shell, run:
   ```bash
   claude /login
   ```
2. Follow the OAuth flow. Credentials persist in `/workspace/.clide/`.

**Option B — Headless via `.env`:**
1. On a machine with a browser, run `claude /login` and copy the token.
2. Update `CLAUDE_CODE_OAUTH_TOKEN` in `.env`.
3. Restart — no rebuild required.

### Rotate ttyd credentials (`TTYD_USER` / `TTYD_PASS`)
1. Update `TTYD_USER` and `TTYD_PASS` in `.env`.
2. Restart the web service:
   ```bash
   docker compose restart web
   ```

---

## Firewall troubleshooting

### Check if the firewall is active
```bash
docker compose exec web iptables -L OUTPUT -n --line-numbers
```
If you see `REJECT` rules, the firewall is active. If you get a permission error, the container may be running without `NET_ADMIN`.

### Check firewall startup logs
```bash
docker compose logs web | grep firewall
```
- `firewall: egress allowlist active` — firewall is running normally
- `firewall: WARNING - cannot access iptables` — `NET_ADMIN` capability missing; egress is unrestricted
- `firewall: disabled (CLIDE_FIREWALL=0)` — firewall was explicitly disabled

### Allow an additional host
Add it to `.env` and restart — no rebuild required:
```env
CLIDE_ALLOWED_HOSTS=pypi.org,files.pythonhosted.org
```
```bash
docker compose restart web
```

### Temporarily disable the firewall
```env
# .env
CLIDE_FIREWALL=0
```
```bash
docker compose restart web
```
Remember to remove `CLIDE_FIREWALL=0` once done.

---

## Web terminal troubleshooting

### Browser shows connection refused
1. Check the container is running: `docker compose ps`
2. Check the port matches `.env`: default is `7681`
3. Check logs: `docker compose logs web`

### Browser shows 401 Unauthorized
- Web terminal authentication is required. Set one of: `TTYD_USER`+`TTYD_PASS`, `TTYD_AUTH_PROXY=true`, or `TTYD_NO_AUTH=true`.
- If you intentionally want no auth: set `TTYD_NO_AUTH=true` in `.env`.

### Session disappeared / tmux session lost
The web terminal always attaches to a named tmux session (`main`). If the container restarted, the session is gone. Refresh the browser to start a new one.

### ttyd crashed / web terminal unresponsive
ttyd auto-restarts with exponential backoff (max 5 rapid restarts). Check logs:
```bash
docker compose logs web | grep "ttyd:"
```
If you see "FATAL — crashed 5 times", the underlying issue needs investigation. Common causes: port conflict, OOM kill, corrupted tmux socket.

### Claude prompts for setup on every run
The entrypoint pre-seeds `~/.claude.json` to suppress first-run prompts. If they keep appearing:
```bash
docker compose down -v
docker compose build --no-cache
make cli
```

---

## Running against a different project

```bash
PROJECT_DIR=/path/to/your/repo make cli
# or
PROJECT_DIR=/path/to/your/repo docker compose run --rm cli
```

---

## Interpreting Docker health states

| Status | Meaning |
|---|---|
| `starting` | Container is within the `--start-period` (10s); health not yet evaluated |
| `healthy` | ttyd responded to the HTTP probe |
| `unhealthy` | ttyd failed to respond 3 times in a row — check logs |
| `none` | HEALTHCHECK not configured (shouldn't happen with current Dockerfile) |

To inspect health detail:
```bash
docker inspect clide-web-1 --format='{{json .State.Health}}' | jq
```
