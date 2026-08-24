# syntax=docker/dockerfile:1

FROM ghcr.io/astral-sh/uv:0.12.5 AS uv
FROM ghcr.io/zeroclaw-labs/zeroclaw:v0.8.4-debian AS zeroclaw

# ── Build zeroclaw from source with observability-otel ──────────
FROM rust:1.98-bookworm AS zeroclaw-builder
ARG ZEROCLAW_VERSION=v0.8.4
ARG ZEROCLAW_CARGO_FEATURES="acp-bridge,agent-runtime,channel-acp-server,channel-discord,channel-email,channel-filesystem,channel-webhook,gateway,observability-prometheus,observability-otel,schema-export"
RUN apt-get update && apt-get install -y --no-install-recommends \
      git pkg-config g++ \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN git clone --depth 1 --branch ${ZEROCLAW_VERSION} \
      https://github.com/zeroclaw-labs/zeroclaw.git .
RUN cargo build --release --locked -p zeroclawlabs \
      --no-default-features \
      --features "${ZEROCLAW_CARGO_FEATURES}" \
    && cp target/release/zeroclaw /app/zeroclaw \
    && strip /app/zeroclaw

# ── Runtime stage: the shipped image ────────────────────────────
FROM zeroclaw
ARG TARGETARCH

# Validate TARGETARCH
RUN case "${TARGETARCH}" in \
      amd64|arm64) echo "Building for ${TARGETARCH}" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac

USER root

# Set up apt repos for kubectl and gh CLI, then install all packages in one layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
       | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
     && echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' \
       > /etc/apt/sources.list.d/kubernetes.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    bash \
    coreutils \
    curl \
    wget \
    git \
    gnupg \
    jq \
    gettext-base \
    imagemagick \
    openssl \
    openssh-client \
    pandoc \
    pass \
    poppler-utils \
    ripgrep \
    tesseract-ocr \
    tesseract-ocr-eng \
    unzip \
    bzip2 \
    dnsutils \
    ffmpeg \
    kubectl \
    gh \
    postgresql-client \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (pinned version with checksum verification)
# NodeSource's apt repo is signed with a SHA1-based key that current apt
# rejects ("provides only weak security information"), so install from the
# official nodejs.org tarball instead — same pattern as helm/yq/restic/neovim.
RUN NODE_VERSION=v24.18.0 && \
    case "${TARGETARCH}" in \
      amd64) NODE_ARCH="linux-x64" ;; \
      arm64) NODE_ARCH="linux-arm64" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    TARBALL="node-${NODE_VERSION}-${NODE_ARCH}.tar.gz" && \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/${TARBALL}" -o "/tmp/${TARBALL}" && \
    NODE_SHA256=$(curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt" \
        | grep " ${TARBALL}\$" | awk '{print $1}') && \
    echo "${NODE_SHA256}  /tmp/${TARBALL}" | sha256sum -c && \
    tar -xzf "/tmp/${TARBALL}" -C /usr/local --strip-components=1 && \
    rm -f "/tmp/${TARBALL}" && \
    node --version && npm --version

# Install MCP server packages used by homelab cron jobs (pinned exactly).
# Bumping these is an explicit, reviewable change — the homelab runtime
# patchers (holdms / captcha) are tested against these specific versions.
# Installed globally so they live on the read-only rootfs at
# /usr/local/lib/node_modules, avoiding the noexec-tmpfs npx-cache problem
# where execve() on the resolved .bin symlinks failed with EPERM.
RUN npm install -g --no-audit --no-fund \
        camofox-mcp@1.15.0 \
        @perplexity-ai/mcp-server@1.2.0 \
    && rm -rf /root/.npm

# Pre-bake the homelab camofox-mcp patches into the image so the runtime
# mirror dance (setup-pass.sh cp -r + two node invocations) can go away.
# The patchers are idempotent source-text substitutions tuned to
# camofox-mcp@1.15.0; the && chain fails the build loudly if upstream's
# dist/ refactors break the regex anchors (each patcher exits 1 on anchor
# mismatch). Cleanup drops the patch source from the image. Run as root
# (still in the USER root block) so the global install is writable.
COPY containers/patches/camofox-mcp/ /tmp/camofox-mcp-patches/
RUN node /tmp/camofox-mcp-patches/patch-holdms.js \
 && node /tmp/camofox-mcp-patches/patch-captcha.js \
 && rm -rf /tmp/camofox-mcp-patches \
 && echo "camofox-mcp patched; verify:" \
 && head -n1 /usr/local/lib/node_modules/camofox-mcp/dist/tools/interaction.js \
 && grep -c registerPressHoldCaptchaTool /usr/local/lib/node_modules/camofox-mcp/dist/server.js

# Make global node_modules resolvable via bare require (e.g.
# `node -e "require('camofox-mcp/package.json')"`).
ENV NODE_PATH=/usr/local/lib/node_modules

# Install uv and uvx
COPY --from=uv /uv /uvx /bin/

ENV UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_TOOL_BIN_DIR=/usr/local/bin

# Install latest Python globally
RUN uv python install --preview --default 3.14

# Install Python-based tools
RUN uv tool install trash-cli

# Install helm (pinned version with checksum verification)
RUN HELM_VERSION=v4.2.4 && \
    HELM_ARCHIVE="helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" && \
    curl -fsSL "https://get.helm.sh/${HELM_ARCHIVE}" -o "/tmp/${HELM_ARCHIVE}" && \
    curl -fsSL "https://get.helm.sh/${HELM_ARCHIVE}.sha256sum" -o /tmp/helm.sha256 && \
    (cd /tmp && sha256sum -c helm.sha256) && \
    tar -xz -C /tmp -f "/tmp/${HELM_ARCHIVE}" && \
    mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm && \
    rm -rf "/tmp/${HELM_ARCHIVE}" /tmp/helm.sha256 /tmp/linux-${TARGETARCH}

