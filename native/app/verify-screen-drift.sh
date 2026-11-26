#!/usr/bin/env bash
# Screen drift: the app's passive replica must show exactly the rows muyad's authoritative terminal has.
#
# The operator's complaint (2026-11-26, "yazi ve ekran kaymalari devam ediyor"): a TUI's drawn screen is SHIFTED
# from what the program drew (a rule row with two titles, a box border in fragments, typed text in the wrong row).
# Cause found here: after a detach + re-attach the snapshot muyad sends dropped the blank rows under the cursor, so
# the replica's content sat one or more rows lower than muyad's while the cursor row (absolute) stayed put.
#
# This drives the REAL app and the REAL muyad: after each step it reads muyad's screen (the `sessions.tail` RPC,
# built on the same visible_lines the daemon parses) and the replica's (`text` on the app debug socket) and compares
# them row by row. Steps: pending wrap, cols+1, box rules + CUP overwrites, Turkish / arrows / ZWJ / combining,
# resizes, and the failing one: scrollback + blank rows under the cursor, detach, re-attach, type more.
#
# Safety: run-dev.sh's throwaway stack (own HOME, own sockets, own ptyd + muyad from native/target/debug, built here).
# The installed Muya, its daemons and its launchd jobs are never touched; `stop` kills only what this started.
# Needs the build environment (zig on PATH, `eval "$(native/scripts/ghostty-env.sh)"`) and python3.
#   verify-screen-drift.sh     exit 1 on any FAIL
set -uo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d /tmp/muya-driftv.XXXXXX)
export TMPDIR=$WORK
STATE=$WORK/muya-native-dev.state
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# The pinned zig + libghostty-vt the daemons link against (it puts zig@0.15 on PATH itself);
# without it a plain PATH picks a newer zig and the build dies.
eval "$(bash ../scripts/ghostty-env.sh)" || { echo "FAIL build environment (see native/scripts/ghostty-env.sh)"; exit 1; }
(cd .. && cargo build -q -p muya-ptyd -p muyad) || { echo "FAIL could not build the daemons"; exit 1; }
[ -x build/MuyaNative.app/Contents/MacOS/MuyaNative ] || ./build.sh >/dev/null || { echo "FAIL could not build the app"; exit 1; }
./run-dev.sh start >/dev/null || exit 1
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
for _ in $(seq 100); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
[ -n "$(dbg windowid 2>/dev/null)" ] || { echo "FAIL the dev app never answered on its debug socket"; exit 1; }
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# muyad's own rows for session $1 (the same RPC the exit panel uses), printed one per line.
cat > "$WORK/muyad_rows.py" <<'PY'
import json, socket, struct, sys
sock, sid = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(5)
def frame(body): return struct.pack(">I", len(body) + 1) + bytes([1]) + body
s.sendall(frame(json.dumps({"type": "hello", "major": 1, "minor": 3, "role": "app", "build": "verify-screen-drift"}).encode()))
s.sendall(frame(json.dumps({"type": "rpc", "req": 1, "method": "sessions.tail", "params": json.dumps({"id": sid, "lines": 200})}).encode()))
buf = b""
while True:
    d = s.recv(65536)
    if not d: sys.exit(2)
    buf += d
    while len(buf) >= 4:
        n = struct.unpack(">I", buf[:4])[0]
        if len(buf) < 4 + n: break
        f, buf = buf[4:4 + n], buf[4 + n:]
        if f[0] != 1: continue
        c = json.loads(f[1:])
        if c.get("type") == "rpc_reply":
            r = c["result"]
            print("\n".join((json.loads(r) if isinstance(r, str) else r)["lines"]))
            sys.exit(0)
        if c.get("type") == "error": print(c, file=sys.stderr); sys.exit(1)
PY
# Row-by-row comparison. muyad's text extraction pads the second cell of a wide character with a space, the replica's
# does not (that is a text-reading difference, not a grid one), so one space after a wide character is dropped.
cat > "$WORK/compare.py" <<'PY'
import sys, unicodedata
m = open(sys.argv[1]).read().split("\n"); a = open(sys.argv[2]).read().split("\n")
def norm(l):
    o, skip = [], False
    for ch in l:
        if skip and ch == " ": skip = False; continue
        skip = False; o.append(ch)
        if unicodedata.east_asian_width(ch) in "WF": skip = True
    return "".join(o).rstrip()
