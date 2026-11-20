#!/usr/bin/env python3 -I
"""Synthetic Claude transcripts + a fake `claude` for the Faz 4a checks. Everything is invented (no real
conversation, user or host name) and goes under the throwaway HOME given as argv[1].

  make-pages-fixtures.py <home> [count] [turns]   a handful of named demo sessions, then filler up to <count> in total;
                                                   <turns> = extra user/assistant turns per filler transcript (size)
"""
import json, os, random, stat, sys, time

home = sys.argv[1]
total = int(sys.argv[2]) if len(sys.argv) > 2 else 12
turns = int(sys.argv[3]) if len(sys.argv) > 3 else 0
random.seed(7)
projects = os.path.join(home, ".claude", "projects")
now = time.time()

DEMO = [
    ("alpha", "Refactor the zebra parser", "please refactor the zebra parser so it streams", "zebra parser now streams line by line"),
    ("alpha", "Fix flaky login test", "the login test is flaky on CI, find out why", "the test raced a timer; it now waits for the event"),
    ("alpha", "Release notes", "draft release notes for v4.2", "release notes drafted with three sections"),
    ("beta", "Database migration", "write the migration that adds the orders table", "migration written and reversible"),
    ("beta", "Cache invalidation", "why does the cache serve stale data", "the key ignored the tenant id; fixed"),
    ("gamma", "Docs cleanup", "remove outdated pages from the docs", "removed twelve outdated pages"),
]
WORDS = "build deploy review parser cache index queue stream render token config module socket worker retry schema widget".split()


def write(proj, sid, title, user, assistant, age, extra=0):
    cwd = f"/work/{proj}"
    d = os.path.join(projects, cwd.replace("/", "-"))
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, f"{sid}.jsonl")
    lines = [
        {"type": "user", "cwd": cwd, "message": {"role": "user", "content": user}},
        {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": assistant}]}},
    ]
    for t in range(extra):
        body = " ".join(random.choice(WORDS) for _ in range(random.randint(150, 450)))
        lines.append({"type": "user", "message": {"role": "user", "content": f"turn {t}: {body}"}})
        lines.append({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": f"reply {t}: {body[: len(body) // 2]}"}]}})
    if title:
        lines.append({"type": "custom-title", "customTitle": title})
    with open(p, "w") as f:
        for l in lines:
            f.write(json.dumps(l, separators=(",", ":")) + "\n")
    os.utime(p, (now - age, now - age))


for i, (proj, title, user, asst) in enumerate(DEMO):
    write(proj, f"{i:08x}-aaaa-4bbb-8ccc-{i:012x}", title, user, asst, 600 + i * 3700)
for i in range(len(DEMO), total):
    proj = random.choice(["alpha", "beta", "gamma", "delta", "epsilon"])
    text = " ".join(random.choice(WORDS) for _ in range(random.randint(30, 400)))
    write(proj, f"{i:08x}-bbbb-4ccc-8ddd-{i:012x}", None, f"session {i}: {text}", f"done {i}: " + text[: len(text) // 2], 86400 + i * 997, turns)

bin_dir = os.path.join(home, ".local", "bin")
os.makedirs(bin_dir, exist_ok=True)
fake = os.path.join(bin_dir, "claude")
with open(fake, "w") as f:
    f.write("#!/bin/sh\nif [ \"$1\" = agents ]; then echo '[]'; exit 0; fi\nsleep 2\necho '{\"result\":\"fake run ok\",\"is_error\":false,\"total_cost_usd\":0.02}'\n")
os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
os.makedirs(os.path.join(home, "work", "report"), exist_ok=True)
# Login shells of the test sessions find the fake claude first (never the real CLI).
with open(os.path.join(home, ".zprofile"), "w") as f:
    f.write('export PATH="$HOME/.local/bin:$PATH"\n')
print(f"{total} synthetic transcripts under {projects}")
