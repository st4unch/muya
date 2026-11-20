#!/usr/bin/env bash
# The toast cards lifted above a dialog (ModalScrim) are panels of the Muya window: they show while the app is active and are
# hidden when another app comes forward (never floating over it), and the toast is back in the window after the dialog closes.
#   TMPDIR=<private dir> native/app/verify-toast-lift.sh [path/to/MuyaNative.app]
set -euo pipefail
cd "$(dirname "$0")"
STATE=${TMPDIR:-/tmp}/muya-native-dev.state
./run-mock.sh start "${1:-$PWD/build/MuyaNative.app}" >/dev/null
trap 'osascript -e "tell application \"Finder\" to close every window" >/dev/null 2>&1 || true; ./run-mock.sh stop >/dev/null' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock" || true; }
fail=0
expect() { if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: wanted '$3' in '$2'"; fail=$((fail + 1)); fi; }
sleep 2   # the mock toast ("Turn on Auto-allow?") appears a moment after launch
dbg "app-activate" >/dev/null; sleep 0.8
dbg "rail Sessions" >/dev/null; sleep 1; dbg "cleanup-open" >/dev/null; sleep 1.2
r=$(dbg toast-panels)   # a script-launched app cannot always be made active (locked screen): the panels must match whatever it is
if [[ "$r" == *"appActive=true"* ]]; then expect "a dialog is open and Muya is active: the toast is lifted and visible" "$r" "visible=1"; else expect "Muya is not active: no toast panel is on screen" "$r" "visible=0"; fi
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true; sleep 1.2
expect "another app in front: the toast panel is hidden" "$(dbg toast-panels)" "visible=0"
dbg "app-activate" >/dev/null; sleep 1.2
r=$(dbg toast-panels); if [[ "$r" == *"appActive=true"* ]]; then expect "Muya in front again: the toast is back" "$r" "visible=1"; else echo "ok   (Muya could not be re-activated in this session: $r)"; fi
dbg "cleanup-close" >/dev/null; sleep 0.8
expect "dialog closed: no lifted panel on screen" "$(dbg toast-panels)" "visible=0"
[ "$fail" = 0 ] && echo "verify-toast-lift: all passed" || { echo "verify-toast-lift: $fail failures"; exit 1; }
