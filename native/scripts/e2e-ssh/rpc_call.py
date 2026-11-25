#!/usr/bin/env python3
"""One muya-proto rpc to muyad as an app client: rpc_call.py <socket> <method> '<params json>'. Prints the reply."""
import json, socket, struct, sys
def frame(o): b = b"\x01" + json.dumps(o).encode(); return struct.pack(">I", len(b)) + b
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(30)
s.sendall(frame({"type": "hello", "major": 1, "minor": 3, "role": "app", "build": "e2e"}))
s.sendall(frame({"type": "rpc", "req": 1, "method": sys.argv[2], "params": sys.argv[3] if len(sys.argv) > 3 else "{}"}))
buf = b""
while True:
    d = s.recv(65536)
    if not d: print("no reply"); sys.exit(3)
    buf += d
    while len(buf) >= 4:
        n = struct.unpack(">I", buf[:4])[0]
        if len(buf) < 4 + n: break
        body, buf = buf[5:4 + n], buf[4 + n:]
        o = json.loads(body)
        if o.get("type") == "error": print("refused:", o.get("message")); sys.exit(4)
        if o.get("type") == "rpc_reply" and o.get("req") == 1: print(json.dumps(o)); sys.exit(0 if o.get("ok", True) else 5)
