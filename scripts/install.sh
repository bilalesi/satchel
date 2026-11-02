#!/bin/zsh
# Build, sign and install Satchel.app into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh release

DEST="/Applications/Satchel.app"
if pgrep -fq "$DEST/Contents/MacOS/Satchel"; then
  echo "Quitting running Satchel…"
  pkill -f "$DEST/Contents/MacOS/Satchel" || true
  sleep 1
fi
rm -rf "$DEST"
cp -R "build/Satchel.app" "$DEST"
echo "Installed $DEST"
echo "Launch it from Spotlight or: open $DEST"
