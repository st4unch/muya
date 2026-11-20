#!/usr/bin/env bash
# P3 (app shell: shortcuts, menus, panel toggles) against the real app view: throwaway stack, fake HOME, own
# sockets, kills only what it started. Keys are REAL CGEvents posted to the app's pid (tools/cg-key.swift), so they
# take the whole path: NSApplication key monitor -> menu key equivalents -> window -> TerminalView.keyDown.
# What reaches the pty is read back with `cat -v`; UI effects through the debug socket's p3-state.
# Run from a tree whose MuyaNative.app is built. MUYA_BIN_DIR=<dir with muya-ptyd + muyad> if native/target is elsewhere.
#   verify-p3.sh    exit 1 on any FAIL; screenshots in screenshots/p3-*.png
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
WORK=$(mktemp -d /tmp/muya-p3v.XXXXXX)
export TMPDIR=$WORK
STATE=$WORK/muya-native-dev.state
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
mkdir -p build screenshots; [ -x build/cg-key ] || swiftc -O -o build/cg-key tools/cg-key.swift || exit 1
./run-dev.sh start >/dev/null || exit 1
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
for _ in $(seq 80); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
# Real CGEvents when the app is the active app; otherwise (this session cannot bring it forward: another app, such as
# the Muya running this very session, keeps the focus) a real NSEvent through NSApp.sendEvent (p3-key).
# Other MuyaNative instances (parallel work sessions, a mock app) take the focus away between two keys: before EVERY key the app is made
# frontmost again and the script waits until it reports active + key (a key posted to a pid that is not active is lost).
ensure_active() {
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$(st active)" = "true" ] && [ "$(st key)" = "true" ] && return 0
    dbg p3-activate >/dev/null; osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$APP_PID"') to true' >/dev/null 2>&1 || true
    sleep 0.2
  done
  return 1
}
others=$(pgrep -f "MuyaNative.app/Contents/MacOS/MuyaNative" | grep -vx "$APP_PID" | wc -l | tr -d ' ')
[ "$others" -gt 0 ] && echo "note: $others other MuyaNative instance(s) running; each key re-activates this app first"
# Safety (a real Cmd+W/T/Q once went to the HOST Muya because it was frontmost while the dev app reported itself active):
# cg-key re-checks the SYSTEM frontmost pid right before posting and posts to the dev app's pid only; any key that
# cannot be delivered safely ABORTS the whole script (exit 3) — never continue, never fall back to another app.
cg() {
  build/cg-key "$APP_PID" "$1"; rc=$?
  case $rc in
    0) ;;
    2) echo "NOT-TRUSTED: cannot post key events"; exit 2 ;;
    3) echo "ABORT: the dev app (pid $APP_PID) is not the frontmost app, so no key was sent (key $1). Run when nothing else takes the focus."; exit 3 ;;
    *) echo "ABORT: cg-key failed ($rc) for $1"; exit 3 ;;
  esac
}
key() {
  ensure_active
  if [ "${P3_INPROCESS:-}" = 1 ]; then dbg "p3-key $1" >/dev/null   # explicit opt-in: NSApp.sendEvent inside the app, no system event at all
  else cg "$1"; fi
  sleep "${2:-0.35}"
}
st() { dbg p3-state | tr ' ' '\n' | sed -n "s/^$1=//p"; }
shot() { id=$(dbg windowid); screencapture -x -o -l "$id" "screenshots/p3-$1.png" 2>/dev/null; }

mkdir -p "$DEV/home/p3"
for _ in $(seq 40); do case "$(dbg "new $DEV/home/p3")" in ok*) break ;; esac; sleep 0.25; done
sleep 1.2
dbg p3-activate >/dev/null; osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$APP_PID"') to true' >/dev/null 2>&1 || true
sleep 0.5
if [ "${P3_INPROCESS:-}" = 1 ]; then echo "key path: NSApp.sendEvent (P3_INPROCESS=1, no system events)"
else build/cg-key "$APP_PID" --check >/dev/null || { echo "ABORT: the dev app (pid $APP_PID) is not the frontmost app; no key will be sent."; exit 3; }; echo "key path: CGEvent posted to pid $APP_PID (frontmost checked before every key)"; fi

