#!/usr/bin/env bash
#
# publish-release.sh — unattended GitHub publish for Apex Mission Control
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
ZIP="$ROOT/ApexMissionControl-${VERSION}-${ARCH}.zip"

say "Publishing Apex Mission Control $TAG"

# --- guards -------------------------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || die "not on main (on '$BRANCH') — refusing to publish"

[ -f "$ZIP" ] || die "dist zip missing: $ZIP — run scripts/build-sign-notarize.sh first"

if git rev-parse "$TAG" >/dev/null 2>&1 || gh release view "$TAG" >/dev/null 2>&1; then
  die "$TAG already exists (tag or release) — bump version in tauri.conf.json first"
fi
ok "guards passed (on main, zip present, $TAG free)"

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

# --- 2. create release with notarized asset -----------------------------------
say "Creating GitHub release $TAG..."
gh release create "$TAG" \
  --target main \
  --title "$TAG" \
  --generate-notes \
  "$ZIP"
ok "release created"

# --- 3. verify ----------------------------------------------------------------
say "Verifying…"
gh release view "$TAG" --json tagName,isDraft,assets \
  --jq '"tag=\(.tagName) draft=\(.isDraft) assets=\([.assets[].name]|join(","))"'
URL="$(gh release view "$TAG" --json url --jq .url)"
printf '\033[1;32m\nDONE.\033[0m %s\n%s\n' "$TAG published" "$URL"
