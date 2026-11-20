#!/usr/bin/env python3 -I
"""Synthetic repository + Claude transcript for the Inspector checks (Faz 4b). Everything is invented and goes
under the throwaway HOME given as argv[1]: <home>/proj is a git repo with <files> files (default 2000), a few
edits, an untracked file, a staged add, a linked worktree and a merge conflict left in progress.
Prints the repo path."""
import json, os, subprocess, sys, time

home = sys.argv[1]
files = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
repo = os.path.join(home, "proj")
wt = os.path.join(home, "proj-feature")


def git(*a, check=True, cwd=repo):
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
               GIT_AUTHOR_NAME="Demo", GIT_AUTHOR_EMAIL="demo@example.com", GIT_COMMITTER_NAME="Demo", GIT_COMMITTER_EMAIL="demo@example.com")
    return subprocess.run(["git", "-c", "commit.gpgsign=false", *a], cwd=cwd, env=env, check=check, capture_output=True, text=True)


def put(rel, text):
    p = os.path.join(repo, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(text)


os.makedirs(repo, exist_ok=True)
git("init", "-q", "-b", "main")
for i in range(files):
    put(f"src/mod{i // 50:02d}/file{i:04d}.txt", f"module {i}\nline two\nline three\n")
put("src/parser.swift", "struct Parser {\n    func parse(_ s: String) -> [String] {\n        s.split(separator: \"\\n\").map(String.init)\n    }\n}\n")
put("README.md", "# Demo project\n\nA synthetic repository.\n")
put("notes/plan.md", "plan\n")
git("add", "."); git("commit", "-q", "-m", "initial")
git("branch", "feature")
git("worktree", "add", "-q", wt, "feature")
# Conflicting change on a topic branch, committed; the merge below is left in progress.
git("checkout", "-q", "-b", "topic")
put("README.md", "# Demo project\n\nTopic branch wording.\n"); put("notes/plan.md", "plan from topic\n")
git("commit", "-q", "-am", "topic wording")
git("checkout", "-q", "main")
put("README.md", "# Demo project\n\nMain branch wording.\n"); put("notes/plan.md", "plan from main\n")
git("commit", "-q", "-am", "main wording")
git("merge", "topic", check=False)
# Working-tree edits on top.
put("src/parser.swift", "struct Parser {\n    func parse(_ s: String) -> [String] {\n        s.split(separator: \"\\n\", omittingEmptySubsequences: false).map(String.init)\n    }\n\n    func count(_ s: String) -> Int { parse(s).count }\n}\n")
put("src/mod00/file0001.txt", "module 1\nline two changed\nline three\nline four\n")
os.remove(os.path.join(repo, "src/mod00/file0002.txt"))
put("docs/new-guide.md", "# Guide\n\nNot tracked yet.\n")
put("src/staged.swift", "let staged = true\n")
git("add", "src/staged.swift")

# Transcript for the folder (Claude Code names the project folder after the working directory).
slug = repo.replace("/", "-").replace(".", "-")
d = os.path.join(home, ".claude", "projects", slug)
os.makedirs(d, exist_ok=True)
now = time.time()


def ts(ago):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now - ago))


def user(ago, text):
    return {"type": "user", "timestamp": ts(ago), "message": {"role": "user", "content": text}}


def tool(ago, name, **inp):
    return {"type": "assistant", "timestamp": ts(ago), "message": {"role": "assistant", "content": [{"type": "tool_use", "name": name, "input": inp}]}}


ev = [
    user(1800, "make the parser keep empty lines and add a count helper"),
    tool(1700, "Read", file_path=f"{repo}/src/parser.swift"),
    tool(1500, "Grep", pattern="func parse"),
    tool(1200, "Edit", file_path=f"{repo}/src/parser.swift"),
    tool(900, "Bash", command="swift build 2>&1 | tail -5"),
    tool(600, "Edit", file_path=f"{repo}/src/mod00/file0001.txt"),
    tool(300, "Write", file_path=f"{repo}/docs/new-guide.md"),
    user(200, "now merge the topic branch"),
    tool(120, "Bash", command="git merge topic"),
    tool(60, "Edit", file_path=f"{repo}/src/parser.swift"),
]
with open(os.path.join(d, "11111111-aaaa-4bbb-8ccc-222222222222.jsonl"), "w") as f:
    for e in ev:
        f.write(json.dumps(e) + "\n")
print(repo)
