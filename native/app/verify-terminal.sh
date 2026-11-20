#!/usr/bin/env bash
# End-to-end check of the terminal essentials against the dev stack (run-dev.sh): selection and
# copy (drag, double, triple click), paste, mouse reporting vs Shift, scrollback, IME preedit with
# the candidate-window anchor, and the 6-tile grid. Asserts what it can, and screenshots dark and
# light under screenshots/. Needs a logged-in GUI session; leaves the stack running.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-term.XXXXXX)  # its own dir per run: the default /tmp state file collides with any other running dev stack
SHOTS=$PWD/screenshots
mkdir -p "$SHOTS"
STATE=${TMPDIR:-/tmp}/muya-native-dev.state
trap './run-dev.sh stop >/dev/null 2>&1 || true' EXIT   # stops its own stack however it ends
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
[ -f "$STATE" ] || ./run-dev.sh start >/dev/null
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 4 "$DEV/app-debug.sock"; }
shot() { screencapture -x -o -l "$(dbg windowid)" "$SHOTS/$1.png"; echo "shot $1"; }
both() { dbg "appearance dark" >/dev/null; sleep 1.2; shot "$1-dark"; dbg "appearance light" >/dev/null; sleep 1.2; shot "$1-light"; }
fails=0
expect() { # name, actual, expected
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $2, want $3"; fails=$((fails + 1)); fi
}
contains() { # name, haystack, needle
  case "$2" in *"$3"*) echo "PASS $1" ;; *) echo "FAIL $1: '$3' not in: $2"; fails=$((fails + 1)) ;; esac
}

dbg "grid off" >/dev/null
for id in $(dbg sessions | cut -f1); do dbg "close $id" >/dev/null; done # fresh sessions: no state left from earlier runs
sleep 0.5
while [ "$(dbg sessions | wc -l | tr -d ' ')" -lt 6 ]; do dbg "new $DEV/home/projects/api" >/dev/null; done
IDS=$(dbg sessions | cut -f1)
first=$(echo "$IDS" | head -1)
i=0
for id in $IDS; do
  i=$((i + 1))
  dbg "select $id" >/dev/null
  dbg 'type "clear; printf \"session '"$i"'\\n\"; ls | head -4; printf \"\\033[3'"$i"'mcolour %s\\033[0m  ş ğ ı İ 日本語\\n\" '"$i"'\n"' >/dev/null
done
sleep 1
dbg "select $first" >/dev/null
dbg 'type "clear; printf \"hello world foo-bar\\nsecond line ş ğ 日本語\\n\"\n"' >/dev/null
sleep 0.8

echo "== selection and copy"
dbg "mouse down 0 0" >/dev/null; dbg "mouse drag 4 0" >/dev/null; dbg "mouse up 4 0" >/dev/null
expect "drag selects 'hello'" "$(dbg selection)" '"hello"'
expect "Cmd+C puts it on the pasteboard" "$(dbg copy)" '"hello"'
expect "pbpaste agrees" "$(pbpaste)" "hello"
dbg "mouse down 6 0" >/dev/null; dbg "mouse up 6 0" >/dev/null; dbg "mouse down 6 0" >/dev/null; dbg "mouse up 6 0" >/dev/null
expect "double click selects the word" "$(dbg selection)" '"world"'
dbg "mouse down 6 0" >/dev/null; dbg "mouse up 6 0" >/dev/null
expect "triple click selects the line" "$(dbg selection)" '"hello world foo-bar"'
dbg "mouse down 0 0" >/dev/null; dbg "mouse drag 20 1" >/dev/null; dbg "mouse up 20 1" >/dev/null
contains "multi-row drag keeps the wide characters" "$(dbg selection)" "日本語"
dbg "mouse down 0 0" >/dev/null; dbg "mouse drag 18 0" >/dev/null; dbg "mouse up 18 0" >/dev/null
both selection

