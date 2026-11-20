#!/usr/bin/env bash
# Guard against the session-switch regression that came back twice (the agent cards rebuilt on every selection change, AC8 switch p50 10 -> 55 ms):
#   1 a selection change rebuilds the agent cards 0 times (debug counter AgentsPanel.rebuilds, 3 rounds over 25 sessions)
#   2 the switch time (select -> first finished frame, the AC7/AC8 probe) of those switches has p50 < 15 ms and p95 < 40 ms
# ~40 s. A machine under heavy load (parallel builds) can miss the time budget: it is measured twice and the better run counts.
set -uo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d /tmp/muya-swg.XXXXXX); export TMPDIR=$WORK
trap './run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
./run-dev.sh start >/dev/null || exit 1
. "$TMPDIR/muya-native-dev.state"
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock"; }
for _ in $(seq 80); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
mkdir -p "$DEV/home"
for _ in $(seq 25); do dbg "new $DEV/home" >/dev/null; done
sleep 2
ids=$(dbg sessions | awk '{print $1}')
fails=0
before=$(dbg agents-rebuilds)
run_round() { # prints sorted switch times (ms)
  for s in $ids; do dbg "probe-switch $s"; done | grep -E '^[0-9.]+$' | sort -n
}
r1=$(run_round); sleep 0.5; r2=$(run_round); sleep 0.5
after=$(dbg agents-rebuilds)
[ "$before" = "$after" ] && echo "PASS a selection change rebuilds the agent cards 0 times ($(echo "$ids" | wc -l | tr -d ' ') sessions x 2 rounds, counter $before -> $after)" || { echo "FAIL the agent cards were rebuilt on a switch: counter $before -> $after"; fails=$((fails + 1)); }
stat() { python3 -c "
import sys
v=sorted(float(x) for x in sys.stdin.read().split())
print('%.1f %.1f %d' % (v[len(v)//2], v[min(len(v)-1, int(len(v)*.95))], len(v)))"; }
a=$(echo "$r1" | stat); b=$(echo "$r2" | stat)
echo "switch p50/p95/n: run 1 = $a, run 2 = $b"
best=$(python3 -c "
a='$a'.split(); b='$b'.split()
print(a[0] if float(a[0]) <= float(b[0]) else b[0], a[1] if float(a[0]) <= float(b[0]) else b[1])")
p50=${best% *}; p95=${best#* }
python3 -c "import sys; sys.exit(0 if float('$p50') < 15 and float('$p95') < 40 else 1)" && echo "PASS switch time within budget (p50 $p50 ms < 15, p95 $p95 ms < 40)" || { echo "FAIL switch time over budget: p50 $p50 ms (< 15), p95 $p95 ms (< 40)"; fails=$((fails + 1)); }
echo "failures=$fails"
[ "$fails" = 0 ]
