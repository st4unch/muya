#!/usr/bin/env bash
# An update must look like Muya 4's did: the app closes and comes back as the new version. One icon, one window.
# 5.0.6 started the new copy as an ordinary app while the old one was still on screen, so a SECOND Muya appeared
# beside it (operator, 2026-11-26: "var olanın yanında yeni bir uygulama açılıyor, eskisi kapanıyor").
#
# Two dev copies of the same bundle (com.staunch.muya.dev — never the installed Muya) in one throwaway HOME:
#   1 the copy started by an update (--switched-from=update) has NO Dock tile and NO window while the old copy lives
#   2 it is not in the app switcher either: exactly one visible copy the whole time
#   3 once the old copy quits, it becomes the visible Muya by itself (Dock tile + window), within a couple of seconds
#   4 a copy whose predecessor never quits still shows itself (the wait has a limit) — asserted by the unit tests
#   5 the sessions survive it: the terminals opened before the update are still there, with their output, after the
#     new copy took over AND the daemon restarted the way launchd restarts it (operator: "oturumlar kopuyor")
#
#   native/app/verify-update-takeover.sh
set -uo pipefail
cd "$(dirname "$0")"
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
WORK=$(mktemp -d /tmp/muya-takeover.XXXXXX)
cleanup() {
  [ -n "${BPID:-}" ] && kill "$BPID" 2>/dev/null
  ./run-dev.sh stop >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

./build.sh >/dev/null 2>&1 || { bad "the app did not build"; exit 1; }

# A probe of what macOS itself thinks: every running copy of the dev bundle id with its activation policy.
# .regular = Dock tile + app switcher; .accessory = running, but nowhere to be seen.
cat > "$WORK/policies.swift" <<'SWIFT'
import AppKit
let id = CommandLine.arguments[1]
for a in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
    let p = a.activationPolicy == .regular ? "regular" : (a.activationPolicy == .accessory ? "accessory" : "prohibited")
    print("\(a.processIdentifier) \(p)")
}
SWIFT
swiftc -O "$WORK/policies.swift" -o "$WORK/policies" 2>/dev/null || { bad "could not build the probe"; exit 1; }
policies() { "$WORK/policies" com.staunch.muya.dev; }
visible_count() { policies | grep -c regular; }

./run-dev.sh start >/dev/null 2>&1 || { bad "the dev stack did not start"; exit 1; }
. "${TMPDIR:-/tmp}/muya-native-dev.state"
dbg() { printf '%s\n' "$2" | nc -U -w 5 "$1"; }
for _ in $(seq 80); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg "$DEV/app-debug.sock" windowid 2>/dev/null)" ] && break; sleep 0.1; done
A=$APP_PID
[ -n "$(dbg "$DEV/app-debug.sock" windowid)" ] || { bad "the first copy never opened its window"; exit 1; }

# Work in progress, the way a user has it when the update arrives: two terminals, one with output on screen.
dbg "$DEV/app-debug.sock" "new $DEV/home" >/dev/null
dbg "$DEV/app-debug.sock" "new $DEV/home" >/dev/null
sleep 2
IDS_BEFORE=$(dbg "$DEV/app-debug.sock" sessions | awk '{print $1}' | sort | tr '\n' ' ')
FIRST=$(echo "$IDS_BEFORE" | awk '{print $1}')
dbg "$DEV/app-debug.sock" "select $FIRST" >/dev/null; sleep 1
MARK="MUYA-SURVIVES-$$"
dbg "$DEV/app-debug.sock" "type \"echo $MARK\\n\"" >/dev/null   # a JSON string; \n is the Enter key
sleep 2
case "$(dbg "$DEV/app-debug.sock" text)" in *"$MARK"*) : ;; *) bad "the test terminal never showed its own output; the session checks below mean nothing"; esac

# The second copy, exactly as the updater starts it.
rm -f "$DEV/b.pid"
HOME=$DEV/home MUYA_SOCKET=$DEV/muyad.sock MUYA_DEBUG_SOCKET=$DEV/b-debug.sock DEVDIR=$DEV \
  nohup bash -c '"$0" --switched-from=update >"$DEVDIR/b.log" 2>&1 & echo $! > "$DEVDIR/b.pid"; wait' \
  "$PWD/build/MuyaNative.app/Contents/MacOS/MuyaNative" >/dev/null 2>&1 &
