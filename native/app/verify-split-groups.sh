#!/usr/bin/env bash
# The whole split-GROUP feature set of classic Muya, against the real app (throwaway stack, fake HOME, own sockets; kills only what it started).
# Checklist = src/lib/controlSplit.ts + src/redesign/AgentList.tsx + src/App.tsx "Split Control":
#   1 create: Split (clone joins, same name, same folder) and drag a session onto another (middle of the row)
#   2 add to an existing group: Split again, drop on the group's header row
#   3 remove: drag a member to the list's empty space (back to a page of its own), × on a pane, dissolve at one
#   4 reorder: drop on the top / bottom quarter of a row; a member moved among loose sessions leaves its split
#   5 ⌘1–9 pick the Nth agent as LISTED (open splits, PINNED, status sections), not the daemon's order
#   6 persistence: groups, collapsed state and the list order survive an app restart
# Screenshots dark + light per action in screenshots/groups-*.png. Exit 1 on any FAIL.
set -uo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d /tmp/muya-grp.XXXXXX)
export TMPDIR=$WORK
STATE=$WORK/muya-native-dev.state
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
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
# The groups with their keys cut back to session ids (a key is `<id>:<pid>`), for comparing with the ids here.
gids() { st groups | sed 's/:[0-9]*//g'; }
npanes() { dbg split-state | sed -n 's/.*panes=\[\([^]]*\)\].*/\1/p' | tr ';' '\n' | grep -c .; }
order() { dbg sessions | awk '{print $1}' | tr '\n' ',' | sed 's/,$//'; }
pos() { order | tr ',' '\n' | grep -n -x -E "$1|$2" | cut -d: -f2 | tr '\n' ' '; }
shot() { for m in dark light; do dbg "appearance $m" >/dev/null; sleep 0.5; screencapture -x -o -l "$(dbg windowid)" "screenshots/groups-$1-$m.png" 2>/dev/null; done; dbg "appearance dark" >/dev/null; }
mkdir -p "$DEV/home/a" "$DEV/home/d" "$DEV/home/e" "$DEV/home/f"
for _ in $(seq 40); do case "$(dbg "new $DEV/home/a")" in ok*) break ;; esac; sleep 0.25; done
sleep 1.2
A=$(dbg sessions | head -1 | awk '{print $1}'); dbg "select $A" >/dev/null; sleep 0.5

echo "== 1 create a group"
dbg split-add >/dev/null; sleep 1.5
B=$(st selected)
check "Split made a group of two" "$(st groups | tr ',' '\n' | grep -c .)" "2"
check "the clone keeps the source's name (a plain shell is not renamed)" "$(dbg sessions | awk -v b="$B" '$1==b{print $2}')" "a"
check "the clone starts in the source's folder" "$(dbg sessions | awk -v b="$B" '$1==b{print $3}')" "~/a"
check "the clone is the selected pane" "$([ "$B" != "$A" ] && echo yes)" "yes"
G=$(st groups | sed -n 's/^\[\([^=]*\)=.*/\1/p')
shot 1-split
D=$(dbg "new $DEV/home/d" | awk '{print $2}'); sleep 0.8
dbg "split-group $D $A" >/dev/null; sleep 1   # dropped on the middle of A's row
has "drag a session onto another joins A's group (shows at once)" "$(gids)" "$A,$B,$D"
check "three panes side by side" "$(npanes)" "3"
check "the dropped-on session is focused" "$(st selected)" "$A"
shot 2-dropped-on-row

echo "== 2 add to an existing group"
E=$(dbg "new $DEV/home/e" | awk '{print $2}'); sleep 0.8
dbg "split-into $E $G" >/dev/null; sleep 1   # dropped on the SPLITS row of the group
has "a session dropped on the group's header row joins it" "$(gids)" ",$E"
check "four panes: 2 columns x 2 rows" "$(dbg split-state | sed -n 's/.*panes=\[\([^]]*\)\].*/\1/p' | tr ';' '\n' | awk -F'[:,]' '{print $3}' | sort -u | wc -l | tr -d ' ')" "2"
shot 3-four-panes
dbg "select $A" >/dev/null; sleep 0.4
dbg split-add >/dev/null; sleep 1.5
check "Split adds a fifth pane to the same group" "$(npanes)" "5"
C=$(st selected)

