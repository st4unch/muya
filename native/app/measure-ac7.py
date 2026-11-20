#!/usr/bin/env python3
"""AC7 (PRD §10): 25 sessions streaming, 6 visible in the grid. Measures fps, frame time, input echo,
session switch and app memory against the dev stack from run-dev.sh and records them in
measurements.json under "ac7" with PASS/FAIL per target.

  fps               frames drawn per visible tile per second (the grid draws on demand, so this is
                    "frames the stream asked for", capped by the display refresh)
  frame p95         CPU time (cell update + encode) + GPU time of the same frame, p95 over all tiles
  echo p50          one typed character -> next finished frame that shows its echo (input -> muyad ->
                    ptyd -> tty echo -> muyad -> app replica -> Metal frame), in the grid, under load
  switch p50        select another session in the single view -> first finished frame of it (includes
                    resizing that session to the view)
  RSS               app resident memory (ps rss) and phys_footprint, peak over the run

Load: the same generator muya-load uses (Claude-like coloured output, UTF-8, wide glyphs):
the 6 visible sessions at 1 MB/s each, the 19 hidden at 64 KB/s each.
"""
import json, os, random, re, socket, subprocess, sys, time

TMP = os.environ.get("TMPDIR", "/tmp")
state = dict(l.strip().split("=", 1) for l in open(os.path.join(TMP, "muya-native-dev.state")) if "=" in l)
state = {k: v.strip("'\"").replace("\\", "") for k, v in state.items()}
DEV = state["DEV"]
PIDS = {"app": int(state["APP_PID"]), "muyad": int(state["MUYAD_PID"]), "ptyd": int(state["PTYD_PID"])}
# AC8 run: AC7_N=100 AC7_VISIBLE=1 AC7_FAST=65536 AC7_GRID=0 AC7_KEY=ac8 (single view, 100 sessions at 64 KB/s).
N, VISIBLE = int(os.environ.get("AC7_N", "25")), int(os.environ.get("AC7_VISIBLE", "6"))
FAST, SLOW, SECONDS = int(os.environ.get("AC7_FAST", "1000000")), 65_536, int(os.environ.get("AC7_SECONDS", "30"))
GRID, KEY = os.environ.get("AC7_GRID", "1") == "1", os.environ.get("AC7_KEY", "ac7")

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

def dbg(cmd, timeout=15):
    s = socket.socket(socket.AF_UNIX); s.settimeout(timeout); s.connect(DEV + "/app-debug.sock")
    s.sendall((cmd + "\n").encode()); out = b""
    while not out.endswith(b"\n"): out += s.recv(65536)
    s.close(); return out.decode().rstrip("\n")

def cpu_seconds(pid):
    t = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    m = re.match(r"(?:(\d+):)?(\d+):(\d+\.\d+)", t)
    return int(m.group(1) or 0) * 3600 + int(m.group(2)) * 60 + float(m.group(3))

def footprint_mb(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s*([\d.]+)\s*(KB|MB|GB)", out)
    return float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)] if m else float("nan")

def rss_mb(pid):
    return int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or 0) / 1024

def gpu_util():
    out = subprocess.run(["ioreg", "-r", "-d", "1", "-w0", "-c", "IOAccelerator"], capture_output=True, text=True).stdout
    m = re.search(r'"Device Utilization %"=(\d+)', out)
    return int(m.group(1)) if m else None

