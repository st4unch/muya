#!/usr/bin/env python3
"""ui-diff — prove the native app looks like today's Muya.

Single pair:
  ui_diff.py REF.png NATIVE.png [--out DIR] [--name NAME]
Batch (matching file names `<view>-<theme>-<WxH>.png` in two folders):
  ui_diff.py --ref-dir native/ui-reference/screens --native-dir <dir> [--out DIR]

For every pair it writes `<name>.compare.png` (reference | native | difference heat-map, with a
header) and prints/stores scores in `ui-diff-report.json`. Needs python3 + Pillow + numpy
(the only deps; no ImageMagick). Native shots are resized to the reference size when the pixel
sizes differ (Retina captures are 2x), so capture the native window at the same point size.

Scores (0-100, higher = more alike):
  layout  — SSIM of both images blurred + shrunk 8x: regions, panel sizes, fills. Ignores glyph noise.
  detail  — SSIM of the full-size grayscale (lightly blurred): text position, borders, icons.
  colour  — 100 - mean |RGB difference| at 1/8 scale (paint colours, theme).
  score   — 0.5*layout + 0.2*detail + 0.3*colour. A view is "same at a glance" when
            layout >= 90 and colour >= 95; "pixel-close" when score >= 90.
"""
import argparse, json, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont


def load(p):
    return Image.open(p).convert("RGB")


def box_mean(a, k):
    """Uniform k x k mean filter via an integral image ('valid' windows)."""
    c = np.cumsum(np.cumsum(a, 0), 1)
    c = np.pad(c, ((1, 0), (1, 0)))
    return (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)


def ssim(a, b, k=7):
    a = a.astype(np.float64); b = b.astype(np.float64)
    if min(a.shape) < k:
        k = max(1, min(a.shape))
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    ma, mb = box_mean(a, k), box_mean(b, k)
    saa = box_mean(a * a, k) - ma * ma
    sbb = box_mean(b * b, k) - mb * mb
    sab = box_mean(a * b, k) - ma * mb
    s = ((2 * ma * mb + c1) * (2 * sab + c2)) / ((ma * ma + mb * mb + c1) * (saa + sbb + c2))
    return float(np.clip(s.mean(), 0, 1))


def scores(ref, nat):
    gr, gn = np.asarray(ref.convert("L")), np.asarray(nat.convert("L"))
    detail = ssim(np.asarray(ref.convert("L").filter(ImageFilter.GaussianBlur(0.8))),
                  np.asarray(nat.convert("L").filter(ImageFilter.GaussianBlur(0.8))))
    w, h = max(8, ref.width // 8), max(8, ref.height // 8)
    sr = ref.filter(ImageFilter.GaussianBlur(3)).resize((w, h), Image.BILINEAR)
    sn = nat.filter(ImageFilter.GaussianBlur(3)).resize((w, h), Image.BILINEAR)
    layout = ssim(np.asarray(sr.convert("L")), np.asarray(sn.convert("L")), k=3)
    colour = 100 - float(np.abs(np.asarray(sr, dtype=np.float64) - np.asarray(sn, dtype=np.float64)).mean()) / 255 * 100
    total = 0.5 * layout * 100 + 0.2 * detail * 100 + 0.3 * colour
    return {"layout": round(layout * 100, 1), "detail": round(detail * 100, 1),
            "colour": round(colour, 1), "score": round(total, 1)}


def heat(ref, nat):
    d = np.abs(np.asarray(ref, dtype=np.int16) - np.asarray(nat, dtype=np.int16)).max(axis=2)
    d = np.clip(d * 3, 0, 255).astype(np.uint8)
    img = np.zeros((*d.shape, 3), np.uint8)
    img[..., 0] = d
    img[..., 1] = d // 3
    img[..., 2] = 255 - d
    return Image.fromarray(img)


def font(size):
    for f in ("/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/SFNS.ttf"):
        try:
            return ImageFont.truetype(f, size)
        except Exception:
            pass
    return ImageFont.load_default()


def compare(ref_path, nat_path, out_png, title, scale=0.5):
    ref, nat = load(ref_path), load(nat_path)
    resized = nat.size != ref.size
    if resized:
        nat = nat.resize(ref.size, Image.LANCZOS)
    sc = scores(ref, nat)
    panes = [("reference (today's Muya)", ref), ("native", nat), ("difference", heat(ref, nat))]
    tw, th = int(ref.width * scale), int(ref.height * scale)
    head = 44
    sheet = Image.new("RGB", (tw * 3 + 16, th + head), (24, 24, 24))
    dr = ImageDraw.Draw(sheet)
    dr.text((8, 6), f"{title}   score {sc['score']}  layout {sc['layout']}  detail {sc['detail']}  colour {sc['colour']}"
            + ("   [native resized]" if resized else ""), fill=(255, 255, 255), font=font(14))
    for i, (label, im) in enumerate(panes):
        x = 8 * i + tw * i
        dr.text((x + 4, 26), label, fill=(170, 200, 255), font=font(12))
        sheet.paste(im.resize((tw, th), Image.LANCZOS), (x, head))
    os.makedirs(os.path.dirname(out_png) or ".", exist_ok=True)
    sheet.save(out_png)
    return sc, resized


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ref", nargs="?")
    ap.add_argument("native", nargs="?")
    ap.add_argument("--ref-dir")
    ap.add_argument("--native-dir")
    ap.add_argument("--out", default="ui-diff-out")
    ap.add_argument("--name")
    ap.add_argument("--min-score", type=float, default=0, help="exit 1 if any pair scores below this")
    a = ap.parse_args()

    pairs = []
    if a.ref and a.native:
        pairs.append((a.name or os.path.splitext(os.path.basename(a.ref))[0], a.ref, a.native))
    elif a.ref_dir and a.native_dir:
        for f in sorted(os.listdir(a.ref_dir)):
            if f.endswith(".png") and os.path.exists(os.path.join(a.native_dir, f)):
                pairs.append((f[:-4], os.path.join(a.ref_dir, f), os.path.join(a.native_dir, f)))
        if not pairs:
            sys.exit("no matching file names between the two folders")
    else:
        ap.error("give REF NATIVE or --ref-dir + --native-dir")

    report, worst = [], 100.0
    for name, r, n in pairs:
        sc, resized = compare(r, n, os.path.join(a.out, name + ".compare.png"), name)
        report.append({"name": name, "ref": r, "native": n, "resized": resized, **sc})
        worst = min(worst, sc["score"])
        print(f"{sc['score']:6.1f}  layout {sc['layout']:5.1f}  detail {sc['detail']:5.1f}  colour {sc['colour']:5.1f}  {name}")
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "ui-diff-report.json"), "w") as fh:
        json.dump(report, fh, indent=2)
    if worst < a.min_score:
        sys.exit(1)


if __name__ == "__main__":
    main()
