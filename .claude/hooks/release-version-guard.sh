#!/usr/bin/env bash
# PreToolUse(Bash) hook: before a Muya release is built or published, check the
# version number (scripts/check-version.sh). A wrong number blocks the command
# (exit 2) and tells Claude why. Added after 4.2.0/4.2.1 shipped instead of 4.1.2.
set -uo pipefail
cmd="$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)"
# Only when a release step actually runs — not when a script merely mentions one.
start='(^|[;&|(])[[:space:]]*(env[[:space:]]+)?([A-Z_]+=[^[:space:]]*[[:space:]]+)*'
printf '%s' "$cmd" | grep -Eq \
  "${start}((bash|sh)[[:space:]]+[^[:space:]]*|\./)scripts/(build-sign-notarize|publish-release)\.sh|${start}gh[[:space:]]+release[[:space:]]+create" ||
  exit 0
root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
block() {
  printf 'Release blocked by the version check.\n%s\nSet the version in tauri.conf.json, Cargo.toml and package.json (a patch step unless the operator asked for minor/major), then retry.\n' "$1" >&2
  exit 2
}
# An operator-approved minor/major step is passed on the same command line.
bump="$(printf '%s' "$cmd" | grep -Eo '(^|[[:space:]])MUYA_VERSION_BUMP=(patch|minor|major)' | head -1 | sed 's/.*=//')"
out="$(MUYA_VERSION_BUMP="${bump:-patch}" bash "$root/scripts/check-version.sh" 2>&1)" || block "$out"
# A hand-typed `gh release create vX` must name the version the files carry.
tag="$(printf '%s' "$cmd" | grep -Eo 'gh[[:space:]]+release[[:space:]]+create[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+$')"
want="$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' "$root/src-tauri/tauri.conf.json" | head -1)"
[ -z "$tag" ] || [ "$tag" = "$want" ] || block "gh release create v$tag, but the app version is $want."
exit 0
