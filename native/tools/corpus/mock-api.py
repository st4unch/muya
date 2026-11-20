#!/usr/bin/env python3
"""Local stand-in for the Anthropic Messages API, used ONLY to capture Claude Code screens for the
AC3 corpus (native/tools/corpus/). No network, no credentials, no cost: Claude is pointed here with
ANTHROPIC_BASE_URL and a fake key. The reply is picked from keywords in the user's last message:

  story / think   slow streamed text (spinner visible), `think` adds a thinking block first
  bash            Bash tool call  -> permission dialog          write   Write tool call
  edit            Edit tool call (needs notes.txt in cwd)       mcp     mcp__fake__ping tool call
  plan            ExitPlanMode tool call (plan-approval dialog)
  long            ~120 lines of text at once                    todo    TodoWrite tool call
  anything else   one short sentence

After the tool result comes back the reply is a short "Done." text.   usage: mock-api.py <port>
"""
import json, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SLOW_WORDS = ("The fox crept along the frozen river at dawn, listening for the faint crunch of snow. "
              "Behind it the forest woke slowly, branch by branch, and the cold light spread across the hills. ").split()


def sse(ev, data):
    return f"event: {ev}\ndata: {json.dumps(data)}\n\n".encode()


def last_user(messages):
    for m in reversed(messages):
        if m.get("role") == "user":
            return m
    return {"content": ""}


def text_of(content):
    if isinstance(content, str):
        return content
    return " ".join(b.get("text", "") for b in content if b.get("type") == "text")


def has_tool_result(content):
    return isinstance(content, list) and any(b.get("type") == "tool_result" for b in content)


def plan(body):
    """-> list of steps: ('think', text) ('text', text, delay) ('tool', name, input)."""
    msgs = body.get("messages", [])
    model = body.get("model", "")
    u = last_user(msgs)
    if has_tool_result(u["content"]):
        return [("text", "Done. The tool call finished and everything looks fine.", 0.0)]
    t = text_of(u["content"]).lower()
    if "haiku" in model or body.get("max_tokens", 99999) < 1000 and "tools" not in body:
        return [("text", '{"title":"Fox story","isNewTopic":false}', 0.0)]
    steps = []
    if "think" in t:
        steps.append(("think", "Let me consider this carefully. " * 12))
    if "bash" in t:
        steps.append(("tool", "Bash", {"command": "mkdir -p corpus-out && touch corpus-out/marker.txt", "description": "Create a marker file"}))
    elif "write" in t:
        steps.append(("tool", "Write", {"file_path": "hello.txt", "content": "hi\nthere\n"}))
    elif "edit" in t:
        steps.append(("tool", "Edit", {"file_path": "notes.txt", "old_string": "alpha", "new_string": "beta"}))
    elif "mcp" in t:
        steps.append(("tool", "mcp__fake__ping", {"message": "hello"}))
    elif "todo" in t:
        steps.append(("tool", "TodoWrite", {"todos": [{"content": "First step", "status": "in_progress", "activeForm": "Doing first step"},
                                                       {"content": "Second step", "status": "pending", "activeForm": "Doing second step"}]}))
    elif "plan" in t:
        steps.append(("tool", "ExitPlanMode", {"plan": "## Plan\n1. Read the notes file\n2. Change alpha to beta\n3. Run the tests"}))
    elif "long" in t:
        steps.append(("text", "\n".join(f"Line {i:03d}: the quick brown fox jumps over the lazy dog, again and again and again." for i in range(1, 121)), 0.0))
    elif "story" in t or "think" in t:
        steps.append(("text", "\n".join(" ".join(SLOW_WORDS[i:i + 8]) for i in range(0, len(SLOW_WORDS) * 4, 8)), 0.3))
    else:
        steps.append(("text", "Understood. This is a short reply from the corpus mock.", 0.0))
    return steps


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        import os
        if os.environ.get("MOCK_LOG"):
            with open(os.environ["MOCK_LOG"], "a") as f:
                f.write(fmt % a + "\n")

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self._json(200, {"data": [], "has_more": False})

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}
        path = self.path.split("?")[0]
        if path.endswith("/count_tokens"):
            return self._json(200, {"input_tokens": 1234})
        if not path.endswith("/messages"):
            return self._json(200, {})
        steps = plan(body)
        if not body.get("stream"):
            text = "".join(s[1] for s in steps if s[0] == "text") or "ok"
            return self._json(200, {"id": "msg_mock", "type": "message", "role": "assistant", "model": body.get("model", "mock"),
                                    "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "stop_sequence": None,
                                    "usage": {"input_tokens": 100, "output_tokens": 20}})
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()

        def w(b):
            self.wfile.write(f"{len(b):x}\r\n".encode() + b + b"\r\n")
            self.wfile.flush()

        stop = "end_turn"
        w(sse("message_start", {"type": "message_start", "message": {"id": "msg_mock", "type": "message", "role": "assistant", "model": body.get("model", "mock"),
                                                                        "content": [], "stop_reason": None, "stop_sequence": None,
                                                                        "usage": {"input_tokens": 1500, "output_tokens": 1}}}))
        for i, s in enumerate(steps):
            if s[0] == "think":
                w(sse("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "thinking", "thinking": "", "signature": ""}}))
                words = s[1].split(" ")
                for j in range(0, len(words), 4):
                    w(sse("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "thinking_delta", "thinking": " ".join(words[j:j + 4]) + " "}}))
                    time.sleep(0.25)
                w(sse("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "signature_delta", "signature": "mock"}}))
            elif s[0] == "text":
                w(sse("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "text", "text": ""}}))
                if s[2] > 0:
                    lines = s[1].split("\n")
                    for j, ln in enumerate(lines):
                        w(sse("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": ln + ("\n" if j < len(lines) - 1 else "")}}))
                        time.sleep(s[2])
                else:
                    w(sse("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": s[1]}}))
            else:
                stop = "tool_use"
                w(sse("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "tool_use", "id": f"toolu_mock{i}", "name": s[1], "input": {}}}))
                w(sse("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "input_json_delta", "partial_json": json.dumps(s[2])}}))
            w(sse("content_block_stop", {"type": "content_block_stop", "index": i}))
        w(sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 300}}))
        w(sse("message_stop", {"type": "message_stop"}))
        w(b"")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
