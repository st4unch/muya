#!/usr/bin/env bash
# Scrollback while the program keeps writing: the view must stay where the operator left it.
#
# The operator's complaint (2026-11-26): "session çalışırken yukarıya kaydırdığımda ekran aşağıya force ediyor" —
# every byte of output snapped the viewport to the bottom, so the past of a running session could not be read.
# This drives the REAL app: a live shell writing a line every 50 ms, a real trackpad wheel event through
# TerminalView.scrollWheel, and the viewport read back from libghostty. Nothing is mocked.
#
# Safety: run-dev.sh's throwaway stack (own HOME, own sockets, own ptyd + muyad from native/target/debug).
# The installed Muya, its daemons and its launchd jobs are never touched; `stop` kills only what this started.
#   verify-scrollback.sh     exit 1 on any FAIL; screenshots in screenshots/scrollback-*.png
set -uo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d /tmp/muya-scrollv.XXXXXX)
export TMPDIR=$WORK
STATE=$WORK/muya-native-dev.state
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p screenshots
./run-dev.sh start >/dev/null || exit 1
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
for _ in $(seq 100); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
[ -n "$(dbg windowid 2>/dev/null)" ] || { echo "FAIL the dev app never answered on its debug socket"; exit 1; }
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
offset() { dbg scrollstate | tr ' ' '\n' | sed -n 's/^offset_from_bottom=//p'; }
history() { dbg scrollstate | tr ' ' '\n' | sed -n 's/^history=//p'; }
shot() { id=$(dbg windowid); screencapture -x -o -l "$id" "screenshots/scrollback-$1.png" 2>/dev/null; }

# A session that writes forever, like an agent working.
case "$(dbg new)" in ok*) ;; *) echo "FAIL could not spawn a session"; exit 1 ;; esac
dbg 'type "i=0; while :; do echo line $i; i=$((i+1)); sleep 0.05; done\n"' >/dev/null
sleep 2.5
[ "$(offset)" = "0" ] && ok "a session at the bottom follows its output" || bad "fresh session is not at the bottom (offset $(offset))"
h0=$(history)

# Scroll back with a real wheel event while the output keeps coming.
dbg "wheel 10" >/dev/null
a=$(offset); textA=$(dbg text)
[ "${a:-0}" -ge 10 ] && ok "the wheel scrolled the view back ($a rows)" || bad "the wheel did not scroll back (offset ${a:-none})"
sleep 2.5
b=$(offset); textB=$(dbg text); h1=$(history)
shot scrolled-back-while-output

[ "${h1:-0}" -gt "${h0:-0}" ] && ok "output really kept coming (history $h0 -> $h1)" || bad "no new output arrived, so nothing was proved (history $h0 -> $h1)"
[ "${b:-0}" -ge "${a:-0}" ] && ok "the view stayed scrolled back under output (offset $a -> $b)" || bad "output pulled the view back down (offset $a -> $b)"
[ "$textA" = "$textB" ] && ok "the same text is still on screen (the view is pinned to it)" || bad "the visible text changed under the operator"

# Back to the last row: following resumes.
dbg "wheel -$((b + 2))" >/dev/null
sleep 1.5
c=$(offset); textC=$(dbg text)
[ "${c:-1}" = "0" ] && ok "scrolling back down returns to the bottom" || bad "could not get back to the bottom (offset $c)"
sleep 0.8
[ "$(dbg text)" != "$textC" ] && ok "at the bottom the view follows the new output again" || bad "the view is at the bottom but no longer follows the output"

# A keystroke returns to the bottom too (sendKey -> scrollToBottom), as in Ghostty.
dbg "wheel 12" >/dev/null
[ "$(offset)" -ge 10 ] || bad "could not scroll back for the keystroke check (offset $(offset))"
dbg "key enter" >/dev/null
sleep 0.5
[ "$(offset)" = "0" ] && ok "a keystroke returns to the bottom and resumes following" || bad "a keystroke left the view scrolled back (offset $(offset))"
shot followed-again

echo "RESULT: $([ $fails = 0 ] && echo PASS || echo "FAIL ($fails)")"
exit $fails
