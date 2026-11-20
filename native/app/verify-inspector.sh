#!/usr/bin/env bash
# Faz 4b check: the Inspector (Changes / Files / Activity) in the real app, against a dev stack with a
# throwaway HOME holding a SYNTHETIC 2,000-file git repo (merge conflict in progress, a linked worktree, edits,
# an untracked and a staged file) and a synthetic transcript. Screenshots dark + light, measures CPU/RSS of the
# app with the pane open on the big repo. Always stops the stack it started.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-insp.XXXXXX)  # its own dir per run: a fixed one collides with another dev stack / a leftover
SHOTS=$PWD/screenshots
STATE=$TMPDIR/muya-native-dev.state
if [ -f "$STATE" ]; then ./run-dev.sh stop >/dev/null 2>&1 || true; fi
MUYA_DEV_NO_APP=1 ./run-dev.sh start >/dev/null || exit 1
. "$STATE"
trap './run-dev.sh stop >/dev/null 2>&1' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
REPO=$(python3 -I make-inspector-fixtures.py "$DEV/home" 2000)
FAILS=0
dbg() { printf '%s\n' "$1" | nc -U -w 5 "$DEV/app-debug.sock"; }
shot() { screencapture -x -o -l "$1" "$SHOTS/$2.png"; echo "shot $2"; }

for TAB in changes diff files activity; do
  [ -f "$STATE" ] && . "$STATE"
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null; sleep 0.5
  MUYA_INSPECTOR_TAB=${TAB/diff/changes} MUYA_INSPECTOR_FILE=$([ $TAB = diff ] && echo src/parser.swift) ./run-dev.sh app >/dev/null; . "$STATE"; sleep 2.5
  dbg "sessions" | while IFS=$'\t' read -r id _; do [ -n "$id" ] && dbg "close $id" >/dev/null; done
  dbg "new $REPO" >/dev/null
  sleep $([ $TAB = diff ] && echo 7 || echo 3)
  W=$(dbg windowid)
  dbg "appearance dark" >/dev/null; sleep 1; shot "$W" "inspector-$TAB-dark"
  dbg "appearance light" >/dev/null; sleep 1; shot "$W" "inspector-$TAB-light"
  if [ "$TAB" = changes ]; then
    # CPU / RSS: pane open on the 2,000-file repo, 20 s idle window (it polls every 5 s).
    ps -o rss= -p "$APP_PID" | awk '{printf "rss_mb=%.1f\n", $1/1024}'
    t0=$(ps -o time= -p "$APP_PID"); sleep 20; t1=$(ps -o time= -p "$APP_PID")
    python3 - "$t0" "$t1" <<'P'
import sys
def sec(t):
    m, s = t.strip().split(":"); return int(m) * 60 + float(s)
print("cpu_pct_over_20s=%.2f" % ((sec(sys.argv[2]) - sec(sys.argv[1])) / 20 * 100))
P
  fi
done
echo "done (look at screenshots/inspector-*)"
