#!/usr/bin/env python3
"""Captures the AC3 screen corpus: real Claude Code TUIs (several versions, widths and scenarios)
talking to the local mock API (mock-api.py), recorded by native/spikes/crash-iso's `capture`.
Everything runs under a throw-away HOME/cwd below /private/tmp/muya-corpus — no login, no cost.

  corpus.py <out-dir> [--jobs N] [--widths 60,80,...] [--versions 2.1.317,2.1.310] [--only name,name]

Output per screen: <out>/<scenario>-v<ver>-w<W>-<snap>.txt (the screen as text, one line per row)
and .bin.gz (every byte the program printed up to that screen).
"""
import argparse, gzip, json, os, shutil, subprocess, sys, threading, time, queue
from pathlib import Path

HERE = Path(__file__).resolve().parent
CAPTURE = HERE / "../../spikes/crash-iso/target/release/capture"
ROOT = Path("/private/tmp/muya-corpus")
PORT = 18999
KEY = "sk-ant-api03-mockmockmockmockmockmockmock0000AAAA"  # git-verify:allow gitleaks:allow (fake key, local mock API)
VERSIONS_DIR = Path.home() / ".local/share/claude/versions"

# scenario -> (claude args, needs trusted project, extra config, steps)
IDLE = "wait-for ❯\nwait 4000\n"
SCEN = {
    "free": ("", {}, IDLE + """snap idle
key shift-tab
wait 1200
snap mode1
key shift-tab
wait 1200
snap mode2
key shift-tab
wait 1200
snap mode3
type /
wait 1500
snap slash
type he
wait 1200
snap slash-filtered
key esc
wait 800
snap slash-closed
"""),
    "think": ("--permission-mode default", {}, IDLE + """type think about a short story
wait 400
key enter
snaps think 12 1500
"""),
    "story": ("--permission-mode default", {}, IDLE + """type tell me a story
wait 400
key enter
snaps story 8 1500
"""),
    "bash": ("--permission-mode default", {}, IDLE + """type run a bash command
wait 400
key enter
wait-for proceed
snap dialog
choose Yes
wait 4000
snap approved
""" ),
    "write": ("--permission-mode default", {}, IDLE + """type write a file
wait 400
key enter
wait-for create
snap dialog
key esc
wait 3500
snap rejected
"""),
    "edit": ("--permission-mode default", {}, IDLE + """type edit the notes
wait 400
key enter
wait-for edit
snap dialog
choose Yes
wait 4000
snap approved
"""),
    "mcp": ("--permission-mode default --mcp-config {MCP}", {}, IDLE + """type call the mcp tool
wait 400
key enter
wait-for proceed
snap dialog
key esc
wait 3500
snap rejected
"""),
    "plan": ("--permission-mode plan", {}, IDLE + """snap idle
type make a plan
wait 400
key enter
wait-for Exit plan
snap dialog
key esc
wait 3000
snap rejected
"""),
    "acceptedits": ("--permission-mode acceptEdits", {}, IDLE + """snap idle
type edit the notes
wait 400
key enter
wait 6000
snap done
"""),
    "todo": ("--permission-mode default", {}, IDLE + """type make a todo list
wait 400
key enter
wait 5000
snap list
wait 3000
snap after
"""),
    "long": ("--permission-mode default", {}, IDLE + """type show long output
wait 400
key enter
wait 1500
snap during
wait 5000
snap done
"""),
    "trust": ("", {"trust": False}, """wait-for trust this folder
wait 1500
snap dialog
"""),
    "apikey": ("", {"approved": False}, """wait 9000
snap dialog
"""),
    "theme": ("", {"onboarded": False}, """wait 9000
snap dialog
"""),
    "bypass": ("--permission-mode bypassPermissions", {}, """wait-for Bypass
wait 1500
snap dialog
"""),
}
LIGHT = {"trust", "apikey", "theme", "bypass"}


def config(home, proj, c):
    d = {"theme": "dark", "numStartups": 20}
    if c.get("onboarded", True):
        d["hasCompletedOnboarding"] = True
    if c.get("approved", True):
        d["customApiKeyResponses"] = {"approved": [KEY[-20:]], "rejected": []}
    if c.get("trust", True):
        d["projects"] = {str(proj): {"hasTrustDialogAccepted": True, "allowedTools": [], "hasCompletedProjectOnboarding": True}}
    (home / ".claude.json").write_text(json.dumps(d))


def job(out, scen, ver, w, n):
    args, c, steps = SCEN[scen]
    base = ROOT / f"j{n}"
    shutil.rmtree(base, ignore_errors=True)
    home, proj, raw = base / "home", base / "project", base / "raw"
    for d in (home / ".claude", proj, raw):
        d.mkdir(parents=True)
    (proj / "notes.txt").write_text("alpha line\nsecond line\n")
    mcp = base / "mcp.json"
    mcp.write_text(json.dumps({"mcpServers": {"fake": {"command": "/usr/bin/python3", "args": [str(HERE / "mcp-fake.py")]}}}))
    config(home, proj, c)
    cmd = (f"cd {proj} && exec env HOME={home} TERM=xterm-256color LANG=en_US.UTF-8 SHELL=/bin/zsh "
           f"ANTHROPIC_BASE_URL=http://127.0.0.1:{PORT} ANTHROPIC_API_KEY={KEY} DISABLE_AUTOUPDATER=1 "
           f"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_TELEMETRY=1 {VERSIONS_DIR / ver} " + args.replace("{MCP}", str(mcp)))
    script = base / "steps"
    script.write_text(f"size {w}x40\nrun {cmd}\n{steps}\nkey ctrl-c\nwait 300\nkey ctrl-c\nwait 500\n")
    try:
        r = subprocess.run([str(CAPTURE), str(raw), str(script)], capture_output=True, text=True, timeout=240)
    except subprocess.TimeoutExpired:
        return f"{scen} v{ver} w{w}: TIMEOUT", 0
    got = sorted(raw.glob("*.txt"))
    for t in got:
        stem = f"{scen}-v{ver}-w{w}-{t.stem}"
        shutil.copy(t, out / f"{stem}.txt")
        with gzip.open(out / f"{stem}.bin.gz", "wb", 9) as g:
            g.write(t.with_suffix(".bin").read_bytes())
    shutil.rmtree(base, ignore_errors=True)
    msg = f"{scen} v{ver} w{w}: {len(got)} screens"
    if r.returncode != 0:
        msg += " (capture failed: " + r.stderr.strip().splitlines()[-1][:120] + ")" if r.stderr.strip() else " (capture failed)"
    return msg, len(got)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--widths", default="60,80,100,120,160,200,240")
    ap.add_argument("--versions", default="2.1.317,2.1.310")
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    only = set(a.only.split(",")) - {""}
    q = queue.Queue()
    n = 0
    for scen in SCEN:
        if only and scen not in only:
            continue
        for ver in a.versions.split(","):
            for w in a.widths.split(","):
                if scen in LIGHT and int(w) not in (60, 120, 240):
                    continue
                q.put((scen, ver, int(w), n))
                n += 1
    total = [0]
    lock = threading.Lock()

    def worker():
        while True:
            try:
                scen, ver, w, i = q.get_nowait()
            except queue.Empty:
                return
            msg, k = job(out, scen, ver, w, i)
            with lock:
                total[0] += k
                print(f"[{total[0]:4d}] {msg}", flush=True)

    ts = [threading.Thread(target=worker) for _ in range(a.jobs)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    print("screens:", total[0])


main()
