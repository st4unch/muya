#!/usr/bin/env python3
"""Agent-path e2e: drives the real muya-ssh-mcp sidecar (-> muyad broker) for direct, key and PSMP servers.
usage: agent_e2e.py <sidecar> ; env: E2E_SECRETS (colon-free list sep by \\x1f of strings that must never appear in results)
Prints PASS/FAIL lines; exit code = number of failures."""
import json, os, re, subprocess, select, sys, time, tempfile

SECRETS = [s for s in os.environ.get("E2E_SECRETS", "").split("\x1f") if s]
fails = 0
raw = ""
def ok(c, msg):
    global fails
    print(("PASS  " if c else "FAIL  ") + msg); fails += (not c)

p = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
n = [0]
def rpc(method, params=None, notify=False):
    m = {"jsonrpc": "2.0", "method": method}
    if params is not None: m["params"] = params
    if not notify: n[0] += 1; m["id"] = n[0]
    p.stdin.write(json.dumps(m) + "\n"); p.stdin.flush()
    if notify: return None
    end = time.time() + 240
    while time.time() < end:
        if select.select([p.stdout], [], [], 1)[0]:
            line = p.stdout.readline()
            if not line: break
            o = json.loads(line)
            if o.get("id") == n[0]: return o
    return {"error": "timeout"}
def call(tool, **args):
    o = rpc("tools/call", {"name": tool, "arguments": args})
    text = json.dumps(o)
    for s in SECRETS: ok(s not in text, f"{tool}: result has no secret")
    r = o.get("result", {}); global raw; raw = text
    return "".join(c.get("text", "") for c in r.get("content", [])), bool(r.get("isError"))

rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}})
rpc("notifications/initialized", notify=True)

def sid(text):
    m = re.search(r'sessionId=([^\s"]+)', text) or re.search(r'"sessionId"\s*:\s*"([^"]+)"', text)
    return m.group(1) if m else None

for alias, tag in [("E2E Direct", "AGDIRECT"), ("E2E Key", "AGKEY"), ("E2E PSMP", "AGPSMP")]:
    # session_open first: a persistent session waits for ssh's password prompt before probing, so it needs a fresh connection
    # (classic has the same limit once ssh_run has left a ControlMaster open for a direct server)
    t, err = call("ssh_session_open", alias=alias); s2 = sid(t)
    ok(bool(s2) and not err, f"agent[{alias}] ssh_session_open: {t[:160]!r}")
    if s2:
        t, err = call("ssh_session_exec", sessionId=s2, command=f"echo {tag}-EXEC-$(whoami)")
        ok(f"{tag}-EXEC-" in t and not err, f"agent[{alias}] ssh_session_exec: {t[:160]!r}")
        # scp keeps strict host-key checking ON in production (build_scp_command sets no -o, the agent cannot pass one) and ssh reads
        # known_hosts from the account's real home (getpwuid, NOT $HOME), which this harness must never touch. So the proof here is that
        # the scp path runs the right argv and stops exactly at host-key verification (never silently trusts an unknown host).
        if tag != "AGPSMP":
            d = tempfile.mkdtemp(prefix="sc", dir=os.environ["E2E_ROOT"]); src = os.path.join(d, "up.txt"); open(src, "w").write(f"payload-{tag}\n")
            t, err = call("ssh_scp", alias=alias, direction="upload", localPath=src, remotePath=f"/tmp/up-{tag}.txt")
            ok("Host key verification failed" in t, f"agent[{alias}] ssh_scp enforces host-key checking: {t[-120:]!r}")
        call("ssh_session_close", sessionId=s2)
    t, err = call("ssh_run", alias=alias, command=f"echo {tag}-$(whoami)")
    ok(f"{tag}-" in t and not err, f"agent[{alias}] ssh_run logged in: {t[:120]!r}")
    t, err = call("ssh_open", alias=alias); s = sid(t)
    ok(bool(s) and not err, f"agent[{alias}] ssh_open: {t[:160]!r} raw={raw[:200]!r}")
    if s:
        time.sleep(6)
        t, err = call("ssh_send", sessionId=s, text=f"echo {tag}-SEND-$(whoami)\n")
        ok(not err, f"agent[{alias}] ssh_send: {t[:120]!r}")
p.terminate()
print(f"AGENT_FAILS={fails}"); sys.exit(fails)
