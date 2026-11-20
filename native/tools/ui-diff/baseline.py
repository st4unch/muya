#!/usr/bin/env python3
"""Native-vs-reference baseline: pairs the reference set (native/ui-reference/screens, 1120x732) with the native
screenshots in native/app/screenshots via map.json, runs ui_diff on every pair, writes
native/tools/ui-diff/baseline/{*.compare.png, ui-diff-report.json, BASELINE.md}.
  python3 native/tools/ui-diff/baseline.py [--native-dir DIR] [--size 1120x732] [--out DIR]
Add a row to map.json when a new native screenshot exists for a reference view."""
import argparse, json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ui_diff

ap = argparse.ArgumentParser()
ap.add_argument("--native-dir", default=os.path.join(HERE, "../../app/screenshots"))
ap.add_argument("--ref-dir", default=os.path.join(HERE, "../../ui-reference/screens"))
ap.add_argument("--size", default="1120x732")
ap.add_argument("--map", default=os.path.join(HERE, "map.json"))
ap.add_argument("--out", default=os.path.join(HERE, "baseline"))
a = ap.parse_args()
mp = json.load(open(a.map))
rows = []
for view, nat in mp.items():
    for theme in ("dark", "light"):
        r = os.path.join(a.ref_dir, f"{view}-{theme}-{a.size}.png")
        n = os.path.join(a.native_dir, nat.replace("{t}", theme))
        if not (os.path.exists(r) and os.path.exists(n)):
            continue
        sc, resized = ui_diff.compare(r, n, os.path.join(a.out, f"{view}-{theme}.compare.png"), f"{view}-{theme}")
        rows.append({"view": view, "theme": theme, "native": os.path.basename(n), "resized": resized, **sc})
os.makedirs(a.out, exist_ok=True)
json.dump(rows, open(os.path.join(a.out, "ui-diff-report.json"), "w"), indent=2)
with open(os.path.join(a.out, "BASELINE.md"), "w") as f:
    f.write("| view | theme | native shot | score | layout | detail | colour |\n|---|---|---|---|---|---|---|\n")
    for r in rows:
        f.write(f"| {r['view']} | {r['theme']} | {r['native']} | {r['score']} | {r['layout']} | {r['detail']} | {r['colour']} |\n")
    if rows:
        f.write(f"\nmean score {sum(r['score'] for r in rows)/len(rows):.1f} over {len(rows)} pairs\n")
print(open(os.path.join(a.out, "BASELINE.md")).read())
