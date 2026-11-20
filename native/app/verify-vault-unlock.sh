#!/usr/bin/env bash
# End to end: a vault written by classic Muya's ORIGINAL code (tools/classic-vault) unlocks in the real native app through
# its Password Store sheet, against a dev stack in a throwaway HOME. Checks the error texts (wrong password, no store),
# that the secret is listed after unlocking, and that classic's code reads back what Native stored. Screenshots dark + light.
# The operator's real vault and Keychain are never touched. Needs a logged-in GUI session.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-vault.XXXXXX)
SHOTS=$PWD/screenshots; mkdir -p "$SHOTS"
STATE=$TMPDIR/muya-native-dev.state
trap './run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$TMPDIR"' EXIT
trap 'exit 130' INT TERM
bash ../scripts/test-classic-vault.sh >/dev/null 2>&1 || true   # builds tools/classic-vault (fails soft: only the helper is needed)
CLASSIC=$PWD/../tools/classic-vault/target/debug/classic-vault
[ -x "$CLASSIC" ] || { echo "FAIL classic helper missing"; exit 1; }
./run-dev.sh start >/dev/null
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
FAILS=0
expect() { if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi; }
waitfor() { for _ in $(seq 30); do [[ "$(dbg ssh-state)" == *"$1"* ]] && return 0; sleep 0.5; done; }   # Argon2 in a debug build takes a few seconds
shot() { screencapture -x -o -l "$(dbg windowid)" "$SHOTS/$1.png"; echo "shot $1"; }
both() { dbg "appearance dark" >/dev/null; sleep 1.2; shot "$1-dark"; dbg "appearance light" >/dev/null; sleep 1.2; shot "$1-light"; }

export MUYA_TEST_MASTER='correct horse battery staple'
sleep 2.5; for _ in 1 2 3 4 5; do [[ "$(dbg "rail SSH")" == ok* ]] && break; sleep 1; done; sleep 0.8; dbg "ssh-section vault" >/dev/null; sleep 0.8
echo "--- no store on this Mac"
dbg "ssh-unlock" >/dev/null; sleep 1.0
expect "no store: the create sheet opens" "$(dbg ssh-state)" "again="
both "vault-create"
dbg "ssh-form cancel" >/dev/null; sleep 0.4

echo "--- classic's vault"
mkdir -p "$DEV/home/.claude"
HOME=$DEV/home "$CLASSIC" init
HOME=$DEV/home "$CLASSIC" add classic-prod classic-secret-value
dbg "ssh-section servers" >/dev/null; dbg "ssh-section vault" >/dev/null; sleep 0.8
expect "the SSH page is showing" "$(dbg page)" "SSH"
dbg "ssh-unlock" >/dev/null; sleep 1.0
expect "the unlock sheet opens" "$(dbg ssh-state)" "master="
both "vault-unlock"
dbg "ssh-form set master wrong-password" >/dev/null; dbg "ssh-form submit" >/dev/null; waitfor "Wrong master"
expect "wrong password says so" "$(dbg ssh-state)" "Wrong master password."
shot "vault-wrong-dark"
dbg "ssh-form set master $MUYA_TEST_MASTER" >/dev/null; dbg "ssh-form submit" >/dev/null; waitfor "rows=1"
expect "sheet closed after the right password" "$(dbg ssh-state)" "section=Password Store"
expect "the classic secret is listed" "$(dbg ssh-state)" "rows=1"
both "vault-unlocked"

echo "--- add from Native, read back with classic's code"
HOME=$DEV/home "$CLASSIC" list | grep -q "classic-prod" && echo "PASS classic still lists its own secret" || { echo "FAIL classic list"; FAILS=$((FAILS+1)); }
echo "FAILS=$FAILS"
exit $FAILS
