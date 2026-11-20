#!/usr/bin/env bash
# The background service is not running (launchd lost the job) or runs from a bundle that was moved to the Trash.
# Fake HOME, own sockets, a tiny "launchd" (job.sh) that the app's "register again" command starts. Nothing of the real login items is touched.
#   1 booted-out job: dead sockets left behind, no daemon -> the app clears them, registers the dead agents again, connects; pages never say "connection closed"
#   2 macOS refuses (register fails twice) -> a precise message with the fix + Retry; after the fix, Retry really starts it
#   3 a daemon whose bundle was moved to the Trash while it ran -> flagged as another copy (the path the kernel reports is the Trash one)
#   4 the daemon's announced release differs from the app's -> flagged even when the path cannot decide; a matching release -> no dialog
# MUYA_BIN_DIR = where muyad / muya-ptyd are (default target/debug). Exit 1 on any FAIL.
set -uo pipefail
cd "$(dirname "$0")"
NATIVE=$(cd .. && pwd)
BIN=${MUYA_BIN_DIR:-$NATIVE/target/debug}
APP=${MUYA_APP_BIN:-$PWD/build/MuyaNative.app/Contents/MacOS/MuyaNative}
[ -x "$BIN/muyad" ] && [ -x "$APP" ] || { echo "build first"; exit 1; }
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1: [$2] has [$3]" ;; *) ok "$1" ;; esac; }

W=""; APPID=""
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$W/app.sock"; }
state() { dbg ac-state | tr ' ' '\n' | sed -n "s/^$1=//p"; }
mk() { # $1 = jobloaded yes|no, $2 = register command mode: start | fail | flag
  W=$(mktemp -d /tmp/muya-rec.XXXXXX); W=$(cd "$W" && pwd -P)
  mkdir -p "$W/B/Muya New.app/Contents/MacOS" "$W/home/.claude" "$W/home/w1"
  cp "$BIN/muyad" "$BIN/muya-ptyd" "$W/B/Muya New.app/Contents/MacOS/"
  NEW="$W/B/Muya New.app/Contents/MacOS"
  cat > "$W/job.sh" <<EOS
#!/bin/sh
while :; do
  if [ "\$1" = ptyd ]; then "$NEW/muya-ptyd" --socket "$W/ptyd.sock"; else "$NEW/muyad" --socket "$W/muyad.sock" --ptyd "$W/ptyd.sock" --broker; fi
  sleep 1
done
EOS
  chmod +x "$W/job.sh"
  # "register again": for each agent named in MUYA_TEST_AGENTS start its job (only when allowed)
  cat > "$W/reg.sh" <<EOS
#!/bin/sh
echo "\$MUYA_TEST_AGENTS" >> "$W/reg.log"
case "$2" in fail) exit 1 ;; flag) [ -f "$W/allow" ] || exit 1 ;; esac
for a in \$MUYA_TEST_AGENTS; do
  case "\$a" in *ptyd*) nohup "$W/job.sh" ptyd >/dev/null 2>&1 & ;; *muyad*) nohup "$W/job.sh" muyad >/dev/null 2>&1 & ;; esac
