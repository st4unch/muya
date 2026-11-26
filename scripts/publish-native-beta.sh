#!/usr/bin/env bash
#
# publish-native-beta.sh — publish a Muya Native beta as a GitHub PRERELEASE.
#
#   scripts/publish-native-beta.sh <Muya-Native.zip> <version> [min-classic-version]
#
# Publishes TWO prereleases, never "latest" (classic's releases/latest/latest.json stays untouched):
#   native-v<version>  immutable: the notarized zip
#   native-beta        rolling pointer: native-beta.json + native-beta.json.minisig, uploaded LAST
# Classic reads the pointer; Native polls the same pointer for updates.
# The zip must be Developer ID signed + notarized + stapled (checked here with spctl).
# Run only on the operator's go. Touches the remote.
set -euo pipefail
ZIP=${1:?path to the notarized Muya Native zip}; VER=${2:?version, e.g. 4.1.21}; MINC=${3:-$VER}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }
KEY="${MUYA_UPDATE_KEY:-$HOME/.tauri/muya-update.key}"
[ -f "$ZIP" ] || die "no zip at $ZIP"; [ -f "$KEY" ] || die "update signing key missing: $KEY"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ditto -x -k "$ZIP" "$W/x"; APP="$W/x/Muya Native.app"; [ -d "$APP" ] || die "zip has no 'Muya Native.app' at its root"
codesign --verify --deep --strict "$APP" || die "signature invalid"
# capture first: `cmd | grep -q` under pipefail fails with SIGPIPE (141) when grep exits early
SIGINFO="$(codesign -dvv "$APP" 2>&1 || true)"; GKINFO="$(spctl -a -t exec -vv "$APP" 2>&1 || true)"
[[ "$SIGINFO" == *"TeamIdentifier=7PG95YYJ64"* ]] || die "not signed by Team 7PG95YYJ64 (ad-hoc builds must never ship)"
[[ "$GKINFO" == *"Notarized Developer ID"* ]] || die "not notarized / stapled"
PLIST_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$PLIST_VER" = "$VER" ] || die "app says $PLIST_VER, you asked for $VER"

ASSET="Muya-Native-$VER.zip"; cp "$ZIP" "$W/$ASSET"
SHA="$(shasum -a 256 "$W/$ASSET" | awk '{print $1}')"; SIZE="$(stat -f%z "$W/$ASSET")"
cat > "$W/native-beta.json" <<JSON
{"schema":1,"channel":"beta","version":"$VER","pub_date":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","url":"https://github.com/st4unch/muya/releases/download/native-v$VER/$ASSET","size":$SIZE,"sha256":"$SHA","minClassicVersion":"$MINC","notes":"$(tr '\n' ' ' < docs/native-beta-release-notes.md | sed 's/"/\\"/g' | cut -c1-600)"}
JSON
TAURI_SIGNING_PRIVATE_KEY_PATH="$KEY" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}" npx tauri signer sign "$W/native-beta.json" >/dev/null 2>&1 || die "signing the manifest failed"
mv "$W/native-beta.json.sig" "$W/native-beta.json.minisig"

say "1/3 immutable release native-v$VER (prerelease, not latest)"
gh release view "native-v$VER" >/dev/null 2>&1 || gh release create "native-v$VER" --prerelease --latest=false --target main --title "Muya Native $VER (beta)" --notes-file docs/native-beta-release-notes.md
gh release upload "native-v$VER" "$W/$ASSET" --clobber
say "2/3 rolling pointer native-beta (prerelease, not latest)"
gh release view native-beta >/dev/null 2>&1 || gh release create native-beta --prerelease --latest=false --target main --title "Muya Native beta channel" --notes "Pointer to the current Muya Native beta. Do not download from here; use the app."
say "3/3 pointer assets last"
gh release upload native-beta "$W/native-beta.json" "$W/native-beta.json.minisig" --clobber
say "verify: classic's latest must still be a classic release"
gh release list -L 4
echo "latest: $(gh release list --json tagName,isLatest --jq '.[]|select(.isLatest).tagName')"
