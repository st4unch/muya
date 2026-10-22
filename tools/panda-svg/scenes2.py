"""Jointed panda scenes: bamboo snap, tofu, manti, fart + run, roll."""
import math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rig import *
from gen import bamboo_piece, leaf, star, tofu, manti, cloud

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out2")
os.makedirs(OUT, exist_ok=True)

SIT = dict(root=(0, 0, 0, 1, 1), head=0, armL=(336, 600), armR=(414, 600), legL=(232, 624), legR=(518, 624))
STAND = dict(root=(0, -69, 0, 1, 1), head=0, armL=(252, 586), armR=(498, 586), legL=(312, 684), legR=(438, 684))

def pose(base, **kw):
    d = dict(base); d.update(kw); return d

def vis_css(cls, ranges, dur):
    seq = [(0.0, 0)]
    for a, b in ranges:
        seq += [(a, 1), (b, 0)]
    body = "".join(f"{t:.2f}%{{opacity:{o}}}" for t, o in seq) + f"100%{{opacity:{seq[-1][1]}}}"
    return f".{cls}{{animation:v_{cls} {dur}s infinite steps(1,end)}}@keyframes v_{cls}{{{body}}}\n"

def follow(cls, frames, dur):
    """frames: [(pct,(x,y,deg))] -> moving group class."""
    body = "".join(f"{p:.1f}%{{transform:translate({x:.1f}px,{y:.1f}px) rotate({a:.1f}deg)}}" for p, (x, y, a) in frames)
    return f".{cls}{{animation:f_{cls} {dur}s infinite linear;transform-box:view-box;transform-origin:0 0}}@keyframes f_{cls}{{{body}}}\n"

def centered(svg, cx, cy):
    return f'<g transform="translate({-cx} {-cy})">{svg}</g>'

def write(name, svg):
    open(os.path.join(OUT, name + ".svg"), "w").write(svg)
    print(name, len(svg))

