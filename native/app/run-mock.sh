#!/usr/bin/env bash
# Starts MuyaNative.app in the dev MOCK mode (Sources/App/Mock.swift): no daemons, the sessions/statuses/folder/counts of the
# web UI's mock data, a throwaway HOME. Writes the same state file as run-dev.sh (DEV, APP_PID) so native-shots.sh,
# measure scripts and `nc -U $DEV/app-debug.sock` work unchanged.
#   TMPDIR=<private dir> native/app/run-mock.sh start [path/to/MuyaNative.app]   (default build/MuyaNative.app)
#   TMPDIR=<private dir> native/app/run-mock.sh stop
# Then:  TMPDIR=<same> native/ui-reference/native-shots.sh OUTDIR  and  python3 native/tools/ui-diff/baseline.py --native-dir OUTDIR/1120x732
set -euo pipefail
cd "$(dirname "$0")"
STATE=${TMPDIR:-/tmp}/muya-native-dev.state
case "${1:-start}" in
  start)
    APP=${2:-$PWD/build/MuyaNative.app}
    DEV=$(mktemp -d "${TMPDIR:-/tmp}/muya-mock.XXXXXX"); DEV=$(cd "$DEV" && pwd -P)
    mkdir -p "$DEV/home"
    HOME=$DEV/home MUYA_MOCK=1 MUYA_SOCKET=$DEV/none.sock MUYA_DEBUG_SOCKET=$DEV/app-debug.sock nohup "$APP/Contents/MacOS/MuyaNative" >"$DEV/app.log" 2>&1 &
    PID=$!
    printf 'DEV=%q\nPTYD_PID=\nMUYAD_PID=\nAPP_PID=%q\n' "$DEV" "$PID" > "$STATE"
    for _ in $(seq 40); do [ -S "$DEV/app-debug.sock" ] && break; sleep 0.25; done
    echo "run-mock: app pid $PID, dir $DEV" ;;
  stop)
    [ -f "$STATE" ] || exit 0
    . "$STATE"
    case "$(ps -o command= -p "${APP_PID:-0}" 2>/dev/null)" in *MuyaNative*) kill "$APP_PID" ;; esac
    case "$DEV" in */muya-mock.*) rm -rf "$DEV" ;; esac
    rm -f "$STATE"; echo "run-mock: stopped" ;;
esac
