#!/bin/zsh
# Build the release binary and assemble + ad-hoc sign build/Vault.app.
set -euo pipefail
setopt null_glob
cd "$(dirname "$0")/.."

NAME="Vault"
APP="build/$NAME.app"
CONFIG="${1:-release}"

swift build -c "$CONFIG" --product "$NAME" 2>&1 | tail -3
BIN=".build/$CONFIG/$NAME"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftPM resource bundles (if any) live next to the binary.
for b in "$BIN_DIR"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# Dynamic frameworks produced by dependencies (Clibsodium is static in swift-sodium 0.11; kept for safety).
for f in "$BIN_DIR"/*.framework; do [ -e "$f" ] && cp -R "$f" "$APP/Contents/Frameworks/"; done
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Ad-hoc signature with hardened runtime. Entitlements are deliberately empty: no sandbox
# (auto-type later), no library-validation bypass, no dyld env vars, no get-task-allow. A stable identifier keeps the designated
# requirement stable across rebuilds, which matters for Secure Enclave key access.
codesign --force --deep --sign - \
  --identifier "com.bilalesi.vault" \
  --entitlements Resources/Vault.entitlements \
  --options runtime \
  "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
