# zeroclaw-container

A container image extending the [zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) base with additional DevOps and automation tooling.

Published to `ghcr.io/markis/zeroclaw-container`.

## Included Tools

| Tool | Version |
|------|---------|
| kubectl | v1.32 (stable) |
| gh (GitHub CLI) | stable |
| helm | v4.1.4 |
| yq | v4.52.5 |
| trash-cli | latest (via uv) |
| neovim | v0.12.1 |
| restic | v0.18.1 |
| agent-browser + Chrome for Testing | v0.25.4 |
| uv / uvx | 0.6.14 |
| Python | 3.13 (via uv) |
| ripgrep, jq, pandoc, imagemagick, tesseract-ocr, poppler-utils | apt stable |
| postgresql-client (psql) | 15 (Debian stable) |

## zeroclaw Build

The container image compiles zeroclaw from source (tag `v0.8.3`) with the
`observability-otel` cargo feature enabled, rather than using the pre-built
binary from the upstream image. This allows OpenTelemetry traces to be
exported when `backend = "otel"` is set in the zeroclaw config.

**Cargo features enabled:**
`acp-bridge, agent-runtime, channel-acp-server, channel-discord,
channel-email, channel-filesystem, channel-webhook, gateway,
observability-prometheus, observability-otel, schema-export`

To change the zeroclaw version or feature set, override the build args:

```sh
docker buildx build \
  --build-arg TARGETARCH=amd64 \
  --build-arg ZEROCLAW_VERSION=v0.8.3 \
  --build-arg ZEROCLAW_CARGO_FEATURES="acp-bridge,agent-runtime,channel-discord,gateway,observability-otel" \
  -t zeroclaw-container:local \
  -f Containerfile .
```

## Local Build

Requires Docker with [buildx](https://docs.docker.com/buildx/working-with-buildx/) support.

```sh
docker buildx build \
  --build-arg TARGETARCH=amd64 \
  -t zeroclaw-container:local \
  -f Containerfile .
```

Supported values for `TARGETARCH`: `amd64`, `arm64`.

## CI/CD

The publish workflow (`.github/workflows/publish.yml`) runs on every push to `main`:

1. **Tag** — automatically bumps the patch version and pushes a new semver tag using [`github-tag-action`](https://github.com/mathieudutour/github-tag-action).
2. **Build & push** — builds a multi-arch image (`linux/amd64`, `linux/arm64`) and pushes to GHCR with both the new version tag and `latest`.

GitHub Actions cache (`type=gha`) is used to speed up layer rebuilds.

To trigger a release, simply merge to `main`.
