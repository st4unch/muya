#!/usr/bin/env bash
# Screenshots of the Password Store (a-h) against a dev stack with a classic-made vault in a throwaway HOME. TEST values only.
#   SHOTS=<dir> native/app/shots-secrets-parity.sh
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-sh.XXXXXX)
SHOTS=${SHOTS:-$PWD/screenshots/secrets-parity}; mkdir -p "$SHOTS"
STATE=$TMPDIR/muya-native-dev.state
trap './run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$TMPDIR"' EXIT
CLASSIC=$PWD/../tools/classic-vault/target/debug/classic-vault
[ -x "$CLASSIC" ] || bash ../scripts/test-classic-vault.sh >/dev/null 2>&1
./run-dev.sh start >/dev/null; . "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
shot() { screencapture -x -o -l "$(dbg windowid)" "$SHOTS/$1.png"; }
both() { dbg "appearance dark" >/dev/null; sleep 1.2; shot "$1-dark"; dbg "appearance light" >/dev/null; sleep 1.2; shot "$1-light"; }
export MUYA_TEST_MASTER='correct horse battery staple'
for _ in $(seq 40); do dbg "ssh-reload" >/dev/null; sleep 1; [[ "$(dbg ssh-state)" != *"Starting the background"* ]] && break; done
sleep 2.5; for _ in 1 2 3 4 5; do [[ "$(dbg "rail SSH")" == ok* ]] && break; sleep 1; done; sleep 0.8; dbg "ssh-section vault" >/dev/null; sleep 1
echo "h: create-store sheet"; dbg ssh-unlock >/dev/null; sleep 1.2; both "h-create-store"; dbg "ssh-form cancel" >/dev/null; sleep 0.4
mkdir -p "$DEV/home/.claude"
HOME=$DEV/home "$CLASSIC" init
HOME=$DEV/home "$CLASSIC" add old-router test-pass-AAA111 Lab admin
HOME=$DEV/home "$CLASSIC" add old-switch test-pass-CCC333 Lab netops
HOME=$DEV/home "$CLASSIC" add old-db test-pass-BBB222 Production dba
HOME=$DEV/home "$CLASSIC" add old-vpn test-pass-DDD444 "" ops
dbg "ssh-section servers" >/dev/null; dbg "ssh-section vault" >/dev/null; sleep 0.8
dbg ssh-unlock >/dev/null; sleep 1; dbg "ssh-form set master $MUYA_TEST_MASTER" >/dev/null; dbg "ssh-form submit" >/dev/null
for _ in $(seq 40); do [[ "$(dbg ssh-state)" == *"rows=4"* ]] && break; sleep 0.5; done; sleep 1
echo "a: list"; both "a-list"
echo "b: revealed"; dbg "ssh-secret show old-router" >/dev/null; sleep 1; both "b-revealed"; dbg "ssh-secret show old-router" >/dev/null
echo "c: edit card"; dbg "ssh-secret edit old-db" >/dev/null; sleep 1.2; both "c-edit"; dbg "ssh-secret formcancel" >/dev/null; sleep 0.5
echo "d: new card"; dbg "ssh-secret new" >/dev/null; sleep 1; both "d-new"; dbg "ssh-secret formcancel" >/dev/null; sleep 0.5
echo "e: import key card"; dbg "ssh-secret import key" >/dev/null; sleep 1; both "e-import-key"; dbg "ssh-secret formcancel" >/dev/null; sleep 0.5
echo "f: collapsed"; dbg "ssh-secret collapse Lab" >/dev/null; sleep 1; both "f-collapsed"; dbg "ssh-secret collapse Lab" >/dev/null
echo "g: narrow"; dbg "window 840 700" >/dev/null; sleep 1.2; both "g-840"; dbg "window 640 700" >/dev/null; sleep 1.2; both "g-640"; dbg "window 1120 700" >/dev/null
dbg "ssh-secret layout" | tail -2
echo done
