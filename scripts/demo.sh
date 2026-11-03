#!/bin/zsh
# Seeds four demo workspaces (fake data only) and launches an isolated copy of the app on them: its own bundle
# id, data folder and settings, so your real vault is never touched.
#   scripts/demo.sh            seed, build, launch
#   WAIT=10 scripts/demo.sh    seconds to wait for the window
#   EXTRA_ENV="A=1 B=2" scripts/demo.sh   extra environment for the app (debug switches)
#   DEMO_SYNC=1 scripts/demo.sh   Personal already syncs to a folder, Banking kept on this Mac
#   DEMO_TRIAL_AGO=10 scripts/demo.sh   the trial started 10 days ago (ended); a licence key to paste is in build/demo/license-key.txt
# Master password of every demo workspace: demo-password-123
set -euo pipefail
cd "$(dirname "$0")/.."

ID="com.bilalesi.satchel.demo"
DEMO="$PWD/build/demo"
APP="$DEMO/Satchel.app"

pkill -f "$APP/Contents/MacOS/Satchel" 2>/dev/null || true

# 1. Vaults: four workspaces with categories and items of every type.
env ${DEMO_SYNC:+SATCHEL_DEMO_SYNC=1} SATCHEL_DEMO_DIR="$DEMO/vaults" swift test --filter DemoVaultSeeder >/dev/null

# 2. A debug build under its own identity (debug builds can unlock the demo vault without typing).
./scripts/bundle.sh debug >/dev/null
rm -rf "$APP" "$DEMO/support" && mkdir -p "$DEMO/support"
cp -R build/Satchel.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
codesign --force --deep --sign - --identifier "$ID" "$APP" >/dev/null 2>&1

# 3. Settings: the workspace list, and a few non-default choices so Settings and the menu look lived in.
defaults delete "$ID" >/dev/null 2>&1 || true
security delete-generic-password -s "$ID.trial" -a trialStarted >/dev/null 2>&1 || true # the trial start's Keychain copy
defaults write "$ID" workspaces -data "$(xxd -p -c0 "$DEMO/vaults/workspaces.json")"
defaults write "$ID" activeWorkspace "11111111-1111-4111-8111-111111111111"
defaults write "$ID" didShowWelcome -bool true
defaults write "$ID" menuExpanded -bool true
defaults write "$ID" listWidth -float 340
defaults write "$ID" autoLockMinutes -int 5
defaults write "$ID" clipboardSeconds -int 15
defaults write "$ID" hotKeyEnabled -bool true
defaults write "$ID" autoTypeEnabled -bool true
defaults write "$ID" allowScreenCapture -bool true
# Two built-in menu entries in a look of the user's own (see MenuLookStore).
defaults write "$ID" menuLooks -data "$(printf '%s' '{"favorites":{"icon":"satchel.favorites","color":"pink"},"secureNote":{"icon":"satchel.lock","color":"red"}}' | xxd -p -c0)"

# Licences: a throwaway key pair for this copy only, and one key signed with it to paste into Settings → Licence.
pair=$(swift scripts/license-key.swift generate)
LICENSE_PUB=$(print -r -- "$pair" | awk '/^public /{print $2}')
LICENSE_SIGNING_KEY=$(print -r -- "$pair" | awk '/^private /{print $2}') \
  swift scripts/license-key.swift issue single "$(date -u +%Y-%m-%d)" demo-0001 > "$DEMO/license-key.txt"
[ -n "${DEMO_TRIAL_AGO:-}" ] && defaults write "$ID" trialStarted -date "$(date -u -v-${DEMO_TRIAL_AGO}d '+%Y-%m-%d %H:%M:%S +0000')"

# 4. Launch, unlocked on the first workspace. Through LaunchServices (`open -n`), so the app is its own
# process, not a child of this shell: a script run from a tool or terminal can end without taking it along.
envargs=(--env "SATCHEL_SUPPORT_DIR=$DEMO/support" --env "SATCHEL_DEMO_PASSWORD=demo-password-123" --env "SATCHEL_LICENSE_PUBKEY=$LICENSE_PUB")
for kv in ${=EXTRA_ENV:-}; do envargs+=(--env "$kv"); done
open -n -a "$APP" "${envargs[@]}"
sleep "${WAIT:-8}"
pgrep -f "$APP/Contents/MacOS/Satchel" | head -1
