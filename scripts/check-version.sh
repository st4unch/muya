#!/usr/bin/env bash
#
# check-version.sh — refuse a release whose version number is wrong.
#
# Checks, before anything is built or published:
#   1. src-tauri/tauri.conf.json, src-tauri/Cargo.toml and package.json carry the
#      same version.
#   2. That version is exactly one PATCH step above the newest published release
#      (4.1.1 → 4.1.2). A minor or major step only when the operator asked for it:
#      MUYA_VERSION_BUMP=minor (4.1.1 → 4.2.0) or MUYA_VERSION_BUMP=major (→ 5.0.0).
#   3. CHANGELOG.md has a "## [<version>]" section.
#
# Run by build-sign-notarize.sh, publish-release.sh, the project hook
# (.claude/hooks/release-version-guard.sh) and the release-version-check agent.
# Exit 0 = OK, 1 = wrong (the reason goes to stderr).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { printf '\033[1;31m  ✗ version check: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }

conf="$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' src-tauri/tauri.conf.json | head -1)"
cargo="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' src-tauri/Cargo.toml | head -1)"
pkg="$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' package.json | head -1)"
[ -n "$conf" ] || fail "could not read the version from src-tauri/tauri.conf.json"
[ "$conf" = "$cargo" ] && [ "$conf" = "$pkg" ] ||
  fail "versions differ: tauri.conf.json=$conf Cargo.toml=$cargo package.json=$pkg"

# Newest published version: GitHub releases, else local tags.
last=""
if command -v gh >/dev/null 2>&1; then
  last="$(gh release list --limit 100 --json tagName,isDraft \
            --jq '.[] | select(.isDraft|not) | .tagName' 2>/dev/null |
          sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)"
fi
if [ -z "$last" ]; then
  last="$(git tag -l 'v*' | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' |
          sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)"
fi
[ -n "$last" ] || fail "no earlier release found to compare against"

IFS=. read -r ma mi pa <<<"$last"
case "${MUYA_VERSION_BUMP:-patch}" in
  patch) want="$ma.$mi.$((pa + 1))" ;;
  minor) want="$ma.$((mi + 1)).0" ;;
  major) want="$((ma + 1)).0.0" ;;
  *) fail "MUYA_VERSION_BUMP must be patch, minor or major (got '${MUYA_VERSION_BUMP}')" ;;
esac

if [ "$conf" = "$last" ]; then
  # Re-running the publish step of a build that is already out is caught by
  # publish-release.sh's tag check; here it is simply not a new version.
  fail "$conf is already released — bump to $want"
fi
[ "$conf" = "$want" ] ||
  fail "version is $conf but the last release is $last, so this release must be $want (${MUYA_VERSION_BUMP:-patch} step).
    A minor/major step only when the operator asked: MUYA_VERSION_BUMP=minor|major."

grep -q "^## \[$conf\]" CHANGELOG.md || fail "CHANGELOG.md has no '## [$conf]' section"

ok "version $conf (last release $last, ${MUYA_VERSION_BUMP:-patch} step) — files agree, changelog present"