# ------------------------------------------------------------------ bamboo snap
def scene_bamboo():
    dur = 4.6
    HOLD = dict(armL=(322, 556), armR=(428, 556))
    keys = [
        (0, pose(STAND, **HOLD, foot="front", eyes="eyes_open", mouth="mouth_open")),
        (10, pose(STAND, **HOLD)),
        (26, pose(STAND, root=(-6, -69, -4, 1, 1), armL=(206, 440), armR=(520, 418), legR=(452, 618), head=-4, eyes="eyes_shut", mouth="mouth_grin")),
        (31, pose(STAND, root=(-6, -69, -2, 1, 1), armL=(388, 590), armR=(496, 590), legR=(452, 618), head=4)),
        (33, pose(STAND, root=(-6, -64, -2, 1.02, .98), armL=(392, 596), armR=(500, 596), legR=(452, 620), head=6)),
        (35, {"eyes": "eyes_happy", "mouth": "mouth_open"}),
        (44, pose(STAND, root=(0, -130, 0, 1, 1), armL=(214, 430), armR=(536, 430), legL=(300, 660), legR=(450, 660), head=0)),
        (52, pose(STAND, root=(0, -69, 0, 1.03, .97), armL=(222, 440), armR=(528, 440))),
        (58, pose(STAND, armL=(196, 470), armR=(554, 470))),
        (64, pose(STAND, armL=(238, 560), armR=(512, 560))),
        (76, pose(STAND, eyes="eyes_open")),
        (90, pose(STAND, **HOLD)),
        (100, pose(STAND, **HOLD)),
    ]
    tl = Timeline(keys)

    def props(paws, pcts, frames):
        css, back, front = "", "", ""
        whole = (bamboo_piece(225, 525) + leaf(227, 512, 200, .9) + leaf(523, 512, -20, .9))
        fr = []
        for (p, (lx, ly)), (_, (rx, ry)) in zip(paws["L"], paws["R"]):
            fr.append((p, ((lx + rx) / 2, (ly + ry) / 2 - 2, math.degrees(math.atan2(ry - ly, rx - lx)))))
        back += f'<g class="bw"><g class="bwv">{centered(whole, 375, 525)}</g></g>'
        css += follow("bw", fr, dur) + vis_css("bwv", [(0, 33.5), (88, 100.01)], dur)
        # halves: in the paws 33.5 -> 60, then thrown
        for side, sign, piece in (("L", -1, bamboo_piece(225, 375, jag_right=True) + leaf(227, 512, 200, .9)),
                                  ("R", 1, bamboo_piece(375, 525, jag_left=True) + leaf(523, 512, -20, .9))):
            cx = 300 if side == "L" else 450
            hf = []
            last = None
            for (p, (x, y)) in paws[side]:
                if p < 60:
                    spin = 0 if p < 33.5 else min(1, (p - 33.5) / 8) * 35
                    last = (x, y, sign * spin)
                    hf.append((p, (x, y, sign * spin)))
                else:
                    u = (p - 60) / 20
                    x0, y0, a0 = last
                    hf.append((p, (x0 + sign * 380 * u, y0 - 260 * u + 520 * u * u, a0 + sign * 400 * u)))
            back += f'<g class="h{side}"><g class="h{side}v">{centered(piece, cx, 525)}</g></g>'
            css += follow("h" + side, hf, dur) + vis_css(f"h{side}v", [(33.5, 80)], dur)
        # impact star at the knee
        front += (f'<g transform="translate(446 590)"><g class="pow">{star(0, 0, 78)}{star(0, 0, 36, "#fff3a8")}</g></g>')
        css += (".pow{animation:pow " + f"{dur}s" + " infinite;transform-box:view-box;transform-origin:0 0}"
                "@keyframes pow{0%,33%{opacity:0;transform:scale(.2)}35%{opacity:1;transform:scale(1.2) rotate(12deg)}"
                "42%{opacity:1;transform:scale(1) rotate(22deg)}47%,100%{opacity:0;transform:scale(.6)}}\n")
        return back, front, css
    svg, _, _ = build(tl, dur, make_props=props)
    write("bamboo", svg)

# ------------------------------------------------------------------ eating
def eating(name, dur, pieces, dish_svg, piece_svg, rest_R, mouth_pt, grab_off, spoon=None):
    REST = pose(SIT, armL=(300, 598), armR=rest_R)
    keys = [(0, pose(REST, foot="sole", eyes="eyes_open", mouth="mouth_open", blush="0"))]
    bites = []
    for k, (px, py) in enumerate(pieces):
        s = 3 + 31 * k
        bites.append(s)
        keys += [
            (s, pose(REST)),
            (s + 6, pose(REST, armR=(px + grab_off[0], py + grab_off[1]), head=3)),
            (s + 8, pose(REST, armR=(px + grab_off[0], py + grab_off[1] + 4), head=3)),
            (s + 15, pose(REST, armR=mouth_pt, head=-7, eyes="eyes_happy")),
            (s + 16.5, {"mouth": "mouth_chew", "blush": "1"}),
            (s + 18, pose(REST, armR=mouth_pt, head=-5, legL=(232, 612), legR=(518, 636))),
            (s + 21, pose(REST, legL=(232, 636), legR=(518, 612), head=4)),
            (s + 24, pose(REST, legL=(232, 612), legR=(518, 636), head=-3)),
            (s + 27, pose(REST, legL=(232, 624), legR=(518, 624), head=0, eyes="eyes_open")),
            (s + 28.5, {"mouth": "mouth_open", "blush": "0"}),
        ]
    keys.append((100, pose(REST)))
    tl = Timeline(keys)

    def props(paws, pcts, frames):
        css, back, front = dish_svg[1], dish_svg[0], ""
        rpaw = dict(paws["R"])
        for k, (px, py) in enumerate(pieces):
            s = bites[k]
            fr = []
            for p in pcts:
                if s + 8 <= p <= s + 16.5:
                    x, y = rpaw[p]
                    fr.append((p, (x - grab_off[0], y - grab_off[1], 0)))
                else:
                    fr.append((p, (px, py, 0)))
            front += f'<g class="pc{k}"><g class="pc{k}v">{piece_svg}</g></g>'
            css += follow(f"pc{k}", fr, dur) + vis_css(f"pc{k}v", [(0, s + 16.5), (97, 100.01)], dur)
        if spoon:
            fr = [(p, (x, y, 0)) for p, (x, y) in paws["R"]]
            front = f'<g class="spn">{spoon}</g>' + front
            css += follow("spn", fr, dur)
        return back, front, css
    svg, _, _ = build(tl, dur, make_props=props)
    write(name, svg)

