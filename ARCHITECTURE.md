# Architecture

## Overview

Clide is a sandboxed agentic terminal — a Docker container that bundles Claude Code, GitHub Copilot CLI, Codex, and standard dev tools into a single, firewall-restricted environment. It provides a controlled workspace where AI coding agents can operate on your project with network access limited to approved API endpoints.

## System Design

```
┌─────────────────────────────────────────────┐
│                 Host Machine                 │
│                                             │
│   /your/project ──bind mount──► /workspace  │
│   .env secrets  ──env vars───► container    │
│                                             │
│  ┌───────────────────────────────────────┐  │
│  │           Clide Container             │  │
│  │                                       │  │
│  │  ┌─────────┐ ┌──────────┐ ┌───────┐  │  │
│  │  │ Claude  │ │ Copilot  │ │ Codex │  │  │
│  │  │  Code   │ │   CLI    │ │       │  │  │
│  │  └────┬────┘ └────┬─────┘ └───┬───┘  │  │
│  │       │           │           │       │  │
│  │  ┌────┴───────────┴───────────┴───┐   │  │
│  │  │        tmux + bash + gh        │   │  │
│  │  └────────────┬───────────────────┘   │  │
│  │               │                       │  │
│  │  ┌────────────┴───────────────────┐   │  │
│  │  │    ttyd (web terminal :7681)   │   │  │
│  │  └────────────┬───────────────────┘   │  │
│  │               │                       │  │
│  │  ┌────────────┴───────────────────┐   │  │
│  │  │   firewall.sh (iptables)       │   │  │
│  │  │   egress allowlist only        │   │  │
│  │  └────────────────────────────────┘   │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

## Key Components

### Container (`Dockerfile`)
- Base: Python 3.12 slim
- Installs: Claude Code, GitHub Copilot CLI, GitHub CLI, Codex, tmux, ttyd
- Runs as non-root user with configurable UID/GID
- Workspace bind-mounted at `/workspace`

### Firewall (`firewall.sh`)
- iptables-based egress allowlist
- Only approved API endpoints can be reached:
  - `api.anthropic.com` (Claude)
  - `api.githubcopilot.com` (Copilot)
  - `api.github.com` (GitHub)
  - `api.openai.com` (Codex)
- Everything else is rejected
- Prevents data exfiltration and unauthorized network access

### Web Terminal (`ttyd`)
- Browser-accessible terminal at port 7681
- Wraps tmux for persistent sessions
- Allows remote access to the agent workspace

### Entry Points
- `entrypoint.sh` — main container startup (firewall + tmux + ttyd)
- `claude-entrypoint.sh` — Claude Code specific initialization
- `clide` — CLI wrapper script for common operations

## Deployment

### Single Host
```bash
docker compose up -d
```
Mounts your project at `/workspace`, injects API keys from `.env`.

### With Caddy Reverse Proxy
See `DEPLOY.md` for Caddy integration via `docker-compose.override.yml`.

### Multi-Host (Production)
In production, Clide containers run on multiple hosts (`bernard`, `forge-mesa`, VPS nodes) with:
- [Clidesdale](https://github.com/itscooleric/clidesdale) for VPS provisioning
- [Clidestable](https://github.com/itscooleric/clidestable) for VPS-side session management
- Tailscale mesh networking between hosts
- Caddy for TLS termination

## Security Model

1. **Network isolation**: Egress allowlist prevents unauthorized outbound connections
2. **Filesystem isolation**: Only `/workspace` is writable; container filesystem is ephemeral
3. **Credential isolation**: API keys passed via environment variables, never baked into images
4. **No root**: Container runs as unprivileged user

## Related Projects

| Project | Role |
|---------|------|
| [clidesdale](https://github.com/itscooleric/clidesdale) | VPS provisioning CLI — "give your AI agent a VPS" |
| [clidestable](https://github.com/itscooleric/clidestable) | VPS-side session management |
| [yap](https://github.com/itscooleric/yap) | Local-first speech I/O stack |
