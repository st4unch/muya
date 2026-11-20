#!/usr/bin/env bash
# Muya 5 UI proof (docs/prd-muya-v5-replace.md) in the dev MOCK app: the Settings > Updates group with "Return to Muya Classic
# (4.1.22)", its confirm dialog, and the app-menu item, in dark and light. Screenshots (the app renders its own windows: works with a locked screen) go to native/app/screenshots/v5-*.png.
#   native/app/verify-v5-ui.sh        (build the dev app first: native/app/build.sh)       exit 1 on any FAIL
set -uo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d /tmp/muya-v5ui.XXXXXX)
export TMPDIR=$WORK
STATE=$WORK/muya-native-dev.state
cleanup() { ./run-mock.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
./run-mock.sh start >/dev/null || exit 1
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
for _ in $(seq 100); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
mkdir -p screenshots

MENU=$(dbg v5-menu-titles)
case "$MENU" in *"Check for Updates…"*"Return to Muya Classic (4.1.22)…"*) ok "app menu has 'Return to Muya Classic (4.1.22)…' ($MENU)";; *) bad "app menu item missing: $MENU";; esac

for theme in Dark Light; do
  t=$(echo "$theme" | tr 'A-Z' 'a-z')
  dbg "settings-set appearance $theme" >/dev/null; sleep 1.5
  wid=$(dbg settings-open); sleep 1.5
  dbg p4-settings-bottom >/dev/null; sleep 0.8
  dbg "snap $PWD/screenshots/v5-updates-$t.png" >/dev/null
  [ -s "screenshots/v5-updates-$t.png" ] && ok "Settings > Updates screenshot ($t)" || bad "no Settings screenshot ($t)"
  dbg v5-return-dialog >/dev/null; sleep 1.2
  dbg "snap $PWD/screenshots/v5-return-dialog-$t.png" >/dev/null
  [ -s "screenshots/v5-return-dialog-$t.png" ] && ok "Return dialog screenshot ($t)" || bad "no dialog screenshot ($t)"
  dbg v5-dialog-dismiss >/dev/null; sleep 0.8
done
echo "RESULT: $([ $fails = 0 ] && echo PASS || echo "FAIL ($fails)")"
exit $fails
