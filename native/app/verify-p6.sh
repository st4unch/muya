#!/usr/bin/env bash
# P6 check: Review changes in the REAL app against a dev stack (throwaway HOME, own sockets/state dir) with a
# SYNTHETIC repo: branch `feat` with 5 changed files vs main (and one uncommitted edit). Opens the dialog from the
# Inspector, presses ] and [ as real key events, checks the footer / file / header counts after each, and takes
# dark + light screenshots. The branch review reads through muyad (git.branch_detail, git.branch_file_pair).
set -uo pipefail
cd "$(dirname "$0")"
# Own state dir: run-dev.sh keeps its PID file and dev dirs under $TMPDIR, so other workers' stacks are never
# seen or stopped. Only a stack left by an earlier run of THIS script (same dir) is cleaned up.
export TMPDIR=$(mktemp -d /tmp/muya-p6.XXXXXX)  # its own dir per run: a fixed one collides with another dev stack / a leftover
mkdir -p "$TMPDIR"
SHOTS=$PWD/screenshots
STATE=$TMPDIR/muya-native-dev.state
if [ -f "$STATE" ]; then ./run-dev.sh stop >/dev/null 2>&1 || true; fi
MUYA_DEV_NO_APP=1 ./run-dev.sh start >/dev/null || exit 1
. "$STATE"
trap './run-dev.sh stop >/dev/null 2>&1' EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
REPO=$DEV/home/projects/review-demo
mkdir -p "$REPO/src" "$REPO/docs" "$REPO/old" && cd "$REPO"
g() { git -c user.name=demo -c user.email=demo@example.invalid -c commit.gpgsign=false "$@"; }
git init -q -b main
printf 'func parse(_ s: String) -> Token? {\n    let tokens = lex(s)\n    return tokens.first\n}\n' > src/parser.swift
printf '# Demo\n\nTerminal.\n' > README.md
printf '// legacy shim\nfunc old() {}\nfunc older() {}\n' > old/legacy.swift
printf 'one\ntwo\nthree\n' > docs/notes.md
g add . && g commit -q -m "base"
git checkout -q -b feat
printf 'func parse(_ s: String) -> Token? {\n    let tokens = lex(s)\n    guard let first = tokens.first else { return nil }\n    return first.value\n}\n' > src/parser.swift
printf 'struct Lexer {\n    let text: String\n    func next() -> Token? { nil }\n}\n' > src/lexer.swift
printf '# Demo\n\nA native terminal for parallel Claude sessions.\n' > README.md
git rm -q old/legacy.swift
printf 'one\nTWO\nthree\nfour\n' > docs/notes.md
g add . && g commit -q -m "feat: parser guard, lexer, notes"
printf 'func parse(_ s: String) -> Token? {\n    let tokens = lex(s)\n    guard let first = tokens.first else { return nil }\n    return first.value ?? ""\n}\n' > src/parser.swift
cd "$OLDPWD"
FAILS=0
dbg() { printf '%s\n' "$1" | nc -U -w 5 "$DEV/app-debug.sock"; }
shot() { screencapture -x -o -l "$1" "$SHOTS/$2.png"; echo "shot $2"; }
ok() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: wanted [$3] got [$2]"; FAILS=$((FAILS+1)); fi; }
has() { case "$2" in *"$3"*) echo "PASS $1";; *) echo "FAIL $1: wanted [$3] in [$2]"; FAILS=$((FAILS+1));; esac; }

./run-dev.sh app >/dev/null; . "$STATE"; sleep 2.5
dbg "sessions" | while IFS=$'\t' read -r id _; do [ -n "$id" ] && dbg "close $id" >/dev/null; done
dbg "new $REPO" >/dev/null
sleep 3
dbg "inspector-tab changes" >/dev/null; sleep 4   # the pane polls git; the daemon owns the session folder
W=$(dbg windowid)

# 1. Branch review, through muyad.
ok "open branch review" "$(dbg 'review-open branch')" "ok"; sleep 3
S=$(dbg review-state); echo "state: $S"
has "starts on file 1 of 5" "$S" "index=0 footer=File 1 of 5"
has "badges: modified, modified, deleted (git rm), added, modified" "$S" "codes=MMDAM"
H=$(dbg review-header); echo "header: $H"
has "header shows counts of the shown file" "$H" "+"
dbg "appearance dark" >/dev/null; sleep 1; shot "$W" "p6-review-dark"
ok "key ]" "$(dbg 'review-key ]')" "ok"; sleep 1.5
S=$(dbg review-state); has "] moved to file 2" "$S" "index=1 footer=File 2 of 5"
H2=$(dbg review-header); echo "header after ]: $H2"
[ "$H" != "$H2" ] && echo "PASS header follows the file" || { echo "FAIL header did not change"; FAILS=$((FAILS+1)); }
dbg "review-key ]" >/dev/null; sleep 1; dbg "review-key ]" >/dev/null; sleep 1
S=$(dbg review-state); has "] x3 → file 4" "$S" "index=3 footer=File 4 of 5"
dbg "review-key [" >/dev/null; sleep 1
S=$(dbg review-state); has "[ went back to file 3" "$S" "index=2 footer=File 3 of 5"
dbg "appearance light" >/dev/null; sleep 1; shot "$W" "p6-review-light"
for _ in 1 2 3 4 5 6; do dbg "review-key ]" >/dev/null; done; sleep 1
S=$(dbg review-state); has "] stops at the last file" "$S" "index=4 footer=File 5 of 5"
for _ in 1 2 3 4 5 6; do dbg "review-key [" >/dev/null; done; sleep 1
S=$(dbg review-state); has "[ stops at the first file" "$S" "index=0 footer=File 1 of 5"
dbg "review-close" >/dev/null; sleep 1
ok "sheet closed" "$(dbg review-state)" "none"

# 2. Working-tree review (local reads: the uncommitted edit).
ok "open working review" "$(dbg 'review-open working')" "ok"; sleep 2
S=$(dbg review-state); has "working tree has its file" "$S" "src/parser.swift"
dbg "review-close" >/dev/null
tail -3 "$DEV/muyad.log" 2>/dev/null | sed 's/^/muyad: /'
echo "fails=$FAILS"; exit $FAILS
