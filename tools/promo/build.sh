#!/bin/zsh
# Compiles the helpers and exports the app icons the cards use. Run once from this folder.
set -e
cd "$(dirname "$0")"
swiftc -O ui.swift -o ui
swiftc -O winsize.swift -o winsize
swiftc -O winfind.swift -o winfind
swiftc -O render.swift -o render
mkdir -p assets
sips -s format png --resampleWidth 1024 ../../Resources/AppIcon.icns --out assets/satchel.png >/dev/null
for app in Dia Arc "Google Chrome" Firefox; do
  p="/Applications/$app.app"; [ -d "$p" ] || continue
  icon=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$p/Contents/Info.plist"); case "$icon" in *.icns) ;; *) icon="$icon.icns";; esac
  sips -s format png --resampleWidth 512 "$p/Contents/Resources/$icon" --out "assets/$(echo $app | tr -d ' ').png" >/dev/null
done
echo "ready"