# Install yq (pinned version with checksum verification)
# SHA-256 is field 19 in the checksums file (filename + 31 hash types, SHA-256 is #18)
RUN YQ_VERSION=v4.53.6 && \
    YQ_BINARY="yq_linux_${TARGETARCH}" && \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -o /tmp/yq && \
    YQ_SHA256=$(curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums" \
        | grep "^${YQ_BINARY} " | awk '{print $19}') && \
    echo "${YQ_SHA256}  /tmp/yq" | sha256sum -c && \
    mv /tmp/yq /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Install restic (pinned version with checksum verification)
RUN RESTIC_VERSION=0.19.1 && \
    RESTIC_ARCHIVE="restic_${RESTIC_VERSION}_linux_${TARGETARCH}.bz2" && \
    curl -fsSL "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/${RESTIC_ARCHIVE}" \
        -o "/tmp/${RESTIC_ARCHIVE}" && \
    RESTIC_SHA256=$(curl -fsSL "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/SHA256SUMS" \
        | grep "${RESTIC_ARCHIVE}$" | awk '{print $1}') && \
    echo "${RESTIC_SHA256}  /tmp/${RESTIC_ARCHIVE}" | sha256sum -c && \
    bzip2 -d "/tmp/${RESTIC_ARCHIVE}" && \
    mv "/tmp/restic_${RESTIC_VERSION}_linux_${TARGETARCH}" /usr/local/bin/restic && \
    chmod +x /usr/local/bin/restic

# Install neovim (pinned version with checksum verification)
RUN case "${TARGETARCH}" in \
      amd64) NVIM_ARCH="x86_64" \
             SHA256="012bf3fcac5ade43914df3f174668bf64d05e049a4f032a388c027b1ebd78628" ;; \
      arm64) NVIM_ARCH="arm64" \
             SHA256="ceb7e88c6b681f0515d135dcdfad54f5eb4373b25ce6172197cd9a69c758063f" ;; \
    esac && \
    TARBALL="nvim-linux-${NVIM_ARCH}.tar.gz" && \
    curl -fsSL "https://github.com/neovim/neovim/releases/download/v0.12.5/${TARBALL}" \
        -o "/tmp/${TARBALL}" && \
    echo "${SHA256}  /tmp/${TARBALL}" | sha256sum -c && \
    tar -xz -C /tmp -f "/tmp/${TARBALL}" && \
    mv "/tmp/nvim-linux-${NVIM_ARCH}/bin/nvim" /usr/local/bin/nvim && \
    rm -rf "/tmp/${TARBALL}" "/tmp/nvim-linux-${NVIM_ARCH}"

# Install agent-browser binary (pinned version with checksum verification)
# Chrome for Testing is amd64-only; install system chromium on arm64
ARG AGENT_BROWSER_VERSION=v0.34.0
RUN case "${TARGETARCH}" in \
      amd64) BINARY="agent-browser-linux-x64" \
             SHA256="69eadf5d8d6003a06a5cd2f914ebb261c7754fe1335a9190122c334e91909789" ;; \
      arm64) BINARY="agent-browser-linux-arm64" \
             SHA256="ca70bf7c2d269a152b3824cbb65befb7b8258b8aa1cf34767c64ada2abc3d7c8" ;; \
    esac && \
    curl -fsSL "https://github.com/vercel-labs/agent-browser/releases/download/${AGENT_BROWSER_VERSION}/${BINARY}" \
        -o /usr/local/bin/agent-browser && \
    echo "${SHA256}  /usr/local/bin/agent-browser" | sha256sum -c && \
    chmod +x /usr/local/bin/agent-browser && \
    case "${TARGETARCH}" in \
      amd64) apt-get update && apt-get install -y --no-install-recommends \
              libxcb-shm0 libx11-xcb1 libx11-6 libxcb1 libxext6 libxrandr2 \
              libxcomposite1 libxcursor1 libxdamage1 libxfixes3 libxi6 \
              libgtk-3-0 libpangocairo-1.0-0 libpango-1.0-0 libatk1.0-0 \
              libcairo-gobject2 libcairo2 libgdk-pixbuf-2.0-0 libxrender1 \
              libasound2 libfreetype6 libfontconfig1 libdbus-1-3 libnss3 \
              libnspr4 libatk-bridge2.0-0 libdrm2 libxkbcommon0 libatspi2.0-0 \
              libcups2 libxshmfence1 libgbm1 fonts-noto-color-emoji \
              fonts-noto-cjk fonts-freefont-ttf \
             && rm -rf /var/lib/apt/lists/* \
             && agent-browser install ;; \
      arm64) apt-get update && apt-get install -y --no-install-recommends chromium \
             && rm -rf /var/lib/apt/lists/* ;; \
    esac

# Overwrite the pre-built zeroclaw binary with the OTel-enabled build
COPY --chmod=755 --from=zeroclaw-builder /app/zeroclaw /usr/local/bin/zeroclaw

# Create non-root agent user and fix ownership
RUN adduser --disabled-password --gecos "" --uid 1000 agent && \
    mkdir -p /home/agent/workspace && \
    chown -R agent:agent /home/agent

ENV ZEROCLAW_WORKSPACE=/home/agent/workspace \
    HOME=/home/agent \
    ZEROCLAW_GATEWAY_PORT=3000

EXPOSE 3000
USER agent
WORKDIR /home/agent/workspace

ENTRYPOINT ["zeroclaw"]
CMD ["daemon"]
