#!/usr/bin/env bash
# End-to-end check of the native app against a throwaway dev stack (run-dev.sh): spawns three
# sessions, types into them through the app's input path, screenshots both appearances, then
# kill -9s the app and relaunches it to show the sessions come back with their screens (AC9 shape).
# Needs a logged-in GUI session. Stops its own stack when it ends.
set -euo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-v.XXXXXX)  # its own dir per run: the default /tmp state file collides with any other running dev stack
SHOTS=$PWD/screenshots
mkdir -p "$SHOTS"
STATE=${TMPDIR:-/tmp}/muya-native-dev.state
trap './run-dev.sh stop >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped

[ -f "$STATE" ] || ./run-dev.sh start >/dev/null
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 3 "$DEV/app-debug.sock"; }
for _ in $(seq 60); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.25; done # a fresh stack: wait for the app
for _ in $(seq 40); do case "$(dbg "new $DEV/home" 2>/dev/null)" in ok*) dbg "close $(dbg sessions | tail -1 | cut -f1)" >/dev/null; break ;; esac; sleep 0.25; done
shot() { screencapture -x -o -l "$(dbg windowid)" "$SHOTS/$1.png"; echo "shot $1"; }
both() { # name
  dbg "appearance dark"; sleep 1.5; shot "$1-dark"
  dbg "appearance light"; sleep 1.5; shot "$1-light"
}

if [ -z "$(dbg sessions)" ]; then
  dbg "new $DEV/home/projects/api" >/dev/null
  dbg "new $DEV/home/projects/web" >/dev/null
  dbg "new $DEV/home" >/dev/null
  sleep 0.8
  dbg "select 1" >/dev/null; dbg 'type "echo hello; ls\n"' >/dev/null
  dbg "select 2" >/dev/null; dbg 'type "ls | head -5\n"' >/dev/null
  dbg "select 3" >/dev/null; dbg 'type "printf \"\\033[31mred \\033[32mgreen \\033[1;34mbold-blue\\033[0m  \\033[4munderline\\033[0m  ş ğ 日本語 🇹🇷\\n\"\n"' >/dev/null
  sleep 0.8
fi
dbg "select 1" >/dev/null; sleep 0.4
echo "--- sessions before"; dbg sessions | tee "$DEV/before.txt"
echo "--- screen of session 1"; dbg text | tee "$DEV/screen1-before.txt"
both app

echo "--- kill -9 the app (pid $APP_PID) and relaunch"
kill -9 "$APP_PID"; sleep 0.5
./run-dev.sh app >/dev/null; . "$STATE"
for _ in $(seq 40); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg sessions 2>/dev/null)" ] && break; sleep 0.25; done
sleep 0.8
echo "--- sessions after"; dbg sessions | tee "$DEV/after.txt"
echo "--- screen of session 1 after relaunch"; dbg text | tee "$DEV/screen1-after.txt"
diff <(cut -f1-3 "$DEV/before.txt") <(cut -f1-3 "$DEV/after.txt") && echo "SAME sessions (id, name, cwd) after relaunch"
diff "$DEV/screen1-before.txt" "$DEV/screen1-after.txt" && echo "SAME screen text for session 1 after relaunch"
both relaunch

echo "--- colours, wide glyphs and emoji (session 3)"
dbg "select 3" >/dev/null; sleep 0.5
both colors
