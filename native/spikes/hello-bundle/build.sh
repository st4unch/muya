#!/usr/bin/env bash
# Faz 0 S2: build, assemble, sign (inside-out, hardened runtime) and optionally notarize the
# hello bundle with nested muya-ptyd / muyad LaunchAgents.
#
#   ./build.sh                 build + sign -> build/out/MuyaSpike.app
#   ./build.sh --notarize      ... + notarize, staple, Gatekeeper assessment
#   ./build.sh --verify        two clean builds; executables and CDHashes must be identical
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
IDENTITY="Developer ID Application"
PROFILE="apex-notary" # xcrun notarytool store-credentials apex-notary
APP_ID=com.staunch.muya.spike

log() { echo "build: $*" >&2; }

build() { # $1 = output dir
  local out=$1 target="$1/target"
  rm -rf "$out" && mkdir -p "$out"
  # Keep source, cargo registry and target paths out of the binaries.
  RUSTFLAGS="--remap-path-prefix=$HERE=/src --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=$target=/target" \
    cargo build --quiet --release --locked --manifest-path daemons/Cargo.toml --target-dir "$target"
  swiftc -O -swift-version 6 -target arm64-apple-macos26.0 -file-prefix-map "$HERE=/src" \
    app/main.swift -o "$out/MuyaSpike"

  local app="$out/MuyaSpike.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchAgents"
  cp bundle/Info.plist "$app/Contents/"
  cp bundle/LaunchAgents/*.plist "$app/Contents/Library/LaunchAgents/"
  cp "$out/MuyaSpike" "$app/Contents/MacOS/"
  cp "$target/release/muya-ptyd" "$target/release/muyad" "$app/Contents/MacOS/"
  if strings "$app"/Contents/MacOS/* | grep -q "/Users/"; then
    log "a home path leaked into a binary:"; strings "$app"/Contents/MacOS/* | grep "/Users/" | head -3 >&2; exit 1
  fi
  (cd "$app/Contents/MacOS" && shasum -a 256 *) > "$out/unsigned.sha256"

  # Inside-out: nested executables first, each with its own identifier (the peer gate checks it).
  local sign=(codesign --force --timestamp --options runtime -s "$IDENTITY")
  "${sign[@]}" --identifier "$APP_ID.ptyd" "$app/Contents/MacOS/muya-ptyd"
  "${sign[@]}" --identifier "$APP_ID.muyad" "$app/Contents/MacOS/muyad"
  "${sign[@]}" "$app"
  codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | tail -1 >&2
  for exe in muya-ptyd muyad MuyaSpike; do
    printf '%s %s\n' "$exe" "$(codesign -dvvv "$app/Contents/MacOS/$exe" 2>&1 | sed -n 's/^CDHash=//p')"
  done > "$out/cdhash.txt"
}

case "${1:-}" in
--verify)
  build build/a && build build/b
  if cmp -s build/a/unsigned.sha256 build/b/unsigned.sha256 && cmp -s build/a/cdhash.txt build/b/cdhash.txt; then
    cat build/a/cdhash.txt; log "reproducible: executables and CDHashes identical across two clean builds"
  else
    diff build/a/unsigned.sha256 build/b/unsigned.sha256 >&2 || true
    diff build/a/cdhash.txt build/b/cdhash.txt >&2 || true
    log "NOT reproducible"; exit 1
  fi
  ;;
*)
  build build/out
  cat build/out/cdhash.txt
  if [ "${1:-}" = "--notarize" ]; then
    app=build/out/MuyaSpike.app zip=build/out/MuyaSpike.zip
    ditto -c -k --keepParent "$app" "$zip"
    log "notarizing (waits for Apple)"
    xcrun notarytool submit "$zip" --keychain-profile "$PROFILE" --wait 2>&1 | grep -E 'status:|id:' | tail -2 >&2
    xcrun stapler staple "$app" >/dev/null && xcrun stapler validate "$app" >&2
    spctl -a -vvv -t exec "$app" 2>&1 >&2
    rm -f "$zip" && ditto -c -k --keepParent "$app" "$zip"
  fi
  ;;
esac