echo "== 3 remove from a group"
dbg "split-ungroup $C" >/dev/null; sleep 1   # dragged to the empty space of the list
check "a member dropped on empty space leaves the split" "$(gids | grep -c "[=,]$C[,;]\|[=,]$C\$\|[=,]$C\]")" "0"
check "...the group keeps the others" "$(st groups | tr ',' '\n' | grep -c .)" "4"
check "...and its session keeps running" "$(dbg sessions | awk -v c="$C" '$1==c' | wc -l | tr -d ' ')" "1"
dbg "select $C" >/dev/null; sleep 0.6
check "...and shows alone on its own page" "$(npanes)" "0"
check "the list shows C once (4 in the split + 1 loose = 5 rows)" "$(dbg agents-order | tr ',' '\n' | sort | uniq -d | wc -l | tr -d ' ')/$(dbg agents-order | tr ',' '\n' | grep -c .)" "0/5"
read -r sy dh vh <<<"$(dbg agents-scroll)"
[ "$dh" -gt "$vh" ] && ok "the list is longer than the column ($dh > $vh): it scrolls" || bad "list not longer than the column ($dh/$vh)"
[ "$sy" -gt 0 ] && ok "the selected loose session was scrolled into view (offset $sy)" || bad "selected row not revealed (offset $sy)"
shot 4-ungrouped
check "the list scrolls by hand (to the top)" "$(dbg 'agents-scroll 0' | cut -d' ' -f1)" "0"
shot 4b-scrolled-top
dbg "agents-scroll 9999" >/dev/null
dbg "split-ungroup $C" >/dev/null; sleep 0.3
check "ungrouping a loose session does nothing" "$(st groups | tr ',' '\n' | grep -c .)" "4"
dbg "select $A" >/dev/null; sleep 0.5
dbg "split-close $D" >/dev/null; sleep 0.6
check "× on a pane leaves the group (3 left), the session runs" "$(npanes)/$(dbg sessions | awk -v d="$D" '$1==d' | wc -l | tr -d ' ')" "3/1"
dbg "split-close $E" >/dev/null; sleep 0.6
dbg "split-close $B" >/dev/null; sleep 0.6
check "a group left with one session dissolves" "$(st groups)" "[]"
check "...and the survivor shows alone" "$(npanes)" "0"
shot 5-dissolved

echo "== 4 reorder"
dbg "split-group $B $A" >/dev/null; sleep 0.8   # group [A,B] again; loose: C D E
dbg "split-reorder $E $C" >/dev/null; sleep 0.6
check "E dropped on C's top quarter lands before C" "$(pos "$E" "$C")" "$E $C "
check "a reorder among loose sessions leaves the groups alone" "$(st groups | tr ',' '\n' | grep -c .)" "2"
dbg "split-reorder $B $E" >/dev/null; sleep 0.8   # a member moved among loose sessions
check "a split member dropped between loose sessions leaves its split" "$(st groups)" "[]"
check "...and takes that place in the list" "$(pos "$B" "$E")" "$B $E "
shot 6-reordered

echo "== 5 ⌘1–9 follow the list as shown"
dbg "split-group $D $C" >/dev/null; sleep 0.8
dbg "split-group $A $B" >/dev/null; sleep 0.8
listed=$(dbg agents-order)
dbg 'p3-key cmd+1' >/dev/null; sleep 0.6
check "⌘1 selects the first listed agent ($listed)" "$(st selected)" "$(echo "$listed" | cut -d, -f1)"
dbg 'p3-key cmd+3' >/dev/null; sleep 0.6
check "⌘3 selects the third listed agent" "$(st selected)" "$(echo "$listed" | cut -d, -f3)"
check "open splits list first, then the loose sessions" "$listed" "$C,$D,$B,$A,$E"

echo "== 6 persistence"
gid=$(st groups | sed -n 's/^\[\([^=]*\)=.*/\1/p')
dbg "split-collapse $gid" >/dev/null; sleep 0.4
gbefore=$(st groups); obefore=$(order); cbefore=$(st collapsed)
kill "$APP_PID" 2>/dev/null; sleep 1.5
./run-dev.sh app >/dev/null; . "$STATE"
for _ in $(seq 80); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
sleep 3
check "groups survive a restart" "$(st groups)" "$gbefore"
check "collapsed state survives a restart" "$(st collapsed)" "$cbefore"
check "the dragged list order survives a restart" "$(order)" "$obefore"
shot 7-restarted
echo "failures=$fails"
[ "$fails" = 0 ]