def scene_tofu():
    plate = (f'<ellipse cx="375" cy="606" rx="150" ry="30" fill="#ffffff" stroke="{NAVY}" stroke-width="{LW}"/>'
             f'<ellipse cx="375" cy="602" rx="112" ry="17" fill="#e6e6f7"/>')
    cube = centered(tofu(0, 0, 50), 34, 25)
    eating("tofu", 6.2, [(350, 562), (400, 562), (376, 518)], (plate, ""), cube,
           rest_R=(452, 600), mouth_pt=(390, 394), grab_off=(24, 6))

def scene_manti():
    bowl = (f'<path d="M244 584 Q250 668 375 672 Q500 668 506 584 Z" fill="#ffffff" stroke="{NAVY}" stroke-width="{LW}" stroke-linejoin="round"/>'
            f'<path d="M258 616 Q375 648 492 616" fill="none" stroke="#4d73e0" stroke-width="12" stroke-linecap="round"/>'
            f'<ellipse cx="375" cy="584" rx="133" ry="24" fill="#fffdf6" stroke="{NAVY}" stroke-width="{LW}"/>'
            + "".join(manti(x, y, 1.1) for x, y in ((300, 576), (452, 576), (334, 590), (418, 590)))
            + "".join(f'<ellipse cx="{x}" cy="{y}" rx="{rx}" ry="4" fill="#d93a22"/>' for x, y, rx in ((318, 570, 10), (404, 572, 12), (448, 590, 8)))
            + "".join(f'<circle cx="{x}" cy="{y}" r="3.5" fill="#3f8f35"/>' for x, y in ((340, 566), (432, 568), (376, 594))))
    steam = ('<g class="steam">' + "".join(
        f'<path d="M{x} 548 q-10 -16 0 -32 q10 -16 0 -32" fill="none" stroke="#c9c9e6" stroke-width="7" stroke-linecap="round" style="animation-delay:{d}s"/>'
        for x, d in ((262, 0), (488, 1.1))) + "</g>")
    steam_css = ".steam path{animation:steam 2.2s infinite ease-in-out;opacity:0}@keyframes steam{0%{opacity:0;transform:translateY(8px)}40%{opacity:.8}100%{opacity:0;transform:translateY(-36px)}}\n"
    spoon = (f'<g transform="rotate(-28)"><rect x="-6" y="-40" width="12" height="50" rx="6" fill="#d9dbe8" stroke="{NAVY}" stroke-width="7"/>'
             f'<ellipse cx="0" cy="-54" rx="16" ry="20" fill="#d9dbe8" stroke="{NAVY}" stroke-width="7"/></g>')
    piece = manti(0, 0, .9)
    # the spoon bowl sits at the paw + (-41,-76): mantı ride there
    eating("manti", 6.2, [(392, 546), (378, 550), (414, 550)], ('<g transform="translate(0 -24)">' + bowl + steam + "</g>", steam_css), piece,
           rest_R=(452, 600), mouth_pt=(396, 410), grab_off=(24, 48), spoon=spoon)

