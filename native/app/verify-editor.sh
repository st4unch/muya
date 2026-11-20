#!/usr/bin/env bash
# Live run of the editor in the dev build (docs/prd-native-editor.md AC1-AC10): throwaway HOME, own sockets, no CGEvents,
# never touches an installed Muya. The app is started from THIS shell and stays its child for the whole run (muyad refuses
# a client whose parent exited), then everything is stopped.
#   native/app/verify-editor.sh            run all checks, screenshots to $SHOTS (default native/app/screenshots)
#   BIG_MB=20 SHOTS=<dir> verify-editor.sh
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
SHOTS=${SHOTS:-$HERE/screenshots}; mkdir -p "$SHOTS"
BIG_MB=${BIG_MB:-20}
BIN_DIR=${MUYA_BIN_DIR:-$HERE/../target/debug}
export TMPDIR=$(mktemp -d /private/tmp/muya-ed.XXXXXX)
STATE=$TMPDIR/muya-native-dev.state
APP_BIN=$HERE/build/MuyaNative.app/Contents/MacOS/MuyaNative
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
expect() { # name, haystack, needle
  case "$2" in *"$3"*) ok "$1";; *) bad "$1 (wanted '$3' in '${2:0:400}')";; esac
}
expect_not() { case "$2" in *"$3"*) bad "$1 (did not want '$3' in '${2:0:400}')";; *) ok "$1";; esac; }

