#!/usr/bin/env bash
# AC19 end to end in the real app: the app is "newer" than the running daemons (debug `ac-skew on` announces another
# protocol major). Expect: the restart dialog lists the live sessions; "Later" keeps all three sessions untouched (same
# ids, same screen hash, still typeable); "Restart service" sends Upgrade, the daemons exit and a stand-in for launchd
# starts them again, the app opens the three sessions again from the resume plan (same folders, same screen hash).
# Everything lives in a throwaway HOME with its own sockets. Stops exactly the PIDs it started. Needs a GUI session.
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
NATIVE=$(cd .. && pwd)
BIN=${MUYA_BIN_DIR:-$NATIVE/target/debug}
APP_BIN=$HERE/build/MuyaNative.app/Contents/MacOS/MuyaNative
export TMPDIR=/tmp/muya-ac1921; mkdir -p "$TMPDIR"
SHOTS=$HERE/screenshots; mkdir -p "$SHOTS"
[ -x "$BIN/muyad" ] && [ -x "$BIN/muya-ptyd" ] && [ -x "$APP_BIN" ] || { echo "build first: cargo build -p muya-ptyd -p muyad; native/app/build.sh"; exit 1; }
DEV=$(mktemp -d "$TMPDIR/ac19.XXXXXX"); DEV=$(cd "$DEV" && pwd -P)
HOMEDIR=$DEV/home; mkdir -p "$HOMEDIR/a" "$HOMEDIR/b" "$HOMEDIR/c" "$DEV/state"
printf "PROMPT='%%~ %%# '\nunsetopt BEEP PROMPT_SP\n" > "$HOMEDIR/.zshrc"
LOOPS=(); APP_PID=
# What launchd does for the two LaunchAgents: start the daemon again when it exits.
keepalive() { ( while :; do HOME=$HOMEDIR PATH=/usr/bin:/bin:/usr/sbin:/sbin "$@"; sleep 0.3; done ) >>"$DEV/daemons.log" 2>&1 & LOOPS+=($!); }
cleanup() {
  [ -n "$APP_PID" ] && case "$(ps -o command= -p "$APP_PID" 2>/dev/null)" in *MuyaNative*) kill "$APP_PID" 2>/dev/null ;; esac
  for l in "${LOOPS[@]:-}"; do [ -n "$l" ] || continue; pkill -P "$l" 2>/dev/null; kill "$l" 2>/dev/null; done
  sleep 0.5; rm -rf "$DEV"
}
trap cleanup EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
FAILS=0
expect() { if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi; }
wait_for() { local out="" end=$((SECONDS + ${4:-15})); while [ $SECONDS -lt $end ]; do out=$(eval "$2"); [[ "$out" == *"$3"* ]] && { echo "PASS $1"; return; }; sleep 0.25; done; echo "FAIL $1: got '$out', wanted '$3'"; FAILS=$((FAILS + 1)); }
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock"; }
shot() { dbg "snap $SHOTS/$1.png" >/dev/null; echo "shot $1"; }
clear_all() { for id in $(dbg ac-sessions | awk -F'\t' '{ print $1 }'); do dbg "select $id" >/dev/null; dbg 'type "clear\n"' >/dev/null; done; sleep 1.5; }
hashes() { dbg ac-sessions | awk -F'\t' '{ print $3 " " $4 }' | sort; }

echo "=== daemons up (with a launchd stand-in), app starts"
keepalive "$BIN/muya-ptyd" --socket "$DEV/ptyd.sock"
for _ in $(seq 50); do [ -S "$DEV/ptyd.sock" ] && break; sleep 0.1; done
keepalive "$BIN/muyad" --socket "$DEV/muyad.sock" --ptyd "$DEV/ptyd.sock" --state-dir "$DEV/state"
for _ in $(seq 50); do [ -S "$DEV/muyad.sock" ] && break; sleep 0.1; done
HOME=$HOMEDIR MUYA_SOCKET=$DEV/muyad.sock MUYA_DEBUG_SOCKET=$DEV/app-debug.sock PATH=/usr/bin:/bin:/usr/sbin:/sbin nohup "$APP_BIN" >"$DEV/app.log" 2>&1 &
APP_PID=$!
wait_for "app connected" "dbg ac-state" "connected=true problem=none" 20
for d in a b c; do dbg "new $HOMEDIR/$d" >/dev/null; sleep 0.5; done
wait_for "three sessions" "dbg ac-state" "sessions=3" 10
clear_all
BEFORE=$(hashes); echo "$BEFORE"
IDS_BEFORE=$(dbg ac-sessions | awk -F'\t' '{ print $1 "," $2 }' | sort)

echo "=== the app is newer than the daemons: dialog"
dbg "ac-settings stub" >/dev/null
dbg "ac-skew on" >/dev/null
wait_for "restart dialog shown" "dbg ac-state" "problem=skew" 15
expect "dialog is up" "$(dbg ac-state)" "restart=shown"
D=$(dbg ac-dialog); echo "$D"
expect "dialog lists the three sessions" "$D" "a [~/a]; b [~/b]; c [~/c]"
expect "buttons" "$D" "Later/Restart service"
dbg "appearance dark" >/dev/null; sleep 1; shot ac19-dialog-dark
dbg "appearance light" >/dev/null; sleep 1; shot ac19-dialog-light
dbg "appearance dark" >/dev/null

echo "=== Later: sessions untouched"
dbg "ac-click later" >/dev/null
wait_for "dialog gone, talking in the daemon's version" "dbg ac-state" "connected=true problem=none onboarding=hidden restart=hidden" 15
wait_for "compat mode, menu entry offered" "dbg ac-state" "compat=true menu=true" 10
expect "same session ids and pids" "$(dbg ac-sessions | awk -F'\t' '{ print $1 "," $2 }' | sort)" "$IDS_BEFORE"
expect "same screen hashes (Later)" "$(hashes)" "$BEFORE"
dbg 'type "echo LATER-OK\n"' >/dev/null
wait_for "session still takes input" "dbg text" "LATER-OK" 10
clear_all
BEFORE=$(hashes)

echo "=== Restart service"
dbg ac-reopen >/dev/null
wait_for "dialog again from the menu" "dbg ac-state" "restart=shown" 10
dbg "ac-click restart" >/dev/null
wait_for "service restarted, sessions opened again" "dbg ac-state" "connected=true problem=none onboarding=hidden restart=shown phase=Done" 90
expect "three sessions again" "$(dbg ac-state)" "sessions=3"
expect "same folders" "$(dbg ac-sessions | awk -F'\t' '{ print $3 }' | sort | tr '\n' ' ')" "$HOMEDIR/a $HOMEDIR/b $HOMEDIR/c"
sleep 2; shot ac19-done-dark
dbg "ac-click done" >/dev/null
wait_for "dialog closed" "dbg ac-state" "restart=hidden" 10
expect "not in compat mode any more" "$(dbg ac-state)" "compat=false"
clear_all
AFTER=$(hashes); echo "$AFTER"
expect "same screen hashes after the restart (prompt per folder)" "$AFTER" "$BEFORE"
dbg 'type "echo NEW-OK\n"' >/dev/null
wait_for "new service takes input" "dbg text" "NEW-OK" 10
expect "app process kept" "$(ps -o pid= -p "$APP_PID" | tr -d ' ')" "$APP_PID"
echo "=== done: $FAILS failure(s)"
exit $FAILS
