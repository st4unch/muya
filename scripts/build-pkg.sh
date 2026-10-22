#!/usr/bin/env bash
#
# build-pkg.sh — build a signed, notarized macOS installer package for Muya
#
#   staged Muya.app -> pkgbuild + productbuild (asks where to install) -> sign with
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
# An installer package places the app in /Applications (all users) or
# ~/Applications (only me) with no quarantine flag on the installed payload, so
# translocation never applies and the permission the user grants is the last one
# they are asked for.
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
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }
# Text going into the distribution XML.
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }  # sed, not ${v//…}: bash 5.2 reads & there

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
trap 'rm -rf "$STAGE" "$STAGE.plist"' EXIT
say "Staging $PRODUCT.app…"
# ditto, not cp: cp -R mangles the signature on bundles with symlinked
# frameworks, and a mangled signature fails notarization after the fact.
ditto "$APP" "$STAGE/$PRODUCT.app"
ok "staged"

# --- component plist: turn OFF bundle relocation --------------------------------
# pkgbuild marks app bundles BundleIsRelocatable=true by default. With that set,
# the installer does NOT install where --install-location says: it looks up the
# bundle id in Launch Services and installs over whatever existing copy it finds
# — the user's ~/Desktop/Muya.app, ~/Downloads/Muya.app, anywhere. That silently
# defeats the entire reason this package exists, because the copy outside
# /Applications is exactly the one macOS translocates. Caught by test-installing
# the first build: it landed on ~/Desktop/Muya.app instead of /Applications.
COMPONENT_PLIST="$STAGE.plist"
pkgbuild --analyze --root "$STAGE" "$COMPONENT_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST" 2>/dev/null \
  || die "could not disable bundle relocation in $COMPONENT_PLIST"
[ "$(/usr/libexec/PlistBuddy -c "Print :0:BundleIsRelocatable" "$COMPONENT_PLIST")" = "false" ] \
  || die "BundleIsRelocatable is still true — the pkg would install over an existing copy"
ok "bundle relocation disabled (installs where the user chooses, never over a stray copy)"

INSTALLER_ID="$(security find-identity -v 2>/dev/null | grep "Developer ID Installer" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

# --- component pkg + product archive: the installer ASKS who it is for -------------
# The component pkg carries the app; a product archive (productbuild + a distribution
# file) around it gives the Installer its "Installation Type" step:
#   * Install for all users   → /Applications    (default, admin password)
#   * Install for me only     → ~/Applications   (no admin password)
# The install location is relative to the chosen domain. A choice-level customLocation
# would pin it absolutely: test-installing with customLocation="/Applications" and
# "only me" put the app in /Applications, not ~/Applications. So no custom folder.
# Two copies of the same bundle id confuse Launch Services, the login item and the
# file-access permissions, so when a copy already exists the installer only offers
# the place where it is (an update), never a second one (the <domains> scripts).
# Relocation stays OFF (above), so it lands there — never over a stray copy elsewhere.
WORK="$(mktemp -d)"   # productbuild scans --package-path: keep it to our own files
COMPONENT_PKG="$WORK/$PRODUCT-component.pkg"
DIST="$WORK/distribution.xml"
trap 'rm -rf "$STAGE" "$STAGE.plist" "$WORK"' EXIT
pkgbuild --root "$STAGE" --component-plist "$COMPONENT_PLIST" \
         --install-location /Applications \
         --identifier "$IDENT" --version "$VER" "$COMPONENT_PKG" >/dev/null
ok "component pkg built"

cat > "$DIST" <<EOXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>$(xml_escape "$PRODUCT")</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <script>
    function copyAt(dir) { return system.files.fileExistsAtPath(dir + '/$(xml_escape "$PRODUCT").app'); }
    function systemCopy() { return copyAt('/Applications'); }
    function homeCopy() { return copyAt(system.env.HOME + '/Applications'); }
    </script>
    <domains enable_localSystem="!homeCopy() || systemCopy()" enable_currentUserHome="!systemCopy() || homeCopy()" enable_anywhere="false"/>
    <choices-outline>
        <line choice="app"/>
    </choices-outline>
    <choice id="app" title="$(xml_escape "$PRODUCT")" description="The $(xml_escape "$PRODUCT") app.">
        <pkg-ref id="$(xml_escape "$IDENT")"/>
    </choice>
    <pkg-ref id="$(xml_escape "$IDENT")" version="$(xml_escape "$VER")" onConclusion="none">$(basename "$COMPONENT_PKG")</pkg-ref>
</installer-gui-script>
EOXML

rm -f "$PKG"
if [ -z "$INSTALLER_ID" ]; then
  say "Building UNSIGNED pkg (no Developer ID Installer certificate found)…"
  productbuild --distribution "$DIST" --package-path "$WORK" "$PKG"
  warn "pkg written to $PKG but it is UNSIGNED — Gatekeeper will block it."
  warn "Create a 'Developer ID Installer' certificate at"
  warn "  https://developer.apple.com/account/resources/certificates/add"
  warn "install it into the login keychain, then re-run this script."
  exit 2
fi

say "Building + signing installer as: $INSTALLER_ID"
productbuild --distribution "$DIST" --package-path "$WORK" \
             --sign "$INSTALLER_ID" "$PKG"
ok "installer signed (asks: all users / only me)"

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
echo "Asks: all users (/Applications) or only me (~/Applications); an update stays where the app already is — no quarantine, no App Translocation, permissions stick."
