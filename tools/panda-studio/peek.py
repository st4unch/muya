import concurrent.futures as cf, os, re, subprocess, sys
RIVE = os.path.expanduser("~/.rive/bin/rive")
jobs = []
for name in sys.argv[2:]:
    dur = int(re.search(r'<LinearAnimation[^>]*duration="(\d+)"', open(f"scene_{name}/scene.rml").read()).group(1))
    for k in range(6):
        f = 1 + int(dur * k / 6)
        jobs.append((name, k, f))
def run(j):
    name, k, f = j
    subprocess.run([RIVE, f"scene_{name}", f"--screenshot={sys.argv[1]}/{name}_{k}.png", f"--advance={f/60:.3f}s"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
with cf.ThreadPoolExecutor(6) as ex: list(ex.map(run, jobs))
for name in sys.argv[2:]:
    subprocess.run(["ffmpeg","-y","-loglevel","error","-i",f"{sys.argv[1]}/{name}_%d.png","-vf","scale=-1:210,tile=6x1","-frames:v","1",f"{sys.argv[1]}/row_{name}.png"])
