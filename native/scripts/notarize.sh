#!/usr/bin/env bash
# Notarize + staple a signed Muya Native .app, then assess it with Gatekeeper.
#   native/scripts/notarize.sh <path-to-.app> [out.zip]
# Auth, same order as the classic scripts/build-sign-notarize.sh:
#   1 keychain profile (MUYA_NOTARY_PROFILE, default apex-notary)
#   2 App Store Connect API key: NOTARY_KEY (.p8 path), NOTARY_KEY_ID, NOTARY_ISSUER from the environment or from
#     the local env file (MUYA_NOTARY_ENV, default ~/.config/muya-release/notary.env). The file is sourced, never printed.
#   3 clear error.
# Output: the stapled app in place, a distribution zip next to it (ditto, never zip), spctl + stapler validate.
set -euo pipefail

APP="${1:-}"
[ -d "$APP" ] || { echo "usage: $0 <path-to-.app> [out.zip]" >&2; exit 2; }
APP="$(cd "$APP" && pwd)"
ZIP="${2:-$(dirname "$APP")/$(basename "$APP" .app | tr ' ' '-').zip}"
SUBMIT="$(mktemp -d)/submit.zip"

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PROFILE="${MUYA_NOTARY_PROFILE:-apex-notary}"
NOTARY_KEY="${NOTARY_KEY:-}"; NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"; NOTARY_ISSUER="${NOTARY_ISSUER:-}"
NOTARY_ENV="${MUYA_NOTARY_ENV:-$HOME/.config/muya-release/notary.env}"
if [ -z "$NOTARY_KEY" ] && [ -f "$NOTARY_ENV" ]; then
  # shellcheck disable=SC1090
  . "$NOTARY_ENV"
fi
ARGS=()
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  ARGS=(--keychain-profile "$PROFILE"); say "notary auth: keychain profile '$PROFILE'"
elif [ -n "$NOTARY_KEY" ] && [ -f "$NOTARY_KEY" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ]; then
  ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"); say "notary auth: API key (profile unavailable)"
else
  die "no notary auth: store profile '$PROFILE', or set NOTARY_KEY (.p8 path), NOTARY_KEY_ID and NOTARY_ISSUER (env or $NOTARY_ENV)"
fi

codesign --verify --deep --strict "$APP" || die "app is not validly signed"
say "zipping for submission"
ditto -c -k --keepParent "$APP" "$SUBMIT"

say "submitting (waits for the result)"
OUT="$(xcrun notarytool submit "$SUBMIT" "${ARGS[@]}" --wait 2>&1)" || true
echo "$OUT"
if ! echo "$OUT" | grep -q "status: Accepted"; then
  ID="$(echo "$OUT" | sed -n 's/^ *id: //p' | head -1)"
  [ -n "$ID" ] && xcrun notarytool log "$ID" "${ARGS[@]}" 2>&1 || true
  die "notarization NOT accepted"
fi

say "stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
say "Gatekeeper"
spctl -a -vv -t exec "$APP"
say "distribution zip"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"; echo "$ZIP"
rm -rf "$(dirname "$SUBMIT")"
