#!/usr/bin/env bash
#
# build-pkg.sh — build a signed, notarized macOS installer package for Muya
#
#   staged Muya.app -> pkgbuild (installs to /Applications) -> sign with
#   Developer ID Installer -> notarize -> staple -> verify
#
# WHY A .PKG AND NOT JUST THE ZIP
#
# A zip downloaded from a browser carries com.apple.quarantine. If the user
# unzips it and opens Muya.app in place, macOS does NOT run the app they see:
# it runs a read-only copy under
#   /private/var/folders/.../AppTranslocation/<random-uuid>/d/Muya.app
# and that UUID is different on every launch. macOS therefore treats each launch
# as a different application: every file-access permission the user grants is
# recorded against a path that will never exist again, so Muya asks for the same
# permission on every single launch, forever. The self-updater fails too — the
# translocated mount is read-only.
#
# An installer package places the app directly in /Applications with no
# quarantine flag on the installed payload, so translocation never applies and
# the permission the user grants is the last one they are asked for.
#
# REQUIREMENT — a certificate this repo cannot create for you:
#   "Developer ID Installer: <name> (<team>)"
# This is a DIFFERENT certificate from the "Developer ID Application" one used
# to sign the .app. Create it once at
#   https://developer.apple.com/account/resources/certificates/add
# (choose "Developer ID Installer"), download it, double-click to install into
# the login keychain. Then this script works unattended.
#
# Without that certificate the script still builds an UNSIGNED pkg so the
# packaging can be inspected, and exits non-zero — an unsigned pkg is blocked by
# Gatekeeper and must never be published.
#
# Run build-sign-notarize.sh first: this script packages the .app that produced.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

PROFILE="apex-notary"
NOTARY_KEY="${NOTARY_KEY:-$HOME/Downloads/AuthKey_M87Y6CK4GH.p8}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-M87Y6CK4GH}"
NOTARY_ISSUER="${NOTARY_ISSUER:-27d976c7-7a94-40cb-a24c-a4fb49c82be8}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

command -v pkgbuild >/dev/null || die "pkgbuild not found (Xcode command line tools)"
command -v xcrun >/dev/null    || die "xcrun not found"

PRODUCT="$(node -p "require('./src-tauri/tauri.conf.json').productName")"
VER="$(node -p "require('./src-tauri/tauri.conf.json').version")"
IDENT="$(node -p "require('./src-tauri/tauri.conf.json').identifier")"
APP="$ROOT/src-tauri/target/release/bundle/macos/$PRODUCT.app"
PKG="$ROOT/$PRODUCT-$VER-arm64.pkg"

[ -d "$APP" ] || die "no $PRODUCT.app at $APP — run scripts/build-sign-notarize.sh first"

# The .app must already be signed and notarized; the pkg wraps it, it does not
# fix it. Checking here turns a silent "notarized installer full of unsigned
# app" into a stop.
say "Verifying the app we are about to package…"
codesign --verify --deep --strict "$APP" 2>/dev/null \
  || die "app signature invalid — run scripts/build-sign-notarize.sh first"
xcrun stapler validate "$APP" >/dev/null 2>&1 \
  || warn "app has no stapled notarization ticket (run build-sign-notarize.sh)"
ok "app signature valid"

# --- stage: pkgbuild --root takes a directory tree that mirrors the install
# location, so the staging dir must contain exactly Muya.app and nothing else.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
say "Staging $PRODUCT.app…"
# ditto, not cp: cp -R mangles the signature on bundles with symlinked
# frameworks, and a mangled signature fails notarization after the fact.
ditto "$APP" "$STAGE/$PRODUCT.app"
ok "staged"

INSTALLER_ID="$(security find-identity -v 2>/dev/null | grep "Developer ID Installer" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

rm -f "$PKG"
if [ -z "$INSTALLER_ID" ]; then
  say "Building UNSIGNED pkg (no Developer ID Installer certificate found)…"
  pkgbuild --root "$STAGE" --install-location /Applications \
           --identifier "$IDENT" --version "$VER" "$PKG"
  warn "pkg written to $PKG but it is UNSIGNED — Gatekeeper will block it."
  warn "Create a 'Developer ID Installer' certificate at"
  warn "  https://developer.apple.com/account/resources/certificates/add"
  warn "install it into the login keychain, then re-run this script."
  exit 2
fi

say "Building + signing pkg as: $INSTALLER_ID"
pkgbuild --root "$STAGE" --install-location /Applications \
         --identifier "$IDENT" --version "$VER" \
         --sign "$INSTALLER_ID" "$PKG"
ok "pkg signed"

# --- notarize -----------------------------------------------------------------
NOTARY_ARGS=()
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  NOTARY_ARGS=(--keychain-profile "$PROFILE")
elif [ -f "$NOTARY_KEY" ]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  die "no notarization credentials (keychain profile '$PROFILE' or $NOTARY_KEY)"
fi

say "Notarizing pkg…"
xcrun notarytool submit "$PKG" "${NOTARY_ARGS[@]}" --wait
ok "notarization accepted"

say "Stapling ticket to pkg…"
xcrun stapler staple "$PKG"
ok "ticket stapled"

# Gatekeeper assesses installers under the "install" policy, not "execute".
say "Gatekeeper assessment…"
spctl --assess --type install -vv "$PKG" 2>&1 | sed 's/^/    /'
ok "Gatekeeper: accepted"

printf '\033[1;32m\nDONE.\033[0m %s ready: %s\n' "v$VER" "$PKG"
echo "Installs to /Applications — no quarantine, no App Translocation, permissions stick."
