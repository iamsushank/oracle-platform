#!/usr/bin/env bash
# Push all platform + app deploy secrets to GitHub from .env.platform.
# Usage: fill .env.platform, then ./scripts/setup-platform-github-secrets.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-$ROOT/.env.platform}"
REPO="${PLATFORM_GITHUB_REPO:-iamsushank/oracle-platform}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE — copy .env.platform.example and fill OCI values." >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a && source "$ENV_FILE" && set +a

expand_path() { echo "${1/#\~/$HOME}"; }

: "${OCI_TENANCY_OCID:?Set OCI_TENANCY_OCID in $ENV_FILE}"
: "${OCI_USER_OCID:?Set OCI_USER_OCID}"
: "${OCI_FINGERPRINT:?Set OCI_FINGERPRINT}"
: "${OCI_REGION:?Set OCI_REGION}"
: "${OCI_COMPARTMENT_OCID:?Set OCI_COMPARTMENT_OCID}"
: "${OCI_PRIVATE_KEY_PATH:?Set OCI_PRIVATE_KEY_PATH}"
: "${OCI_S3_ACCESS_KEY:?Set OCI_S3_ACCESS_KEY (Customer Secret Key access)}"
: "${OCI_S3_SECRET_KEY:?Set OCI_S3_SECRET_KEY (Customer Secret Key secret)}"

PRIVATE_KEY_PATH="$(expand_path "$OCI_PRIVATE_KEY_PATH")"
[ -f "$PRIVATE_KEY_PATH" ] || { echo "Missing OCI private key: $PRIVATE_KEY_PATH" >&2; exit 1; }

PLATFORM_SSH_KEY="$(expand_path "${PLATFORM_SSH_KEY:-$HOME/.ssh/oracle_platform}")"
DEPLOY_SSH_KEY="$(expand_path "${DEPLOY_SSH_KEY:-$HOME/.ssh/github_deploy}")"

mkdir -p "$(dirname "$PLATFORM_SSH_KEY")"
[ -f "$PLATFORM_SSH_KEY" ] || ssh-keygen -t ed25519 -f "$PLATFORM_SSH_KEY" -N "" -C "oracle-platform"
[ -f "$DEPLOY_SSH_KEY" ] || ssh-keygen -t ed25519 -f "$DEPLOY_SSH_KEY" -N "" -C "github-deploy"

command -v gh >/dev/null || { echo "Install gh CLI: https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run: gh auth login" >&2; exit 1; }

GITHUB_OWNER="${GITHUB_OWNER:-iamsushank}"
DEFAULT_REPO="${WEBHOOK_INGESTOR_REPO:-webhook-ingestor}"
APP_REPOS="${APP_REPOS:-$GITHUB_OWNER/$DEFAULT_REPO}"

echo "==> Platform repo secrets ($REPO)"
gh secret set OCI_TENANCY_OCID --body "$OCI_TENANCY_OCID" -R "$REPO"
gh secret set OCI_USER_OCID --body "$OCI_USER_OCID" -R "$REPO"
gh secret set OCI_FINGERPRINT --body "$OCI_FINGERPRINT" -R "$REPO"
gh secret set OCI_COMPARTMENT_OCID --body "$OCI_COMPARTMENT_OCID" -R "$REPO"
gh secret set OCI_PRIVATE_KEY < "$PRIVATE_KEY_PATH" -R "$REPO"
gh secret set OCI_S3_ACCESS_KEY --body "$OCI_S3_ACCESS_KEY" -R "$REPO"
gh secret set OCI_S3_SECRET_KEY --body "$OCI_S3_SECRET_KEY" -R "$REPO"
gh secret set PLATFORM_SSH_PRIVATE_KEY < "$PLATFORM_SSH_KEY" -R "$REPO"
gh secret set PLATFORM_SSH_PUBLIC_KEY < "${PLATFORM_SSH_KEY}.pub" -R "$REPO"
gh secret set PLATFORM_GH_TOKEN --body "$(gh auth token)" -R "$REPO"

if [ -n "${GHCR_PULL_TOKEN:-}" ]; then
  gh secret set GHCR_PULL_TOKEN --body "$GHCR_PULL_TOKEN" -R "$REPO"
fi

echo "==> Platform repo variables"
gh variable set OCI_REGION --body "$OCI_REGION" -R "$REPO"
gh variable set APP_REPOS --body "$APP_REPOS" -R "$REPO"
[ -n "${TF_STATE_BUCKET:-}" ] && gh variable set TF_STATE_BUCKET --body "$TF_STATE_BUCKET" -R "$REPO"
[ -n "${GHCR_USER:-}" ] && gh variable set GHCR_USER --body "$GHCR_USER" -R "$REPO"

IP=""
if [ -d "$ROOT/terraform" ] && command -v terraform >/dev/null 2>&1; then
  IP=$(cd "$ROOT/terraform" && terraform output -raw instance_public_ip 2>/dev/null || true)
fi

if [ -n "$IP" ]; then
  gh variable set ORACLE_HOST --body "$IP" -R "$REPO"
fi

echo "==> App repo deploy secrets"
for app_repo in $APP_REPOS; do
  if [ -n "$IP" ]; then
    gh secret set ORACLE_HOST --body "$IP" -R "$app_repo"
  fi
  gh secret set ORACLE_SSH_KEY < "$DEPLOY_SSH_KEY" -R "$app_repo"
  echo "  $app_repo"
done

echo ""
echo "GitHub secrets configured."
echo "Next: gh workflow run provision.yml -R $REPO -f action=apply"
