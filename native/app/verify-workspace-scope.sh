#!/usr/bin/env bash
# Workspace scope (docs/prd-workspace-scope-native.md) on a REAL daemon + app in a throwaway HOME (run-dev.sh): sessions in two
# folders, a subfolder of the first and a worktree folder of the first. Choosing a folder must leave only its scope in the agents
# list and the palette, "All workspaces" must bring everything back, the ⌥⌘1 / ⌥⌘0 path must do what the rows do, the tick must
# follow the scope, and the choice must survive an app restart. Out-of-scope sessions must keep running.
#   MUYA_BIN_DIR=<dir with muya-ptyd + muyad> native/app/verify-workspace-scope.sh
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-ws.XXXXXX)  # its own dir per run: the default /tmp state file collides with any other running dev stack
STATE=$TMPDIR/muya-native-dev.state
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$TMPDIR"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
# run-dev.sh runs whatever is in build/, so a fix made after the last build would not be the thing tested
# (release trap 8: the operator was once shown a stale dev build and reported the bug as unfixed).
eval "$(bash ../scripts/ghostty-env.sh)" || { echo "FAIL build environment (see native/scripts/ghostty-env.sh)"; exit 1; }
./build.sh >/dev/null 2>&1 || { echo "FAIL could not build the app"; exit 1; }
./run-dev.sh start >/dev/null || { echo "FAIL could not start the dev stack"; exit 1; }
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock" || true; }
for _ in $(seq 40); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid)" ] && break; sleep 0.5; done
fail=0
expect() { if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: wanted '$3' in '$2'"; fail=$((fail + 1)); fi; }
equal() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: wanted '$3', got '$2'"; fail=$((fail + 1)); fi; }
row() { dbg ws-rows | tr '|' '\n' | sed -n "$1p"; }   # 1 = heading, 2 = All workspaces, 3.. = folders

W=$DEV/home/ws; A=$W/proj-a; B=$W/proj-b
mkdir -p "$A/sub" "$B" "$W/proj-a-worktrees/feat"
dbg "window 1120 732" >/dev/null
id() { dbg "new $1" | awk '{print $2}'; }
SA=$(id "$A"); SS=$(id "$A/sub"); SB=$(id "$B"); SW=$(id "$W/proj-a-worktrees/feat"); sleep 2
case "$SA$SS$SB$SW" in *[!0-9]*|"") echo "FAIL could not open the four sessions: '$SA' '$SS' '$SB' '$SW'"; exit 1 ;; esac
sorted() { tr ',' '\n' | sort -n | paste -sd, -; }
ALL=$(printf '%s\n' "$SA" "$SS" "$SB" "$SW" | sort -n | paste -sd, -)
SCOPE_A=$(printf '%s\n' "$SA" "$SS" "$SW" | sort -n | paste -sd, -)

echo "-- all workspaces (start)"
equal "list shows all four sessions" "$(dbg ws-list | sorted)" "$ALL"
equal "palette shows all four sessions" "$(dbg ws-palette | sorted)" "$ALL"
expect "menu starts with the heading and an All workspaces row" "$(row 2)" "All workspaces"
expect "All row counts every agent" "$(row 2)" "All workspaces   4 agents"
expect "All row carries the ⌥⌘0 shortcut" "$(row 2)" "⌥⌘0"
expect "All row is ticked" "$(row 2)" "✓ All workspaces"
expect "menu ends with Add workspace…" "$(dbg ws-rows)" "|-|Add workspace…"
expect "chip says All workspaces" "$(dbg ws-state)" "chip=All workspaces"

