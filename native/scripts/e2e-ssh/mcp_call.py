#!/usr/bin/env python3
"""Minimal MCP stdio client for the e2e: mcp_call.py <sidecar> <tool> '<json args>' [<tool> '<json>' ...]
Runs every call in ONE sidecar session (so ssh_open ids carry over) and prints each result as JSON on one line."""
import json, os, subprocess, sys, select, time

def main():
    sidecar, rest = sys.argv[1], sys.argv[2:]
    p = subprocess.Popen([sidecar], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=os.environ)
    nid = [0]
    def rpc(method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None: msg["params"] = params
        if not notify:
            nid[0] += 1; msg["id"] = nid[0]
        p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
        if notify: return None
        end = time.time() + 180
        while time.time() < end:
            r, _, _ = select.select([p.stdout], [], [], 1)
            if r:
                line = p.stdout.readline()
                if not line: break
                o = json.loads(line)
                if o.get("id") == nid[0]: return o
        return {"error": "timeout"}
    rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    for tool, args in zip(rest[::2], rest[1::2]):
        o = rpc("tools/call", {"name": tool, "arguments": json.loads(args)})
        print(json.dumps({"tool": tool, "result": o.get("result", o)}))
    p.stdin.close(); p.terminate()
main()
