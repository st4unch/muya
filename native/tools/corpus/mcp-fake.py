#!/usr/bin/env python3
"""Tiny stdio MCP server with one tool (`ping`), for the permission-dialog captures."""
import json, sys
for line in sys.stdin:
    try:
        m = json.loads(line)
    except Exception:
        continue
    i, meth = m.get("id"), m.get("method")
    if meth == "initialize":
        r = {"protocolVersion": m["params"].get("protocolVersion", "2024-11-05"), "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
    elif meth == "tools/list":
        r = {"tools": [{"name": "ping", "description": "Reply with pong", "inputSchema": {"type": "object", "properties": {"message": {"type": "string"}}}}]}
    elif meth == "tools/call":
        r = {"content": [{"type": "text", "text": "pong"}]}
    elif i is None:
        continue
    else:
        r = {}
    print(json.dumps({"jsonrpc": "2.0", "id": i, "result": r}), flush=True)
