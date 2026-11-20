#!/usr/bin/env bash
# Faz 4a end-to-end check: Sessions, Schedules, Settings and the command palette of the native app against a
# dev stack with muyad running the schedule timers (`--scheduler`), a throwaway HOME with SYNTHETIC transcripts
# and a fake `claude`. Drives the real app through the debug socket, asserts, checks keyboard navigation and the
# accessibility audit, and screenshots dark + light.
# Needs a logged-in GUI session. Always stops the stack it started.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-pages.XXXXXX)  # its own dir per run: a fixed one collides with another dev stack / a leftover # short, user-free paths in the screenshots; its own state file, so another dev stack is never stopped
mkdir -p "$TMPDIR"
SHOTS=$PWD/screenshots
mkdir -p "$SHOTS"
STATE=$TMPDIR/muya-native-dev.state
if [ -f "$STATE" ]; then ./run-dev.sh stop >/dev/null 2>&1 || true; fi
# A minimal PATH: the schedule runner must find the FAKE claude in the throwaway HOME, never the real CLI.
PATH=/usr/bin:/bin:/usr/sbin:/sbin MUYAD_ARGS=--scheduler MUYA_DEV_NO_APP=1 ./run-dev.sh start >/dev/null || exit 1
. "$STATE"
trap './run-dev.sh stop >/dev/null 2>&1' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
HOMEDIR=$DEV/home
python3 -I make-pages-fixtures.py "$HOMEDIR" 12 >/dev/null
./run-dev.sh app >/dev/null
. "$STATE" # APP_PID
sleep 2.5

