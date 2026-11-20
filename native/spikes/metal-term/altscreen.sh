#!/bin/sh
# S1 alt screen check: main screen text, then the alternate screen, then back (main must be intact).
printf 'MAIN SCREEN line 1\r\nMAIN SCREEN line 2 \033[32mgreen\033[0m\r\n'
sleep 2
printf '\033[?1049h\033[2J\033[H\033[44m  ALT SCREEN (like vim / less)  \033[0m\r\n\033[5;10H\033[1;33mcursor-addressed text\033[0m'
sleep 3
printf '\033[?1049l'
sleep 30
