#!/usr/bin/env bash
# Backward-compat proof for the password store: a vault written by classic Muya's ORIGINAL code opens in Native with the
# same master password and no migration, and what Native adds is readable by that classic code again.
#   native/scripts/test-classic-vault.sh
# Fake HOME only: the operator's real ~/.claude/muya-ssh-vault.enc is never touched.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
TOOL=$HERE/../tools/classic-vault
PRE_MOVE=b703a25   # the commit just before credstore (and its helpers) moved into muya-core: its parent is classic's own, self-contained copy
log() { echo "classic-vault: $*" >&2; }

git -C "$ROOT" show "$PRE_MOVE^:src-tauri/src/credstore.rs" \
  | grep -v '^#\[tauri::command\]' | sed -e 's/use tauri::/use crate::tauri::/' -e 's/app: tauri::AppHandle/app: crate::tauri::AppHandle/' > "$TOOL/src/old_credstore.rs"
(cd "$TOOL" && cargo build --quiet) || { log "could not build the classic helper"; exit 1; }
CLASSIC=$TOOL/target/debug/classic-vault

FAKE=$(mktemp -d /tmp/muya-classic-vault.XXXXXX)
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$FAKE/.claude"
export HOME=$FAKE MUYA_TEST_MASTER='correct horse battery staple'

log "1/3 classic code creates the vault and a secret"
"$CLASSIC" init
"$CLASSIC" add classic-prod 'classic-secret-value'
[ "$("$CLASSIC" list)" = "classic-prod" ]

log "2/3 Native (muyad) opens it, lists it, adds one, locks"
export MUYA_CLASSIC_COMPAT_HOME=$FAKE
eval "$(bash "$HERE/ghostty-env.sh")"
(cd "$ROOT/native" && cargo test --quiet -p muyad --test rpc vault_ -- --nocapture)

log "3/3 classic code reads Native's secret back"
[ "$("$CLASSIC" list)" = "classic-prod,native-added" ] || { log "classic list: $("$CLASSIC" list)"; exit 1; }
[ "$("$CLASSIC" reveal native-added)" = "native-secret-value" ]
[ "$("$CLASSIC" reveal classic-prod)" = "classic-secret-value" ]
log "PASS"
