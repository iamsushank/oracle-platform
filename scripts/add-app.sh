#!/usr/bin/env bash
# Register a new app on the platform (creates apps/<name>.yml from template).
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "Usage: $0 <app-name>"
  exit 1
fi

NAME="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/apps/${NAME}.yml"

if [ -f "$TARGET" ]; then
  echo "Already exists: $TARGET"
  exit 1
fi

cp "$ROOT/apps/_template.yml" "$TARGET"
sed -i '' "s/my-app/${NAME}/g" "$TARGET" 2>/dev/null || sed -i "s/my-app/${NAME}/g" "$TARGET"
sed -i '' "s/myapp.example.com/${NAME}.example.com/g" "$TARGET" 2>/dev/null || sed -i "s/myapp.example.com/${NAME}.example.com/g" "$TARGET"

echo "Created $TARGET"
echo "Edit the file, then run: ./scripts/configure.sh"
