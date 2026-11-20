#!/usr/bin/env bash
# Stale background services: the app (bundle B) is attached to a muyad / muya-ptyd that run from ANOTHER copy (bundle A, the old
# one, started without --broker). Same protocol, so the handshake sees nothing. Fake HOME, own sockets, a tiny "launchd" loop per
# daemon that restarts whatever `target` names (kills only what it started):
#   1 the app notices: the dialog names the other copy, lists the running sessions; Later keeps everything, the menu entry brings it back
#   2 Restart service: the daemons come back from B (path + the broker socket B serves and A did not), sessions open again, no dialog
#   3 a restart that does NOT change the job (launchd still points at A): the dialog says so, with the exact steps, instead of looping
#   4 a matching service: no dialog at all
# Screenshots dark + light in screenshots/stale-*.png. Exit 1 on any FAIL.
set -uo pipefail
cd "$(dirname "$0")"
NATIVE=$(cd .. && pwd)
BIN=${MUYA_BIN_DIR:-$NATIVE/target/debug}   # MUYA_BIN_DIR=native/target-release/release proves the shipped daemons
APP=${MUYA_APP_BIN:-$PWD/build/MuyaNative.app/Contents/MacOS/MuyaNative}
[ -x "$BIN/muyad" ] && [ -x "$APP" ] || { echo "build first: (cd native && cargo build -p muya-ptyd -p muyad) && native/app/build.sh"; exit 1; }
mkdir -p screenshots
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }

stack() { # $1 = scenario dir name, $2 = the command the app's "register this copy" runs ("switch" = point the job at B)
  W=$(mktemp -d /tmp/muya-stl.XXXXXX); W=$(cd "$W" && pwd -P)
  mkdir -p "$W/A/Muya Old.app/Contents/MacOS" "$W/B/Muya New.app/Contents/MacOS" "$W/home/.claude" "$W/home/w1" "$W/home/w2"
  cp "$BIN/muyad" "$BIN/muya-ptyd" "$W/A/Muya Old.app/Contents/MacOS/"; cp "$BIN/muyad" "$BIN/muya-ptyd" "$W/B/Muya New.app/Contents/MacOS/"
  OLD="$W/A/Muya Old.app/Contents/MacOS"; NEW="$W/B/Muya New.app/Contents/MacOS"
  touch -t 202601010000 "$OLD/muyad" "$OLD/muya-ptyd"; touch -t 202611010000 "$NEW/muyad" "$NEW/muya-ptyd"
  echo "${3:-A}" > "$W/target"
  export HOME=$W/home
  # "launchd": runs the program of the current target (A has no --broker, B has it) and starts it again a second after it exits.
  cat > "$W/job.sh" <<EOS
#!/bin/sh
# job.sh <ptyd|muyad>
while :; do
  t=\$(cat "$W/target"); if [ "\$t" = A ]; then d="$OLD"; flags=""; else d="$NEW"; flags="--broker"; fi
  if [ "\$1" = ptyd ]; then "\$d/muya-ptyd" --socket "$W/ptyd.sock"; else "\$d/muyad" --socket "$W/muyad.sock" --ptyd "$W/ptyd.sock" \$flags; fi
  sleep 1
done
EOS
  chmod +x "$W/job.sh"
  nohup "$W/job.sh" ptyd >"$W/ptyd.log" 2>&1 & JP=$!
  for _ in $(seq 50); do [ -S "$W/ptyd.sock" ] && break; sleep 0.1; done
  nohup "$W/job.sh" muyad >"$W/muyad.log" 2>&1 & JM=$!
  for _ in $(seq 50); do [ -S "$W/muyad.sock" ] && break; sleep 0.1; done
  if [ "$2" = switch ]; then REREG="echo B > '$W/target'"; else REREG="true"; fi
  MUYA_SOCKET=$W/muyad.sock MUYA_DEBUG_SOCKET=$W/app.sock MUYA_TEST_EXPECT_MUYAD="$NEW/muyad" MUYA_TEST_EXPECT_PTYD="$NEW/muya-ptyd" MUYA_TEST_REREGISTER="$REREG" \
    nohup "$APP" >"$W/app.log" 2>&1 & APPID=$!
  for _ in $(seq 80); do [ -S "$W/app.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
}
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$W/app.sock"; }
down() {
  # the jobs first (so nothing restarts), then exactly the daemons they started and the app
  kill "$JM" "$JP" "$APPID" 2>/dev/null; sleep 0.3
  for pid in $(ps -axo pid=,command= | awk -v w="$W" 'index($0, w) {print $1}'); do [ "$pid" != "$$" ] && kill "$pid" 2>/dev/null; done
  sleep 0.5; rm -rf "$W"
}
trap 'down' EXIT
trap 'exit 130' INT TERM
state() { dbg ac-state | tr ' ' '\n' | sed -n "s/^$1=//p"; }
progp() { ps -o command= -p "$1" 2>/dev/null | awk '{print $1}'; }
daemon_pid() { ps -axo pid=,command= | awk -v w="$W" -v n="$1" 'index($0, w) && $2 != "" && $0 ~ n"( |$)" && $0 !~ /job.sh/ && $0 !~ /awk/ {print $1; exit}'; }
shot() { for m in dark light; do dbg "appearance $m" >/dev/null; sleep 0.5; screencapture -x -o -l "$(dbg windowid)" "screenshots/stale-$1-$m.png" 2>/dev/null; done; dbg "appearance dark" >/dev/null; }
wait_for() { for _ in $(seq "${3:-100}"); do [ "$(state "$1")" = "$2" ] && return 0; sleep 0.2; done; return 1; }

echo "== 1 the app notices a service from another copy"
stack one switch
sleep 1.5
for _ in $(seq 40); do case "$(dbg "new $W/home/w1")" in ok*) break ;; esac; sleep 0.25; done
dbg "new $W/home/w2" >/dev/null; sleep 1
oldpid=$(daemon_pid "Muya Old.app/Contents/MacOS/muyad"); oldptyd=$(daemon_pid "Muya Old.app/Contents/MacOS/muya-ptyd")
[ -n "$oldpid" ] && ok "muyad runs from the old copy (pid $oldpid)" || bad "no old muyad"
check "the old muyad has no broker socket" "$([ -S "$W/home/.claude/muya-ssh-broker.sock" ] && echo yes || echo no)" "no"
# the dialog opens when the next connect proves the service (the app connected before the sessions existed: ask again)
dbg 'ac-skew off' >/dev/null; sleep 2.5
check "problem is the stale service" "$(state problem | cut -c1-6)" "stale("
has "...and it is about the muyad program, another copy" "$(dbg ac-state)" "stale(muyad otherCopy"
check "the restart dialog is shown" "$(state restart)" "shown"
d=$(dbg ac-dialog)
has "the dialog names the old copy" "$d" "Muya Old.app"
has "the dialog says the fixes are not active" "$d" "latest fixes"
has "the dialog lists the sessions that restart ends" "$d" "ends the 2 running sessions"
shot 1-dialog
dbg 'ac-click later' >/dev/null; sleep 0.8
check "Later closes the dialog" "$(state restart)" "hidden"
check "Later keeps the same daemon running" "$(daemon_pid "Muya Old.app/Contents/MacOS/muyad")" "$oldpid"
check "Later keeps the sessions" "$(state sessions)" "2"
check "a menu entry offers the restart again" "$(state menu)" "true"
dbg ac-reopen >/dev/null; sleep 0.6
check "the menu entry brings the dialog back" "$(state restart)" "shown"

