#!/usr/bin/env bash
# AC12 notifications end to end, three paths, each on a throwaway dev stack (own TMPDIR, own HOME, own sockets):
#   A  app running   -> the APP posts through UNUserNotificationCenter (muyad stays silent); a click selects the session
#   B  app quit      -> muyad launches the helper app (MuyaNotifier.app) with the text
#   C  helper absent -> muyad falls back to osascript (a fake osascript records its argv; nothing real is shown)
# No system dialog is opened and no real banner needs clicking: the app reports what it handed to the notification
# center (`notify-state`) and, when Muya has notification permission, the system's delivered list (`notify-delivered`);
# the helper writes one result line to MUYA_NOTIFIER_LOG. With no permission granted those two paths end in
# "not-asked" (helper exit 3) — that is the asserted outcome, and the delivered-list check is reported as skipped.
# Needs a logged-in GUI session and: (cd native && cargo build --workspace), native/app/build.sh.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-notif.XXXXXX)  # its own dir per run: a fixed one collides with another dev stack / a leftover
mkdir -p "$TMPDIR"
STATE=$TMPDIR/muya-native-dev.state
MINPATH=/usr/bin:/bin:/usr/sbin:/sbin
FAILS=0
expect() { if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi; }
absent() { if [ ! -s "$2" ]; then echo "PASS $1"; else echo "FAIL $1: $2 has: $(cat "$2")"; FAILS=$((FAILS + 1)); fi; }
wait_for() { local out="" end=$((SECONDS + ${4:-12})); while [ $SECONDS -lt $end ]; do out=$(eval "$2"); [[ "$out" == *"$3"* ]] && { echo "PASS $1"; return; }; sleep 0.25; done; echo "FAIL $1: got '$out', wanted '$3'"; FAILS=$((FAILS + 1)); }

[ -f "$STATE" ] && ./run-dev.sh stop >/dev/null 2>&1
HELPER_DIR=$TMPDIR/helper
bash ../helpers/notifier/build.sh "$HELPER_DIR" >/dev/null || { echo "FAIL helper build"; exit 1; }
FAKE_OSA=$TMPDIR/osascript
OSA_LOG=$TMPDIR/osascript.log
HELPER_LOG=$TMPDIR/helper.log
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\n' "$OSA_LOG" > "$FAKE_OSA"; chmod +x "$FAKE_OSA"

# permission.py is a bare fake dialog: the parser finds no tool title in it, so all three paths say "a tool" (the tool + target wording is unit-tested).
BODY="Claude is asking permission to use a tool"
TITLE="Muya: permission needed"

stack_up() { # extra env for muyad is exported by the caller
  rm -f "$OSA_LOG" "$HELPER_LOG"
  PATH=$MINPATH MUYA_DEV_NO_APP=1 ./run-dev.sh start >/dev/null || exit 1
  . "$STATE"
  python3 -I make-pages-fixtures.py "$DEV/home" 14 >/dev/null
  python3 -I make-4e-fixtures.py "$DEV/home" >/dev/null
  # A prompt that appears 5 s after the command is typed (fake claude: the permission.py dialog).
  printf 'sleep 5; python3 -I %s/permission.py\n' "$DEV/home" > "$DEV/slow-prompt.txt"
}
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock"; }
stack_down() { ./run-dev.sh stop >/dev/null 2>&1; }
trap 'stack_down' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
export MUYA_NOTIFIER_LOG=$HELPER_LOG MUYA_NOTIFIER_NO_PROMPT=1 MUYA_OSASCRIPT=$FAKE_OSA

echo "=== A: app running — the app posts, muyad stays silent"
export MUYA_NOTIFIER_APP=$HELPER_DIR/MuyaNotifier.app
stack_up
PATH=$MINPATH ./run-dev.sh app >/dev/null; . "$STATE"
sleep 2.5
dbg "new $DEV/home" >/dev/null; sleep 1
A=$(dbg sessions | awk -F'\t' 'NR==1 {print $1}')
dbg "new $DEV/home" >/dev/null; sleep 1
B=$(dbg sessions | awk -F'\t' 'NR==2 {print $1}')
echo "sessions: prompt in $A, selected $B"
dbg "select $A" >/dev/null
dbg "type \"python3 -I $DEV/home/permission.py\\n\"" >/dev/null
dbg "select $B" >/dev/null   # looking at another session: the prompt in $A needs a banner
wait_for "app handed the notice to the notification center" "dbg notify-state" "posted=1" 15
S=$(dbg notify-state); echo "$S"
expect "title" "$S" "$TITLE"
expect "body is the daemon's text" "$S" "$BODY"
expect "notice is for the prompting session" "$S" "$A"$'\t'
if [[ "$S" == *"auth=authorized"* ]]; then
  expect "delivered list holds the notice" "$(dbg notify-delivered)" "$BODY"
else
  echo "SKIP delivered-list check (notification permission: $(echo "$S" | sed -n '1s/ .*//p'); a test run never opens the system dialog)"
