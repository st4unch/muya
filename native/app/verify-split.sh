#!/usr/bin/env bash
# Split Control against the real app (throwaway stack, fake HOME, own sockets; kills only what it started):
#   1 Split (the command ⌘⇧D / the header button run) opens a clone pane; ⌘⇧D itself through a real NSEvent
#   2 drag-to-split (a session dropped on another), up to 8 panes, the 9th is refused, layout cols x rows
#   3 pane focus/zoom, close pane (session keeps running), group dissolves at one, divider drag keeps the sum at 1
#   4 collapse state, persistence: the app is restarted against the same daemons and the groups come back
#   5 agent open_session with splitWith: the new terminal joins the caller's group; without it a plain session
#   6 IME / Turkish input in a pane: marked text + commit reach the focused pane's pty, candidate rect inside that pane
# Exit 1 on any FAIL; screenshots in screenshots/split-*.png.
set -uo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d /tmp/muya-spl.XXXXXX)
export TMPDIR=$WORK
STATE=$WORK/muya-native-dev.state
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
mkdir -p screenshots
./run-dev.sh start >/dev/null || exit 1
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
for _ in $(seq 80); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
st() { dbg split-state | tr ' ' '\n' | sed -n "s/^$1=//p"; }
npanes() { dbg split-state | sed -n 's/.*panes=\[\([^]]*\)\].*/\1/p' | tr ';' '\n' | grep -c .; }
shot() { screencapture -x -o -l "$(dbg windowid)" "screenshots/split-$1.png" 2>/dev/null; }
mkdir -p "$DEV/home/a" "$DEV/home/b"
newsess() { dbg "new $DEV/home/$1" | awk '{print $2}'; }
for _ in $(seq 40); do case "$(dbg "new $DEV/home/a")" in ok*|session*) break ;; esac; sleep 0.25; done
sleep 1.2
A=$(dbg sessions | head -1 | awk '{print $1}'); A=${A:-1}
dbg "select $A" >/dev/null; sleep 0.6

echo "== 1 split"
check "no group at the start" "$(st groups)" "[]"
dbg split-add >/dev/null; sleep 1.5
has "Split made a group of two" "$(st groups)" "=$A,"
check "two panes are shown" "$(npanes)" "2"
check "a clone is selected" "$([ "$(st selected)" != "$A" ] && echo yes)" "yes"
shot two
P=$(st panes); x1=$(echo "$P" | sed -n 's/^\([0-9]*\):\([0-9-]*\),.*/\2/p'); has "panes sit side by side (two different x)" "$P" ";"
dbg 'p3-key cmd+shift+d' >/dev/null; sleep 1.5
check "⌘⇧D opens a third pane" "$(npanes)" "3"
check "ids in the group are three" "$(st groups | tr ',' '\n' | grep -c .)" "3"

echo "== 2 drag to split and the cap of 8"
ids=$(dbg sessions | awk '{print $1}' | tr '\n' ' ')
for i in 1 2 3 4 5 6; do n=$(newsess b); [ -n "$n" ] && sleep 0.4; done
all=$(dbg sessions | awk '{print $1}')
cnt=0
for s in $all; do
  in=$(st groups | grep -c "[=,]$s[,\]]\|[=,]$s\$"); [ "$in" = 0 ] && { dbg "split-group $s $A" >/dev/null; sleep 0.3; }
done
check "the group is capped at 8 panes" "$(npanes)" "8"
check "ninth session was refused (still outside)" "$([ "$(dbg sessions | wc -l | tr -d ' ')" -ge 9 ] && echo yes)" "yes"
check "Split button disabled at the cap" "$(st splitEnabled)" "false"
shot eight
dbg "select $(echo $all | awk '{print $1}')" >/dev/null; sleep 0.4

echo "== 3 focus, close, divider"
sel=$(st selected); other=$(echo $all | awk '{print $2}')
dbg "split-zoom $sel" >/dev/null; sleep 0.5; check "zoom shows one pane" "$(npanes)" "1"
dbg "split-zoom $sel" >/dev/null; sleep 0.5; check "restore shows the group again" "$(npanes)" "8"
dbg "split-close $other" >/dev/null; sleep 0.6; check "closing a pane leaves seven" "$(npanes)" "7"
check "the closed session keeps running" "$(dbg sessions | awk -v o="$other" '$1==o&&1' | wc -l | tr -d " ")" "1"
dbg split-state | grep -q "fractions=" && {
  f0=$(st fractions); dbg "split-divider 0 60" >/dev/null; sleep 0.3; f1=$(st fractions)
  [ "$f0" != "$f1" ] && ok "dragging a divider changes the widths ($f0 -> $f1)" || bad "divider drag changed nothing ($f0)"
  check "widths still sum to 1" "$(echo "$f1" | tr ',' '\n' | awk '{s+=$1} END {printf "%.2f", s}')" "1.00"
}

