#!/usr/bin/env python3
"""Contact sheet of reference screenshots for quick review.
  contact.py OUT.png IMG1 IMG2 ... [--cols 2] [--width 720]
"""
import sys, os
from PIL import Image, ImageDraw, ImageFont

args = [a for a in sys.argv[1:]]
cols, width = 2, 720
for flag in ("--cols", "--width"):
    if flag in args:
        i = args.index(flag)
        v = int(args[i + 1])
        del args[i:i + 2]
        cols, width = (v, width) if flag == "--cols" else (cols, v)
out, imgs = args[0], args[1:]
tiles = []
for p in imgs:
    im = Image.open(p).convert("RGB")
    h = int(im.height * width / im.width)
    tiles.append((os.path.basename(p), im.resize((width, h), Image.LANCZOS)))
rows = [tiles[i:i + cols] for i in range(0, len(tiles), cols)]
rh = [max(t[1].height for t in r) + 20 for r in rows]
sheet = Image.new("RGB", (cols * (width + 6), sum(rh)), (40, 40, 40))
d = ImageDraw.Draw(sheet)
y = 0
for r, h in zip(rows, rh):
    for c, (name, im) in enumerate(r):
        d.text((c * (width + 6) + 4, y + 3), name, fill=(255, 255, 160))
        sheet.paste(im, (c * (width + 6), y + 18))
    y += h
sheet.save(out)
