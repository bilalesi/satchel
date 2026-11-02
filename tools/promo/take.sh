#!/bin/zsh
# take.sh NAME SECONDS SCENE.sh : bring the demo to the front, check it, record the screen, run the scene.
# Aborts (and records nothing) unless the demo app is really the front app of the visible screen.
set -u
cd "$(dirname "$0")"
NAME=$1; SECS=$2; SCENE=$3
ID="com.bilalesi.satchel.demo"
pid=$(pgrep -f "build/demo/Satchel.app/Contents/MacOS/Satchel" | head -1)
[ -n "$pid" ] || { echo "demo not running"; exit 2; }
osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '$pid') to true'
sleep 2.5
front=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
[ "$front" = "$ID" ] || { echo "ABORT: front app is $front"; exit 3; }
# The app must be in real full screen, filling the display, or nothing is recorded.
read W H Y <<< "$(./winsize $pid)"
[ "${W:-0}" -ge 1500 ] && [ "${H:-0}" -ge 880 ] || { echo "ABORT: window is not at full size (window ${W:-?}x${H:-?})"; exit 5; }
export DEMO_PID=$pid
rm -f "$NAME.mov"
./ui move 900 900 10
START=$(date +%s)
(screencapture -v -V "$SECS" -x -R0,0,1512,917 "$NAME.mov" >cap.log 2>&1 &)
sleep 1.5
"./$SCENE" || { echo "scene aborted"; pkill screencapture; exit 4; }
LEFT=$((START + SECS + 3 - $(date +%s))); [ $LEFT -gt 0 ] && sleep $LEFT   # let the recorder finish
ls -la "$NAME.mov" | awk '{print $5}'
