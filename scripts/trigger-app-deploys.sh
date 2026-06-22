#!/usr/bin/env bash
# Trigger deploy workflow on each repo in APP_REPOS (space-separated owner/repo).
set -euo pipefail

GITHUB_OWNER="${GITHUB_OWNER:-iamsushank}"
DEFAULT_REPO="${WEBHOOK_INGESTOR_REPO:-webhook-ingestor}"
APP_REPOS="${APP_REPOS:-$GITHUB_OWNER/$DEFAULT_REPO}"

command -v gh >/dev/null || { echo "Install gh CLI: https://cli.github.com"; exit 1; }

for repo in $APP_REPOS; do
  echo "==> triggering deploy on $repo"
  gh workflow run deploy.yml -R "$repo" 2>/dev/null || \
    gh workflow run "Build and Deploy" -R "$repo" 2>/dev/null || \
    echo "warn: could not trigger deploy on $repo" >&2
done
