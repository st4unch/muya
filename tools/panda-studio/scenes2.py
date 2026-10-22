"""One Rive project per panda scene (scene_<name>/scene.rml), built on gen_panda's rig.

python3 scenes2.py wave [FFFFFFFF]     -> scene_wave/scene.rml   (2nd arg = preview background)
"""
import math, os, random, sys
import xml.etree.ElementTree as ET
import gen_panda as G
from gen_panda import el, solid, nid, rect, ellipse, star, keyframes, show, P, REST, GUARD, CROUCH, LAND, RAD, GROUND, PIV, LIMBS, INK, FUR, Frag

# ---------------------------------------------------------------- shared build
def build(name, keys, props=None, extra=None, size=(1000, 1100), origin=(334, 640), background=None, fps=60, head_extra=None, chest_extra=None):
    """panda + optional props(world, front, back) -> dict, then keys + extra(la, ids, props)"""
    G.PAW_IDS.clear(); G.PAW_IDS_NODE.clear()
    W, H = size
    rive = ET.Element("Rive", version="1", kind="fragment")
    ab = el("Artboard", rive, defaultStateMachineId="9:7", styleId="9:5", width=W, height=H, name=name, id="9:2")
    el("LayoutComponentStyle", ab, name="Artboard Style", id="9:5")
    if background:
        solid(ab, "Fill", background)
    world = el("Node", ab, x=origin[0], y=origin[1], name="world", id="9:10")
    front = el("Node", world, name="front", id=nid())                  # props in front of the panda
    body = el("Node", world, x=PIV[0], y=PIV[1], name="body", id="2:11")
    inner = el("Node", body, x=-PIV[0], y=-PIV[1], name="inner", id="2:13")
    back = el("Node", world, name="back", id=nid())                    # props behind the panda
    ids = {"body": "2:11", "head": G.HEAD}
    parts = {}
    for n, (x, y, a, L1, L2, r0, r1, paw) in LIMBS.items():
        node, b1, b2 = G.limb(n, x, y, a, L1, L2, r0, r1, G.hand if paw == "hand" else G.foot)
        parts[n] = node; ids[n + "1"] = b1; ids[n + "2"] = b2
    pr = props(world, front, back, ids) if props else {}
    head = G.face_head()
    if head_extra:
        head_extra(head)                     # things worn on the head turn and bob with it
    for c in (parts["armL"], parts["armR"], head, G.borrowed("1:728"),
              parts["legL"], parts["legR"], G.borrowed("1:740")):
        inner.append(c)
    inner.append(G.borrowed("1:751", x="-209.11639", y="-340.1178"))
    if chest_extra:                          # worn on the chest: over the body, under the arms and head
        for k, c in enumerate(chest_extra()):
            inner.insert(3 + k, c)
    world.append(G.borrowed("1:748", name="shadow", id="2:14")); ids["shadow"] = "2:14"
    sm = el("StateMachine", ab, name="State Machine 1", id="9:7")
    lay = el("StateMachineLayer", sm, name="Layer 1", id="9:8")
    el("AnyState", lay, x=200, y=-120); el("ExitState", lay, x=400, y=-120)
    ent = el("EntryState", lay); el("StateTransition", ent, stateToId="9:12")
    el("AnimationState", lay, x=200, y=100, animationId="9:6", id="9:12")
    end = keys[-1][0]
    la = el("LinearAnimation", ab, duration=end, fps=fps, loopValue="loop", name=name, id="9:6")
    G.panda_tracks(la, ids, keys)
    if extra:
        extra(la, ids, pr, end)
    ET.indent(rive)
    d = f"scene_{name}"
    os.makedirs(d, exist_ok=True)
    if not os.path.exists(f"{d}/rive.yaml"):
        open(f"{d}/rive.yaml", "w").write(f"name: {name}\nlogs:\n  file: build/rive.log\n  problems: build/problems.log\n")
    open(f"{d}/scene.rml", "w").write(ET.tostring(rive, encoding="unicode"))
    return d

def wobble(base, frames, **amp):
    """keys that wobble around a pose: amp = {field: amplitude}, alternating sign each key"""
    out = []
    for i, f in enumerate(frames):
        s = 1 if i % 2 == 0 else -1
        out.append((f, P(base, **{k: base[k] + s * v for k, v in amp.items()}), "io"))
    return out

# ---------------------------------------------------------------- 8. wave
def wave():
    SMILE = P(GUARD, armL1=0, armL2=0, armR1=0, armR2=0)
    UP = P(SMILE, armR1=-150, armR2=-25, head=-6, eyes="happy", mouth="open", lenAR=96)
    keys = [(0, SMILE, "io"), (24, SMILE, "out"), (40, UP, "io")]
    for i, f in enumerate(range(52, 52 + 12 * 6, 12)):
        keys.append((f, P(UP, armR2=-25 + (38 if i % 2 == 0 else -18), head=-6 + (3 if i % 2 else -2)), "io"))
    keys += [(132, UP, "io"), (150, P(SMILE, head=3), "io"), (200, SMILE, "hold")]
    return build("wave", keys)

# ---------------------------------------------------------------- 1. sleep, sitting against a bamboo stalk
def sleep():
    def sit(**k):
        # sitting on the ground: body lowered, legs splayed forward-out, paws folded on the belly,
        # head dropped to the side onto the stalk
        p = P(dy=46, legL1=52, legR1=-52, legL2=-8, legR2=8, eyes="shut", mouth="grin", head=-13, hy=14, rot=-5)
        r1, r2 = G.ik("armL", (150, 252), elbow_out=1); p["armL1"], p["armL2"] = r1, r2
        r1, r2 = G.ik("armR", (182, 258), elbow_out=-1); p["armR1"], p["armR2"] = r1, r2
        p.update(k); return p
    IN, OUT = sit(sy=103, sx=99, hy=10, head=-12), sit(sy=99, sx=101, hy=16, head=-14)
    keys = [(0, OUT, "io"), (70, IN, "io"), (140, OUT, "io"), (210, IN, "io"), (280, OUT, "hold")]

    def props(world, front, back, ids):
        pr = {"z": []}
        # a tall bamboo stalk behind the panda's shoulder to lean on, a second one further back
        back.append(G.bamboo_piece("stalk", -40, G.GROUND - 330, 660, drop=(G.LEAF_BOTTOM,), thick=1.9))
        back.append(G.bamboo_piece("stalk2", 410, G.GROUND - 260, 520, drop=(G.LEAF_BOTTOM,), thick=1.6))
        for k in range(3):
            pr["z"].append(zz(front, 0, 0, 58 - k * 12).get("id"))
        return pr

    def extra(la, ids, pr, end):
        for k, zid in enumerate(pr["z"]):       # z's drift up from the head and fade, one after another
            t0 = k * 90
            la.append(keyframes(zid, 13, [(0, 250, "hold"), (t0, 250, "out"), (t0 + 100, 330, "hold")]))
            la.append(keyframes(zid, 14, [(0, -120, "hold"), (t0, -120, "out"), (t0 + 100, -300, "hold")]))
            la.append(keyframes(zid, 15, [(0, 0, "hold"), (t0, -0.2, "io"), (t0 + 100, 0.25, "hold")]))
            la.append(keyframes(zid, 18, [(0, 0, "hold"), (t0, 0, "lin"), (t0 + 20, 1, "lin"), (t0 + 75, 1, "lin"), (t0 + 100, 0, "hold")]))
    return build("sleep", keys, props, extra)

