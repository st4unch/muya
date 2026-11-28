#!/usr/bin/env bash
# ⌘T opens a PLAIN terminal, never one inside a split.
#
# The bug: a split group was persisted by the daemon's session id alone ("1", "2"), and muya-ptyd hands out
# session ids from 1 again every time it starts (muya-ptyd/src/lib.rs next_id = 1). So a split made in an
# earlier run matched the terminals of the NEXT run: ⌘T opened straight into a split, next to a terminal the
# operator never asked for. `SplitModel.resolve(existing:)` was never called, so nothing cleaned it up either.
#
# This is a live check against the real app with real daemons, in a throwaway HOME with its own sockets; it
# starts and kills only its own processes and never touches the installed Muya, its daemons or its prefs.
# The point of the two phases is that the stale prefs are written by the app ITSELF, not by hand:
#   phase 1  make a split, then stop the app and both daemons (the prefs keep the group)
#   phase 2  start fresh daemons on the SAME HOME (ids start at 1 again) and press ⌘T
#
#   native/app/verify-newterminal-split.sh      (build first: native/app/build.sh; cargo build -p muyad -p muya-ptyd)
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
NATIVE=$(cd .. && pwd)
BIN=${MUYA_BIN_DIR:-$NATIVE/target/debug}
APP_BIN=$HERE/build/MuyaNative.app/Contents/MacOS/MuyaNative
[ -x "$BIN/muya-ptyd" ] && [ -x "$BIN/muyad" ] || { echo "FAIL build the daemons first: (cd native && cargo build -p muya-ptyd -p muyad)"; exit 1; }
[ -x "$APP_BIN" ] || { echo "FAIL build the app first: native/app/build.sh"; exit 1; }

WORK=$(mktemp -d /tmp/muya-cmdt.XXXXXX)
WORK=$(cd "$WORK" && pwd -P)
export TMPDIR=$WORK
FAKE=$WORK/home
mkdir -p "$FAKE/work"
printf "PROMPT='%%~ %%# '\nunsetopt BEEP PROMPT_SP\n" > "$FAKE/.zshrc"
PREFS="$FAKE/Library/Application Support/com.staunch.muya/native/ui-prefs.json"
PTYD= MUYAD= APP=
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }

kill_wait() { # pid
  [ -n "${1:-}" ] || return 0
  kill "$1" 2>/dev/null || true
  for _ in $(seq 25); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done
  kill -9 "$1" 2>/dev/null || true
}
cleanup() { kill_wait "$APP"; kill_wait "$MUYAD"; kill_wait "$PTYD"; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

dbg() { printf '%s\n' "$1" | nc -U -w 6 "$WORK/app-debug.sock"; }
st() { dbg split-state | tr ' ' '\n' | sed -n "s/^$1=//p"; }
npanes() { dbg split-state | sed -n 's/.*panes=\[\([^]]*\)\].*/\1/p' | tr ';' '\n' | grep -c .; }
nsess() { dbg sessions | grep -c .; }

start_stack() {
  rm -f "$WORK/ptyd.sock" "$WORK/muyad.sock" "$WORK/app-debug.sock" "$WORK/app.pid"
  env HOME="$FAKE" "$BIN/muya-ptyd" --socket "$WORK/ptyd.sock" >>"$WORK/ptyd.log" 2>&1 &
  PTYD=$!
  for _ in $(seq 60); do [ -S "$WORK/ptyd.sock" ] && break; sleep 0.1; done
  env HOME="$FAKE" "$BIN/muyad" --socket "$WORK/muyad.sock" --ptyd "$WORK/ptyd.sock" --broker >>"$WORK/muyad.log" 2>&1 &
  MUYAD=$!
  for _ in $(seq 60); do [ -S "$WORK/muyad.sock" ] && break; sleep 0.1; done
  [ -S "$WORK/muyad.sock" ] || { bad "muyad did not come up"; tail -5 "$WORK/muyad.log"; exit 1; }
  # muyad refuses a peer with no living parent, so a subshell stays alive as the app's parent (as run-dev.sh does).
  HOME=$FAKE MUYA_SOCKET=$WORK/muyad.sock MUYA_DEBUG_SOCKET=$WORK/app-debug.sock APP_BIN=$APP_BIN D=$WORK \
    nohup bash -c '"$APP_BIN" >>"$D/app.log" 2>&1 & echo $! > "$D/app.pid"; wait' >/dev/null 2>&1 &
  for _ in $(seq 60); do [ -s "$WORK/app.pid" ] && break; sleep 0.1; done
  APP=$(cat "$WORK/app.pid" 2>/dev/null || true)
  for _ in $(seq 100); do [ -S "$WORK/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
  [ -n "$(dbg windowid 2>/dev/null)" ] || { bad "the app never answered on its debug socket"; tail -5 "$WORK/app.log"; exit 1; }
}

stop_stack() { kill_wait "$APP"; APP=; kill_wait "$MUYAD"; MUYAD=; kill_wait "$PTYD"; PTYD=; }

echo "== phase 1: a split made in this run"
start_stack
for _ in $(seq 40); do case "$(dbg "new $FAKE/work")" in ok*) break ;; esac; sleep 0.25; done
sleep 1.2
A=$(dbg sessions | head -1 | awk '{print $1}')
dbg "select $A" >/dev/null; sleep 0.4
dbg split-add >/dev/null; sleep 2
check "Split put the two terminals in one group" "$(st groups | tr ',' '\n' | grep -c .)" "2"
check "two panes side by side" "$(npanes)" "2"
sleep 2   # the prefs file is written with a 1 s debounce
GROUPS_SAVED=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1])).get("muya.splitGroups",""))' "$PREFS" 2>/dev/null)
[ -n "$GROUPS_SAVED" ] && ok "the group is in the prefs file: $GROUPS_SAVED" || bad "nothing was persisted under muya.splitGroups"
case "$GROUPS_SAVED" in
  *'"1:'*|*'"2:'*) ok "its keys name the session AND its process (id:pid), so they cannot match another run's terminals" ;;
  *) bad "its keys are not id:pid — a later run's terminals can match them: $GROUPS_SAVED" ;;
esac
stop_stack

echo "== phase 2: fresh daemons on the same HOME (session ids start at 1 again), then ⌘T"
start_stack
BEFORE=$(nsess)
check "the new daemons start with no sessions" "$BEFORE" "0"
dbg "p3-key cmd+t" >/dev/null; sleep 2.5
IDS=$(dbg sessions | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
check "⌘T opened exactly one terminal (id $IDS)" "$(nsess)" "1"
check "it is NOT in a split group" "$(st groups)" "[]"
# `panes` lists the SPLIT panes: none means the terminal fills the Control area on its own (the buggy build had 2).
check "the Control area holds one whole terminal, no split panes" "$(npanes)" "0"
SEL=$(st selected)
check "the new terminal is the selected one" "$SEL" "$IDS"
# A second ⌘T must not pair the two either (the stale group named ids 1 and 2).
dbg "p3-key cmd+t" >/dev/null; sleep 2.5
check "a second ⌘T opens a second plain terminal, still no split" "$(st groups)" "[]"
check "still no split panes in view" "$(npanes)" "0"
check "two sessions now" "$(nsess)" "2"
# And splitting by hand still works in this run.
dbg split-add >/dev/null; sleep 2
check "Split still groups two terminals on purpose" "$(st groups | tr ',' '\n' | grep -c .)" "2"
check "two panes after a deliberate split" "$(npanes)" "2"

echo "RESULT: $([ $fails = 0 ] && echo PASS || echo "FAIL ($fails)")"
exit $fails