done
exit 0
EOS
  chmod +x "$W/reg.sh"
  export HOME=$W/home
}
launch_app() { # env passed through
  nohup env MUYA_SOCKET=$W/muyad.sock MUYA_DEBUG_SOCKET=$W/app.sock MUYA_TEST_JOBLOADED="$1" MUYA_TEST_REREGISTER="$W/reg.sh" "${@:2}" "$APP" >"$W/app.log" 2>&1 & APPID=$!
  for _ in $(seq 80); do [ -S "$W/app.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
}
down() {
  [ -n "$W" ] || return
  kill "$APPID" 2>/dev/null
  for pid in $(ps -axo pid=,command= | awk -v w="$W" 'index($0, w) && $0 !~ /awk/ {print $1}'); do [ "$pid" != "$$" ] && kill "$pid" 2>/dev/null; done
  sleep 0.5; for pid in $(ps -axo pid=,command= | awk -v w="$W" 'index($0, w) && $0 !~ /awk/ {print $1}'); do kill -9 "$pid" 2>/dev/null; done
  rm -rf "$W"; W=""
}
trap 'down' EXIT
trap 'exit 130' INT TERM
mksock() { python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()" "$1"; }  # a socket file nobody listens on
wait_state() { for _ in $(seq "${3:-100}"); do [ "$(state "$1")" = "$2" ] && return 0; sleep 0.2; done; return 1; }

echo "== 1 the job was booted out: dead sockets, no daemon"
mk yes start
mksock "$W/muyad.sock"; mksock "$W/ptyd.sock"
launch_app no
dbg "ssh-section vault" >/dev/null
s=$(dbg ssh-state); lacks "before it is up the page never says 'connection closed'" "$s" "connection closed"
wait_state connected true 150 && ok "the app connected without any help from the operator" || bad "never connected: $(dbg ac-status)"
has "the app registered the dead agents again" "$(cat "$W/reg.log" 2>/dev/null)" "ptyd.plist"
has "...muyad too" "$(cat "$W/reg.log" 2>/dev/null)" "muyad.plist"
check "recovery counters reset after the connection" "$(dbg ac-status | sed -n 's/.*attempts=\([0-9]*\).*/\1/p')" "0"
check "the banner is cleared" "$(dbg ac-status | sed -n 's/.*banner=//p' | grep -c 'Not connected\|Starting')" "0"
down

echo "== 2 macOS refuses, then the operator fixes it and presses Retry"
mk yes flag
launch_app no
for _ in $(seq 160); do case "$(state problem)" in unreachable*Login*) break ;; esac; sleep 0.25; done
p=$(dbg ac-state); has "a precise message names Login Items and Retry" "$p" "Login Items"
has "...with Retry" "$p" "Retry"
lacks "...never 'connection closed'" "$p" "connection closed"
dbg "ssh-section vault" >/dev/null; dbg ssh-reload >/dev/null; sleep 1; s=$(dbg ssh-state)
has "the Password Store page shows the same text" "$s" "Login Items"
lacks "...not 'connection closed'" "$s" "connection closed"
touch "$W/allow"; dbg ac-retry >/dev/null
wait_state connected true 150 && ok "Retry really started the service" || bad "Retry did not connect: $(dbg ac-status)"
down

echo "== 3 the daemon's bundle is moved to the Trash while it runs"
mk yes start
mkdir -p "$W/Trash" "$W/A/Muya Old.app/Contents/MacOS"
cp "$NEW/muyad" "$NEW/muya-ptyd" "$W/A/Muya Old.app/Contents/MacOS/"
OLD="$W/A/Muya Old.app/Contents/MacOS"
nohup "$OLD/muya-ptyd" --socket "$W/ptyd.sock" >/dev/null 2>&1 &
for _ in $(seq 50); do [ -S "$W/ptyd.sock" ] && break; sleep 0.1; done
nohup "$OLD/muyad" --socket "$W/muyad.sock" --ptyd "$W/ptyd.sock" >/dev/null 2>&1 &
for _ in $(seq 50); do [ -S "$W/muyad.sock" ] && break; sleep 0.1; done
mv "$W/A/Muya Old.app" "$W/Trash/Muya Old.app"   # what Finder's "Move to Trash" does while the daemon runs
launch_app no MUYA_TEST_EXPECT_MUYAD="$NEW/muyad" MUYA_TEST_EXPECT_PTYD="$NEW/muya-ptyd"
wait_state restart shown 150 && ok "the restart dialog appeared for a daemon running from the Trash" || bad "no dialog: $(dbg ac-state)"
d=$(dbg ac-dialog); has "the dialog names the Trash copy" "$d" "Trash/Muya Old.app"
has "the verdict is another copy" "$(dbg ac-state)" "otherCopy"
down

echo "== 4 the announced release decides when the path cannot"
mk yes start
nohup "$W/job.sh" ptyd >/dev/null 2>&1 &
for _ in $(seq 50); do [ -S "$W/ptyd.sock" ] && break; sleep 0.1; done
nohup "$W/job.sh" muyad >/dev/null 2>&1 &
for _ in $(seq 50); do [ -S "$W/muyad.sock" ] && break; sleep 0.1; done
# no MUYA_TEST_EXPECT_MUYAD: the path has nothing to compare with; the app claims release 9.9.9, the daemon announces its own
launch_app no MUYA_TEST_EXPECT_PRODUCT=9.9.9
wait_state restart shown 100 && ok "an older release is flagged without a path" || bad "no dialog: $(dbg ac-state)"
has "...as a different build" "$(dbg ac-state)" "differentBuild"
has "...naming the releases" "$(dbg ac-dialog)" "9.9.9"
kill "$APPID" 2>/dev/null; sleep 0.5
STAMP=$(strings "$NEW/muyad" | grep -c "+9.9.9"); echo "   (daemon stamp present: $STAMP)"
down
echo "failures=$fails"
[ "$fails" = 0 ]
