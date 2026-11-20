#!/usr/bin/env python3 -I
"""Synthetic repositories for the Queue / Branches / Kanban checks. Everything is invented and goes under the
throwaway HOME given as argv[1]: <home>/qproj is a git repo with N commits (default 5000; merges, side branches),
a bare <home>/qorigin.git as its only remote (a local temp path), branches in every queue state, a linked
worktree, and docs/prd-*.progress.md files for the board. Prints the repo path."""
import os, random, subprocess, sys

home = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
repo, origin = os.path.join(home, "qproj"), os.path.join(home, "qorigin.git")
ENV = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
           GIT_AUTHOR_NAME="Demo", GIT_AUTHOR_EMAIL="demo@example.com", GIT_COMMITTER_NAME="Demo", GIT_COMMITTER_EMAIL="demo@example.com")


def git(*a, cwd=repo, inp=None):
    return subprocess.run(["git", "-c", "commit.gpgsign=false", *a], cwd=cwd, env=ENV, check=True, capture_output=True, text=True, input=inp).stdout


os.makedirs(repo, exist_ok=True)
git("init", "-q", "-b", "main")
rng = random.Random(7)
out, t, mark = [], 1_700_000_000, 0
tips = {"main": None}          # branch -> last mark
open_side = []                  # [branch, remaining commits]


def commit(branch, msg, merge=None):
    global mark, t
    mark += 1; t += rng.randint(60, 4000)
    b = f"blob {mark}\n"
    out.append(f"commit refs/heads/{branch}\nmark :{mark}\ncommitter Demo <demo@example.com> {t} +0000\ndata {len(msg)}\n{msg}\n")
    if tips.get(branch): out.append(f"from :{tips[branch]}\n")
    if merge: out.append(f"merge :{merge}\n")
    out.append(f"M 100644 inline f{mark % 40}.txt\ndata {len(b)}\n{b}\n")
    tips[branch] = mark


commit("main", "initial commit")
side_id = 0
for i in range(1, n):
    if rng.random() < 0.04 and len(open_side) < 5:
        side_id += 1
        name = f"side{side_id}"
        tips[name] = tips["main"]
        open_side.append([name, rng.randint(3, 12)])
    if open_side and rng.random() < 0.5:
        s = rng.choice(open_side)
        commit(s[0], f"work on {s[0]} #{i}")
        s[1] -= 1
        if s[1] <= 0:
            open_side.remove(s)
            commit("main", f"Merge {s[0]}", merge=tips[s[0]])
            del tips[s[0]]
    else:
        commit("main", f"change {i}")
for s in open_side:
    commit("main", f"Merge {s[0]}", merge=tips[s[0]]); del tips[s[0]]
stream = "".join(out)
subprocess.run(["git", "fast-import", "--quiet"], cwd=repo, env=ENV, input=stream, text=True, check=True)
git("symbolic-ref", "HEAD", "refs/heads/main"); git("reset", "-q", "--hard", "main")
for b in git("for-each-ref", "--format=%(refname:short)", "refs/heads").split():
    if b.startswith("side"): git("branch", "-q", "-D", b)

# Docs for the Kanban board.
os.makedirs(os.path.join(repo, "docs"), exist_ok=True)
cards = [("login-flow", "Login flow", "draft"), ("export-csv", "Export to CSV", "active"), ("dark-mode", "Dark mode polish", "in progress"),
         ("audit-log", "Audit log viewer", "review"), ("rate-limit", "Rate limiting", "awaiting review"), ("onboarding", "Onboarding tour", "done"),
         ("search-v2", "Search v2", "implementing"), ("billing", "Billing page", "draft")]
for slug, title, status in cards:
    open(os.path.join(repo, "docs", f"prd-{slug}.md"), "w").write(f"# {title}\n\nSynthetic PRD.\n")
    open(os.path.join(repo, "docs", f"prd-{slug}.progress.md"), "w").write(f"---\nstatus: {status}\nprd: docs/prd-{slug}.md\n---\n\nProgress notes.\n")

git("add", "-A"); git("commit", "-q", "-m", "docs: PRD progress files")
git("init", "-q", "--bare", origin, cwd=home)
git("remote", "add", "origin", origin); git("push", "-q", "-u", "origin", "main")


def work(branch, base, msgs, push=False, track=False):
    git("checkout", "-q", "-b", branch, base)
    for i, m in enumerate(msgs):
        open(os.path.join(repo, f"{branch}-{i}.txt"), "w").write(m + "\n"); git("add", "-A"); git("commit", "-q", "-m", m)
    if push: git("push", "-q", "-u", "origin", branch)
    git("checkout", "-q", "main")


work("stale-topic", "main~3", ["stale: start", "stale: more"])           # behind main, no upstream
git("branch", "-q", "merged-topic", "main")                                # fully merged
work("ready-topic", "main", ["ready: feature", "ready: tests"], push=True)  # pushed, ahead of main
work("unpushed-topic", "main", ["unpushed: wip"], push=True)               # then one more local commit
git("checkout", "-q", "unpushed-topic"); open(os.path.join(repo, "extra.txt"), "w").write("x\n"); git("add", "-A"); git("commit", "-q", "-m", "unpushed: extra"); git("checkout", "-q", "main")
work("local-topic", "main", ["local: idea"])                               # no upstream
git("worktree", "add", "-q", os.path.join(home, "qproj-wt"), "-b", "wt-topic", "main")
print(repo)
