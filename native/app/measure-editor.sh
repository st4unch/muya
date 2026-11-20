#!/usr/bin/env bash
# Engine spike harness: builds tools/editor-spike with the real SyntaxHighlight.swift and prints open / highlight / typing / RSS for
# JSON fixtures at 3, 20 and 50 MB on TextKit 1 and 2 (docs/prd-native-editor.md ADR). The window is off screen; no CGEvents.
set -euo pipefail
cd "$(dirname "$0")"
OUT=$(mktemp -d /private/tmp/muya-spike.XXXXXX); trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -O -target arm64-apple-macos26.0 Sources/Logic/SyntaxHighlight.swift tools/editor-spike/main.swift -o "$OUT/spike"
for mb in ${SIZES:-3 20 50}; do
  f=$(python3 -I make-large-fixtures.py "$OUT" json "$mb")
  for m in tk1 tk2; do "$OUT/spike" "$f" "$m" hl | tail -1; done
  rm -f "$f"
done
