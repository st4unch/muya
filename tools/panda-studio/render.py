"""Render a scene project to an mp4: python3 render.py scene_wave [loops]
Frames come from `rive --screenshot --advance` (every 2nd frame at 60 fps -> 30 fps video),
rendered 6 at a time. Output: videos/<name>.mp4 (white background, panda scene only)."""
import concurrent.futures as cf, os, re, subprocess, sys

RIVE = os.path.expanduser("~/.rive/bin/rive")
proj = sys.argv[1].rstrip("/")
loops = int(sys.argv[2]) if len(sys.argv) > 2 else 2
name = proj.replace("scene_", "")
dur = int(re.search(r'<LinearAnimation[^>]*duration="(\d+)"', open(f"{proj}/scene.rml").read()).group(1))
fdir = f"frames/{name}"
os.makedirs(fdir, exist_ok=True)
for f in os.listdir(fdir):
    os.remove(os.path.join(fdir, f))

def shot(i):
    f = 1 + 2 * i
    subprocess.run([RIVE, proj, f"--screenshot={fdir}/f_{i:04d}.png", f"--advance={f / 60:.4f}s"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

n = dur // 2
with cf.ThreadPoolExecutor(6) as ex:
    list(ex.map(shot, range(n)))
os.makedirs("videos", exist_ok=True)
out = f"videos/{name}.mp4"
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-stream_loop", str(loops - 1), "-framerate", "30", "-i", f"{fdir}/f_%04d.png",
                "-vf", "scale=-2:720,pad=ceil(iw/2)*2:720:0:0:white", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", out], check=True)
print(out, n, "frames")
