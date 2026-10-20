"""Crop box per scene for the 62 px rail: the union of what is drawn over all frames,
squared up and bottom-aligned. Scenes with scrolling scenery or a run-off gag use the panda's
own box instead (the scenery may leave the frame). Prints JSON {scene: [x0, y0, x1, y1]}."""
import json, os, re, sys
import numpy as np
from PIL import Image

PANDA_ONLY = {"traveller", "business", "fart", "roll"}
out = {}
for name in sorted(os.listdir("frames")):
    rml = open(f"scene_{name}/scene.rml").read()
    W = int(re.search(r'<Artboard[^>]*width="(\d+)"', rml).group(1))
    H = int(re.search(r'<Artboard[^>]*height="(\d+)"', rml).group(1))
    ox, oy = (float(v) for v in re.search(r'<Node x="([-\d.]+)" y="([-\d.]+)" name="world"', rml).groups()) if re.search(r'<Node x="([-\d.]+)" y="([-\d.]+)" name="world"', rml) else (W / 2, H / 2)
    if name in PANDA_ONLY:
        # the panda at rest: head top to feet, ears to ears (root space -> artboard)
        cx = ox + 166
        x0, x1, y0, y1 = cx - 300, cx + 300, oy - 380, oy + 480
        if name == "roll":
            x0, x1 = 0, W
    else:
        lo = np.array([W, H]); hi = np.array([0, 0])
        files = sorted(os.listdir(f"frames/{name}"))
        for f in files[:: max(1, len(files) // 40)]:
            a = np.asarray(Image.open(f"frames/{name}/{f}").convert("RGB"))
            mask = (a < 245).any(axis=2)
            ys, xs = np.nonzero(mask)
            if len(xs):
                lo = np.minimum(lo, [xs.min(), ys.min()]); hi = np.maximum(hi, [xs.max(), ys.max()])
        x0, y0 = lo; x1, y1 = hi
    # square, bottom-aligned, a little margin
    side = max(x1 - x0, y1 - y0) * 1.04
    cx = (x0 + x1) / 2
    box = [cx - side / 2, y1 + side * 0.02 - side, cx + side / 2, y1 + side * 0.02]
    out[name] = [round(v) for v in box]
print(json.dumps(out, indent=1))
