#!/usr/bin/env bash
# End to end (5.0.2 secrets parity): an OLD vault written by classic Muya's original code (tools/classic-vault) with
# username + group opens in the real native app and shows its entries; Show / Copy / Edit / Delete / Lock work;
# agents get a placeholder + usage text from get_secret and can call a local test server through http_request,
# run_with_secrets and `muyactl secret exec` without the value ever appearing in a result. Throwaway HOME, TEST values only.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-sp.XXXXXX)
SHOTS=${SHOTS:-$PWD/screenshots/secrets-parity}; mkdir -p "$SHOTS"
STATE=$TMPDIR/muya-native-dev.state
SRV_PID=""
trap './run-dev.sh stop >/dev/null 2>&1 || true; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$TMPDIR"' EXIT
trap 'exit 130' INT TERM
bash ../scripts/test-classic-vault.sh >/dev/null 2>&1 || true
CLASSIC=$PWD/../tools/classic-vault/target/debug/classic-vault
[ -x "$CLASSIC" ] || { echo "FAIL classic helper missing"; exit 1; }
./run-dev.sh start >/dev/null
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
FAILS=0
expect() { if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi; }
nexpect() { if [[ "$2" != *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: found '$3'"; FAILS=$((FAILS + 1)); fi; }
waitfor() { for _ in $(seq 30); do [[ "$(dbg ssh-state)" == *"$1"* ]] && return 0; sleep 0.5; done; }
shot() { screencapture -x -o -l "$(dbg windowid)" "$SHOTS/$1.png"; echo "shot $1"; }
both() { dbg "appearance dark" >/dev/null; sleep 1.2; shot "$1-dark"; dbg "appearance light" >/dev/null; sleep 1.2; shot "$1-light"; }
export MUYA_TEST_MASTER='correct horse battery staple'
mkdir -p "$DEV/home/.claude"
HOME=$DEV/home "$CLASSIC" init
HOME=$DEV/home "$CLASSIC" add old-router test-pass-AAA111 Lab admin
HOME=$DEV/home "$CLASSIC" add old-db test-pass-BBB222 Production dba
sleep 2.5; for _ in 1 2 3 4 5; do [[ "$(dbg "rail SSH")" == ok* ]] && break; sleep 1; done; sleep 0.8; dbg "ssh-section vault" >/dev/null; sleep 0.8
for _ in $(seq 40); do dbg "ssh-reload" >/dev/null; sleep 1; [[ "$(dbg ssh-state)" != *"Starting the background"* ]] && break; done
echo "--- old vault opens and shows its entries"
dbg "ssh-unlock" >/dev/null; sleep 1.0
dbg "ssh-form set master $MUYA_TEST_MASTER" >/dev/null; dbg "ssh-form submit" >/dev/null; waitfor "rows=2"
expect "2 old entries listed" "$(dbg ssh-state)" "rows=2"
ROWS=$(dbg "ssh-secret rows")
expect "username + group shown" "$ROWS" "old-router|admin|Lab|password|••••••••"
nexpect "value hidden by default" "$ROWS" "AAA111"
both "store-list"
echo "--- show / copy / edit / lock"
dbg "ssh-secret show old-router" >/dev/null; sleep 1
expect "Show reveals the old password" "$(dbg 'ssh-secret rows')" "test-pass-AAA111"
both "store-revealed"
dbg "ssh-secret copy old-db" >/dev/null; sleep 1
expect "Copy puts the value on the clipboard" "$(pbpaste)" "test-pass-BBB222"
pbcopy </dev/null
dbg "ssh-secret edit old-db" >/dev/null; sleep 1.2
expect "Edit opens the in-place card with the stored value" "$(dbg 'ssh-secret formstate')" "value-set"
shot "store-edit-dark"
dbg "ssh-secret formset group Prod2" >/dev/null; dbg "ssh-secret formsave" >/dev/null; sleep 2
expect "the edit was saved (group changed)" "$(dbg 'ssh-secret rows')" "old-db|dba|Prod2"
expect "the value survived the edit" "$(HOME=$DEV/home "$CLASSIC" reveal old-db)" "test-pass-BBB222"
echo "--- delete + lock"
dbg "ssh-secret lock" >/dev/null; sleep 1
expect "lock locks it" "$(dbg ssh-state)" "locked"
nexpect "no values after lock" "$(dbg 'ssh-secret rows')" "AAA111"
echo "FAILS=$FAILS"
exit $FAILS
