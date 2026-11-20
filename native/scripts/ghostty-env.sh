#!/usr/bin/env bash
# Builds libghostty-vt once per pinned Ghostty commit, offline and in fixed, user-independent
# paths, then prints the env cargo needs to link it (libghostty-vt-sys "pkg-config" feature).
# Fixed paths make the library byte-identical across checkouts, cargo target dirs and
# machines, and keep home directories out of the binary.
#
#   eval "$(native/scripts/ghostty-env.sh)" && cargo build --release
#   native/scripts/ghostty-env.sh --verify   # rebuild from scratch twice, compare bytes
set -euo pipefail
# git bisect / hooks export these; they would make `git -C $ROOT/src` read the calling repo instead of the cache.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_NAMESPACE

# Must match GHOSTTY_COMMIT in libghostty-vt-sys 0.2.2 build.rs (checked below).
GHOSTTY_COMMIT=a887df42c56f6de86c0fe6da9c4eeca37931e083
ZIG_VERSION=0.15.2
ROOT=/Users/Shared/muya-build/ghostty-$GHOSTTY_COMMIT
# Same flags libghostty-vt-sys passes for a release build (build.rs `build_vendored`).
ZIG_FLAGS=(-Demit-lib-vt=true -Doptimize=ReleaseFast -Dcpu=baseline -Demit-xcframework=false -Dapp-runtime=none)

log() { echo "ghostty-env: $*" >&2; }

if command -v brew >/dev/null && [ -x "$(brew --prefix zig@0.15 2>/dev/null)/bin/zig" ]; then
  export PATH="$(brew --prefix zig@0.15)/bin:$PATH"
fi
have=$(zig version 2>/dev/null || true)
[ "$have" = "$ZIG_VERSION" ] || { log "need zig $ZIG_VERSION, found '${have:-none}' (brew install zig@0.15)"; exit 1; }
command -v pkg-config >/dev/null || { log "need pkg-config (brew install pkgconf)"; exit 1; }

sys_build_rs=$(ls "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/libghostty-vt-sys-0.2.2/build.rs 2>/dev/null | head -1 || true)
if [ -n "$sys_build_rs" ] && ! grep -q "$GHOSTTY_COMMIT" "$sys_build_rs"; then
  log "libghostty-vt-sys pins a different Ghostty commit than this script"; exit 1
fi

# Concurrent runs (several cargo/build.sh at once) must never fetch or build into the same
# directory at the same time: one run takes an exclusive mkdir-lock, the others wait and then
# re-check, finding the finished build. A lock whose owner died is taken over.
mkdir -p "$ROOT"
LOCK="$ROOT.lock"
. "$(dirname "${BASH_SOURCE[0]}")/mkdir-lock.sh"
acquire_lock
src_head=$(git -C "$ROOT/src" rev-parse HEAD 2>/dev/null || true)
if [ "$src_head" != "$GHOSTTY_COMMIT" ]; then
  # A finished build must never be wiped because its source checkout could not be read.
  if [ -z "$src_head" ] && [ -f "$ROOT/install/SHA256SUMS" ] && [ -d "$ROOT/src" ]; then
    log "cannot read the HEAD of $ROOT/src but a finished build exists; not deleting it (check git / the environment)"; exit 1
  fi
  log "fetching Ghostty $GHOSTTY_COMMIT"
  rm -rf "$ROOT/src" "$ROOT/zig-pkg" "$ROOT/install"
  git clone --quiet --filter=blob:none --no-checkout https://github.com/ghostty-org/ghostty.git "$ROOT/src"
  git -C "$ROOT/src" -c advice.detachedHead=false checkout --quiet "$GHOSTTY_COMMIT"
fi
[ -z "$(git -C "$ROOT/src" status --porcelain)" ] || { log "$ROOT/src has local changes"; exit 1; }

if [ ! -f "$ROOT/zig-pkg/.complete" ]; then
  # `zig build --fetch` skips lazy and transitive packages (ziglang/zig#20976); Ghostty's
  # packaging script fetches every URL in build.zig.zon.txt. build.zig.zon pins each
  # package's content hash, so a tampered download is rejected at build time.
  log "fetching Zig packages"
  rm -rf "$ROOT/zig-pkg"
  ZIG_GLOBAL_CACHE_DIR="$ROOT/zig-pkg" sh "$ROOT/src/nix/build-support/fetch-zig-cache.sh" >/dev/null
  touch "$ROOT/zig-pkg/.complete"
fi

build() {
  rm -rf "$ROOT/install" "$ROOT/zig-cache" "$ROOT/zig-global"
  log "building libghostty-vt ($ZIG_VERSION, ${ZIG_FLAGS[*]})"
  (cd "$ROOT/src" && zig build "${ZIG_FLAGS[@]}" --prefix "$ROOT/install" \
    --cache-dir "$ROOT/zig-cache" --global-cache-dir "$ROOT/zig-global" \
    --system "$ROOT/zig-pkg/p" >&2)
  # zig build writes into the source tree only through the cache dirs; fail loudly if not.
  [ -z "$(git -C "$ROOT/src" status --porcelain)" ] || { log "build modified $ROOT/src"; exit 1; }
  # Zig names per-compilation cache dirs non-deterministically and records them in DWARF,
  # and Ghostty merges the archive with libtool (real mtime, uid). The linked library is
  # therefore repacked deterministically (-D) and stripped of debug info (-S; function
  # symbols stay, so crash reports still name functions). The full-DWARF archive stays in
  # lib-debug/ for local debugging only; it is not reproducible and never shipped.
  mkdir -p "$ROOT/install/lib-debug"
  mv "$ROOT/install/lib/libghostty-vt.a" "$ROOT/install/lib-debug/"
  rm -f "$ROOT/install/lib/"libghostty-vt*.dylib
  # strip rewrites the archive with the current time, so the -D repack must come last.
  local tmp="$ROOT/install/stripped.a"
  cp "$ROOT/install/lib-debug/libghostty-vt.a" "$tmp" && strip -S "$tmp"
  libtool -static -D -o "$ROOT/install/lib/libghostty-vt.a" "$tmp" 2>&1 | grep -v 'has no symbols' >&2 || true
  rm -f "$tmp"
  (cd "$ROOT/install/lib" && shasum -a 256 libghostty-vt.a) > "$ROOT/install/SHA256SUMS"
}

if [ "${1:-}" = "--verify" ]; then
  build; first=$(cat "$ROOT/install/SHA256SUMS")
  build; second=$(cat "$ROOT/install/SHA256SUMS")
  echo "$second"
  [ "$first" = "$second" ] && { log "reproducible: two clean builds are byte-identical"; exit 0; }
  log "NOT reproducible:"; diff <(echo "$first") <(echo "$second") >&2; exit 1
fi

[ -f "$ROOT/install/SHA256SUMS" ] || build
(cd "$ROOT/install/lib" && shasum -a 256 -c --quiet ../SHA256SUMS) || { log "installed library changed since it was built"; exit 1; }

echo "export PKG_CONFIG_PATH=\"$ROOT/install/share/pkgconfig\""
echo "unset GHOSTTY_SOURCE_DIR GHOSTTY_ZIG_SYSTEM_DIR"
