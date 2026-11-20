#!/usr/bin/env python3
"""CPU / memory / GPU of the native app and its daemons, idle and under a 50 MB stream.

Uses the dev stack from run-dev.sh (must be running with the app). CPU is the delta of process
CPU time over the window (ps), memory is phys_footprint (`footprint`), GPU is the system-wide
"Device Utilization %" from ioreg (no sudo; powermetrics needs root, so per-process GPU time is
not available - the renderer's own per-frame GPU time comes from Metal completion handlers).
"""
import json, os, re, socket, subprocess, sys, tempfile, time

state = dict(l.strip().split("=", 1) for l in open(os.path.join(os.environ.get("TMPDIR", "/tmp"), "muya-native-dev.state")) if "=" in l)
state = {k: v.strip("'\"").replace("\\", "") for k, v in state.items()}
DEV = state["DEV"]
PIDS = {"app": int(state["APP_PID"]), "muyad": int(state["MUYAD_PID"]), "ptyd": int(state["PTYD_PID"])}

def dbg(cmd, timeout=10):
    s = socket.socket(socket.AF_UNIX); s.settimeout(timeout); s.connect(DEV + "/app-debug.sock")
    s.sendall((cmd + "\n").encode()); out = b""
    while not out.endswith(b"\n"): out += s.recv(65536)
    s.close(); return out.decode().rstrip("\n")

def cpu_seconds(pid):
    t = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    m = re.match(r"(?:(\d+):)?(\d+):(\d+\.\d+)", t)
    h, mi, s = (int(m.group(1) or 0), int(m.group(2)), float(m.group(3)))
    return h * 3600 + mi * 60 + s

def footprint_mb(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s*([\d.]+)\s*(KB|MB|GB)", out)
    if not m: return float("nan")
    return float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)]

def rss_mb(pid):
    return int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or 0) / 1024

def gpu_util():
    out = subprocess.run(["ioreg", "-r", "-d", "1", "-w0", "-c", "IOAccelerator"], capture_output=True, text=True).stdout
    m = re.search(r'"Device Utilization %"=(\d+)', out)
    return int(m.group(1)) if m else None

def window(seconds, poll=None):
    c0 = {k: cpu_seconds(p) for k, p in PIDS.items()}; t0 = time.time(); gpu = []; fp = {k: [] for k in PIDS}
    while time.time() - t0 < seconds:
        time.sleep(1)
        gpu.append(gpu_util())
        for k, p in PIDS.items(): fp[k].append(footprint_mb(p))
        if poll and poll(): break
    el = time.time() - t0
    return {"seconds": round(el, 1),
            "cpu_pct": {k: round((cpu_seconds(p) - c0[k]) / el * 100, 1) for k, p in PIDS.items()},
            "footprint_mb_peak": {k: round(max(v), 1) for k, v in fp.items()},
            "gpu_util_pct_system": {"samples": [g for g in gpu if g is not None][:30]}}

out = {"sessions": len(dbg("sessions").splitlines()), "grid": json.loads(dbg("metrics"))["grid"]}
dbg("select 1")
dbg("appearance dark")
time.sleep(2)
dbg("metrics-reset")
out["idle"] = window(20)
out["idle"]["renderer"] = json.loads(dbg("metrics"))
out["rss_mb_idle"] = {k: round(rss_mb(p), 1) for k, p in PIDS.items()}

# Stream 50 MB through the visible session.
dbg("metrics-reset")
b0 = json.loads(dbg("metrics"))["bytes_in_selected"]
last = {"n": b0, "t": time.time()}
t_start = time.time()
dbg('type "yes | head -c 50000000; echo STREAM-DONE\\n"')
def done():
    m = json.loads(dbg("metrics"))
    if m["bytes_in_selected"] != last["n"]: last["n"], last["t"] = m["bytes_in_selected"], time.time()
    return "STREAM-DONE" in dbg("text") and time.time() - last["t"] > 1
stream = window(120, poll=done)
m = json.loads(dbg("metrics"))
elapsed = last["t"] - t_start
stream["renderer"] = m
stream["bytes_through_app"] = m["bytes_in_selected"] - b0
stream["seconds_to_last_byte"] = round(elapsed, 1)
stream["throughput_mb_s"] = round((m["bytes_in_selected"] - b0) / 1e6 / max(elapsed, 0.01), 1)
out["stream_50mb"] = stream
time.sleep(3)
dbg("metrics-reset")
out["after_stream_idle"] = window(10)
out["rss_mb_after"] = {k: round(rss_mb(p), 1) for k, p in PIDS.items()}
print(json.dumps(out, indent=1))
