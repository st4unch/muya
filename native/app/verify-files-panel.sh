#!/usr/bin/env bash
# The Files panel's open-files list, end to end in the dev stack (run-dev.sh, throwaway HOME): with 22 files open
#   A. nothing is drawn outside the list's frame, and the list scrolls;
#   B. a click on the right part of a LONG file name opens it (it used to close it), a click on the × closes it;
#   C. the open files are visible in Control mode too (classic's open-files list only exists on the Files screen; the operator wants
#      them in the Files area from Control as well, see OpenFilesList.compact);
# then screenshots of the window in both themes, Files mode and Control mode: screenshots/files-panel-*.png.
# Builds first. Needs the daemons (native/target/debug, or MUYA_BIN_DIR); builds them when missing.   exit = number of FAILs
set -uo pipefail
cd "$(dirname "$0")"
export PATH=/opt/homebrew/opt/zig@0.15/bin:$PATH
eval "$(bash ../scripts/ghostty-env.sh)"
./build.sh >/dev/null 2>&1 || { echo "FAIL build.sh"; exit 1; }
BINDIR=${MUYA_BIN_DIR:-../target/debug}
[ -x "$BINDIR/muyad" ] && [ -x "$BINDIR/muya-ptyd" ] || (cd .. && cargo build -p muya-ptyd -p muyad >/dev/null 2>&1) || { echo "FAIL cargo build of the daemons"; exit 1; }
export TMPDIR=$(mktemp -d /tmp/muya-fp.XXXXXX)
SHOTS=$PWD/screenshots; mkdir -p "$SHOTS"
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$TMPDIR"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
./run-dev.sh start >/dev/null || { echo "FAIL run-dev start"; exit 1; }
. "$TMPDIR/muya-native-dev.state"
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock"; }
kv() { tr ' ' '\n' <<<"$1" | sed -n "s/^$2=//p" | head -1; }
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
expect() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1: got '$2', wanted '$3'"; }
for _ in $(seq 100); do [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
sleep 2

D=$DEV/home/ofp; mkdir -p "$D"
LONG=a-really-long-file-name-that-runs-far-past-the-close-button-and-keeps-going-0042.txt
for i in $(seq -w 1 21); do echo "file $i" > "$D/note-$i.txt"; done
echo "the long one" > "$D/$LONG"
dbg "new $D" >/dev/null; sleep 1.5
for i in $(seq -w 1 21); do dbg "viewer-open $D/note-$i.txt" >/dev/null; done
dbg "viewer-open $D/$LONG" >/dev/null; sleep 0.5
dbg "viewer-open $D/note-01.txt" >/dev/null; sleep 0.5   # another file is the current one
dbg "window 1120 700" >/dev/null; sleep 0.6
dbg "p4-files 0" >/dev/null

# ---- Files mode ----
dbg "rail Files" >/dev/null; sleep 0.8
st=$(dbg of-state)
expect "22 files open in the list" "$(kv "$st" count)" 22
expect "Files mode: full list (not compact), visible" "$(kv "$st" compact)/$(kv "$st" hidden)" "false/false"
expect "the list scrolls (22 cards do not fit)" "$(kv "$st" scrolls)" true
fy=$(sed -n 's/frame=[0-9-]*,\([0-9-]*\),[0-9]*,\([0-9]*\).*/\1 \2/p' <<<"$st"); top=${fy% *}; h=${fy#* }
[ $((top + h)) -le "$(kv "$st" headerY)" ] && ok "list frame ends above the FILES header ($((top + h)) <= $(kv "$st" headerY))" || bad "list frame overlaps the FILES header: $st"
ov=$(dbg of-overdraw)
expect "nothing painted below/right/above the frame (Files)" "$(kv "$ov" below)/$(kv "$ov" right)/$(kv "$ov" above)" "0/0/0"
[ "$(kv "$ov" inside)" -gt 100 ] 2>/dev/null && ok "something IS painted inside ($ov)" || bad "nothing painted inside: $ov"
sc=$(dbg "of-scroll 100000"); [ "$(kv "$sc" offset)" -gt 0 ] && [ "$(kv "$sc" offset)" = "$(kv "$sc" max)" ] && ok "scrolls to the end ($(kv "$sc" offset))" || bad "scroll: $sc"
ov=$(dbg of-overdraw); expect "scrolled to the end: still nothing outside the frame" "$(kv "$ov" below)/$(kv "$ov" right)/$(kv "$ov" above)" "0/0/0"
dbg "of-scroll 0" >/dev/null

# ---- B: click on the name opens, click on the × closes ----
expect "before the click another file is current" "$(kv "$(dbg of-state)" current)" note-01.txt
r=$(dbg "of-click $LONG name"); sleep 0.6
v=$(dbg viewer); n=$(kv "$(dbg of-state)" count)   # the click ran openViewer: the list's current file and the viewer follow it
expect "click on a long name opens it: it becomes the current file ($r)" "$(kv "$(dbg of-state)" current)" "$LONG"
[ "$v" != hidden ] && ok "the viewer is showing a file ($v)" || bad "viewer hidden after the click"
expect "... and it is still in the list" "$n" 22
dbg "viewer-open $D/note-02.txt" >/dev/null; sleep 0.3
dbg "of-click $LONG x" >/dev/null; sleep 0.6
n=$(kv "$(dbg of-state)" count); files=$(kv "$(dbg p4-state)" openFiles)
[ "$n" = 21 ] && [[ "$files" != *"$LONG"* ]] && ok "click on the × closes the long file (21 left)" || bad "× did not close: count=$n files=$files"
dbg "viewer-open $D/$LONG" >/dev/null; sleep 0.5   # back to 22 for the pictures
expect "22 files again" "$(kv "$(dbg of-state)" count)" 22

# ---- screenshots, Files mode ----
for theme in Dark Light; do
  t=$(echo "$theme" | tr 'A-Z' 'a-z'); dbg "settings-set appearance $theme" >/dev/null; sleep 1.2
  dbg "snap $SHOTS/files-panel-files-$t.png" >/dev/null; sleep 0.5
  [ -s "$SHOTS/files-panel-files-$t.png" ] && ok "screenshot files-panel-files-$t.png" || bad "no screenshot files-$t"
done

# ---- C: Control mode ----
dbg "rail Control" >/dev/null; sleep 0.8
st=$(dbg of-state)
expect "Control: the open files are listed (compact, visible, 22)" "$(kv "$st" compact)/$(kv "$st" hidden)/$(kv "$st" count)" "true/false/22"
fy=$(sed -n 's/frame=[0-9-]*,\([0-9-]*\),[0-9]*,\([0-9]*\).*/\1 \2/p' <<<"$st"); top=${fy% *}; h=${fy#* }
[ $((top + h)) -le "$(kv "$st" headerY)" ] && ok "Control: list sits above the FILES header ($((top + h)) <= $(kv "$st" headerY))" || bad "Control: list overlaps FILES header: $st"
[ "$h" -gt 40 ] && ok "Control: the list has height ($h px)" || bad "Control: list collapsed: $st"
expect "Control: the current file is marked" "$(kv "$st" current)" "$LONG"
ov=$(dbg of-overdraw); expect "Control: nothing painted outside the frame" "$(kv "$ov" below)/$(kv "$ov" right)/$(kv "$ov" above)" "0/0/0"
for theme in Dark Light; do
  t=$(echo "$theme" | tr 'A-Z' 'a-z'); dbg "settings-set appearance $theme" >/dev/null; sleep 1.2
  dbg "snap $SHOTS/files-panel-control-$t.png" >/dev/null; sleep 0.5
  [ -s "$SHOTS/files-panel-control-$t.png" ] && ok "screenshot files-panel-control-$t.png" || bad "no screenshot control-$t"
done
echo "RESULT: $([ $fails = 0 ] && echo PASS || echo "FAIL ($fails)")"
exit $fails
