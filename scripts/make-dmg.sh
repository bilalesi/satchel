#!/bin/zsh
# Build a release DMG: build/Satchel-<version>.dmg (+ .sha256).
#   VERSION=0.1.27 BUILD_NUMBER=27 UNIVERSAL=1 scripts/make-dmg.sh
# The DMG holds Satchel.app and an Applications shortcut for drag-to-install, and carries
# the app icon as its volume icon. It is verified at the end: the image checksums, the app
# inside passes codesign, and the binary contains the expected architectures.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Satchel"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
export VERSION

./scripts/bundle.sh release

APP="build/$NAME.app"
DMG="build/$NAME-$VERSION.dmg"
RW="build/$NAME-rw.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$RW"; hdiutil detach "/Volumes/$NAME" -quiet 2>/dev/null || true' EXIT

rm -f "$DMG" "$DMG.sha256" "$RW"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# Read-write image first so the volume's custom-icon flag can be set, then compress.
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
# No -quiet on attach: the mount point is read from its output.
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -o '/Volumes/.*$' | tail -1)"
[ -d "$MOUNT" ] || { echo "could not mount $RW" >&2; exit 1; }
SetFile -a C "$MOUNT"
sync
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG"
# A Developer ID build signs the disk image too (notarized and stapled afterwards by the release workflow).
if [ -n "${SIGN_IDENTITY:-}" ]; then
  SIGN=(codesign --force --timestamp --sign "$SIGN_IDENTITY")
  [ -n "${SIGN_KEYCHAIN:-}" ] && SIGN+=(--keychain "$SIGN_KEYCHAIN")
  "${SIGN[@]}" "$DMG"
fi

( cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

# --- Verification -------------------------------------------------------------------------
hdiutil verify -quiet "$DMG"
CHECK="$(hdiutil attach -readonly -nobrowse -noverify -noautoopen "$DMG" | grep -o '/Volumes/.*$' | tail -1)"
[ -d "$CHECK" ] || { echo "could not mount $DMG" >&2; exit 1; }
codesign --verify --deep --strict "$CHECK/$NAME.app"
ARCHS="$(lipo -archs "$CHECK/$NAME.app/Contents/MacOS/$NAME")"
test -L "$CHECK/Applications"
hdiutil detach -quiet "$CHECK"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "expected a universal binary, got: $ARCHS" >&2; exit 1; }
fi
echo "DMG ready: $DMG ($(du -h "$DMG" | cut -f1), $ARCHS)"
cat "$DMG.sha256"