for _ in $(seq 100); do [ -S "$DEV/b-debug.sock" ] && [ -n "$(dbg "$DEV/b-debug.sock" takeover-state 2>/dev/null)" ] && break; sleep 0.1; done
BPID=$(cat "$DEV/b.pid" 2>/dev/null)
B=$(dbg "$DEV/b-debug.sock" takeover-state)
[ -n "$B" ] || { bad "the update copy never answered"; exit 1; }

case "$B" in
  "accessory 0") ok "the copy started by the update has no Dock tile and no window while the old copy is up ($B)" ;;
  *)             bad "the update copy showed itself straight away: '$B' (5.0.6 behaviour)" ;;
esac
N=$(visible_count)
[ "$N" = 1 ] && ok "exactly one visible Muya during the update (macOS sees $(policies | tr '\n' ';'))" \
             || bad "$N visible copies at once: $(policies | tr '\n' ';')"

# The old copy quits, the way it does when the daemon says the update is done.
kill -TERM "$A" 2>/dev/null
for _ in $(seq 40); do kill -0 "$A" 2>/dev/null || break; sleep 0.1; done
kill -0 "$A" 2>/dev/null && bad "the old copy did not quit"
TOOK=""
for i in $(seq 60); do
  B=$(dbg "$DEV/b-debug.sock" takeover-state 2>/dev/null)
  [ "$B" = "regular 1" ] && { TOOK=$(python3 -c "print(f'{$i*0.25:.1f}')"); break; }
  sleep 0.25
done
[ -n "$TOOK" ] && ok "it became the visible Muya by itself ${TOOK}s after the old copy quit (Dock tile + window)" \
               || bad "it never took over: takeover-state '$B' ($(policies | tr '\n' ';'))"
N=$(visible_count)
[ "$N" = 1 ] && ok "and there is still exactly one visible Muya" || bad "$N visible copies after the takeover"

# An in-place update also restarts the daemon: muyad exits so launchd can start the one inside the new bundle.
# ptyd is NOT restarted — it holds the terminals. The new copy must find them again on its own.
BIN=${MUYA_BIN_DIR:-$(cd .. && pwd)/target/debug}
kill "$MUYAD_PID" 2>/dev/null
for _ in $(seq 40); do kill -0 "$MUYAD_PID" 2>/dev/null || break; sleep 0.1; done
HOME=$DEV/home nohup "$BIN/muyad" --socket "$DEV/muyad.sock" --ptyd "$DEV/ptyd.sock" --broker >>"$DEV/muyad2.log" 2>&1 &
MUYAD2=$!
for _ in $(seq 100); do [ -S "$DEV/muyad.sock" ] && break; sleep 0.1; done
IDS_AFTER=""
for _ in $(seq 60); do
  IDS_AFTER=$(dbg "$DEV/b-debug.sock" sessions 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' ')
  [ -n "$IDS_AFTER" ] && [ "$IDS_AFTER" = "$IDS_BEFORE" ] && break
  sleep 0.5
done
[ "$IDS_AFTER" = "$IDS_BEFORE" ] && ok "the terminals came through the update: same sessions ($IDS_BEFORE)" \
                                 || bad "sessions lost or renumbered: before [$IDS_BEFORE] after [$IDS_AFTER]"
dbg "$DEV/b-debug.sock" "select $FIRST" >/dev/null
GOT=""
for _ in $(seq 30); do
  T=$(dbg "$DEV/b-debug.sock" text 2>/dev/null)
  case "$T" in *"$MARK"*) GOT=yes; break;; esac
  sleep 0.5
done
if [ -n "$GOT" ]; then
  ok "and they kept their output: the new copy re-attached and replayed the terminal, it did not restart it"
else
  bad "the terminal came back empty after the update (bytes: $(dbg "$DEV/b-debug.sock" bytes | tr '\n' ' '); last text: $(dbg "$DEV/b-debug.sock" text | tr '\n' '|' | tail -c 120))"
fi
kill "$MUYAD2" 2>/dev/null

echo "RESULT: $([ $fails = 0 ] && echo PASS || echo "FAIL ($fails)")"
exit $fails
