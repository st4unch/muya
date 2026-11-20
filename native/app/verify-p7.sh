#!/usr/bin/env bash
# P7 check in the REAL app against a dev stack (throwaway HOME): Resources page (local lists, file text, search,
# marketplace, plugin install through a fake `claude` in the temp HOME) and the slash popover, dark + light shots.
set -uo pipefail
cd "$(dirname "$0")"
export TMPDIR=$(mktemp -d /tmp/muya-p7.XXXXXX)  # its own dir per run: a fixed one collides with another dev stack / a leftover
export SHELL=/usr/bin/false
export PATH=/usr/bin:/bin:/usr/sbin:/sbin # no real claude: the plugin install must use the fake in the temp HOME
mkdir -p "$TMPDIR"
SHOTS=${SHOTS:-$PWD/screenshots}
STATE=$TMPDIR/muya-native-dev.state
if [ -f "$STATE" ]; then ./run-dev.sh stop >/dev/null 2>&1 || true; fi
MUYA_DEV_NO_APP=1 ./run-dev.sh start >/dev/null || exit 1
. "$STATE"
trap './run-dev.sh stop >/dev/null 2>&1' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
H=$DEV/home
mkdir -p "$H/.claude/skills/review" "$H/.claude/skills/deploy-helper" "$H/.claude/agents" "$H/.claude/hooks" "$H/.claude/commands" "$H/.local/bin"
printf -- '---\nname: review\ndescription: Review code\n---\n# Review\nCheck the diff.\n' > "$H/.claude/skills/review/skill.md"
printf '# Deploy helper\n' > "$H/.claude/skills/deploy-helper/README.md"
printf -- '---\nname: helper\n---\nHelps.\n' > "$H/.claude/agents/helper.md"
printf '#!/bin/sh\necho hook\n' > "$H/.claude/hooks/pre-tool.sh"
printf '{"mcpServers":{"files":{"command":"npx","description":"Reads folders"}}}' > "$H/.claude/.mcp.json"
printf -- '---\ndescription: Ship it\n---\nship\n' > "$H/.claude/commands/ship.md"
cat > "$H/.local/bin/claude" <<'F'
#!/bin/sh
case "$1" in agents) echo '[]';; plugin) [ "$2" = "--help" ] && exit 0; echo "$@" >> "$HOME/plugin.log";; *) exit 1;; esac
F
chmod +x "$H/.local/bin/claude"
printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$H/.zprofile"
cat > "$H/.local/bin/claude" <<'F'
#!/bin/sh
case "$1" in agents) echo '[]';; plugin) [ "$2" = "--help" ] && exit 0; echo "$@" >> "$HOME/plugin.log";; *) printf '%s' "$1" > "$HOME/create.log";; esac
F
FAILS=0
dbg() { printf '%s\n' "$1" | nc -U -w 20 "$DEV/app-debug.sock"; }
shot() { screencapture -x -o -l "$1" "$SHOTS/$2.png"; echo "shot $2"; }
has() { case "$2" in *"$3"*) echo "PASS $1";; *) echo "FAIL $1: wanted [$3] in [$2]"; FAILS=$((FAILS+1));; esac; }
./run-dev.sh app >/dev/null; . "$STATE"; sleep 2.5
W=$(dbg windowid)
dbg "appearance dark" >/dev/null
dbg "resources-open skills" >/dev/null; sleep 1.5
S=$(dbg resources-state); echo "$S"; has "two skills listed" "$S" "skills=2"; has "agents/hooks/mcps counted" "$S" "agents=1 hooks=1 mcps=1"
dbg "resources-select 0" >/dev/null; sleep 0.5
has "skill text shown" "$(dbg resources-state)" "file="
shot "$W" "p7-resources-dark"
dbg "appearance light" >/dev/null; sleep 1; shot "$W" "p7-resources-light"
dbg "resources-query rev" >/dev/null; sleep 0.5; has "search narrows skills" "$(dbg resources-state)" "skills=1"
dbg "resources-query " >/dev/null
dbg "resources-open mcps" >/dev/null; sleep 0.5; has "mcp listed" "$(dbg resources-state)" "mcps=1"
dbg "resources-open marketplace" >/dev/null; sleep 6
dbg "resources-install-plugin" >/dev/null; sleep 5
S=$(dbg resources-state); echo "$S"; has "plugin installed via fake claude" "$S" "plugin=ok:muya-mcp plugin installed."
has "claude got both plugin commands" "$(cat "$H/plugin.log" 2>/dev/null | tr '\n' '|')" "plugin marketplace add st4unch/muya|plugin install muya-mcp@muya|"
dbg "appearance dark" >/dev/null; sleep 1; shot "$W" "p7-marketplace-dark"
dbg "appearance light" >/dev/null; sleep 1; shot "$W" "p7-marketplace-light"
dbg "view none" >/dev/null
# Create with Claude: the wrapped request reaches `claude` as ONE argument, quotes and $(...) intact
dbg "resources-create Skill|make it's a \$(touch $H/pwned) skill" >/dev/null; sleep 4
C=$(cat "$H/create.log" 2>/dev/null)
has "create: claude got the skill-author wrapper" "$C" "Claude Code skill author"
has "create: request arrived verbatim" "$C" "User request: make it's a \$(touch $H/pwned) skill"
[ -e "$H/pwned" ] && { echo "FAIL create: the request ran as a command"; FAILS=$((FAILS+1)); } || echo "PASS create: nothing in the request ran"
dbg "slash-open" >/dev/null; sleep 1.5
S=$(dbg slash-state); echo "$S"; has "built-ins + custom command" "$S" "groups=builtin,"
dbg "appearance dark" >/dev/null; sleep 0.5; shot "$W" "p7-slash-dark"
dbg "slash-type ship" >/dev/null; has "filter finds ship" "$(dbg slash-state)" "selected=ship"
dbg "slash-key esc" >/dev/null; has "esc closes" "$(dbg slash-state)" "open=false"
dbg "slash-open" >/dev/null; sleep 0.5; dbg "appearance light" >/dev/null; sleep 0.5; shot "$W" "p7-slash-light"
dbg "slash-key down" >/dev/null; has "down moves" "$(dbg slash-state)" "index=1"
dbg "slash-key esc" >/dev/null
echo "fails=$FAILS"; exit $FAILS
