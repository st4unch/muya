#!/usr/bin/env bash
# Terminal colour schemes, find (⌘F), Paste as Path, Clear Scrollback and the footer's status fields, on a REAL daemon + app
# in a throwaway HOME (run-dev.sh): a shell prints 300 rows, the app finds / selects / pastes / clears, the scheme survives an app
# restart, and the status JSON a "Claude" wrote into MUYA_STATUS_FILE shows in the footer.
#   TMPDIR=<private dir> MUYA_BIN_DIR=<dir with muya-ptyd + muyad> native/app/verify-term-features.sh
set -euo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-tf.XXXXXX)  # its own dir per run: the default /tmp state file collides with any other running dev stack
STATE=${TMPDIR:-/tmp}/muya-native-dev.state
./run-dev.sh start >/dev/null
trap './run-dev.sh stop >/dev/null' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock" || true; }
for _ in $(seq 40); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid)" ] && break; sleep 0.5; done
fail=0
expect() { # label, actual, substring
  if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: wanted '$3' in '$2'"; fail=$((fail + 1)); fi
}
dbg "window 1120 732" >/dev/null
dbg "new" >/dev/null; sleep 2
dbg 'type "for i in $(seq 1 300); do echo \"row-$i Alpha beta\"; done\n"' >/dev/null; sleep 3

# find
r=$(dbg "term-find ALPHA"); expect "find: 301 case-insensitive matches over the scrollback" "$r" "matches=301"
expect "find: the current match is selected" "$r" "selected=Alpha"
c0=$(dbg "term-find ALPHA"); c1=$(dbg "term-find next"); c2=$(dbg "term-find prev")
[[ "$c1" != "$c0" ]] && echo "ok   find: next moves" || { echo "FAIL find: next did not move"; fail=$((fail + 1)); }
[[ "$c2" == "$c0" ]] && echo "ok   find: previous returns to the first match" || { echo "FAIL find: prev: $c2 vs $c0"; fail=$((fail + 1)); }
r=$(dbg "term-find row-42 "); expect "find: one row-42" "$r" "matches=1"
dbg "term-find close" >/dev/null

# context menu
expect "menu lists Paste as Path, Find and Clear Scrollback" "$(dbg term-menu)" "Paste as Path|"
expect "menu: Find… and Clear Scrollback" "$(dbg term-menu)" "Find…    ⌘F|Clear Scrollback"

# paste as path
dbg 'term-paste-path /tmp/My Files/x (1).txt\n' >/dev/null; sleep 0.6
expect "paste as path: spaces and brackets backslashed, newline not run" "$(dbg text)" '/tmp/My\ Files/x\ \(1\).txt'
dbg "key ctrl-u" >/dev/null || true

# clear scrollback
expect "clear scrollback empties the history" "$(dbg term-clear-scrollback)" "after=0"

# colour schemes: set, persisted in the prefs, kept over an app restart
expect "scheme dracula applies" "$(dbg 'terminal-scheme dracula')" "bg=282a36"
kill "$APP_PID"; sleep 1; ./run-dev.sh app >/dev/null; . "$STATE"; for _ in $(seq 40); do [ -n "$(dbg windowid)" ] && break; sleep 0.5; done; sleep 1
expect "scheme survives an app restart" "$(dbg terminal-scheme)" "scheme=dracula"
expect "every scheme is accepted" "$(for s in nord one-dark tokyo-night gruvbox-dark solarized-dark solarized-light github-light muya; do dbg "terminal-scheme $s"; done | tail -1)" "scheme=muya"

# status fields: the status JSON the Claude tap writes into MUYA_STATUS_FILE
dbg "new" >/dev/null; sleep 2
dbg 'type "printf %s '"'"'{\"model\":{\"display_name\":\"Opus\"},\"context_window\":{\"used_percentage\":42.4,\"total_input_tokens\":16900},\"cost\":{\"total_cost_usd\":1.239}}'"'"' > $MUYA_STATUS_FILE\n"' >/dev/null; sleep 1.5
dbg "status-fields model.display_name,context_window.used_percentage,context_window.total_input_tokens,cost.total_cost_usd,session_id" >/dev/null; sleep 2.5
f=$(dbg status-footer)
expect "footer shows the real model" "$f" "Model=Opus"
expect "footer shows context used" "$f" "Context used=42%"
expect "footer shows input tokens" "$f" "Input tokens=16.9k"
expect "footer shows the cost" "$f" "Cost=\$1.24"
[[ "$f" != *"Session id"* ]] && echo "ok   a field the data lacks is hidden" || { echo "FAIL missing field shown: $f"; fail=$((fail + 1)); }
[ "$fail" = 0 ] && echo "verify-term-features: all passed" || { echo "verify-term-features: $fail failures"; exit 1; }
