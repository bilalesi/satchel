#!/bin/zsh
# Build the release binary and assemble + sign build/Satchel.app (ad hoc unless SIGN_IDENTITY is set).
#   VERSION=0.1.27 BUILD_NUMBER=27   stamp the bundle version (default: Resources/Info.plist)
#   UNIVERSAL=1                      build arm64 + x86_64 (what releases ship)
#   SIGN_IDENTITY=<hash or name>     sign with this Developer ID Application identity (SIGN_KEYCHAIN: its keychain)
set -euo pipefail
setopt null_glob
cd "$(dirname "$0")/.."

NAME="Satchel"
APP="build/$NAME.app"
CONFIG="${1:-release}"

if [ "${UNIVERSAL:-0}" = "1" ]; then
  # Two single-architecture builds merged with lipo. SwiftPM's multi-arch mode (xcbuild)
  # mis-resolves swift-sodium's macOS-only binary target and fails to link -lsodium.
  DIRS=()
  for arch in arm64 x86_64; do
    TRIPLE="$arch-apple-macosx15.0"
    swift build -c "$CONFIG" --triple "$TRIPLE" --product "$NAME" 2>&1 | tail -3
    swift build -c "$CONFIG" --triple "$TRIPLE" --product satchel-host 2>&1 | tail -1
    DIRS+=("$(swift build -c "$CONFIG" --triple "$TRIPLE" --show-bin-path)")
  done
  BIN_DIR="build/.universal"
  rm -rf "$BIN_DIR"; mkdir -p "$BIN_DIR"
  for bin in "$NAME" satchel-host; do
    lipo -create "${DIRS[1]}/$bin" "${DIRS[2]}/$bin" -output "$BIN_DIR/$bin"
  done
else
  swift build -c "$CONFIG" --product "$NAME" 2>&1 | tail -3
  swift build -c "$CONFIG" --product satchel-host 2>&1 | tail -1
  BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
fi
BIN="$BIN_DIR/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp "$BIN_DIR/satchel-host" "$APP/Contents/MacOS/satchel-host"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Version stamping happens before signing; the source plist stays at its development value.
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
# Updates: the public half of the release signing key (the private half never enters the repo).
if [ -s Resources/update-public-key.txt ]; then
  /usr/libexec/PlistBuddy -c "Set :SatchelUpdatePublicKey $(tr -d '[:space:]' < Resources/update-public-key.txt)" "$APP/Contents/Info.plist"
fi
# Licences: the public half of the licence signing key (scripts/license-key.swift). Without it nothing is enforced.
if [ -s Resources/license-public-key.txt ]; then
  /usr/libexec/PlistBuddy -c "Set :SatchelLicensePublicKey $(tr -d '[:space:]' < Resources/license-public-key.txt)" "$APP/Contents/Info.plist"
fi
# Browser extension (built by extension/build.sh) ships inside the bundle for "Load unpacked".
if [ -x extension/build.sh ]; then ./extension/build.sh >/dev/null && cp -R extension/dist "$APP/Contents/Resources/extension"; fi
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
cp THIRD_PARTY_NOTICES.md LICENSE "$APP/Contents/Resources/"

# Hardened runtime either way. Entitlements are deliberately empty: no sandbox (auto-type), no library-validation
# bypass, no dyld env vars, no get-task-allow. A stable identifier keeps the designated requirement stable across
# rebuilds, which matters for Secure Enclave key access.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  # Developer ID (then notarized by the release workflow): nested code first, inside out, each with a secure
  # timestamp; Apple advises against --deep for signing.
  SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  [ -n "${SIGN_KEYCHAIN:-}" ] && SIGN+=(--keychain "$SIGN_KEYCHAIN")
  for f in "$APP"/Contents/Frameworks/*.framework "$APP/Contents/MacOS/satchel-host"; do "${SIGN[@]}" "$f"; done
  "${SIGN[@]}" --identifier "com.bilalesi.satchel" --entitlements Resources/Satchel.entitlements "$APP"
else
  codesign --force --deep --sign - \
    --identifier "com.bilalesi.satchel" \
    --entitlements Resources/Satchel.entitlements \
    --options runtime \
    "$APP"
fi
# No code may depend on a SwiftPM resource bundle (its lookup falls back to the build machine's path).
if strings "$APP/Contents/MacOS/$NAME" | grep -q "_VaultCore.bundle"; then echo "binary references a SwiftPM resource bundle" >&2; exit 1; fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"), archs: $(lipo -archs "$APP/Contents/MacOS/$NAME"))"