echo "== terminal bytes (real key events; cat -v shows what the program receives)"
# -icanon -echo -icrnl: every byte arrives as typed (no line editing, no echo, \r stays ^M), so cat -v shows it exactly.
fresh() { dbg "new $DEV/home/p3" >/dev/null; sleep 1.2; dbg p3-focus-terminal >/dev/null; dbg 'type "clear; stty -icanon -echo -icrnl; cat -v\n"' >/dev/null; sleep 0.6; }
bytes() { # name, combo, expected first line of the screen
  fresh; key "$2" 0.6
  check "$1" "$(dbg text | sed -n 1p)" "$3"
}
# cat -ve marks a line feed as "$": Shift+Enter must give "$" (a bare \n), plain Enter would give "^M".
dbg "new $DEV/home/p3" >/dev/null; sleep 1.2; dbg p3-focus-terminal >/dev/null; dbg 'type "clear; stty -icanon -echo -icrnl; cat -ve\n"' >/dev/null; sleep 0.6
key shift+return 0.6; check "Shift+Enter writes \\n" "$(dbg text | sed -n 1p)" '$'
dbg "new $DEV/home/p3" >/dev/null; sleep 1.2; dbg p3-focus-terminal >/dev/null; dbg 'type "clear; stty -icanon -echo -icrnl; cat -ve\n"' >/dev/null; sleep 0.6
key return 0.6; check "plain Enter is still ^M" "$(dbg text | sed -n 1p)" '^M'
bytes "Option+Left = ESC b" "opt+left" "^[b"
bytes "Option+Right = ESC f" "opt+right" "^[f"
bytes "Option+Up = plain Up" "opt+up" "^[[A"
bytes "Option+Down = plain Down" "opt+down" "^[[B"
bytes "Cmd+R = Ctrl+R" "cmd+r" "^R"
bytes "Cmd+L = Ctrl+L" "cmd+l" "^L"
bytes "Cmd+A = Ctrl+A" "cmd+a" "^A"
bytes "Cmd+E = Ctrl+E" "cmd+e" "^E"
bytes "Cmd+U = Ctrl+U" "cmd+u" "^U"
# Cmd+D: ^D ends cat; the echo after it proves the EOF arrived.
dbg "new $DEV/home/p3" >/dev/null; sleep 1.2; dbg p3-focus-terminal >/dev/null
dbg 'type "clear; cat -v; echo EOF-SEEN\n"' >/dev/null; sleep 0.6; key cmd+d 0.8
check "Cmd+D = Ctrl+D (cat sees EOF)" "$(dbg text | grep -c EOF-SEEN)" "1"
# Cmd+C without a selection is Ctrl+C: the tty echoes ^C and cat dies.
dbg "new $DEV/home/p3" >/dev/null; sleep 1.2; dbg p3-focus-terminal >/dev/null
dbg 'type "clear; cat -v; echo INT-SEEN\n"' >/dev/null; sleep 0.6; key cmd+c 0.8
t=$(dbg text); case "$t" in *'^C'*) ok "Cmd+C without selection = Ctrl+C" ;; *) bad "Cmd+C without selection: no ^C in [$t]" ;; esac
# Cmd+C with a selection copies it and does not interrupt.
dbg "new $DEV/home/p3" >/dev/null; sleep 1.2; dbg p3-focus-terminal >/dev/null
dbg 'type "clear; echo copyme-p3; cat -v\n"' >/dev/null; sleep 1.5
# The general pasteboard is shared with every other app and session on this Mac: retry if someone else wrote to it.
got=0
for _ in 1 2 3; do
  printf 'before' | pbcopy; dbg p3-selectall >/dev/null; key cmd+c 0.6
  got=$(pbpaste | grep -c copyme-p3); [ "$got" = 1 ] && break
done
check "Cmd+C with selection copies" "$got" "1"
dbg 'type "x"' >/dev/null; sleep 0.4
case "$(dbg text)" in *'^C'*) bad "Cmd+C with selection must not interrupt" ;; *) ok "Cmd+C with selection does not interrupt" ;; esac
# Cmd+Shift+C types the claude launch command (cat -v shows it without running it).
fresh; key cmd+shift+c 0.6
check "Cmd+Shift+C types the claude command" "$(dbg text | sed -n 1p)" "claude --permission-mode auto^M"

echo "== app shortcuts"
for id in $(dbg sessions | cut -f1); do dbg "close $id" >/dev/null; done; sleep 0.5
for n in 1 2 3; do dbg "new $DEV/home/p3" >/dev/null; sleep 0.8; done
ids=($(dbg sessions | cut -f1)); dbg "select ${ids[0]}" >/dev/null; sleep 0.3
key cmd+2; check "Cmd+2 selects the 2nd agent" "$(st selected)" "${ids[1]}"
key cmd+3; check "Cmd+3 selects the 3rd agent" "$(st selected)" "${ids[2]}"
key cmd+1; check "Cmd+1 selects the 1st agent" "$(st selected)" "${ids[0]}"
key cmd+9; check "Cmd+9 with 3 agents does nothing" "$(st selected)" "${ids[0]}"
check "sidebar starts shown" "$(st sidebar)" "shown"
key cmd+b; check "Cmd+B hides the agents panel" "$(st sidebar)" "hidden"; shot sidebar-hidden
key cmd+b; check "Cmd+B shows it again" "$(st sidebar)" "shown"
first=$(st inspector)
key cmd+opt+b; second=$(st inspector)
[ "$first" != "$second" ] && ok "Cmd+Opt+B toggles the inspector ($first -> $second)" || bad "Cmd+Opt+B: inspector stayed $first"
key cmd+opt+b; check "Cmd+Opt+B toggles it back" "$(st inspector)" "$first"
n0=$(st sessions); key cmd+t 1.5
check "Cmd+T opens a terminal" "$(st sessions)" "$((n0 + 1))"
key cmd+k; check "Cmd+K opens the command palette" "$(st palette)" "true"; shot palette
key cmd+k; check "Cmd+K closes it" "$(st palette)" "false"

