#!/usr/bin/env bash
# PRD AC23: no terminal content on disk. 25 sessions print a unique canary for MINUTES (default
# 10); afterwards the canary must not appear in any file Muya or a terminal program could have
# written to. TCC-protected folders (Mail, Messages, Safari, Containers) are not scanned: reading
# them would raise permission prompts for the operator.
#   native/tests/ac23.sh [minutes]
set -u
cd "$(dirname "$0")/.."
MIN=${1:-10}
BIN=target/debug
W=$(mktemp -d /tmp/muya-ac23.XXXXXX)
CANARY="MUYA-CANARY-$(uuidgen)"
pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
$BIN/muya-ptyd --socket "$W/p.sock" 2>/dev/null & pids+=($!)
while [ ! -S "$W/p.sock" ]; do sleep 0.05; done
$BIN/muyad --socket "$W/m.sock" --ptyd "$W/p.sock" 2>/dev/null & pids+=($!)
while [ ! -S "$W/m.sock" ]; do sleep 0.05; done
python3 - "$W/m.sock" "$CANARY" <<'PY'
import socket, struct, json, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
def send(o):
    b = b"\x01" + json.dumps(o).encode(); s.sendall(struct.pack(">I", len(b)) + b)
send({"type":"hello","major":1,"minor":0,"role":"app","build":"ac23"})
for i in range(25):
    send({"type":"spawn","argv":["/bin/sh","-c",f"while :; do echo {sys.argv[2]} session {i}; sleep 0.2; done"],"cwd":"/tmp","env":[],"cols":100,"rows":30})
import time; time.sleep(1)
PY
echo "AC23: 25 sessions printing the canary for $MIN min"
sleep $((MIN * 60))
before=$(ps -o rss= -p ${pids[1]})
L="$HOME/Library"
hits=$(grep -rIl -D skip --exclude-dir="muya-ac23.*" "$CANARY" \
  "$L/Application Support/Muya" "$L/Caches" "$L/Logs" "$L/Saved Application State" "$L/Preferences" "$L/HTTPStorages" "$L/WebKit" \
  "${TMPDIR:-/tmp}" /tmp 2>/dev/null | grep -v "^$W" | grep -v '/muya-ac23\.' )
if [ -z "$hits" ]; then
  echo "AC23 PASS: canary found nowhere on disk after $MIN min (muyad rss ${before} KB)"
else
  echo "AC23 FAIL: canary on disk:"; echo "$hits"; exit 1
fi
