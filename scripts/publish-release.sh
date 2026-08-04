#!/usr/bin/env bash
#
# publish-release.sh — unattended GitHub publish for Muya
#
#   git push origin main (fast-forward ONLY) -> gh release create v<version>
#   with the notarized distribution zip attached.
#
# No arguments. Version read from src-tauri/tauri.conf.json.
#
# REMOTE / SHARED STATE: this writes to GitHub. Fail-safe guards:
#   - aborts if not on main
#   - aborts if the dist zip is missing (run build-sign-notarize.sh first)
#   - aborts if tag v<version> already exists (no clobber)
#   - push is fast-forward only; NEVER force-pushes
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# --- preflight ----------------------------------------------------------------
command -v node >/dev/null || die "node not found"
command -v gh   >/dev/null || die "gh (GitHub CLI) not found"
command -v git  >/dev/null || die "git not found"
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"

VERSION="$(node -p "require('$ROOT/src-tauri/tauri.conf.json').version")"
[ -n "$VERSION" ] || die "could not read version from tauri.conf.json"
ARCH="$(uname -m)"
TAG="v${VERSION}"
ZIP="$ROOT/Muya-${VERSION}-${ARCH}.zip"
# macOS's Tauri updater ALWAYS extracts the downloaded artifact with GzDecoder +
# tar (tauri-plugin-updater src/updater.rs: macOS path). A .zip therefore fails
# with "invalid gzip header" — the updater needs a .app.tar.gz.
APP="$ROOT/src-tauri/target/release/bundle/macos/Muya.app"
TARGZ="$ROOT/Muya-${VERSION}-${ARCH}.app.tar.gz"

say "Publishing Muya $TAG"

# --- guards -------------------------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || die "not on main (on '$BRANCH') — refusing to publish"

[ -f "$ZIP" ] || die "dist zip missing: $ZIP — run scripts/build-sign-notarize.sh first"

# Refuse to re-release a version that is ALREADY fully published (release exists
# WITH assets). But allow finishing a PARTIAL publish — a release/tag left behind by
# an interrupted upload — so a re-run can complete it idempotently (step 3 below
# detects the existing release and re-uploads with --clobber).
if gh release view "$TAG" >/dev/null 2>&1; then
  EXISTING_ASSETS="$(gh release view "$TAG" --json assets --jq '.assets | length' 2>/dev/null || echo 0)"
  if [ "${EXISTING_ASSETS:-0}" -gt 0 ]; then
    die "$TAG already fully published ($EXISTING_ASSETS asset(s)) — bump version in tauri.conf.json first"
  fi
  ok "$TAG exists but has no assets — resuming a partial publish"
elif git rev-parse "$TAG" >/dev/null 2>&1; then
  die "tag $TAG exists without a release — resolve manually (git tag -d $TAG to redo)"
fi
# A release without a changelog entry gives the operator no way to see what
# changed — refuse to publish one (operator standing rule).
CHANGELOG="$ROOT/CHANGELOG.md"
[ -f "$CHANGELOG" ] || die "CHANGELOG.md missing — add it before releasing"
grep -qE "^## \\[${VERSION}\\]" "$CHANGELOG" \
  || die "CHANGELOG.md has no '## [${VERSION}]' section — write the entry before releasing"
ok "guards passed (on main, zip present, $TAG free, changelog entry present)"

# --- 1. fast-forward push -----------------------------------------------------
git fetch origin main --quiet
LOCAL="$(git rev-parse main)"
REMOTE="$(git rev-parse origin/main)"
BASE="$(git merge-base main origin/main)"
if [ "$LOCAL" = "$REMOTE" ]; then
  ok "main already in sync with origin"
elif [ "$REMOTE" = "$BASE" ]; then
  say "Pushing main (fast-forward)…"
  git push origin main
  ok "pushed: $(git rev-parse --short "$REMOTE")..$(git rev-parse --short "$LOCAL")"
else
  die "main has DIVERGED from origin/main — resolve manually (will NOT force-push)"
fi

# --- 2. sign zip for auto-updater ---------------------------------------------
SIGN_KEY="$HOME/.tauri/muya-update.key"
if [ -f "$SIGN_KEY" ]; then
  [ -d "$APP" ] || die "stapled app missing: $APP — run scripts/build-sign-notarize.sh first"
  say "Building updater archive (.app.tar.gz)…"
  # -C so the archive root is exactly "Muya.app", which is what the updater
  # expects to unpack in place of the running bundle.
  # COPYFILE_DISABLE stops macOS tar from emitting AppleDouble "._" sidecars.
  # They matter because the updater strips each entry's FIRST path component
  # (updater.rs: `entry.path()?.iter().skip(1)`), so a top-level file like
  # "._Muya.app" collapses to an empty path and unpacking it over the temp dir
  # fails with: failed to unpack `._Muya.app`.
  COPYFILE_DISABLE=1 tar -czf "$TARGZ" -C "$(dirname "$APP")" "$(basename "$APP")"

  # Guard: every entry must live under the single top-level bundle dir, or the
  # updater's skip(1) will produce an empty destination path.
  # NOTE: macOS `tar -tzf` HIDES the AppleDouble entries it wrote itself, so it
  # cannot be used to audit this — read the archive with a foreign reader
  # (python tarfile), the same way the updater's Rust tar crate sees it.
  BAD="$(python3 - "$TARGZ" "$(basename "$APP")" <<'PYEOF'
