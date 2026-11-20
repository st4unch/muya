#!/usr/bin/env bash
# Faz 4e end-to-end check: live agent sessions, transcript drawer, clean-up (Trash), Scheduled Prompt,
# auto-allow, resume on launch, Open at login + licences, schedules-changed events and the palette's
# "files on this Mac" group — the real app against a dev stack in a throwaway HOME with SYNTHETIC data
# and a fake `claude`. Needs a logged-in GUI session. Always stops the stack it started.
# Trash is redirected (MUYA_TRASH_DIR, honoured only with the debug socket) so the real Trash stays untouched;
# the Spotlight check needs an indexed folder, so it makes (and removes) one under /Users/Shared.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-4e.XXXXXX)  # its own dir per run: a fixed one collides with another dev stack / a leftover
mkdir -p "$TMPDIR"
SHOTS=$PWD/screenshots
mkdir -p "$SHOTS"
STATE=$TMPDIR/muya-native-dev.state
export MUYA_TRASH_DIR=$TMPDIR/trash
rm -rf "$MUYA_TRASH_DIR"
if [ -f "$STATE" ]; then ./run-dev.sh stop >/dev/null 2>&1 || true; fi
MINPATH=/usr/bin:/bin:/usr/sbin:/sbin
PATH=$MINPATH MUYAD_ARGS=--scheduler MUYA_DEV_NO_APP=1 ./run-dev.sh start >/dev/null || exit 1
. "$STATE"
SPOT=/Users/Shared/muya-faz4e-$$
cleanup() { ./run-dev.sh stop >/dev/null 2>&1; rm -rf "$SPOT" "$MUYA_TRASH_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
HOMEDIR=$DEV/home
python3 -I make-pages-fixtures.py "$HOMEDIR" 14 >/dev/null
python3 -I make-4e-fixtures.py "$HOMEDIR" >/dev/null
start_app() { PATH=$MINPATH ./run-dev.sh app >/dev/null; . "$STATE"; }
start_app
sleep 2.5

dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock"; }
FAILS=0
expect() { if [[ "$2" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi; }
refuse() { if [[ "$2" != *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1: found '$3' in '$2'"; FAILS=$((FAILS + 1)); fi; }
wait_for() { # description, command, expected-substring [seconds]
  local out="" end=$((SECONDS + ${4:-10}))
  while [ $SECONDS -lt $end ]; do out=$(eval "$2"); [[ "$out" == *"$3"* ]] && { echo "PASS $1"; return; }; sleep 0.25; done
  echo "FAIL $1: got '$out', wanted '$3'"; FAILS=$((FAILS + 1))
}
shot() { screencapture -x -o -l "$1" "$SHOTS/$2.png"; echo "shot $2"; }
both() { dbg "appearance dark" >/dev/null; sleep 1; shot "$($1)" "$2-dark"; dbg "appearance light" >/dev/null; sleep 1; shot "$($1)" "$2-light"; }
mainwin() { dbg windowid; }
swiftc -O -o build/ax-audit tools/ax-audit.swift >/dev/null 2>&1
axaudit() {
  local r rc; r=$(./build/ax-audit "$APP_PID" 2>&1); rc=$?
  if [ $rc -eq 4 ] || [ $rc -eq 5 ]; then sleep 2; r=$(./build/ax-audit "$APP_PID" 2>&1); rc=$?; fi
  if [ $rc -eq 2 ]; then echo "SKIP AX audit, $1: $r"; return; fi
  if [ $rc -eq 4 ] || [ $rc -eq 5 ]; then # the AX server does not expose this app's windows right now: the in-app audit (windows + sheets) stands in
    r=$(dbg "ax-audit"); expect "in-app audit (AXUIElement unavailable), $1: no unlabelled control" "$r" "unlabelled=0"; return 0
  fi
  expect "AXUIElement audit, $1: every control speaks" "$r" "unlabelled=0"
  return 0
}
close_all() { dbg "sessions" | while IFS=$'\t' read -r id _; do [ -n "$id" ] && dbg "close $id" >/dev/null; done; }
newterm() { dbg "new $HOMEDIR" | awk '{print $2}'; }

close_all
dbg "appearance dark" >/dev/null

echo "=== Live agent sessions (claude agents --json, binary picked by capability)"
dbg "page sessions" >/dev/null
wait_for "two live sessions listed" "dbg sessions-view" "live	2"
V=$(dbg sessions-view)
expect "interactive session, working" "$V" "Zebra live	working	$HOMEDIR/work/report"
expect "background session waits on a prompt" "$V" "Needs input	waiting-for-input	/work/gamma	permission prompt"
expect "history is still listed below the live sessions (one flat list of cards)" "$V" "past	"
expect "past cards keep their folder" "$V" "Refactor the zebra parser		/work/alpha"
INFO=$(dbg agents-info)
expect "a binary was found: the OLD claude first in the login PATH (rejects --json) was skipped" "$INFO" "bin=found error="
both mainwin pages-4e-sessions-live
python3 - "$HOMEDIR/agents.json" <<'PY'
import json, sys
p = sys.argv[1]; a = json.load(open(p)); json.dump(a[:1], open(p, "w"))
PY
dbg agents-reload >/dev/null
wait_for "the list follows the CLI (one session left)" "dbg sessions-view" "live	1"
mv "$HOMEDIR/.local/bin/claude" "$HOMEDIR/.local/bin/claude.off"
dbg "agents-reload" >/dev/null
wait_for "no usable claude: a clear message, no crash" "dbg sessions-view" "Claude CLI not found"
refuse "...and no live group" "$(dbg sessions-view)" "live	"
mv "$HOMEDIR/.local/bin/claude.off" "$HOMEDIR/.local/bin/claude"
dbg agents-reload >/dev/null
wait_for "binary is found again after it came back" "dbg sessions-view" "live	1"
python3 - "$HOMEDIR/agents.json" <<'PY'
import json, sys
p = sys.argv[1]; a = json.load(open(p)); a.append({"sessionId": "00000008-bbbb-4ccc-8ddd-000000000008", "cwd": "/work/gamma", "kind": "background", "id": "bg02", "state": "blocked", "waitingFor": "permission prompt", "name": "Needs input"}); json.dump(a, open(p, "w"))
PY
dbg agents-reload >/dev/null
wait_for "the old session that is running again is listed" "dbg sessions-view" "live	2"

echo "=== Transcript drawer"
dbg "sessions-search " >/dev/null; sleep 0.4
expect "open the transcript" "$(dbg 'transcript-open 00000020')" "ok"
wait_for "the drawer shows the conversation" "dbg transcript-view" "run the quokka tests"
T=$(dbg transcript-view)
expect "title is the session name" "$T" "shown=00000020"
expect "user turn with its time" "$T" "You · 2026-03-01 10:00:00"
expect "assistant turn with a tool marker" "$T" "Running them now."
expect "tool use is a one-line marker" "$T" "🔧 [Bash]"
refuse "tool results are not dumped" "$T" "SECRET-TOOL-DUMP"
expect "a very long answer is cut" "$T" "… [truncated]"
both mainwin pages-4e-transcript
dbg transcript-close >/dev/null
expect "the drawer closes" "$(dbg transcript-view)" "shown=none"

echo "=== Clean-up (Trash only)"
dbg "cleanup-open" >/dev/null; sleep 0.6
dbg "cleanup-set larger 50" >/dev/null
C=$(dbg cleanup-view)
expect "old sessions are picked (40 days)" "$C" "00000006"
expect "old sessions are picked (45 days)" "$C" "00000007"
expect "a large session is picked" "$C" "00000009"
refuse "a running session is left alone although it is 50 days old" "$C" "00000008"
refuse "a recent small session is not picked" "$C" "00000020"
refuse "a just-written large session is left alone" "$C" "0000000a"
both mainwin pages-4e-cleanup
axaudit "clean-up dialog"
dbg "cleanup-toggle 00000007" >/dev/null
expect "unticking removes it from the selection" "$(dbg cleanup-view)" "[ ]	00000007"
dbg "cleanup-set older off" >/dev/null
refuse "rule off: the old ones are no longer picked" "$(dbg cleanup-view)" "00000006"
dbg "cleanup-set older 30" >/dev/null
P=$HOMEDIR/.claude/projects
ls "$P"/*/00000006-*.jsonl "$P"/*/00000009-*.jsonl >/dev/null 2>&1 || { echo "FAIL fixtures missing"; FAILS=$((FAILS + 1)); }
dbg "cleanup-trash" >/dev/null
wait_for "result line says what happened" "dbg cleanup-view" "Moved to the Trash: 3 sessions."
expect "the transcripts are in the (redirected) Trash" "$(ls "$MUYA_TRASH_DIR" | wc -l | tr -d ' ')" "3"
expect "old session 6 left Claude's folder" "$(ls "$P"/*/00000006-*.jsonl 2>&1)" "No such file"
expect "large session 9 left Claude's folder" "$(ls "$P"/*/00000009-*.jsonl 2>&1)" "No such file"
expect "old session 7 went too" "$(ls "$P"/*/00000007-*.jsonl 2>&1)" "No such file"
expect "the just-written large one stayed" "$(ls "$P"/*/0000000a-*.jsonl 2>&1 | wc -l | tr -d ' ')" "1"
dbg "cleanup-close" >/dev/null; sleep 0.5
wait_for "the list reloads without them" "dbg sessions-view" "status="
refuse "trashed sessions are gone from the list" "$(dbg sessions-view)" "00000006-bbbb"

echo "=== Scheduled prompt (one-shot, in memory)"
dbg "page schedules" >/dev/null; sleep 0.5
close_all
T1=$(newterm); sleep 2
expect "terminal is up" "$(dbg sessions)" "$T1"
dbg "sprompt-open" >/dev/null; sleep 0.4
dbg "sprompt-set prompt " >/dev/null
expect "an empty prompt is refused" "$(dbg sprompt-submit)" "error=Write the prompt to send first."
dbg "sprompt-set prompt echo SPROMPT-OK-\$((6*7))" >/dev/null
dbg "sprompt-set terminals nobody" >/dev/null
expect "no terminal is refused" "$(dbg sprompt-submit)" "error=Pick at least one terminal."
dbg "sprompt-set terminals $(dbg sessions | head -1 | cut -f2)" >/dev/null
dbg "sprompt-set in -30" >/dev/null
expect "a time in the past is refused" "$(dbg sprompt-submit)" "has already passed"
both mainwin pages-4e-scheduled-prompt
axaudit "scheduled prompt sheet"
dbg "sprompt-set in 4" >/dev/null
expect "schedule" "$(dbg sprompt-submit)" "ok"
expect "it waits" "$(dbg sprompt-state)" "pending=1"
refuse "nothing typed yet" "$(dbg text)" "SPROMPT-OK-42"
wait_for "at the time the prompt is typed and submitted" "dbg text" "SPROMPT-OK-42" 12
expect "it fired once" "$(dbg sprompt-state)" "fired=1 pending=0"
dbg "sprompt-set prompt later one" >/dev/null; dbg "sprompt-set in 900" >/dev/null; dbg sprompt-submit >/dev/null
dbg "sprompt-select 0" >/dev/null; dbg "sprompt-edit" >/dev/null
expect "edit loads it into the form" "$(dbg sprompt-view)" "submit=Save changes"
dbg "sprompt-set prompt edited one" >/dev/null; dbg sprompt-submit >/dev/null
expect "edit replaces it in place" "$(dbg sprompt-view)" "pending	edited one"
dbg "sprompt-delete" >/dev/null
expect "delete removes it" "$(dbg sprompt-state)" "pending=0"
dbg "sprompt-close" >/dev/null

echo "=== Auto-allow permission prompts"
dbg "settings-open" >/dev/null; dbg "settings-set autoApprove off" >/dev/null; dbg "settings-close" >/dev/null
dbg "type \"python3 -I $HOMEDIR/permission.py\\n\"" >/dev/null
wait_for "the daemon sees the prompt" "dbg sessions" "Needs permission" 8
sleep 4
expect "auto-allow off: nothing was answered" "$(dbg autoallow-state)" "allowed=0"
refuse "...and the program still waits" "$(dbg text)" "ANSWERED"
both mainwin pages-4e-permission-prompt
T0=$SECONDS
dbg "settings-open" >/dev/null; dbg "settings-set autoApprove on" >/dev/null; dbg "settings-close" >/dev/null
wait_for "turning it on answers the waiting prompt (Allow key 1)" "dbg text" "ANSWERED:1" 8
expect "counted once" "$(dbg autoallow-state)" "allowed=1"
dbg "type \"clear\\n\"" >/dev/null
wait_for "the answered prompt is gone from the screen" "dbg sessions" "~	Shell" 8
dbg "type \"python3 -I $HOMEDIR/permission.py\\n\"" >/dev/null
T1S=$(date +%s)
wait_for "a new prompt is answered by itself" "dbg autoallow-state" "allowed=2" 10
echo "     (answered $(( $(date +%s) - T1S )) s after the command was typed; the rule is 2 s after the prompt shows)"
dbg "settings-open" >/dev/null; dbg "settings-set autoApprove off" >/dev/null; dbg "settings-close" >/dev/null

echo "=== Settings: Open at login, licences"
dbg "settings-open" >/dev/null
SW=$(dbg settings-open); sleep 1
expect "the row exists" "$(dbg settings-rows)" "openAtLogin=off"
dbg "settings-set openAtLogin on" >/dev/null
# Prefs are written debounced (250 ms) on a private queue (a7f6e1e): wait for the value instead of reading the file at once.
wait_for "the pref is stored" "cat \"$HOMEDIR/Library/Application Support/MuyaNative/prefs.json\" | tr -d ' \\n'" '"openAtLogin":true' 8
expect "a throwaway HOME never registers a real login item (no error shown, value kept)" "$(dbg "settings-get openAtLogin")" "on"
dbg "settings-set openAtLogin off" >/dev/null
dbg "licences-open" >/dev/null; sleep 0.6
expect "licences are read from the bundle" "$(dbg licences-text)" "Third-party"
shot "$SW" pages-4e-settings-dark
dbg "appearance light" >/dev/null; sleep 1; shot "$SW" pages-4e-settings-light; dbg "appearance dark" >/dev/null
expect "in-app audit, licences sheet: no unlabelled control" "$(dbg 'ax-audit settings')" "unlabelled=0"
dbg "licences-close" >/dev/null
dbg "settings-set spotlightRoots $SPOT" >/dev/null
dbg "settings-close" >/dev/null

echo "=== Resume on launch"
dbg "settings-open" >/dev/null; dbg "settings-set resumeOnLaunch on" >/dev/null; dbg "settings-close" >/dev/null
dbg "page sessions" >/dev/null
wait_for "the open Claude session is remembered" "dbg resume-state" "saved=11111111-aaaa"
close_all
kill "$APP_PID" 2>/dev/null
for _ in $(seq 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.25; done
start_app; sleep 3
expect "the daemon came back empty: the saved Claude session was reopened" "$(dbg resume-state)" "resumed=Zebra live"
wait_for "...by typing claude --resume" "dbg text" "claude --resume '11111111-aaaa-4bbb-8ccc-000000000001'" 8
close_all
dbg "settings-open" >/dev/null; dbg "settings-set resumeOnLaunch off" >/dev/null; dbg "settings-close" >/dev/null
kill "$APP_PID" 2>/dev/null
for _ in $(seq 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.25; done
start_app; sleep 3
expect "setting off: nothing is reopened" "$(dbg resume-state)" "resumed= "
expect "...and no terminal exists" "$(dbg sessions | grep -c .)" "0"
MIG=$(dbg migration-state) # an old daemon answers "unsupported"; the current muyad runs it and answers "done"
case "$MIG" in *unsupported*|*done*) echo "PASS first-launch migration: unsupported (old daemon) or done (current daemon) is not an error: $MIG" | head -1 ;; *) echo "FAIL first-launch migration: got '$MIG'"; FAILS=$((FAILS + 1)) ;; esac

echo "=== schedules-changed event instead of polling"
dbg "page schedules" >/dev/null; sleep 4
E0=$(dbg sched-events)
expect "no daemon event yet: the fallback poll runs" "$E0" "events=0"
refuse "...it has polled" "$E0" "pollReloads=0"
dbg "sched-new" >/dev/null
dbg "sched-set name Event test" >/dev/null; dbg "sched-set prompt say hi" >/dev/null
dbg "sched-set folder $HOMEDIR/work/report" >/dev/null; dbg "sched-set kind interval" >/dev/null; dbg "sched-set minutes 60" >/dev/null
dbg sched-save >/dev/null
wait_for "the daemon event arrives and reloads the page at once" "dbg sched-events" "eventReloads=1" 5
P0=$(dbg sched-events | sed -n 's/.*pollReloads=\([0-9]*\).*/\1/p')
dbg "sched-run Event test" >/dev/null
wait_for "a run updates the page via events" "dbg sched-view" "runs=1" 15
sleep 7
P1=$(dbg sched-events | sed -n 's/.*pollReloads=\([0-9]*\).*/\1/p')
expect "once events flow the poll stays quiet (no poll reloads in 7 s)" "$P1" "$P0"
dbg "sched-delete Event test" >/dev/null

echo "=== Command palette: files on this Mac (chosen folders only)"
mkdir -p "$SPOT/docs"; echo "x" > "$SPOT/docs/quokkaprobe-report.txt"
end=$((SECONDS + 90)); idx=0
while [ $SECONDS -lt $end ]; do [ -n "$(mdfind -onlyin "$SPOT" "kMDItemFSName == '*quokkaprobe*'")" ] && { idx=1; break; }; sleep 2; done
if [ $idx -eq 0 ]; then echo "SKIP spotlight: the throwaway folder was not indexed within 90 s"; else
  dbg "page none" >/dev/null; dbg "palette-shortcut" >/dev/null
  dbg "palette-query quokkaprobe" >/dev/null
  wait_for "the file is found, in its own group" "dbg palette-state" "Files on this Mac	quokkaprobe-report.txt"
  expect "location shown" "$(dbg palette-state)" "$SPOT/docs"
  both mainwin pages-4e-palette-files
  dbg "palette-run file:$SPOT/docs/quokkaprobe-report.txt" >/dev/null; sleep 1
  dbg "palette-shortcut" >/dev/null
  dbg "settings-open" >/dev/null; dbg "settings-set spotlightRoots /nonexistent-root" >/dev/null; dbg "settings-close" >/dev/null
  dbg "palette-query quokkaprobe" >/dev/null; sleep 3
  refuse "no existing chosen folder: no file results at all" "$(dbg palette-state)" "Files on this Mac"
  dbg "settings-open" >/dev/null; dbg "settings-set spotlightRoots /Users/Shared/not-the-folder" >/dev/null; dbg "settings-close" >/dev/null
  dbg "palette-query quokkaprobe" >/dev/null; sleep 3
  # The file was opened above, so the palette's "open" (recent) group still offers it by design (adad8a2); what must not
  # happen is a Spotlight result: no "Files on this Mac" group for a folder outside the chosen roots.
  refuse "a folder outside the chosen roots is never searched (no Files on this Mac group)" "$(dbg palette-state)" "Files on this Mac"
  expect "the opened file is offered only as a recent 'open' entry" "$(dbg palette-state)" "quokkaprobe-report"
  dbg "palette-close" >/dev/null
fi
axaudit "palette / main window"

echo
[ $FAILS -eq 0 ] && echo "ALL PASS" || echo "$FAILS FAILED"
exit $FAILS
