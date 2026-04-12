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
RUN uv python install --default 3.13

# Install Node.js LTS (v22) with checksum verification
ARG NODE_VERSION=22.14.0
RUN case "${TARGETARCH}" in \
      amd64) NODE_ARCH="x64" ;; \
      arm64) NODE_ARCH="arm64" ;; \
    esac && \
    TARBALL="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" && \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${TARBALL}" && \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
        | grep "${TARBALL}" | sha256sum -c - && \
    tar -xJf "${TARBALL}" --strip-components=1 -C /usr/local \
        --exclude "*/include" --exclude "*/share" && \
    rm "${TARBALL}"

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

# Install agent-browser and Chrome for Testing with system dependencies
RUN npm install -g agent-browser && \
    agent-browser install --with-deps

# Create non-root agent user and fix ownership
RUN adduser --disabled-password --gecos "" --uid 1000 agent && \
    mkdir -p /home/agent/workspace && \
    chown -R agent:agent /home/agent

ENV NULLCLAW_WORKSPACE=/home/agent/workspace \
    NULLCLAW_HOME=/home/agent \
    HOME=/home/agent \
    NULLCLAW_GATEWAY_PORT=3000

EXPOSE 3000
USER agent
WORKDIR /home/agent/workspace

ENTRYPOINT ["nullclaw"]
CMD ["gateway"]
