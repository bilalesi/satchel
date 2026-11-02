#!/bin/zsh
# Selective sync: a lock marks what stays on this Mac; each secret has its own allow / keep button; Settings has the
# per-category switches.
set -e
U=./ui
PID=$(pgrep -f "build/demo/Satchel.app/Contents/MacOS/Satchel" | head -1)
menu() { # menu ROW : pick row 0..2 of the card that just opened
  read MX MY MW MH <<< "$(./winfind $PID any)"
  [ -n "${MX:-}" ] || { echo "menu not found"; exit 1; }
  $U move $((MX+126)) $((MY+25+40*$1)) 450; sleep 0.5; $U click
}
$U move 900 700 10;                         sleep 0.8
$U move 176 309 700; $U click;              sleep 1.3          # Banking: its items are marked
$U move 470 163 500; $U click;              sleep 1.4          # Checking account: "Local only"
$U move 1067 117 600; sleep 0.5; $U click;  sleep 1.4          # the secret's own button
menu 1;                                     sleep 1.8          # Allow sync
$U move 176 345 600; $U click;              sleep 1.0          # Shopping
$U move 470 163 450; $U click;              sleep 1.4          # Amazon: "Sync allowed"
$U move 1067 117 600; sleep 0.5; $U click;  sleep 1.4
menu 2;                                     sleep 2.0          # Keep on this Mac: the lock appears
$U move 265 882 700; sleep 0.3; $U click;   sleep 1.8          # Settings
read X Y W H <<< "$(./winfind $PID)"
[ -n "${X:-}" ] || { echo "Settings window not found"; exit 1; }
$U move $((X+277)) $((Y+60)) 500; $U click; sleep 1.3          # Sync tab: what to sync on this Mac
$U move $((X+512)) $((Y+545)) 600; sleep 0.5; $U click; sleep 1.4   # Streaming off
$U move $((X+512)) $((Y+422)) 450; sleep 0.4; $U click; sleep 1.6   # Banking on
$U move $((X+16)) $((Y+16)) 500; $U click;  sleep 1.0
$U move 900 800 500;                        sleep 0.6
