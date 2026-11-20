#!/usr/bin/env bash
# Builds MuyaNotifier.app (plain swiftc, ad-hoc signed unless sign.sh signs it for release).
#   native/helpers/notifier/build.sh <out-dir> [version] [build]   -> <out-dir>/MuyaNotifier.app
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
OUT=${1:?usage: build.sh <out-dir> [version] [build]}
VERSION=${2:-0.0.1}
BUILD=${3:-1}
APP=$OUT/MuyaNotifier.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" "$HERE/Info.plist" > "$APP/Contents/Info.plist"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -warnings-as-errors -file-prefix-map "$HERE=/src" \
  "$HERE/main.swift" -o "$APP/Contents/MacOS/MuyaNotifier"
cp "$REPO/src-tauri/icons/icon.icns" "$APP/Contents/Resources/Muya.icns"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
if strings "$APP/Contents/MacOS/MuyaNotifier" | grep -q "/Users/"; then echo "notifier: a home path leaked into the binary" >&2; exit 1; fi
codesign --force --sign - --identifier com.staunch.muya.notifier "$APP"
codesign --verify --strict "$APP"
echo "$APP"