def zz(parent, x, y, size):
    """a sleepy 'Z' drawn as a thick navy stroke"""
    s = el("Shape", parent, x=x, y=y, opacity=0, name="z", id=nid())
    p = el("PointsPath", s, isClosed="false", name="Path", id=nid())
    for vx, vy in ((-size / 2, -size / 2), (size / 2, -size / 2), (-size / 2, size / 2), (size / 2, size / 2)):
        el("StraightVertex", p, x=vx, y=vy)
    solid(s, "Stroke", INK, thickness=max(5, size / 5), cap="round", join="round")
    return s

# ---------------------------------------------------------------- 2. gaming on a beanbag
PAD = (166, 236)                      # gamepad centre (inner space), held at the belly

def pad_pose(base, jitter=0):
    p = P(base)
    for arm, (gx, gy) in (("armL", (PAD[0] - 46, PAD[1] + 2)), ("armR", (PAD[0] + 46, PAD[1] + 2))):
        r1, r2 = G.ik(arm, (gx, gy + jitter * (1 if arm == "armL" else -1)), elbow_out=1 if arm == "armL" else -1)
        p[arm + "1"], p[arm + "2"] = r1, r2
    return p

def gaming():
    SIT = P(dy=64, legL1=-40, legR1=40, legL2=0, legR2=0, head=0)
    PLAY = pad_pose(SIT)
    keys = [(0, PLAY, "io")]
    f = 0
    for i in range(10):                        # button mashing: paws jiggle, head bobs
        f += 7
        keys.append((f, P(pad_pose(SIT, 6 if i % 2 else -6), head=3 if i % 2 else -3, sy=101 if i % 2 else 99), "io"))
    WIN = P(SIT, armL1=150, armR1=-150, armL2=10, armR2=-10, eyes="happy", mouth="open", dy=40, sy=106, head=0)
    keys += [(f + 16, WIN, "back"), (f + 28, P(WIN, dy=70, sy=96), "io"), (f + 40, WIN, "io"), (f + 60, PLAY, "io")]
    f2 = f + 60
    for i in range(6):
        f2 += 7
        keys.append((f2, P(pad_pose(SIT, 6 if i % 2 else -6), head=3 if i % 2 else -3), "io"))
    keys.append((f2 + 10, PLAY, "hold"))

    def props(world, front, back, ids):
        # beanbag behind; the gamepad rides with the body, in front of the belly and under the paws
        bag = el("Node", back, name="beanbag", id=nid())
        bs = el("Shape", bag, x=166, y=G.GROUND - 40, name="bag", id=nid())
        el("Ellipse", bs, width=470, height=250, name="Path", id=nid())
        solid(bs, "Fill", "FF6A5ACD"); solid(bs, "Stroke", INK, thickness=9)
        hl = el("Shape", bag, x=110, y=G.GROUND - 100, rotation=-0.3, name="shine", id=nid())
        el("Ellipse", hl, width=120, height=40, name="Path", id=nid())
        solid(hl, "Fill", "FF8C7EE0")
        return {"pad": gamepad(world)}

    def extra(la, ids, pr, end):
        # the pad follows the body (simple: same offset as the body)
        track = [(f, p, e) for f, p, e in keys]
        la.append(keyframes(pr["pad"], 13, [(f, PAD[0] + p["dx"], e) for f, p, e in track]))
        la.append(keyframes(pr["pad"], 14, [(f, PAD[1] + p["dy"] + (60 if p["eyes"] == "happy" else 0), e) for f, p, e in track]))
        la.append(keyframes(pr["pad"], 15, [(f, (-0.5 if p["eyes"] == "happy" else 0), e) for f, p, e in track]))
    return build("gaming", keys, props, extra)

def gamepad(parent):
    n = el("Node", parent, x=PAD[0], y=PAD[1], name="gamepad", id=nid())
    parent.remove(n); parent.insert(0, n)        # in front of everything
    # buttons first (on top), then the body
    for bx, by, c in ((44, -10, "FFFF6B6B"), (60, 4, "FF4ECDC4"), (44, 18, "FFFFD54A"), (28, 4, "FF7BC95F")):
        ellipse(n, bx, by, 15, 15, c, stroke=4)
    rect(n, -46, 4, 34, 11, "FF2A2560", "dpadH", stroke=0, radius=3)
    rect(n, -46, 4, 11, 34, "FF2A2560", "dpadV", stroke=0, radius=3)
    rect(n, 0, 0, 170, 74, "FFE8E6F5", "body", stroke=8, radius=34)
    return n.get("id")

# ---------------------------------------------------------------- 11. celebrate
def celebrate():
    HOORAY = P(armL1=118, armR1=-118, armL2=35, armR2=-35, eyes="happy", mouth="open", lenAL=100, lenAR=100)
    keys = [(0, GUARD, "io"), (16, P(CROUCH, eyes="happy"), "out"), (28, P(HOORAY, dy=-170, sy=106, sx=95), "io"),
            (40, P(HOORAY, dy=-185, legL1=20, legR1=-20, legL2=-30, legR2=30), "in"), (54, P(LAND, eyes="happy", mouth="open"), "back"),
            (64, P(CROUCH, eyes="happy", armL1=100, armR1=-100), "out"), (76, P(HOORAY, dy=-120, sy=105), "io"),
            (88, P(HOORAY, dy=-130), "in"), (100, P(LAND, eyes="happy"), "back"),
            (114, P(HOORAY, dy=-4), "io"), (150, P(HOORAY, dy=-4, head=5), "io"), (176, GUARD, "hold")]

    def props(world, front, back, ids):
        rnd = random.Random(5)
        cols = ["FFFF6B6B", "FFFFD54A", "FF4ECDC4", "FF7BC95F", "FFB388FF", "FFFF9F43"]
        frs = []
        for k in range(34):
            c = rect(front, 0, 0, rnd.uniform(12, 20), rnd.uniform(7, 11), cols[k % len(cols)], f"confetti{k}", stroke=0, radius=2, opacity=0)
            ang = rnd.uniform(-math.pi * 0.95, -math.pi * 0.05); sp = rnd.uniform(9, 19)
            frs.append(Frag(c, 166 + rnd.uniform(-30, 30), -40, rnd.uniform(0, 3), math.cos(ang) * sp, math.sin(ang) * sp, rnd.uniform(-0.3, 0.3), G.GROUND - 4))
        return {"confetti": frs}

    def extra(la, ids, pr, end):
        hit = 28
        for fr in pr["confetti"]:
            la.append(keyframes(fr.id, 18, [(0, 0, "hold"), (hit, 1, "hold"), (end - 30, 1, "lin"), (end - 8, 0, "hold")]))
            for prop, k in ((13, 0), (14, 1), (15, 2)):
                pts = [(0, (fr.x, fr.y, fr.rot)[k], "hold")] + [(f, slow_fall(fr, f - hit)[k], "lin") for f in range(hit, end - 6, 3)]
                la.append(keyframes(fr.id, prop, pts))
    return build("celebrate", keys, props, extra)