echo "== grid keys"
dbg "grid on" >/dev/null; sleep 0.5; dbg p3-focus-terminal >/dev/null
key esc; check "Esc inside a terminal stays in the grid" "$(st grid)" "true"
dbg p3-focus-none >/dev/null; key esc; check "Esc outside a terminal leaves the grid" "$(st grid)" "false"
dbg "grid on" >/dev/null; sleep 0.5; key cmd+return; check "Cmd+Enter maximizes the focused panel" "$(st grid)" "false"

echo "== font size"
c0=$(st cell); key cmd+=; check "Cmd+= bigger" "$(st font)" "14"; c1=$(st cell)
[ "$c0" != "$c1" ] && ok "cell size changed ($c0 -> $c1)" || bad "cell size did not change ($c0)"
key cmd+-; check "Cmd+- smaller" "$(st font)" "13"
for _ in 1 2 3 4 5 6 7; do key cmd+= 0.1; done; check "font steps up" "$(st font)" "20"; key cmd+0; check "Cmd+0 resets to 13" "$(st font)" "13"
for _ in $(seq 20); do key cmd+- 0.05; done; check "font floor is 9" "$(st font)" "9"; key cmd+0 >/dev/null
check "font size is stored in prefs" "$(python3 -I -c "import json,sys;print(json.load(open('$DEV/home/Library/Application Support/MuyaNative/prefs.json')).get('terminalFontSize'))")" "13"

echo "== File menu keys: Close Tab / Reopen Closed Tab / New File / Open"
echo "p3 file" > "$DEV/home/p3/note.txt"
dbg "viewer-open $DEV/home/p3/note.txt" >/dev/null; sleep 0.4
check "viewer is open" "$(st viewer)" "shown"
key cmd+w; check "Cmd+W closes the file in view first" "$(st viewer)" "hidden"
key cmd+shift+t 0.6; check "Cmd+Shift+T reopens the closed file" "$(st viewer)" "shown"
dbg viewer-close >/dev/null
n0=$(st sessions); key cmd+w 0.6; check "Cmd+W with no file closes the selected session" "$(st sessions)" "$((n0 - 1))"
key cmd+shift+t 1.5; check "Cmd+Shift+T brings the session back" "$(st sessions)" "$n0"
key cmd+n 1; check "Cmd+N opens the New File dialog" "$(dbg p3-panels)" "save"; shot new-file-dialog
dbg p3-dismiss >/dev/null; sleep 0.5
key cmd+o 1; check "Cmd+O opens the Open dialog" "$(dbg p3-panels)" "open"; dbg p3-dismiss >/dev/null; sleep 0.5
dbg "p3-createfile $DEV/home/p3/created.txt" >/dev/null
check "New File creates the empty file" "$([ -f "$DEV/home/p3/created.txt" ] && [ ! -s "$DEV/home/p3/created.txt" ] && echo yes)" "yes"
check "and opens it in the viewer" "$(st viewer)" "shown"; dbg viewer-close >/dev/null
printf "a\nb\nc\nd\n" > "$DEV/home/p3/finder.txt"; dbg "p3-open $DEV/home/p3/finder.txt" >/dev/null; sleep 0.3
check "a file handed over by Finder opens (apex://open-file)" "$(dbg viewer | grep -c "5 lines")" "1"; dbg viewer-close >/dev/null

echo "== Cmd+Q: hint on the first press, quit on a second one within 700 ms"
key cmd+q 0.5; check "first Cmd+Q shows the hint" "$(st quithint)" "true"; shot quit-hint
sleep 2.6; check "the hint goes away" "$(st quithint)" "false"
kill -0 "$APP_PID" 2>/dev/null && ok "a single Cmd+Q does not quit" || bad "a single Cmd+Q quit the app"
# Both presses go out back to back (the app is made active once, before): ensure_active between them would eat the 700 ms window.
ensure_active
if [ "${P3_INPROCESS:-}" = 1 ]; then dbg "p3-key cmd+q" >/dev/null; sleep 0.1; dbg "p3-key cmd+q" >/dev/null; else cg cmd+q; sleep 0.1; cg cmd+q; fi
# Wait for THIS app's pid to exit (not for a process name: other MuyaNative instances run too).
for _ in $(seq 60); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.25; done
kill -0 "$APP_PID" 2>/dev/null && bad "double Cmd+Q did not quit (pid $APP_PID still alive after 15 s)" || ok "double Cmd+Q quits"

echo "== result: $fails failure(s)"
[ "$fails" = 0 ]
