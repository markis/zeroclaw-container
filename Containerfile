# syntax=docker/dockerfile:1

FROM ghcr.io/astral-sh/uv:0.6.14 AS uv
FROM ghcr.io/zeroclaw-labs/zeroclaw:v0.6.9-debian AS zeroclaw

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
    && curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
       | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    && echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' \
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
    jq \
    gettext-base \
    imagemagick \
    openssl \
    openssh-client \
    pandoc \
    poppler-utils \
    ripgrep \
    tesseract-ocr \
    tesseract-ocr-eng \
    unzip \
    bzip2 \
    dnsutils \
    kubectl \
    gh \
    && apt-get purge -y gnupg && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Install uv and uvx
COPY --from=uv /uv /uvx /bin/

ENV UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_TOOL_BIN_DIR=/usr/local/bin

# Install latest Python globally
RUN uv python install --preview --default 3.13

# Install Python-based tools
RUN uv tool install trash-cli

# Install helm (pinned version with checksum verification)
RUN HELM_VERSION=v4.1.4 && \
    HELM_ARCHIVE="helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" && \
    curl -fsSL "https://get.helm.sh/${HELM_ARCHIVE}" -o "/tmp/${HELM_ARCHIVE}" && \
    curl -fsSL "https://get.helm.sh/${HELM_ARCHIVE}.sha256sum" -o /tmp/helm.sha256 && \
    (cd /tmp && sha256sum -c helm.sha256) && \
    tar -xz -C /tmp -f "/tmp/${HELM_ARCHIVE}" && \
    mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm && \
    rm -rf "/tmp/${HELM_ARCHIVE}" /tmp/helm.sha256 /tmp/linux-${TARGETARCH}

# Install yq (pinned version with checksum verification)
# SHA-256 is field 19 in the checksums file (filename + 31 hash types, SHA-256 is #18)
RUN YQ_VERSION=v4.52.5 && \
    YQ_BINARY="yq_linux_${TARGETARCH}" && \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -o /tmp/yq && \
    YQ_SHA256=$(curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums" \
        | grep "^${YQ_BINARY} " | awk '{print $19}') && \
    echo "${YQ_SHA256}  /tmp/yq" | sha256sum -c && \
    mv /tmp/yq /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Install restic (pinned version with checksum verification)
RUN RESTIC_VERSION=0.18.1 && \
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
             SHA256="ab757a1fd9ad307d53d2df4045698906a7ca3993d92260dd8fe49108712d57d0" ;; \
      arm64) NVIM_ARCH="arm64" \
             SHA256="a3f8aa5590fd2ac930bcc5c9070b9ac1ec33461d262b6428874c5fc640f3f13c" ;; \
    esac && \
    TARBALL="nvim-linux-${NVIM_ARCH}.tar.gz" && \
    curl -fsSL "https://github.com/neovim/neovim/releases/download/v0.12.1/${TARBALL}" \
        -o "/tmp/${TARBALL}" && \
    echo "${SHA256}  /tmp/${TARBALL}" | sha256sum -c && \
    tar -xz -C /tmp -f "/tmp/${TARBALL}" && \
    mv "/tmp/nvim-linux-${NVIM_ARCH}/bin/nvim" /usr/local/bin/nvim && \
    rm -rf "/tmp/${TARBALL}" "/tmp/nvim-linux-${NVIM_ARCH}"

# Install agent-browser binary (pinned version with checksum verification)
# Chrome for Testing is amd64-only; install system chromium on arm64
ARG AGENT_BROWSER_VERSION=v0.25.4
RUN case "${TARGETARCH}" in \
      amd64) BINARY="agent-browser-linux-x64" \
             SHA256="02d26f105a9d8e203f8f966acfeb4bab191cfa4625431a535b8be5f8f5905472" ;; \
      arm64) BINARY="agent-browser-linux-arm64" \
             SHA256="f44b037cf208e1c5771ad498983f5674aca2b65da5c1b2f440aba901f3ddf536" ;; \
    esac && \
    curl -fsSL "https://github.com/vercel-labs/agent-browser/releases/download/${AGENT_BROWSER_VERSION}/${BINARY}" \
        -o /usr/local/bin/agent-browser && \
    echo "${SHA256}  /usr/local/bin/agent-browser" | sha256sum -c && \
    chmod +x /usr/local/bin/agent-browser && \
    case "${TARGETARCH}" in \
      amd64) agent-browser install --with-deps ;; \
      arm64) apt-get update && apt-get install -y --no-install-recommends chromium \
             && rm -rf /var/lib/apt/lists/* ;; \
    esac

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
