# Renovate Setup for Auto-Updates

This repository uses Renovate to automatically update pinned tool versions in the Containerfile.

## What It Does

Renovate monitors the `Containerfile` for new versions of:

- **Docker base images**: `ghcr.io/zeroclaw-labs/zeroclaw`, `ghcr.io/astral-sh/uv`, `rust`
- **GitHub release tools**: helm, yq, restic, neovim, agent-browser, kubectl, Python
- **npm packages**: `camofox-mcp`, `@perplexity-ai/mcp-server`
- **Node.js**: installed from nodejs.org tarball

Renovate will:

- Create PRs with semantic commit messages (`chore(deps): update helm to v4.2.4`)
- **Auto-merge** minor and patch updates for most tools
- Require manual approval for major updates (e.g., kubernetes, Python)
- Require manual review for `camofox-mcp` (patches are version-pinned to specific releases)

## Setup Instructions

### 1. Create Required Secrets

Add these repository secrets under Settings → Secrets and variables → Actions:

| Secret | Purpose |
|--------|---------|
| `RENOVATE_TOKEN` | GitHub PAT with `repo` and `workflow` scopes (used by self-hosted Renovate) |
| `GHCR_TOKEN` | GitHub PAT with `read:packages` scope (for ghcr.io docker datasource access) |

### 2. Enable Auto-Merge in GitHub Settings

1. Go to repo Settings → General
2. Scroll to "Pull Requests"
3. Check "Allow auto-merge"

### 3. First Run

The self-hosted Renovate workflow runs every 6 hours via cron (`0 */6 * * *`).
You can also trigger it manually via the Actions tab → "Renovate" → "Run workflow".

After the first run:

1. Renovate creates an "onboarding" PR to confirm setup
2. Merge the onboarding PR
3. Renovate creates PRs for any outdated tool versions

## Configuration Details

### Auto-Merge Rules

| Update Type | Behavior |
|-------------|----------|
| Patch (0.12.1 → 0.12.2) | Auto-merged |
| Minor (0.12.x → 0.13.0) | Auto-merged (most tools) |
| Major (1.x → 2.0.0) | Manual review required |
| `camofox-mcp` (any) | Manual review required (patches are version-pinned) |
| `kubernetes/kubernetes` (any) | Manual review required |
| `python/cpython` (any) | Manual review required |

### Checksum Updates

Two tools have SHA-256 checksums pinned in the Containerfile:

- **neovim** — checksums per arch
- **agent-browser** — checksums per arch

The `update-checksums.yml` workflow automatically updates these checksums when Renovate
bumps the version. It triggers on PRs from `renovate/` branches, downloads the new
binaries, computes checksums, and commits the update to the PR branch.

### Commit Format

Renovate follows conventional commits:

```text
chore(deps): update helm to v4.2.4
```

### Rate Limiting

- Max 3 PRs open at once
- Max 2 PRs created per hour
- Runs before 6am Monday (America/Los_Angeles)

## Self-Hosted vs Hosted App

This repo uses **self-hosted Renovate** via GitHub Actions (`.github/workflows/renovate.yml`),
matching the pattern in `cluster-config`. This gives more control over scheduling and
allows authenticated access to private GHCR images via `GHCR_TOKEN`.

The hosted Renovate app (https://github.com/apps/renovate) also works if installed —
the `renovate.json` config is compatible with both.

## Customization

Edit `.github/renovate.json` to:

- Change auto-merge rules
- Add new tools (add a `customManagers` entry with a regex matching the Containerfile line)
- Adjust PR limits
- Change timezone for scheduling

### Adding a New Tool

Add a customManager matching the version pattern in the Containerfile:

```json
{
  "customType": "regex",
  "fileMatch": ["^Containerfile$"],
  "matchStrings": ["TOOL_VERSION=(?<currentValue>v[0-9.]+)"],
  "depNameTemplate": "owner/repo",
  "datasourceTemplate": "github-releases"
}
```

## Troubleshooting

**Renovate not creating PRs:**
- Check the workflow run logs in Actions tab → "Renovate"
- Verify `RENOVATE_TOKEN` has `repo` and `workflow` scopes
- Ensure `.github/renovate.json` is valid JSON

**Auto-merge not working:**
- Verify "Allow auto-merge" is enabled in repo settings
- Check that branch protection rules allow auto-merge
- Ensure all required CI checks pass

**Checksum update workflow not running:**
- The `update-checksums.yml` only runs on PRs from `renovate/` branches
- Check that the workflow has `contents: write` and `pull-requests: write` permissions