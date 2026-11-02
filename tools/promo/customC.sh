#!/bin/zsh
# Make it yours: right-click a menu entry, change its icon and colour (the tile plays its motion), then add a category.
set -e
U=./ui
PID=$(pgrep -f "build/demo/Satchel.app/Contents/MacOS/Satchel" | head -1)
$U move 900 700 10;                         sleep 0.8
$U move 176 200 700;                        sleep 0.6
$U rclick;                                  sleep 1.0          # context menu on Favorites
$U move 246 214 350; $U click;              sleep 1.4          # "Change icon and colour…"
read X Y W H <<< "$(./winfind $PID any)"
[ -n "${X:-}" ] || { echo "card not found"; exit 1; }
$U move $((X+166)) $((Y+77)) 600; $U click; sleep 0.9          # teal
$U move $((X+131)) $((Y+145)) 500; $U click; sleep 1.3         # the shield (it plays its motion)
$U move $((X+63)) $((Y+113)) 500; $U click; sleep 1.0          # a different one
$U move $((X+97)) $((Y+145)) 450; $U click; sleep 1.3          # the padlock
$U key 53;                                  sleep 1.0          # Escape closes the card
$U move 269 278 700; $U click;              sleep 1.0          # + : a new category
$U type "Launch day";                       sleep 0.8
$U key 36;                                  sleep 1.6          # Return
$U move 900 800 600;                        sleep 0.8
