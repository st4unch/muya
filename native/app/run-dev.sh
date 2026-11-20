#!/usr/bin/env bash
# Dev stack for the native app: muya-ptyd + muyad (debug builds from native/target/debug) in a
# throwaway HOME with its own sockets, and MuyaNative.app pointed at them. Nothing here touches
# the installed Muya.app or its sidecars; `stop` kills exactly the PIDs this script started.
#
#   run-dev.sh [start]   start ptyd + muyad + the app, print the PIDs
#   run-dev.sh app       (re)start only the app against the running daemons
#   run-dev.sh status    show the recorded PIDs and whether they are alive
#   run-dev.sh stop      kill the recorded PIDs, remove the temp dir
#   MUYA_DEV_NO_APP=1 run-dev.sh start   daemons only (tests drive them directly)
#   MUYAD_ARGS=--scheduler run-dev.sh start   extra muyad flags
#   MUYA_APP_ARGS="-AppleKeyboardUIMode 3"   extra app arguments (here: Full Keyboard Access on)
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
NATIVE=$(cd .. && pwd)
STATE=${TMPDIR:-/tmp}/muya-native-dev.state
BIN=${MUYA_BIN_DIR:-$NATIVE/target/debug} # MUYA_BIN_DIR=<dir with muya-ptyd + muyad> to run release builds
APP_BIN=$HERE/build/MuyaNative.app/Contents/MacOS/MuyaNative

say() { echo "run-dev: $*" >&2; }

load() { [ -f "$STATE" ] && . "$STATE"; return 0; }
save() { printf 'DEV=%q\nPTYD_PID=%q\nMUYAD_PID=%q\nAPP_PID=%q\n' "${DEV:-}" "${PTYD_PID:-}" "${MUYAD_PID:-}" "${APP_PID:-}" > "$STATE"; }

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# Kills one recorded PID, but only if it still runs the program we started (PIDs get reused).
stop_pid() { # pid, expected substring of its command
  local pid=${1:-} want=$2
  alive "$pid" || return 0
  local cmd; cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
  case "$cmd" in
    *"$want"*) kill "$pid" 2>/dev/null || true
               for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$pid" || return 0; sleep 0.2; done
               kill -9 "$pid" 2>/dev/null || true ;;
    *) say "pid $pid is no longer $want ('$cmd'); leaving it alone" ;;
  esac
}

start_daemons() {
  [ -x "$BIN/muya-ptyd" ] && [ -x "$BIN/muyad" ] || { say "build them first: (cd native && cargo build -p muya-ptyd -p muyad)"; exit 1; }
  DEV=$(mktemp -d "${TMPDIR:-/tmp}/muya-dev.XXXXXX")
  DEV=$(cd "$DEV" && pwd -P) # physical path: zsh only abbreviates $HOME to ~ when $PWD matches it literally
  mkdir -p "$DEV/home/projects/api" "$DEV/home/projects/web" "$DEV/home/notes"
  : > "$DEV/home/projects/api/main.rs"; : > "$DEV/home/projects/api/Cargo.toml"; : > "$DEV/home/projects/web/index.html"; : > "$DEV/home/notes/todo.md"
  # A short prompt without user or host name.
  printf "PROMPT='%%~ %%# '\nunsetopt BEEP PROMPT_SP\n" > "$DEV/home/.zshrc"
  export HOME=$DEV/home
  nohup "$BIN/muya-ptyd" --socket "$DEV/ptyd.sock" >"$DEV/ptyd.log" 2>&1 &
  PTYD_PID=$!
  for _ in $(seq 50); do [ -S "$DEV/ptyd.sock" ] && break; sleep 0.1; done
  # Default `--broker` = the flags of the shipped LaunchAgent (scripts/bundle/LaunchAgents); MUYAD_ARGS replaces them.
  # MUYAD_ARGS="--broker --scheduler" etc. are passed on (the Faz 4a checks run the schedule timers in muyad).
  # shellcheck disable=SC2086
  nohup "$BIN/muyad" --socket "$DEV/muyad.sock" --ptyd "$DEV/ptyd.sock" ${MUYAD_ARGS---broker} >"$DEV/muyad.log" 2>&1 &
  MUYAD_PID=$!
  for _ in $(seq 50); do [ -S "$DEV/muyad.sock" ] && break; sleep 0.1; done
  [ -S "$DEV/muyad.sock" ] || { say "muyad did not come up:"; cat "$DEV/muyad.log" >&2; save; exit 1; }
  APP_PID=
  save
  say "ptyd pid $PTYD_PID, muyad pid $MUYAD_PID, dir $DEV"
}

start_app() {
  load
  [ -n "${DEV:-}" ] && [ -S "$DEV/muyad.sock" ] || { say "no running daemons; use start"; exit 1; }
  [ -x "$APP_BIN" ] || { say "build the app first: native/app/build.sh"; exit 1; }
  alive "${APP_PID:-}" && { say "app already running (pid $APP_PID)"; return; }
  # The throwaway HOME also keeps AppKit's saved state and defaults away from the real home.
  # MUYA_APP_ARGS="-AppleKeyboardUIMode 3" runs the app with Full Keyboard Access on (a process-local default; the real setting is untouched).
  # shellcheck disable=SC2086
  HOME=$DEV/home MUYA_SOCKET=$DEV/muyad.sock MUYA_DEBUG_SOCKET=$DEV/app-debug.sock \
    nohup "$APP_BIN" ${MUYA_APP_ARGS:-} >"$DEV/app.log" 2>&1 &
  APP_PID=$!
  save
  say "app pid $APP_PID (debug socket $DEV/app-debug.sock)"
}

case "${1:-start}" in
  start)
    load
    if alive "${MUYAD_PID:-}"; then say "already running (see status)"; exit 1; fi
    start_daemons
    [ -n "${MUYA_DEV_NO_APP:-}" ] || start_app
    echo "PTYD_PID=$PTYD_PID MUYAD_PID=$MUYAD_PID APP_PID=${APP_PID:-} DEV=$DEV"
    ;;
  app) start_app; echo "APP_PID=$APP_PID" ;;
  status)
    load
    for n in PTYD MUYAD APP; do v=${n}_PID; alive "${!v:-}" && echo "$n ${!v} alive" || echo "$n ${!v:-} not running"; done
    echo "DEV=${DEV:-}"
    ;;
  stop)
    load
    stop_pid "${APP_PID:-}" "MuyaNative"
    stop_pid "${MUYAD_PID:-}" "/muyad"
    stop_pid "${PTYD_PID:-}" "/muya-ptyd"
    [ -n "${DEV:-}" ] && case "$DEV" in */muya-dev.*) rm -rf "$DEV" ;; esac
    rm -f "$STATE"
    say "stopped"
    ;;
  *) echo "usage: run-dev.sh [start|app|status|stop]" >&2; exit 2 ;;
esac
