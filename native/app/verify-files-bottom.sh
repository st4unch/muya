#!/usr/bin/env bash
# The FILES section sits at the BOTTOM of the left column, like classic (collapsed: the header alone, flush with the bottom
# edge; open: it grows upward over the column). Files screen with open files + Control screen, collapsed and open, dark and
# light. Screenshots land in screenshots/files-bottom-*. Needs a logged-in GUI session; dev stack in a throwaway HOME.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-fb.XXXXXX)
SHOTS=$PWD/screenshots; mkdir -p "$SHOTS"
trap './run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$TMPDIR"' EXIT
trap 'exit 130' INT TERM
./run-dev.sh start >/dev/null
. "$TMPDIR/muya-native-dev.state"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
shot() { screencapture -x -o -l "$(dbg windowid)" "$SHOTS/$1.png"; echo "shot $1"; }
both() { dbg "appearance dark" >/dev/null; sleep 1.2; shot "$1-dark"; dbg "appearance light" >/dev/null; sleep 1.2; shot "$1-light"; }
sleep 2.5
FIX=$DEV/home/view; python3 -I make-fixtures.py "$FIX"
SID=$(dbg "new $FIX" | awk '{print $2}'); sleep 1.5
dbg "files-open $FIX/README.txt" >/dev/null; sleep 0.4; dbg "files-open $FIX/src/main.rs" >/dev/null; sleep 0.6
for i in 2 3; do mkdir -p "$DEV/home/view$i"; dbg "new $DEV/home/view$i" >/dev/null; sleep 1; done
dbg "select $SID" >/dev/null; sleep 0.5
dbg "p4-files 0" >/dev/null
dbg "rail Files" >/dev/null; sleep 0.8
both files-bottom-files-collapsed
dbg "p4-files 1" >/dev/null; sleep 0.6
both files-bottom-files-open
dbg "rail Control" >/dev/null; sleep 0.6
both files-bottom-control-open
dbg "p4-files 0" >/dev/null; sleep 0.6
both files-bottom-control-collapsed
