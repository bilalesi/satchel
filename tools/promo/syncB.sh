#!/bin/zsh
# Sync: Settings, the five ways to sync, a synced folder, test, save, sync now (the notch announces the end).
set -e
U=./ui
PID=$(pgrep -f "build/demo/Satchel.app/Contents/MacOS/Satchel" | head -1)
$U move 900 700 10;                       sleep 0.8
$U move 265 882 600; sleep 0.3; $U click;  sleep 1.8       # the gear: Settings
read X Y W H <<< "$(./winfind $PID)"
[ -n "${X:-}" ] || { echo "Settings window not found"; exit 1; }   # never click blind
$U move $((X+277)) $((Y+60)) 700; $U click;  sleep 1.0     # Sync tab
$U move $((X+420)) $((Y+133)) 500; $U click; sleep 1.3     # the methods
PX=$((X+310)); PY=$((Y+152))
for i in 0 1 2 3 4 5; do $U move $((PX+155)) $((PY+25+40*i)) 300; sleep 0.6; done
$U move $((PX+155)) $((PY+65)) 350; $U click; sleep 1.0    # Synced folder
$U move $((X+260)) $((Y+181)) 450; $U tclick;                                sleep 0.3        # select the whole path
$U type "/tmp/Dropbox/Satchel";           sleep 0.8
$U move $((X+67)) $((Y+276)) 450; $U click;  sleep 1.8     # Test
$U move $((X+150)) $((Y+276)) 300; $U click; sleep 1.2     # Save
$U move $((X+476)) $((Y+276)) 350; $U click; sleep 3.0     # Sync now: notch card
$U move $((X+16)) $((Y+16)) 450; $U click; sleep 1.0       # close Settings
$U move 176 128 500; $U click;            sleep 1.6        # Overview: the Sync card
$U move 900 800 500;                      sleep 0.8