echo "-- choose proj-a (row 1, as ⌥⌘1 does)"
equal "ws-select 1 succeeds" "$(dbg 'ws-select 1')" "ok"; sleep 1
r=$(dbg ws-rows)
equal "list is proj-a, its subfolder and its worktree" "$(dbg ws-list | sorted)" "$SCOPE_A"
equal "palette is filtered the same" "$(dbg ws-palette | sorted)" "$SCOPE_A"
case ",$(dbg ws-list)," in *",$SB,"*) echo "FAIL proj-b session still listed"; fail=$((fail + 1)) ;; *) echo "PASS proj-b session is not listed" ;; esac
expect "the tick is on proj-a" "$(row 3)" "✓ proj-a   3 agents"
[[ "$(row 2)" != ✓* ]] && echo "PASS All row not ticked" || { echo "FAIL All row still ticked"; fail=$((fail + 1)); }
expect "row 1 has the ⌥⌘1 hint" "$(row 3)" "⌥⌘1"
expect "subfolder row counts only itself" "$(row 4)" "sub   1 agent · "
expect "chip names the folder" "$(dbg ws-state)" "chip=proj-a"
expect "the choice is persisted" "$(dbg ws-state)" "persisted=$A"
# out-of-scope sessions keep running
live=$(dbg sessions | awk -F'\t' -v id="$SB" '$1 == id' | grep -vc "Exited" || true)
equal "the out-of-scope session is still running" "$live" "1"
dbg "select $SB" >/dev/null; dbg 'type "echo OOS-ALIVE\n"' >/dev/null; sleep 1
expect "the out-of-scope terminal still answers" "$(dbg text)" "OOS-ALIVE"

echo "-- selection falls out of scope"
dbg "select $SB" >/dev/null; dbg 'ws-select 1' >/dev/null; sleep 1
case ",$SCOPE_A," in *",$(dbg ws-state | sed -n 's/.*selected=\([0-9-]*\).*/\1/p'),"*) echo "PASS choosing a scope that excludes the selection selects an in-scope session" ;; *) echo "FAIL selection stayed out of scope: $(dbg ws-state)"; fail=$((fail + 1)) ;; esac

echo "-- choose proj-b (row 3: rows are proj-a, proj-a/sub, proj-b, worktree)"
dbg 'ws-select 3' >/dev/null; sleep 1
equal "list is proj-b only" "$(dbg ws-list)" "$SB"
expect "the tick moved to proj-b" "$(row 5)" "✓ proj-b   1 agent "

echo "-- the subfolder alone"
dbg 'ws-select 2' >/dev/null; sleep 1
equal "choosing the subfolder lists only it" "$(dbg ws-list)" "$SS"

echo "-- All workspaces (as ⌥⌘0 does)"
equal "ws-select all succeeds" "$(dbg 'ws-select all')" "ok"; sleep 1
equal "list shows all four again" "$(dbg ws-list | sorted)" "$ALL"
equal "palette shows all four again" "$(dbg ws-palette | sorted)" "$ALL"
expect "All row ticked again" "$(row 2)" "✓ All workspaces"
expect "persisted choice is cleared" "$(dbg ws-state)" "persisted=none"

echo "-- the choice survives a restart"
dbg 'ws-select 1' >/dev/null; sleep 2.5
kill "$APP_PID" 2>/dev/null; for _ in $(seq 30); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.2; done
rm -f "$DEV/app-debug.sock"
./run-dev.sh app >/dev/null; . "$STATE"
for _ in $(seq 60); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid)" ] && break; sleep 0.5; done
for _ in $(seq 30); do [ -n "$(dbg ws-list)" ] && break; sleep 0.5; done
expect "the restored scope is proj-a" "$(dbg ws-state)" "scope=$A"
equal "the restored list is filtered" "$(dbg ws-list | sorted)" "$SCOPE_A"
expect "the restored tick is on proj-a" "$(row 3)" "✓ proj-a"

echo "-- a chosen root stays listed when its last session closes"
dbg "ws-choose $B" >/dev/null; dbg "close $SB" >/dev/null; sleep 2
expect "proj-b still has its row, with 0 agents" "$(dbg ws-rows)" "✓ proj-b   0 agents"
equal "its list is empty" "$(dbg ws-list)" ""

[ "$fail" = 0 ] && echo "verify-workspace-scope: all passed" || echo "verify-workspace-scope: $fail failures"
exit "$fail"
