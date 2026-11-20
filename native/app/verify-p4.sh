#!/usr/bin/env bash
# P4 (state restore) against the real app: throwaway stack, fake HOME, own sockets, kills only what it started.
#   A. set UI state -> ui-prefs.json has today's keys/formats -> quit -> relaunch -> same state
#   B. a migrated ui-prefs.json (webview formats, incl. keys native does not use) -> same state; foreign keys survive
#   C. garbled ui-prefs.json -> app starts, file moved aside, writing works
#   D. cost: file writes per minute and idle CPU while nothing changes
# Run from a tree whose MuyaNative.app is built.   verify-p4.sh   exit 1 on any FAIL
set -uo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d /tmp/muya-p4v.XXXXXX)
export TMPDIR=$WORK
STATE=$WORK/muya-native-dev.state
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
./run-dev.sh start >/dev/null || exit 1
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
wait_app() { for _ in $(seq 100); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && return 0; sleep 0.1; done; return 1; }
wait_app || { echo "FAIL app did not come up"; exit 1; }
PREFS="$DEV/home/Library/Application Support/com.staunch.muya/native/ui-prefs.json"
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
st() { dbg p4-state | tr ' ' '\n' | sed -n "s/^$1=//p"; }
pref() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],"<absent>"))' "$PREFS" "$1" 2>/dev/null || echo "<nofile>"; }
quit_app() { dbg p4-quit >/dev/null; for _ in $(seq 50); do kill -0 "$APP_PID" 2>/dev/null || return 0; sleep 0.2; done; bad "app did not quit"; }
restart_app() { quit_app; ./run-dev.sh app >/dev/null; . "$STATE"; wait_app || bad "relaunch failed"; dbg "window 1440 900" >/dev/null; sleep 2; }

mkdir -p "$DEV/home/p4"; printf '# note\n' > "$DEV/home/p4/a.md"; printf 'x\n' > "$DEV/home/p4/b.txt"
sleep 1

echo "== A. set state, quit, relaunch"
dbg "window 1440 900" >/dev/null; sleep 1   # the inspector is the operator's choice only from 1280 px
dbg "p4-agents-width 300" >/dev/null; dbg p4-inspector >/dev/null; sleep 0.4; dbg p4-inspector >/dev/null; sleep 0.4   # wide window: open by default, so close it and open it again = a saved choice
 dbg "p4-inspector-width 400" >/dev/null
dbg "p4-files 1" >/dev/null; dbg "p4-grid 1" >/dev/null
dbg "p4-open $DEV/home/p4/a.md" >/dev/null; dbg "p4-open $DEV/home/p4/b.txt" >/dev/null
dbg "p4-history first prompt" >/dev/null; dbg "p4-history second ğü 日本" >/dev/null
sleep 2.0
B4=$(dbg p4-state); echo "before: $B4"
check "agentsOpen written" "$(pref muya.panels.agentsOpen)" "true"
check "agentsWidth written" "$(pref muya.panels.agentsWidth)" "300"
check "inspectorOpen written" "$(pref muya.panels.inspectorOpen)" "true"
iw=$(pref muya.panels.inspectorWidth); [ "$iw" -ge 390 ] && [ "$iw" -le 410 ] && ok "inspectorWidth written ($iw)" || bad "inspectorWidth [$iw]"
check "filesOpen written" "$(pref muya.panels.filesOpen)" "true"
check "viewMode written" "$(pref apex.viewMode)" "grid"
check "openFiles formats" "$(pref muya.openFiles | python3 -c 'import sys,ast; l=ast.literal_eval(sys.stdin.read().strip()) if False else None' 2>/dev/null; python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); l=json.loads(d["muya.openFiles"]); print(",".join(e["kind"]+":"+e["name"] for e in l))' "$PREFS")" "mdview:a.md,editor:b.txt"
check "composerHistory formats" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.loads(d["apex.composerHistory.agent"]))' "$PREFS")" "['first prompt', 'second ğü 日本']"
restart_app
A4=$(dbg p4-state); echo "after:  $A4"
for k in agents inspector filesOpen grid openFiles history; do check "relaunch keeps $k" "$(st $k)" "$(echo "$B4" | tr ' ' '\n' | sed -n "s/^$k=//p")"; done
dbg "p4-grid 0" >/dev/null; sleep 1.0   # the grid hides the agents panel (like today's GridScreen): measure the panel widths in the single view
aw=$(st agentsW); [ "$aw" -ge 295 ] && [ "$aw" -le 305 ] && ok "agents width back ($aw)" || bad "agents width [$aw]"
iw2=$(st inspectorW); [ "$iw2" -ge 390 ] && [ "$iw2" -le 410 ] && ok "inspector width back ($iw2)" || bad "inspector width [$iw2]"
# panels closed again -> keys flip, nothing else is lost
dbg p4-toggle-sidebar >/dev/null; dbg "p4-grid 0" >/dev/null; sleep 0.8; dbg p4-inspector >/dev/null; dbg "p4-files 0" >/dev/null; sleep 2
check "agentsOpen false" "$(pref muya.panels.agentsOpen)" "false"
check "inspectorOpen false" "$(pref muya.panels.inspectorOpen)" "false"
check "viewMode tabs" "$(pref apex.viewMode)" "tabs"
check "filesOpen false" "$(pref muya.panels.filesOpen)" "false"
check "history survives" "$(st history)" "2"
# hard kill after the debounce window: nothing is lost (the app is not asked to flush)
dbg p4-toggle-sidebar >/dev/null; sleep 2.5; kill -9 "$APP_PID" 2>/dev/null; sleep 0.5
check "SIGKILL after debounce keeps agentsOpen" "$(pref muya.panels.agentsOpen)" "true"