def pct(v, p):
    v = sorted(x for x in v if x == x)
    return v[min(len(v) - 1, max(0, int(-(-len(v) * p // 1)) - 1))] if v else float("nan")

# --- set up: 25 sessions, generators started
for line in dbg("sessions").splitlines():
    dbg("close " + line.split("\t")[0])
time.sleep(0.5)
gen = os.path.join(DEV, "gen.py")
open(gen, "w").write(GEN)
ids = []
for i in range(N):
    r = dbg("new " + DEV + "/home")
    ids.append(int(r.split()[1]))
for i, sid in enumerate(ids):
    dbg("select %d" % sid)
    time.sleep(0.15)
    dbg('type "python3 %s %d\\n"' % (gen, FAST if i < VISIBLE else SLOW))
dbg("select %d" % ids[0])
dbg("grid on" if GRID else "grid off")
if GRID: dbg("grid-layout " + os.environ.get("AC7_LAYOUT", "3x2"))   # 3x2 = the 6 tiles of the first AC7 run; today's default grid is 2x2 (AC7_LAYOUT=2x2, AC7_VISIBLE=4)
time.sleep(6)  # warm up: atlas filled, shells busy, resizes settled
tiles = dbg("tiles").splitlines()
assert len(tiles) == VISIBLE, tiles

# --- window: fps / frame time / CPU / memory under load
c0 = {k: cpu_seconds(p) for k, p in PIDS.items()}
b0 = {int(l.split("\t")[0]): int(l.split("\t")[1]) for l in dbg("bytes").splitlines()}
dbg("metrics-reset")
t0 = time.time(); fp = {k: [] for k in PIDS}; rss = []; gpu = []
while time.time() - t0 < SECONDS:
    time.sleep(1)
    gpu.append(gpu_util()); rss.append(rss_mb(PIDS["app"]))
    for k, p in PIDS.items(): fp[k].append(footprint_mb(p))
el = time.time() - t0
m = json.loads(dbg("metrics"))
b1 = {int(l.split("\t")[0]): int(l.split("\t")[1]) for l in dbg("bytes").splitlines()}
delivered = {sid: b1[sid] - b0[sid] for sid in ids}
cpu = {k: round((cpu_seconds(p) - c0[k]) / el * 100, 1) for k, p in PIDS.items()}

# --- echo: grid, everything streaming
echo = []
for _ in range(40):
    r = dbg("probe-echo Q")
    if r.replace(".", "", 1).isdigit(): echo.append(float(r))
    time.sleep(0.15)

# --- switch: single view, any of the 25 sessions (hidden ones are live replicas too)
dbg("grid off"); time.sleep(1.5)
sw = []
order = ids[:]
random.Random(7).shuffle(order)
for sid in (order * 2)[:50]:
    r = dbg("probe-switch %d" % sid)
    if r.replace(".", "", 1).isdigit(): sw.append(float(r))
    time.sleep(0.12)
# and focus changes inside the grid
dbg("select %d" % ids[0]); dbg("grid on" if GRID else "grid off"); time.sleep(1.5)
focus = []
for sid in ((ids[:VISIBLE] * 6)[:36] if GRID else []):
    r = dbg("probe-switch %d" % sid)
    if r.replace(".", "", 1).isdigit(): focus.append(float(r))
    time.sleep(0.12)
rss_after = rss_mb(PIDS["app"])

for sid in ids: dbg("close %d" % sid)

fps = m["fps_per_tile"]
res = {
  "setup": {"sessions": N, "visible_tiles": VISIBLE, "visible_rate_bytes_s": FAST, "hidden_rate_bytes_s": SLOW, "window_seconds": round(el, 1)},
  "load_delivered_mb_s": {"visible_sessions_mean": round(sum(delivered[s] for s in ids[:VISIBLE]) / VISIBLE / el / 1e6, 2),
                          "hidden_sessions_mean": round(sum(delivered[s] for s in ids[VISIBLE:]) / (N - VISIBLE) / el / 1e6, 3)},
  "fps_per_tile": round(fps, 1), "tiles_drawing": m["tiles_drawing"],
  "frame_ms": {"p50": round(m["frame_ms_p50"], 2), "p95": round(m["frame_ms_p95"], 2), "max": round(m["frame_ms_max"], 1)},
  "cpu_ms": {"p50": round(m["cpu_ms_p50"], 2), "p95": round(m["cpu_ms_p95"], 2)},
  "gpu_ms": {"p50": round(m["gpu_ms_p50"], 2), "p95": round(m["gpu_ms_p95"], 2)},
  "frame_interval_ms": {"p50": round(m["interval_ms_p50"], 1), "p95": round(m["interval_ms_p95"], 1)},
  "echo_ms": {"n": len(echo), "p50": round(pct(echo, .5), 1), "p95": round(pct(echo, .95), 1), "max": round(max(echo), 1) if echo else None},
  "switch_single_view_ms": {"n": len(sw), "p50": round(pct(sw, .5), 1), "p95": round(pct(sw, .95), 1), "max": round(max(sw), 1) if sw else None},
  "focus_change_in_grid_ms": {"n": len(focus), "p50": round(pct(focus, .5), 1), "p95": round(pct(focus, .95), 1)},
  "cpu_pct": cpu,
  "app_rss_mb": {"peak": round(max(rss), 1), "after": round(rss_after, 1)},
  "footprint_mb_peak": {k: round(max(v), 1) for k, v in fp.items()},
  "gpu_util_pct_system": [g for g in gpu if g is not None],
}
res["targets"] = {
  "fps >= 55":        {"value": res["fps_per_tile"], "pass": res["fps_per_tile"] >= 55},
  "frame p95 <= 25 ms": {"value": res["frame_ms"]["p95"], "pass": res["frame_ms"]["p95"] <= 25},
  "echo p50 <= 30 ms": {"value": res["echo_ms"]["p50"], "pass": res["echo_ms"]["p50"] <= 30},
  "switch p50 <= 50 ms": {"value": res["switch_single_view_ms"]["p50"], "pass": res["switch_single_view_ms"]["p50"] <= 50},
  "app RSS < 1 GB":   {"value": res["app_rss_mb"]["peak"], "pass": res["app_rss_mb"]["peak"] < 1024},
}
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "measurements.json")
doc = json.load(open(path))
doc[KEY] = res
json.dump(doc, open(path, "w"), indent=1)
print(json.dumps(res, indent=1))
for k, v in res["targets"].items(): print("PASS" if v["pass"] else "FAIL", k, "->", v["value"])
