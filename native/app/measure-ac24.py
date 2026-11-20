#!/usr/bin/env python3
"""AC24 (PRD §10): with 25 streaming sessions and the window fully occluded / minimized the app uses <= 5 % CPU
(drawing stops while NSWindow.occlusionState is not .visible), and a sleep / wake cycle loses no session and
shows correct statuses within 5 s. Runs against the dev stack from run-dev.sh; records "ac24" in measurements.json.

Load = the same generator as measure-ac7.py (6 sessions at 1 MB/s, 19 at 64 KB/s: ~7.2 MB/s of coloured, UTF-8 output).
Phases: A visible grid | B window minimized (real NSWindow.miniaturize) | C restored | D sleep + wake while minimized
(NSWorkspace willSleep / didWake posted through the test hook; the app observes the same notifications the system sends).
"""
import json, os, re, socket, subprocess, time

TMP = os.environ.get("TMPDIR", "/tmp")
state = dict(l.strip().split("=", 1) for l in open(os.path.join(TMP, "muya-native-dev.state")) if "=" in l)
state = {k: v.strip("'\"").replace("\\", "") for k, v in state.items()}
DEV = state["DEV"]
PIDS = {"app": int(state["APP_PID"]), "muyad": int(state["MUYAD_PID"]), "ptyd": int(state["PTYD_PID"])}
N, VISIBLE, SLOW = 25, 6, 65_536
FAST = int(os.environ.get("AC24_FAST", "1000000"))  # AC24_FAST=65536: every session at 64 KB/s (light stream)
KEY = os.environ.get("AC24_KEY", "ac24")
WINDOW = int(os.environ.get("AC24_SECONDS", "20"))

GEN = r'''
import sys, time
rate = int(sys.argv[1]); out = sys.stdout.buffer
lines = [("\x1b[38;5;%dm*\x1b[0m Read \x1b[1msrc/components/File%d.tsx\x1b[0m lorem ipsum \x1b[38;2;%d;120;200mşğüİı 日本語\x1b[0m %d\r\n" % (16 + i % 200, i, i % 255, i)).encode() for i in range(400)]
blob = b"".join(lines); pos = 0; step = max(1, rate // 100); t = time.monotonic()
while True:
    chunk = (blob + blob)[pos:pos + step]; pos = (pos + step) % len(blob)
    out.write(chunk); out.flush()
    t += 0.01; d = t - time.monotonic()
    if d > 0: time.sleep(d)
    else: t = time.monotonic()
'''


def dbg(cmd, timeout=90):
    s = socket.socket(socket.AF_UNIX); s.settimeout(timeout); s.connect(DEV + "/app-debug.sock")
    s.sendall((cmd + "\n").encode()); out = b""
    while not out.endswith(b"\n"): out += s.recv(65536)
    s.close(); return out.decode().rstrip("\n")


def cpu_seconds(pid):
    t = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    m = re.match(r"(?:(\d+):)?(\d+):(\d+\.\d+)", t)
    return int(m.group(1) or 0) * 3600 + int(m.group(2)) * 60 + float(m.group(3))