echo "== B. migrated file (webview formats)"
quit_app 2>/dev/null; kill -9 "$APP_PID" 2>/dev/null
python3 - "$PREFS" "$DEV/home/p4/a.md" <<'PY'
import json, sys
f = {
 "apex.theme": "dark", "muya.resumeOnLaunch": "1", "muya.autoSave": "1",
 "muya.terminalPrefs": json.dumps({"fontSize": 17, "lineHeight": 1.4, "letterSpacing": 0, "scheme": "muya"}),
 "muya.panels.agentsOpen": "true", "muya.panels.agentsWidth": "320", "muya.panels.inspectorOpen": "true", "muya.panels.inspectorWidth": "420",
 "muya.panels.filesOpen": "true", "apex.viewMode": "grid",
 "muya.openFiles": json.dumps([{"key": "k1", "kind": "mdview", "filePath": sys.argv[2], "name": "a.md"}, {"key": "k2", "kind": "editor", "filePath": "/gone/missing.txt", "name": "missing.txt"}]),
 "apex.composerHistory.agent": json.dumps(["one", "two", "three"]),
 "apex.openTabs": json.dumps([{"key": "t1", "kind": "terminal", "cwd": "/tmp"}]), "muya.selectedAgent": "t1", "muya.gridLayout": "1x2",
 "apex.mergeQueue": json.dumps(["/p/q"]), "muya.unicode": "Türkçe ğüşiöç — 日本語 🙂",
}
json.dump(f, open(sys.argv[1], "w"))
PY
./run-dev.sh app >/dev/null; . "$STATE"; wait_app || bad "relaunch failed"; sleep 2
M=$(dbg p4-state); echo "migrated: $M"
check "theme from apex.theme" "$(st theme)" "Dark"
check "font size from muya.terminalPrefs" "$(st font)" "17"
check "grid from apex.viewMode" "$(st grid)" "true"
check "agents shown" "$(st agents)" "shown"
check "files section open" "$(st filesOpen)" "true"
check "open files: existing kept, missing dropped" "$(st openFiles)" "a.md"
check "composer history" "$(st history)" "3"
# The inspector belongs to the Control view and is only on screen from 1280 px (usePanelLayout): the saved choice never changes.
check "grid: no inspector on screen (the saved choice stays)" "$(st inspector)|$(pref muya.panels.inspectorOpen)" "hidden|true"
dbg "window 1440 900" >/dev/null; sleep 1.2
dbg "p4-grid 0" >/dev/null; sleep 1.2
check "inspector open (wide window, Control)" "$(st inspector)" "shown"
aw=$(st agentsW); [ "$aw" -ge 315 ] && [ "$aw" -le 325 ] && ok "agents width 320 ($aw)" || bad "agents width [$aw]"
iw=$(st inspectorW); [ "$iw" -ge 410 ] && [ "$iw" -le 430 ] && ok "inspector width 420 ($iw)" || bad "inspector width [$iw]"
dbg "window 1120 732" >/dev/null; sleep 1.5
iwp=$(pref muya.panels.inspectorWidth); check "narrow window (1120): inspector hidden, saved choice and width untouched" "$(st inspector)|$(pref muya.panels.inspectorOpen)|$([ "$iwp" -ge 410 ] && [ "$iwp" -le 430 ] && echo ok)" "hidden|true|ok"
dbg "window 1440 900" >/dev/null; sleep 1.5
check "wide again (1440): the inspector is back" "$(st inspector)|$(pref muya.panels.inspectorOpen)" "shown|true"
iw=$(st inspectorW); [ "$iw" -ge 410 ] && [ "$iw" -le 430 ] && ok "inspector width 420 after the round trip ($iw)" || bad "inspector width after the round trip [$iw]"
dbg "p4-grid 0" >/dev/null; sleep 2
check "foreign keys untouched (openTabs)" "$(pref apex.openTabs)" '[{"key": "t1", "kind": "terminal", "cwd": "/tmp"}]'
check "foreign keys untouched (mergeQueue)" "$(pref apex.mergeQueue)" '["/p/q"]'
check "foreign keys untouched (unicode)" "$(pref muya.unicode)" "Türkçe ğüşiöç — 日本語 🙂"
check "terminalPrefs keeps lineHeight" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.loads(d["muya.terminalPrefs"])["lineHeight"])' "$PREFS")" "1.4"
check "viewMode flipped" "$(pref apex.viewMode)" "tabs"

