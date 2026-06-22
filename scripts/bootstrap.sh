#!/usr/bin/env bash
# End-to-end bootstrap: Terraform → Ansible → GitHub secrets → first deploy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env.platform"

echo "==> oracle-platform bootstrap"

for cmd in terraform ansible-playbook gh ssh-keygen; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
done

if [ ! -f "$ENV_FILE" ]; then
  cp "$ROOT/.env.platform.example" "$ENV_FILE"
  echo ""
  echo "Created $ENV_FILE"
  echo ""
  echo "ONE-TIME Oracle setup (cannot be skipped — Oracle requires it):"
  echo "  1. Console → Profile (top-right) → My profile → API Keys → Add API Key"
  echo "  2. Download private key → save as ~/.oci/oci_api_key.pem"
  echo "  3. Note fingerprint shown in console"
  echo "  4. Fill OCI_* values in $ENV_FILE"
  echo "     Tip: compartment_ocid can equal tenancy_ocid for root compartment"
  echo "     OCIDs: Console → Governance → Tenancy details / User settings"
  echo "  5. Re-run: ./scripts/bootstrap.sh"
  echo ""
  exit 1
fi

# shellcheck disable=SC1090
set -a && source "$ENV_FILE" && set +a

"$ROOT/scripts/generate-tfvars.sh" "$ENV_FILE"

echo "==> Terraform provision"
"$ROOT/scripts/provision.sh"

IP=$(cd "$ROOT/terraform" && terraform output -raw instance_public_ip)
echo "==> VM public IP: $IP"

expand_path() { echo "${1/#\~/$HOME}"; }
DEPLOY_SSH_KEY="$(expand_path "${DEPLOY_SSH_KEY:-$HOME/.ssh/github_deploy}")"
"$ROOT/scripts/wait-for-ssh.sh" "$IP" deploy "$DEPLOY_SSH_KEY" 360

echo "==> Ansible inventory"
mkdir -p "$ROOT/ansible/group_vars"
cat > "$ROOT/ansible/inventory.yml" <<EOF
all:
  children:
    platform:
      hosts:
        oracle:
          ansible_host: $IP
          ansible_user: deploy
          ansible_ssh_private_key_file: $DEPLOY_SSH_KEY
          ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
EOF

[ -f "$ROOT/ansible/group_vars/platform.yml" ] || \
  cp "$ROOT/ansible/group_vars/platform.yml.example" "$ROOT/ansible/group_vars/platform.yml"

echo "==> Ansible configure (Caddy + apps)"
ANSIBLE_HOST_KEY_CHECKING=False "$ROOT/scripts/configure.sh"

echo "==> GitHub secrets"
"$ROOT/scripts/setup-github-secrets.sh" "$ENV_FILE"

echo "==> Trigger app deploys"
"$ROOT/scripts/trigger-app-deploys.sh"

echo ""
echo "============================================"
echo " DONE"
echo " Dashboard: http://$IP/"
echo " Health:    curl http://$IP/healthz"
echo " GitHub:    gh run list -R ${APP_REPOS%% *}"
echo "============================================"