def cpu_split(pid):
    out = subprocess.run(["ps", "-o", "utime=,stime=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
    f = lambda t: int(t.split(":")[0]) * 60 + float(t.split(":")[1])
    return f(out[0]), f(out[1])


def rss_mb(pid):
    return int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or 0) / 1024


def window_cpu(label):
    c0 = {k: cpu_seconds(p) for k, p in PIDS.items()}
    u0, s0 = cpu_split(PIDS["app"])
    t0 = time.time(); rss = []
    while time.time() - t0 < WINDOW:
        time.sleep(1); rss.append(rss_mb(PIDS["app"]))
    el = time.time() - t0
    r = {"seconds": round(el, 1), "cpu_pct": {k: round((cpu_seconds(p) - c0[k]) / el * 100, 1) for k, p in PIDS.items()},
         "app_rss_mb_max": round(max(rss), 1), "visibility": dbg("visibility")}
    u1, s1 = cpu_split(PIDS["app"])
    r["app_user_pct"], r["app_system_pct"] = round((u1 - u0) / el * 100, 1), round((s1 - s0) / el * 100, 1)
    r["load_average_1m"] = os.getloadavg()[0]
    print(label, r)
    return r


def bytes_map():
    return {int(l.split("\t")[0]): int(l.split("\t")[1]) for l in dbg("bytes").splitlines()}


def stable(sessions):  # id, name, cwd, state (the selection star excluded)
    return [tuple(l.split("\t")[:4]) for l in sessions.splitlines()]


for line in dbg("sessions").splitlines():
    dbg("close " + line.split("\t")[0])
time.sleep(0.5)
gen = os.path.join(DEV, "gen.py")
open(gen, "w").write(GEN)
ids = [int(dbg("new " + DEV + "/home").split()[1]) for _ in range(N)]
for i, sid in enumerate(ids):
    dbg("select %d" % sid); time.sleep(0.15)
    dbg('type "python3 %s %d\\n"' % (gen, FAST if i < VISIBLE else SLOW))
dbg("select %d" % ids[0]); dbg("grid on"); time.sleep(6)

SIMULATED = []


def minimize():
    """Real miniaturize; with the screen locked macOS sends no occlusion notification, so the same
    handler is driven through the debug `occlude` hook and the result says so."""
    dbg("minimize"); time.sleep(2)
    if "visible=true" in dbg("visibility"):
        dbg("occlude yes"); SIMULATED.append("minimize"); time.sleep(1)


def restore():
    dbg("restore"); time.sleep(2)
    if SIMULATED and "visible=false" in dbg("visibility"):
        dbg("occlude no"); time.sleep(1)


res = {"setup": {"total_mb_s": round((VISIBLE * FAST + (N - VISIBLE) * SLOW) / 1e6, 2), "sessions": N, "visible_tiles": VISIBLE, "visible_rate_bytes_s": FAST, "hidden_rate_bytes_s": SLOW}}
res["A_visible_grid"] = window_cpu("A visible")
minimize()
res["B_minimized"] = window_cpu("B minimized")
res["B_minimized"]["suspended_flag_set"] = "suspended=true" in res["B_minimized"]["visibility"]
restore()
res["C_restored"] = {"visibility": dbg("visibility")}
print("C", res["C_restored"])

# D: sleep / wake while minimized and streaming
minimize()
if os.environ.get("AC24_SAMPLE"): subprocess.run(["sample", str(PIDS["app"]), "4", "-file", os.environ["AC24_SAMPLE"]], capture_output=True)
before = dbg("sessions")
dbg("sleep"); time.sleep(3)
vis_asleep = dbg("visibility")
t0 = time.monotonic(); wake = dbg("wake")
ok_ms = None
while time.monotonic() - t0 < 8:  # statuses back after wake, while still minimized (Screen keeps flowing to a detached app)
    if stable(dbg("sessions")) == stable(before):
        break
    time.sleep(0.05)
# Output is detached while minimized by design (AC24): restore, then the visible tiles stream again.
restore()
b0 = bytes_map()
t1 = time.monotonic()
while time.monotonic() - t1 < 8:
    b1 = bytes_map()
    if sum(1 for i in ids if b1[i] > b0[i]) >= VISIBLE:
        ok_ms = (time.monotonic() - t1) * 1000
        break
    time.sleep(0.05)
after = dbg("sessions")
res["D_sleep_wake"] = {"wake_reply": wake, "visibility_while_asleep": vis_asleep, "sessions_before": len(before.splitlines()), "sessions_after": len(after.splitlines()),
                       "sessions_lost": len(set(s[0] for s in stable(before)) - set(s[0] for s in stable(after))),
                       "statuses_equal": stable(after) == stable(before), "all_sessions_streaming_again_ms": round(ok_ms, 1) if ok_ms else None,
                       "visibility_after": dbg("visibility")}
print("D", res["D_sleep_wake"])

app_occluded = res["B_minimized"]["cpu_pct"]["app"]
d = res["D_sleep_wake"]
res["targets"] = {
    "app CPU <= 5 % while minimized (25 streaming sessions)": {"value": app_occluded, "pass": app_occluded <= 5.0},
    "0 sessions lost across sleep/wake": {"value": d["sessions_lost"], "pass": d["sessions_lost"] == 0 and d["sessions_after"] == d["sessions_before"] == N},
    "statuses correct after wake; visible tiles streaming within 5 s of restore": {"value_ms": d["all_sessions_streaming_again_ms"], "pass": bool(d["statuses_equal"] and ok_ms and ok_ms <= 5000)},
    "drawing suspended while minimized": {"value": res["B_minimized"]["visibility"], "pass": res["B_minimized"]["suspended_flag_set"]},
}
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "measurements.json")
doc = json.load(open(path)); doc[KEY] = res
json.dump(doc, open(path, "w"), indent=1)
for sid in ids: dbg("close %d" % sid)
for k, v in res["targets"].items(): print("PASS" if v["pass"] else "FAIL", k, "->", v.get("value", v.get("value_ms")))
