"""Mouse reactions for the 4.1.12 jointed panda: angry (click) and hello (hover)."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rig
from rig import *
from scenes2 import STAND, pose, write as _write

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out3")
os.makedirs(OUT, exist_ok=True)

def write(name, svg):
    open(os.path.join(OUT, name + ".svg"), "w").write(svg)
    print(name, len(svg))

# ---- angry face parts ------------------------------------------------------------
RED = "#ff4d4d"
def _eyes_angry():
    eyes = "".join(path(i) for i in G["eyes"])
    squint = f'<g transform="translate(375 304) scale(1 .62) translate(-375 -296)">{eyes}</g>'
    brows = (f'<path d="M236 248 L314 282" fill="none" stroke="{NAVY}" stroke-width="17" stroke-linecap="round"/>'
             f'<path d="M514 248 L436 282" fill="none" stroke="{NAVY}" stroke-width="17" stroke-linecap="round"/>')
    return squint + brows
FACE["eyes_angry"] = _eyes_angry
FACE["mouth_angry"] = lambda: (f'<path d="M340 380 Q373 346 406 380" fill="none" stroke="{NAVY}" stroke-width="12" stroke-linecap="round"/>')
FACE["mouth_shout"] = lambda: (f'<path d="M338 384 Q373 336 408 384 Z" fill="{NAVY}" stroke="{NAVY}" stroke-width="8" stroke-linejoin="round"/>'
                               f'<path d="M354 380 Q373 366 392 380 Z" fill="#ef4141"/>')
rig.EYES.append("eyes_angry")
rig.MOUTHS += ["mouth_angry", "mouth_shout"]

def anger_mark(cx, cy, s):
    """the manga 'popping vein' mark: four red curved brackets"""
    arcs = ""
    for rot in (0, 90, 180, 270):
        arcs += (f'<path transform="rotate({rot})" d="M10 -34 Q10 -10 34 -10" fill="none" stroke="{RED}" stroke-width="13" stroke-linecap="round"/>')
    return f'<g transform="translate({cx} {cy}) scale({s})">{arcs}</g>'

def puff(cx, cy, s):
    blobs = [(-14, 4, 15), (0, -6, 18), (14, 4, 15)]
    out = "".join(f'<circle cx="{cx + dx*s:.1f}" cy="{cy + dy*s:.1f}" r="{r*s:.1f}" fill="{NAVY}"/>' for dx, dy, r in blobs)
    out += "".join(f'<circle cx="{cx + dx*s:.1f}" cy="{cy + dy*s:.1f}" r="{r*s - 5:.1f}" fill="#f4f2ff"/>' for dx, dy, r in blobs)
    return out

# ---- angry: poked, flares up, shakes its fists and stomps, then turns away "hmph" ----
def scene_angry():
    dur = 3.2
    FISTS = dict(armL=(214, 430), armR=(536, 430))
    keys = [
        (0, pose(STAND, foot="front", eyes="eyes_open", mouth="mouth_open", blush="0")),
        (4, pose(STAND, root=(0, -60, 0, 1.05, .95), eyes="eyes_wide", mouth="mouth_o", head=-5, armL=(262, 560), armR=(488, 560))),
        (10, pose(STAND, root=(0, -76, 0, .98, 1.03), head=0)),
        (12, {"eyes": "eyes_angry", "mouth": "mouth_shout"}),
        (16, pose(STAND, **FISTS, root=(0, -69, 0, 1, 1), head=4)),
    ]
    # fists shaking + stomping, alternating sides
    t = 16
    for i in range(10):
        t += 5
        up = i % 2 == 0
        keys.append((t, pose(STAND,
                             armL=(206, 396) if up else (222, 446), armR=(528, 446) if up else (544, 396),
                             legL=(312, 650) if up else (312, 684), legR=(438, 684) if up else (438, 650),
                             root=(0, -69 - (6 if up else 0), 3 if up else -3, 1, 1), head=-5 if up else 5)))
        if i == 4:
            keys.append((t + .5, {"mouth": "mouth_angry"}))
        if i == 6:
            keys.append((t + .5, {"mouth": "mouth_shout"}))
    keys += [
        (70, pose(STAND, **FISTS)),
        (71, {"mouth": "mouth_angry"}),
        # hmph: arms down and back, chin up, turned away
        (80, pose(STAND, armL=(236, 600), armR=(514, 600), root=(0, -69, -4, 1, 1), head=-12)),
        (81, {"eyes": "eyes_shut"}),
        (94, pose(STAND, armL=(236, 600), armR=(514, 600), root=(0, -69, -4, 1, 1), head=-14)),
        (100, pose(STAND, root=(0, -69, -4, 1, 1), head=-12)),
    ]
    tl = Timeline(keys)
    d = f"{dur}s"
    css = (
        # red rising up the face while angry
        f".rage{{animation:rage {d} infinite;opacity:0}}@keyframes rage{{0%,11%{{opacity:0}}16%,70%{{opacity:.75}}80%{{opacity:.5}}100%{{opacity:.45}}}}"
        # the normal brows hide while the angry ones show
        f".brows{{animation:brows {d} infinite steps(1,end)}}@keyframes brows{{0%{{opacity:1}}12%{{opacity:0}}81%{{opacity:1}}100%{{opacity:1}}}}"
        # the vein mark pops and throbs
        f".vein{{animation:vein {d} infinite;transform-box:fill-box;transform-origin:center;opacity:0}}"
        "@keyframes vein{0%,12%{opacity:0;transform:scale(.2)}16%{opacity:1;transform:scale(1.25)}20%{transform:scale(.9)}"
        "26%{transform:scale(1.15)}32%{transform:scale(.92)}38%{transform:scale(1.15)}44%{transform:scale(.92)}50%{transform:scale(1.15)}"
        "56%{transform:scale(.92)}62%{transform:scale(1.15)}70%{opacity:1;transform:scale(1)}96%{opacity:1;transform:scale(1)}100%{opacity:0;transform:scale(.6)}}"
        # steam from both ears, in bursts
        ".steam g{opacity:0;animation:stm 0.8s infinite ease-out}.steam .s2{animation-delay:.27s}.steam .s3{animation-delay:.53s}"
        "@keyframes stm{0%{opacity:0;transform:translateY(0) scale(.5)}25%{opacity:1}100%{opacity:0;transform:translateY(-55px) scale(1.35)}}"
        f".steam{{animation:stmw {d} infinite steps(1,end)}}@keyframes stmw{{0%{{opacity:0}}14%{{opacity:1}}72%{{opacity:0}}100%{{opacity:0}}}}\n"
    )
    rage = ('<g class="rage">'
            f'<ellipse cx="226" cy="356" rx="46" ry="26" fill="{RED}"/><ellipse cx="524" cy="356" rx="46" ry="26" fill="{RED}"/>'
            + "".join(f'<path d="M{x} 206 l0 26" stroke="{RED}" stroke-width="9" stroke-linecap="round"/>' for x in (348, 372, 396))
            + '</g>')
    vein = f'<g class="vein">{anger_mark(540, 150, 1.25)}</g>'
    steam = '<g class="steam">' + "".join(
        f'<g class="s{k}" style="transform-box:fill-box;transform-origin:center">{puff(x + dx, 60, 1.5)}</g>'
        for x in (130, 620) for k, dx in ((1, 0), (2, -10 if x < 375 else 10), (3, 0))) + "</g>"
    svg, _, _ = build(tl, dur, extra_css=css, head_extra=rage + steam + vein)
    write("angry", svg)

# ---- hello: the pointer arrives, the panda looks up and waves --------------------
def scene_hello():
    dur = 2.0
    keys = [
        (0, pose(STAND, foot="front", eyes="eyes_open", mouth="mouth_open", blush="0")),
        (8, pose(STAND, head=-6, root=(0, -74, 0, 1, 1))),
        (10, {"eyes": "eyes_wide"}),
        (18, pose(STAND, head=-8, armR=(548, 352))),
        (20, {"eyes": "eyes_happy", "mouth": "mouth_grin", "blush": "1"}),
    ]
    t = 18
    for i in range(6):
        t += 8
        keys.append((t, pose(STAND, head=-8 + (3 if i % 2 else 0), armR=(590, 380) if i % 2 == 0 else (540, 344))))
    keys += [(86, pose(STAND, head=-3)), (88, {"eyes": "eyes_open", "mouth": "mouth_open", "blush": "0"}), (100, pose(STAND))]
    tl = Timeline(keys)
    svg, _, _ = build(tl, dur)
    write("hello", svg)

if __name__ == "__main__":
    scene_angry(); scene_hello()