echo "== 2 Restart service starts this copy's daemons"
dbg 'ac-click restart' >/dev/null
wait_for restart hidden 5 >/dev/null; sleep 4
for _ in $(seq 60); do case "$(state phase)" in Done*|Restarted*|*opened*|*Opened*|*resumed*) break ;; esac; sleep 0.5; done
st=$(dbg ac-state); echo "   $st"
newpid=$(daemon_pid "Muya New.app/Contents/MacOS/muyad")
[ -n "$newpid" ] && ok "muyad now runs from the new copy (pid $newpid)" || bad "no muyad from the new copy"
[ "$newpid" != "$oldpid" ] && ok "it is a different process" || bad "same pid"
check "the old copy's muyad is gone" "$(daemon_pid "Muya Old.app/Contents/MacOS/muyad")" ""
check "ptyd runs from the new copy too" "$([ -n "$(daemon_pid "Muya New.app/Contents/MacOS/muya-ptyd")" ] && [ -z "$(daemon_pid "Muya Old.app/Contents/MacOS/muya-ptyd")" ] && echo yes)" "yes"
check "the new muyad serves the MCP broker the old one did not" "$([ -S "$W/home/.claude/muya-ssh-broker.sock" ] && echo yes || echo no)" "yes"
check "the sessions were opened again" "$(state sessions)" "2"
check "the folders are the same" "$(dbg sessions | awk '{print $3}' | sort | tr '\n' ' ')" "~/w1 ~/w2 "
shot 2-restarted
dbg 'ac-click restart' >/dev/null; sleep 0.8   # "Done"
sleep 2
check "no stale problem now" "$(state problem)" "none"
check "no dialog" "$(state restart)" "hidden"
down

echo "== 3 a restart that does not change what launchd starts"
stack two keep
sleep 1.5
for _ in $(seq 40); do case "$(dbg "new $W/home/w1")" in ok*) break ;; esac; sleep 0.25; done
sleep 0.5; dbg 'ac-skew off' >/dev/null; sleep 2.5
check "stale detected" "$(state restart)" "shown"
dbg 'ac-click restart' >/dev/null
for _ in $(seq 60); do d=$(dbg ac-dialog); case "$d" in *"came back from the same other copy"*) break ;; esac; sleep 0.5; done
has "the dialog says the old program came back, with the steps" "$d" "came back from the same other copy"
has "...and names the launchctl bootout command" "$d" "launchctl bootout"
check "the old copy's muyad is what runs" "$([ -n "$(daemon_pid "Muya Old.app/Contents/MacOS/muyad")" ] && echo yes)" "yes"
shot 3-still-old
down

echo "== 4 matching services: no dialog"
stack three switch B
sleep 1.5
dbg 'ac-skew off' >/dev/null; sleep 3
check "services from the same copy: no problem" "$(state problem)" "none"
check "...and no dialog" "$(state restart)" "hidden"
echo "failures=$fails"
[ "$fails" = 0 ]
