#!/bin/zsh
# Build the release binary and assemble + ad-hoc sign build/Satchel.app.
set -euo pipefail
setopt null_glob
cd "$(dirname "$0")/.."

NAME="Satchel"
APP="build/$NAME.app"
CONFIG="${1:-release}"

swift build -c "$CONFIG" --product "$NAME" 2>&1 | tail -3
swift build -c "$CONFIG" --product satchel-host 2>&1 | tail -1
BIN=".build/$CONFIG/$NAME"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp "$BIN_DIR/satchel-host" "$APP/Contents/MacOS/satchel-host"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Browser extension (built by extension/build.sh) ships inside the bundle for "Load unpacked".
if [ -x extension/build.sh ]; then ./extension/build.sh >/dev/null && cp -R extension/dist "$APP/Contents/Resources/extension"; fi
# SwiftPM resource bundles (if any) live next to the binary.
cp -R "$BIN_DIR/${NAME}_VaultCore.bundle" "$APP/Contents/Resources/" # PSL data; only this package's bundle
# Dynamic frameworks produced by dependencies (Clibsodium is static in swift-sodium 0.11; kept for safety).
for f in "$BIN_DIR"/*.framework; do [ -e "$f" ] && cp -R "$f" "$APP/Contents/Frameworks/"; done
# App icon: layered Icon Composer icon compiled to Assets.car (macOS 26 glass, dark, tinted),
# plus the size-tuned AppIcon.icns from scripts/make-icon.swift as the classic fallback.
if [ -d Resources/AppIcon.icon ]; then
  xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 15.0 --app-icon AppIcon \
    --output-partial-info-plist "$APP/Contents/Resources/.actool-partial.plist" >/dev/null
  rm -f "$APP/Contents/Resources/.actool-partial.plist"
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Codicon font (loaded by macOS through ATSApplicationFontsPath = Fonts) and its CC BY 4.0 license.
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

# Ad-hoc signature with hardened runtime. Entitlements are deliberately empty: no sandbox
# (auto-type later), no library-validation bypass, no dyld env vars, no get-task-allow. A stable identifier keeps the designated
# requirement stable across rebuilds, which matters for Secure Enclave key access.
codesign --force --deep --sign - \
  --identifier "com.bilalesi.satchel" \
  --entitlements Resources/Satchel.entitlements \
  --options runtime \
  "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
