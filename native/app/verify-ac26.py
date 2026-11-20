#!/usr/bin/env python3 -I
"""AC26: accessibility + keyboard audit of every surface of the native app.

Starts its own dev stack (TMPDIR=/tmp/muya-ac26, fake HOME with synthetic fixtures, own sockets; it stops only the
PIDs it started), opens each view / dialog / sheet through the debug socket and checks:
  * accessibility: the NSAccessibility hierarchy of every visible window and sheet (`ax-tree`, the objects the AX
    server serialises) has 0 interactive controls without a label; every enabled control can take keyboard focus;
  * keyboard: real key events (NSEvent keyDown through window.sendEvent, the path of a keyboard minus the HID layer)
    move through the list, the dialogs, the tree and the palette, and Esc / Return behave.
The external AXUIElement walk (tools/ax-audit.swift) is also run first; when the session cannot use it (locked screen
-> the AX server answers with a flat application element) the script says so and the in-app walk stands in.
The SSH & Passwords sheets run in tools/ssh-shots.swift (fake daemon) with the same audit; see verify-ssh.sh.

  python3 -I verify-ac26.py     records "ac26" in measurements.json, exit 1 on any failure
"""
import json, os, re, shutil, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = "/tmp/muya-ac26"  # short: unix socket paths are limited to 104 bytes
os.makedirs(TMP, exist_ok=True)
ENV = dict(os.environ, TMPDIR=TMP)
STATE = os.path.join(TMP, "muya-native-dev.state")
FAILS = []
RESULTS = {"surfaces": [], "keyboard": []}
SHOTS = os.path.join(HERE, "screenshots")


def sh(*args, env=None, check=True):
    return subprocess.run(args, cwd=HERE, env=env or ENV, capture_output=True, text=True, check=check).stdout


def state():
    out = {}
    for line in open(STATE):
        k, _, v = line.strip().partition("=")
        out[k] = v.strip("'\"").replace("\\", "")
    return out


