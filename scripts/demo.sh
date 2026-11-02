#!/bin/zsh
# Seeds four demo workspaces (fake data only) and launches an isolated copy of the app on them: its own bundle
# id, data folder and settings, so your real vault is never touched.
#   scripts/demo.sh            seed, build, launch
#   WAIT=10 scripts/demo.sh    seconds to wait for the window
#   EXTRA_ENV="A=1 B=2" scripts/demo.sh   extra environment for the app (debug switches)
# Master password of every demo workspace: demo-password-123
set -euo pipefail
cd "$(dirname "$0")/.."

ID="com.bilalesi.satchel.demo"
DEMO="$PWD/build/demo"
APP="$DEMO/Satchel.app"

pkill -f "$APP/Contents/MacOS/Satchel" 2>/dev/null || true

# 1. Vaults: four workspaces with categories and items of every type.
SATCHEL_DEMO_DIR="$DEMO/vaults" swift test --filter DemoVaultSeeder >/dev/null

# 2. A debug build under its own identity (debug builds can unlock the demo vault without typing).
./scripts/bundle.sh debug >/dev/null
rm -rf "$APP" "$DEMO/support" && mkdir -p "$DEMO/support"
cp -R build/Satchel.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
codesign --force --deep --sign - --identifier "$ID" "$APP" >/dev/null 2>&1

# 3. Settings: the workspace list, and a few non-default choices so Settings and the menu look lived in.
defaults delete "$ID" >/dev/null 2>&1 || true
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

# 4. Launch, unlocked on the first workspace. Through LaunchServices (`open -n`), so the app is its own
# process, not a child of this shell: a script run from a tool or terminal can end without taking it along.
envargs=(--env "SATCHEL_SUPPORT_DIR=$DEMO/support" --env "SATCHEL_DEMO_PASSWORD=demo-password-123")
for kv in ${=EXTRA_ENV:-}; do envargs+=(--env "$kv"); done
open -n -a "$APP" "${envargs[@]}"
sleep "${WAIT:-8}"
pgrep -f "$APP/Contents/MacOS/Satchel" | head -1