# ------------------------------------------------------------------ fart and run
def scene_fart():
    dur = 7.5
    keys = [
        (0, pose(STAND, foot="front", eyes="eyes_open", mouth="mouth_open", blush="0")),
        (12, pose(STAND)),
        (19, pose(STAND, root=(-14, -69, -6, 1, 1), legR=(456, 650), armL=(232, 600), armR=(500, 560), head=5, eyes="eyes_shut", mouth="mouth_grin")),
        (23, pose(STAND, root=(-14, -69, -6, 1, 1), legR=(456, 650), head=5)),
        (24.5, pose(STAND, root=(0, -96, 0, 1, 1), head=0)),
        (26, {"eyes": "eyes_wide", "mouth": "mouth_o", "blush": "1"}),
        (28, pose(STAND, armL=(300, 396), armR=(450, 396))),
        (34, pose(STAND, armL=(300, 396), armR=(450, 396), head=-8)),
        (36, pose(STAND, armL=(300, 396), armR=(450, 396), head=8)),
    ]
    # run left: 4 strides
    t, x = 38, 0
    for i in range(8):
        up = "L" if i % 2 == 0 else "R"
        t += 3.2; x -= 105
        k = pose(STAND, root=(x, -69 - (22 if i % 2 == 0 else 6), -8, 1, 1),
                 legL=(300, 628) if up == "L" else (318, 684), legR=(446, 628) if up == "R" else (432, 684),
                 armL=(270, 470) if up == "R" else (250, 600), armR=(480, 470) if up == "L" else (500, 600), head=-4)
        keys.append((t, k))
    keys += [
        (66, pose(STAND, root=(-900, -69, -8, 1, 1))),
        (78, pose(STAND, root=(-900, -69, 0, 1, 1), eyes="eyes_happy", mouth="mouth_grin")),
    ]
    t, x = 78, -900
    for i in range(6):
        up = "L" if i % 2 == 0 else "R"
        t += 3; x += 150
        keys.append((t, pose(STAND, root=(x, -69 - (12 if i % 2 == 0 else 2), 3, 1, 1),
                              legL=(306, 650) if up == "L" else (312, 684), legR=(444, 650) if up == "R" else (438, 684),
                              armL=(262, 560), armR=(488, 560), head=-6)))
    keys += [(98, pose(STAND, eyes="eyes_happy")), (99.5, {"eyes": "eyes_open", "mouth": "mouth_open", "blush": "0"}), (100, pose(STAND))]
    tl = Timeline(keys)
    css = """
.cloud{animation:cloud 7.5s infinite;transform-box:view-box;transform-origin:520px 600px;opacity:0}
@keyframes cloud{0%,23.5%{opacity:0;transform:scale(.2)}27%{opacity:1;transform:scale(.95)}40%{opacity:1;transform:scale(1.05)}60%{opacity:.9;transform:scale(1.3) translateY(-24px)}74%,100%{opacity:0;transform:scale(1.5) translateY(-44px)}}
.c2{animation-delay:.12s}
.stink path{animation:stink 7.5s infinite;opacity:0}
@keyframes stink{0%,27%{opacity:0;transform:translateY(0)}33%{opacity:1}62%{opacity:0;transform:translateY(-56px)}100%{opacity:0}}
.sweat{animation:sweat 7.5s infinite;opacity:0}
@keyframes sweat{0%,27%{opacity:0;transform:translateY(0)}30%{opacity:1}37%{opacity:1;transform:translateY(16px)}40%,100%{opacity:0}}
"""
    behind = (f'<g class="cloud">{cloud(540, 590, 1.3)}</g><g class="cloud c2">{cloud(620, 630, .75)}</g>'
              + '<g class="stink">' + "".join(
                  f'<path d="M{x} 560 q-12 -14 0 -28 q12 -14 0 -28" fill="none" stroke="#7fa83a" stroke-width="7" stroke-linecap="round" style="animation-delay:{d}s"/>'
                  for x, d in ((500, 0), (555, .15), (605, .3))) + "</g>")

    def props(paws, pcts, frames):
        return "", f'<path class="sweat" d="M566 196 q-14 22 0 30 q14 -8 0 -30 Z" fill="#8fd3ff" stroke="{NAVY}" stroke-width="6" stroke-linejoin="round"/>', ""
    svg, _, _ = build(tl, dur, make_props=props, behind=behind, extra_css=css)
    write("fart", svg)

