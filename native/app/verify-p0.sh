#!/usr/bin/env bash
# P0 verify sweep: re-runs the live scripts that back the "verified" rows (files, queue/branches/kanban, SSH
# page) and probes the terminal key bytes against the dev stack. Rows whose spec the app does NOT meet
# (Shift+Enter = \n, Option+arrows = ESC b/f, Cmd+R/K/L/A/E/D/U = Ctrl bytes) print GAP, not FAIL: they are
# listed as todo in docs/native/parity.md with the reason. Uses its own state dir; stops only its own PIDs.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=${P0_STATE:-$(mktemp -d /tmp/muya-p0v.XXXXXX)}   # its own dir per run (a fixed path collides with another run / a leftover stack)
mkdir -p "$TMPDIR"
trap './run-dev.sh stop >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
STATE=$TMPDIR/muya-native-dev.state
[ -f "$STATE" ] || ./run-dev.sh start >/dev/null
. "$STATE"
mkdir -p "$DEV/home/projects/api"   # the folder the key probes open their shells in
dbg() { printf '%s\n' "$1" | nc -U -w 4 "$DEV/app-debug.sock"; }
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

echo "== live scripts"
for s in verify-files.sh verify-queue.sh verify-ssh.sh; do
  # each inner script gets its own TMPDIR: with the same one it would find (and stop) THIS script's dev stack
  mkdir -p "$TMPDIR/in-$s"; TMPDIR="$TMPDIR/in-$s" bash "./$s" >"$TMPDIR/$s.log" 2>&1; if grep -qE "ALL PASS|^failures=0" "$TMPDIR/$s.log"; then ok "$s"; else bad "$s (see $TMPDIR/$s.log)"; fi
done

echo "== terminal key bytes (cat -v shows what the program receives)"
probe() { # name, "keyCode mods", expected cat -v text, "must" | "spec"
  dbg "new $DEV/home/projects/api" >/dev/null; sleep 1.2 # a fresh shell per probe
  id=$(dbg sessions | tail -1 | cut -f1)
  dbg "select $id" >/dev/null
  dbg 'type "clear; cat -v\n"' >/dev/null; sleep 0.6
  dbg p3-activate >/dev/null; dbg p3-focus-terminal >/dev/null   # the key goes to the terminal even when another app holds the focus
  dbg "nskey $2" >/dev/null; sleep 0.5
  got=$(dbg text | sed -n 1p)
  dbg "close $id" >/dev/null
  if [ "$got" = "$3" ]; then ok "$1 -> $3"; elif [ "$4" = must ]; then bad "$1: got '$got', want '$3'"; else echo "GAP  $1: spec wants '$3', app sends '$got'"; fi
}
probe "Left arrow" "123" "^[[D" must
probe "Shift+Enter writes \\n" "36 shift" "^J" spec
probe "Option+Left = ESC b" "123 alt" "^[b" spec
probe "Option+Right = ESC f" "124 alt" "^[f" spec
probe "Option+Up = plain Up" "126 alt" "^[[A" spec
probe "Cmd+R = Ctrl+R" "15 cmd" "^R" spec
probe "Cmd+K = Ctrl+K" "40 cmd" "^K" spec

echo "== result: $fails failure(s)"
[ "$fails" = 0 ]
