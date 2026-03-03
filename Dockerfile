FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies (curl only — no wget)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (official apt repo)
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.x LTS (pinned major; avoids surprise LTS jumps)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install ttyd 1.7.7 for web terminal access (pinned — avoid /latest/ surprises)
RUN curl -fsSL https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.$(uname -m) \
    -o /usr/local/bin/ttyd \
    && chmod +x /usr/local/bin/ttyd

# Install Claude Code CLI (unpinned — tracks new features intentionally)
RUN npm install -g @anthropic-ai/claude-code

# Install GitHub Copilot CLI (unpinned — tracks gh extension updates)
RUN curl -fsSL https://gh.io/copilot-install | bash

# Add entrypoint script for web terminal
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Auth env vars:
#   GH_TOKEN      — GitHub fine-grained PAT with "Copilot Requests" permission
#   ANTHROPIC_API_KEY — Anthropic API key for Claude Code

WORKDIR /workspace

# Default to bash shell (can be overridden by command in docker-compose)
CMD ["/bin/bash"]
