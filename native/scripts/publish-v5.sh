#!/usr/bin/env bash
#
# publish-v5.sh - PUBLISH Muya 5.0.0 (REMOTE / SHARED STATE). Run only by the operator's release owner, only after
# native/scripts/release-v5.sh succeeded and the pre-publish checklist in docs/prd-muya-v5-replace.progress.md is done.
#
#   MUYA_PUBLISH_CONFIRM=yes MUYA_VERSION_BUMP=major native/scripts/publish-v5.sh
#
# Order matters:
#   1. The immutable release v<ver> becomes Latest with the zip, the updater tarball and latest.json. From this moment classic
#      4.1.22 apps are offered Muya 5 by their normal updater, and Muya 5 apps read the same latest.json.
#   2. The bridge build (4.1.27, "Muya Native.app", id com.staunch.muya.native) goes to the native-beta POINTER with
#      scripts/publish-native-beta.sh: published Native betas can only accept an app with that id, and from there the bridge
#      moves itself to Muya 5 using latest.json.
#   3. (later, after the beta users have moved) pull the offer: gh release delete native-beta --yes
# Nothing here force-pushes or deletes. The git push of the release commit is NOT done here: do it through the usual
# project-manager review.
set -euo pipefail
[ "${MUYA_PUBLISH_CONFIRM:-}" = "yes" ] || { echo "refusing: set MUYA_PUBLISH_CONFIRM=yes (this writes to GitHub)" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
NATIVE=$(cd "$HERE/.." && pwd)
REPO=$(cd "$NATIVE/.." && pwd)
OUT=$NATIVE/target-release/v5-release
VERSION=${MUYA_PRODUCT_VERSION:-$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$REPO/src-tauri/tauri.conf.json" | head -1)}
BRIDGE=${MUYA_BRIDGE_VERSION:-4.1.27}
ARCH=$(uname -m); TAG=v$VERSION
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m  x %s\033[0m\n' "$*" >&2; exit 1; }
for f in "Muya-$VERSION-$ARCH.zip" "Muya-$VERSION-$ARCH.app.tar.gz" "Muya-$VERSION-$ARCH.app.tar.gz.sig" latest.json; do [ -f "$OUT/$f" ] || die "missing $OUT/$f (run release-v5.sh)"; done
grep -q "\"version\": \"$VERSION\"" "$OUT/latest.json" || die "latest.json is not for $VERSION"
( cd "$REPO" && bash scripts/check-version.sh ) || die "version guard"
gh release view "$TAG" >/dev/null 2>&1 && die "$TAG already exists"

NOTES=$(mktemp)
awk -v ver="## [$VERSION]" 'index($0, ver) == 1 { inside = 1; next } inside && /^## \[/ { exit } inside { print }' "$REPO/CHANGELOG.md" > "$NOTES"
[ -s "$NOTES" ] || die "no CHANGELOG section for $VERSION"

say "1/2 release $TAG (Latest)"
gh release create "$TAG" --latest --title "Muya $VERSION" --notes-file "$NOTES" --target "$(git -C "$REPO" rev-parse HEAD)"
gh release upload "$TAG" "$OUT/Muya-$VERSION-$ARCH.zip" "$OUT/Muya-$VERSION-$ARCH.app.tar.gz" --clobber
gh release upload "$TAG" "$OUT/latest.json" --clobber       # last: the feed only points at files that are already there
curl -fsSL "https://github.com/st4unch/muya/releases/latest/download/latest.json" | grep -q "\"version\": \"$VERSION\"" || die "the live feed does not say $VERSION"

if [ -f "$OUT/Muya-Native-$BRIDGE.zip" ]; then
  say "2/2 bridge $BRIDGE on the native-beta pointer"
  bash "$REPO/scripts/publish-native-beta.sh" "$OUT/Muya-Native-$BRIDGE.zip" "$BRIDGE" 4.1.21
fi
gh release list -L 5
