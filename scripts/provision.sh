#!/usr/bin/env bash
# One-time: provision Oracle Always Free platform VM.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/terraform"

if [ ! -f terraform.tfvars ]; then
  echo "Copy terraform.tfvars.example → terraform.tfvars and fill in OCIDs."
  exit 1
fi

terraform init
terraform plan -out=tfplan
terraform apply tfplan

echo ""
echo "=== Next steps ==="
terraform output ssh_command
terraform output -raw instance_public_ip | xargs -I{} echo "ORACLE_HOST secret: {}"
echo "1. Wait ~2 min for cloud-init"
echo "2. cp ansible/inventory.yml.example ansible/inventory.yml  # set ansible_host"
echo "3. cp ansible/group_vars/platform.yml.example ansible/group_vars/platform.yml"
echo "4. ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml"
