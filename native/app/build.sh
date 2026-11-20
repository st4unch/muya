#!/usr/bin/env bash
# Builds MuyaNative.app (dev: com.staunch.muya.dev; MUYA_RELEASE=1: "Muya", com.staunch.muya = classic's own id; ad-hoc signed) and the client tests with
# plain swiftc: no Xcode project, no SwiftPM, no external packages.
#
#   native/app/build.sh            build the app -> build/MuyaNative.app
#   native/app/build.sh test       build and run the client unit tests
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
OUT=$HERE/build
[ "${MUYA_RELEASE:-}" = "1" ] && OUT=$HERE/build-release   # never overwrite the dev build the verify scripts use

# libghostty-vt: the reproducible build from native/scripts/ghostty-env.sh (installed under a
# fixed, user-independent prefix).
GHOSTTY=$(bash "$HERE/../scripts/ghostty-env.sh" | sed -n 's|^export PKG_CONFIG_PATH="\(.*\)/share/pkgconfig"|\1|p')
[ -f "$GHOSTTY/lib/libghostty-vt.a" ] || { echo "build: libghostty-vt missing at '$GHOSTTY' (run native/scripts/ghostty-env.sh)" >&2; exit 1; }

# MUYA_TEST_HOOKS compiles the debug socket and the mock-data hooks the verify scripts drive. The shipping build
# (scripts/bundle.sh sets MUYA_RELEASE=1) leaves them out entirely.
HOOKS=(-D MUYA_TEST_HOOKS)
[ "${MUYA_RELEASE:-}" = "1" ] && HOOKS=()
SWIFTC=(swiftc -swift-version 5 -target arm64-apple-macos14.0 -file-prefix-map "$HERE=/src" -warnings-as-errors ${HOOKS[@]+"${HOOKS[@]}"})
CLIENT=(Sources/Client/*.swift Sources/Logic/*.swift Sources/Inspector/InspectorLogic.swift Sources/Inspector/InspectorSource.swift Sources/Queue/QueueLogic.swift Sources/Queue/QueueSource.swift Sources/SSH/SSHLogic.swift Sources/SSH/SSHService.swift Sources/Bridge/BridgeLogic.swift Sources/Bridge/BridgeService.swift Sources/Resources/ResourcesLogic.swift Sources/Resources/ResourcesService.swift Sources/Resources/SlashBuiltins.swift Sources/Vault/VaultLogic.swift)

mkdir -p "$OUT"

if [ "${1:-}" = "test" ]; then
  # Tests link libghostty-vt too: selection and scrollback are checked against a real terminal.
  "${SWIFTC[@]}" -Onone -I CGhostty -Xcc -I"$GHOSTTY/include" -L "$GHOSTTY/lib" \
    "${CLIENT[@]}" Sources/App/Replica.swift Sources/App/CustomGlyphs.swift Sources/App/Theme.swift Sources/Theme/*.swift Tests/*.swift -o "$OUT/ClientTests"
  exec "$OUT/ClientTests" "${@:2}"
fi

BIN=$OUT/MuyaNative
"${SWIFTC[@]}" -O -I CGhostty -Xcc -I"$GHOSTTY/include" -L "$GHOSTTY/lib" \
  "${CLIENT[@]}" Sources/Inspector/InspectorPane.swift Sources/Queue/QueuePage.swift Sources/Queue/QueueViews.swift Sources/Queue/QueueDebug.swift Sources/SSH/SSHForm.swift Sources/SSH/SSHPage.swift Sources/SSH/SSHDaemon.swift Sources/Vault/VaultPanel.swift Sources/Vault/DebugP12.swift Sources/Resources/ResourcesPage.swift Sources/Resources/SlashPopover.swift Sources/Resources/ResourcesWiring.swift Sources/Resources/DebugP7.swift Sources/Theme/*.swift Sources/App/*.swift -o "$BIN"

APP=$OUT/MuyaNative.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
# The product version is the Tauri app's (one number for both apps): the footer shows CFBundleShortVersionString.
PRODUCT_VERSION=${MUYA_PRODUCT_VERSION:-$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' ../../src-tauri/tauri.conf.json | head -1)}
[ -n "$PRODUCT_VERSION" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PRODUCT_VERSION" "$APP/Contents/Info.plist"
cp ../../src-tauri/icons/icon.icns "$APP/Contents/Resources/Muya.icns"   # Dock / Finder / Cmd-Tab icon (CFBundleIconFile=Muya)
cp ../THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# The release build is Muya 5: classic's own id (no .dev), so macOS permissions carry over (docs/prd-muya-v5-replace.md).
# This is only the donor of the binary; scripts/bundle.sh makes the real flavours (release / bridge) from it.
BUNDLE_ID=com.staunch.muya.dev
if [ "${MUYA_RELEASE:-}" = "1" ]; then
  BUNDLE_ID=com.staunch.muya
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleDisplayName Muya" -c "Set :CFBundleName Muya" "$APP/Contents/Info.plist"
fi
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/" # IBM Plex Sans + JetBrains Mono, SIL OFL 1.1 (licence texts included)
cp "$BIN" "$APP/Contents/MacOS/MuyaNative"
if strings "$APP/Contents/MacOS/MuyaNative" | grep -q "/Users/"; then
  echo "build: a home path leaked into the binary:" >&2; strings "$APP/Contents/MacOS/MuyaNative" | grep "/Users/" | head -3 >&2; exit 1
fi
if [ "${MUYA_RELEASE:-}" = "1" ]; then
  # A release must not keep the dev bundle id (the template Info.plist ships com.staunch.muya.dev).
  if [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")" = "com.staunch.muya.dev" ]; then
    echo "build: the release bundle still has the dev bundle id" >&2; exit 1
  fi
  # Into a variable first: `grep -q` closing the pipe early would make `strings` fail under pipefail and hide a hit.
  SYMS=$(strings "$APP/Contents/MacOS/MuyaNative")
  if grep -qE "DebugServer|debug-socket|MUYA_SOCKET" <<<"$SYMS"; then
    echo "build: the release binary still contains the debug socket or the MUYA_SOCKET override" >&2; exit 1
  fi
fi
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
echo "build: $APP"
