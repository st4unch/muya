#!/usr/bin/env bash
# A permission prompt Claude could not draw in full ("↑ 8 more lines") must still be seen by Muya, and answering it
# must end with the prompt gone. Drives the REAL app and the REAL muyad on run-dev.sh's throwaway stack (own HOME,
# own sockets) with a scripted TUI standing in for Claude (fake-prompt.py draws the operator's exact screen).
#   a  accepts the digit                    -> Muya sees the prompt, the digit answers it, no fallback
#   b  ignores digits, only arrows + Enter  -> the fallback moves the marker from where it IS (row 3 and row 1)
#                                              and confirms the asked-for row; Deny likewise
#   c  answers nothing                      -> Muya gives up (stuck=1), does not loop, the prompt stays on screen
# Exit status = number of FAIL lines. Needs a logged-in GUI session, python3, and the build environment.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-pans.XXXXXX)
STATE=$TMPDIR/muya-native-dev.state
FAILS=0
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$TMPDIR"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
expect() { if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi; }
wait_for() { local out="" end=$((SECONDS + ${4:-12})); while [ $SECONDS -lt $end ]; do out=$(eval "$2"); [[ "$out" == *"$3"* ]] && { echo "PASS $1"; return; }; sleep 0.25; done; echo "FAIL $1: got '$out', wanted '$3'"; FAILS=$((FAILS + 1)); }

eval "$(bash ../scripts/ghostty-env.sh)" || { echo "FAIL build environment"; exit 1; }
(cd .. && cargo build -q -p muya-ptyd -p muyad) || { echo "FAIL could not build the daemons"; exit 1; }
./build.sh >/dev/null 2>&1 || { echo "FAIL could not build the app"; exit 1; }   # a stale app is the usual false result

./run-dev.sh start >/dev/null || { echo "FAIL dev stack did not start"; exit 1; }
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock"; }

cat > "$DEV/home/fake-prompt.py" <<'PYEOF'
import os, sys, termios, tty
mode, start = sys.argv[1], int(sys.argv[2])   # mode: digit | arrows | none ; start: row (0-based) the marker begins on
rows = ["Yes", "Yes, and don't ask again for murat-personal-access commands in /tmp/x", "No"]
sel = start
def draw():
    w = sys.stdout.write
    w("\x1b[2J\x1b[H")
    dash = "╌" * 60
    for l in ["    limit: 50", "  }", dash,
              " About the murat-personal-access Tool:",
              "  Dispatch to any tool available to this agent, including built-in platform tools…",
              " (ctrl+o to expand description)", "", " Do you want to proceed?"]:
        w(l + "\r\n")
    for i, r in enumerate(rows):
        w((" ❯ " if i == sel else "   ") + "%d. %s\r\n" % (i + 1, r))
    w(" ↑ 8 more lines\r\n")
    w(" Esc to cancel · Tab to amend · ctrl+x ctrl+k twice to stop background agents\r\n")
    sys.stdout.flush()
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    draw()
    while True:
        b = os.read(fd, 16)
        if mode == "none":
            continue
        if mode == "digit" and b in (b"1", b"2", b"3"):
            sys.stdout.write("\x1b[2J\x1b[H"); sys.stdout.write("ANSWERED %s\r\n" % b.decode()); sys.stdout.flush(); break
        if mode == "arrows":
            if b == b"\x1b[B": sel = min(2, sel + 1); draw()
            elif b == b"\x1b[A": sel = max(0, sel - 1); draw()
            elif b == b"\r":
                sys.stdout.write("\x1b[2J\x1b[H"); sys.stdout.write("CONFIRMED ROW %d\r\n" % (sel + 1)); sys.stdout.flush(); break
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
PYEOF

PATH=/usr/bin:/bin:/usr/sbin:/sbin ./run-dev.sh app >/dev/null; . "$STATE"
sleep 2.5

# run_case <label> <mode> <start-row>: opens a session, runs the fake TUI in it, leaves the id in $SID.
run_case() {
  dbg "new $DEV/home" >/dev/null; sleep 1
  SID=$(dbg sessions | awk -F'\t' 'END {print $1}')
  dbg "select $SID" >/dev/null
  dbg "type \"python3 -I $DEV/home/fake-prompt.py $2 $3\\n\"" >/dev/null
  wait_for "$1: the dialog is drawn" "dbg text" "8 more lines" 10
  wait_for "$1: Muya SEES the prompt (the operator's bug: it saw nothing)" "dbg 'prompt-screen $SID'" "permission=true truncated=true" 10
  expect "$1: three options, Allow is key 1" "$(dbg "prompt-screen $SID")" "approve=1"
}

echo "=== a: the TUI accepts the digit"
run_case a digit 0
expect "a: marker row reported" "$(dbg "prompt-screen $SID")" "selected=0"
dbg "answer-prompt $SID allow" >/dev/null
wait_for "a: prompt answered by the digit" "dbg text" "ANSWERED 1" 8
expect "a: no fallback needed" "$(dbg prompt-answer-state)" "fallbacks=0 stuck=0"

echo "=== b: the TUI ignores digits, arrows + Enter only (marker starts on row 3)"
run_case b arrows 2
expect "b: marker row 3 is read from the screen" "$(dbg "prompt-screen $SID")" "selected=2"
dbg "answer-prompt $SID allow" >/dev/null
wait_for "b: the fallback confirmed the ASKED row (1), moving up from row 3" "dbg text" "CONFIRMED ROW 1" 10
expect "b: exactly one fallback" "$(dbg prompt-answer-state)" "fallbacks=1 stuck=0"

echo "=== b2: same, marker on row 1, Deny (Esc ignored, fallback goes to the last row)"
run_case b2 arrows 0
dbg "answer-prompt $SID deny" >/dev/null
wait_for "b2: the fallback confirmed the Deny row (3)" "dbg text" "CONFIRMED ROW 3" 10
expect "b2: two fallbacks in total" "$(dbg prompt-answer-state)" "fallbacks=2 stuck=0"

echo "=== c: the TUI answers nothing"
run_case c none 0
dbg "answer-prompt $SID allow" >/dev/null
wait_for "c: Muya gave up" "dbg prompt-answer-state" "stuck=1" 10
sleep 3
expect "c: it did not loop" "$(dbg prompt-answer-state)" "fallbacks=3 stuck=1"
expect "c: the prompt is still on screen" "$(dbg text)" "8 more lines"
expect "c: and still seen by Muya" "$(dbg "prompt-screen $SID")" "permission=true"

echo "---"
echo "failures: $FAILS"
exit $FAILS
