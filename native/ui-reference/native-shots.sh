#!/usr/bin/env bash
# Screenshots of the running native dev app (run-dev.sh stack; TMPDIR selects the state file) in the names
# native/tools/ui-diff/map.json expects, for both themes at 1120x732 and 1440x900 (content size, points).
#   native-shots.sh OUTDIR        -> OUTDIR/1120x732/<name>-<theme>.png, OUTDIR/1440x900/...   (MUYA_SHOT_SELECT=2 selects session 2: muya-all in the mock mode)
set -euo pipefail
OUT=${1:?outdir}
STATE=${TMPDIR:-/tmp}/muya-native-dev.state
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 5 "$DEV/app-debug.sock"; }
# MUYA_SHOT_SNAP=1: render the window in-process (`snap`, works with the screen locked; the Metal terminal area stays empty)
cap() { if [ -n "${MUYA_SHOT_SNAP:-}" ]; then dbg "snap $1" >/dev/null; else screencapture -x -o -l "$(dbg windowid)" "$1"; fi; }
dbg "toast-lift off" >/dev/null 2>&1 || true   # a window-id capture leaves the lifted toast panels out: keep the toast in the window while shooting
for size in 1120x732 1440x900; do
  mkdir -p "$OUT/$size"
  dbg "window ${size%x*} ${size#*x}" >/dev/null; sleep 1
  for theme in dark light; do
    dbg "appearance $theme" >/dev/null; sleep 1.5
    dbg "grid off" >/dev/null; dbg "select ${MUYA_SHOT_SELECT:-1}" >/dev/null; sleep 0.6
    cap "$OUT/$size/app-$theme.png"
    dbg "select $(dbg sessions | awk -F'\t' '$2 ~ /^documents/ {print $1; exit}')" >/dev/null; dbg "grid on" >/dev/null; sleep 1   # the reference grid's focused panel is the first one (documents-44); native focus follows the selection
    cap "$OUT/$size/grid-$theme.png"
    dbg "grid off" >/dev/null
    dbg "rail Files" >/dev/null; sleep 1; cap "$OUT/$size/files-tree-$theme.png"; dbg "rail Control" >/dev/null; sleep 0.5
    # pages (rail items) — same names as the reference views
    for pair in "Sessions:sessions" "Queue:queue" "Kanban:kanban" "Resources:resources" "SSH:ssh-servers" "Schedules:schedules"; do
      dbg "rail ${pair%%:*}" >/dev/null; sleep 1.2; cap "$OUT/$size/${pair##*:}-$theme.png"; dbg "rail Control" >/dev/null; sleep 0.4
    done
  done
done
if [ -n "${MUYA_SHOT_MORE:-}" ]; then   # the overlay screens: captured as a screen rectangle of the main window (popovers, sheets and dialogs are child windows)
  for size in 1120x732 1440x900; do
    dbg "window ${size%x*} ${size#*x}" >/dev/null; sleep 1
    for theme in dark light; do
      dbg "appearance $theme" >/dev/null; sleep 1.2
      rect() { set -- $(dbg "window-rect"); screencapture -x -R "$1,$2,$3,$4" "$OUT/$size/$NAME-$theme.png" 2>/dev/null || screencapture -x -o -l "$(dbg windowid)" "$OUT/$size/$NAME-$theme.png"; }   # the window id capture works where a screen rectangle does not (locked screen)
      front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1 || true; sleep 0.3; }
      front
      dbg "rail Control" >/dev/null; dbg "grid off" >/dev/null
      dbg "queue-page branches" >/dev/null; sleep 1.2; NAME=branches rect; dbg "rail Control" >/dev/null
      dbg "rail SSH" >/dev/null; dbg "ssh-section cyberark" >/dev/null; sleep 1; NAME=ssh-cyberark rect
      dbg "ssh-section vault" >/dev/null; sleep 1; NAME=ssh-store rect; dbg "rail Control" >/dev/null
      dbg "rail Resources" >/dev/null; dbg "resources-tab marketplace" >/dev/null; sleep 1.5; NAME=resources-marketplace rect; dbg "rail Control" >/dev/null
      dbg "palette-open" >/dev/null; sleep 1; NAME=palette rect; dbg "palette-close" >/dev/null
      dbg "newagent-open" >/dev/null; sleep 1.2; NAME=new-agent rect; dbg "newagent-close" >/dev/null
      dbg "notifications-open" >/dev/null; sleep 1; NAME=notifications rect; dbg "popover-close" >/dev/null
      dbg "rail Sessions" >/dev/null; sleep 1; dbg "cleanup-open" >/dev/null; sleep 1.2; NAME=sessions-cleanup rect; dbg "cleanup-close" >/dev/null; dbg "rail Control" >/dev/null
      id=$(dbg "settings-open"); sleep 1.2; screencapture -x -o -l "$id" "$OUT/$size/settings-$theme.png"; dbg "settings-close" >/dev/null
    done
  done
fi
echo "shots in $OUT"
