#!/usr/bin/env bash
# Terminal path links (classic's feature, in Muya Native) on a REAL daemon + app in a throwaway HOME (run-dev.sh): a shell prints
# paths of a real file, a real directory and things that do not exist; the app must find the token under a cell, resolve it
# (file / dir / none, relative against the shell's CURRENT directory, ~ against its home), underline it on hover, and open the
# classic menu (header, then Open in Muya | Open Terminal Here, Reveal in Finder, Copy Path) on click and on right-click.
#   MUYA_BIN_DIR=<dir with muya-ptyd + muyad> native/app/verify-path-links.sh
set -euo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-pl.XXXXXX)  # its own dir per run: the default /tmp state file collides with any other running dev stack
STATE=${TMPDIR:-/tmp}/muya-native-dev.state
./run-dev.sh start >/dev/null
trap './run-dev.sh stop >/dev/null' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock" || true; }
for _ in $(seq 40); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid)" ] && break; sleep 0.5; done
fail=0
expect() { # label, actual, substring
  if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: wanted '$3' in '$2'"; fail=$((fail + 1)); fi
}
expect_not() { # label, actual, substring
  if [[ "$2" != *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: did not want '$3' in '$2'"; fail=$((fail + 1)); fi
}
D=$TMPDIR/work; mkdir -p "$D/folder/inner"; echo hello > "$D/note.txt"
dbg "window 1120 732" >/dev/null
dbg "new" >/dev/null; sleep 2
# The shell's HOME must be the throwaway one: the ~/ case creates a file there.
dbg 'type "printf \"HOME=%s\\n\" \"$HOME\"\n"' >/dev/null; sleep 1
case "$(dbg text)" in *"HOME=$DEV/home"*) ;; *) echo "FAIL the session's HOME is not the throwaway one"; exit 1 ;; esac
dbg 'type "clear; export D='"$D"'; touch ~/pl-tilde.txt; cd $D\n"' >/dev/null; sleep 1
dbg 'type "printf \"P1 %s\\nP2 %s\\nP3 %s/gone.txt\\nP4 ./note.txt\\nP5 folder/inner\\nP6 %s/note.txt.\\nP7 %s/note.txt:42\\nP8 ~/pl-tilde.txt\\nP9 just words\\nP10 (%s/note.txt)\\n\" \"$D/note.txt\" \"$D/folder\" \"$D\" \"$D\" \"$D\" \"$D\"\n"' >/dev/null; sleep 1.5
screen=$(dbg text)
rowof() { printf '%s\n' "$screen" | awk -v k="$1 " 'index($0, k) == 1 { print NR - 1; exit }'; }
link() { dbg "term-link $2 $(rowof "$1")"; }   # label, col

# detection + resolution
r=$(link P1 5); expect "P1 absolute file: token" "$r" "token=$D/note.txt "; expect "P1 absolute file: a file" "$r" "kind=file"
r=$(link P2 5); expect "P2 absolute dir: a dir" "$r" "kind=dir"
r=$(link P3 5); expect "P3 missing path: detected as a token" "$r" "token=$D/gone.txt "; expect "P3 missing path: none" "$r" "kind=none"
r=$(link P4 5); expect "P4 ./relative resolves against the shell's current directory" "$r" "work/./note.txt"; expect "P4 ./relative: a file" "$r" "kind=file"
r=$(link P5 5); expect "P5 folder/inner relative dir" "$r" "kind=dir"
r=$(link P6 5); expect "P6 trailing period is trimmed" "$r" "token=$D/note.txt "; expect "P6 trailing period: still a file" "$r" "kind=file"
r=$(link P7 5); expect "P7 file:42 stays one token" "$r" "note.txt:42 "; expect "P7 file:42 does not resolve (classic)" "$r" "kind=none"
r=$(link P8 5); expect "P8 ~/ resolves against the session's home" "$r" "path=$DEV/home/pl-tilde.txt"; expect "P8 ~/: a file" "$r" "kind=file"
expect "P9 plain words are no token" "$(link P9 5)" "none"
r=$(link P10 5); expect "P10 parenthesised path: a file" "$r" "kind=file"
expect "a cell outside the token is no hit" "$(link P1 1)" "none"

# the menu: header, then classic's items in classic's order
expect "file menu" "$(dbg "term-link-menu 5 $(rowof P1)")" "📄 note.txt|-|Open in Muya|Reveal in Finder|Copy Path"
expect "dir menu" "$(dbg "term-link-menu 5 $(rowof P2)")" "📁 folder|-|Open Terminal Here|Reveal in Finder|Copy Path"
expect "no menu for a missing path" "$(dbg "term-link-menu 5 $(rowof P3)")" "none"
expect_not "a file has no Open Terminal Here" "$(dbg "term-link-menu 5 $(rowof P1)")" "Open Terminal Here"
expect_not "a dir has no Open in Muya" "$(dbg "term-link-menu 5 $(rowof P2)")" "Open in Muya"