m = [norm(x) for x in m]; a = [x.rstrip() for x in a]
while m and m[-1] == "": m.pop()
while a and a[-1] == "": a.pop()
if m == a: sys.exit(0)
for i in range(max(len(m), len(a))):
    x = m[i] if i < len(m) else "<none>"; y = a[i] if i < len(a) else "<none>"
    if x != y: print(f"  row {i}\n    muyad   |{x[:100]}|\n    replica |{y[:100]}|")
sys.exit(1)
PY
SID=1
same() { # label: wait for output to settle, then compare muyad's rows with the replica's
  sleep "${WAIT:-1.5}"
  python3 "$WORK/muyad_rows.py" "$DEV/muyad.sock" "$SID" > "$WORK/m.txt" 2>"$WORK/m.err" || { bad "$1 (could not read muyad's screen: $(cat "$WORK/m.err"))"; return; }
  dbg text > "$WORK/a.txt"
  if diff_out=$(python3 "$WORK/compare.py" "$WORK/m.txt" "$WORK/a.txt"); then ok "$1"; else bad "$1"; echo "$diff_out" | head -12; fi
}
type_() { dbg "type $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" >/dev/null; }

case "$(dbg new)" in ok*) ;; *) echo "FAIL could not spawn a session"; exit 1 ;; esac
dbg "grid-layout 1" >/dev/null; sleep 1
cols=$(dbg tiles | cut -f3 | sed 's/x.*//')
[ -n "$cols" ] && [ "$cols" -gt 20 ] || { echo "FAIL no terminal grid ($(dbg tiles))"; exit 1; }

type_ "clear; printf '%${cols}s' '' | tr ' ' A; printf 'next\nline2\n'
"; same "1 a line exactly $cols wide (pending wrap), then more output"
type_ "clear; printf '%$((cols + 1))s' '' | tr ' ' B; printf '\nline2\n'
"; same "2 a line of cols+1 characters"
type_ "clear; python3 -c \"
w=__import__('sys').stdout.write
w('\x1b[2J\x1b[H')
for r in range(1,15): w('\x1b[%d;1H'%r+('─' if r in (1,14) else '│'+' '*($cols-2)+'│'))
w('\x1b[1;20H TITLE A \x1b[1;60H TITLE B \x1b[14;30H\x1b[2K\x1b[14;1H└'+'─'*40)
w('\x1b[8;1H/rc\x1b[8;100H\x1b[K\x1b[16;1H')
\"
"; same "3 box-drawing rows overwritten by absolute cursor moves"
type_ "clear; python3 -c \"
print('hâlâ İ ı ş ğ ← ✱ ▸▸ ❯ 👨‍👩‍👧 é 日本語 x')
print('│ ✱ Welcome ❯ ▸▸ ← 👩‍💻 ñ̃ ĞÜŞ │')
\"
"; same "4 Turkish letters, arrows, ZWJ emoji, combining marks"
type_ "clear; python3 -c \"
for i in range(3): print(('wrapped line %d '%i)*14)
print('─'*$cols); print('hâlâ '*40)
\"; sleep 3000
"; sleep 1
for sz in "800 600" "480 700" "1300 800" "560 560" "1120 700"; do
  dbg "window $sz" >/dev/null; sleep 0.5; same "5 resize to $sz with wrapped lines on screen ($(dbg tiles | cut -f3))"
done
type_ $'\x03'; sleep 0.8

# 6: the failing step. Scrollback, then blank rows under the cursor (a TUI that drew in the upper part of the screen).
type_ "clear; seq 1 60; printf '\033[2;1H\033[Jprompt> '
"; same "6.0 scrollback and blank rows under the cursor (before the detach)"
for _ in 1 2 3 4 5; do dbg new >/dev/null; sleep 0.3; done
for id in 2 3 4 5 6; do dbg "select $id" >/dev/null; sleep 0.5; done # session 1 falls out of the 3-session cache: detached
sleep 1
dbg "select 1" >/dev/null; sleep 2
same "6.1 the same screen after detach + re-attach (the snapshot)"
type_ "typed after the re-attach"; same "6.2 text typed after the re-attach lands on the right row"
type_ $'\x03'; sleep 0.8; type_ "clear; seq 1 40; (sleep 5; seq 100 150; printf '\033[3;5Hwrote-while-detached\033[10;1H') &
"; sleep 1
for id in 2 3 4 5 6; do dbg "select $id" >/dev/null; sleep 0.5; done
sleep 6
dbg "select 1" >/dev/null; sleep 2
same "6.3 output that arrived while detached, then re-attach"

[ "$fails" = 0 ] && { echo "verify-screen-drift: all checks passed"; exit 0; }
echo "verify-screen-drift: $fails check(s) FAILED"; exit 1