dbg() { printf '%s\n' "$1" | nc -U -w 5 "$DEV/app-debug.sock"; }
FAILS=0
expect() { if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi; }
refuse() { if [[ "$2" != *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: found '$3' in '$2'"; FAILS=$((FAILS + 1)); fi; }
wait_for() { # description, command, expected-substring [seconds]
  local out="" end=$((SECONDS + ${4:-10}))
  while [ $SECONDS -lt $end ]; do out=$(eval "$2"); [[ "$out" == *"$3"* ]] && { echo "PASS $1"; return; }; sleep 0.25; done
  echo "FAIL $1: got '$out', wanted '$3'"; FAILS=$((FAILS + 1))
}
shot() { screencapture -x -o -l "$1" "$SHOTS/$2.png"; echo "shot $2"; }
both() { # window id command, name
  dbg "appearance dark" >/dev/null; sleep 1; shot "$($1)" "$2-dark"; dbg "appearance light" >/dev/null; sleep 1; shot "$($1)" "$2-light"
}
mainwin() { dbg windowid; }
# The real Accessibility API (AXUIElement) against the app's pid; the in-app audit above is the fallback.
swiftc -O -o build/ax-audit tools/ax-audit.swift >/dev/null 2>&1
axaudit() { # description
  local r rc; r=$(./build/ax-audit "$APP_PID" 2>&1); rc=$?
  if [ $rc -eq 4 ] || [ $rc -eq 5 ]; then sleep 2; r=$(./build/ax-audit "$APP_PID" 2>&1); rc=$?; fi # one retry: a busy app can miss the first walk
  if [ $rc -eq 2 ]; then echo "SKIP AX audit, $1: $r"; return; fi
  if [ $rc -eq 4 ] || [ $rc -eq 5 ]; then # the AX server does not expose this app's windows right now: the in-app audit stands in
    echo "SKIP AXUIElement audit, $1: the AX server does not expose the app's windows (the in-app audit() of this script covers it)"; return 0
  fi
  expect "AXUIElement audit, $1: every control speaks" "$r" "unlabelled=0"
  return 0
}
audit() { # page label
  local r; r=$(dbg "ax-audit")
  expect "accessibility audit, $1: no unlabelled control" "$r" "unlabelled=0"
}

dbg "sessions" | while IFS=$'\t' read -r id _; do [ -n "$id" ] && dbg "close $id" >/dev/null; done

echo "=== Sessions"
expect "page opens" "$(dbg 'page sessions')" "Sessions"
wait_for "history lists the synthetic sessions" "dbg sessions-view" "status=12 sessions"
V=$(dbg sessions-view)
expect "history is one flat list of session cards (no per-project grouping)" "$V" "past	12"
refuse "no per-project group headers" "$V" "group	alpha"
expect "each card carries its own folder (alpha session)" "$V" "Refactor the zebra parser		/work/alpha"
expect "each card carries its own folder (gamma session)" "$V" "Docs cleanup		/work/gamma"
expect "session names come from the transcript" "$V" "Refactor the zebra parser"
expect "the page has the keyboard on arrival (search is not auto-focused, like today)" "$(dbg focus)" "SessionsPage"
dbg "appearance dark" >/dev/null
dbg "sessions-search zebra" >/dev/null
wait_for "content search finds the word in the conversation" "dbg sessions-view" "matches=1"
expect "snippet shown" "$(dbg sessions-view)" "refactor the zebra parser so it streams"
both mainwin pages-sessions-search
dbg "sessions-search include=migration" >/dev/null
wait_for "include= needs a content hit" "dbg sessions-view" "00000003-aaaa"
refuse "include= hides the other sessions" "$(dbg sessions-view)" "00000000-aaaa"
dbg "sessions-search session=cache" >/dev/null; sleep 0.5
expect "session= filters by name" "$(dbg sessions-view)" "Cache invalidation"
refuse "session= hides the others" "$(dbg sessions-view)" "Database migration"
dbg "sessions-search path=gamma" >/dev/null; sleep 0.5
expect "path= filters by folder (the flat list shrinks to the gamma sessions)" "$(dbg sessions-view)" "status=2 of 12 sessions"
expect "path= keeps one flat list" "$(dbg sessions-view)" "past	2"
dbg "sessions-search zzzzqqq" >/dev/null
wait_for "no hit: empty result" "dbg sessions-view" "matches=0"
dbg "sessions-search zz" >/dev/null; dbg "sessions-cancel" >/dev/null
expect "a running search can be cancelled" "$(dbg sessions-view)" "searching=false"
dbg "sessions-search " >/dev/null; sleep 0.4
both mainwin pages-sessions
audit sessions
axaudit "sessions page"
# keyboard: Tab from the search box reaches the list, Return resumes, Esc closes the page
expect "the first tab lands in the search box" "$(dbg 'press tab' >/dev/null; dbg focus)" "label=Search sessions"
expect "the next tab moves focus to the list" "$(dbg 'press tab' >/dev/null; dbg focus)" "label=Sessions list"
dbg "press esc" >/dev/null; sleep 0.3
expect "Esc closes the page" "$(dbg 'page')" "none"

dbg "page sessions" >/dev/null; sleep 0.8
EXPORT=$HOMEDIR/export-test.md
dbg "sessions-export 00000000 $EXPORT" >/dev/null
wait_for "export writes Markdown" "head -1 $EXPORT 2>/dev/null" "# Session"
expect "export holds the conversation" "$(cat "$EXPORT" 2>/dev/null)" "zebra parser now streams line by line"
expect "export names the folder" "$(cat "$EXPORT" 2>/dev/null)" "Working directory: \`/work/alpha\`"
BEFORE=$(dbg sessions | grep -c .)
dbg "sessions-resume 00000000" >/dev/null; sleep 2
expect "resume opens a new terminal" "$(dbg sessions | grep -c .)" "$((BEFORE + 1))"
expect "resume types the claude command" "$(dbg text)" "claude --resume '00000000-aaaa-4bbb-8ccc-000000000000' --permission-mode auto"
expect "the page closes after resume" "$(dbg page)" "none"

echo "=== Schedules"
dbg "page schedules" >/dev/null; sleep 1
expect "muyad is the runner" "$(dbg sched-view)" "runner=service"
dbg "sched-new" >/dev/null
expect "editor opens" "$(dbg sched-editor)" "title=New schedule"
chk() { # description, expected message
  dbg sched-save >/dev/null; sleep 0.7; expect "$1" "$(dbg sched-editor)" "$2"
}
chk "name is required" "error=Give the schedule a name."
dbg "sched-set name Nightly report" >/dev/null
chk "prompt is required" "error=The prompt is empty."
dbg "sched-set prompt Summarise the open issues in this project" >/dev/null
chk "folder is required" "error=Choose a folder."
dbg "sched-set folder /definitely/not/here" >/dev/null
chk "folder must exist" "error=That folder doesn't exist."
dbg "sched-set folder $HOMEDIR/work/report" >/dev/null
dbg "sched-set kind interval" >/dev/null; dbg "sched-set minutes 1" >/dev/null
chk "interval floor" "error=Run at most every 5 minutes."
dbg "sched-set kind weekly" >/dev/null; dbg "sched-set days none" >/dev/null
chk "weekly needs a day" "error=Pick at least one day."
dbg "sched-set times 09:00,25:99" >/dev/null
dbg "sched-set days 0,1,2,3,4" >/dev/null
chk "times must be real" "error=Use times like 09:30."
dbg "sched-set times 08:30,17:00" >/dev/null
dbg "sched-set timeout 0" >/dev/null
chk "timeout range" "error=Timeout must be between 1 minute and 24 hours."
dbg "sched-set timeout 5" >/dev/null
expect "summary follows the form" "$(dbg sched-editor)" "summary=Runs: weekdays at 08:30, 17:00"
both mainwin pages-schedule-editor
audit "schedule editor"
axaudit "schedule editor sheet"
dbg sched-save >/dev/null
wait_for "valid schedule is created" "dbg sched-view" "Nightly report"
V=$(dbg sched-view)
expect "described like the Tauri page" "$V" "Weekdays at 08:30, 17:00"
expect "never run yet" "$V" "Never run"
expect "stats count it" "$V" "stats=1 (1 on · 0 off)|0|—|None"
dbg "sched-toggle Nightly report off" >/dev/null
wait_for "disable" "dbg sched-view" "	off	"
dbg "sched-toggle Nightly report on" >/dev/null
wait_for "enable" "dbg sched-view" "	on	"
dbg "sched-run Nightly report" >/dev/null
wait_for "run now shows Running" "dbg sched-view" "Running" 5
both mainwin pages-schedules-running
wait_for "the run finishes (fake claude)" "dbg sched-view" "runs=1" 15
V=$(dbg sched-view)
expect "last run succeeded" "$V" "Success"
expect "stats after a run" "$V" "stats=1 (1 on · 0 off)|1|100%|None"
dbg "sched-history Nightly report" >/dev/null
wait_for "history lists the manual run" "dbg sched-history-view" "Success	Run now"
both mainwin pages-schedule-history
axaudit "schedule history sheet"
dbg sched-history-close >/dev/null; sleep 0.4
both mainwin pages-schedules
audit schedules
axaudit "schedules page"
expect "arrow keys + Return open the editor from the list" "$(dbg 'press return' >/dev/null; sleep 0.5; dbg sched-editor)" "title=Edit schedule"
dbg "sched-set name Nightly summary" >/dev/null; dbg sched-save >/dev/null
wait_for "edit saves under the same id" "dbg sched-view" "Nightly summary"
expect "still one schedule" "$(dbg sched-view | grep -c 'runs=')" "1"
dbg "sched-delete Nightly summary" >/dev/null
wait_for "delete" "dbg sched-view" "stats=0 (0 on · 0 off)"
expect "its run history is gone" "$(ls "$HOMEDIR/.claude/muya-schedule-runs" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "=== Settings"
dbg "page none" >/dev/null
SW=$(dbg settings-open); sleep 1.2
expect "settings window opens" "$(dbg 'settings-get keepRunningInBackground')" "on"
settings_win() { echo "$SW"; }
audit_s() { expect "accessibility audit, settings: no unlabelled control" "$(dbg 'ax-audit settings')" "unlabelled=0"; }
audit_s
axaudit "settings window"
dbg "settings-set keepRunningInBackground off" >/dev/null
dbg "settings-set claudeCleanupDays 60 days" >/dev/null
dbg "settings-set claudeStatusInFooter off" >/dev/null
dbg "settings-set autoSave on" >/dev/null
dbg "settings-set autoApprove on" >/dev/null
dbg "settings-set appearance Dark" >/dev/null
dbg "settings-set debugLog on" >/dev/null
dbg "settings-set debugLogPath $HOMEDIR/dbg.log" >/dev/null
sleep 1
expect "muya-core stored 'keep running' (muya-app.json)" "$(cat "$HOMEDIR/.claude/muya-app.json" 2>/dev/null | tr -d ' \n')" '"keepRunningInBackground":false'
expect "muya-core stored the footer switch" "$(cat "$HOMEDIR/.claude/muya-app.json" 2>/dev/null | tr -d ' \n')" '"claudeStatusInFooter":false'
expect "cleanup days written to Claude's settings.json" "$(cat "$HOMEDIR/.claude/settings.json" 2>/dev/null | tr -d ' \n')" '"cleanupPeriodDays":60'
expect "app prefs file holds the app-only rows" "$(cat "$HOMEDIR/Library/Application Support/MuyaNative/prefs.json" 2>/dev/null | tr -d ' \n')" '"autoSave":true'
expect "theme applied at once" "$(dbg appearance-name)" "dark"
shot "$SW" pages-settings-dark
dbg "settings-set appearance Light" >/dev/null; sleep 1; shot "$SW" pages-settings-light
expect "theme Light applied" "$(dbg appearance-name)" "light"
dbg "settings-set appearance Dark" >/dev/null
dbg "settings-close" >/dev/null
# relaunch: only the app; muyad keeps running
kill "$APP_PID" 2>/dev/null
for _ in $(seq 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.25; done
kill -0 "$APP_PID" 2>/dev/null && { echo "FAIL the app did not exit"; FAILS=$((FAILS + 1)); }
./run-dev.sh app >/dev/null; . "$STATE"; sleep 3
SW=$(dbg settings-open); sleep 1.5
R=$(dbg settings-rows)
expect "after relaunch: keep running is still off" "$R" "keepRunningInBackground=off"
expect "after relaunch: footer switch still off" "$R" "claudeStatusInFooter=off"
expect "after relaunch: cleanup is still 60 days" "$R" "claudeCleanupDays=60 days"
expect "after relaunch: auto-save still on" "$R" "autoSave=on"
expect "after relaunch: auto-allow still on" "$R" "autoApprove=on"
expect "after relaunch: theme still Dark" "$R" "appearance=Dark"
expect "after relaunch: debug log still on" "$R" "debugLog=on"
expect "after relaunch: log path kept" "$R" "debugLogPath=$HOMEDIR/dbg.log"
expect "after relaunch: the theme is applied at startup" "$(dbg appearance-name)" "dark"
dbg "settings-close" >/dev/null
expect "Settings window is closed" "$(dbg settings-visible)" "no"
# AppKit shows the key for the user's layout (on a Turkish keyboard the comma key reads "ö"), so only Cmd is asserted.
expect "the Settings menu item carries a Cmd shortcut" "$(dbg 'menu-item Settings…')" "cmd=true"
sleep 0.6
expect "choosing the menu item opens Settings" "$(dbg settings-visible)" "yes"
dbg "settings-close" >/dev/null

echo "=== Command palette"
dbg "page sessions" >/dev/null; sleep 0.8; dbg "page none" >/dev/null
expect "Cmd-K opens the palette" "$(dbg palette-shortcut)" "open"
expect "focus is in the palette search" "$(dbg focus)" "label=Command palette search"
dbg "palette-query " >/dev/null
axaudit "command palette"
both mainwin pages-palette
expect "views are listed" "$(dbg palette-state)" "view:schedules"
expect "'sch' finds Schedules first" "$(dbg 'palette-query sch' | head -1)" "view:schedules"
dbg "palette-run" >/dev/null; sleep 1
expect "running it opens the page" "$(dbg page)" "Schedules"
dbg "page none" >/dev/null; dbg "palette-shortcut" >/dev/null
expect "sessions are searchable by name" "$(dbg 'palette-query zebra')" "hist:00000000-aaaa"
expect "open terminals are searchable too" "$(dbg 'palette-state')" "↻ Refactor the zebra parser"
dbg "palette-run hist:00000000-aaaa-4bbb-8ccc-000000000000" >/dev/null; sleep 1.2
expect "a session result opens Sessions filtered to it" "$(dbg sessions-view)" "Refactor the zebra parser"
refuse "...and only it" "$(dbg sessions-view)" "Database migration"
dbg "page none" >/dev/null; dbg "palette-shortcut" >/dev/null
BEFORE=$(dbg sessions | grep -c .)
dbg "palette-query new term" >/dev/null; dbg "press return" >/dev/null; sleep 1.5
expect "'new term' + Return opens a terminal" "$(dbg sessions | grep -c .)" "$((BEFORE + 1))"
dbg "palette-shortcut" >/dev/null; dbg "press esc" >/dev/null
expect "Esc closes the palette" "$(dbg palette-state | head -1)" "closed"
expect "focus returns to the terminal" "$(dbg focus)" "TerminalView"

echo
[ $FAILS -eq 0 ] && echo "ALL PASS" || echo "$FAILS FAILED"
exit $FAILS