# hover: underline only on an existing path, cleared when the pointer leaves
R1=$(rowof P1); R2=$(rowof P2); R3=$(rowof P3); R9=$(rowof P9)
dbg "mouse move 6 $R1" >/dev/null; sleep 0.6
r=$(dbg term-link-state); expect "hover: the file path is underlined" "$r" "kind=file"; expect "hover: the renderer draws it" "$r" "underlined=true"
dbg "mouse move 20 $R1" >/dev/null; sleep 0.2
expect "hover: moving along the same token keeps it" "$(dbg term-link-state)" "kind=file"
dbg "mouse move 6 $R3" >/dev/null; sleep 0.6
expect "hover: a path that does not exist is not underlined" "$(dbg term-link-state)" "none"
dbg "mouse move 6 $R1" >/dev/null; sleep 0.6; dbg "mouse move 5 $R9" >/dev/null; sleep 0.2
expect "hover: leaving the token clears it" "$(dbg term-link-state)" "none"
dbg "mouse move 6 $R1" >/dev/null; sleep 0.6; dbg "wheel 1" >/dev/null; sleep 0.2
expect "hover: scrolling clears it" "$(dbg term-link-state)" "none"; dbg "wheel -1" >/dev/null

# click: mouse up on the link that the press started on opens the menu; a drag or a click elsewhere does not
dbg "term-link-capture on" >/dev/null
click() { # col row: hover, press, release in the same cell; answers with the menu the release opened
  dbg "term-link-capture reset" >/dev/null
  dbg "mouse move $1 $2" >/dev/null; sleep 0.6; dbg "mouse down $1 $2" >/dev/null; dbg "mouse up $1 $2" >/dev/null; dbg "term-link-capture last"
}
expect "click on a file link opens its menu" "$(click 6 "$R1")" "📄 note.txt|-|Open in Muya|Reveal in Finder|Copy Path"
expect "click on a dir link opens its menu" "$(click 6 "$R2")" "📁 folder|-|Open Terminal Here|Reveal in Finder|Copy Path"
expect "click on a missing path opens no menu" "$(click 6 "$R3")" "none"
expect "click on plain text opens no menu" "$(click 5 "$R9")" "none"
dbg "term-link-capture reset" >/dev/null
dbg "mouse move 6 $R1" >/dev/null; sleep 0.6; dbg "mouse down 6 $R1" >/dev/null; dbg "mouse drag 12 $R1" >/dev/null; dbg "mouse up 12 $R1" >/dev/null
expect "a drag over the link selects and opens no menu" "$(dbg term-link-capture last)" "none"
dbg "term-link-capture off" >/dev/null
expect "right-click on a file link shows the link menu" "$(dbg "mouse right 6 $R1")" "📄 note.txt|-|Open in Muya|Reveal in Finder|Copy Path"
expect "right-click off a link keeps the terminal menu" "$(dbg "mouse right 5 $R9")" "Paste as Path|"
expect "the terminal menu itself is unchanged" "$(dbg term-menu)" "Copy    ⌘C|Paste    ⌘V|Paste as Path|Select All    ⌘A|-|Find…    ⌘F|Clear Scrollback"

# actions
r=$(dbg "term-link-run 5 $R1 Copy Path"); expect "Copy Path puts the resolved path on the clipboard" "$r" "clipboard=$D/note.txt "
r=$(dbg "term-link-run 5 $R1 Open in Muya"); expect "Open in Muya opens the file in the viewer" "$r" "viewer=$D/note.txt"
before=$(dbg sessions | grep -c . || true)
dbg "term-link-run 5 $R2 Open Terminal Here" >/dev/null; sleep 1.5
dbg 'type "pwd\n"' >/dev/null; sleep 0.8
expect "Open Terminal Here starts a session in that directory" "$(dbg text)" "$D/folder"
[ "$(dbg sessions | grep -c . || true)" -gt "$before" ] && echo "ok   Open Terminal Here added a session" || { echo "FAIL Open Terminal Here added no session"; fail=$((fail + 1)); }

# the program owning the mouse: no hover (the click is the program's), unless Shift is held
dbg 'type "printf \"\\033[?1000h\\033[?1006hQQ %s\\n\" '"$D"'/note.txt\n"' >/dev/null; sleep 1   # (the new session has no $D)
rq=$(dbg text | awk 'index($0, "QQ ") == 1 { print NR - 1; exit }')
dbg "mouse move 8 $rq" >/dev/null; sleep 0.6
expect "mouse tracking on: no link hover" "$(dbg term-link-state)" "none"
dbg "mouse move 8 $rq shift" >/dev/null; sleep 0.6
expect "mouse tracking on + Shift: the link works again" "$(dbg term-link-state)" "kind=file"
dbg 'type "printf \"\\033[?1000l\\033[?1006l\"\n"' >/dev/null

[ "$fail" = 0 ] && echo "verify-path-links: all passed" || { echo "verify-path-links: $fail failures"; exit 1; }
