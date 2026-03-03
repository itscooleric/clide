# Clyde (clide) Review & Recommendations

This is a practical review of the current containerized CLI toolkit with recommendations focused on:

1. Documentation completeness
2. Capability gaps
3. Security controls
4. Memory/context strategy while staying lightweight

## 1) Documentation: what is good and what is missing

### What is already strong
- README gives a quick setup path, includes multiple run modes, and explains env vars for auth.  
- DEPLOY guide covers local and Caddy-proxied deployment, including troubleshooting and backup notes.  

### Gaps worth filling (high-value, low-overhead)
1. **Add a compatibility/support matrix**
   - Minimum Docker/Compose versions
   - Host OS caveats (Linux/macOS/Windows bind-mount behavior)
   - ARM vs x86 notes for ttyd binary retrieval

2. **Add explicit threat model + trust boundaries**
   - Clarify that web terminal users can run arbitrary shell commands with mounted workspace access
   - Clarify whether this is intended for personal-only use, LAN team use, or internet exposure behind SSO

3. **Document token scope recommendations**
   - Show least-privilege GH PAT scopes and rotation guidance
   - Mention that tokens should be long-lived only when necessary

4. **Add “operational runbook” snippets**
   - Health checks (`docker compose ps`, log checks)
   - Upgrade path and rollback procedure
   - Known failure modes with quick fixes

5. **Add an architecture diagram (one image is enough)**
   - Browser → Caddy(optional) → ttyd → shell → CLIs (gh/copilot/claude)

## 2) Capability gaps: biggest opportunities

### Likely biggest gap: provider breadth and interchangeable agent backends
Current focus is GitHub + Anthropic CLIs in one image. That’s useful, but a larger capability jump is a **pluggable agent runner model** where each provider is optional and consistently invoked.

### Concrete additions to consider
1. **Add OpenAI Codex CLI (optional profile/service)**
   - Keep base image small by making this opt-in (`docker compose --profile codex ...`)
   - Use dedicated env vars (e.g., `OPENAI_API_KEY`) and isolate auth docs per provider

2. **Create a unified wrapper command set**
   - `./clide ask --provider copilot|claude|codex "prompt"`
   - This reduces operator cognitive load and makes scripting easier

3. **Project-local policy hooks**
   - Optional command prefix wrappers (e.g., preflight checks before invoking any AI CLI)
   - Useful for team standards and safe defaults

4. **Non-interactive automation mode**
   - Add examples for CI-style usage with mounted repo + command output artifacting

## 3) Security: easiest hardening wins

### Fast wins (do these first)
1. **Disable unauthenticated ttyd by default**
   - Today auth is optional; safer default is requiring credentials unless explicitly disabled

2. **Run container as non-root user**
   - Create an unprivileged user in Dockerfile and use `USER`
   - Keep only required file permissions writable

3. **Add resource limits in compose**
   - Memory/CPU/pids limits to reduce blast radius

4. **Harden container runtime settings**
   - `read_only: true` where possible
   - `cap_drop: ["ALL"]`
   - `security_opt: ["no-new-privileges:true"]`
   - `tmpfs` for writable runtime paths if needed

5. **Pin dependencies/versions where feasible**
   - Reduce supply-chain drift from “latest” installers

### On IP allow/block lists specifically
- **Inbound allowlist**: yes, useful at proxy layer (Caddy/Traefik/Nginx, firewall, VPN ACLs). Prefer this over app-level ad-hoc filtering.
- **Outbound allowlist**: very valuable but slightly more effort. Best done with host firewall/eBPF policy or container network policy tooling.
- Practical default: restrict service exposure to LAN/VPN + proxy auth + optional IP allowlist at proxy/firewall.

### Additional controls teams often use
- SSO/OIDC at reverse proxy
- Audit logs of terminal access and command sessions
- Short-lived credentials from a secret manager (instead of static PATs)
- Separate “read-only” and “writable” deployment modes

## 4) Memory/context strategy (lightweight-first)

You can keep this clean without building a heavy memory subsystem.

### Recommended model
1. **Three-tier context policy**
   - Tier 0: current working files + immediate shell output
   - Tier 1: project-local `README` / `docs` snippets loaded on demand
   - Tier 2 (optional): compact persistent notes in a small file (`.clide/context.md`)

2. **Token budget guardrails**
   - Hard cap per request and summarize-before-append behavior
   - Avoid accumulating full transcripts; keep rolling summaries

3. **Skill-like extensions as thin adapters**
   - Add “skills” as markdown instructions + tiny scripts, not a big framework
   - Keep each skill isolated and opt-in

4. **Context hygiene automation**
   - `./clide context trim` command to prune old notes
   - `./clide context show` to inspect exactly what is being fed to agent CLIs

## Suggested phased roadmap

### Phase 1 (1–2 sessions)
- Add docs: threat model, support matrix, token scope guidance, runbook
- Make ttyd auth default-on
- Add non-root user + basic runtime hardening

### Phase 2 (next)
- Add optional Codex provider profile/service
- Introduce unified wrapper command (`ask` with provider switch)
- Add basic audit logging guidance

### Phase 3 (if needed)
- Add outbound policy controls and stricter egress
- Optional OIDC/SSO at proxy
- Optional compact persistent context store

## Bottom line
- The foundation is good and intentionally lightweight.
- The biggest immediate wins are **security defaults** and **provider pluggability**.
- You can add memory/skills safely by keeping them **small, inspectable, and opt-in**.