import sys, tarfile, pathlib
archive, root = sys.argv[1], sys.argv[2]
bad = []
for m in tarfile.open(archive).getmembers():
    parts = pathlib.PurePath(m.name).parts
    if not parts or parts[0] != root or any(p.startswith("._") for p in parts):
        bad.append(m.name)
print("\n".join(bad))
PYEOF
)"
  if [ -n "$BAD" ]; then
    die "updater archive has stray/AppleDouble entries (updater would fail to unpack):
$BAD"
  fi
  ok "updater archive: $(basename "$TARGZ") ($(du -h "$TARGZ" | cut -f1)), single-root verified"

  say "Signing updater archive…"
  TAURI_SIGNING_PRIVATE_KEY_PATH="$SIGN_KEY" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" \
    npx tauri signer sign "$TARGZ" >/dev/null 2>&1
  SIG="$(cat "${TARGZ}.sig")"
  PUB_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  LATEST="$ROOT/latest.json"
  cat > "$LATEST" <<EOJSON
{
  "version": "$VERSION",
  "notes": "Release $TAG",
  "pub_date": "$PUB_DATE",
  "platforms": {
    "darwin-aarch64": {
      "signature": "$SIG",
      "url": "https://github.com/st4unch/muya/releases/download/$TAG/$(basename "$TARGZ")"
    }
  }
}
EOJSON
  ok "latest.json + signature generated"
else
  say "⚠️  No signing key at $SIGN_KEY — skipping auto-updater manifest"
  LATEST=""
fi

# --- 3. create release with notarized asset -----------------------------------
say "Creating GitHub release $TAG..."
# `ls *.dmg` exits non-zero when no DMG was built (the normal case — we ship .app +
# zip, not DMG). Under `set -euo pipefail` that non-zero propagates through the pipe
# and ABORTS the whole script right here, after "Creating GitHub release…" printed —
# which is exactly why every release's `gh release create` step silently died and had
# to be finished by hand. `|| true` swallows the empty-glob failure.
DMG="$(ls "$ROOT"/src-tauri/target/release/bundle/dmg/*.dmg 2>/dev/null | head -1 || true)"
ASSETS=("$ZIP")
# The .app.tar.gz is what the auto-updater downloads (latest.json points at it);
# the .zip stays for manual download.
[ -f "$TARGZ" ] && ASSETS+=("$TARGZ")
[ -n "$LATEST" ] && [ -f "$LATEST" ] && ASSETS+=("$LATEST")
if [ -n "$DMG" ] && [ -f "$DMG" ]; then
  if spctl --assess --type install "$DMG" >/dev/null 2>&1; then
    ASSETS+=("$DMG")
    ok "will attach DMG (notarized): $(basename "$DMG")"
  else
    ok "DMG found but not notarized by Gatekeeper — skipping: $(basename "$DMG")"
  fi
fi
# Release notes come from this version's CHANGELOG section, so GitHub and the
# repo never tell different stories.
NOTES_FILE="$(mktemp)"
awk -v ver="## [$VERSION]" '
  index($0, ver) == 1 { inside = 1; next }
  inside && /^## \[/ { exit }
  inside { print }
' "$CHANGELOG" > "$NOTES_FILE"
[ -s "$NOTES_FILE" ] || die "could not extract CHANGELOG section for $VERSION"

# Create the release WITHOUT assets first, then upload assets separately. Uploading
# 20+ MB inline with `gh release create` was flaky and repeatedly left the release
# uncreated (the process stalled mid-upload with neither success nor error). A bare
# `create` is instant and atomic; splitting off the upload makes each step retryable
# and idempotent, so a re-run finishes a partial publish instead of dying.
retry() { # retry <label> <cmd...>
  local label="$1"; shift
  local n=1
  until "$@"; do
    [ "$n" -ge 3 ] && return 1
    say "$label failed (attempt $n/3) — retrying in 3s…"; sleep 3; n=$((n+1))
  done
}

if gh release view "$TAG" >/dev/null 2>&1; then
  ok "release $TAG already exists — will (re)upload assets (--clobber)"
else
  retry "gh release create" \
    gh release create "$TAG" --target main --title "$TAG" --notes-file "$NOTES_FILE" \
    || { rm -f "$NOTES_FILE"; die "gh release create failed after 3 attempts"; }
  ok "release created (no assets yet)"
fi
rm -f "$NOTES_FILE"

say "Uploading ${#ASSETS[@]} asset(s)…"
# --clobber overwrites same-named assets, so re-running is safe and idempotent.
retry "asset upload" gh release upload "$TAG" "${ASSETS[@]}" --clobber \
  || die "asset upload failed after 3 attempts — re-run this script to finish (release exists, upload will resume)"
ok "assets uploaded"

# --- 4. verify ----------------------------------------------------------------
say "Verifying…"
gh release view "$TAG" --json tagName,isDraft,assets \
  --jq '"tag=\(.tagName) draft=\(.isDraft) assets=\([.assets[].name]|join(","))"'
URL="$(gh release view "$TAG" --json url --jq .url)"
printf '\033[1;32m\nDONE.\033[0m %s\n%s\n' "$TAG published" "$URL"
