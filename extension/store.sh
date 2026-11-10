#!/bin/zsh
# Store packages for the browser extension.
#
#   ./store.sh pack                     zips for the Chrome Web Store and Firefox Add-ons, in extension/store/
#   ./store.sh set-chrome-key <key>     after the first Chrome Web Store upload: adopt the store's public key, so the
#                                       extension id is the store's everywhere (manifest, app, smoke test)
#
# The Chrome Web Store refuses a "key" field on a new item, so `pack` strips it until set-chrome-key has run
# (the marker src/.chrome-web-store). Later uploads keep the key; it then equals the store's and pins the id.
set -euo pipefail
cd "$(dirname "$0")"

pack() {
  ./build.sh >/dev/null
  # Each store has its own version (Firefox may be ahead of Chrome or the reverse).
  local chrome firefox
  chrome=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' src/manifest.chromium.json)
  firefox=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' src/manifest.firefox.json)
  rm -rf store; mkdir -p store
  if [[ ! -f src/.chrome-web-store ]]; then
    grep -v '^  "key": ' dist/chromium/manifest.json > dist/chromium/manifest.tmp && mv dist/chromium/manifest.tmp dist/chromium/manifest.json
  fi
  (cd dist/chromium && zip -qrX "../../store/satchel-chrome-$chrome.zip" . -x '.*')
  (cd dist/firefox && zip -qrX "../../store/satchel-firefox-$firefox.zip" . -x '.*')
  ./build.sh >/dev/null  # dist/ back to the unpacked builds, key included
  echo "store/satchel-chrome-$chrome.zip  (Chrome Web Store; Edge, Brave, Arc and Dia install from it)"
  echo "store/satchel-firefox-$firefox.zip (addons.mozilla.org)"
}

set_chrome_key() {
  local key="${1:?usage: ./store.sh set-chrome-key <public key from the dashboard>}"
  key=$(print -r -- "$key" | sed -e 's/-----[A-Z ]*-----//g' | tr -d ' \n')
  local id; id=$(print -r -- "$key" | base64 -d | shasum -a 256 | head -c32 | tr 0-9a-f a-p)
  [[ "$id" =~ ^[a-p]{32}$ ]] || { echo "that is not a public key" >&2; exit 1; }
  print -r -- "$key" > src/.chromium-key
  print -r -- "$id" > src/.chromium-id
  sed -i '' "s|^  \"key\": \"[^\"]*\"|  \"key\": \"$key\"|" src/manifest.chromium.json
  sed -i '' "s|static let chromiumExtensionID = \"[a-p]*\"|static let chromiumExtensionID = \"$id\"|" ../Sources/Vault/Bridge/BridgeProtocol.swift
  grep -q "\"$id\"" ../Sources/Vault/Bridge/BridgeProtocol.swift || { echo "could not update BridgeProtocol.swift" >&2; exit 1; }
  touch src/.chrome-web-store
  echo "extension id is now $id. Commit, then the next app release accepts the store extension."
}

case "${1:-}" in
  pack) pack ;;
  set-chrome-key) shift; set_chrome_key "$@" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
