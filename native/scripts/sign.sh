#!/usr/bin/env bash
# Sign the Muya app (any flavour of bundle.sh) inside-out with hardened runtime. Ad-hoc by default.
#
#   native/scripts/sign.sh [app]                      ad-hoc ("-"): verifies structure only
#   MUYA_SIGN_IDENTITY="Developer ID Application: ..." native/scripts/sign.sh   real identity (NOT run in CI-less prep)
#
# Order (every nested code before the thing that contains it; each executable keeps the identifier
# the peer gate in muya-peer expects):
#   1 muya-ptyd  2 muyad  3 muyactl  4 muya-ssh-mcp (sidecar)  5 [Sparkle helpers: none yet]  6 MuyaNotifier.app  7 the app
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
APP=${1:-$HERE/../target-release/bundle/release/Muya.app}
ID=${MUYA_SIGN_IDENTITY:--}
log() { echo "sign: $*" >&2; }
[ -d "$APP" ] || { log "no bundle at $APP (run bundle.sh)"; exit 1; }

sign=(codesign --force --options runtime)
if [ "$ID" = "-" ]; then sign+=(-s -); log "AD-HOC signing (no Team ID: the peer gate accepts same-user peers only)"
else sign+=(--timestamp -s "$ID"); fi

M=$APP/Contents/MacOS
"${sign[@]}" --identifier com.staunch.muya.ptyd    --entitlements "$HERE/bundle/daemon.entitlements" "$M/muya-ptyd"
"${sign[@]}" --identifier com.staunch.muya.muyad   --entitlements "$HERE/bundle/daemon.entitlements" "$M/muyad"
"${sign[@]}" --identifier com.staunch.muya.muyactl --entitlements "$HERE/bundle/daemon.entitlements" "$M/muyactl"
"${sign[@]}" --identifier com.staunch.muya.mcp     --entitlements "$HERE/bundle/daemon.entitlements" "$M/muya-ssh-mcp"
# Sparkle (Faz 5): sign Sparkle.framework's XPC services / Autoupdate / Updater.app here, deepest first.
for nested in $(find "$APP/Contents/Frameworks" -name '*.xpc' -o -name 'Autoupdate' -o -name 'Updater.app' 2>/dev/null); do
  "${sign[@]}" "$nested"
done
# The notifier helper (Contents/Helpers): its own bundle id, no entitlements; the app signature seals it.
[ -d "$APP/Contents/Helpers/MuyaNotifier.app" ] && "${sign[@]}" --identifier com.staunch.muya.notifier "$APP/Contents/Helpers/MuyaNotifier.app"
APP_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")   # com.staunch.muya for Muya 5: the same designated requirement as classic
"${sign[@]}" --identifier "$APP_ID" --entitlements "$HERE/bundle/app.entitlements" "$M/MuyaNative"   # the real app: the bundle identifier, so the designated requirement is the same
"${sign[@]}" --identifier "$APP_ID" --entitlements "$HERE/bundle/app.entitlements" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2 >&2
for f in "$M"/*; do printf '%s %s\n' "$(basename "$f")" "$(codesign -dvv "$f" 2>&1 | sed -n 's/^Identifier=//p')"; done >&2
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "flags|Signature|TeamIdentifier" >&2 || true
log "spctl assessment (ad-hoc is expected to be rejected):"
spctl -a -vv "$APP" 2>&1 | sed 's/^/sign:   /' >&2 || true