# ------------------------------------------------------------------ roll (idle)
def scene_roll():
    dur = 7
    CURL = pose(SIT, legL=(318, 540), legR=(432, 540), armL=(312, 560), armR=(438, 560), head=0)
    keys = [
        (0, pose(CURL, root=(-950, 0, -720, 1, 1), foot="sole", eyes="eyes_shut", mouth="mouth_grin")),
        (24, pose(CURL, root=(0, 0, 0, 1, 1))),
        (26, {"eyes": "eyes_dizzy", "mouth": "mouth_open"}),
        (28, pose(SIT, root=(0, 10, 0, 1.06, .93), armL=(250, 560), armR=(500, 560))),
        (33, pose(SIT, root=(0, 0, -3, 1, 1), armL=(236, 520), armR=(514, 520), head=-9)),
        (39, pose(SIT, root=(0, 0, 3, 1, 1), armL=(260, 560), armR=(490, 520), head=9)),
        (45, pose(SIT, root=(0, 0, -3, 1, 1), armL=(240, 520), armR=(510, 560), head=-9)),
        (51, pose(SIT, root=(0, 0, 3, 1, 1), head=8)),
        (57, pose(SIT, root=(0, 0, 0, 1, 1), head=-4)),
        (59, pose(SIT, head=-12)), (60.5, pose(SIT, head=12)), (62, pose(SIT, head=-10)), (63.5, pose(SIT, head=0)),
        (64, {"eyes": "eyes_happy", "mouth": "mouth_grin"}),
        (68, pose(SIT, root=(0, -60, 0, 1, 1), armL=(220, 430), armR=(530, 430))),
        (72, pose(CURL, root=(0, 0, 0, 1, 1))),
        (73, {"eyes": "eyes_shut"}),
        (100, pose(CURL, root=(950, 0, 720, 1, 1))),
    ]
    tl = Timeline(keys)
    # keep the lowest point of the curled ball on the ground while it turns
    blobs = [((375, 240), 228), ((375, 560), 120)]
    px, py = ROOT_PIVOT
    def root_fn(p, r):
        dx, dy, rot, sx, sy = r
        if p < 26 or p > 70:
            a = math.radians(rot)
            low = max(py + (cx - px) * math.sin(a) + (cy - py) * math.cos(a) + rad for (cx, cy), rad in blobs)
            dy = 652 - low - 4
        return dx, dy, rot, sx, sy
    css = ".stars{animation:stars 7s infinite steps(1,end)}@keyframes stars{0%{opacity:0}27%{opacity:1}58%{opacity:0}}\n"
    import math as m
    orb = "".join(f"{q}%{{transform:translate({170*m.cos(2*m.pi*q/100):.0f}px,{50*m.sin(2*m.pi*q/100):.0f}px)}}" for q in range(0, 101, 10))
    css += "@keyframes orb{" + orb + "}.orb{animation:orb 1.1s infinite linear}\n"
    front = '<g class="stars">' + "".join(f'<g class="orb" style="animation-delay:-{d}s">{star(375, 14, 32)}</g>' for d in (0, .37, .74)) + "</g>"
    svg, _, _ = build(tl, dur, root_fn=root_fn, front=front, extra_css=css)
    write("roll", svg)

if __name__ == "__main__":
    scene_bamboo(); scene_tofu(); scene_manti(); scene_fart(); scene_roll()
