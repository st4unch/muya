#!/bin/sh
# S1 render check: 24-bit color, 256 colors, styles, wide CJK, emoji, box drawing, Turkish.
printf '\033[1mBold\033[0m \033[3mItalic\033[0m \033[4mUnderline\033[0m \033[7mInverse\033[0m \033[2mFaint\033[0m \033[9mStrike\033[0m\r\n'
i=0; while [ $i -lt 72 ]; do printf "\033[48;2;%d;%d;%dm \033[0m" $((i*3)) $((255-i*3)) 128; i=$((i+1)); done; printf '\r\n'
i=0; while [ $i -lt 72 ]; do printf "\033[48;5;%dm \033[0m" $((16+i*3)); i=$((i+1)); done; printf '\r\n'
printf 'Türkçe: ğüşıöç ĞÜŞİÖÇ  日本語テキスト 中文字符 한국어  Emoji: 😀 🚀 ✅ 👍🏽 🇹🇷\r\n'
printf '┌──────┬──────┐  ╭────╮  ▁▂▃▄▅▆▇█  ⣿⡇ \r\n│ box  │ draw │  │ ok │  ░▒▓  →←↑↓ ✓✗\r\n└──────┴──────┘  ╰────╯\r\n'
printf '\033[38;2;255;128;0morange 24-bit\033[0m \033[38;5;45mcyan 256\033[0m \033[31mred\033[32mgreen\033[34mblue\033[0m\r\n'
printf 'wide test: [日本]|[ab]|[😀]|\r\n'
sleep 30
