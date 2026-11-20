#!/usr/bin/env python3
"""AC14 (PRD §10): an external touch / delete / rename shows up in the file tree within 1 s. Runs against the
dev stack from run-dev.sh: opens a throwaway folder as a session's cwd, expands a subfolder, does N rounds of
each operation from outside the app and polls the tree (`files` on the debug socket) every 5 ms until the
row list shows the change. Records the latencies in measurements.json under "ac14"."""
import json, os, shutil, socket, time

TMP = os.environ.get("TMPDIR", "/tmp")
state = dict(l.strip().split("=", 1) for l in open(os.path.join(TMP, "muya-native-dev.state")) if "=" in l)
state = {k: v.strip("'\"").replace("\\", "") for k, v in state.items()}
DEV = state["DEV"]
ROUNDS = int(os.environ.get("AC14_ROUNDS", "10"))


def dbg(cmd, timeout=10):
    # One connection per command: replies can span several lines (`files`), the server ends them with a blank "\n".
    s = socket.socket(socket.AF_UNIX); s.settimeout(timeout); s.connect(DEV + "/app-debug.sock")
    s.sendall((cmd + "\n").encode()); out = b""
    while not out.endswith(b"\n"): out += s.recv(65536)
    s.close(); return out.decode().rstrip("\n")


def names():
    r = dbg("files")
    return [x.split("\t")[1] for x in r.split("\n") if "\t" in x]


root = os.path.join(DEV, "home", "ac14")
shutil.rmtree(root, ignore_errors=True)
os.makedirs(os.path.join(root, "sub"))
for n in ("seed1.txt", "seed2.txt"):
    open(os.path.join(root, n), "w").close()
open(os.path.join(root, "sub", "inner.txt"), "w").close()
r = dbg("new " + root)
assert r.startswith("ok"), r
time.sleep(1.2)
assert dbg("files-root") == root, dbg("files-root")
assert dbg("files-expand " + os.path.join(root, "sub")) == "ok"
time.sleep(0.5)


def wait_for(pred, timeout=3.0):
    t0 = time.monotonic()
    while True:
        if pred(names()):
            return (time.monotonic() - t0) * 1000
        if time.monotonic() - t0 > timeout:
            return None
        time.sleep(0.005)


res = {}


def run(label, act, pred, undo=None):
    ms = []
    for i in range(ROUNDS):
        act(i)  # the clock starts right after the syscall returns
        ms.append(wait_for(lambda n, i=i: pred(n, i)))
        if undo:
            undo(i)
        time.sleep(0.4)
    ok = [m for m in ms if m is not None]
    res[label] = {"n": ROUNDS, "missed": ROUNDS - len(ok), "ms_min": round(min(ok), 1) if ok else None,
                  "ms_p50": round(sorted(ok)[len(ok) // 2], 1) if ok else None, "ms_max": round(max(ok), 1) if ok else None}
    print(label, res[label])


def P(*a):
    return os.path.join(root, *a)


run("create file", lambda i: open(P(f"new{i}.txt"), "w").close(), lambda n, i: f"new{i}.txt" in n)
run("rename", lambda i: os.rename(P(f"new{i}.txt"), P(f"moved{i}.txt")), lambda n, i: f"moved{i}.txt" in n and f"new{i}.txt" not in n)
run("delete file", lambda i: os.remove(P(f"moved{i}.txt")), lambda n, i: f"moved{i}.txt" not in n)
run("mkdir", lambda i: os.mkdir(P(f"d{i}")), lambda n, i: f"d{i}/" in n, undo=lambda i: os.rmdir(P(f"d{i}")))
run("create file in expanded subfolder", lambda i: open(P("sub", f"x{i}.txt"), "w").close(), lambda n, i: f"x{i}.txt" in n)

for k in range(200):
    open(P(f"burst{k}.txt"), "w").close()
ms = wait_for(lambda n: sum(1 for x in n if x.startswith("burst")) == 200)
res["burst of 200 files"] = {"ms": round(ms, 1) if ms else None}
print("burst", res["burst of 200 files"])
res["tree_stats"] = dbg("files-stats")
print(res["tree_stats"])

worst = max([v["ms_max"] or 1e9 for v in res.values() if isinstance(v, dict) and "ms_max" in v] + [res["burst of 200 files"]["ms"] or 1e9])
missed = sum(v["missed"] for v in res.values() if isinstance(v, dict) and "missed" in v)
passed = worst <= 1000 and missed == 0
res["target"] = {"every change visible within 1000 ms, none missed": {"worst_ms": round(worst, 1), "missed": missed, "pass": passed}}
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "measurements.json")
doc = json.load(open(path)); doc["ac14"] = res
json.dump(doc, open(path, "w"), indent=1)
for s in dbg("sessions").splitlines():
    if root in s or "ac14" in s:
        dbg("close " + s.split("\t")[0])
shutil.rmtree(root, ignore_errors=True)
print("PASS" if passed else "FAIL", "AC14 worst", round(worst, 1), "ms, missed", missed)
