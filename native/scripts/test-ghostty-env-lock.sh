#!/usr/bin/env bash
# Starts 3 runs at once against an empty fake cache: all must succeed and the "build" must run once.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
log() { echo "[test] $*" >&2; }
cat > "$tmp/run.sh" <<'RUN'
set -euo pipefail
. "$1/mkdir-lock.sh"
log() { :; }
LOCK="$2/cache.lock"
acquire_lock
if [ ! -f "$2/cache/done" ]; then
  [ ! -d "$2/cache/partial" ] || { echo "saw a half-built cache" >&2; exit 1; }
  mkdir -p "$2/cache/partial"; sleep 2; echo built >> "$2/builds"; rm -rf "$2/cache/partial"; touch "$2/cache/done"
fi
RUN
mkdir -p "$tmp/cache"
pids=()
for i in 1 2 3; do bash "$tmp/run.sh" "$here" "$tmp" 2>"$tmp/err.$i" & pids+=($!); done
fail=0; for p in "${pids[@]}"; do wait "$p" || fail=1; done
[ "$fail" = 0 ] || { cat "$tmp"/err.*; echo "FAIL: a run failed"; exit 1; }
n=$(wc -l < "$tmp/builds" | tr -d ' ')
[ "$n" = 1 ] || { echo "FAIL: $n builds, expected 1"; exit 1; }
[ ! -e "$tmp/cache.lock" ] || { echo "FAIL: lock left behind"; exit 1; }
# a dead owner's lock is taken over
mkdir "$tmp/cache.lock"; echo 99999999 > "$tmp/cache.lock/pid"; rm -f "$tmp/cache/done" "$tmp/builds"
bash "$tmp/run.sh" "$here" "$tmp"
[ "$(wc -l < "$tmp/builds" | tr -d ' ')" = 1 ] || { echo "FAIL: stale lock not taken over"; exit 1; }
# the real script, 3 at once, on the existing cache
out=$(for i in 1 2 3; do "$here/ghostty-env.sh" 2>/dev/null & done; wait)
[ "$(echo "$out" | grep -c '^export PKG_CONFIG_PATH')" = 3 ] || { echo "FAIL: real script runs"; exit 1; }
# bisect/hook environment: GIT_DIR pointing at another repo must not make the script wipe the cache
repo=$(cd "$here/../.." && git rev-parse --absolute-git-dir)
out=$(GIT_DIR="$repo" GIT_WORK_TREE="$here/../.." GIT_INDEX_FILE="$repo/index" "$here/ghostty-env.sh" 2>"$tmp/gerr") || { cat "$tmp/gerr"; echo "FAIL: run under GIT_DIR"; exit 1; }
echo "$out" | grep -q '^export PKG_CONFIG_PATH' || { echo "FAIL: no env under GIT_DIR"; exit 1; }
! grep -q fetching "$tmp/gerr" || { echo "FAIL: re-fetched under GIT_DIR"; exit 1; }
echo "PASS: 3 concurrent runs, one build, stale lock recovered, real script x3 ok"