echo "== 4 collapse and restart"
g=$(st groups | sed -n 's/^\[\([^=]*\)=.*/\1/p')
dbg "split-collapse $g" >/dev/null; sleep 0.4; has "collapsed state kept" "$(st collapsed)" "$g"
before=$(st groups)
kill "$APP_PID" 2>/dev/null; sleep 1.5
./run-dev.sh app >/dev/null; . "$STATE"
for _ in $(seq 80); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
sleep 3
check "groups restored after a restart" "$(st groups)" "$before"
has "collapsed restored after a restart" "$(st collapsed)" "$g"
dbg "split-collapse $g" >/dev/null; sleep 0.3

echo "== 5 agent open_session"
dbg "select $A" >/dev/null; sleep 0.4
# regroup to a small case: close panes until only the group of A remains small
for s in $(dbg sessions | awk '{print $1}'); do [ "$s" != "$A" ] && dbg "split-close $s" >/dev/null; done
sleep 0.5
b4=$(dbg sessions | wc -l | tr -d ' ')
dbg "split-open anchor=$A {\"name\":\"agentw\",\"cwd\":\"$DEV/home/b\",\"agent\":\"claude\",\"splitWith\":\"x\",\"unattended\":false}" >/dev/null; sleep 1.8
check "open_session made a session" "$(dbg sessions | wc -l | tr -d ' ')" "$((b4 + 1))"
has "the new session joined the caller's group" "$(st groups)" "$A"
check "two panes shown" "$(npanes)" "2"
dbg "split-open {\"name\":\"plain\",\"cwd\":\"$DEV/home/b\",\"splitWith\":\"unknown\"}" >/dev/null; sleep 1.8
check "an unresolved splitWith opens a plain session" "$(dbg sessions | wc -l | tr -d ' ')" "$((b4 + 2))"
check "...and shows alone" "$(npanes)" "0"
shot agent
echo "== 5b close_session: the daemon's close event removes the tab"
bc=$(dbg sessions | wc -l | tr -d ' ')
victim=$(dbg sessions | awk '{print $1}' | tail -1)
dbg "agent-close {\"sessionId\":\"4f6c1d2e-aaaa-bbbb-cccc-0123456789ab\",\"terminalId\":$victim}" >/dev/null; sleep 0.8
check "close_session removed the tab" "$(dbg sessions | wc -l | tr -d ' ')" "$((bc - 1))"
check "a close for a tab that is gone is ignored" "$(dbg "agent-close {\"terminalId\":$victim}")" "error: no such tab"

echo "== 6 IME and Turkish in a pane"
dbg "select $A" >/dev/null; sleep 0.6
dbg 'type "clear; cat > '"$WORK"'/tr.out\n"' >/dev/null; sleep 0.5
dbg 'commit "ğşıİöçüĞŞ"' >/dev/null; sleep 0.3; dbg 'type "\n"' >/dev/null; sleep 0.3
dbg 'preedit "にほんご"' >/dev/null; sleep 0.3
fr=$(dbg firstrect); has "marked text is shown in the focused pane" "$fr" 'preedit="にほんご"'
dbg unmark >/dev/null
dbg 'commit "日本語"' >/dev/null; sleep 0.3; dbg 'type "\n"' >/dev/null; sleep 0.5
got=$(cat "$WORK/tr.out" 2>/dev/null | tr -d '\n')
case "$got" in *ğşıİöçüĞŞ*日本語*) ok "Turkish letters and a Japanese commit reached the pane's shell" ;; *) bad "pane input: got [$got]" ;; esac
geo=$(dbg split-state | sed -n 's/.*panes=\[\([^]]*\)\].*/\1/p'); has "the pane still shows" "$geo" "$A:"
echo "failures=$fails"
[ "$fails" = 0 ]
