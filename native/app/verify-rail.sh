#!/usr/bin/env bash
# Rail transitions and the FILES header against the dev stack (run-dev.sh): every rail item -> every rail item (8 x 8)
# must show exactly the target's screen (no stale page, no stale Files screen), and the FILES header must collapse/expand
# the tree in Control and in Files mode and keep that state across the rail. Screenshots dark + light into screenshots/.
# Needs a logged-in GUI session. Stops its own stack when it ends.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-rail.XXXXXX)
SHOTS=$PWD/screenshots; mkdir -p "$SHOTS"
STATE=$TMPDIR/muya-native-dev.state
trap './run-dev.sh stop >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM
[ -f "$STATE" ] || ./run-dev.sh start >/dev/null
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
FAILS=0
expect() { if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi; }
shot() { dbg "snap $SHOTS/$1.png" >/dev/null; echo "shot $1"; }

dbg "new $HOME" >/dev/null; sleep 1.5
ITEMS=(Control Files Sessions Queue Kanban Resources SSH Schedules)
n=0
for a in "${ITEMS[@]}"; do for b in "${ITEMS[@]}"; do
  dbg "rail $a" >/dev/null; sleep 0.12; dbg "rail $b" >/dev/null; sleep 0.12; r=$(dbg screens); n=$((n + 1))
  case $b in
    Control) want="pages=- filesScreen=false rail=Control";; Files) want="pages=- filesScreen=true rail=Files";;
    Sessions) want="pages=sessions filesScreen=false rail=Sessions";; Queue) want="pages=queue filesScreen=false rail=Queue";;
    Kanban) want="pages=queue filesScreen=false rail=Kanban";; Resources) want="pages=resources filesScreen=false rail=Resources";;
    SSH) want="pages=ssh filesScreen=false rail=SSH";; Schedules) want="pages=schedules filesScreen=false rail=Schedules";;
  esac
  [[ "$r" == "$want"* ]] || { echo "FAIL $a -> $b: $r"; FAILS=$((FAILS + 1)); }
done; done
echo "rail: $n transitions checked"

echo "--- FILES header"
dbg "rail Control" >/dev/null; dbg "p4-files 1" >/dev/null; sleep 0.4
expect "Control: tree open" "$(dbg screens)" "expanded=true"
both() { dbg "appearance dark" >/dev/null; sleep 1.2; shot "$1-dark"; dbg "appearance light" >/dev/null; sleep 1.2; shot "$1-light"; }
both rail-control-files-open
expect "Control: click collapses" "$(dbg p4-files-click)" "expanded=false"; sleep 0.4
both rail-control-files-collapsed
expect "Control: click expands again" "$(dbg p4-files-click)" "expanded=true"; sleep 0.3
dbg "p4-files-click" >/dev/null   # collapsed; the state must survive the rail
dbg "rail Files" >/dev/null; sleep 0.4
expect "Files mode keeps the collapsed state" "$(dbg screens)" "expanded=false"
both rail-files-files-collapsed
expect "Files mode: click expands" "$(dbg p4-files-click)" "expanded=true"; sleep 0.4
both rail-files-files-open
dbg "rail Control" >/dev/null; sleep 0.4
expect "Files -> Control shows Control" "$(dbg screens)" "pages=- filesScreen=false rail=Control"
expect "state survives Files -> Control" "$(dbg screens)" "expanded=true"
both rail-files-to-control
echo "FAILS=$FAILS"; exit $((FAILS > 0))
