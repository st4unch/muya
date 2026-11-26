#!/usr/bin/env bash
# A caller must be tied to its own Claude session by process ancestry alone — no channel subscription,
# which needs a flag most sessions are not started with. In 5.0.3 every caller counted as unverified:
# `broadcast` was refused outright and every message arrived tagged as coming from an unverified session.
#
# This is not a mock. The request is sent by a process THIS Claude session spawned, so its parent chain
# really leads to this session's `claude` process, and the broker resolves it through the same
# `claude agents --json` registry the shipped app uses. Run it from a Claude session, or it cannot pass.
#
# Safety: a throwaway broker of its own, in its own fake HOME, so it binds its own socket and never goes
# near the running Muya, its socket, its daemons or its launchd jobs. `CLAUDE_CONFIG_DIR` keeps the real
# session registry readable while HOME is faked.
#
#   native/app/verify-caller-binding.sh [path to muyad]        default: native/target/debug/muyad
set -uo pipefail
cd "$(dirname "$0")/.."            # native/
MUYAD=${1:-$PWD/target/debug/muyad}
[ -x "$MUYAD" ] || { echo "FAIL no muyad at $MUYAD (build it: cargo build -p muyad)"; exit 1; }
WORK=$(mktemp -d /tmp/muya-bind.XXXXXX)
FAKE=$WORK/home
mkdir -p "$FAKE"
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
cleanup() {
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

env HOME="$FAKE" CLAUDE_CONFIG_DIR="$HOME/.claude" TMPDIR="$WORK" \
  "$MUYAD" --socket "$WORK/muyad.sock" --ptyd "$WORK/ptyd.sock" --broker --state-dir "$WORK" \
  >"$WORK/muyad.log" 2>&1 &
PID=$!
SOCK=$FAKE/.claude/muya-ssh-broker.sock
for _ in $(seq 150); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { bad "the throwaway broker never bound its socket"; sed -n 1,10p "$WORK/muyad.log"; exit 1; }

# `broadcast` carries the identity gate, and it is checked before any tab is enumerated: a bound caller
# gets a normal (here empty) target list, an unbound one gets the refusal. That makes it the cheapest
# probe of the binding itself — this broker has no tabs, so nothing can be typed into anything.
REPLY=$(python3 -I - "$SOCK" <<'PY'
import socket, sys, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(30)
s.connect(sys.argv[1])
s.sendall((json.dumps({"op": "broadcast", "command": "# caller-binding probe", "kind": "shell"}) + "\n").encode())
buf = b""
while b"\n" not in buf:
    d = s.recv(65536)
    if not d:
        break
    buf += d
print(buf.decode("utf-8", "replace").strip())
PY
)
case "$REPLY" in
  *'"ok":true'*)        ok  "a caller under a Claude process is bound by ancestry: $REPLY" ;;
  *unverified*|*'could not be tied'*) bad "the caller is still unverified: $REPLY" ;;
  "")                   bad "the broker closed the connection without answering" ;;
  *)                    bad "unexpected answer: $REPLY" ;;
esac

# A claimed session id is not an identity. A subscribe for an id the registry does not know still gets its push
# channel (a sidecar can start before the registry has caught up), but the claim is NOT recorded as the caller's
# identity: authorisation stays with the kernel-backed ancestry binding. That a made-up id cannot act as that
# session is asserted by the broker unit tests (a_made_up_session_id_gets_a_channel_but_no_identity_and_no_powers);
# live, this checks the two observable halves from ONE process: the channel is served, and the caller is
# still the session its ancestry proves (the identity gate lets it through exactly as in the first check).
REPLY=$(python3 -I - "$SOCK" <<'PY'
import socket, sys, json
def conn():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    s.connect(sys.argv[1])
    return s
def line(s):
    buf = b""
    while b"\n" not in buf:
        d = s.recv(65536)
        if not d:
            break
        buf += d
    return buf.decode("utf-8", "replace").strip()
sub = conn()
sub.sendall((json.dumps({"op": "subscribe", "sessionId": "00000000-dead-beef-0000-000000000000"}) + "\n").encode())
ack = line(sub)
b = conn()
b.sendall((json.dumps({"op": "broadcast", "command": "# caller-binding probe", "kind": "shell"}) + "\n").encode())
print(ack + " || " + line(b))
PY
)
case "$REPLY" in
  *'"ok":true'*'||'*'"ok":true'*) ok  "a made-up claim gets a channel and the caller keeps only its ancestry identity: $REPLY" ;;
  *) bad "unexpected answer to a made-up claim: ${REPLY:-no answer}" ;;
esac

echo "RESULT: $([ $fails = 0 ] && echo PASS || echo "FAIL ($fails)")"
exit $fails