def slow_fall(fr, t):
    """confetti: fast burst, then flutters down slowly (drag)"""
    k = 0.06
    x = fr.x + fr.vx * (1 - math.exp(-k * t)) / k
    vy_term = 2.2
    y = fr.y + (fr.vy - vy_term) * (1 - math.exp(-k * t)) / k + vy_term * t
    y = min(y, fr.floor)
    return x + 8 * math.sin(t * 0.15 + fr.rot), y, fr.rot + fr.spin * t

# ---------------------------------------------------------------- 12. teacher at a chalkboard
BOARD = (-300, 10, 400, 290)           # board centre x, y, w, h (root space), left of the panda
CHALK = "E6FFFFFF"

def chalk_line(parent, pts, name, w=7):
    s = el("Shape", parent, name=name, id=nid())
    p = el("PointsPath", s, isClosed="false", name="Path", id=nid())
    for x, y in pts:
        el("StraightVertex", p, x=round(x, 1), y=round(y, 1))
    solid(s, "Stroke", CHALK, thickness=w, cap="round", join="round")
    return s

def teacher():
    bx, by, bw, bh = BOARD
    SPOTS = [(bx - 110, by + 70), (bx + 110, by - 70), (bx - 60, by - 70)]    # chart, star, text
    PTR = 190                                   # pointer length past the paw
    def point(base, spot, tap=0):
        """left paw holds the pointer so its tip lands on a spot on the board: search the angle at
        which the forearm (and so the pointer) actually aims from the paw to the spot"""
        p = P(base)
        tx, ty = SPOTS[spot][0] - p["dx"], SPOTS[spot][1] + tap - p["dy"]
        best = None
        for deg in range(-70, 71, 2):
            th = math.radians(deg)
            paw = (tx + PTR * math.cos(th), ty + PTR * math.sin(th))      # paw to the right of the spot
            r1, r2 = G.ik("armL", paw, elbow_out=1)
            q = dict(p, armL1=r1, armL2=r2)
            (px_, py_), d2 = G.tip(q, "armL")
            miss = math.hypot(px_ + PTR * math.cos(d2) - tx, py_ + PTR * math.sin(d2) - ty)
            if best is None or miss < best[0]:
                best = (miss, r1, r2)
        p["armL1"], p["armL2"] = best[1], best[2]
        return p
    EXPLAIN = P(armR1=-55, armR2=-75, head=-7, lenAR=96)          # right paw up, palm out
    BELLY = P(armR1=20, armR2=95, head=-4)
    AUDIENCE = P(armR1=-70, armR2=-40, head=6, eyes="happy", mouth="open", lenAR=96)
    keys = [(0, point(BELLY, 0), "io")]
    f = 0
    for spot, side in ((0, EXPLAIN), (1, BELLY), (2, EXPLAIN)):
        f += 14
        keys.append((f, point(side, spot), "out"))
        for i in range(3):              # tap, tap, tap while talking
            f += 8
            keys.append((f, P(point(side, spot, -12 if i % 2 == 0 else 0), mouth="open" if i % 2 == 0 else "grin"), "io"))
        f += 16
        keys.append((f, P(point(side, spot), mouth="grin"), "io"))
    keys += [(f + 18, point(AUDIENCE, 2, 30), "io"), (f + 50, point(AUDIENCE, 2, 30), "io"), (f + 70, point(BELLY, 0), "hold")]

    def props(world, front, back, ids):
        b = el("Node", back, name="board", id=nid())
        # chalk drawings first (on top of the slate): a bar chart, two lines of "text", a star, a tick
        x0, y0 = SPOTS[0]
        for i, h in enumerate((50, 90, 70)):
            rect(b, x0 - 40 + i * 40, y0 + 40 - h / 2, 22, h, "00000000", f"bar{i}", stroke=0, radius=3)
            chalk_line(b, [(x0 - 51 + i * 40, y0 + 40), (x0 - 51 + i * 40, y0 + 40 - h), (x0 - 29 + i * 40, y0 + 40 - h), (x0 - 29 + i * 40, y0 + 40)], f"bar{i}", 6)
        chalk_line(b, [(x0 - 70, y0 + 40), (x0 + 60, y0 + 40)], "axis", 6)
        tx, ty = SPOTS[2]
        for i, w in enumerate((150, 110)):
            pts = [(tx - 70 + k * 10, ty - 8 + i * 36 + (6 if k % 2 else -6)) for k in range(int(w / 10) + 1)]
            chalk_line(b, pts, f"words{i}", 5)
        sx_, sy_ = SPOTS[1]
        star_pts = []
        for k in range(11):
            r = 34 if k % 2 == 0 else 14
            a_ = -math.pi / 2 + k * math.pi / 5
            star_pts.append((sx_ + r * math.cos(a_), sy_ + r * math.sin(a_)))
        chalk_line(b, star_pts, "star", 5)
        chalk_line(b, [(sx_ - 34, sy_ + 110), (sx_ - 14, sy_ + 132), (sx_ + 30, sy_ + 80)], "tick", 7)
        rect(b, bx, by, bw - 36, bh - 36, "FF2F5D50", "slate", stroke=0, radius=8)
        rect(b, bx, by, bw, bh, "FFB9824A", "frame", stroke=9, radius=14)
        rect(b, bx, by + bh / 2 + 6, bw * 0.7, 16, "FFB9824A", "ledge", stroke=6, radius=6)
        for dx in (-bw / 2 + 60, bw / 2 - 60):           # easel legs to the floor
            top = by + bh / 2
            rect(b, bx + dx, (top + G.GROUND) / 2, 16, G.GROUND - top, "FFB9824A", "leg", stroke=7, radius=6)
        b.remove(b[-1]); b.remove(b[-1])                  # (re-add legs behind the frame)
        for dx in (-bw / 2 + 60, bw / 2 - 60):
            top = by + bh / 2
            b.append(rect(el("Node", None), bx + dx, (top + G.GROUND) / 2, 16, G.GROUND - top, "FFB9824A", "leg", stroke=7, radius=6))
        ptr = G.bamboo_piece("pointer", 0, 0, 190, drop=(G.LEAF_TOP, G.LEAF_BOTTOM), thick=0.5, rot=0)
        G.PAW_IDS_NODE["armL"].insert(0, ptr)
        ptr.attrib.update(x="0", y="95", rotation=f"{math.pi / 2}")
        return {}
    return build("teacher", keys, props, None, size=(1250, 1100), origin=(660, 640))