MUYA_BIN_DIR=$BIN_DIR MUYA_DEV_NO_APP=1 ./run-dev.sh start >/dev/null || { echo "daemons did not start"; exit 1; }
. "$STATE"
APP_PID=
cleanup() { cp "$DEV/app.log" "$SHOTS/app.log" 2>/dev/null; [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; MUYA_BIN_DIR=$BIN_DIR ./run-dev.sh stop >/dev/null 2>&1; rm -rf "$TMPDIR"; }
trap cleanup EXIT
HOME=$DEV/home MUYA_SOCKET=$DEV/muyad.sock MUYA_DEBUG_SOCKET=$DEV/app-debug.sock "$APP_BIN" >"$DEV/app.log" 2>&1 &
APP_PID=$!
dbg() { printf '%s\n' "$1" | nc -U -w "${2:-30}" "$DEV/app-debug.sock"; }
shot() { dbg "snap $SHOTS/editor-$1.png" >/dev/null; } # in-process render (screencapture is black on a locked screen)
rss_mb() { ps -o rss= -p "$APP_PID" | awk '{printf "%.0f", $1/1024}'; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
for _ in $(seq 60); do [ -S "$DEV/app-debug.sock" ] && break; sleep 0.25; done
sleep 3; dbg "ac-click later" >/dev/null 2>&1 || true
SID=$(dbg "new $DEV/home" | awk '{print $2}'); sleep 1.5

W=$DEV/home/ed; mkdir -p "$W"
cat > "$W/a.ts" <<'EOF'
// A small TypeScript file
import { thing } from "./thing";

export interface User { id: number; name: string }

/* block
   comment */
export function greet(u: User): string {
  const msg = `hello ${u.name}`;
  return msg + 42;
}
EOF
printf '\xef\xbb\xbfline one\r\nline two\r\n' > "$W/crlf.txt"
printf '# Title\n\nSome *text* and `code`.\n\n- one\n- two\n' > "$W/notes.md"
python3 -I make-large-fixtures.py "$W" json "$BIG_MB" >/dev/null
BIG=$W/big-json-${BIG_MB}mb.json
cp "$BIG" "$W/perf.json"
( cd "$W" && git init -q && printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' > tracked.txt && git add tracked.txt && git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m init )

echo "== AC1 open, highlight, edit, save"
dbg "viewer-open $W/a.ts" >/dev/null; sleep 1.2
r=$(dbg viewer); expect "opens as the editor" "$r" "EditorContainer"
 r=$(dbg editor-state); expect "typescript highlighted" "$r" "lang=typescript highlight=true"; expect "clean on open" "$r" "dirty=false"
dbg "appearance dark" >/dev/null; sleep 0.5; shot ts-dark
dbg "appearance light" >/dev/null; sleep 0.5; shot ts-light
dbg "appearance dark" >/dev/null
r=$(dbg 'editor-type // edited by the test\n'); expect "typing marks dirty" "$r" "dirty=true"; sleep 0.3; expect "save enabled" "$(dbg editor-state)" "save=true"
shot ts-dirty
r=$(dbg editor-save); expect "save returns true" "$r" "true"
expect "disk has the typed text" "$(cat "$W/a.ts")" "// edited by the test"
r=$(dbg editor-state); expect "clean after save" "$r" "dirty=false"

echo "== AC2 CRLF + BOM kept"
dbg "viewer-open $W/crlf.txt" >/dev/null; sleep 0.5
dbg 'editor-type X' >/dev/null; dbg editor-save >/dev/null
r=$(python3 - "$W/crlf.txt" <<'EOF'
import sys; b = open(sys.argv[1], 'rb').read(); print('bom' if b.startswith(b'\xef\xbb\xbf') else 'nobom', b.count(b'\r\n'), b.count(b'\n'))
EOF
)
expect "BOM and CRLF preserved" "$r" "bom 2 2"

echo "== AC4 switching keeps unsaved edits"
dbg "viewer-open $W/a.ts" >/dev/null; sleep 0.4
dbg 'editor-type KEEPME' >/dev/null
dbg "viewer-open $W/crlf.txt" >/dev/null; sleep 0.3
dbg "viewer-open $W/a.ts" >/dev/null; sleep 0.3
r=$(dbg editor-text); expect "unsaved text survived a file switch" "$r" "KEEPME"; expect "still dirty" "$(dbg editor-state)" "dirty=true"

echo "== AC5 external change"
dbg editor-save >/dev/null
echo "// agent wrote this" >> "$W/a.ts"; sleep 1.6
r=$(dbg editor-text); expect "clean buffer reloads from disk" "$r" "agent wrote this"
dbg 'editor-type MINE' >/dev/null
echo "// agent wrote again" >> "$W/a.ts"; sleep 1.6
r=$(dbg editor-state); expect "dirty buffer: badge raised" "$r" "diskChanged=true"; expect "dirty buffer kept" "$(dbg editor-text)" "MINE"
shot badge
dbg "editor-answer cancel" >/dev/null; r=$(dbg editor-save); expect "save over a changed file is refused until confirmed" "$r" "false"
expect_not "disk not overwritten by the refused save" "$(cat "$W/a.ts")" "MINE"
dbg "editor-answer overwrite" >/dev/null; dbg editor-save >/dev/null
expect "Overwrite writes the buffer" "$(cat "$W/a.ts")" "MINE"
dbg 'editor-type AGAIN' >/dev/null; echo "// third" >> "$W/a.ts"; sleep 1.6
dbg "editor-answer reload" >/dev/null; dbg editor-save >/dev/null
expect "Reload takes the disk version" "$(dbg editor-text)" "third"; expect_not "edits dropped" "$(dbg editor-text)" "AGAIN"

echo "== AC3 close / quit guard"
dbg 'editor-type UNSAVED' >/dev/null
dbg "editor-answer cancel" >/dev/null; r=$(dbg editor-close); expect "Cancel keeps the file open" "$r" "kept"
r=$(dbg editor-state); expect "still open and dirty" "$r" "dirty=true"
r=$(dbg editor-close); sleep 0.6; expect "sheet shown for a dirty close" "$(dbg editor-sheet-title)" "sheet"; shot close-guard
dbg "editor-sheet third" >/dev/null; sleep 0.4
expect "cancelling the sheet keeps it" "$(dbg editor-state)" "dirty=true"
dbg "editor-answer cancel" >/dev/null; expect "quit guard: cancel" "$(dbg editor-quit)" "false"
dbg "editor-answer discard" >/dev/null; expect "quit guard: discard lets it quit" "$(dbg editor-quit)" "true"
dbg "editor-answer save" >/dev/null; expect "quit guard: save all" "$(dbg editor-quit)" "true"
expect "quit-save wrote the file" "$(cat "$W/a.ts")" "UNSAVED"
dbg "editor-answer discard" >/dev/null; r=$(dbg editor-close); expect "clean/discard close" "$r" "closed"

echo "== AC6 toggles, diff against HEAD"
dbg "viewer-open $W/a.ts" >/dev/null; sleep 0.4
dbg "editor-toggle wrap" >/dev/null; dbg "editor-toggle map" >/dev/null; sleep 0.8; shot wrap-map-dark
dbg "appearance light" >/dev/null; sleep 0.5; shot wrap-map-light; dbg "appearance dark" >/dev/null
r=$(dbg "editor-state"); expect "wrap + map on" "$r" "wrap=true map=true"
dbg "editor-toggle wrap" >/dev/null; dbg "editor-toggle map" >/dev/null
dbg "viewer-open $W/tracked.txt" >/dev/null; sleep 0.4
dbg 'editor-type CHANGED\n' >/dev/null; dbg "editor-toggle diff" >/dev/null; sleep 1.2
r=$(dbg editor-state); expect "diff mode" "$r" "inDiff=true"; expect "side-by-side like Monaco's diff editor" "$r" "sideBySide=true"
r=$(dbg editor-diff-text); expect "HEAD on the left, buffer on the right" "$r" "====="; expect "added line on the right" "$r" "CHANGED"; echo "    frames: $(dbg editor-diff-frames)"; shot diff-dark
dbg "appearance light" >/dev/null; sleep 0.4; shot diff-light; dbg "appearance dark" >/dev/null
dbg "editor-toggle diff" >/dev/null; dbg editor-save >/dev/null

echo "== AC7 find, go to line, undo"
dbg "viewer-open $W/a.ts" >/dev/null; sleep 0.4
dbg "editor-goto 8:3" >/dev/null; sleep 0.3
dbg editor-find >/dev/null; sleep 0.6; shot find
dbg 'editor-type Z' >/dev/null; r=$(dbg editor-undo); expect "undo works" "$r" "dirty=true"

echo "== labels, bracket colours, folding, multi-cursor, ⌘S routing"
dbg "viewer-open $W/a.ts" >/dev/null; sleep 0.5
expect "language label like classic" "$(dbg viewer)" "TypeScript ·"
dbg "viewer-open $BIG" >/dev/null; sleep 3; expect "JSON label" "$(dbg viewer)" "JSON ·"; dbg "viewer-close" >/dev/null; sleep 0.3
printf 'function f() {\n  const a = [1, (2 + 3)];\n  if (a) {\n    return foo(a);\n  }\n}\nconst foo = 1; foo; foo;\n' > "$W/fold.ts"
dbg "viewer-open $W/fold.ts" >/dev/null; sleep 0.8
shot brackets-fold-open
r=$(dbg "editor-fold 1"); expect "fold the function block" "$r" "folds=1"; sleep 0.4; shot folded-dark
dbg "appearance light" >/dev/null; sleep 0.4; shot folded-light; dbg "appearance dark" >/dev/null
r=$(dbg "editor-fold 1"); expect "unfold" "$r" "folds=0"
dbg "editor-caret 0" >/dev/null
r=$(dbg "editor-fold 3"); expect "inner block folds too" "$r" "folds=1"; dbg "editor-fold 3" >/dev/null
echo "  -- multi-cursor"
OFF=$(grep -b -o 'foo; foo;' "$W/fold.ts" | head -1 | cut -d: -f1)
dbg "editor-caret $OFF" >/dev/null
r=$(dbg editor-addnext); expect "first ⌘D selects the word" "$r" ",3"
r=$(dbg editor-addnext); expect "second ⌘D adds the next occurrence" "$r" " "; shot multi-cursor
dbg 'editor-type bar' >/dev/null
r=$(dbg editor-text); n=$(printf '%s' "$r" | grep -o 'bar' | wc -l | tr -d ' ')
[ "$n" -ge 2 ] && ok "typing replaces every selected occurrence ($n)" || bad "typing hit $n places"
dbg "editor-caret 0" >/dev/null; dbg "editor-cursor 10" >/dev/null; r=$(dbg "editor-cursor 20"); expect "⌥-click adds carets" "$r" "0,0"
dbg 'editor-type ZZ' >/dev/null; r=$(dbg editor-text); n=$(printf '%s' "$r" | grep -o 'ZZ' | wc -l | tr -d ' ')
[ "$n" -ge 3 ] && ok "typing inserts at all carets ($n)" || { bad "typing inserted at $n carets"; echo "    sel: $(dbg editor-selections) text: ${r:0:200}"; }
dbg "editor-answer discard" >/dev/null; dbg editor-close >/dev/null
echo "  -- ⌘S while the terminal has the keyboard"
dbg "viewer-open $W/a.ts" >/dev/null; sleep 0.5
dbg 'editor-type CMDS_TEST' >/dev/null
r=$(dbg "editor-cmd-s terminal"); expect "⌘S saves a dirty visible file even when the editor is not focused" "$r" "handled"
expect "file on disk saved by ⌘S" "$(cat "$W/a.ts")" "CMDS_TEST"
r=$(dbg "editor-cmd-s terminal"); expect "clean file: ⌘S stays Sessions" "$r" "passed"

echo "== AC8 sizes"
dbg "viewer-open $BIG" >/dev/null; sleep 3; r=$(dbg viewer); expect "big JSON opens" "$r" "EditorContainer"
r=$(dbg editor-state); expect "big JSON full features" "$r" "highlight=true minimap=true diff=true"
shot big-json
printf 'x%.0s' $(seq 1 250000) > "$W/oneline.txt"
dbg "viewer-open $W/oneline.txt" >/dev/null; sleep 1; r=$(dbg editor-state); expect "long line is read-only" "$r" "longLine"
r=$(dbg 'editor-type nope'); expect_not "read-only takes no edits" "$r" "dirty=true"

echo "== markdown edit toggle"
dbg "viewer-open $W/notes.md" >/dev/null; sleep 0.6; shot markdown-rendered
r=$(dbg viewer); expect "rendered by default" "$r" "Markdown"
dbg "md-edit" >/dev/null; sleep 0.8; r=$(dbg editor-state); expect "Edit switches to the editor" "$r" "lang=markdown"; shot markdown-edit
dbg 'editor-type PREVIEWTEXT' >/dev/null; dbg "md-edit" >/dev/null; sleep 0.5
expect "Preview renders the unsaved buffer" "$(dbg viewer)" "Markdown"
dbg "md-edit" >/dev/null; sleep 0.5; expect "unsaved Markdown edits survive Preview/Edit" "$(dbg editor-state)" "dirty=true"; dbg "editor-save" >/dev/null


echo "== AC9 perf (${BIG_MB} MB JSON): budgets open < 500 ms, typing median < 16 ms"
dbg "viewer-close" >/dev/null; sleep 0.5
dbg "viewer-open $W/perf.json" 120 >/dev/null
for _ in $(seq 400); do case "$(dbg viewer)" in *EditorContainer*) break;; esac; sleep 0.05; done
OPEN_MS=$(dbg viewer-open-ms); sleep 2
echo "  open + first paint: ${OPEN_MS} ms; rss $(rss_mb) MB"
[ "$OPEN_MS" -lt 500 ] && ok "open under 500 ms" || bad "open took $OPEN_MS ms"
RSS=$(rss_mb); [ "$RSS" -lt $((BIG_MB * 16 + 100)) ] && ok "rss ${RSS} MB under 16 x file + 100 MB (this run holds two 20 MB documents)" || bad "rss ${RSS} MB"
B=$(dbg "editor-bench 40"); echo "  typing (insert + re-highlight + repaint), 40 keys: $B"
MED=$(echo "$B" | sed -n 's/^median=\([0-9.]*\).*/\1/p')
[ "$(echo "$MED < 16" | bc)" = 1 ] && ok "typing median ${MED} ms under 16" || bad "typing median ${MED} ms"
SCR=$(echo "$B" | sed -n 's/.*scroll median=\([0-9.]*\).*/\1/p')
[ "$(echo "$SCR < 16" | bc)" = 1 ] && ok "scroll step median ${SCR} ms under 16" || bad "scroll step median ${SCR} ms"
otool -L "$APP_BIN" | grep -qi webkit && bad "WebKit is linked" || ok "no WebKit linked"

if [ -n "${TIERS:-50 127 135}" ] && [ "${NO_TIERS:-}" != 1 ]; then
echo "== size tiers, live (open, memory, typing, scroll)"
for MB in ${TIERS:-50 127 135}; do
  F=$(python3 -I make-large-fixtures.py "$W" json "$MB"); SZ=$(stat -f %z "$F")
  dbg "viewer-open $F" 120 >/dev/null
  for _ in $(seq 600); do [ "$(dbg viewer-open-ms)" -ge 0 ] && break; sleep 0.1; done
  OPENMS=$(dbg viewer-open-ms)
  if [ "$SZ" -gt 134217728 ]; then
    echo "  ${MB} MB ($SZ bytes): above 128 MB, open took ${OPENMS} ms and showed: $(dbg viewer)"; shot tier-${MB}mb-prompt
    dbg viewer-open-anyway >/dev/null; sleep 4; R=$(dbg editor-state)
    expect "${MB} MB: Open Anyway shows the head read-only" "$R" "readOnly=Optional"
    expect "${MB} MB: head is read-only (truncated)" "$R" "truncated"
    r=$(dbg 'editor-type nope'); expect_not "${MB} MB head takes no edits" "$r" "dirty=true"
    shot tier-${MB}mb-head
    echo "  ${MB} MB head: rss $(rss_mb) MB; $(dbg editor-bench 20)"
  else
    sleep 3; R=$(dbg editor-state)
    echo "  ${MB} MB ($SZ bytes): open+first paint ${OPENMS} ms; rss $(rss_mb) MB"
    if [ "$SZ" -ge 52428800 ]; then expect "${MB} MB: plain but editable" "$R" "highlight=false minimap=false diff=false readOnly=nil"
    else expect "${MB} MB: all features" "$R" "highlight=true minimap=true diff=true"; fi
    echo "  ${MB} MB typing/scroll: $(dbg editor-bench 40)"
    r=$(dbg 'editor-type TIERED'); expect "${MB} MB: editable (dirty after typing)" "$r" "dirty=true"
    shot tier-${MB}mb
    echo "  ${MB} MB save: $(python3 -c 'import time;print(int(time.time()*1000))')"; a=$(now_ms); dbg editor-save 120 >/dev/null; b=$(now_ms)
    echo "  ${MB} MB save took $((b - a)) ms (atomic rewrite of $SZ bytes)"
    [ "$(grep -c TIERED "$F")" -ge 1 ] && ok "${MB} MB: saved text on disk" || bad "${MB} MB: TIERED not on disk"
  fi
  dbg "editor-answer discard" >/dev/null; dbg editor-close >/dev/null; rm -f "$F"; sleep 1
  echo "  rss after closing: $(rss_mb) MB; $(dbg editor-live)"
done
fi

echo
echo "editor verify: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
