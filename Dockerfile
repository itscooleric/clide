FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies (curl only — no wget)
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    gnupg \
    gosu \
    iptables \
    tmux \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (official apt repo)
# hadolint ignore=DL3008
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.x LTS (pinned major; avoids surprise LTS jumps)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install ttyd 1.7.7 for web terminal access (pinned — avoid /latest/ surprises)
RUN ARCH="$(uname -m)" \
    && curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${ARCH}" \
       -o /usr/local/bin/ttyd \
    && chmod +x /usr/local/bin/ttyd

# Install Codex CLI (pinned — bump ARG to upgrade)
# hadolint ignore=DL3059
ARG CODEX_VERSION=0.112.0
RUN npm install -g "@openai/codex@${CODEX_VERSION}"

# Install glab (GitLab CLI) — pinned version, single binary
ARG GLAB_VERSION=1.47.0
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${ARCH}.deb" \
       -o /tmp/glab.deb \
    && dpkg -i /tmp/glab.deb \
    && rm /tmp/glab.deb

# Install Python 3 + dev tooling into an isolated venv
# - python3-venv provides the venv module (not always bundled in minimal images)
# - /opt/pyenv is owned by clide so the agent can pip-install workspace project
#   dependencies on demand (e.g. pip install -r /workspace/clem/requirements.txt)
#   without a container rebuild. pytest + ruff are pre-installed as a baseline.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/pyenv \
    && /opt/pyenv/bin/pip install --no-cache-dir \
       pytest==9.0.2 \
       ruff==0.15.5

ENV PATH="/home/clide/.local/bin:/opt/pyenv/bin:${PATH}"

# Create unprivileged user and set up workspace
# UID/GID default to 1000 (standard first non-root user on Linux/macOS).
# Override at build time:  CLIDE_UID=$(id -u) CLIDE_GID=$(id -g) docker compose build
ARG CLIDE_UID=1000
ARG CLIDE_GID=1000
RUN groupadd -g "${CLIDE_GID}" clide 2>/dev/null || groupmod -n clide "$(getent group "${CLIDE_GID}" | cut -d: -f1)" \
    && useradd -m -l -s /bin/bash -u "${CLIDE_UID}" -g clide clide \
    && mkdir -p /workspace \
    && chown clide:clide /workspace \
    # Hand venv ownership to clide so pip install works without sudo
    && chown -R clide:clide /opt/pyenv

# Add entrypoint scripts
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY claude-entrypoint.sh /usr/local/bin/claude-entrypoint.sh
COPY firewall.sh /usr/local/bin/firewall.sh
COPY scripts/session-logger.sh /usr/local/bin/session-logger.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-entrypoint.sh /usr/local/bin/firewall.sh /usr/local/bin/session-logger.sh

# Default CLAUDE.md template — seeded into /workspace on first run if none exists
COPY CLAUDE.md.template /usr/local/share/clide/CLAUDE.md.template

# tmux config — mouse support, sane splits, 256-colour
COPY --chown=clide:clide .tmux.conf /home/clide/.tmux.conf

# Switch to unprivileged user for user-scoped installs
USER clide

# Install Claude Code CLI via native installer (self-updating, no npm dependency).
# Installs to ~/.local/bin/claude — auto-updates at runtime without sudo.
RUN curl -fsSL https://claude.ai/install.sh | sh

# Trust all directories for git operations.
# Clide is a single-user dev sandbox — volume-mounted repos from the host
# are often owned by a different UID (host user vs clide:1000), which causes
# git to refuse to operate and wastes tokens on `git config --global
# --add safe.directory ...` at the start of every session.
# Set safe.directory=* once at image build time to eliminate this entirely.
# See: https://git-scm.com/docs/git-config#Documentation/git-config.txt-safedirectory
RUN git config --global --add safe.directory '*'

# Install GitHub Copilot CLI (unpinned — tracks gh extension updates)
RUN curl -fsSL https://gh.io/copilot-install | bash

# Auth env vars:
#   GH_TOKEN      — GitHub fine-grained PAT with "Copilot Requests" permission
#   ANTHROPIC_API_KEY — Anthropic API key for Claude Code

# Switch back to root so entrypoints start as root; privilege drop to clide
# is handled by gosu inside each entrypoint script after firewall setup.
# hadolint ignore=DL3002
USER root

WORKDIR /workspace

# Health check — confirms the web terminal is accepting connections.
# Port is validated as numeric to prevent injection; base path is respected.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD sh -c 'PORT="${TTYD_PORT:-7681}"; case "$PORT" in (""|*[!0-9]*) PORT=7681 ;; esac; curl -f "http://localhost:${PORT}${TTYD_BASE_PATH:-/}" || exit 1'

# Default to bash shell (can be overridden by command in docker-compose)
CMD ["/bin/bash"]
