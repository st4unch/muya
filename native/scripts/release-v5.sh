#!/usr/bin/env bash
#
# release-v5.sh - build the Muya 5 release artifacts. Builds, signs (Developer ID), notarizes and staples; PUBLISHES NOTHING.
#
#   MUYA_VERSION_BUMP=major native/scripts/release-v5.sh
#
# Produces in native/target-release/v5-release/:
#   Muya-<ver>-arm64.zip              the notarized Muya.app (manual download; also what "Return" style checks use)
#   Muya-<ver>-arm64.app.tar.gz       what classic's Tauri updater downloads (root dir Muya.app, no AppleDouble entries)
#   Muya-<ver>-arm64.app.tar.gz.sig   its minisign signature (Tauri updater key)
#   latest.json                       the feed, same shape as scripts/publish-release.sh writes
#   Muya-Native-<bridge>.zip          the bridge build ("Muya Native.app", id com.staunch.muya.native) for the native-beta pointer
#   SHA256SUMS
#
# Env: MUYA_SIGN_IDENTITY (default: the Developer ID Application identity of Team 7PG95YYJ64), MUYA_UPDATE_KEY (default
#      ~/.tauri/muya-update.key), TAURI_CLI_DIR (a directory where `npx tauri signer sign` works), MUYA_BRIDGE_VERSION (4.1.27),
#      MUYA_SKIP_BRIDGE=1 to skip the bridge. Credentials for notarization: native/scripts/notarize.sh reads them itself.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NATIVE=$(cd "$HERE/.." && pwd)
REPO=$(cd "$NATIVE/.." && pwd)
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m  x %s\033[0m\n' "$*" >&2; exit 1; }

VERSION=${MUYA_PRODUCT_VERSION:-$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$REPO/src-tauri/tauri.conf.json" | head -1)}
BRIDGE=${MUYA_BRIDGE_VERSION:-4.1.27}
ARCH=$(uname -m)
KEY=${MUYA_UPDATE_KEY:-$HOME/.tauri/muya-update.key}
[ -f "$KEY" ] || die "update signing key missing: $KEY"
export MUYA_SIGN_IDENTITY=${MUYA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*(7PG95YYJ64)\)".*/\1/p' | head -1)}
[ -n "$MUYA_SIGN_IDENTITY" ] || die "no Developer ID Application identity for Team 7PG95YYJ64"
# The Tauri CLI comes from node_modules, which only the main checkout has: released from a worktree, $REPO has no
# node_modules and `npx tauri` fails. Fall back to the checkout the worktree belongs to (git's common dir).
TAURI_CLI_DIR=${TAURI_CLI_DIR:-$REPO}
if [ ! -d "$TAURI_CLI_DIR/node_modules" ]; then
  MAIN_CHECKOUT=$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')
  [ -n "$MAIN_CHECKOUT" ] && [ -d "$MAIN_CHECKOUT/node_modules" ] && TAURI_CLI_DIR=$MAIN_CHECKOUT
fi
[ -d "$TAURI_CLI_DIR/node_modules" ] || die "no node_modules for the Tauri CLI (looked in $TAURI_CLI_DIR); run npm install there"
OUT=$NATIVE/target-release/v5-release
rm -rf "$OUT"; mkdir -p "$OUT"
[ -z "${MUYA_E2E_ID:-}" ] || die "MUYA_E2E_ID is set: this script builds the REAL ids"

# The version guard: a wrong number never reaches a build (a major step needs MUYA_VERSION_BUMP=major).
if [ -x "$REPO/scripts/check-version.sh" ]; then (cd "$REPO" && bash scripts/check-version.sh) || die "fix the version first"; fi

say "Muya $VERSION (release flavour, id com.staunch.muya)"
MUYA_PRODUCT_VERSION=$VERSION MUYA_FLAVOR=release bash "$HERE/bundle.sh"
APP=$NATIVE/target-release/bundle/release/Muya.app
bash "$HERE/sign.sh" "$APP"
bash "$HERE/notarize.sh" "$APP" "$OUT/Muya-$VERSION-$ARCH.zip"

say "the designated requirement must be classic's"
WANT='identifier "com.staunch.muya" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "7PG95YYJ64"'
GOT=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
[ "$GOT" = "$WANT" ] || die "designated requirement differs from classic's:
$GOT"

say "updater archive"
TARGZ=$OUT/Muya-$VERSION-$ARCH.app.tar.gz
# COPYFILE_DISABLE: no AppleDouble "._" entries (the updater strips each entry's first path component).
COPYFILE_DISABLE=1 tar -czf "$TARGZ" -C "$(dirname "$APP")" "$(basename "$APP")"
BAD=$(python3 - "$TARGZ" Muya.app <<'PY'
import sys, tarfile, pathlib
bad = [m.name for m in tarfile.open(sys.argv[1]).getmembers() if not pathlib.PurePath(m.name).parts or pathlib.PurePath(m.name).parts[0] != sys.argv[2] or any(p.startswith("._") for p in pathlib.PurePath(m.name).parts)]
print("\n".join(bad))
PY
)
[ -z "$BAD" ] || die "stray entries in the updater archive: $BAD"
( cd "$TAURI_CLI_DIR" && TAURI_SIGNING_PRIVATE_KEY_PATH="$KEY" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" npx tauri signer sign "$TARGZ" ) >/dev/null || die "signing the updater archive failed (see the error above)"
SIG=$(cat "$TARGZ.sig")
# The archive must verify with the public key compiled into classic 4.1.22 (the same code the apps use).
PUB=$(sed -n 's/.*"pubkey": "\([^"]*\)".*/\1/p' "$REPO/src-tauri/tauri.conf.json" | head -1)
(cd "$NATIVE" && cargo run -q -p muya-switchover --example verify_sig -- "$TARGZ" "$TARGZ.sig" "$PUB") || die "the updater archive does not verify against the updater public key"
cat > "$OUT/latest.json" <<EOF
{
  "version": "$VERSION",
  "notes": "Release v$VERSION",
  "pub_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "platforms": {
    "darwin-aarch64": {
      "signature": "$SIG",
      "url": "https://github.com/st4unch/muya/releases/download/v$VERSION/Muya-$VERSION-$ARCH.app.tar.gz"
    }
  }
}
EOF

if [ -z "${MUYA_SKIP_BRIDGE:-}" ]; then
  say "bridge build $BRIDGE (Muya Native.app, id com.staunch.muya.native) for the native-beta pointer"
  MUYA_PRODUCT_VERSION=$BRIDGE MUYA_FLAVOR=bridge bash "$HERE/bundle.sh"
  BAPP="$NATIVE/target-release/bundle/bridge/Muya Native.app"
  bash "$HERE/sign.sh" "$BAPP"
  bash "$HERE/notarize.sh" "$BAPP" "$OUT/Muya-Native-$BRIDGE.zip"
fi

( cd "$OUT" && shasum -a 256 *.zip *.tar.gz latest.json > SHA256SUMS )
say "artifacts in $OUT"; ls -la "$OUT"