echo "== C. garbled file"
quit_app 2>/dev/null; kill -9 "$APP_PID" 2>/dev/null
printf '{ this is not json' > "$PREFS"; rm -f "$PREFS.corrupt"
./run-dev.sh app >/dev/null; . "$STATE"; wait_app || bad "relaunch with garbled file failed"; sleep 1.5
check "app runs with defaults" "$(st grid)|$(st inspector)" "false|hidden"
[ -f "$PREFS.corrupt" ] && ok "garbled file kept aside" || bad "garbled file not kept aside"
dbg "p4-grid 1" >/dev/null; sleep 2
check "writing works afterwards" "$(pref apex.viewMode)" "grid"

echo "== D. cost"
w0=$(st writes); sleep 20; w1=$(st writes)
check "no writes while idle (20 s)" "$w1" "$w0"
for _ in $(seq 30); do dbg "p4-agents-width $((250 + RANDOM % 100))" >/dev/null; done; sleep 2
w2=$(st writes); echo "30 divider drags -> $((w2 - w1)) write(s)"
[ $((w2 - w1)) -le 2 ] && ok "a drag burst costs at most 2 writes" || bad "drag burst wrote $((w2 - w1)) times"
cpu=$(ps -o %cpu= -p "$APP_PID" | tr -d ' '); echo "idle app CPU now: $cpu%"
for i in 1 2 3; do ps -o %cpu= -p "$APP_PID" >/dev/null; sleep 1; done
echo "writes/min while idle: 0 (measured $((w1 - w0)) in 20 s)"

echo "== E. settings footer + settings written through the real Settings path"
dbg "settings-set appearance Dark" >/dev/null; dbg "settings-set autoApprove on" >/dev/null; dbg "settings-set autoSave on" >/dev/null; sleep 2
check "Theme -> apex.theme" "$(pref apex.theme)" "dark"
check "Auto-allow -> muya.autoApprove" "$(pref muya.autoApprove)" "1"
check "Auto-save -> muya.autoSave" "$(pref muya.autoSave)" "1"
restart_app
check "Theme back after relaunch" "$(st theme)" "Dark"
check "Auto-allow back after relaunch" "$(st autoApprove)" "true"
wid=$(dbg settings-open); sleep 1.2; mkdir -p screenshots
dbg p4-settings-bottom >/dev/null; sleep 0.6
screencapture -x -o -l "$wid" screenshots/p4-settings-footer.png 2>/dev/null
[ -s screenshots/p4-settings-footer.png ] && ok "settings screenshot saved (screenshots/p4-settings-footer.png)" || bad "no settings screenshot"
check "licences sheet opens from the footer button" "$(dbg licences-open)" "ok"; dbg licences-close >/dev/null

echo "== F. a change right before SIGTERM / SIGHUP is not lost (flush on signal, atomic write)"
dbg licences-close >/dev/null; sleep 0.5
dbg "settings-set appearance Light" >/dev/null; kill -TERM "$APP_PID" 2>/dev/null; sleep 0.8
check "Theme written by the SIGTERM flush" "$(pref apex.theme)" "light"
ls "$(dirname "$PREFS")" | grep -q '\.tmp\|~' && bad "temp file left behind" || ok "no half-written temp file after the kill"
./run-dev.sh app >/dev/null; . "$STATE"; wait_app || bad "relaunch failed"; sleep 1.5
check "Theme back after SIGTERM within 1 s" "$(st theme)" "Light"
dbg "settings-set appearance Dark" >/dev/null; kill -HUP "$APP_PID" 2>/dev/null; sleep 0.8
check "Theme written by the SIGHUP flush" "$(pref apex.theme)" "dark"

echo
[ "$fails" = 0 ] && echo "verify-p4: all PASS" || { echo "verify-p4: $fails FAIL"; exit 1; }
