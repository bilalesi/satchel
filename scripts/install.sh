#!/bin/zsh
# Build, sign and install Vault.app into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh release

DEST="/Applications/Vault.app"
if pgrep -fq "$DEST/Contents/MacOS/Vault"; then
  echo "Quitting running Vault…"
  pkill -f "$DEST/Contents/MacOS/Vault" || true
  sleep 1
fi
rm -rf "$DEST"
cp -R "build/Vault.app" "$DEST"
echo "Installed $DEST"
echo "Launch it from Spotlight or: open $DEST"
