#!/bin/zsh
# Quick Access: open it from the main menu, search, choose, close.
set -e
U=./ui
$U move 900 700 10;                         sleep 0.8
$U move 86 882 700; sleep 0.3; $U click;    sleep 1.3          # the main menu
$U move 208 665 500; sleep 0.4; $U click;   sleep 1.6          # Quick Access
$U type "a";                                sleep 1.3
$U type "m";                                sleep 1.3
$U key 125;                                 sleep 0.9          # down
$U type "a";                                sleep 1.2
$U key 53;                                  sleep 1.0          # Escape closes it
$U move 900 800 500;                        sleep 0.6
