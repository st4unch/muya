#!/usr/bin/env bash
# AC21 end to end in the real app: muyad runs but its ptyd is not there (the state before the user approves the
# background service in Login Items). The app must show the onboarding screen, the daemon must answer a session start with
# the typed error, and starting ptyd (= approving) must continue the app by itself, same process, no relaunch.
# Everything lives in a throwaway HOME with its own sockets; the real login items are never touched (System Settings is
# not opened: the button click is counted by the debug hook). Stops exactly the PIDs it started. Needs a GUI session.
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
NATIVE=$(cd .. && pwd)
BIN=${MUYA_BIN_DIR:-$NATIVE/target/debug}
APP_BIN=$HERE/build/MuyaNative.app/Contents/MacOS/MuyaNative
export TMPDIR=/tmp/muya-ac1921; mkdir -p "$TMPDIR"
SHOTS=$HERE/screenshots; mkdir -p "$SHOTS"
[ -x "$BIN/muyad" ] && [ -x "$BIN/muya-ptyd" ] && [ -x "$APP_BIN" ] || { echo "build first: cargo build -p muya-ptyd -p muyad; native/app/build.sh"; exit 1; }
DEV=$(mktemp -d "$TMPDIR/ac21.XXXXXX"); DEV=$(cd "$DEV" && pwd -P)
HOMEDIR=$DEV/home; mkdir -p "$HOMEDIR/work"
printf "PROMPT='%%~ %%# '\nunsetopt BEEP PROMPT_SP\n" > "$HOMEDIR/.zshrc"
MUYAD_PID=; PTYD_PID=; APP_PID=
stop_pid() { local pid=$1 want=$2; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
  case "$(ps -o command= -p "$pid" 2>/dev/null)" in *"$want"*) kill "$pid" 2>/dev/null; sleep 0.5; kill -9 "$pid" 2>/dev/null || true ;; esac; }
cleanup() { stop_pid "$APP_PID" MuyaNative; stop_pid "$PTYD_PID" /muya-ptyd; stop_pid "$MUYAD_PID" /muyad; rm -rf "$DEV"; }
trap cleanup EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
FAILS=0
expect() { if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi; }
wait_for() { local out="" end=$((SECONDS + ${4:-15})); while [ $SECONDS -lt $end ]; do out=$(eval "$2"); [[ "$out" == *"$3"* ]] && { echo "PASS $1"; return; }; sleep 0.25; done; echo "FAIL $1: got '$out', wanted '$3'"; FAILS=$((FAILS + 1)); }
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock"; }
shot() { dbg "snap $SHOTS/$1.png" >/dev/null; echo "shot $1"; }
cpu_seconds() { ps -o time= -p "$1" | awk -F'[:.]' '{ n = NF; printf "%.2f", ($(n-2) * 60 + $(n-1)) + $n / 100 }'; }
# CPU of a process over N seconds, in percent of one core.
cpu_over() { local a b; a=$(cpu_seconds "$1"); sleep "$2"; b=$(cpu_seconds "$1"); awk -v a="$a" -v b="$b" -v n="$2" 'BEGIN { printf "%.3f", (b - a) / n * 100 }'; }

echo "=== muyad up, ptyd not running (not approved)"
HOME=$HOMEDIR PATH=/usr/bin:/bin:/usr/sbin:/sbin nohup "$BIN/muyad" --socket "$DEV/muyad.sock" --ptyd "$DEV/ptyd.sock" >"$DEV/muyad.log" 2>&1 &
MUYAD_PID=$!
for _ in $(seq 50); do [ -S "$DEV/muyad.sock" ] && break; sleep 0.1; done
[ -S "$DEV/muyad.sock" ] || { echo "FAIL muyad did not start"; cat "$DEV/muyad.log"; exit 1; }

echo "=== a session start is answered with the typed error"
TYPED=$(python3 -I - "$DEV/muyad.sock" <<'EOF'
import json, socket, struct, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
def send(o):
    b = b"\x01" + json.dumps(o).encode(); s.sendall(struct.pack(">I", len(b)) + b)
def recv():
    n = struct.unpack(">I", s.recv(4))[0]; b = b""
    while len(b) < n: b += s.recv(n - len(b))
    return json.loads(b[1:])
send({"type": "hello", "major": 1, "minor": 3, "role": "app", "build": "verify-ac21"})
print(recv()["type"])
send({"type": "spawn", "argv": [], "cwd": "/tmp", "env": [], "cols": 80, "rows": 24})
r = recv(); print(r["type"], r.get("code"))
EOF
)
expect "welcome, then spawn -> error not_approved" "$TYPED" "error not_approved"

echo "=== app starts: onboarding screen"
HOME=$HOMEDIR MUYA_SOCKET=$DEV/muyad.sock MUYA_DEBUG_SOCKET=$DEV/app-debug.sock PATH=/usr/bin:/bin:/usr/sbin:/sbin nohup "$APP_BIN" >"$DEV/app.log" 2>&1 &
APP_PID=$!
wait_for "app shows the onboarding screen" "dbg ac-state" "problem=approval onboarding=shown" 20
dbg "ac-settings stub" >/dev/null
dbg "appearance dark" >/dev/null; sleep 1; shot ac21-onboarding-dark
dbg "appearance light" >/dev/null; sleep 1; shot ac21-onboarding-light
dbg "appearance dark" >/dev/null
expect "no session can be started meanwhile" "$(dbg 'new /tmp')" "error"
dbg "ac-click open" >/dev/null
expect "Open Login Items button reaches the opener" "$(dbg ac-state)" "settingsCalls=1"
dbg "ac-key return" >/dev/null
expect "Return does the same" "$(dbg ac-state)" "settingsCalls=2"
expect "still waiting after the clicks (nothing was faked)" "$(dbg ac-state)" "onboarding=shown"

echo "=== idle CPU while onboarding polls (30 s)"
sleep 3
CPU_ONB=$(cpu_over "$APP_PID" 30)
echo "onboarding polling: app CPU ${CPU_ONB}% of one core"

echo "=== approval: ptyd comes up (what the user's switch in Login Items does)"
HOME=$HOMEDIR nohup "$BIN/muya-ptyd" --socket "$DEV/ptyd.sock" >"$DEV/ptyd.log" 2>&1 &
PTYD_PID=$!
wait_for "onboarding goes away by itself" "dbg ac-state" "connected=true problem=none onboarding=hidden" 20
expect "same app process, no relaunch" "$(ps -o pid= -p "$APP_PID" | tr -d ' ')" "$APP_PID"
dbg "new $HOMEDIR/work" >/dev/null
wait_for "a session can be started now" "dbg sessions" "work" 10
dbg 'type "echo AC21-OK\n"' >/dev/null
wait_for "the session works" "dbg text" "AC21-OK" 10
shot ac21-after-approval-dark
sleep 3
CPU_IDLE=$(cpu_over "$APP_PID" 30)
echo "connected, one idle session: app CPU ${CPU_IDLE}% of one core"
awk -v a="$CPU_ONB" -v b="$CPU_IDLE" 'BEGIN { exit !(a <= b + 0.5) }' && echo "PASS onboarding polling costs no more than idle (+0.5% allowance): $CPU_ONB vs $CPU_IDLE" || { echo "FAIL onboarding polling CPU $CPU_ONB vs idle $CPU_IDLE"; FAILS=$((FAILS + 1)); }
echo "=== done: $FAILS failure(s)"
exit $FAILS
