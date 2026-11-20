#!/usr/bin/env python3 -I
"""Extra synthetic data for the Faz 4e checks, on top of make-pages-fixtures.py. Everything is invented.

  make-4e-fixtures.py <home>
    - three old transcripts (40/45/50 days) and two 60 MB ones (one touched two days ago, one just now)
    - a transcript with tool use, a tool result and a very long answer (the "View" drawer)
    - agents.json: what the fake `claude agents --json` answers (two live sessions; one is an OLD transcript's id)
    - an OLD `claude` earlier in the login shell's PATH that rejects `agents --json` (capability pick)
    - a fake `claude` that answers `agents --json` from agents.json
    - fake permission-prompt programs (permission.py)
"""
import json, os, stat, sys, time

home = sys.argv[1]
now = time.time()
projects = os.path.join(home, ".claude", "projects")


def tpath(proj, i, kind="bbbb-4ccc-8ddd"):
    return os.path.join(projects, f"-work-{proj}"), f"{i:08x}-{kind}-{i:012x}.jsonl"


def age(path, seconds):
    os.utime(path, (now - seconds, now - seconds))


def find(i):
    for d in os.listdir(projects):
        for f in os.listdir(os.path.join(projects, d)):
            if f.startswith(f"{i:08x}-"):
                return os.path.join(projects, d, f)
    raise SystemExit(f"fixture {i} missing")


DAY = 86400
for i, days in ((6, 40), (7, 45), (8, 50)):
    age(find(i), days * DAY)


def pad(path, mb):
    line = json.dumps({"type": "user", "message": {"role": "user", "content": "x" * 900}}) + "\n"
    with open(path, "a") as f:
        for _ in range(mb * 1024 * 1024 // len(line) + 1):
            f.write(line)


pad(find(9), 60); age(find(9), 2 * DAY)   # big, not in use
pad(find(10), 60)                          # big, but written just now: held back

# The "View" drawer: user text, assistant text + tool use, a tool result (must not show), a long answer.
d, f = tpath("alpha", 0x20)
os.makedirs(d, exist_ok=True)
p = os.path.join(d, f)
lines = [
    {"type": "summary", "summary": "x"},
    {"type": "user", "cwd": "/work/alpha", "timestamp": "2026-03-01T10:00:00Z", "message": {"role": "user", "content": "run the quokka tests"}},
    {"type": "assistant", "timestamp": "2026-03-01T10:00:05Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "Running them now."}, {"type": "tool_use", "name": "Bash", "input": {"command": "make test"}}]}},
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "SECRET-TOOL-DUMP"}]}},
    {"type": "assistant", "timestamp": "2026-03-01T10:01:00Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "All 41 quokka tests pass. " + "More detail. " * 500}]}},
    {"type": "custom-title", "customTitle": "Quokka test run"},
]
with open(p, "w") as fh:
    for l in lines:
        fh.write(json.dumps(l, separators=(",", ":")) + "\n")
age(p, 5 * DAY)

live_id = os.path.basename(find(8))[:-6]
ms = int(now * 1000)
agents = [
    {"sessionId": "11111111-aaaa-4bbb-8ccc-000000000001", "cwd": os.path.join(home, "work", "report"), "kind": "interactive", "status": "busy", "startedAt": ms - 120000, "pid": 4242, "name": "Zebra live"},
    {"sessionId": live_id, "cwd": "/work/gamma", "kind": "background", "id": "bg02", "state": "blocked", "waitingFor": "permission prompt", "startedAt": ms - 3600000, "name": "Needs input"},
]
with open(os.path.join(home, "agents.json"), "w") as fh:
    json.dump(agents, fh)

os.makedirs(os.path.join(home, ".local", "bin"), exist_ok=True)
os.makedirs(os.path.join(home, "oldbin"), exist_ok=True)
old = os.path.join(home, "oldbin", "claude")
with open(old, "w") as fh:
    fh.write("#!/bin/sh\nif [ \"$2\" = \"--json\" ]; then echo 'error: unknown option --json' >&2; exit 1; fi\necho 2.1.78\n")
fake = os.path.join(home, ".local", "bin", "claude")
with open(fake, "w") as fh:
    fh.write("#!/bin/sh\nif [ \"$1\" = agents ]; then cat \"$HOME/agents.json\" 2>/dev/null || echo '[]'; exit 0; fi\nsleep 2\necho '{\"result\":\"fake run ok\",\"is_error\":false}'\n")
perm = os.path.join(home, "permission.py")
with open(perm, "w") as fh:
    fh.write('''import sys, tty, termios
print("Bash command")
print("  rm -rf build-cache")
print("Do you want to proceed?")
print("❯ 1. Yes")
print("  2. Yes, and don't ask again for rm commands")
print("  3. No, and tell Claude what to do differently (esc)")
print()
print(" Esc to cancel")
sys.stdout.flush()
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setcbreak(fd)
ch = sys.stdin.read(1)
termios.tcsetattr(fd, termios.TCSADRAIN, old)
print("\\nANSWERED:" + ch)
sys.stdout.flush()
''')
for path in (old, fake):
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
# Login shells find the OLD claude first: the app must skip it and pick the capable one.
with open(os.path.join(home, ".zprofile"), "w") as fh:
    fh.write('export PATH="$HOME/oldbin:$HOME/.local/bin:$PATH"\n')
print("faz4e fixtures ready")
