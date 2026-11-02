#!/bin/zsh
# Fresh demo, unlocked on Personal, in real full screen. EXTRA_ENV passes debug switches to the app.
P0="$(cd "$(dirname "$0")" && pwd)"
cd "$P0/../.."
pkill -f "build/demo/Satchel.app" 2>/dev/null; sleep 1
rm -rf "$HOME/Library/Saved Application State/com.bilalesi.satchel.demo.savedState"   # never resume into a lost window or full screen
WAIT=8 ./scripts/demo.sh >/dev/null 2>&1
pid=$(pgrep -f "build/demo/Satchel.app/Contents/MacOS/Satchel" | head -1)
osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '$pid') to true'
sleep 1.5
P="$P0"
# Not macOS full screen: the window at the largest size the screen allows (full width, below the menu bar, above
# the Dock). Leave full screen first if the app restored into it.
sysev() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to $1" 2>/dev/null; }
for i in $(seq 1 15); do [ -n "$("$P/winsize" $pid)" ] && break; sleep 1; done   # wait for the window
sleep 1
for i in 1 2 3 4; do
  read W H Y <<< "$("$P/winsize" $pid)"
  if [ "${Y:-0}" = "33" ] && [ "${H:-0}" -ge 940 ]; then   # full screen: leave it
    sysev 'tell (first window whose title is "Satchel") to click (first button whose subrole is "AXFullScreenButton")' >/dev/null; sleep 3.5; continue
  fi
  sysev 'tell (first window whose title is "Satchel") to set position to {0, 33}' >/dev/null
  sysev 'tell (first window whose title is "Satchel") to set size to {1512, 884}' >/dev/null
  sleep 1.2
  read W H Y <<< "$("$P/winsize" $pid)"
  [ "${W:-0}" -ge 1500 ] && [ "${H:-0}" -ge 880 ] && [ "${H:-0}" -le 900 ] && break
done
echo "window ${W:-?}x${H:-?} at y=${Y:-?} pid=$pid"