# ---------------------------------------------------------------- shared bits for B / C
def walk_cycle(base, start, steps, period=16, stride=18, bob=10):
    """in-place walk: legs swing, arms swing the other way, body bobs"""
    keys = []
    for i in range(steps):
        s = 1 if i % 2 == 0 else -1
        keys.append((start + i * period, P(base, legL1=base["legL1"] + s * stride, legR1=base["legR1"] + s * stride,
                                            legL2=base["legL2"] - abs(s) * 6, legR2=base["legR2"] - abs(s) * 6,
                                            armL1=base["armL1"] - s * 14, armR1=base["armR1"] - s * 14,
                                            dy=base["dy"] - bob, head=base["head"] + s * 2), "io"))
        keys.append((start + i * period + period // 2, P(base, dy=base["dy"]), "io"))
    return keys

def flip_track(keys, field, frames):
    return [(f, p[field]) for f, p, e in keys]

def eat_pose(base, r2, head, sy=100):
    """right elbow out to the side, forearm folds the held food to the mouth (see the cookie scene)"""
    return P(base, head=head, sy=sy, armR1=-92, armR2=r2, lenAR=118, armL1=42, armL2=-8, lenAL=96)

def chew_keys(base, start, bites, period=34):
    """bite / chew / chew per bite; returns keys and the frames the bites land on"""
    keys, marks = [], []
    f = start
    for b in range(bites):
        keys += [(f, eat_pose(base, -150, -5, 98), "out"), (f + 8, eat_pose(base, -135, 4, 102), "io"),
                 (f + 16, eat_pose(base, -128, -2, 99), "io"), (f + 24, eat_pose(base, -135, 4, 102), "io")]
        marks.append(f); f += period
    return keys, marks, f

def held_food(paw_name, build_fn, y=55):
    """a node riding a paw, shown in world size (paw space is scaled 0.82)"""
    paw = G.PAW_IDS_NODE[paw_name]
    n = el("Node", paw, x=0, y=y, scaleX=1 / 0.82, scaleY=1 / 0.82, name="held", id=nid())
    paw.remove(n); paw.insert(0, n)
    build_fn(n)
    return n

def crumbs(front, color, n, seed):
    rnd = random.Random(seed)
    return [rect(front, 0, 0, rnd.uniform(8, 13), rnd.uniform(7, 10), color, f"crumb{k}", stroke=3, radius=3, opacity=0).get("id") for k in range(n)]

def crumb_tracks(la, ids_, marks, keys, seed, mouth=(163, 82)):
    rnd = random.Random(seed)
    poses = {f: p for f, p, e in keys}
    for k, cid in enumerate(ids_):
        bite = marks[k % len(marks)]
        pose = poses.get(bite, REST)
        mx, my = G.body_to_root(pose, (mouth[0] + rnd.uniform(-10, 30), mouth[1]))
        fr = Frag(el("Node", None, id=cid), mx, my, 0, rnd.uniform(-2.5, 3.5), -rnd.uniform(1, 4), rnd.uniform(-0.3, 0.3), GROUND - 6)
        la.append(keyframes(cid, 18, [(0, 0, "hold"), (bite, 1, "hold"), (bite + 55, 0, "hold")]))
        for prop, j in ((13, 0), (14, 1), (15, 2)):
            la.append(keyframes(cid, prop, [(0, (fr.x, fr.y, 0)[j], "hold")] + [(bite + t, fr.at(t)[j], "lin") for t in range(0, 56, 3)]))

# ---------------------------------------------------------------- 9. somersault
def flip():
    TUCK = dict(legL1=70, legR1=-70, legL2=-120, legR2=120, armL1=60, armR1=-60, armL2=-110, armR2=110, eyes="shut")
    keys = [(0, GUARD, "io"), (24, GUARD, "io"), (38, P(CROUCH, eyes="shut"), "out"),
            (48, P(dy=-200, sy=106, sx=95, armL1=150, armR1=-150, legL1=10, legR1=-10), "out"),
            (56, P(dy=-280, rot=-120, **TUCK), "lin"), (64, P(dy=-300, rot=-240, **TUCK), "lin"),
            (72, P(dy=-220, rot=-340, **TUCK), "in"), (80, P(dy=-60, rot=-360, armL1=120, armR1=-120, legL1=10, legR1=-10), "in"),
            (86, P(LAND, rot=-360, eyes="happy"), "back"),
            (100, P(rot=-360, armL1=118, armR1=-118, armL2=35, armR2=-35, eyes="happy", mouth="open", lenAL=100, lenAR=100), "io"),
            (140, P(rot=-360, armL1=118, armR1=-118, armL2=35, armR2=-35, eyes="happy", mouth="open", lenAL=100, lenAR=100), "io"),
            (160, P(GUARD, rot=-360), "io"), (180, P(GUARD, rot=-360), "hold")]
    return build("flip", keys)

# ---------------------------------------------------------------- 10. bow (kung fu salute)
def bow():
    def salute(base):
        p = P(base)
        r1, r2 = G.ik("armL", (150, 225), elbow_out=1); p["armL1"], p["armL2"] = r1, r2
        r1, r2 = G.ik("armR", (182, 225), elbow_out=-1); p["armR1"], p["armR2"] = r1, r2
        return p
    UP = salute(P(head=0))
    DOWN = salute(P(hy=36, sy=94, dy=16, eyes="shut", head=0))
    keys = [(0, GUARD, "io"), (20, GUARD, "io"), (34, UP, "io"), (50, UP, "io"), (66, DOWN, "io"), (90, DOWN, "io"),
            (106, UP, "io"), (124, P(UP, eyes="happy"), "io"), (150, GUARD, "io"), (170, GUARD, "hold")]
    return build("bow", keys)

# ---------------------------------------------------------------- 7. roll down a hill
HILL_X = (-470, 560)                    # root x where the slope starts (top) and ends (bottom)
HILL_TOP = 300                          # how high the top is above the floor

def hill_y(x):
    """floor height (root y) on the slope at x: an eased S-curve from top to bottom"""
    t = min(1, max(0, (x - HILL_X[0]) / (HILL_X[1] - HILL_X[0])))
    s = t * t * (3 - 2 * t)
    return GROUND - HILL_TOP * (1 - s)

# how far below the body pivot the tucked ball reaches at each rotation (measured by
# measure_ball.py from renders); the big head makes it an egg, not a ball
BALL_LOW = {0: 49, 24: 73, 48: 94, 72: 129, 96: 257, 120: 418, 144: 519, 168: 541, 192: 540,
            216: 516, 240: 415, 264: 252, 288: 130, 312: 94, 336: 73}
ROLL_H = 245                       # roll about a point this far above the pivot (between belly and head)

def ball_low(a):
    a %= 360
    lo = int(a // 24) * 24; hi = (lo + 24) % 360
    t = (a - lo) / 24
    return BALL_LOW[lo] * (1 - t) + BALL_LOW[hi] * t

def roll():
    BALL = dict(legL1=70, legR1=-70, legL2=-120, legR2=120, armL1=60, armR1=-60, armL2=-110, armR2=110, eyes="shut", sx=86, sy=86)
    guard_arms = {k: v for k, v in GUARD.items() if k.startswith("arm") or k == "head"}
    def stand(x, **k):         # feet on the slope at root x (body centre)
        return P(dx=x - PIV[0], dy=hill_y(x) - GROUND, **k)
    def rolling(x, rot, **k):  # an egg rolling on the slope about its middle: lowest point on the ground
        rr = rot * RAD
        g = ball_low(rot) + ROLL_H * math.cos(rr)          # lowest point below the roll centre
        cy = hill_y(x) - g                                  # roll centre, root space
        p = P(rot=rot, **BALL, **k)
        p["dx"] = x - ROLL_H * math.sin(rr) - PIV[0]
        p["dy"] = cy + ROLL_H * math.cos(rr) - PIV[1]
        return p
    X0, X1 = -330, 430
    keys = [(0, stand(X0, **guard_arms), "io"), (24, stand(X0, eyes="happy", mouth="open", **guard_arms), "io"),
            (36, rolling(X0, 0), "out")]
    f, x, r = 36, X0, 0.0
    while x < X1:              # roll: angle follows the distance (radius ~ 260), speeding up downhill
        step = 14 + 26 * (x - X0) / (X1 - X0)
        x = min(X1, x + step); r += step / 260 / RAD; f += 3
        keys.append((f, rolling(x, r), "lin"))
    end_rot = math.ceil(r / 360) * 360
    keys.append((f + 10, rolling(X1 + 30, end_rot - 20), "out"))
    keys.append((f + 20, stand(X1 + 30, rot=end_rot, eyes="shut", head=8, sx=108, sy=92), "back"))
    for i in range(5):          # dizzy wobble
        keys.append((f + 32 + i * 9, stand(X1 + 30, rot=end_rot + (7 if i % 2 else -7), eyes="shut", mouth="open", head=(-9 if i % 2 else 9)), "io"))
    f += 32 + 45
    keys.append((f + 10, stand(X1 + 30, rot=end_rot, eyes="happy", mouth="open", armL1=118, armR1=-118, armL2=35, armR2=-35), "io"))
    f += 30
    # hop back up the hill in four big hops
    xs = [X1 + 30 - (X1 + 30 - X0) * k / 4 for k in range(5)]
    for k in range(4):
        mid = (xs[k] + xs[k + 1]) / 2
        keys.append((f + 8, P(stand(xs[k], rot=end_rot, **CROUCH_LEGS), sy=92, sx=106), "out"))
        keys.append((f + 20, P(stand(mid, rot=end_rot, legL1=20, legR1=-20, legL2=-30, legR2=30, armL1=40, armR1=-40), dy=hill_y(mid) - GROUND - 95), "in"))
        keys.append((f + 32, P(stand(xs[k + 1], rot=end_rot), sy=94, sx=105), "back"))
        f += 32
    keys.append((f + 16, stand(X0, rot=end_rot, **guard_arms), "hold"))

    def props(world, front, back, ids):
        h = el("Shape", back, name="hill", id=nid())
        p = el("PointsPath", h, isClosed="true", name="Path", id=nid())
        xs_ = [HILL_X[0] - 260 + i * 20 for i in range(int((HILL_X[1] - HILL_X[0] + 520) / 20) + 1)]
        for xv in xs_:
            el("StraightVertex", p, x=xv, y=round(hill_y(xv) + 4, 1))
        el("StraightVertex", p, x=xs_[-1], y=GROUND + 200); el("StraightVertex", p, x=xs_[0], y=GROUND + 200)
        solid(h, "Fill", "FF8FD46F"); solid(h, "Stroke", INK, thickness=8, join="round")
        for gx in (-380, -150, 120, 360):               # tufts of grass on the slope
            t = el("Shape", back, x=gx, y=hill_y(gx) + 2, name="tuft", id=nid())
            q = el("PointsPath", t, isClosed="false", name="Path", id=nid())
            for vx, vy in ((-14, 0), (-8, -22), (-2, 0), (4, -28), (10, 0), (16, -18), (20, 0)):
                el("StraightVertex", q, x=vx, y=vy)
            solid(t, "Stroke", "FF4E9A3A", thickness=5, cap="round", join="round")
            back.remove(t); back.insert(0, t)
        return {}
    return build("roll", keys, props, size=(1500, 1260), origin=(720, 760))

CROUCH_LEGS = dict(legL1=10, legR1=-10, legL2=-22, legR2=22)

# ---------------------------------------------------------------- 6. fart and run
def fart():
    keys = [(0, GUARD, "io"), (20, GUARD, "io"), (30, P(sx=106, sy=95, eyes="shut"), "io"), (36, P(sx=96, sy=104, eyes="shut"), "io"),
            (42, P(sx=106, sy=95, eyes="shut"), "io"), (50, P(dy=-30, eyes="open", mouth="open", armL1=60, armR1=-60, armL2=-40, armR2=40, hy=-14), "out"),
            (66, P(dy=-30, eyes="open", mouth="open", armL1=60, armR1=-60, armL2=-40, armR2=40, hy=-14), "io")]
    # run off to the right
    f, x = 66, 0
    for i in range(10):
        x += 70; s = 1 if i % 2 == 0 else -1
        keys.append((f + 6, P(dx=x, dy=-14, legL1=s * 40, legR1=s * 40, legL2=-20, legR2=-20, armL1=-s * 50, armR1=-s * 50,
                               armL2=-60, armR2=60, eyes="shut", mouth="open", rot=6), "lin")); f += 6
    keys.append((f + 30, P(dx=x, eyes="shut"), "hold"))
    f += 30
    # peeks back in, embarrassed, and tiptoes home
    keys.append((f + 1, P(dx=620, eyes="happy"), "io"))
    for i in range(8):
        s = 1 if i % 2 == 0 else -1
        keys.append((f + 14 + i * 12, P(dx=620 - (i + 1) * 77, dy=-6, legL1=s * 14, legR1=s * 14, eyes="happy", head=s * 3,
                                       armL1=-30, armR1=30, armL2=-90, armR2=90), "io"))
    f += 14 + 8 * 12
    keys.append((f + 14, GUARD, "hold"))
    end = f + 14

    def props(world, front, back, ids):
        rnd = random.Random(3)
        clouds = []
        for k in range(6):
            c = el("Shape", back, x=166 + rnd.uniform(-60, 60), y=330 + rnd.uniform(-30, 30), scaleX=0, scaleY=0, opacity=0, name=f"cloud{k}", id=nid())
            el("Ellipse", c, width=rnd.uniform(90, 140), height=rnd.uniform(70, 100), name="Path", id=nid())
            solid(c, "Fill", "CC9BE07A"); solid(c, "Stroke", "FF6FBF4A", thickness=5)
            clouds.append((c.get("id"), rnd.uniform(-90, 90), rnd.uniform(-120, -30), k))
        return {"clouds": clouds}

    def extra(la, ids, pr, end):
        for cid, ex, ey, k in pr["clouds"]:
            t0 = 44 + k * 3
            for prop in (16, 17):
                la.append(keyframes(cid, prop, [(0, 0, "hold"), (t0, 0, "out"), (t0 + 30, 1.3, "io"), (t0 + 140, 1.6, "hold")]))
            la.append(keyframes(cid, 18, [(0, 0, "hold"), (t0, 1, "lin"), (t0 + 100, 1, "lin"), (t0 + 150, 0, "hold")]))
            la.append(keyframes(cid, 14, [(0, 330, "hold"), (t0, 330, "out"), (t0 + 140, 330 + ey, "hold")]))
    return build("fart", keys, props, extra, size=(1500, 1100), origin=(420, 640))

# ---------------------------------------------------------------- 13. fan dance
def dance():
    keys = [(0, GUARD, "io")]
    f = 10
    for i in range(10):
        s = 1 if i % 2 == 0 else -1
        keys.append((f, P(dx=s * 26, rot=s * 7, head=-s * 6, armL1=(150 if s > 0 else 40), armL2=(10 if s > 0 else -60),
                          armR1=(-40 if s > 0 else -150), armR2=(60 if s > 0 else -10), legL1=s * 10, legR1=s * 10,
                          eyes="happy", mouth="open" if i % 4 < 2 else "grin", lenAL=96, lenAR=96), "io"))
        keys.append((f + 10, P(dy=12, sy=96, eyes="happy", armL1=95, armR1=-95, armL2=-20, armR2=20, head=0), "io"))
        f += 20
    keys.append((f + 10, GUARD, "hold"))

    def props(world, front, back, ids):
        for paw in ("armL", "armR"):
            held_food(paw, fan, y=40)
        return {}
    return build("dance", keys, props)

def fan(n):
    """a folding fan: pink half-disc with ribs, pivot at the handle"""
    for a in range(-60, 61, 30):     # ribs on top
        r = math.radians(a - 90)
        s = el("Shape", n, name="rib", id=nid())
        p = el("PointsPath", s, isClosed="false", name="Path", id=nid())
        el("StraightVertex", p, x=0, y=0); el("StraightVertex", p, x=round(70 * math.cos(r), 1), y=round(70 * math.sin(r), 1))
        solid(s, "Stroke", "FFC2185B", thickness=4, cap="round")
    s = el("Shape", n, name="fan", id=nid())
    p = el("PointsPath", s, isClosed="true", name="Path", id=nid())
    el("StraightVertex", p, x=0, y=0)
    for a in range(-75, 76, 10):
        r = math.radians(a - 90)
        el("StraightVertex", p, x=round(78 * math.cos(r), 1), y=round(78 * math.sin(r), 1))
    solid(s, "Fill", "FFFF8FB1"); solid(s, "Stroke", INK, thickness=6, join="round")
    n.set("rotation", f"{math.pi}")      # the fan opens away from the paw

# ---------------------------------------------------------------- 3. snap bamboo and eat it
def bamboo_eat():
    def hold_both(base):
        p = P(base)
        r1, r2 = G.ik("armL", (96, 236), elbow_out=1); p["armL1"], p["armL2"] = r1, r2
        r1, r2 = G.ik("armR", (236, 236), elbow_out=-1); p["armR1"], p["armR2"] = r1, r2
        return p
    HOLD = hold_both(P(head=4))
    SNAP = hold_both(P(head=-4, eyes="shut", sx=104, sy=96))
    keys = [(0, HOLD, "io"), (30, HOLD, "io"), (40, P(SNAP, armL1=SNAP["armL1"] + 18, armR1=SNAP["armR1"] - 18), "out"), (52, HOLD, "io")]
    ck, marks, f = chew_keys(P(), 70, 3)
    keys += [(62, eat_pose(P(), -120, 6), "io")] + ck + [(f + 10, P(eyes="happy", armL1=-30, armR1=30, armL2=-90, armR2=90), "io"),
                                                          (f + 50, P(eyes="happy", armL1=-30, armR1=30, armL2=-90, armR2=90), "io"), (f + 70, HOLD, "hold")]

    def props(world, front, back, ids):
        whole = G.bamboo_piece("stick", 166, 236, 300, drop=(G.LEAF_BOTTOM,), thick=1.1, rot=0)
        front.insert(0, whole)
        pieces = []
        def piece(n):
            for k in range(3):
                g = G.bamboo_piece(f"bite{k}", 0, 0, 110 - k * 30, drop=(G.LEAF_TOP, G.LEAF_BOTTOM), thick=1.1, rot=math.pi / 2)
                g.set("y", f"{(110 - k * 30) / 2 - 10}"); g.set("opacity", "0"); n.append(g); pieces.append(g.get("id"))
        held_food("armR", piece, y=30)
        drop = G.bamboo_piece("dropped", 100, 236, 150, drop=(G.LEAF_TOP,), thick=1.1, rot=0)
        drop.set("opacity", "0"); front.append(drop)
        return {"whole": whole.get("id"), "pieces": pieces, "drop": drop.get("id"), "crumbs": crumbs(front, "FF7BC95F", 12, 4), "marks": marks}

    def extra(la, ids, pr, end):
        show(la, pr["whole"], [(0, 1), (52, 0), (end - 20, 1)])
        la.append(keyframes(pr["whole"], 13, [(f, 166 + p["dx"], e) for f, p, e in keys]))
        la.append(keyframes(pr["whole"], 14, [(f, 236 + p["dy"], e) for f, p, e in keys]))
        show(la, pr["drop"], [(0, 0), (52, 1), (end - 20, 0)])
        fr = Frag(el("Node", None, id=pr["drop"]), 100, 236, 0, -3, -6, -0.12, GROUND - 14)
        for prop, j in ((13, 0), (14, 1), (15, 2)):
            la.append(keyframes(pr["drop"], prop, [(0, (100, 236, 0)[j], "hold")] + [(52 + t, fr.at(t)[j], "lin") for t in range(0, 60, 3)]))
        stages = [62] + marks + [end + 1]
        for k, pid in enumerate(pr["pieces"]):
            show(la, pid, [(0, 0), (stages[k], 1), (stages[k + 1], 0)])
        crumb_tracks(la, pr["crumbs"], marks, keys, 4)
    return build("bamboo_eat", keys, props, extra)

# ---------------------------------------------------------------- 4. tofu eat / 5. mantı
def bitten_polys(shape, bites):
    from shapely.geometry import Point
    out = [shape]
    for i in range(1, len(bites) + 1):
        p = shape
        for bx, by in bites[:i]:
            p = p.difference(Point(bx, by).buffer(26, 24))
        out.append(p)
    return out

def poly_shape(parent, poly, fill, name, opacity=1.0, stroke=7):
    s = el("Shape", parent, opacity=opacity, name=name, id=nid())
    p = el("PointsPath", s, isClosed="true", name="Path", id=nid())
    geom = max(getattr(poly, "geoms", [poly]), key=lambda g: g.area)
    for x, y in list(geom.exterior.coords)[:-1]:
        el("StraightVertex", p, x=round(x, 2), y=round(y, 2))
    solid(s, "Fill", fill); solid(s, "Stroke", INK, thickness=stroke, join="round")
    return s

def upright_track(la, node_id, arm, keys, extra_deg=0):
    """keep a held prop upright in the world: undo the arm's (and body's) turn on the paw's child"""
    rest = LIMBS[arm][2]
    la.append(keyframes(node_id, 15, [(f, -(rest + (p[arm + "1"] + p[arm + "2"] + p["rot"]) * RAD) + math.pi / 2 + extra_deg * RAD, e) for f, p, e in keys]))

def tofu_shapes(parent, bites):
    """a soft tofu cube in 2.5D: front face, a lighter top, a shaded right side; bites eat into all of it"""
    from shapely.geometry import Polygon, LineString, Point
    front = Polygon([(-44, -26), (40, -26), (40, 56), (-44, 56)])
    top = Polygon([(-44, -26), (40, -26), (60, -46), (-24, -46)])
    side = Polygon([(40, -26), (60, -46), (60, 36), (40, 56)])
    ids = []
    for stage in range(len(bites) + 1):
        cut = None
        for bx, by in bites[:stage]:
            c = Point(bx, by).buffer(24, 24)
            cut = c if cut is None else cut.union(c)
        n = el("Node", parent, opacity=1 if stage == 0 else 0, name=f"tofu{stage}", id=nid())
        whole = front.union(top).union(side)
        # face fills first (on top), outline last
        for poly, col in ((top, "FFFFFFFF"), (side, "FFE9DFC6"), (front, "FFFFF8E7")):
            piece = poly.difference(cut) if cut is not None else poly
            if not piece.is_empty and piece.area > 30:
                poly_shape(n, piece, col, "face", stroke=0)
        sil = whole.difference(cut) if cut is not None else whole
        s = poly_shape(n, sil, "00000000", "outline", stroke=7)
        # the inner edges (front/top, front/side), cut where bitten
        for a_, b_ in (((-44, -26), (40, -26)), ((40, -26), (40, 56))):
            ln = LineString([a_, b_])
            if cut is not None:
                ln = ln.difference(cut)
            for g in getattr(ln, "geoms", [ln]):
                if g.length > 4:
                    e = el("Shape", n, name="edge", id=nid())
                    pth = el("PointsPath", e, isClosed="false", name="Path", id=nid())
                    for x, y in g.coords:
                        el("StraightVertex", pth, x=round(x, 1), y=round(y, 1))
                    solid(e, "Stroke", INK, thickness=4, cap="round")
                    n.remove(e); n.insert(0, e)
        ids.append(n.get("id"))
    return ids

def tofu_eat():
    BITES = [(-40, -40), (-6, -48), (-44, 8)]          # from the top-left corner: the side facing the mouth
    def eat(r2, head, sy=100):
        return P(head=head, sy=sy, armR1=-92, armR2=r2, lenAR=118, armL1=14, armL2=-12)
    keys = [(0, eat(-112, 6), "io"), (24, eat(-120, 8, 102), "io")]
    f, marks = 40, []
    for b in range(3):
        keys += [(f, eat(-150, -5, 98), "out"), (f + 8, eat(-135, 4, 102), "io"), (f + 16, eat(-128, -2, 99), "io"), (f + 24, eat(-135, 4, 102), "io")]
        marks.append(f); f += 34
    HAPPY = P(eyes="happy", armL1=-30, armR1=30, armL2=-90, armR2=90)
    keys += [(f + 10, HAPPY, "io"), (f + 50, HAPPY, "io"), (f + 70, eat(-112, 6), "hold")]

    def props(world, front, back, ids):
        st = []
        def build_tofu(n):
            st.append(n.get("id"))
            st.extend(tofu_shapes(n, BITES))
        held_food("armR", build_tofu, y=78)
        return {"held": st[0], "stages": st[1:], "crumbs": crumbs(front, "FFFFF8E7", 12, 6)}

    def extra(la, ids, pr, end):
        upright_track(la, pr["held"], "armR", keys)
        for prop in (16, 17):
            la.append(keyframes(pr["held"], prop, [(0, 1.32 / 0.82, "hold")]))
        stages = [0] + marks + [marks[-1] + 26]           # the last bite finishes it
        for k, sid in enumerate(pr["stages"]):
            if k == 0:
                show(la, sid, [(0, 1), (stages[1], 0), (end - 6, 1)])
            else:
                show(la, sid, [(0, 0), (stages[k], 1), (stages[k + 1], 0)])
        crumb_tracks(la, pr["crumbs"], marks, keys, 6)
    return build("tofu_eat", keys, props, extra)

PLATE = (430, 300)                       # plate centre (root space), on a low table to the right
MANTI = [(-44, -6), (0, -14), (44, -6)]

def manti():
    def reach(i):
        tx, ty = PLATE[0] + MANTI[i][0], PLATE[1] + MANTI[i][1] - 10
        p = P(head=-8, hy=10)
        r1, r2 = G.ik("armR", (tx - 30, ty + 10), elbow_out=-1); p["armR1"], p["armR2"] = r1, r2
        return p
    keys = [(0, GUARD, "io"), (20, P(GUARD, eyes="happy", mouth="open"), "io")]
    f = 40; marks = []
    for i in range(3):
        keys += [(f, reach(i), "io"), (f + 14, reach(i), "io"), (f + 30, eat_pose(P(), -150, -5, 98), "out")]
        marks.append(f + 14)
        keys += [(f + 38, eat_pose(P(), -135, 4, 102), "io"), (f + 46, eat_pose(P(), -128, -2, 99), "io"), (f + 54, eat_pose(P(), -135, 4, 102), "io")]
        f += 62
    keys += [(f + 10, P(eyes="happy", armL1=-30, armR1=30, armL2=-90, armR2=90), "io"), (f + 50, P(eyes="happy", armL1=-30, armR1=30, armL2=-90, armR2=90), "io"),
             (f + 70, GUARD, "hold")]

    def props(world, front, back, ids):
        t = el("Node", front, name="table", id=nid())
        dumplings = []
        for i, (mx, my) in enumerate(MANTI):     # dumplings on top of the plate
            dumplings.append(dumpling(t, PLATE[0] + mx, PLATE[1] + my).get("id"))
        sauce = el("Shape", t, x=PLATE[0], y=PLATE[1] + 4, name="sauce", id=nid())
        el("Ellipse", sauce, width=150, height=34, name="Path", id=nid()); solid(sauce, "Fill", "FFFFFBF2")
        drizzle = el("Shape", t, x=PLATE[0], y=PLATE[1] + 4, name="pepper", id=nid())
        el("Ellipse", drizzle, width=110, height=18, name="Path", id=nid()); solid(drizzle, "Stroke", "FFE04A2F", thickness=5)
        t.remove(drizzle); t.insert(len(dumplings), drizzle)
        rect(t, PLATE[0], PLATE[1] + 14, 190, 30, "FFF4F1FF", "plate", stroke=7, radius=15)
        rect(t, PLATE[0], PLATE[1] + 36, 230, 16, "FFB9824A", "tabletop", stroke=7, radius=6)
        for dx in (-90, 90):
            rect(t, PLATE[0] + dx, (PLATE[1] + 44 + GROUND) / 2, 14, GROUND - PLATE[1] - 44, "FFB9824A", "leg", stroke=6, radius=5)
        inhand = []
        held_food("armR", lambda n: inhand.append(dumpling(n, 0, 0, opacity=0).get("id")), y=48)
        return {"plate": dumplings, "inhand": inhand[0], "crumbs": crumbs(front, "FFFFF1D6", 9, 8)}

    def extra(la, ids, pr, end):
        for i, did in enumerate(pr["plate"]):      # leaves the plate when picked up
            show(la, did, [(0, 1), (marks[i], 0), (end - 20, 1)])
        frames = [(0, 0)]
        for m in marks:
            frames += [(m, 1), (m + 40, 0)]
        show(la, pr["inhand"], frames)
        crumb_tracks(la, pr["crumbs"], [m + 16 for m in marks], keys, 8)
    return build("manti", keys, props, extra, size=(1150, 1100), origin=(330, 640))

def dumpling(parent, x, y, opacity=1):
    """a little mantı: a cream square pinched into a knot at the top"""
    n = el("Node", parent, x=x, y=y, opacity=opacity, name="manti", id=nid())
    k = el("Shape", n, x=0, y=-17, name="knot", id=nid())
    el("Ellipse", k, width=14, height=12, name="Path", id=nid()); solid(k, "Fill", "FFFFF1D6"); solid(k, "Stroke", INK, thickness=4)
    rect(n, 0, 0, 40, 30, "FFFFF1D6", "dough", stroke=5, radius=11)
    return n

# ---------------------------------------------------------------- 14. traveller
def scenery(back, n=4, seed=1):
    """bamboo stalks that scroll past behind a walking panda"""
    rnd = random.Random(seed); out = []
    for k in range(n):
        h = rnd.uniform(380, 560)
        g = G.bamboo_piece(f"tree{k}", 0, GROUND - h / 2, h, drop=(G.LEAF_BOTTOM,), thick=1.3)
        back.append(g); out.append((g.get("id"), k))
    return out

def scroll_tracks(la, trees, end, span=1400, x0=-600):
    for tid, k in trees:
        off = k * span / len(trees)
        pts = []
        for f in range(0, end + 1, 6):    # moves right -> left, wraps around
            x = x0 + span - ((off + f * 3.2) % span)
            pts.append((f, x, "lin"))
        # break the wrap: hold at the jump so it does not slide back across the screen
        fixed = []
        for i, (f, x, e) in enumerate(pts):
            nxt = pts[i + 1][1] if i + 1 < len(pts) else x
            fixed.append((f, x, "hold" if nxt > x else "lin"))
        la.append(keyframes(tid, 13, fixed))

def straw_hat(head):
    """a straw sun hat on the head node (head space: the top of the head is near y -230)"""
    h = el("Node", head, x=-12, y=-176, name="hat", id=nid())
    head.remove(h); head.insert(0, h)                   # on top of the head art
    rect(h, 0, -40, 196, 24, "FFE04A4A", "band", stroke=0, radius=6)
    d = el("Shape", h, x=0, y=-30, name="crown", id=nid())
    p = el("PointsPath", d, isClosed="true", name="Path", id=nid())
    for k in range(0, 13):
        a_ = math.pi + k * math.pi / 12
        el("StraightVertex", p, x=round(110 * math.cos(a_), 1), y=round(96 * math.sin(a_), 1))
    solid(d, "Fill", "FFF2D27A"); solid(d, "Stroke", INK, thickness=8, join="round")
    b = el("Shape", h, x=0, y=-24, name="brim", id=nid())
    el("Ellipse", b, width=430, height=86, name="Path", id=nid())
    solid(b, "Fill", "FFF2D27A"); solid(b, "Stroke", INK, thickness=8)

def map_sheet(n):
    for x in (-25, 25):                                   # folds
        rect(n, x, 0, 3, 96, "33000073", "fold", stroke=0, radius=1)
    for i, (x, y) in enumerate(((-55, 30), (-30, 18), (-5, 24), (20, 4))):     # a dotted route
        ellipse(n, x, y, 7, 7, "FFE04A4A")
    xm = el("Shape", n, x=40, y=-18, name="x", id=nid())
    q = el("PointsPath", xm, isClosed="false", name="Path", id=nid())
    for vx, vy in ((-9, -9), (9, 9)):
        el("StraightVertex", q, x=vx, y=vy)
    solid(xm, "Stroke", "FFE04A4A", thickness=5, cap="round")
    rect(n, 0, 0, 150, 104, "FFF5E6B8", "map", stroke=6, radius=6)

def suitcase(parent, x):
    """a rolling suitcase standing on the floor, its handle up by the paw"""
    n = el("Node", parent, name="suitcase", id=nid())
    for dx in (-26, 26):
        ellipse(n, x + dx, G.GROUND - 6, 20, 20, "FF2A2560")
    rect(n, x - 22, G.GROUND - 212, 8, 50, "FF9AA0B5", "rodL", stroke=4, radius=3)
    rect(n, x + 22, G.GROUND - 212, 8, 50, "FF9AA0B5", "rodR", stroke=4, radius=3)
    rect(n, x, G.GROUND - 240, 64, 14, "FF2A2560", "grip", stroke=4, radius=6)
    rect(n, x, G.GROUND - 100, 140, 180, "FF3FA7D6", "case", stroke=8, radius=20)
    rect(n, x, G.GROUND - 100, 104, 10, "FF2E86B0", "stripe", stroke=0, radius=4)
    return n

def traveller():
    def read(**k):
        p = P(lenAL=96, **k)
        r1, r2 = G.ik("armL", (128, 205), elbow_out=1); p["armL1"], p["armL2"] = r1, r2
        r1, r2 = G.ik("armR", (300, 172), elbow_out=-1); p["armR1"], p["armR2"] = r1, r2     # holds the case's grip
        return p
    keys = [(0, read(head=8, hy=12), "io"), (30, read(head=8, hy=12), "io"), (46, read(head=-8, hy=12), "io"),
            (62, read(head=10, hy=12, mouth="open"), "io"), (80, read(head=-4, hy=4, eyes="shut"), "io")]
    AHA = read(eyes="happy", mouth="open", hy=-6)
    AHA["armL1"], AHA["armL2"] = 150, 20
    keys += [(94, P(AHA, dy=-40, sy=104), "out"), (104, AHA, "back"), (120, AHA, "io")]
    POINT = read(eyes="open", mouth="open", head=-6)
    POINT["armL1"], POINT["armL2"] = 100, -10
    keys += [(140, POINT, "io"), (180, POINT, "io"), (200, read(head=8, hy=12), "hold")]

    def props(world, front, back, ids):
        pr = {}
        held = []
        def mp(n):
            held.append(n.get("id")); map_sheet(n)
        held_food("armL", mp, y=58)
        pr["map"] = held[0]
        suitcase(back, 330)
        return pr

    def extra(la, ids, pr, end):
        upright_track(la, pr["map"], "armL", keys)

    def straps():                      # backpack straps over the shoulders (body space)
        out = []
        for dx in (-62, 62):
            out.append(rect(el("Node", None), 166 + dx, 215, 24, 150, "FFC85F22", "strap", stroke=6, radius=10))
        return out
    return build("traveller", keys, props, extra, size=(1100, 1100), origin=(334, 640), head_extra=straw_hat, chest_extra=straps)

SCENES = {"wave": wave, "sleep": sleep, "gaming": gaming, "celebrate": celebrate, "teacher": teacher,
          "flip": flip, "bow": bow, "roll": roll, "fart": fart, "dance": dance,
          "bamboo_eat": bamboo_eat, "tofu_eat": tofu_eat, "manti": manti, "traveller": traveller}

if __name__ == "__main__":
    names = sys.argv[1].split(",") if len(sys.argv) > 1 else list(SCENES)
    bg = sys.argv[2] if len(sys.argv) > 2 else None
    for n in names:
        import functools
        orig = build.__defaults__
        build.__defaults__ = orig[:4] + (bg,) + orig[5:]
        print(SCENES[n]())
        build.__defaults__ = orig
