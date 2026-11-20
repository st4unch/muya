#!/usr/bin/env bash
# Assemble the Muya app from the native app build and release builds of the Rust parts.
# Local only: builds into native/target-release, signs nothing (run sign.sh next).
#
#   native/scripts/bundle.sh                    -> native/target-release/bundle/release/Muya.app
#   MUYA_FLAVOR=bridge native/scripts/bundle.sh -> native/target-release/bundle/bridge/"Muya Native.app"
#   MUYA_E2E_ID=com.staunch.muya.e2e ...        -> a throwaway copy under that id (bundle/e2e-<flavor>/); never the real id
#   MUYA_REBUILD_APP=1 ...                      rebuild the Swift app first (default: reuse native/app/build-release)
#   MUYA_SIDECAR=<path> ...                     ship this muya-ssh-mcp instead of building it
#
# Flavours (docs/prd-muya-v5-replace.md):
#   release  Muya.app          com.staunch.muya          Muya 5: classic's own identity, so macOS permissions carry over
#   bridge   Muya Native.app   com.staunch.muya.native   the last build on the native-beta pointer; it moves itself to Muya 5
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NATIVE=$(cd "$HERE/.." && pwd)
REPO=$(cd "$NATIVE/.." && pwd)
TARGET=$NATIVE/target-release
log() { echo "bundle: $*" >&2; }

FLAVOR=${MUYA_FLAVOR:-release}
BASE_ID=${MUYA_E2E_ID:-com.staunch.muya}
case "$FLAVOR" in
  release) BUNDLE_ID=$BASE_ID;        NAME="Muya";        APPFILE="Muya.app" ;;
  bridge)  BUNDLE_ID=$BASE_ID.native; NAME="Muya Native"; APPFILE="Muya Native.app" ;;
  *) log "MUYA_FLAVOR must be release or bridge (got '$FLAVOR')"; exit 2 ;;
esac
# A throwaway id must be visibly not the real one: the real id is only ever produced without MUYA_E2E_ID.
if [ -n "${MUYA_E2E_ID:-}" ]; then
  case "$MUYA_E2E_ID" in com.staunch.muya.e2e*) ;; *) log "MUYA_E2E_ID must start with com.staunch.muya.e2e"; exit 2 ;; esac
  OUT=$TARGET/bundle/e2e-$FLAVOR
  RUST_FEATURES=(--features muyad/e2e)
  RELEASE_TARGET=$NATIVE/target-release-e2e   # an e2e muyad is never mixed into the shipping build directory
else
  OUT=$TARGET/bundle/$FLAVOR
  RUST_FEATURES=()
  RELEASE_TARGET=$TARGET
fi
APP="$OUT/$APPFILE"

eval "$(bash "$HERE/ghostty-env.sh")"

