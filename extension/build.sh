#!/bin/zsh
# Assemble extension/dist/chromium and extension/dist/firefox from extension/src.
set -euo pipefail
cd "$(dirname "$0")"
for target in chromium firefox; do
  out="dist/$target"
  rm -rf "$out"; mkdir -p "$out"
  cp src/background.js src/content.js src/popup.html src/popup.js src/popup.css "$out/"
  cp -R src/icons "$out/icons"
  cp "src/manifest.$target.json" "$out/manifest.json"
done
echo "extension built: dist/chromium (id $(cat src/.chromium-id)), dist/firefox (satchel@bilalesi)"
