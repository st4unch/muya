#!/usr/bin/env bash
#
# build-sign-notarize.sh — unattended local release build for Muya
#
#   build (signs via Developer ID in tauri.conf) -> verify signature ->
#   notarize (apex-notary keychain profile) -> staple -> Gatekeeper assess ->
#   ditto distribution zip
#
# No arguments. Version is read from src-tauri/tauri.conf.json (single source).
# Touches NOTHING remote. Run publish-release.sh afterwards to ship it.
#
# Exit non-zero on any failure (safe to chain).
#
set -euo pipefail

# --- locate repo root from this script's location -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

PROFILE="apex-notary"   # xcrun notarytool store-credentials apex-notary

# Direct App Store Connect API key — used when the keychain profile isn't
# accessible (e.g. login keychain locked). Overridable via env.
NOTARY_KEY="${NOTARY_KEY:-$HOME/Downloads/AuthKey_M87Y6CK4GH.p8}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-M87Y6CK4GH}"
NOTARY_ISSUER="${NOTARY_ISSUER:-27d976c7-7a94-40cb-a24c-a4fb49c82be8}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# --- preflight ----------------------------------------------------------------
command -v node >/dev/null        || die "node not found"
command -v xcrun >/dev/null        || die "xcrun (Xcode CLT) not found"
command -v ditto >/dev/null        || die "ditto not found"

# Pick a notary auth mode: prefer the keychain profile; fall back to the raw
# API key (survives a locked keychain, since no keychain read is needed).
NOTARY_ARGS=()
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  NOTARY_ARGS=(--keychain-profile "$PROFILE")
  ok "notary auth: keychain profile '$PROFILE'"
elif [ -f "$NOTARY_KEY" ]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  ok "notary auth: API key $NOTARY_KEY_ID (profile unavailable)"
else
  die "no notary auth — store profile '$PROFILE' or place key at $NOTARY_KEY"
fi

VERSION="$(node -p "require('$ROOT/src-tauri/tauri.conf.json').version")"
[ -n "$VERSION" ] || die "could not read version from tauri.conf.json"
PRODUCT="$(node -p "require('$ROOT/src-tauri/tauri.conf.json').productName")"
[ -n "$PRODUCT" ] || die "could not read productName from tauri.conf.json"
ARCH="$(uname -m)"   # arm64 on Apple Silicon
say "$PRODUCT v$VERSION ($ARCH) — local release build"

# --- 1. build (frontend + rust, auto-signed) ----------------------------------
say "Building (npm run tauri build) — this is the slow part…"
npm run tauri build
ok "build complete"

# --- 2. locate the signed .app ------------------------------------------------
# Select by productName, not `ls | head -1`: a stale *.app from a prior rename
# (e.g. "Apex Mission Control.app") would otherwise be picked and shipped.
APP="$ROOT/src-tauri/target/release/bundle/macos/$PRODUCT.app"
[ -d "$APP" ] || die "no $PRODUCT.app found under bundle/macos/"
ok "app: $APP"

# --- 3. verify signature ------------------------------------------------------
say "Verifying code signature…"
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1 \
  || die "codesign verification failed"
ok "signature valid"

# --- 4. notarize (submit a zip, --wait) ---------------------------------------
ZIP="$ROOT/Muya-${VERSION}-${ARCH}.zip"
say "Zipping for notarization…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

say "Submitting to Apple notary service (waits for result)…"
SUBMIT_OUT="$(xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait 2>&1)"
echo "$SUBMIT_OUT"
echo "$SUBMIT_OUT" | grep -q "status: Accepted" \
  || die "notarization NOT accepted — see output above"
ok "notarization accepted"

# --- 5. staple + validate -----------------------------------------------------
say "Stapling ticket to .app…"
xcrun stapler staple "$APP" >/dev/null
xcrun stapler validate "$APP" >/dev/null || die "stapler validate failed"
ok "ticket stapled"

# --- 6. Gatekeeper assessment -------------------------------------------------
say "Gatekeeper assessment…"
spctl -a -vvv -t install "$APP" 2>&1 | grep -q "source=Notarized Developer ID" \
  || die "Gatekeeper did not report Notarized Developer ID"
ok "Gatekeeper: accepted (Notarized Developer ID)"

# --- 7. rebuild distribution zip WITH the stapled ticket ----------------------
say "Rebuilding distribution zip (with stapled ticket)…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
ok "distribution zip: $ZIP ($(du -h "$ZIP" | cut -f1))"

printf '\033[1;32m\nDONE.\033[0m v%s ready: %s\n' "$VERSION" "$ZIP"
printf 'Next: scripts/publish-release.sh  (pushes + creates GitHub release)\n'
