#!/usr/bin/env bash
# End-to-end check of the file tree and the native viewers against the dev stack (run-dev.sh), plus AC15
# (no WebKit in the process). Builds a fixture folder under the throwaway HOME, drives the real app through the
# debug socket, asserts, measures app CPU / RSS per step and screenshots dark + light.
# Needs a logged-in GUI session. Stops its own stack when it ends.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-files.XXXXXX)  # its own dir per run: the default /tmp state file collides with any other running dev stack
SHOTS=$PWD/screenshots
mkdir -p "$SHOTS"
STATE=${TMPDIR:-/tmp}/muya-native-dev.state
trap './run-dev.sh stop >/dev/null 2>&1 || true' EXIT   # stops its own stack however it ends
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
[ -f "$STATE" ] || ./run-dev.sh start >/dev/null
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 4 "$DEV/app-debug.sock"; }
FAILS=0
expect() { # description, actual, expected-substring
  if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi
}
refuse() { # description, actual, forbidden-substring
  if [[ "$2" != *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: found '$3' in '$2'"; FAILS=$((FAILS + 1)); fi
}
cpu_s() { ps -o time= -p "$APP_PID" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
rss_mb() { ps -o rss= -p "$APP_PID" | awk '{printf "%.0f", $1/1024}'; }
step() { # label: print app CPU time spent and RSS since the previous step
  local now; now=$(cpu_s)
  printf 'MEASURE %-34s cpu +%5.2fs  rss %s MB\n' "$1" "$(echo "$now - $LAST" | bc)" "$(rss_mb)"
  LAST=$now
}
shot() { screencapture -x -o -l "$(dbg windowid)" "$SHOTS/$1.png"; echo "shot $1"; }
both() { dbg "appearance dark" >/dev/null; sleep 1.2; shot "$1-dark"; dbg "appearance light" >/dev/null; sleep 1.2; shot "$1-light"; }
LAST=$(cpu_s)

FIX=$DEV/home/view
python3 -I make-fixtures.py "$FIX"
dbg "sessions" | while IFS=$'\t' read -r id _; do [ -n "$id" ] && dbg "close $id" >/dev/null; done
sleep 0.4
SID=$(dbg "new $FIX" | awk '{print $2}')
sleep 1.5
step "open folder (tree of fixtures)"

echo "--- tree"
# Today's tree has one root per workspace folder, each with the agent working in it (FileTree.tsx)
FIX2=$DEV/home/view2; mkdir -p "$FIX2/pkg"; printf 'x\n' > "$FIX2/pkg/a.txt"
SID2=$(dbg "new $FIX2" | awk '{print $2}'); sleep 1.2
RT=$(dbg files-roots)
expect "two workspaces = two roots" "$RT" "$FIX2"
expect "both roots in the order of the sessions" "$(echo "$RT" | cut -f1 | tr '\n' ' ')" "$FIX $FIX2"
expect "a root carries the name of its agent" "$(echo "$RT" | grep "$FIX2" | cut -f2)" "$(dbg sessions | awk -F'\t' -v id=$SID2 '$1==id {print $2}')"
dbg "close $SID2" >/dev/null; sleep 1
refuse "closing the agent drops its workspace root" "$(dbg files-roots)" "$FIX2"
dbg "select $SID" >/dev/null; sleep 0.5
expect "root is the session cwd" "$(dbg files-root)" "$FIX"
ROWS=$(dbg files)
expect "the root is the first row, folders sort first below it" "$(echo "$ROWS" | head -2 | tr "\n" "|")" "0	view/|1	assets/"
refuse "dot files hidden by default" "$ROWS" ".env.example"
refuse "children are lazy (nothing below assets yet)" "$ROWS" "gradient.png"
dbg "files-expand $FIX/assets" >/dev/null; dbg "files-expand $FIX/docs" >/dev/null; dbg "files-expand $FIX/src" >/dev/null; dbg "files-expand $FIX/zeta/inner" >/dev/null
sleep 0.3
ROWS=$(dbg files)
expect "expanded folder shows its files" "$ROWS" "gradient.png"
expect "git-ignored folder is marked" "$(echo "$ROWS" | grep -P 'build/' 2>/dev/null || echo "$ROWS" | grep 'build/')" "ignored"
expect "git-ignored file is marked" "$(echo "$ROWS" | grep 'debug.log')" "ignored"
refuse "normal file is not marked" "$(echo "$ROWS" | grep 'README.txt')" "ignored"
HR=$(dbg "files-hidden on"); sleep 0.3; echo "(files-hidden on -> $HR)"
expect "hidden toggle shows dot files" "$(dbg files | tr "\n" " ")" ".env.example"
expect "hidden toggle keeps expanded folders" "$(dbg files)" "gradient.png"
step "expand 4 folders + hidden on"
dbg "rail Files" >/dev/null; sleep 0.8
both "files-tree-live"
dbg "rail Control" >/dev/null
dbg "files-hidden off" >/dev/null

echo "--- context menu"
expect "file menu" "$(dbg "files-menu $FIX/README.txt")" "Open|-|Copy Path|Reveal in Finder|Open in Terminal Here|-|Rename…|Move to Trash…"
expect "folder menu" "$(dbg "files-menu $FIX/docs")" "Collapse|-|Copy Path"
expect "Copy Path puts the full path on the clipboard" "$(dbg "files-copypath $FIX/src/main.rs")" "\"$FIX/src/main.rs\""
BEFORE=$(dbg sessions | wc -l | tr -d ' ')
dbg "files-terminal $FIX/zeta" >/dev/null; sleep 0.8
expect "Open in Terminal Here on a folder starts a session there" "$(dbg sessions | tail -1)" "view/zeta"
dbg "select $SID" >/dev/null; sleep 0.8
dbg "files-terminal $FIX/src/lib.rs" >/dev/null; sleep 0.8
expect "Open in Terminal Here on a file uses its folder" "$(dbg sessions | tail -1)" "view/src"
expect "two new sessions" "$(dbg sessions | wc -l | tr -d ' ')" "$((BEFORE + 2))"
dbg "select $SID" >/dev/null; sleep 1.2
step "context menu + 2 terminals"

echo "--- rename / trash"
echo scratch > "$FIX/scratch-a.txt"; echo scratch > "$FIX/scratch-b-$$.txt"; sleep 0.5
expect "external file appears" "$(dbg files)" "scratch-a.txt"
expect "Rename moves the file on disk" "$(dbg "files-rename $FIX/scratch-a.txt renamed-a.txt")" "ok"
[ -f "$FIX/renamed-a.txt" ] && [ ! -f "$FIX/scratch-a.txt" ] && echo "PASS rename on disk" || { echo "FAIL rename on disk"; FAILS=$((FAILS + 1)); }
expect "tree shows the new name at once" "$(dbg files)" "renamed-a.txt"
expect "Rename refuses an existing name" "$(dbg "files-rename $FIX/renamed-a.txt README.txt")" "already exists"
expect "Rename refuses a slash" "$(dbg "files-rename $FIX/renamed-a.txt a/b")" "cannot contain"
TR=$(dbg "files-trash $FIX/scratch-b-$$.txt")
expect "Move to Trash" "$TR" "ok"
[ ! -e "$FIX/scratch-b-$$.txt" ] && echo "PASS trashed file left the folder" || { echo "FAIL still there"; FAILS=$((FAILS + 1)); }
TRASHED=${TR#ok }
case "$TRASHED" in
  */.Trash/scratch-b-*) [ -f "$TRASHED" ] && { echo "PASS file sits in the Trash, not deleted (.Trash/$(basename "$TRASHED"))"; rm -f "$TRASHED"; } || { echo "FAIL trashed file missing"; FAILS=$((FAILS + 1)); } ;;
  *) echo "FAIL unexpected trash location"; FAILS=$((FAILS + 1)) ;;
esac
refuse "tree dropped the trashed file" "$(dbg files)" "scratch-b-"
step "rename + trash"

echo "--- viewers"
shotv() { # name path expected-description
  expect "$1 opens in the right viewer" "$(dbg "viewer-open $2")" "$3"
  sleep 0.6
  both "viewer-$1"
}
shotv image "$FIX/assets/gradient.png" "NSImageView Image · 320×200"; step "image viewer"
shotv pdf "$FIX/docs/report.pdf" "PDF · 2 pages"; step "pdf viewer"
shotv markdown "$FIX/docs/notes.md" "Markdown"; step "markdown viewer"
shotv text "$FIX/src/main.rs" "read-only preview"; step "text viewer"
shotv binary "$FIX/data/blob.bin" "Binary · 1 KB"; step "binary viewer"
dbg "viewer-close" >/dev/null
expect "closing the viewer returns to the terminal" "$(dbg viewer)" "hidden"
dbg "files-open $FIX/assets/gradient.png" >/dev/null
expect "double click / Return on a file opens it" "$(dbg viewer)" "NSImageView"
dbg "select $SID" >/dev/null
expect "switching session closes the viewer" "$(dbg viewer)" "hidden"

echo "--- AC15: no WebKit"
APP_BIN=${APP_BIN:-$PWD/build/MuyaNative.app/Contents/MacOS/MuyaNative}
WK=$(vmmap "$APP_PID" 2>/dev/null | grep -c WebKit)
OT=$(otool -L "$APP_BIN" 2>/dev/null | grep -ci webkit)
HELPERS=$( (ps -A -o ppid=,command= | awk -v p="$APP_PID" '$1==p' | grep -ci "WebKit\|WebContent") || true)
echo "vmmap $APP_PID | grep -c WebKit = $WK   (after opening image, PDF, Markdown, text, binary)"
echo "otool -L MuyaNative | grep -ci webkit = $OT"
echo "WebKit / WebContent child processes = $HELPERS"
expect "AC15 otool shows no WebKit" "$OT" "0"
expect "AC15 no WebKit helper processes" "$HELPERS" "0"
python3 -I ./probe-appkit-webkit.py "$WK" || FAILS=$((FAILS + 1))

echo
[ "$FAILS" = 0 ] && echo "ALL PASS" || echo "$FAILS FAILED"
exit "$FAILS"
