"""Check that every reaction stays inside the shared rail crop (reactions.FRAME), so clicking the
panda never resizes it. Run render.py on each reaction first (white background, frames/<name>/).
python3 check_frame.py   -> one line per reaction, exit 1 if anything is drawn outside"""
import os, sys
import numpy as np
from PIL import Image
from reactions import FRAME, REACTIONS

bad = 0
for name in REACTIONS:
    files = sorted(os.listdir(f"frames/{name}"))
    lo, hi = np.array([10**6, 10**6]), np.array([0, 0])
    for f in files:
        a = np.asarray(Image.open(f"frames/{name}/{f}").convert("RGB"))
        ys, xs = np.nonzero((a < 245).any(axis=2))
        if len(xs):
            lo = np.minimum(lo, [xs.min(), ys.min()]); hi = np.maximum(hi, [xs.max(), ys.max()])
    x0, y0, x1, y1 = FRAME
    over = max(x0 - lo[0], y0 - lo[1], hi[0] - x1, hi[1] - y1, 0)
    bad += over > 0
    print(f"{name:9} drawn {lo[0]:4} {lo[1]:4} {hi[0]:4} {hi[1]:4}  {'OUTSIDE by %d px' % over if over else 'ok'}")
sys.exit(1 if bad else 0)
