# syntax=docker/dockerfile:1

FROM ghcr.io/astral-sh/uv:0.11.31 AS uv
FROM ghcr.io/zeroclaw-labs/zeroclaw:v0.8.3-debian AS zeroclaw

# ── Build zeroclaw from source with observability-otel ──────────
FROM rust:1.96-bookworm AS zeroclaw-builder
ARG ZEROCLAW_VERSION=v0.8.3
ARG ZEROCLAW_CARGO_FEATURES="acp-bridge,agent-runtime,channel-acp-server,channel-discord,channel-email,channel-filesystem,channel-webhook,gateway,observability-prometheus,observability-otel,schema-export"
RUN apt-get update && apt-get install -y --no-install-recommends \
      git pkg-config g++ \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN git clone --depth 1 --branch ${ZEROCLAW_VERSION} \
      https://github.com/zeroclaw-labs/zeroclaw.git .
ARG TARGETARCH
RUN --mount=type=cache,id=zeroclaw-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=zeroclaw-cargo-target-${TARGETARCH},target=/app/target,sharing=locked \
    cargo build --release --locked -p zeroclawlabs \
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

# Set up apt repos for Node.js, kubectl, and gh CLI, then install all packages in one layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
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
    kubectl \
    gh \
    nodejs \
    postgresql-client \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

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
RUN HELM_VERSION=v4.2.3 && \
    HELM_ARCHIVE="helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" && \
    curl -fsSL "https://get.helm.sh/${HELM_ARCHIVE}" -o "/tmp/${HELM_ARCHIVE}" && \
    curl -fsSL "https://get.helm.sh/${HELM_ARCHIVE}.sha256sum" -o /tmp/helm.sha256 && \
    (cd /tmp && sha256sum -c helm.sha256) && \
    tar -xz -C /tmp -f "/tmp/${HELM_ARCHIVE}" && \
    mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm && \
    rm -rf "/tmp/${HELM_ARCHIVE}" /tmp/helm.sha256 /tmp/linux-${TARGETARCH}

# Install yq (pinned version with checksum verification)
# SHA-256 is field 19 in the checksums file (filename + 31 hash types, SHA-256 is #18)
RUN YQ_VERSION=v4.53.3 && \
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
    curl -fsSL "https://github.com/neovim/neovim/releases/download/v0.12.4/${TARBALL}" \
        -o "/tmp/${TARBALL}" && \
    echo "${SHA256}  /tmp/${TARBALL}" | sha256sum -c && \
    tar -xz -C /tmp -f "/tmp/${TARBALL}" && \
    mv "/tmp/nvim-linux-${NVIM_ARCH}/bin/nvim" /usr/local/bin/nvim && \
    rm -rf "/tmp/${TARBALL}" "/tmp/nvim-linux-${NVIM_ARCH}"

# Install agent-browser binary (pinned version with checksum verification)
# Chrome for Testing is amd64-only; install system chromium on arm64
ARG AGENT_BROWSER_VERSION=v0.32.0
RUN case "${TARGETARCH}" in \
      amd64) BINARY="agent-browser-linux-x64" \
             SHA256="c8dd1344a0bdae8ebf76833a99eabe60afb0bfbd7f5e1dcdb589588e47f97c72" ;; \
      arm64) BINARY="agent-browser-linux-arm64" \
             SHA256="f3a4e48afcab95eada89c72c2004e98321ee74a896578d73e963d3131bd9531c" ;; \
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
