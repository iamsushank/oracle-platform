#!/usr/bin/env bash
# Read .env.platform and emit terraform/terraform.tfvars
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-$ROOT/.env.platform}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE — copy .env.platform.example and fill in OCI values."
  exit 1
fi

# shellcheck disable=SC1090
set -a && source "$ENV_FILE" && set +a

expand_path() { echo "${1/#\~/$HOME}"; }

if [ "${OCI_USE_LOCAL_CONFIG:-false}" = "true" ] || [ -z "${OCI_TENANCY_OCID:-}" ]; then
  OCI_CFG="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
  if [ -f "$OCI_CFG" ]; then
    OCI_TENANCY_OCID="${OCI_TENANCY_OCID:-$(awk -F= '/^tenancy=/{print $2}' "$OCI_CFG" | tr -d ' ')}"
    OCI_USER_OCID="${OCI_USER_OCID:-$(awk -F= '/^user=/{print $2}' "$OCI_CFG" | tr -d ' ')}"
    OCI_FINGERPRINT="${OCI_FINGERPRINT:-$(awk -F= '/^fingerprint=/{print $2}' "$OCI_CFG" | tr -d ' ')}"
    OCI_REGION="${OCI_REGION:-$(awk -F= '/^region=/{print $2}' "$OCI_CFG" | tr -d ' ')}"
    OCI_PRIVATE_KEY_PATH="${OCI_PRIVATE_KEY_PATH:-$(awk -F= '/^key_file=/{print $2}' "$OCI_CFG" | tr -d ' ')}"
  fi
fi

: "${OCI_TENANCY_OCID:?Set OCI_TENANCY_OCID in .env.platform}"
: "${OCI_USER_OCID:?Set OCI_USER_OCID}"
: "${OCI_FINGERPRINT:?Set OCI_FINGERPRINT}"
: "${OCI_REGION:?Set OCI_REGION}"
: "${OCI_COMPARTMENT_OCID:?Set OCI_COMPARTMENT_OCID (root compartment OCID = tenancy OCID is OK)}"
: "${OCI_PRIVATE_KEY_PATH:?Set OCI_PRIVATE_KEY_PATH}"

PLATFORM_SSH_KEY="$(expand_path "${PLATFORM_SSH_KEY:-$HOME/.ssh/oracle_platform}")"
DEPLOY_SSH_KEY="$(expand_path "${DEPLOY_SSH_KEY:-$HOME/.ssh/github_deploy}")"

mkdir -p "$(dirname "$PLATFORM_SSH_KEY")"
if [ ! -f "$PLATFORM_SSH_KEY" ]; then
  ssh-keygen -t ed25519 -f "$PLATFORM_SSH_KEY" -N "" -C "oracle-platform"
fi
if [ ! -f "$DEPLOY_SSH_KEY" ]; then
  ssh-keygen -t ed25519 -f "$DEPLOY_SSH_KEY" -N "" -C "github-deploy"
fi

SSH_PUBLIC=$(cat "${PLATFORM_SSH_KEY}.pub")
DEPLOY_PUBLIC=$(cat "${DEPLOY_SSH_KEY}.pub")
PRIVATE_KEY_PATH="$(expand_path "$OCI_PRIVATE_KEY_PATH")"

cat > "$ROOT/terraform/terraform.tfvars" <<EOF
tenancy_ocid     = "$OCI_TENANCY_OCID"
user_ocid        = "$OCI_USER_OCID"
fingerprint      = "$OCI_FINGERPRINT"
private_key_path = "$PRIVATE_KEY_PATH"
region           = "$OCI_REGION"
compartment_ocid = "$OCI_COMPARTMENT_OCID"
ssh_public_key   = "$SSH_PUBLIC"
deploy_ssh_public_key = "$DEPLOY_PUBLIC"
instance_name    = "${TF_INSTANCE_NAME:-platform}"
shape_ocpus      = ${TF_SHAPE_OCPUS:-2}
shape_memory_gb  = ${TF_SHAPE_MEMORY_GB:-12}
EOF

if [ -n "${TF_ADMIN_CIDR:-}" ]; then
  echo "admin_cidr = \"$TF_ADMIN_CIDR\"" >> "$ROOT/terraform/terraform.tfvars"
fi

echo "Wrote terraform/terraform.tfvars"
