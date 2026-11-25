#!/usr/bin/env bash
# SSH parity e2e: the Native dev build + muyad in a throwaway HOME against three docker sshd containers
# (password / key / PSMP-like gateway). UI path: debug-socket "ssh-connect" (what pressing Connect does).
# Agent path: the real muya-ssh-mcp sidecar -> muyad broker (ssh_open, ssh_send, ssh_run, ssh_session_*, ssh_scp).
# Throwaway fake credentials only; the real vault, ~/.ssh and running Muya are never touched. Needs a GUI session + docker.
#
#   native/scripts/e2e-ssh/run.sh [ui|agent|all]      (default all)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NATIVE=$(cd "$HERE/../.." && pwd)
APP=$NATIVE/app
ROOT=$(cd "$NATIVE/.." && pwd)
SIDECAR=${SIDECAR:-$ROOT/src-tauri/target/debug/muya-ssh-mcp}
WHAT=${1:-all}
# Short on purpose: ssh ControlPath (HOME/.claude/muya-cm/<pid>/<hash>) must stay under 104 bytes in the fake HOME.
export TMPDIR=$(mktemp -d /tmp/e.XXX)
SHOTS=${SHOTS:-$TMPDIR/shots}; mkdir -p "$SHOTS"
export MUYA_TEST_MASTER='e2e master phrase'
export E2E_TARGET_PW='tgt-Pw-93kd' E2E_VAULT_PW='vlt-Pw-17xq' E2E_OTP=246810
LEAK_WORDS=("$E2E_TARGET_PW" "$E2E_VAULT_PW" "$MUYA_TEST_MASTER")
FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
expect() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1: wanted '$3' in: ${2:0:300}"; fi; }
refute() { if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1: found '$3'"; fi; }
cleanup() {
  (cd "$APP" && ./run-dev.sh stop >/dev/null 2>&1) ; (cd "$HERE" && docker compose down -v >/dev/null 2>&1)
  rm -rf "$TMPDIR"
}
trap cleanup EXIT; trap 'exit 130' INT TERM

# ---- docker + key
KEYDIR=$TMPDIR/keys; mkdir -p "$KEYDIR"; ssh-keygen -q -t ed25519 -N '' -f "$KEYDIR/id" -C e2e
export E2E_PUBKEY=$(cat "$KEYDIR/id.pub")
(cd "$HERE" && docker compose up -d --build >/dev/null 2>&1) || { echo "docker compose failed"; exit 1; }
for p in 2201 2202 2203; do for _ in $(seq 30); do nc -z 127.0.0.1 $p 2>/dev/null && break; sleep 0.5; done; done

# ---- dev stack in a fake HOME
bash "$NATIVE/scripts/test-classic-vault.sh" >/dev/null 2>&1 || true
CLASSIC=$NATIVE/tools/classic-vault/target/debug/classic-vault
[ -x "$CLASSIC" ] || { echo "classic-vault helper missing"; exit 1; }
MUYAD_ARGS="--broker" "$APP/run-dev.sh" start >/dev/null || { echo "dev stack failed"; exit 1; }
. "$TMPDIR/muya-native-dev.state"
H=$DEV/home; mkdir -p "$H/.claude"
dbg() { printf '%s\n' "$1" | nc -U -w 8 "$DEV/app-debug.sock"; }
HOSTKEY="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
# The dev HOME is too long for the ssh ControlPath Muya derives from it (104-byte socket limit); direct servers get a short one.
CM="-o ControlPath=/tmp/cm-$$-%C"
HOME=$H "$CLASSIC" init >/dev/null 2>&1; HOME=$H "$CLASSIC" add target-pw "$E2E_TARGET_PW" >/dev/null 2>&1; HOME=$H "$CLASSIC" add vault-pw "$E2E_VAULT_PW" >/dev/null 2>&1
# The agent resolves a server's stored credential by its id (classic stores the id), so the config names ids.
IDS=$(HOME=$H "$CLASSIC" ids); TID=$(echo "$IDS" | sed -n 's/^target-pw=//p'); VID=$(echo "$IDS" | sed -n 's/^vault-pw=//p')
cat > "$H/.claude/muya-ssh-config.json" <<JSON
{"version":1,
 "servers":[
  {"id":"s-direct","label":"E2E Direct","host":"127.0.0.1","port":2201,"username":"dba","connectionType":"direct","credentialSource":{"kind":"local","localCredId":"$TID"},"agentAccess":true,"sshOptions":"$HOSTKEY $CM"},
  {"id":"s-key","label":"E2E Key","host":"127.0.0.1","port":2202,"username":"keyuser","connectionType":"direct","credentialSource":{"kind":"local","localCredId":"$TID"},"agentAccess":true,"sshOptions":"-i $KEYDIR/id -o IdentitiesOnly=yes -o BatchMode=yes $HOSTKEY $CM"},
  {"id":"s-psmp","label":"E2E PSMP","host":"ssh-pw","port":22,"username":"dba","connectionType":"psmp","psmpProfileId":"p1","credentialSource":{"kind":"local","localCredId":"$VID"},"agentAccess":true,"sshOptions":"-p 2203 $HOSTKEY"}],
 "psmpProfiles":[{"id":"p1","label":"Sim PSMP","psmpAddress":"127.0.0.1","vaultUser":"vaultuser"}]}
JSON
sleep 3; for _ in 1 2 3 4 5; do [[ "$(dbg "rail SSH")" == ok* ]] && break; sleep 1; done; sleep 1
dbg "ssh-section vault" >/dev/null; sleep 1
dbg "ssh-unlock" >/dev/null; sleep 1
dbg "ssh-form set master $MUYA_TEST_MASTER" >/dev/null; dbg "ssh-form submit" >/dev/null
for _ in $(seq 40); do [[ "$(dbg ssh-state)" == *"rows=2"* ]] && break; sleep 0.5; done
expect "vault unlocked in the app" "$(dbg ssh-state)" "rows=2"
dbg "ssh-section servers" >/dev/null; sleep 1

shot() { screencapture -x -o -l "$(dbg windowid)" "$SHOTS/$1.png" 2>/dev/null; }
screen_of() { dbg "select $1" >/dev/null; sleep 0.5; dbg text; }
wait_text() { local id=$1 want=$2; for _ in $(seq 40); do [[ "$(screen_of "$id")" == *"$want"* ]] && return 0; sleep 0.5; done; return 1; }
last_session() { dbg sessions | tail -1 | cut -f1 | tr -d '*'; }
no_leak() { for w in "${LEAK_WORDS[@]}"; do refute "$1 has no secret" "$2" "$w"; done; }

ui_case() { # title marker [typed OTP]
  local title=$1 marker=$2 otp=${3:-}
  local before; before=$(dbg sessions | grep -c .)
  dbg "ssh-connect $title" >/dev/null
  for _ in $(seq 40); do [[ $(dbg sessions | grep -c .) -gt $before ]] && break; sleep 0.5; done
  local id; id=$(dbg sessions | tail -1 | cut -f1)
  expect "ui[$title]: a terminal tab opened" "$(dbg sessions)" "$title"
  if [ -n "$otp" ]; then
    wait_text "$id" "RADIUS passcode" && pass "ui[$title]: challenge shown, password NOT injected" || fail "ui[$title]: no challenge prompt"
    dbg "type \"$otp\\n\"" >/dev/null
  fi
  dbg "select $id" >/dev/null; sleep 6
  dbg "type \"echo $marker-\$(whoami)\\n\"" >/dev/null
  if wait_text "$id" "$marker-"; then pass "ui[$title]: logged in, command ran"; else fail "ui[$title]: no login proof"; echo "---screen:"; dbg text | tail -8; fi
  local txt; txt=$(dbg text); shot "ui-$(echo "$title" | tr ' ' '-')"
  no_leak "ui[$title] screen" "$txt"
  dbg "close $id" >/dev/null
}

if [[ $WHAT == ui || $WHAT == all ]]; then
  echo "--- UI path (Connect button)"
  ui_case "E2E Direct" "UIDIRECT"
  ui_case "E2E Key" "UIKEY"
  ui_case "E2E PSMP" "UIPSMP"
  # PSMP with a typed RADIUS challenge: the daemon must WITHHOLD the vault password; the person types the OTP.
  (cd "$HERE" && E2E_CHALLENGE=1 docker compose up -d psmp >/dev/null 2>&1); sleep 4
  ui_case "E2E PSMP" "UIPSMPOTP" "$E2E_OTP"
  (cd "$HERE" && E2E_CHALLENGE=0 docker compose up -d psmp >/dev/null 2>&1); sleep 4
  no_leak "muyad log" "$(cat "$DEV/muyad.log" 2>/dev/null)"; no_leak "app log" "$(cat "$DEV/app.log" 2>/dev/null)"
fi

if [[ $WHAT == agent || $WHAT == all ]]; then
  # The UI phase left ControlMaster sockets for the direct servers; a persistent agent session needs a fresh connection
  # (it waits for ssh's password prompt before probing the shell), so close them first.
  for f in /tmp/cm-$$-*; do [ -S "$f" ] && ssh -O exit -o ControlPath="$f" x >/dev/null 2>&1; done
  echo "--- Agent path (muya-ssh-mcp sidecar -> muyad broker)"
  [ -x "$SIDECAR" ] || { fail "sidecar missing: cargo build --bin muya-ssh-mcp in src-tauri"; }
  export HOME=$H
  # scp gets no -o from the agent (hard rule), so it needs a known_hosts entry and a default identity in the (fake) HOME.
  mkdir -p "$H/.ssh"; chmod 700 "$H/.ssh"; cp "$KEYDIR/id" "$H/.ssh/id_ed25519"; chmod 600 "$H/.ssh/id_ed25519"
  for p in 2201 2202; do ssh-keyscan -p $p 127.0.0.1 2>/dev/null >> "$H/.ssh/known_hosts"; done
  echo "known_hosts lines: $(wc -l < "$H/.ssh/known_hosts") ($(cut -d" " -f1 "$H/.ssh/known_hosts" | sort -u | tr "\n" " "))"
  ROOT_DIR=$TMPDIR/ws; mkdir -p "$ROOT_DIR"
  python3 "$HERE/rpc_call.py" "$DEV/muyad.sock" workspace.set_roots "{\"roots\":[\"$ROOT_DIR\"]}" >/dev/null
  out=$(E2E_ROOT="$ROOT_DIR" E2E_SECRETS="$E2E_TARGET_PW"$'\x1f'"$E2E_VAULT_PW"$'\x1f'"$MUYA_TEST_MASTER" python3 "$HERE/agent_e2e.py" "$SIDECAR" 2>&1 | grep -v "no secret"); echo "$out"
  FAILS=$((FAILS + $(echo "$out" | grep -c '^FAIL')))
  mcp() { python3 "$HERE/mcp_call.py" "$SIDECAR" "$@"; }
  echo "$(mcp ssh_list_servers '{}')" | head -c 600; echo
  no_leak "muyad log" "$(cat "$DEV/muyad.log" 2>/dev/null)"
fi
echo "FAILS=$FAILS"; exit $FAILS
