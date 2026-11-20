#!/usr/bin/env bash
# P12 end-to-end: the Vault Source panel and the auto-allow toast in the real app, dev stack in a throwaway HOME,
# SYNTHETIC data, fake `claude`. Always stops the stack it started. Needs a logged-in GUI session.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-p12.XXXXXX)  # its own dir per run: a fixed one collides with another dev stack / a leftover
mkdir -p "$TMPDIR"
SHOTS=$PWD/screenshots; mkdir -p "$SHOTS"
STATE=$TMPDIR/muya-native-dev.state
if [ -f "$STATE" ]; then ./run-dev.sh stop >/dev/null 2>&1 || true; fi
MINPATH=/usr/bin:/bin:/usr/sbin:/sbin
PATH=$MINPATH MUYAD_ARGS=--scheduler MUYA_DEV_NO_APP=1 ./run-dev.sh start >/dev/null || exit 1
. "$STATE"
cleanup() { ./run-dev.sh stop >/dev/null 2>&1; }
trap cleanup EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
HOMEDIR=$DEV/home
python3 -I make-pages-fixtures.py "$HOMEDIR" 14 >/dev/null
python3 -I make-4e-fixtures.py "$HOMEDIR" >/dev/null
mkdir -p "$HOMEDIR/Notes/NotesVault/.obsidian" "$HOMEDIR/Elsewhere/Picked/.obsidian"
echo "# hello" > "$HOMEDIR/Notes/NotesVault/hello.md"
PATH=$MINPATH ./run-dev.sh app >/dev/null; . "$STATE"
sleep 2.5
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock"; }
FAILS=0
expect() { if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi; }
wait_for() { local out="" end=$((SECONDS + ${4:-10})); while [ $SECONDS -lt $end ]; do out=$(eval "$2"); [[ "$out" == *"$3"* ]] && { echo "PASS $1"; return; }; sleep 0.25; done; echo "FAIL $1: got '$out', wanted '$3'"; FAILS=$((FAILS + 1)); }
shot() { screencapture -x -o -l "$1" "$SHOTS/$2.png"; echo "shot $2"; }
both() { dbg "appearance dark" >/dev/null; sleep 1; shot "$($1)" "$2-dark"; dbg "appearance light" >/dev/null; sleep 1; shot "$($1)" "$2-light"; }
mainwin() { dbg windowid; }
setwin() { dbg "settings-open"; }
dbg "sessions" | while IFS=$'\t' read -r id _; do [ -n "$id" ] && dbg "close $id" >/dev/null; done

echo "=== Vault Source panel"
dbg "appearance dark" >/dev/null
dbg "vault-open" >/dev/null
wait_for "panel shows a state" "dbg vault-state" "current="
sleep 1
echo "$(dbg vault-state)"
expect "auto-detected vault listed (ordinary folder scan)" "$(dbg vault-state)" "NotesVault"
both setwin p12-vault-panel
dbg "vault-type $HOMEDIR/Elsewhere/Picked" >/dev/null
dbg "vault-set" >/dev/null
wait_for "chosen path is applied" "dbg vault-state" "configured=$HOMEDIR/Elsewhere/Picked" 15
echo "$(dbg vault-state)"
dbg "vault-close" >/dev/null
expect "panel closed" "$(dbg vault-state)" "none"

echo "=== Auto-allow suggestion toast"
dbg "new $HOMEDIR" >/dev/null; sleep 1.5
dbg "settings-open" >/dev/null; dbg "settings-set autoApprove off" >/dev/null; dbg "settings-close" >/dev/null
dbg "type \"python3 -I $HOMEDIR/permission.py\\n\"" >/dev/null
wait_for "toast offered for a new prompt" "dbg suggest-state" "shown=true" 15
echo "$(dbg suggest-state)"
both mainwin p12-autoallow-toast
dbg "suggest-esc" >/dev/null
wait_for "Esc closes the toast" "dbg suggest-state" "shown=false" 5
echo "=== done: $FAILS failure(s)"
exit $FAILS