fi
sleep 3
absent "muyad stayed silent while the app was attached (no helper)" "$HELPER_LOG"
absent "muyad stayed silent while the app was attached (no osascript)" "$OSA_LOG"
dbg "notify-click $A" >/dev/null
expect "click selects the session that asked" "$(dbg sessions | grep "^$A")" $'\t*'
# Idle CPU of the app with nothing going on (10 s average over a 1 s ps sample is noise-free enough for "about zero").
sleep 5
CPU=$(ps -o %cpu= -p "$APP_PID" | tr -d ' ')
echo "app idle CPU: $CPU %"
expect "idle CPU under 2 %" "$(awk -v c="$CPU" 'BEGIN { print (c < 2.0) ? "low" : "high" }')" "low"

echo "=== B: app quit — muyad launches the helper"
dbg "new $DEV/home" >/dev/null; sleep 1
C=$(dbg sessions | awk -F'\t' 'END {print $1}')
dbg "select $C" >/dev/null
dbg "type \"sleep 6; python3 -I $DEV/home/permission.py\\n\"" >/dev/null
sleep 1
# Quit only the app we started (exact PID); the daemons keep the session.
kill "$APP_PID" 2>/dev/null; for _ in $(seq 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.25; done
wait_for "helper ran with the text and the session id" "cat $HELPER_LOG 2>/dev/null" "outcome=not-asked session=$C title=$TITLE body=$BODY" 20
absent "no osascript while the helper works" "$OSA_LOG"
stack_down

echo "=== C: helper missing — osascript last resort"
export MUYA_NOTIFIER_APP=$TMPDIR/no-such-helper.app
stack_up
PATH=$MINPATH ./run-dev.sh app >/dev/null; . "$STATE"
sleep 2.5
dbg "new $DEV/home" >/dev/null; sleep 1
C=$(dbg sessions | awk -F'\t' 'END {print $1}')
dbg "type \"sleep 6; python3 -I $DEV/home/permission.py\\n\"" >/dev/null
sleep 1
kill "$APP_PID" 2>/dev/null; for _ in $(seq 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.25; done
wait_for "fake osascript got the title and body as argv" "cat $OSA_LOG 2>/dev/null" "$BODY" 20
expect "osascript argv carries the title" "$(cat "$OSA_LOG" 2>/dev/null)" "$TITLE"
absent "no helper ran" "$HELPER_LOG"
stack_down

echo "=== D: click on a helper-posted banner focuses that session (the helper's click path, driven by --click-session)"
export MUYA_NOTIFIER_APP=$HELPER_DIR/MuyaNotifier.app
stack_up
PATH=$MINPATH ./run-dev.sh app >/dev/null; . "$STATE"
sleep 2.5
dbg "new $DEV/home" >/dev/null; sleep 1
A=$(dbg sessions | awk -F'\t' 'NR==1 {print $1}')
dbg "new $DEV/home" >/dev/null; sleep 1
B=$(dbg sessions | awk -F'\t' 'NR==2 {print $1}')
dbg "select $B" >/dev/null
expect "session $B is selected before the click" "$(dbg sessions | grep "^$B")" $'\t*'
# The helper opens muya://session/<A> at the dev app (MUYA_NOTIFIER_TARGET_APP) exactly as it does for a real click.
# The helper hands muya://session/<id> to LaunchServices (`open -a <app>`). LaunchServices delivers it to a RUNNING instance of the app's
# bundle id, and other MuyaNative dev builds (parallel work sessions) share that id: then the URL reaches the wrong process and never this
# one (seen as a "late" click: it never comes). So: the helper's own part is asserted from its log; the app's part is asserted by delivering
# the same URL to THIS pid through the debug socket when LaunchServices did not (and the note says so).
MUYA_NOTIFIER_TARGET_APP=$PWD/build/MuyaNative.app "$HELPER_DIR/MuyaNotifier.app/Contents/MacOS/MuyaNotifier" --click-session "$A" &
clicked=no
for _ in $(seq 24); do dbg sessions | grep "^$A" | grep -q $'\t\*' && { clicked=yes; break; }; sleep 0.25; done
if [ "$clicked" = yes ]; then echo "PASS click selects session $A (URL delivered by LaunchServices)"
else
  others=$(pgrep -f "MuyaNative.app/Contents/MacOS/MuyaNative" | grep -vx "$APP_PID" | wc -l | tr -d ' ')
  echo "note: LaunchServices did not deliver the URL to this app within 6 s ($others other MuyaNative instance(s) running, same bundle id): delivering it through the debug socket"
  dbg "open-url muya://session/$A" >/dev/null
  wait_for "click selects session $A (URL handler of this app)" "dbg sessions | grep '^$A'" $'\t*' 5
fi
wait_for "helper logged the click" "cat $HELPER_LOG" "outcome=clicked session=$A" 5
wait
stack_down

echo "=== done: $FAILS failure(s)"
exit $FAILS
