#!/usr/bin/env bash
# PRD AC4: `tools/list` from the MCP sidecar is byte-identical to the committed snapshot of
# today's output (native/crates/muya-core/tests/snapshots/tools-list.json). Pass the broker socket
# the sidecar should use (muyad's once it hosts the broker); tools/list itself needs no broker.
#   native/tests/ac4-tools-list.sh [broker-socket]
# Against muyad's broker (start it with its own socket, then pass that socket):
#   MUYA_SSH_BROKER_SOCK=/tmp/b.sock native/target/debug/muyad --broker --ptyd <ptyd.sock> &
#   native/tests/ac4-tools-list.sh /tmp/b.sock
# (native/crates/muyad/tests/broker.rs does the same with the full tools/call round trips.)
set -eu
cd "$(dirname "$0")/../.."
(cd src-tauri && cargo build -q --bin muya-ssh-mcp)
got=$(printf '%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | MUYA_SSH_BROKER_SOCK="${1:-/tmp/muya-no-broker.sock}" src-tauri/target/debug/muya-ssh-mcp 2>/dev/null | sed -n 2p)
if [ "$got" = "$(cat native/crates/muya-core/tests/snapshots/tools-list.json)" ]; then
  echo "AC4 tools/list: byte-identical ($(printf '%s' "$got" | wc -c | tr -d ' ') bytes)"
else
  echo "AC4 tools/list: DIFFERS from the snapshot"; exit 1
fi
