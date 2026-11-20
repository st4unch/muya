#!/usr/bin/env bash
# Faz 0 S4: kill -9 muyad with 25 live sessions; it must re-adopt every PTY (PIDs unchanged),
# rebuild the same screens as a never-killed reference muyad, and keep the input modes.
#   ./run.sh [sessions]
set -u
cd "$(dirname "$0")"
N=${1:-25}
W=$(mktemp -d /tmp/muya-s4.XXXXXX)
BIN=target/release
cleanup() {
  [ -n "${pids:-}" ] && for p in $pids; do kill -9 -"$p" 2>/dev/null; done
  kill -9 ${PTYD:-} ${A:-} ${B:-} 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
footprint() { vmmap --summary "$1" 2>/dev/null | awk '/Physical footprint:/{v=$3; u=substr(v,length(v)); n=v+0; if(u=="G") n*=1024; if(u=="K") n/=1024; printf "%.0f", n}'; }
ask() { python3 - "$1" "$2" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall((sys.argv[2] + "\n").encode())
data = b""
while not data.endswith(b"end\n"):
    chunk = s.recv(65536)
    if not chunk: break
    data += chunk
print(data.decode().removesuffix("end\n"), end="")
PY
}
$BIN/ptyd "$W/ptyd.sock" "$N" /usr/bin/python3 "$PWD/gen.py" "{i}" 2>"$W/ptyd.log" & PTYD=$!
sleep 1
pids=$(ask "$W/ptyd.sock" list | awk '{print $2}' | tr '\n' ' ')
$BIN/muyad "$W/ptyd.sock" "$W/a.sock" 2>"$W/a.log" & A=$!
$BIN/muyad "$W/ptyd.sock" "$W/b.sock" 2>"$W/b.log" & B=$!
WAIT=${WAIT:-15}
echo "waiting $WAIT s for streams (session 0 floods 12 MB after setting modes)"
sleep "$WAIT"
compare() {
  ask "$W/ptyd.sock" pause >/dev/null; sleep 0.5
  ask "$W/a.sock" hash > "$W/ha"; ask "$W/b.sock" hash > "$W/hb"
  ask "$W/ptyd.sock" resume >/dev/null
  same=$(paste -d' ' "$W/ha" "$W/hb" | awk '$2==$5 && $3==$6' | wc -l | tr -d ' ')
  echo "$1: $same/$N visible screens identical to the reference (cells: text + colors + style + cursor; and plain text)"
}
compare "before kill"
cpu_s() { ps -o time= -p "$1" | awk -F'[:.]' '{print $1*60 + $2 + $3/100}'; }
[ -n "${SAMPLE:-}" ] && sample $PTYD 5 -file "$SAMPLE" >/dev/null 2>&1
c0p=$(cpu_s $PTYD); c0a=$(cpu_s $A); sleep 10; c1p=$(cpu_s $PTYD); c1a=$(cpu_s $A)
echo "steady state over 10 s: ptyd CPU $(python3 -c "print(round(($c1p-$c0p)*10))")%, muyad CPU $(python3 -c "print(round(($c1a-$c0a)*10))")%; footprint ptyd $(footprint $PTYD) MB, muyad $(footprint $A) MB"
echo "ptyd rss $(ps -o rss= -p $PTYD | awk '{printf "%.0f", $1/1024}') MB, muyad rss $(ps -o rss= -p $A | awk '{printf "%.0f", $1/1024}') MB, cpu ptyd $(ps -o %cpu= -p $PTYD)% muyad $(ps -o %cpu= -p $A)%"
before=$(ask "$W/ptyd.sock" list | awk '{print $2}' | tr '\n' ' ')
t0=$(python3 -c 'import time; print(time.time())')
kill -9 $A
$BIN/muyad "$W/ptyd.sock" "$W/a.sock" 2>"$W/a2.log" & A=$!
until [ -S "$W/a.sock" ] && ask "$W/a.sock" hash >/dev/null 2>&1; do sleep 0.02; done
t1=$(python3 -c 'import time; print(time.time())')
echo "kill -9 muyad -> answering again after $(python3 -c "print(round(($t1-$t0)*1000))") ms; $(cat "$W/a2.log")"
after=$(ask "$W/ptyd.sock" list | awk '{print $2}' | tr '\n' ' ')
[ "$before" = "$after" ] && echo "PIDs: all $N unchanged" || echo "PIDs CHANGED"
compare "after re-adopt"
echo "session 0 modes after re-adopt (mode bytes 12 MB back, ring 1 MB): $(ask "$W/a.sock" 'modes 0')"
echo "session 0 Shift+Enter encodes as: $(ask "$W/a.sock" 'shift-enter 0') (Kitty CSI 13;2u = [27, 91, 49, 51, 59, 50, 117])"
echo "session 2 top rows  A: $(ask "$W/a.sock" "top 2")"; echo "session 2 top rows  B: $(ask "$W/b.sock" "top 2")"
grep '^2 ' "$W/ha" > "$W/a2h"; grep '^2 ' "$W/hb" > "$W/b2h"
cmp -s "$W/a2h" "$W/b2h" && echo "session 2 (header + scroll region): identical without resync" || {
  echo "session 2 (header + scroll region): DIFFERENT after replay (header bytes left the ring) -> sending SIGWINCH resync"
  ask "$W/ptyd.sock" "winch 2" >/dev/null; sleep 0.5
  ask "$W/ptyd.sock" pause >/dev/null; sleep 0.3
  a=$(ask "$W/a.sock" hash | grep '^2 '); b=$(ask "$W/b.sock" hash | grep '^2 ')
  ask "$W/ptyd.sock" resume >/dev/null
  [ "$a" = "$b" ] && echo "session 2 after SIGWINCH resync: identical" || echo "session 2 after SIGWINCH resync: STILL DIFFERENT"
}
