#!/usr/bin/env python3
"""Faz 4a measurements: CPU / RSS of the app and muyad with the Sessions page open over 500 SYNTHETIC transcripts
(idle, during a full-scan content search, during a cancelled search) and the Schedules page idle. Records "faz4a"
in measurements.json. Starts and stops its own dev stack (throwaway HOME under /tmp, minimal PATH).
"""
import json, os, re, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ["TMPDIR"] = "/tmp/muya-faz4a"  # own state file: never touches another dev stack
os.makedirs(os.environ["TMPDIR"], exist_ok=True)
N = int(os.environ.get("FAZ4A_N", "500"))
TURNS = int(os.environ.get("FAZ4A_TURNS", "60"))
env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin", MUYAD_ARGS="--scheduler", MUYA_DEV_NO_APP="1")
run = lambda *a, **k: subprocess.run(a, cwd=HERE, capture_output=True, text=True, **k)
run("./run-dev.sh", "stop", env=env)
assert run("./run-dev.sh", "start", env=env).returncode == 0, "stack did not start"


def state():
    d = dict(l.strip().split("=", 1) for l in open(os.environ["TMPDIR"] + "/muya-native-dev.state") if "=" in l)
    return {k: v.strip("'\"").replace("\\", "") for k, v in d.items()}


try:
    DEV = state()["DEV"]
    out = run("python3", "-I", "make-pages-fixtures.py", DEV + "/home", str(N), str(TURNS)).stdout.strip()
    total_bytes = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(DEV + "/home/.claude/projects") for f in fs)
    print(out, f"({total_bytes / 1e6:.0f} MB)")
    assert run("./run-dev.sh", "app", env=env).returncode == 0
    S = state()
    PIDS = {"app": int(S["APP_PID"]), "muyad": int(S["MUYAD_PID"])}
    time.sleep(3)

    def dbg(cmd, timeout=120):
        s = socket.socket(socket.AF_UNIX); s.settimeout(timeout); s.connect(DEV + "/app-debug.sock")
        s.sendall((cmd + "\n").encode()); data = b""
        while not data.endswith(b"\n"): data += s.recv(65536)
        s.close(); return data.decode().rstrip("\n")

    def cpu(pid):
        t = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        m = re.match(r"(?:(\d+):)?(\d+):(\d+\.\d+)", t)
        return int(m.group(1) or 0) * 3600 + int(m.group(2)) * 60 + float(m.group(3))

    def rss(pid):
        return round(int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or 0) / 1024, 1)

    def window(label, seconds):
        c0 = {k: cpu(p) for k, p in PIDS.items()}; t0 = time.time(); time.sleep(seconds); dt = time.time() - t0
        r = {f"{k}_cpu_pct": round((cpu(p) - c0[k]) / dt * 100, 2) for k, p in PIDS.items()}
        r.update({f"{k}_rss_mb": rss(p) for k, p in PIDS.items()}); r["seconds"] = seconds
        print(label, r); return r

    def wait_for(fn, timeout=120):
        t0 = time.time()
        while time.time() - t0 < timeout:
            v = fn()
            if v: return time.time() - t0
            time.sleep(0.02)
        raise SystemExit("timed out")

    def search_done():
        v = dbg("sessions-view").split("\n")
        return v[1] == "searching=false" and v[2] != "matches=nil"

    R = {"transcripts": N, "transcript_mb": round(total_bytes / 1e6, 1), "turns_per_transcript": TURNS}
    R["baseline_idle_no_page"] = window("idle, terminals only", 10)
    dbg("page sessions")
    R["list_load_seconds"] = round(wait_for(lambda: f"status={N} sessions" in dbg("sessions-view").split("\n")[0]), 3)
    R["sessions_page_idle"] = window("sessions page idle", 10)

    # Full scan: a term that is in no transcript, so every file is read to the end.
    c0 = {k: cpu(p) for k, p in PIDS.items()}; t0 = time.time()
    dbg("sessions-search qqqzzznotthere")
    R["search_scan_seconds"] = round(wait_for(search_done), 3)
    R["search_scan_cpu_seconds"] = {k: round(cpu(p) - c0[k], 2) for k, p in PIDS.items()}
    R["search_scan_rss_mb_after"] = {k: rss(p) for k, p in PIDS.items()}
    print("full scan", R["search_scan_seconds"], R["search_scan_cpu_seconds"])

    # A word in most transcripts: many hits, snippets rendered.
    c0 = {k: cpu(p) for k, p in PIDS.items()}
    dbg("sessions-search parser")
    R["search_common_word_seconds"] = round(wait_for(search_done), 3)
    R["search_common_word_hits"] = int(dbg("sessions-view").split("\n")[2].split("=")[1])
    R["search_common_word_cpu_seconds"] = {k: round(cpu(p) - c0[k], 2) for k, p in PIDS.items()}

    # Cancel: start the full scan, cancel after 100 ms; muyad must stop reading.
    dbg("sessions-search qqqzzznotthere2"); time.sleep(0.1)
    t0 = time.time(); dbg("sessions-cancel"); R["cancel_ui_ms"] = round((time.time() - t0) * 1000, 1)
    time.sleep(0.3); c0 = cpu(PIDS["muyad"]); time.sleep(2)
    R["muyad_cpu_pct_2s_after_cancel"] = round((cpu(PIDS["muyad"]) - c0) / 2 * 100, 2)
    print("cancel", R["cancel_ui_ms"], "ms; muyad after:", R["muyad_cpu_pct_2s_after_cancel"], "%")
    dbg("sessions-search ")
    R["sessions_page_idle_after_search"] = window("sessions page idle after search", 10)

    dbg("page schedules"); time.sleep(1)
    R["schedules_page_idle"] = window("schedules page idle (3 s poll)", 10)
    dbg("page none"); time.sleep(1)
    R["back_to_terminals_idle"] = window("terminals only again", 10)

    path = os.path.join(HERE, "measurements.json")
    data = json.load(open(path)); data["faz4a"] = R
    json.dump(data, open(path, "w"), indent=2); open(path, "a").write("\n")
    print("recorded faz4a")
finally:
    run("./run-dev.sh", "stop", env=env)