class Dbg:
    def __init__(self, path): self.path = path

    def __call__(self, cmd, timeout=10):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(timeout)
        try:
            s.connect(self.path)
            s.sendall((cmd + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk: break
                buf += chunk
            return buf.decode("utf-8", "replace").rstrip("\n")
        except Exception as e:
            return f"error: {e}"
        finally:
            s.close()


def ok(cond, what, detail=""):
    print(("PASS " if cond else "FAIL ") + what + ("" if cond or not detail else f": {detail}"))
    if not cond: FAILS.append(what)
    return cond


def parse_audit(text):
    head, *rest = text.split("\n")
    m = dict(kv.split("=", 1) for kv in head.split(" ") if "=" in kv)
    return {"windows": int(m.get("windows", 0)), "elements": int(m.get("elements", 0)), "interactive": int(m.get("interactive", 0)),
            "unlabelled": int(m.get("unlabelled", -1)), "lines": [l.strip() for l in rest if l.strip().startswith("UNLABELLED")]}


def focusable_report(dbg, target):
    rows = [l.split("\t") for l in dbg(f"keycontrols {target}").split("\n") if "\t" in l]
    return rows, [f"{r[0]} '{r[1]}'" for r in rows if len(r) > 2 and r[2] == "no"]


def audit(dbg, name, target="main", min_interactive=1, settle=0.6):
    """ax-tree of all visible windows + keycontrols of the target window."""
    time.sleep(settle)
    a = parse_audit(dbg("ax-tree"))
    rows, stuck = ([], [])
    if target:
        rows, stuck = focusable_report(dbg, target)
    good = (a["unlabelled"] == 0 and a["interactive"] >= min_interactive and not stuck)
    RESULTS["surfaces"].append({"surface": name, "interactive": a["interactive"], "unlabelled": a["unlabelled"], "controls_checked_for_focus": len(rows), "not_focusable": stuck})
    ok(good, f"AX {name}: {a['interactive']} controls, {a['unlabelled']} unlabelled, {len(rows)} focus-checked, {len(stuck)} not focusable",
       "; ".join(a["lines"] + stuck))
    return a


def keyboard(name, cond, detail=""):
    RESULTS["keyboard"].append({"check": name, "pass": bool(cond)})
    ok(cond, f"keyboard {name}", detail)


def focus_cycle(dbg, target, presses=14, key="tab"):
    """Presses Tab `presses` times at the window; returns the focus labels visited in order."""
    seen = [dbg(f"focusin {target}")]
    for _ in range(presses):
        dbg(f"pressin {target} {key}")
        time.sleep(0.08)
        seen.append(dbg(f"focusin {target}"))
    return seen


def main():
    if os.path.exists(STATE):
        sh("./run-dev.sh", "stop", check=False)
    sh("./run-dev.sh", "start", env=dict(ENV, MUYA_DEV_NO_APP="1"))
    st = state()
    DEV = st["DEV"]
    home = os.path.join(DEV, "home")
    try:
        sh("python3", "-I", "make-pages-fixtures.py", home, "12")
        sh("python3", "-I", "make-4e-fixtures.py", home)
        inspector_repo = sh("python3", "-I", "make-inspector-fixtures.py", home, "200").strip().splitlines()[-1]
        queue_repo = sh("python3", "-I", "make-queue-fixtures.py", home, "300").strip().splitlines()[-1]
        files_dir = os.path.join(home, "view")
        sh("python3", "make-fixtures.py", files_dir)
        sh("./run-dev.sh", "app")
        st = state()
        dbg = Dbg(os.path.join(DEV, "app-debug.sock"))
        for _ in range(60):
            if dbg("windowid").isdigit(): break
            time.sleep(0.25)
        for line in dbg("sessions").split("\n"):
            if line.strip(): dbg("close " + line.split("\t")[0])
        sid = dbg(f"new {files_dir}").split()[-1]
        time.sleep(1.5)
        run(dbg, DEV, home, files_dir, inspector_repo, queue_repo, st)
    finally:
        sh("./run-dev.sh", "stop", check=False)
        shutil.rmtree(TMP, ignore_errors=True)
    # SSH & Passwords sheets and sections: the page's own tool (fake daemon) with the same tree audit.
    r = subprocess.run(["bash", "verify-ssh.sh"], cwd=HERE, capture_output=True, text=True)
    ax = [l[3:] for l in r.stdout.splitlines() if l.startswith("AX ")]
    for l in ax:
        name, _, rest = l.partition(": ")
        m = dict(kv.split("=", 1) for kv in rest.split(" ") if "=" in kv)
        RESULTS["surfaces"].append({"surface": name + " (ssh-shots, fake daemon)", "interactive": int(m.get("interactive", 0)), "unlabelled": int(m.get("unlabelled", -1)), "controls_checked_for_focus": 0, "not_focusable": []})
    ok(r.returncode == 0 and ax and all("unlabelled=0" in l for l in ax), f"SSH & Passwords sections and forms ({len(ax)} surfaces, verify-ssh.sh)", r.stdout[-300:])
    finish()


def run(dbg, DEV, home, files_dir, inspector_repo, queue_repo, st):
    app_pid = st["APP_PID"]
    # ---- the external Accessibility API first: does this session see the app's windows at all?
    ext = subprocess.run([os.path.join(HERE, "build/ax-audit"), app_pid], capture_output=True, text=True)
    ext_ok = ext.returncode in (0, 1) and "interactive=" in ext.stdout
    locked = "CGSSessionScreenIsLocked" in sh("ioreg", "-n", "Root", "-d1", "-a") and "<true/>" in sh("sh", "-c", "ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked")
    RESULTS["external_axuielement"] = {"usable": ext_ok, "screen_locked": locked, "exit": ext.returncode, "first_line": (ext.stdout.strip().splitlines() or [""])[0][:200]}
    print(f"external AXUIElement walk: usable={ext_ok} (exit {ext.returncode}, screen locked={locked}) -> "
          + ("used as a second opinion" if ext_ok else "in-app NSAccessibility walk is the audit"))
    if ext_ok:
        ok("unlabelled=0" in ext.stdout.replace(" ", "") or "unlabelled=0" in ext.stdout, "external AXUIElement walk: every control speaks", ext.stdout[:300])

    # ---- Terminals (main window: sidebar, terminal, file tree)
    audit(dbg, "Terminals (sidebar, terminal, file tree)", "main", 8)
    dbg("grid on"); audit(dbg, "Terminals, grid view", "main", 1, 1.0); dbg("grid off"); time.sleep(0.6)
    # file viewers
    for label, name in (("image viewer", "assets/gradient.png"), ("PDF viewer", "docs/report.pdf"), ("text viewer", "docs/notes.md"),
                        ("source viewer", "src/main.rs"), ("binary / hex viewer", "data/blob.bin")):
        path = os.path.join(files_dir, name)
        if not os.path.exists(path):
            cand = [f for f in os.listdir(os.path.dirname(path))] if os.path.isdir(os.path.dirname(path)) else []
            print(f"note: {name} missing ({cand[:6]})")
            continue
        dbg(f"viewer-open {path}")
        audit(dbg, f"File {label}", "main", 8, 1.0)
        dbg("viewer-close")
    # ---- Sessions
    dbg("page sessions"); audit(dbg, "Sessions", "main", 3, 1.0)
    dbg("sessions-search zebra"); audit(dbg, "Sessions, search results", "main", 3, 1.0); dbg("sessions-cancel")
    dbg("cleanup-open"); audit(dbg, "Sessions, Clean up dialog", "sheet", 3, 1.0); dbg("cleanup-close"); time.sleep(0.5)
    sess = dbg("sessions-view")
    ids = re.findall(r"\b(0000[0-9a-f]{4})\b", sess)
    tid = "00000020" if "00000020" in sess else (ids[0] if ids else "00000000")
    dbg(f"transcript-open {tid}"); audit(dbg, "Sessions, transcript drawer", "main", 3, 1.2); dbg("transcript-close")
    # ---- Schedules
    dbg("page schedules"); time.sleep(0.8)
    os.makedirs(os.path.join(home, "work", "report"), exist_ok=True)
    dbg("sched-new")
    for kv in ("name Nightly report", "prompt Summarise the open issues in this project", f"folder {os.path.join(home, 'work', 'report')}", "kind interval", "minutes 60"):
        dbg("sched-set " + kv)
    dbg("sched-save"); time.sleep(0.8)
    audit(dbg, "Schedules", "main", 3, 1.0)
    dbg("sched-new"); audit(dbg, "Schedules, new-schedule editor", "sheet", 4, 1.0); dbg("sched-cancel"); time.sleep(0.5)
    dbg("sprompt-open"); audit(dbg, "Scheduled Prompt sheet", "sheet", 3, 1.0); dbg("sprompt-close"); time.sleep(0.5)
    names = [l.split("\t")[0] for l in dbg("sched-view").split("\n") if "\t" in l]
    if names:
        dbg(f"sched-history {names[0]}"); audit(dbg, "Schedules, run history", "main", 3, 1.0); dbg("sched-history-close")
    dbg("page none"); time.sleep(0.4)
    # ---- Settings + licences
    dbg("settings-open"); audit(dbg, "Settings", "settings", 8, 1.0)
    dbg("licences-open"); audit(dbg, "Settings, licences sheet", "settings-sheet", 0, 1.0); dbg("licences-close"); dbg("settings-close"); time.sleep(0.5)
    # ---- Command palette
    dbg("palette-open"); audit(dbg, "Command palette", "main", 2, 0.8)
    dbg("palette-query new"); audit(dbg, "Command palette, results", "main", 2, 0.5); dbg("palette-close"); time.sleep(0.4)
    # ---- Inspector (a session inside the git fixture)
    dbg(f"new {inspector_repo}"); time.sleep(2.5)
    for tab in ("changes", "files", "activity"):
        dbg(f"inspector-tab {tab}"); audit(dbg, f"Inspector, {tab}", "main", 8, 3.0)
    dbg("inspector-tab off")
    # ---- Queue / Branches / Kanban
    dbg(f"new {queue_repo}"); time.sleep(2.0); dbg(f"queue-cwd {queue_repo}")
    for tab in ("queue", "branches", "kanban"):
        dbg(f"queue-page {tab}"); time.sleep(2.0); audit(dbg, f"Queue page, {tab}", "main", 3, 1.5)
    dbg("page none"); time.sleep(0.4)
    # ---- SSH & Passwords (the app against a daemon without the SSH calls: the not-available state)
    dbg("menu-item SSH & Passwords"); audit(dbg, "SSH & Passwords (app, daemon without the SSH calls)", "main", 3, 1.5)
    dbg("page none"); time.sleep(0.4)

    keyboard_tests(dbg, DEV, files_dir)


def keyboard_tests(dbg, DEV, files_dir):
    print("== keyboard")
    # Sessions page: search box -> Tab -> list; arrows move the selection; Esc leaves
    dbg("page sessions"); dbg("sessions-search"); dbg("sessions-reload"); time.sleep(1.0) # a clean, unfiltered list
    # Today's page does not focus the search box on arrival (no focus ring): the page itself has the keyboard, the first Tab lands in the search box, the next in the list.
    keyboard("Sessions: the page has the keyboard (search not auto-focused)", "SessionsPage" in dbg("focus"), dbg("focus"))
    dbg("pressin main tab"); time.sleep(0.2)
    keyboard("Sessions: the first Tab lands in the search box", "Search sessions" in dbg("focus"), dbg("focus"))
    dbg("pressin main tab"); time.sleep(0.2)
    keyboard("Sessions: the next Tab moves to the list", "Sessions list" in dbg("focus"), dbg("focus"))
    s0 = dbg("sessions-selected")
    dbg("pressin main down"); time.sleep(0.4); s1 = dbg("sessions-selected")
    dbg("pressin main down"); time.sleep(0.4); s2 = dbg("sessions-selected")
    dbg("pressin main up"); time.sleep(0.4); s3 = dbg("sessions-selected")
    keyboard("Sessions: Down / Up move the selection through the list", s0 != s1 and s1 != s2 and s3 == s1, f"{s0} {s1} {s2} {s3}")
    dbg("pressin main esc"); time.sleep(0.5)
    keyboard("Sessions: Esc returns focus to the terminal", "TerminalView" in dbg("focus"), dbg("focus"))
    dbg("page none")

    # Schedules list: arrows + Return open the editor; Tab cycles the editor's fields; Esc cancels
    dbg("page schedules"); time.sleep(1.0)
    f0 = dbg("focus")
    for _ in range(25):   # the page takes focus after its list loads; a busy machine needs longer than a fixed 1 s
        if "label=" in f0: break
        time.sleep(0.2); f0 = dbg("focus")
    keyboard("Schedules: focus lands in a control of the page (not lost)", "label=" in f0 and "TerminalView" not in f0, f0)
    dbg("pressin main down"); dbg("pressin main return"); time.sleep(0.6)
    ed = dbg("sched-editor")
    keyboard("Schedules: arrow keys + Return open the editor from the list", "Edit schedule" in ed, ed[:80])
    if "Edit schedule" in ed:
        rows, _ = focusable_report(dbg, "sheet")
        fields = [r for r in rows if r[0] in ("NSTextField", "NSTextView", "NSTableView")]
        seen = focus_cycle(dbg, "sheet", len(fields) + 3)
        distinct = {s for s in seen if s}
        keyboard(f"Schedules editor: Tab visits every text field ({len(fields)}) and wraps without a trap", len(distinct) >= max(2, len(fields)) and seen[0] in seen[1:], f"visited {sorted(distinct)}")
        dbg("pressin sheet esc"); time.sleep(0.5)
        keyboard("Schedules editor: Esc cancels", dbg("sched-editor") == "none", dbg("sched-editor"))
    dbg("page none")

    # Cleanup dialog: Tab cycle + Esc
    dbg("cleanup-open"); time.sleep(0.8)
    rows, _ = focusable_report(dbg, "sheet")
    fields = [r for r in rows if r[0] in ("NSTextField", "NSTableView")]
    seen = focus_cycle(dbg, "sheet", len(fields) + 3)
    keyboard("Clean up dialog: Tab reaches its fields and wraps", len({s for s in seen if s}) >= 1 and seen[0] in seen[1:] or len(fields) <= 1, f"{seen[:4]}")
    dbg("pressin sheet esc"); time.sleep(0.5)
    keyboard("Clean up dialog: Esc closes it", dbg("cleanup-view") == "none", dbg("cleanup-view")[:60])
    dbg("page none")

    # Scheduled Prompt sheet
    dbg("sprompt-open"); time.sleep(0.8)
    seen = focus_cycle(dbg, "sheet", 8)
    keyboard("Scheduled Prompt: Tab moves between its fields and wraps (the prompt box does not eat Tab)", len({s for s in seen if s}) >= 2 and seen[0] in seen[1:], f"{sorted({s for s in seen if s})}")
    dbg("pressin sheet esc"); time.sleep(0.5)
    keyboard("Scheduled Prompt: Esc closes it", dbg("sprompt-view") in ("none", ""), dbg("sprompt-view")[:60])

    # Settings: Tab between its text fields without a trap; Esc closes
    dbg("settings-open"); time.sleep(0.8)
    seen = focus_cycle(dbg, "settings", 6)
    keyboard("Settings: Tab cycles between its text fields and wraps", len({s for s in seen if s}) >= 2 and seen[0] in seen[1:], f"{sorted({s for s in seen if s})}")
    dbg("pressin settings esc"); time.sleep(0.5)
    keyboard("Settings: Esc closes the window", dbg("settings-visible") == "no", dbg("settings-visible"))

    # Palette: type, arrows, Return, Esc
    dbg("palette-open"); time.sleep(0.6)
    keyboard("Palette: focus starts in the search field", "Command palette search" in dbg("focus"), dbg("focus"))
    dbg("pressin main esc"); time.sleep(0.4)
    keyboard("Palette: Esc closes it and focus returns to the terminal", "closed" in dbg("palette-state") and "TerminalView" in dbg("focus"), dbg("focus"))

    # File tree: arrows walk, Right expands, Left collapses, Return opens the file
    dbg(f"new {files_dir}"); time.sleep(1.5)
    dbg("files-focus"); time.sleep(0.2)
    keyboard("Tree: focus lands in the file tree", "File tree" in dbg("focus"), dbg("focus"))
    first = dbg("files-selected")
    dbg("pressin main down"); time.sleep(0.2); second = dbg("files-selected")
    keyboard("Tree: Down moves the selection", first != second, f"{first!r} -> {second!r}")
    # walk down to a folder that is collapsed, expand it with Right, collapse with Left
    folder = None
    for _ in range(12):
        cur = dbg("files-selected")
        if cur.endswith("collapsed"): folder = cur; break
        dbg("pressin main down"); time.sleep(0.15)
    if folder:
        dbg("pressin main right"); time.sleep(0.4)
        expanded = dbg("files-selected").endswith("expanded")
        dbg("pressin main left"); time.sleep(0.4)
        collapsed = dbg("files-selected").endswith("collapsed")
        keyboard("Tree: Right expands a folder and Left collapses it", expanded and collapsed, folder)
    else:
        keyboard("Tree: a collapsed folder was found to test Right / Left", False, "none within 12 rows")
    dbg("files-select " + os.path.join(files_dir, "README.txt")); time.sleep(0.2)
    dbg("pressin main return"); time.sleep(0.8)
    keyboard("Tree: Return opens the selected file in a viewer", dbg("viewer") != "hidden", dbg("viewer")[:80])
    dbg("viewer-close")


def finish():
    unlabelled = sum(s["unlabelled"] for s in RESULTS["surfaces"])
    stuck = sum(len(s["not_focusable"]) for s in RESULTS["surfaces"])
    out = {"surfaces_audited": len(RESULTS["surfaces"]), "interactive_controls": sum(s["interactive"] for s in RESULTS["surfaces"]),
           "unlabelled_controls": unlabelled, "controls_not_keyboard_focusable": stuck,
           "keyboard_checks": len(RESULTS["keyboard"]), "keyboard_failed": [k["check"] for k in RESULTS["keyboard"] if not k["pass"]],
           "audit_source": "in-app NSAccessibility walk" if not RESULTS.get("external_axuielement", {}).get("usable") else "external AXUIElement + in-app",
           "external_axuielement": RESULTS.get("external_axuielement"), "surfaces": RESULTS["surfaces"], "pass": not FAILS}
    path = os.path.join(HERE, "measurements.json")
    d = json.load(open(path)); d["ac26"] = out
    json.dump(d, open(path, "w"), indent=1); open(path, "a").write("\n")
    print(f"AC26 {'PASS' if not FAILS else 'FAIL (%d)' % len(FAILS)}: {out['surfaces_audited']} surfaces, {out['interactive_controls']} controls, "
          f"{unlabelled} unlabelled, {stuck} not focusable, {len(RESULTS['keyboard'])} keyboard checks")
    sys.exit(0 if not FAILS else 1)


if __name__ == "__main__":
    main()
