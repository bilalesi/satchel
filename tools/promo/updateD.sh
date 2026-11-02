#!/bin/zsh
# Updates: Check now finds a newer version, the notch announces it, the footer shows the update icon, the
# main menu says "0.2.0 available". Nothing is installed.
set -e
U=./ui
PID=$(pgrep -f "build/demo/Satchel.app/Contents/MacOS/Satchel" | head -1)
$U move 900 700 10;                       sleep 0.8
$U move 265 882 600; sleep 0.3; $U click;  sleep 1.8       # the gear: Settings (General)
read X Y W H <<< "$(./winfind $PID)"
[ -n "${X:-}" ] || { echo "Settings window not found"; exit 1; }
python3 -m http.server 8765 --directory feed >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 0.8
$U move $((X+481)) $((Y+323)) 700; sleep 0.5; $U click; sleep 3.6   # Check now: the notch card
$U move $((X+16)) $((Y+16)) 500; $U click; sleep 1.0       # close Settings
$U move 230 882 700;                      sleep 2.0        # the update icon and its label
$U move 86 882 500; $U click;             sleep 2.6        # the main menu: "0.2.0 available"
$U key 53;                                sleep 1.0        # Escape
$U move 900 800 500;                      sleep 0.6
