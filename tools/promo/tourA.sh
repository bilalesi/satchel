#!/bin/zsh
# A quick tour: Personal (favorites, a category, an item with its live code), then a locked workspace, the
# notch card, and the Work workspace (categories, a database login, an API key, an SSH key).
set -e
U=./ui
$U move 900 900 10;                sleep 0.8
$U move 176 200 800; $U click;     sleep 1.0      # Favorites
$U move 176 309 450; $U click;     sleep 0.8      # Banking
$U move 470 163 450; $U click;     sleep 1.5      # Checking account (live code)
$U move 176 128 450; $U click;     sleep 0.7      # Overview
$U move 26 149 600;  $U click;     sleep 2.2      # Work: locked, notch card
$U move 739 537 500; $U click;     sleep 0.4
$U type demo-password-123;         sleep 0.5
$U key 36;                         sleep 2.0      # Return: unlocked
$U move 176 381 700; $U click;     sleep 0.9      # Infrastructure
$U move 470 211 450; $U click;     sleep 1.4      # Postgres production
$U move 176 453 450; $U click;     sleep 0.9      # Payments
$U move 470 163 450; $U click;     sleep 1.4      # Stripe live key
$U move 176 707 500; $U click;     sleep 0.9      # SSH Key type
$U move 470 163 450; $U click;     sleep 1.6      # a key
$U move 176 128 450; $U click;     sleep 0.8      # Overview
$U move 900 900 500;               sleep 0.8
