#!/bin/zsh
# The menu: every entry plays its own icon motion when chosen; collapsed, the rails show a label beside each icon.
set -e
U=./ui
$U move 900 700 10;                         sleep 0.7
$U move 176 128 600;                        sleep 0.3          # Overview
$U move 176 164 300; $U click;              sleep 0.75         # All items
$U move 176 200 260; $U click;              sleep 0.75         # Favorites
$U move 176 236 260; $U click;              sleep 0.75         # Recent
$U move 176 309 260; $U click;              sleep 0.6          # categories
$U move 176 345 240; $U click;              sleep 0.6
$U move 176 381 240; $U click;              sleep 0.6
$U move 176 528 300; $U click;              sleep 0.75         # Login
$U move 176 563 240; $U click;              sleep 0.75         # API Key
$U move 176 599 240; $U click;              sleep 0.75         # Database
$U move 176 635 240; $U click;              sleep 0.75         # Webhook
$U move 176 671 240; $U click;              sleep 0.75         # Secure Note
$U move 176 707 240; $U click;              sleep 0.9          # SSH Key
$U move 106 53 450;  sleep 0.2; $U click;   sleep 1.1          # collapse the menu
$U move 88 100 450;  sleep 0.9
$U move 88 142 220;  sleep 0.75
$U move 88 184 220;  sleep 0.75
$U move 88 226 220;  sleep 0.75
$U move 26 149 350;  sleep 0.9                                  # workspace rail
$U move 26 201 220;  sleep 0.75
$U move 26 253 220;  sleep 0.75
$U move 106 53 450;  sleep 0.2; $U click;   sleep 1.2          # expand again
$U move 900 800 500;                        sleep 0.6
