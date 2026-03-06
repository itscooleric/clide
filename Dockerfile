FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies (curl only — no wget)
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    gnupg \
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

# Install Claude Code CLI (unpinned — tracks new features intentionally)
# hadolint ignore=DL3016
RUN npm install -g @anthropic-ai/claude-code

# Create unprivileged user and set up workspace
RUN useradd -m -s /bin/bash -u 1000 clide \
    && mkdir -p /workspace \
    && chown clide:clide /workspace

# Add entrypoint scripts
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY claude-entrypoint.sh /usr/local/bin/claude-entrypoint.sh
COPY firewall.sh /usr/local/bin/firewall.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-entrypoint.sh /usr/local/bin/firewall.sh

# tmux config — mouse support, sane splits, 256-colour
COPY --chown=clide:clide .tmux.conf /home/clide/.tmux.conf

# Switch to unprivileged user for user-scoped installs
USER clide

# Install GitHub Copilot CLI (unpinned — tracks gh extension updates)
RUN curl -fsSL https://gh.io/copilot-install | bash

# Auth env vars:
#   GH_TOKEN      — GitHub fine-grained PAT with "Copilot Requests" permission
#   ANTHROPIC_API_KEY — Anthropic API key for Claude Code

WORKDIR /workspace

# Default to bash shell (can be overridden by command in docker-compose)
CMD ["/bin/bash"]
