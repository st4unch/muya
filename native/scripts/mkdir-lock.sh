#!/usr/bin/env bash
# Exclusive mkdir-lock shared by ghostty-env.sh and its test. Source it, set LOCK, call acquire_lock.
# Needs a `log` function. The lock is released by an EXIT trap.
acquire_lock() {
  local waited=0 owner
  until mkdir "$LOCK" 2>/dev/null; do
    owner=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      log "taking over the lock of dead run $owner"
      # rename first so only one waiter wins the takeover
      mv "$LOCK" "$LOCK.dead.$$" 2>/dev/null && rm -rf "$LOCK.dead.$$"
      continue
    fi
    if [ "$waited" -eq 0 ]; then log "another run holds the lock (pid ${owner:-?}), waiting"; fi
    waited=$((waited + 1)); sleep 1
    # a lock without a pid file for 30 s is a crash between mkdir and write: take it over
    if [ -z "$owner" ] && [ "$waited" -gt 30 ]; then rm -rf "$LOCK"; waited=0; fi
  done
  echo $$ > "$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
}
