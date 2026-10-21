"""Measure how far below the body pivot the tucked ball reaches, per rotation (render + scan)."""
import json, math, os, subprocess, sys
import numpy as np
from PIL import Image
import scenes2 as S
from gen_panda import P
BALL = dict(legL1=70, legR1=-70, legL2=-120, legR2=120, armL1=60, armR1=-60, armL2=-110, armR2=110, eyes="shut", sx=86, sy=86)
angles = list(range(0, 360, 24))
keys = []
for i, a in enumerate(angles):
    keys.append((i * 10, P(rot=a, **BALL), "hold"))
keys.append((len(angles) * 10, P(rot=0, **BALL), "hold"))
S.build("measure", keys, size=(1600, 1800), origin=(634, 700), background="FFFFFFFF")
out = {}
pivot_y = 700 + S.PIV[1]
for i, a in enumerate(angles):
    f = i * 10 + 5
    subprocess.run([os.path.expanduser("~/.rive/bin/rive"), "scene_measure", f"--screenshot=sc/m_{a}.png", f"--advance={f/60:.3f}s"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    im = np.asarray(Image.open(f"sc/m_{a}.png").convert("RGB"))
    mask = (im < 170).any(axis=2)
    pass
    ys = np.nonzero(mask.any(axis=1))[0]
    out[a] = int(ys.max() - pivot_y)
print(json.dumps(out))
