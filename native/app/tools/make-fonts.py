#!/usr/bin/env python3
"""Rebuild native/app/Resources/Fonts/*.ttf from the repo's own @fontsource copies (node_modules).
CoreText cannot load WOFF, so the WOFF files (zlib-compressed sfnt, lossless) are unpacked with fontTools and the
latin + latin-ext subsets merged into one font per weight. No download; fonts are IBM Plex Sans and JetBrains Mono
(SIL OFL 1.1). Run from the repo root:  python3 native/app/tools/make-fonts.py
"""
import os, sys
from fontTools.ttLib import TTFont
from fontTools.merge import Merger

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OUT = os.path.join(ROOT, "native/app/Resources/Fonts")
JOBS = [
    ("ibm-plex-sans", "ibm-plex-sans", [400, 500, 600, 700]),
    ("jetbrains-mono", "jetbrains-mono", [400, 700]),
]
os.makedirs(OUT, exist_ok=True)
for pkg, stem, weights in JOBS:
    d = os.path.join(ROOT, "node_modules/@fontsource", pkg, "files")
    for w in weights:
        parts = []
        for sub in ("latin", "latin-ext"):
            p = os.path.join(d, f"{stem}-{sub}-{w}-normal.woff")
            if not os.path.exists(p):
                sys.exit(f"missing {p} — run npm install")
            f = TTFont(p); f.flavor = None
            tmp = os.path.join(OUT, f".tmp-{sub}.ttf"); f.save(tmp); parts.append(tmp)
        merged = Merger().merge(parts)
        ps = merged["name"].getDebugName(6)
        dst = os.path.join(OUT, f"{ps}.ttf")
        merged.save(dst)
        print("wrote", os.path.relpath(dst, ROOT), os.path.getsize(dst) // 1024, "KB", ps, merged["name"].getDebugName(1), "/", merged["name"].getDebugName(2))
        for t in parts: os.remove(t)