echo "== paste goes through the Paste message"
dbg 'clipboard "echo pasted-ok-ş"' >/dev/null
dbg paste >/dev/null; dbg 'key enter' >/dev/null; sleep 0.6
contains "pasted text reaches the shell" "$(dbg text)" "pasted-ok-ş"

echo "== mouse reporting (program tracks the mouse) vs selection (Shift)"
dbg 'type "clear; printf \"\\033[?1000h\\033[?1006h\"; echo tracking-on; sleep 5; printf \"\\033[?1000l\\033[?1006l\"\n"' >/dev/null; sleep 0.8
dbg "mouse down 3 5" >/dev/null; dbg "mouse up 3 5" >/dev/null; sleep 0.4
contains "press is reported to the program" "$(dbg text)" "^[[<0;4;6M"
expect "and nothing is selected locally" "$(dbg selection)" '""'
dbg "mouse down 0 0 shift" >/dev/null; dbg "mouse drag 7 0 shift" >/dev/null; dbg "mouse up 7 0 shift" >/dev/null
expect "Shift selects locally anyway" "$(dbg selection)" '"tracking"'
sleep 5.5

echo "== scrollback"
dbg 'type "clear; seq 1 300\n"' >/dev/null; sleep 1
expect "at the bottom after output" "$(dbg scrollstate | sed 's/history=[0-9]* //')" "offset_from_bottom=0"
dbg "wheel 20" >/dev/null
off=$(dbg scrollstate | sed 's/.*offset_from_bottom=//')
if [ "$off" -ge 15 ] && [ "$off" -le 25 ]; then echo "PASS wheel scrolled ~20 lines up ($off)"; else echo "FAIL wheel offset $off"; fails=$((fails + 1)); fi
dbg 'type "echo snapped\n"' >/dev/null; sleep 0.5
expect "typing / new output snaps back" "$(dbg scrollstate | sed 's/history=[0-9]* //')" "offset_from_bottom=0"

echo "== IME preedit (API calls; the real input source is not switched)"
dbg 'type "clear\n"' >/dev/null; sleep 0.4
dbg 'type "echo "' >/dev/null; sleep 0.3
dbg 'preedit "ğşçıöüİ"' >/dev/null; sleep 0.3
fr=$(dbg firstrect)
contains "preedit is held by the view" "$fr" 'preedit="ğşçıöüİ"'
want=$(( $(dbg text | head -1 | awk "{print length}") + 1 )) # prompt + "echo", plus the typed space
contains "candidate window anchors at the cursor cell" "$fr" "cursor=$want,0"
both preedit-turkish
dbg 'preedit "にほんご"' >/dev/null; sleep 0.3
both preedit-japanese
dbg 'commit "日本語"' >/dev/null; sleep 0.3
contains "commit sends the text and clears the preedit" "$(dbg firstrect)" 'preedit=""'
contains "committed text reached the shell" "$(dbg text)" "echo 日"
dbg 'key ctrl 0' >/dev/null

echo "== grid"
dbg "select $first" >/dev/null
dbg "grid on" >/dev/null; sleep 1.2
tiles=$(dbg tiles)
expect "today's default grid is 2x2: four tiles" "$(echo "$tiles" | wc -l | tr -d ' ')" "4"
dbg "grid-layout 3x2" >/dev/null; sleep 1.0
tiles=$(dbg tiles)
expect "the 3x2 layout shows six tiles" "$(echo "$tiles" | wc -l | tr -d ' ')" "6"
echo "$tiles"
both grid
dbg "mouse down 2 2 tile=3" >/dev/null; dbg "mouse up 2 2 tile=3" >/dev/null
contains "clicking a tile focuses its session" "$(dbg tiles | grep '\*')" "$(dbg sessions | sed -n 4p | cut -f1)"
dbg "grid off" >/dev/null; sleep 0.8
dbg "select $first" >/dev/null

echo "== result: $fails failure(s)"
exit $((fails > 0))