# One product version for both apps: the Tauri app's (the footer shows CFBundleShortVersionString).
# MUYA_PRODUCT_VERSION overrides it (a release cut from this branch before the version bump has been merged in).
VERSION=${MUYA_PRODUCT_VERSION:-$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$REPO/src-tauri/tauri.conf.json" | head -1)}
[ -n "$VERSION" ] || VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$NATIVE/Cargo.toml" | head -1)
# The daemons announce this in their hello (build id) so the app can tell an older daemon from its own.
export MUYA_PRODUCT_VERSION="$VERSION"

# Remap source, cargo and target paths so no home directory ends up in a binary.
export CARGO_INCREMENTAL=0
export RUSTFLAGS="--remap-path-prefix=$REPO=/src --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=$RELEASE_TARGET=/target"
(cd "$NATIVE" && cargo build --release --locked --target-dir "$RELEASE_TARGET" -p muya-ptyd -p muyad -p muyactl ${RUST_FEATURES[@]+"${RUST_FEATURES[@]}"})

APP_BIN=$NATIVE/app/build-release/MuyaNative.app/Contents/MacOS/MuyaNative
if [ -n "${MUYA_REBUILD_APP:-}" ] || [ ! -x "$APP_BIN" ]; then
  log "building the Swift app"; MUYA_RELEASE=1 bash "$NATIVE/app/build.sh"
fi
# The sidecar lives in the Tauri crate (its own target dir; builds the whole lib, ~3 min cold). The prebuilt
# src-tauri/binaries copy is NOT used: it carries cargo-registry paths (the leak gate below caught it).
if [ -z "${MUYA_SIDECAR:-}" ]; then
  (cd "$REPO/src-tauri" && RUSTFLAGS="--remap-path-prefix=$REPO=/src --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=$TARGET/sidecar=/target" \
    cargo build --release --locked --bin muya-ssh-mcp --target-dir "$TARGET/sidecar")
fi
SIDECAR=${MUYA_SIDECAR:-$TARGET/sidecar/release/muya-ssh-mcp}
[ -x "$SIDECAR" ] || { log "sidecar not found: $SIDECAR"; exit 1; }

BUILD=$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 1)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Library/LaunchAgents"
sed -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD|g" -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" -e "s|@NAME@|$NAME|g" "$HERE/bundle/Info.plist" > "$APP/Contents/Info.plist"
cp "$APP_BIN" "$APP/Contents/MacOS/MuyaNative"
# The main executable is a tiny launcher (native/launcher): on macOS 14+ it execs MuyaNative, below that it restores Muya Classic.
# Named `muya` like classic's executable. The e2e flavour gets the test build (fake-OS override), a shipping flavour never.
LAUNCHER_FLAGS=()
[ -z "${MUYA_E2E_ID:-}" ] || LAUNCHER_FLAGS=(-DMUYA_LAUNCHER_TEST)
clang -arch arm64 -mmacosx-version-min=11.0 -O2 -Wall -Werror ${LAUNCHER_FLAGS[@]+"${LAUNCHER_FLAGS[@]}"} -I "$NATIVE/launcher" -o "$APP/Contents/MacOS/muya" "$NATIVE/launcher/launcher.c"
cp "$RELEASE_TARGET/release/muya-ptyd" "$RELEASE_TARGET/release/muyad" "$RELEASE_TARGET/release/muyactl" "$APP/Contents/MacOS/"
cp "$SIDECAR" "$APP/Contents/MacOS/muya-ssh-mcp"
# Only the two Native services. Classic's scheduler agent (com.staunch.muya.scheduler) is NOT shipped: its program
# (Contents/MacOS/muya) does not exist here, and the app boots a leftover job out at first launch.
for p in "$HERE"/bundle/LaunchAgents/*.plist; do
  sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" "$p" > "$APP/Contents/Library/LaunchAgents/$(basename "$p")"
done
# The notifier helper: muyad launches it for permission-prompt notifications while no Muya window runs (it posts through
# UNUserNotificationCenter, so the banner carries Muya's icon). Ad-hoc signed here; sign.sh re-signs it for release.
bash "$NATIVE/helpers/notifier/build.sh" "$RELEASE_TARGET/helper" "$VERSION" "$BUILD" >/dev/null
cp -R "$RELEASE_TARGET/helper/MuyaNotifier.app" "$APP/Contents/Helpers/"
cp "$REPO/src-tauri/icons/icon.icns" "$APP/Contents/Resources/Muya.icns"
[ -f "$NATIVE/THIRD_PARTY_NOTICES.md" ] && cp "$NATIVE/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
chmod 755 "$APP"/Contents/MacOS/*
plutil -lint "$APP/Contents/Info.plist" "$APP"/Contents/Library/LaunchAgents/*.plist >&2
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "$BUNDLE_ID" ] || { log "bundle id did not take"; exit 1; }
[ ! -e "$APP/Contents/Library/LaunchAgents/com.staunch.muya.scheduler.plist" ] || { log "the classic scheduler agent must not ship in Muya 5"; exit 1; }

# No machine-specific string in anything we ship.
leak=$(strings "$APP"/Contents/MacOS/* "$APP"/Contents/Helpers/*/Contents/MacOS/* | grep -E "/Users/" | head -3 || true)
[ -z "$leak" ] || { log "a home path leaked into a binary:"; echo "$leak" >&2; exit 1; }
# A shipping flavour must not carry the e2e hooks (only the throwaway e2e build has them).
if [ -z "${MUYA_E2E_ID:-}" ]; then
  lh=$(strings "$APP/Contents/MacOS/muya" | grep -E "MUYA_LAUNCHER_FAKE_MAJOR|MUYA_LAUNCHER_NO_DIALOG" | head -3 || true)
  [ -z "$lh" ] || { log "the shipping launcher contains test overrides:"; echo "$lh" >&2; exit 1; }
  hooks=$(strings "$APP/Contents/MacOS/muyad" | grep -E "MUYA_SWITCHOVER_E2E" | head -3 || true)
  [ -z "$hooks" ] || { log "the shipping muyad contains e2e overrides:"; echo "$hooks" >&2; exit 1; }
fi
log "assembled $APP ($BUNDLE_ID $VERSION)"
