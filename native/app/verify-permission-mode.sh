#!/usr/bin/env bash
# Default permission mode against the real app (throwaway stack, fake HOME, own sockets; kills only what it started):
#   1 a fresh profile (no stored mode): every start path types --permission-mode auto
#   (the split fork needs a running real Claude for the app to detect it; it is covered by unit tests)
#   2 Settings > Default permission mode = Bypass: New agent sheet, resume, agent open_session, ⌘⇧C, fork (split), Resources
#     create (the six start paths minus the split fork) all carry --dangerously-skip-permissions; a one-off pick in the sheet is not written back
#   3 the same with Manual: --permission-mode manual everywhere
#   4 the setting survives an app restart
# The sheet command comes from `newagent-state`; every other command is read from what the shell really received
# (the selected terminal's screen: the typed command line is echoed before anything runs).
# Exit = number of failures.
set -uo pipefail
cd "$(dirname "$0")"
./build.sh >/dev/null 2>&1 || { echo "FAIL build"; exit 1; }
WORK=$(mktemp -d /tmp/muya-pm.XXXXXX)
export TMPDIR=$WORK
STATE=$WORK/muya-native-dev.state
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
./run-dev.sh start >/dev/null || exit 1
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
wait_app() { for _ in $(seq 100); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done; }
wait_app
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1: [$2] has [$3]" ;; *) ok "$1" ;; esac; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
HOMEDIR=$DEV/home
PREFS="$HOMEDIR/Library/Application Support/MuyaNative/prefs.json"
python3 -I make-pages-fixtures.py "$HOMEDIR" 4 >/dev/null
mkdir -p "$HOMEDIR/proj"
BYPASS="--dangerously-skip-permissions"

# `claude` in the throwaway HOME is a logger: it records the argv the shell really ran it with (the typed command line).
mkdir -p "$HOMEDIR/.local/bin"
LOG=$HOMEDIR/claude-argv.log
: > "$LOG"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" | cut -c1-160 >> "%s"\n[ "$1" = "--hold" ] && sleep 120\nexit 0\n' "$LOG" > "$HOMEDIR/.local/bin/claude"
chmod +x "$HOMEDIR/.local/bin/claude"

newshell() { local out id; out=$(dbg "new $HOMEDIR/proj"); id=$(echo "$out" | awk '{print $2}'); dbg "select $id" >/dev/null; sleep 1.2; echo "$id"; }
sheet_cmd() { dbg newagent-state | sed -n 's/.*command=\(.*\) error=.*/\1/p'; }
# argv lines `claude` was run with since the mark.
mark() { wc -l < "$LOG" | tr -d ' '; }
since() { tail -n +$(($1 + 1)) "$LOG"; }
openset() { dbg settings-open >/dev/null; sleep 0.5; dbg settings-close >/dev/null; }

# One full pass: $1 = label, $2 = flag every path must carry, $3 = a flag that must NOT appear.
pass() {
  local label=$1 flag=$2 other=$3 id s m before
  echo "== $label ($flag)"
  # New agent sheet: opens on the stored mode
  dbg newagent-open >/dev/null; sleep 0.5
  has "$label: the New agent sheet opens on the stored mode" "$(sheet_cmd)" "$flag"
  # a one-off pick in the sheet changes its command, never the setting
  before=$(dbg "settings-get permissionMode")
  dbg "newagent-set mode Plan" >/dev/null
  has "$label: picking Plan in the sheet changes its command" "$(sheet_cmd)" "--permission-mode plan"
  dbg newagent-close >/dev/null; sleep 0.3
  check "$label: the one-off pick did not write the setting back" "$(dbg "settings-get permissionMode")" "$before"
  dbg newagent-open >/dev/null; sleep 0.5
  has "$label: the sheet reopens on the stored mode, not Plan" "$(sheet_cmd)" "$flag"
  dbg newagent-close >/dev/null; sleep 0.3

  # Command-shift-C in a terminal
  newshell >/dev/null; m=$(mark)
  dbg "p3-key cmd+shift+c" >/dev/null; sleep 1.5
  s=$(since "$m")
  check "$label: cmd-shift-C ran claude with the stored mode" "$s" "$flag"

  # Resume of a session (Sessions page)
  m=$(mark)
  dbg "page sessions" >/dev/null; sleep 0.8
  dbg "sessions-reload" >/dev/null; sleep 0.8
  dbg "sessions-resume 00000000" >/dev/null; sleep 2
  dbg "page none" >/dev/null; sleep 0.4
  s=$(since "$m")
  has "$label: resume ran claude --resume" "$s" "--resume 00000000"
  has "$label: resume carries the stored mode" "$s" "$flag"
  lacks "$label: resume does not carry the other mode" "$s" "$other"

  # An agent opens a session (MCP open_session)
  m=$(mark)
  dbg "split-open {\"name\":\"w-$label\",\"cwd\":\"$HOMEDIR/proj\",\"unattended\":false}" >/dev/null; sleep 2
  s=$(since "$m")
  check "$label: agent open_session follows the setting" "$s" "$flag --name w-$label"

  # Resources "Create with Claude"
  m=$(mark)
  dbg "resources-create Skill|hello" >/dev/null 2>&1; sleep 2
  s=$(since "$m")
  has "$label: Resources create follows the setting" "$s" "$flag You are a Claude Code skill author"
}

echo "== fresh profile: no stored mode"
openset
if [ -f "$PREFS" ]; then check "no permissionMode in the prefs file" "$(grep -c permissionMode "$PREFS")" "0"; else ok "no prefs file at all"; fi
check "Settings shows Auto with nothing stored" "$(dbg "settings-get permissionMode")" "Auto"
pass fresh "--permission-mode auto" "$BYPASS"

echo "== Settings: Bypass"
check "settings-set Bypass" "$(dbg 'settings-set permissionMode Bypass permissions')" "ok"
check "the setting reads back" "$(dbg "settings-get permissionMode")" "Bypass permissions"
pass bypass "$BYPASS" "--permission-mode auto"

echo "== Settings: Manual"
check "settings-set Manual" "$(dbg 'settings-set permissionMode Manual')" "ok"
pass manual "--permission-mode manual" "$BYPASS"

echo "== Restart keeps the setting"
dbg "settings-set permissionMode Bypass permissions" >/dev/null
sleep 2.5   # prefs.json is written after a debounce
grep -q '"permissionMode" *: *"bypass"' "$PREFS" && ok "prefs.json holds bypass" || bad "prefs.json lacks bypass: $(cat "$PREFS" 2>/dev/null | head -c 300)"
kill "$APP_PID" 2>/dev/null; sleep 1.5
./run-dev.sh app >/dev/null; . "$STATE"
wait_app; sleep 2; openset
check "the setting survived the restart" "$(dbg "settings-get permissionMode")" "Bypass permissions"
dbg newagent-open >/dev/null; sleep 0.5
has "the sheet after a restart opens on Bypass" "$(sheet_cmd)" "$BYPASS"
dbg newagent-close >/dev/null

echo "verify-permission-mode: $fails failure(s)"
exit "$fails"
