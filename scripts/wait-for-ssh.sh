#!/usr/bin/env bash
# Poll until SSH on a host accepts connections (replaces a fragile fixed sleep).
# Usage: wait-for-ssh.sh <host> [user] [key_path] [timeout_seconds]
set -euo pipefail

HOST="${1:?usage: wait-for-ssh.sh <host> [user] [key] [timeout]}"
USER="${2:-deploy}"
KEY="${3:-}"
TIMEOUT="${4:-300}"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null)
[ -n "$KEY" ] && SSH_OPTS+=(-i "${KEY/#\~/$HOME}")

echo "Waiting for SSH on $USER@$HOST (timeout ${TIMEOUT}s)..."
deadline=$(( $(date +%s) + TIMEOUT ))
until ssh "${SSH_OPTS[@]}" "$USER@$HOST" 'true' 2>/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "Timed out waiting for SSH on $HOST" >&2
    exit 1
  fi
  sleep 5
done
echo "SSH is up on $HOST"
