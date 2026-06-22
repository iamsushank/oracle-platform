#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ansible"

if [ ! -f inventory.yml ]; then
  echo "Copy inventory.yml.example → inventory.yml and set ansible_host."
  exit 1
fi
if [ ! -f group_vars/platform.yml ]; then
  cp group_vars/platform.yml.example group_vars/platform.yml
  echo "Created group_vars/platform.yml from example."
fi

ansible-playbook playbooks/site.yml
