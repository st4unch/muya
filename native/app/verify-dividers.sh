#!/usr/bin/env bash
# No stray divider on any screen: in the mock-mode app (run-mock.sh), for every rail page, the grid and the control view, in dark and light
# at both sizes, no split view may have a hidden pane AND a divider (`dump-views thin`), and no visible 1-2 px wide view may be taller than
# 100 px. A divider left behind by a hidden pane is the thin vertical line down the middle of every screen.
#   TMPDIR=<private dir> native/app/verify-dividers.sh [path/to/MuyaNative.app]
set -euo pipefail
cd "$(dirname "$0")"
STATE=${TMPDIR:-/tmp}/muya-native-dev.state
./run-mock.sh start "${1:-$PWD/build/MuyaNative.app}" >/dev/null
trap './run-mock.sh stop >/dev/null' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 5 "$DEV/app-debug.sock"; }
bad=0; n=0
check() { # label
  local d; d=$(dbg "dump-views thin")
  n=$((n + 1))
  if echo "$d" | grep "hidden-subviews=[1-9]" | grep -v "divider=0.0" | grep -q .; then echo "FAIL $1: a split keeps its divider next to a hidden pane"; echo "$d" | grep "hidden-subviews"; bad=$((bad + 1)); fi
  # The Resources page draws a real 1 px rule between its list and its detail (as today's page does): not checked there.
  if [[ "$1" != Resources* ]] && echo "$d" | awk '/NSTextInsertionIndicator/ {next} { for (i = 1; i <= NF; i++) { if ($i ~ /^w=/) w = substr($i, 3); if ($i ~ /^h=/) h = substr($i, 3) } if (!/NSSplitView|InspectorSplit/ && w + 0 <= 2 && h + 0 > 100) bad = 1 } END { exit bad ? 0 : 1 }'; then echo "FAIL $1: a visible 1-2 px wide view is taller than 100 px"; bad=$((bad + 1)); fi
}
for size in "1120 732" "1440 900"; do
  dbg "window $size" >/dev/null
  for theme in dark light; do
    dbg "appearance $theme" >/dev/null; sleep 1
    dbg "grid off" >/dev/null; for item in Control Files Sessions Queue Kanban Resources SSH Schedules; do dbg "rail $item" >/dev/null; sleep 0.6; check "$item $theme $size"; done
    dbg "rail Control" >/dev/null; dbg "grid on" >/dev/null; sleep 1; check "grid $theme $size"; dbg "grid off" >/dev/null
  done
done
[ "$bad" = 0 ] && echo "verify-dividers: $n screens, no stray divider" || { echo "verify-dividers: $bad failures"; exit 1; }
