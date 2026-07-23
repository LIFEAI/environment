# GitHub Actions Self-Hosted Runner
# Pre-built with Node 20 + pnpm for regen-root monorepo CI
#
# Build: docker build -t lifeai/github-runner:latest .
# (Or let Coolify build it from the docker-compose context)

FROM ubuntu:22.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# --- System dependencies ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    jq \
    unzip \
    sudo \
    libicu70 \
    libssl3 \
    liblttng-ust1 \
    libkrb5-3 \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

# --- Node.js 20 (LTS) via NodeSource ---
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- pnpm (corepack) ---
RUN corepack enable && corepack prepare pnpm@latest --activate

# --- GitHub Actions Runner ---
# Pin to a known stable version; bump as needed
ARG RUNNER_VERSION=2.334.0
ARG RUNNER_ARCH=x64

RUN mkdir -p /home/runner/actions-runner \
    && cd /home/runner/actions-runner \
    && curl -fsSL -o runner.tar.gz \
       "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
    && tar xzf runner.tar.gz \
    && rm runner.tar.gz \
    && ./bin/installdependencies.sh || true

# --- Runner user (GitHub recommends non-root) ---
RUN useradd -m -d /home/runner -s /bin/bash runner \
    && chown -R runner:runner /home/runner/actions-runner

# --- Work directory + cache dirs (must be owned by runner, not root) ---
RUN mkdir -p /home/runner/work \
    && mkdir -p /home/runner/.cache/node/corepack \
    && mkdir -p /home/runner/.local/share/corepack \
    && chown -R runner:runner /home/runner/work \
    && chown -R runner:runner /home/runner/.cache \
    && chown -R runner:runner /home/runner/.local

# --- pnpm store pre-warm directory ---
# The actual store will be populated on first build and persisted via volume
RUN mkdir -p /home/runner/.local/share/pnpm/store \
    && chown -R runner:runner /home/runner/.local/share/pnpm

# --- Entrypoint script ---
COPY entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

USER runner
WORKDIR /home/runner/actions-runner

ENTRYPOINT ["/home/runner/entrypoint.sh"]
