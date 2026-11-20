#!/usr/bin/env bash
# Created by Claude — Classification: INTERNAL
# Measures how the native viewer opens big files: open time (incl. first draw), app CPU and RSS per file.
# usage: measure-largefile.sh "<kinds>" "<sizes MB>"   (dev stack, throwaway HOME; stops its own stack)
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-lf.XXXXXX)
STATE=$TMPDIR/muya-native-dev.state
trap './run-dev.sh stop >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM
[ -f "$STATE" ] || ./run-dev.sh start >/dev/null
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w "${2:-60}" "$DEV/app-debug.sock"; }
cpu_s() { ps -o time= -p "$APP_PID" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
rss_mb() { ps -o rss= -p "$APP_PID" | awk '{printf "%.0f", $1/1024}'; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
KINDS=${1:-"json log ts md minjs"}; SIZES=${2:-"1 3 5 10 20 50"}
FIX=$DEV/home/lf; mkdir -p "$FIX"
sleep 3; dbg "ac-click later" >/dev/null 2>&1 || true   # a dev stack from an older build asks to restart the service; dismiss it so shots are clean
SID=$(dbg "new $FIX" | awk '{print $2}'); sleep 1.5
FAIL=0
echo "kind mb | open_ms(viewer-open) draw_ms | cpu_s rss_mb | scroll | note"
for k in $KINDS; do for s in $SIZES; do
  f=$(python3 -I make-large-fixtures.py "$FIX" "$k" "$s")
  dbg "viewer-close" >/dev/null; sleep 0.4
  c0=$(cpu_s); t0=$(now_ms)
  note=$(dbg "viewer-open $f" 120); t1=$(now_ms)
  dbg "windowid" >/dev/null; screencapture -x -o -l "$(dbg windowid)" "$TMPDIR/lf.png"; t2=$(now_ms)
  sleep 1; c1=$(cpu_s)
  s50=$(dbg "viewer-scroll 0.5" 120); s100=$(dbg "viewer-scroll 1" 120); s0=$(dbg "viewer-scroll 0" 120)
  printf '%s %s | %s %s | %.2f %s | scroll_ms mid=%s end=%s top=%s | %s\n' "$k" "$s" "$((t1 - t0))" "$((t2 - t1))" "$(echo "$c1 - $c0" | bc)" "$(rss_mb)" "$s50" "$s100" "$s0" "$note"
  # BUDGET_MS=<ms>: fail when open + first draw takes longer (perf gate)
  if [ -n "${BUDGET_MS:-}" ] && [ "$((t2 - t0))" -gt "$BUDGET_MS" ]; then echo "FAIL $k $s MB: open+draw $((t2 - t0)) ms > budget $BUDGET_MS ms"; FAIL=1; fi
  [ -n "${SHOTS:-}" ] && cp "$TMPDIR/lf.png" "$SHOTS/native-$k-${s}mb.png"
  rm -f "$f"
done; done
exit $FAIL
