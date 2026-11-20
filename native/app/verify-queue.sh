#!/usr/bin/env bash
# Queue / Branches / Kanban check in the real app, against a dev stack with a throwaway HOME holding a
# SYNTHETIC 5,000-commit repo (branches in every queue state, a local bare "origin", a linked worktree, PRD
# progress files). Checks the destructive buttons only LOG, scrolls the graph with frame timing, drags cards,
# screenshots dark + light, records CPU/RSS. Always stops the stack it started.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-queue.XXXXXX)  # its own dir per run: a fixed one collides with another dev stack / a leftover
SHOTS=$PWD/screenshots
STATE=$TMPDIR/muya-native-dev.state
if [ -f "$STATE" ]; then ./run-dev.sh stop >/dev/null 2>&1 || true; fi
MUYA_DEV_NO_APP=1 ./run-dev.sh start >/dev/null || exit 1
. "$STATE"
trap './run-dev.sh stop >/dev/null 2>&1' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
REPO=$(python3 -I make-queue-fixtures.py "$DEV/home" 5000)
ORIGIN="$DEV/home/qorigin.git"
FAILS=0
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock"; }
shot() { screencapture -x -o -l "$1" "$SHOTS/$2.png"; echo "shot $2"; }
ok() { if [ "$1" = 0 ]; then echo "PASS $2"; else echo "FAIL $2"; FAILS=$((FAILS+1)); fi; }
has() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }
waitload() { for _ in $(seq 1 60); do s=$(dbg queue-state); has "$s" "loading=false" && has "$s" "root=git" && return 0; sleep 0.5; done; return 1; }

./run-dev.sh app >/dev/null; . "$STATE"; sleep 2.5
dbg "sessions" | while IFS=$'\t' read -r id _; do [ -n "$id" ] && dbg "close $id" >/dev/null; done
dbg "new $REPO" >/dev/null; sleep 2
dbg "queue-cwd $REPO" >/dev/null
W=$(dbg windowid)
BEFORE_ORIGIN=$(git -C "$ORIGIN" for-each-ref | md5)
BEFORE_REPO=$(git -C "$REPO" for-each-ref | md5)

# --- Queue
dbg "queue-page queue" >/dev/null; waitload; ok $? "queue loads"
S=$(dbg queue-state); echo "$S" | sed -n 1,12p
has "$S" "ready-topic	Ready to merge"; ok $? "ready-topic is Ready to merge"
has "$S" "unpushed-topic	Push needed"; ok $? "unpushed-topic is Push needed"
has "$S" "stale-topic	Needs rebase"; ok $? "stale-topic needs rebase"
has "$S" "merged-topic	Merged"; ok $? "merged-topic is Merged"
dbg "appearance dark" >/dev/null; sleep 1; shot "$W" queue-dark
dbg "appearance light" >/dev/null; sleep 1; shot "$W" queue-light
dbg "queue-select unpushed-topic" >/dev/null; dbg "queue-push" >/dev/null; sleep 1
R=$(dbg queue-sheet); has "$R" "origin unpushed-topic"; ok $? "push shows a confirmation sheet with the command"
dbg "appearance dark" >/dev/null; sleep 0.5; shot "$W" queue-sheet-dark
dbg "queue-sheet-cancel" >/dev/null; sleep 0.5
[ "$(dbg queue-log)" = "" ]; ok $? "cancel logs nothing"
dbg "queue-push" >/dev/null; sleep 1; dbg "queue-sheet-confirm" >/dev/null; sleep 0.5
has "$(dbg queue-log)" "would run: git"; ok $? "confirm logs the push command"
dbg "queue-autoconfirm on" >/dev/null
dbg "queue-select ready-topic" >/dev/null; dbg "queue-merge" >/dev/null
dbg "queue-select merged-topic" >/dev/null; dbg "queue-delete" >/dev/null
has "$(dbg queue-log)" "git branch -d merged-topic"; ok $? "delete logs the safe -d command"
[ "$(git -C "$ORIGIN" for-each-ref | md5)" = "$BEFORE_ORIGIN" ]; ok $? "origin untouched (nothing pushed)"
[ "$(git -C "$REPO" for-each-ref | md5)" = "$BEFORE_REPO" ]; ok $? "repo refs untouched (nothing merged or deleted)"

# --- Branches
dbg "appearance dark" >/dev/null
dbg "queue-page branches" >/dev/null; sleep 1
S=$(dbg queue-state); has "$S" "branches: 5"; ok $? "5,000+ commits in the graph ($(echo "$S" | grep '^branches'))"
dbg "dag-select 40" >/dev/null; sleep 0.5; shot "$W" branches-dark
dbg "appearance light" >/dev/null; sleep 1; shot "$W" branches-light
dbg "dag-select 0" >/dev/null
[ "$(dbg 'dag-key down')" = "selected=1" ]; ok $? "keyboard: down selects the next commit"
[ "$(dbg 'dag-key end')" != "selected=1" ]; ok $? "keyboard: end jumps to the last commit"
dbg "dag-select 0" >/dev/null
echo "frame times: $(dbg dag-bench)"
BENCH=$(dbg dag-bench)

# --- Kanban
dbg "appearance dark" >/dev/null
dbg "queue-page kanban" >/dev/null; sleep 1
S=$(dbg queue-state); has "$S" "Draft=2 In Progress=3 Review=2 Done=1"; ok $? "8 cards in 4 columns ($(echo "$S" | grep '^kanban'))"
dbg "kanban-select export-csv" >/dev/null; sleep 0.5; shot "$W" kanban-dark
dbg "appearance light" >/dev/null; sleep 1; shot "$W" kanban-light
dbg "kanban-drag billing done" >/dev/null; sleep 1.5
has "$(dbg queue-state)" "Draft=1 In Progress=3 Review=2 Done=2"; ok $? "dragging billing to Done moves it"
dbg "kanban-select audit-log" >/dev/null
dbg "kanban-key right opt" >/dev/null; sleep 1
has "$(dbg queue-state)" "Review=1 Done=3"; ok $? "option-right moves the selected card one column"
[ -z "$(git -C "$REPO" status --porcelain)" ]; ok $? "the repo's progress files were not modified (temp copy only)"
grep -q "status: draft" "$REPO/docs/prd-billing.progress.md"; ok $? "original prd-billing.progress.md still says draft"

# CPU / RSS with the page open on the 5,000-commit repo, 20 s idle.
dbg "queue-page branches" >/dev/null; sleep 2
ps -o rss= -p "$APP_PID" | awk '{printf "rss_mb=%.1f\n", $1/1024}'
t0=$(ps -o time= -p "$APP_PID"); sleep 20; t1=$(ps -o time= -p "$APP_PID")
python3 - "$t0" "$t1" <<'P'
import sys
def sec(t):
    m, s = t.strip().split(":"); return int(m) * 60 + float(s)
print("cpu_pct_over_20s=%.2f" % ((sec(sys.argv[2]) - sec(sys.argv[1])) / 20 * 100))
P
echo "bench: $BENCH"
echo "failures=$FAILS (look at screenshots/queue-* branches-* kanban-*)"
exit $FAILS
