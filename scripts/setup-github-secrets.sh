#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-$ROOT/.env.platform}"

# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a

expand_path() { echo "${1/#\~/$HOME}"; }
DEPLOY_SSH_KEY="$(expand_path "${DEPLOY_SSH_KEY:-$HOME/.ssh/github_deploy}")"
GITHUB_OWNER="${GITHUB_OWNER:-iamsushank}"
DEFAULT_REPO="${WEBHOOK_INGESTOR_REPO:-webhook-ingestor}"
APP_REPOS="${APP_REPOS:-$GITHUB_OWNER/$DEFAULT_REPO}"

IP=$(cd "$ROOT/terraform" && terraform output -raw instance_public_ip)

command -v gh >/dev/null || { echo "Install gh CLI: https://cli.github.com"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run: gh auth login"; exit 1; }

for repo in $APP_REPOS; do
  echo "Setting ORACLE_HOST=$IP on $repo"
  gh secret set ORACLE_HOST --body "$IP" -R "$repo"
  gh secret set ORACLE_SSH_KEY < "$DEPLOY_SSH_KEY" -R "$repo"
done

echo "GitHub secrets configured for: $APP_REPOS"
