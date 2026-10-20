"""Muya's panda rig, built in Rive RML (see README.md), plus the bamboo and cookie scenes.

Head, torso, belly, shadow and bamboo come from the imported artwork (art/panda.rml,
artboards "Kungfu Panda" and "Faces"). Arms and legs are new: each is ONE tube path skinned
to a 2-bone chain (rubber hose, no visible elbow/knee), in the artwork's colours, with a paw
parented to the tip bone.

python3 gen_panda.py bamboo - scene_bamboo 1000 654       (scenes, background or -, out dir,
python3 gen_panda.py cookie - scene_cookie 1100 0 cam      artboard width, origin x, follow cam)

Coordinates are the artwork's "root" space (root sits at artboard 209,450).
In Rive the FIRST child draws on top.
"""
import copy, math, os, sys
import xml.etree.ElementTree as ET

SRC = ET.parse(os.path.join(os.path.dirname(os.path.abspath(__file__)), "art", "panda.rml")).getroot()
BY_ID = {e.get("id"): e for e in SRC.iter() if e.get("id")}

INK = "FF000073"      # outline navy
FUR = "FF5F537B"      # dark fur (limbs)
PAD = "FFB4AFD6"      # paw pads
_n = [100]
def nid():
    _n[0] += 1
    return f"2:{_n[0]}"

def el(tag, parent=None, **a):
    e = ET.Element(tag, {k: (f"{v:.4f}".rstrip("0").rstrip(".") if isinstance(v, float) else str(v)) for k, v in a.items()})
    if parent is not None:
        parent.append(e)
    return e

def solid(parent, kind, color, **a):
    p = el(kind, parent, name=kind, **a)
    el("SolidColor", p, colorValue=color, name="C")
    return p

def borrowed(id_, **override):
    e = copy.deepcopy(BY_ID[id_])
    for k, v in override.items():
        e.set(k, str(v))
    return e

# ---- the head, with every expression (eyes open/shut/happy, mouth grin/open) ----
HEAD = "1:1026"
FACE = {"eyes_open": "1:1113", "eyes_shut": "1:1091", "eyes_happy": "1:1102", "mouth_grin": "1:1048", "mouth_open": "1:1060"}

def face_head():
    h = borrowed(HEAD, x="178.49863", y="-101.2798")
    for e in h.iter():
        if e.get("id") in (FACE["eyes_shut"], FACE["eyes_happy"], FACE["mouth_open"]):
            e.set("opacity", "0")
    return h

# ---- limbs -----------------------------------------------------------------------
def smooth(e0, e1, x):
    t = min(1, max(0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)

def tube_points(L1, L2, r0, r1, step=7):
    L = L1 + L2
    n = max(2, int(L / step))
    xs = [L * i / n for i in range(n + 1)]
    rad = lambda x: r0 + (r1 - r0) * x / L
    pts = [(x, -rad(x)) for x in xs]
    pts += [(L + r1 * math.cos(math.radians(a)), r1 * math.sin(math.radians(a))) for a in range(-60, 61, 30)]
    pts += [(x, rad(x)) for x in reversed(xs)]
    pts += [(-r0 * math.cos(math.radians(a)), r0 * math.sin(math.radians(a))) for a in range(60, -61, -30)]
    return pts

def limb(name, x, y, angle, L1, L2, r0, r1, paw, blend=34):
    """A limb node at the joint (x, y) pointing along `angle` (radians, 0 = +x, pi/2 = down).
    Returns (node, root bone id, tip bone id)."""
    node = ET.Element("Node", x=f"{x}", y=f"{y}", rotation=f"{angle}", name=name, id=nid())
    b1, b2 = nid(), nid()
    rb = el("RootBone", node, x=0, y=0, length=L1, rotation=0, name=f"{name}_1", id=b1)
    tip = el("Bone", rb, length=L2, rotation=0, name=f"{name}_2", id=b2)
    # paw rides on the tip bone (rigid), drawn on top of the tube
    pawn = el("Node", tip, x=L2, y=0, rotation=-angle, name=f"{name}_paw", id=nid())
    paw(pawn)
    PAW_IDS[name] = pawn.get("id"); PAW_IDS_NODE[name] = pawn
    shape = el("Shape", node, name=f"{name}_tube", id=nid())
    path = el("PointsPath", shape, isClosed="true", name="Path", id=nid())
    for px, py in tube_points(L1, L2, r0, r1):
        f = smooth(L1 - blend, L1 + blend, max(0, min(L1 + L2, px)))
        vf = round(255 * f)
        v = el("StraightVertex", path, x=round(px, 2), y=round(py, 2))
        el("Weight", v, values=(255 - vf) | (vf << 8), indices=1 | (2 << 8))
    skin = el("Skin", path, tx=0, ty=0, name="Skin")
    el("Tendon", skin, boneId=b1, tx=0, ty=0, name="Upper")
    el("Tendon", skin, boneId=b2, tx=L1, ty=0, name="Lower")
    solid(shape, "Fill", FUR)
    solid(shape, "Stroke", INK, thickness=9, cap="round", join="round")
    # draw order inside the limb node: paw (on bone) first, then tube
    node.remove(shape); node.insert(0, shape); node.remove(rb); node.insert(0, rb)
    return node, b1, b2

PAW_IDS = {}
PAW_IDS_NODE = {}

def ellipse(parent, x, y, w, h, color, stroke=None, rot=0):
    s = el("Shape", parent, x=x, y=y, rotation=rot, name="Ellipse", id=nid())
    el("Ellipse", s, width=w, height=h, name="Path", id=nid())
    solid(s, "Fill", color)
    if stroke:
        solid(s, "Stroke", INK, thickness=stroke)
    return s

def fresh(e):
    """a copy of borrowed art with new ids (the same art is used twice)"""
    e = copy.deepcopy(e)
    for x in e.iter():
        if x.get("id"): x.set("id", nid())
    return e

def art(n, ids, dx=0, dy=0):
    for i in ids:              # first id draws on top
        g = fresh(BY_ID[i]); g.set("x", f"{dx}"); g.set("y", f"{dy}")
        n.append(g)

def hand(n):      # the artist's round paw, sized to the arm so it reads as the arm's end
    # along the arm: the paw art points down, the bone's +x is "down the arm"
    n.set("rotation", f"{-math.pi / 2}"); n.set("x", f"{float(n.get('x')) - 8}"); n.set("scaleX", "0.82"); n.set("scaleY", "0.82")
    art(n, ["1:59", "1:78"], 0, 0)

def foot(n):      # the top of the artist's foot (no sole pads: the viewer never sees the sole)
    art(n, ["1:673", "1:710"], 0, 6)

# ---- assemble -------------------------------------------------------------------
import random
PIV = (166, 300)                    # body pivot (belly centre) in root space
LIMBS = {   # name: joint x, y, rest angle, L1, L2, r0, r1, paw
    "armL": (82, 140, 1.5707964 + 0.12, 82, 78, 30, 27, "hand"),
    "armR": (250, 140, 1.5707964 - 0.12, 82, 78, 30, 27, "hand"),
    "legL": (112, 262, 1.5707964 + 0.05, 58, 52, 37, 34, "foot"),
    "legR": (220, 262, 1.5707964 - 0.05, 58, 52, 37, 34, "foot"),
}
W, H, WX, WY = 1900, 1150, 540, 680  # artboard size and where root (0,0) sits
GROUND = 418                        # root-space y of the floor (feet rest here)
X0 = -320                           # where the panda stands when a scene starts/ends (dx)
STALK_X = (-122 + X0, 454 + X0)     # the two bamboo stalks
LOW, TOP = 330, 520                 # stalk pieces: the part that stays, the part that breaks off
SEGS = 4                            # the broken-off part shatters into this many segments
TOFU = (590, 92, 200, 160)          # tofu centre x, y, width, height (root space)
CREAM, CREAM_TOP = "FFFFF8E7", "FFFFFFFF"
G = 0.85                            # gravity, px per frame^2 (60 fps)

BAMBOO_LEN = 300                    # the art's stalk runs x -150..150; leaves at both ends
LEAF_TOP, LEAF_BOTTOM = "1:152", "1:158"

def bamboo_piece(name, x, y, length, src="1:149", drop=(), thick=1.7, rot=-math.pi / 2):
    """the artist's bamboo turned upright (+x end up); (x, y) is the piece's centre"""
    g = copy.deepcopy(BY_ID[src])
    for parent in list(g.iter()):
        for c in list(parent):
            if c.get("id") in drop:
                parent.remove(c)
    g = fresh(g)
    g.attrib.update(x=f"{x}", y=f"{y}", rotation=f"{rot}", scaleX=f"{length / BAMBOO_LEN}", scaleY=f"{thick}", name=name)
    return g

def rect(parent, x, y, w, h, color, name, stroke=7, radius=10, rot=0, opacity=1):
    s = el("Shape", parent, x=x, y=y, rotation=rot, opacity=opacity, name=name, id=nid())
    el("Rectangle", s, width=w, height=h, cornerRadiusTL=radius, name="Path", id=nid())
    solid(s, "Fill", color)
    if stroke:
        solid(s, "Stroke", INK, thickness=stroke, join="round")
    return s

def star(parent, x, y, name):
    s = el("Shape", parent, x=x, y=y, scaleX=0, scaleY=0, name=name, id=nid())
    el("Star", s, width=120, height=120, points=8, innerRadius=0.45, name="Path", id=nid())
    solid(s, "Fill", "FFFFD54A")
    solid(s, "Stroke", INK, thickness=7, join="round")
    return s

def tofu(parent, x, y, w, h, name):
    """a soft tofu block: cream body, a lighter top face, navy outline"""
    n = el("Node", parent, x=x, y=y, name=name, id=nid())
    rect(n, 0, -h / 2 + 16, w - 18, 14, CREAM_TOP, "top", stroke=0, radius=7)
    rect(n, 0, 0, w, h, CREAM, "block", stroke=9, radius=18)
    return n

def stand(parent, x, top_y):
    """a bamboo stand: a plank on two bamboo legs, from the floor up to top_y"""
    n = el("Node", parent, name="stand", id=nid())
    h = GROUND - top_y
    n.append(bamboo_piece("plank", x, top_y + 10, 270, drop=(LEAF_TOP, LEAF_BOTTOM), thick=1.4, rot=0))
    for dx in (-100, 100):
        n.append(bamboo_piece("leg", x + dx, top_y + h / 2 + 10, h - 10, drop=(LEAF_TOP, LEAF_BOTTOM), thick=1.3))
    return n

# --- fragments: each one has a rest place (assembled), a launch, and flies ballistically ---
class Frag:
    def __init__(self, node, x, y, rot, vx, vy, spin, floor):
        self.id = node.get("id"); self.x, self.y, self.rot = x, y, rot
        self.vx, self.vy, self.spin, self.floor = vx, vy, spin, floor
    def at(self, t):
        """position after t frames of flight; settles on the floor"""
        x, y, r = self.x + self.vx * t, self.y + self.vy * t + 0.5 * G * t * t, self.rot + self.spin * t
        if y > self.floor:   # landed: slide a little, then rest
            # time of landing
            a, b, c = 0.5 * G, self.vy, self.y - self.floor
            tl = (-b + math.sqrt(max(0, b * b - 4 * a * c))) / (2 * a)
            x = self.x + self.vx * tl + self.vx * 0.15 * min(8, t - tl)
            y = self.floor
            r = self.rot + self.spin * tl
        return x, y, r

def build(order, background=None):
    rive = ET.Element("Rive", version="1", kind="fragment")
    ab = el("Artboard", rive, defaultStateMachineId="2:7", styleId="2:5", width=W, height=H, name="Kungfu Panda", id="2:2")
    el("LayoutComponentStyle", ab, name="Artboard Style", id="2:5")
    if background:
        solid(ab, "Fill", background)
    world = el("Node", ab, x=WX, y=WY, name="world", id="2:10")
    ids = {"body": "2:11"}
    rnd = random.Random(7)
    fx = el("Node", world, name="fx", id=nid())                  # fragments and flashes, in front
    # bamboo scene: two stalks; the top part is whole until the hit, then shatters
    bamboo = {"frags": [], "tops": [], "stumps": [], "stars": []}
    for side, sx in zip("LR", STALK_X):
        out = -1 if side == "L" else 1
        bamboo["stars"].append(star(fx, sx, GROUND - LOW - 28, "hit" + side).get("id"))
        seg = TOP / SEGS
        for k in range(SEGS):
            cy = GROUND - LOW - seg * (k + 0.5)
            piece = bamboo_piece(f"seg{side}{k}", sx, cy, seg, drop=(LEAF_BOTTOM,) + (() if k == SEGS - 1 else (LEAF_TOP,)))
            piece.set("opacity", "0"); fx.append(piece)
            up = (k + 1) / SEGS
            bamboo["frags"].append(Frag(piece, sx, cy, -math.pi / 2, out * rnd.uniform(4, 9) * (0.6 + up),
                                        -rnd.uniform(4, 10) * (1.2 - up * 0.5), out * rnd.uniform(0.05, 0.16), GROUND - 14))
        for k in range(6):                                          # splinters
            sl = rect(fx, sx, GROUND - LOW - 6, rnd.uniform(26, 46), 9, "FF7BC95F", f"splinter{side}{k}", stroke=4, radius=4, opacity=0)
            bamboo["frags"].append(Frag(sl, sx, GROUND - LOW - 6, rnd.uniform(0, 3), rnd.uniform(-7, 7) + out * 3,
                                        -rnd.uniform(6, 14), rnd.uniform(-0.4, 0.4), GROUND - 6))
    cookie = cookie_props(fx, rnd)
    # the panda
    body = el("Node", world, x=PIV[0], y=PIV[1], name="body", id="2:11")
    inner = el("Node", body, x=-PIV[0], y=-PIV[1], name="inner", id="2:13")
    parts = {}
    for name, (x, y, a, L1, L2, r0, r1, paw) in LIMBS.items():
        node, b1, b2 = limb(name, x, y, a, L1, L2, r0, r1, hand if paw == "hand" else foot)
        parts[name] = node; ids[name + "1"] = b1; ids[name + "2"] = b2
    ids["head"] = HEAD
    cookie["inhand"] = hand_cookie(PAW_IDS_NODE["armR"])
    for c in (parts["armL"], parts["armR"], face_head(), borrowed("1:728"),
              parts["legL"], parts["legR"], borrowed("1:740")):        # front -> back
        inner.append(c)
    inner.append(borrowed("1:751", x="-209.11639", y="-340.1178"))        # belly clip (invisible)
    # props behind the panda
    props = el("Node", world, name="props", id=nid())
    for side, sx in zip("LR", STALK_X):
        top = bamboo_piece("top" + side, sx, GROUND - LOW - TOP / 2, TOP, drop=(LEAF_BOTTOM,))
        props.append(top); bamboo["tops"].append(top.get("id"))
        stump = bamboo_piece("stalk" + side, sx, GROUND - LOW / 2, LOW, drop=(LEAF_TOP,))
        props.append(stump); bamboo["stumps"].append(stump.get("id"))
    cookie_stage(props, cookie)
    world.append(borrowed("1:748", name="shadow", id="2:14"))
    ids["shadow"] = "2:14"
    ids["bamboo"], ids["cookie"] = bamboo, cookie
    # state machine: the scenes play one after another
    sm = el("StateMachine", ab, name="State Machine 1", id="2:7")
    lay = el("StateMachineLayer", sm, name="Layer 1", id="2:8")
    el("AnyState", lay, x=200, y=-120); el("ExitState", lay, x=400, y=-120)
    anims = {"bamboo": ("2:6", "2:12", bamboo_scene), "cookie": ("2:16", "2:17", cookie_scene)}
    ent = el("EntryState", lay); el("StateTransition", ent, stateToId=anims[order[0]][1])
    for i, name in enumerate(order):
        aid, sid, fn = anims[name]
        stt = el("AnimationState", lay, x=200 + 220 * i, y=100, animationId=aid, id=sid)
        if len(order) > 1:
            nxt = anims[order[(i + 1) % len(order)]][1]
            el("StateTransition", stt, stateToId=nxt, enableExitTime="true", exitTime=100, exitTimeIsPercetange="true")
    for name in order:
        aid, sid, fn = anims[name]
        fn(ab, ids, aid)
    ET.indent(rive)
    return ET.tostring(rive, encoding="unicode")

# ---- animation --------------------------------------------------------------------
RAD = math.pi / 180
CAMERA = None                         # artboard x the panda is kept at (None = fixed view)
EASE = {"io": (0.42, 0, 0.58, 1), "out": (0.15, 0.6, 0.3, 1), "in": (0.55, 0, 0.85, 0.4),
        "back": (0.3, 1.5, 0.5, 1), "lin": None, "hold": "hold"}

REST = dict(armL1=0, armL2=0, armR1=0, armR2=0, legL1=0, legL2=0, legR1=0, legR2=0,
            dx=0, dy=0, rot=0, sx=100, sy=100, head=0, lenL=58, lenR=58, lenAL=82, lenAR=82, hit=0, eyes="open", mouth="grin", hy=0)
def P(base=REST, **k):
    p = dict(base); p.update(k); return p

def keyframes(obj, prop, frames):
    ko = ET.Element("KeyedObject", objectId=obj)
    kp = el("KeyedProperty", ko, propertyKey=prop)
    for f, v, e in frames:
        e = EASE[e]
        if e is None:
            el("KeyFrameDouble", kp, value=round(v, 5), frame=f, interpolationType="linear")
        elif e == "hold":
            el("KeyFrameDouble", kp, value=round(v, 5), frame=f, interpolationType="hold")
        else:
            k = el("KeyFrameDouble", kp, value=round(v, 5), frame=f, interpolationType="cubic")
            el("CubicEaseInterpolator", k, x1=e[0], y1=e[1], x2=e[2], y2=e[3])
    return ko

def panda_tracks(la, ids, KEYS):
    track = lambda fn: [(f, fn(p), e) for f, p, e in KEYS]
    for j in ("armL1", "armL2", "armR1", "armR2", "legL1", "legL2", "legR1", "legR2"):
        la.append(keyframes(ids[j], 15, track(lambda p, j=j: p[j] * RAD)))
    la.append(keyframes(ids["legL1"], 89, track(lambda p: p["lenL"])))   # rubber-hose stretch
    la.append(keyframes(ids["legR1"], 89, track(lambda p: p["lenR"])))
    la.append(keyframes(ids["armL1"], 89, track(lambda p: p["lenAL"])))
    la.append(keyframes(ids["armR1"], 89, track(lambda p: p["lenAR"])))
    la.append(keyframes(ids["body"], 13, track(lambda p: PIV[0] + p["dx"])))
    la.append(keyframes(ids["body"], 14, track(lambda p: PIV[1] + p["dy"])))
    la.append(keyframes(ids["body"], 15, track(lambda p: p["rot"] * RAD)))
    la.append(keyframes(ids["body"], 16, track(lambda p: p["sx"] / 100)))
    la.append(keyframes(ids["body"], 17, track(lambda p: p["sy"] / 100)))
    la.append(keyframes(ids["head"], 15, track(lambda p: p["head"] * RAD)))
    la.append(keyframes(ids["head"], 14, track(lambda p: -101.2798 + p["hy"])))
    for leg in ("legL", "legR"):        # feet keep pointing at the floor, whatever the leg and body do
        rest = LIMBS[leg][2]
        la.append(keyframes(PAW_IDS[leg], 15, track(lambda p, leg=leg, rest=rest: -(rest + (p[leg + "1"] + p[leg + "2"] + p["rot"]) * RAD))))
    for kind in ("open", "shut", "happy"):
        la.append(keyframes(FACE["eyes_" + kind], 18, [(f, 1 if p["eyes"] == kind else 0, "hold") for f, p, e in KEYS]))
    for kind in ("grin", "open"):
        la.append(keyframes(FACE["mouth_" + kind], 18, [(f, 1 if p["mouth"] == kind else 0, "hold") for f, p, e in KEYS]))
    if CAMERA is not None:            # the view follows the panda sideways (props scroll by)
        la.append(keyframes("2:10", 13, track(lambda p: CAMERA - (PIV[0] + p["dx"]))))
    la.append(keyframes(ids["shadow"], 13, track(lambda p: 165.88 + p["dx"])))
    la.append(keyframes(ids["shadow"], 16, track(lambda p: max(0.5, 1 + p["dy"] / 400))))

def frag_tracks(la, frags, hit, end, step=3):
    """fragments: hidden until the hit, then fly; fade out before the scene ends"""
    for fr in frags:
        flight = list(range(hit, end - 10, step))
        la.append(keyframes(fr.id, 18, [(0, 0, "hold"), (hit, 1, "hold"), (end - 24, 1, "lin"), (end - 10, 0, "hold")]))
        for prop, k in ((13, 0), (14, 1), (15, 2)):
            pts = [(0, (fr.x, fr.y, fr.rot)[k], "hold")] + [(f, fr.at(f - hit)[k], "lin") for f in flight]
            la.append(keyframes(fr.id, prop, pts))

def show(la, obj, frames):   # opacity, held
    la.append(keyframes(obj, 18, [(f, v, "hold") for f, v in frames]))

# --- scene 1: splits through two bamboo stalks ---
GUARD  = P(armL1=-25, armR1=25, armL2=-95, armR2=95, head=2)
CROUCH = P(dy=36, sx=107, sy=92, armL1=-15, armR1=15, armL2=-105, armR2=105, legL1=10, legR1=-10, legL2=-22, legR2=22, head=-4)
RISE   = P(lenL=70, lenR=70, dy=-200, sx=95, sy=106, armL1=30, armR1=-30, armL2=-40, armR2=40, legL1=45, legR1=-45, legL2=-50, legR2=50)
SPLIT  = P(lenL=150, lenR=150, dy=-204, armL1=95, armR1=-95, armL2=-25, armR2=25, legL1=86, legR1=-86, legL2=2, legR2=-2, head=-2, hit=1)
FOLLOW = P(lenL=154, lenR=154, dy=-214, armL1=105, armR1=-105, armL2=-15, armR2=15, legL1=90, legR1=-90, legL2=4, legR2=-4, head=4, hit=1.25)
HANG   = P(lenL=146, lenR=146, dy=-206, armL1=100, armR1=-100, armL2=-20, armR2=20, legL1=84, legR1=-84, legL2=2, legR2=-2, head=3)
FALL   = P(lenL=66, lenR=66, dy=-30, sx=96, sy=105, armL1=40, armR1=-40, armL2=-20, armR2=20, legL1=18, legR1=-18, legL2=-12, legR2=12)
LAND   = P(dy=44, sx=110, sy=90, armL1=10, armR1=-10, legL1=14, legR1=-14, legL2=-28, legR2=28, head=-4)
PROUD  = P(dy=-6, sx=98, sy=103, armL1=-12, armR1=12, armL2=-70, armR2=70, head=3)
BAMBOO_KEYS = [
    (0, GUARD, "io"), (30, GUARD, "io"), (44, CROUCH, "out"), (54, RISE, "out"), (60, SPLIT, "out"),
    (66, FOLLOW, "io"), (80, HANG, "in"), (94, FALL, "in"), (100, LAND, "back"), (116, REST, "io"),
    (130, PROUD, "io"), (175, PROUD, "io"), (195, REST, "io"), (215, GUARD, "hold"),
]
BAMBOO_HIT = 60
BAMBOO_KEYS = [(f, P(p, dx=p["dx"] + X0), e) for f, p, e in BAMBOO_KEYS]   # the scene happens at X0

def bamboo_scene(ab, ids, aid):
    end = BAMBOO_KEYS[-1][0]
    la = el("LinearAnimation", ab, duration=end, fps=60, loopValue="loop", name="Bamboo splits", id=aid)
    panda_tracks(la, ids, BAMBOO_KEYS)
    b, c = ids["bamboo"], ids["cookie"]
    for o in c["hide"]:
        show(la, o, [(0, 0)])
    for o in b["stumps"]:
        show(la, o, [(0, 1)])
    for o in b["tops"]:      # whole until the hit; a new one grows back at the end
        show(la, o, [(0, 1), (BAMBOO_HIT, 0), (end - 22, 1)])
        la.append(keyframes(o, 16, [(0, LOW and TOP / BAMBOO_LEN, "hold"), (end - 22, 0, "back"), (end - 4, TOP / BAMBOO_LEN, "hold")]))
    for o in b["stars"]:
        la.append(keyframes(o, 16, [(0, 0, "hold"), (BAMBOO_HIT - 2, 0, "out"), (BAMBOO_HIT + 4, 1.3, "in"), (BAMBOO_HIT + 14, 0, "hold")]))
        la.append(keyframes(o, 17, [(0, 0, "hold"), (BAMBOO_HIT - 2, 0, "out"), (BAMBOO_HIT + 4, 1.3, "in"), (BAMBOO_HIT + 14, 0, "hold")]))
    frag_tracks(la, b["frags"], BAMBOO_HIT, end)

# --- scene 2: parkour up two bamboo platforms, flying kick to a cookie, catch it, eat it ---
# (pasted into gen_panda.py at @@COOKIE@@; uses its helpers)
from shapely.geometry import Point

CK_R = 60                                   # cookie radius
CK_DOUGH, CK_CHIP = "FFE0A458", "FF6B3A1E"
CHIPS = [(-22, -18), (14, -26), (26, 6), (-6, 4), (-28, 20), (8, 28), (-14, -36), (34, -12)]
BITES = [[(-16, 54)], [(-16, 54), (24, 50)], [(-16, 54), (24, 50), (2, 22)]]   # bite centres per stage (+y = toward the mouth)
BITE_R = 30

def cookie_polys():
    base = Point(0, 0).buffer(CK_R, 32)
    polys = [base]
    for bites in BITES:
        p = base
        for bx, by in bites:
            p = p.difference(Point(bx, by).buffer(BITE_R, 24))
        polys.append(p)
    return polys

def cookie_shape(parent, poly, name, opacity=1.0):
    """one stage of the cookie: dough with a navy outline, and the chips still left"""
    n = el("Node", parent, opacity=opacity, name=name, id=nid())
    inside = poly.buffer(-7)
    for cx, cy in CHIPS:                     # chips first: drawn on top of the dough
        if inside.contains(Point(cx, cy)):
            ellipse(n, cx, cy, 11, 9, CK_CHIP)
    s = el("Shape", n, name="dough", id=nid())
    path = el("PointsPath", s, isClosed="true", name="Path", id=nid())
    geom = max(getattr(poly, "geoms", [poly]), key=lambda g: g.area)
    for x, y in list(geom.exterior.coords)[:-1]:
        el("StraightVertex", path, x=round(x, 2), y=round(y, 2))
    solid(s, "Fill", CK_DOUGH)
    solid(s, "Stroke", INK, thickness=7, join="round")
    return n

def hand_cookie(paw):
    """the cookie as held in the right paw: one node per bite stage, all hidden at first"""
    # paw space: rotated so +y runs down the arm, scaled 0.82 -> undo the scale
    n = el("Node", paw, x=0, y=55, scaleX=1 / 0.82, scaleY=1 / 0.82, name="cookie_in_paw", id=nid())
    paw.remove(n); paw.insert(0, n)           # in front of the paw
    return [cookie_shape(n, p, f"stage{i}", opacity=0).get("id") for i, p in enumerate(cookie_polys())]

def cookie_props(fx, rnd):
    c = {"hide": [], "crumbs": []}
    c["place"] = cookie_place()
    c["pole"] = (c["place"][0], c["place"][1] + CK_R)
    c["fly"] = cookie_shape(fx, cookie_polys()[0], "cookie").get("id")
    c["star"] = star(fx, 0, 0, "hitCookie").get("id")
    for k in range(18):
        cr = rect(fx, 0, 0, rnd.uniform(9, 15), rnd.uniform(8, 12), CK_DOUGH, f"crumb{k}", stroke=3, radius=3, opacity=0)
        c["crumbs"].append(cr.get("id"))
    c["hide"] += [c["fly"], c["star"]] + c["crumbs"]
    return c

def platform(parent, x, top_y, w, name):
    n = el("Node", parent, name=name, id=nid())
    h = GROUND - top_y
    n.append(bamboo_piece("plank", x, top_y + 10, w, drop=(LEAF_TOP, LEAF_BOTTOM), thick=1.4, rot=0))
    for dx in (-w / 2 + 30, w / 2 - 30):
        n.append(bamboo_piece("leg", x + dx, top_y + h / 2 + 10, h - 10, drop=(LEAF_TOP, LEAF_BOTTOM), thick=1.3))
    return n

# platforms: (centre x, top y, width) in root space; the pole carries the cookie
PLAT1 = (180, GROUND - 160, 230)
PLAT2 = (520, GROUND - 320, 230)

def cookie_stage(props, c):
    for i, (x, ty, w) in enumerate((PLAT1, PLAT2)):
        c["hide"].append(platform(props, x, ty, w, f"platform{i + 1}").get("id"))
    px, py = c["pole"]
    pole = el("Node", props, name="pole", id=nid())
    pole.append(bamboo_piece("pole", px, (GROUND + py) / 2 + 6, GROUND - py, drop=(LEAF_TOP,), thick=1.5))
    pole.append(bamboo_piece("cap", px, py + 8, 90, drop=(LEAF_TOP, LEAF_BOTTOM), thick=1.3, rot=0))
    c["hide"].append(pole.get("id"))
    c["hide"] += c["inhand"]

# ---- kinematics: where a paw/foot is in root space for a pose ----
def body_to_root(p, q):
    """inner-space point q -> root space, through the body's move/tilt/squash about its pivot"""
    x, y = q[0] - PIV[0], q[1] - PIV[1]
    x, y = x * p["sx"] / 100, y * p["sy"] / 100
    r = p["rot"] * RAD
    x, y = x * math.cos(r) - y * math.sin(r), x * math.sin(r) + y * math.cos(r)
    return PIV[0] + p["dx"] + x, PIV[1] + p["dy"] + y

def tip(p, name, extra=0):
    """inner-space tip of a limb (+ `extra` further along the last bone) and that bone's direction"""
    x, y, a, L1, L2 = LIMBS[name][:5]
    if name == "legL": L1 = p["lenL"]
    if name == "legR": L1 = p["lenR"]
    if name == "armL": L1 = p["lenAL"]
    if name == "armR": L1 = p["lenAR"]
    d1 = a + p[name + "1"] * RAD; d2 = d1 + p[name + "2"] * RAD
    ex, ey = x + L1 * math.cos(d1), y + L1 * math.sin(d1)
    return (ex + (L2 + extra) * math.cos(d2), ey + (L2 + extra) * math.sin(d2)), d2

def ik(name, target, elbow_out=1):
    """joint angles (degrees, relative to rest) that put the limb tip on an inner-space target"""
    x, y, a, L1, L2 = LIMBS[name][:5]
    dx, dy = target[0] - x, target[1] - y
    d = min(L1 + L2 - 1, max(abs(L1 - L2) + 1, math.hypot(dx, dy)))
    th = math.atan2(dy, dx)
    beta = math.acos((L1 * L1 + d * d - L2 * L2) / (2 * L1 * d))
    d1 = th + elbow_out * beta
    ex, ey = x + L1 * math.cos(d1), y + L1 * math.sin(d1)
    d2 = math.atan2(target[1] - ey, target[0] - ex)
    norm = lambda v: (v + math.pi) % (2 * math.pi) - math.pi
    return norm(d1 - a) / RAD, norm(d2 - d1) / RAD

HELD = 45                                   # cookie centre sits this far past the right arm's tip
MOUTH = (163, 52)                           # inner space, just under the grin

def hold_cookie_at(pose, target):
    """pose with the right arm placing the held cookie's centre on an inner-space target"""
    sx, sy = LIMBS["armR"][:2]
    d = math.hypot(target[0] - sx, target[1] - sy)
    u = ((target[0] - sx) / d, (target[1] - sy) / d)
    r1, r2 = ik("armR", (target[0] - u[0] * HELD, target[1] - u[1] * HELD), elbow_out=1)   # elbow out to the side
    p = dict(pose); p["armR1"], p["armR2"] = r1, r2
    return p

# ---- poses ----
def on(plat):   # body offset that stands the panda on a platform (or the floor)
    return plat[1] - GROUND

C_GUARD  = P(GUARD, dx=X0)
C_CROUCH = P(CROUCH, dx=X0)
HOP_UP   = P(lenL=66, lenR=66, sx=95, sy=106, armL1=40, armR1=-40, armL2=-60, armR2=60, legL1=30, legR1=-30, legL2=-60, legR2=60, head=-3)
LAND_SQ  = P(sx=110, sy=90, armL1=15, armR1=-15, legL1=14, legR1=-14, legL2=-28, legR2=28, head=-4)
p1x, p2x = PLAT1[0] - PIV[0], PLAT2[0] - PIV[0]
C_HOP1   = P(HOP_UP, dx=(X0 + p1x) / 2, dy=on(PLAT1) - 150)
C_LAND1  = P(LAND_SQ, dx=p1x, dy=on(PLAT1) + 30)
C_ON1    = P(GUARD, dx=p1x, dy=on(PLAT1))
C_CR1    = P(CROUCH, dx=p1x, dy=on(PLAT1) + 30)
C_HOP2   = P(HOP_UP, dx=(p1x + p2x) / 2, dy=on(PLAT2) - 150)
C_LAND2  = P(LAND_SQ, dx=p2x, dy=on(PLAT2) + 30)
C_ON2    = P(GUARD, dx=p2x, dy=on(PLAT2))
C_CR2    = P(CROUCH, dx=p2x, dy=on(PLAT2) + 30)
C_LEAP   = P(dx=p2x + 120, dy=on(PLAT2) - 110, rot=-8, lenR=70, armL1=40, armR1=-135, armL2=-80, armR2=-35,
             legL1=55, legL2=-120, legR1=-40, legR2=60, head=-4)
C_KICK   = P(dx=p2x + 230, dy=on(PLAT2) - 40, rot=-14, lenR=168, armL1=75, armR1=-135, armL2=-30, armR2=-35,
             legL1=60, legL2=-125, legR1=-98, legR2=-2, head=-6, hit=1)
C_THRU   = P(C_KICK, dx=p2x + 270, dy=on(PLAT2) - 10, rot=-18, lenR=172, legR1=-102, head=-8, hit=1.25)
LANDX    = p2x + 170
C_DROP   = P(dx=LANDX, dy=-90, armL1=40, armR1=-40, armL2=-20, armR2=20, legL1=20, legR1=-25, legL2=-20, legR2=10)
C_LAND   = P(LAND, dx=LANDX)
C_LOOK   = P(dx=LANDX, head=-8, armL1=-10, armR1=-160, armR2=-10, sy=103)          # looks up, paw up
C_CATCH  = P(dx=LANDX, dy=14, sx=104, sy=95, head=-4, armL1=-10, armR1=-150, armR2=-25)
# eating: the right elbow sticks out to the side, the forearm folds back so the cookie is at the mouth;
# the left paw rests on the hip with its elbow out too
def EAT(r2, head, sy=100, hip=(42, -8)):
    return P(dx=LANDX, head=head, sy=sy, armR1=-92, armR2=r2, lenAR=118, armL1=hip[0], armL2=hip[1], lenAL=96)
C_SNIFF  = EAT(-120, 6)
C_BITE   = EAT(-150, -5, sy=98)
C_CHEW_A = EAT(-135, 4, sy=102)
C_CHEW_B = EAT(-128, -2, sy=99)
C_HAPPY  = P(dx=LANDX, dy=-8, head=6, sx=98, sy=104, armL1=-30, armR1=30, armL2=-90, armR2=90)   # paws on the belly
C_BACK1  = P(GUARD, dx=(LANDX + X0) * 0.66 + 20, dy=-130)
C_MID    = P(LAND_SQ, dx=(LANDX + X0) / 2, dy=20)
C_BACK2  = P(GUARD, dx=(LANDX + X0) * 0.33 - 40, dy=-130)

COOKIE_KEYS = [
    (0, C_GUARD, "io"), (20, C_GUARD, "io"), (30, C_CROUCH, "out"),
    (42, C_HOP1, "in"), (52, C_LAND1, "back"), (60, C_ON1, "io"), (68, C_CR1, "out"),
    (80, C_HOP2, "in"), (90, C_LAND2, "back"), (98, C_ON2, "io"), (106, C_CR2, "out"),
    (118, C_LEAP, "out"), (126, C_KICK, "out"), (132, C_THRU, "in"), (150, C_DROP, "in"), (156, C_LAND, "back"),
    (170, C_LOOK, "io"), (184, C_LOOK, "out"), (190, C_CATCH, "back"), (204, C_SNIFF, "io"),
    (218, C_BITE, "out"), (226, C_CHEW_A, "io"), (234, C_CHEW_B, "io"), (242, C_CHEW_A, "io"),
    (252, C_BITE, "out"), (260, C_CHEW_A, "io"), (268, C_CHEW_B, "io"), (276, C_CHEW_A, "io"),
    (286, C_BITE, "out"), (294, C_CHEW_A, "io"), (302, C_CHEW_B, "io"), (310, C_CHEW_A, "io"),
    (320, C_BITE, "out"), (330, C_CHEW_B, "io"), (346, C_HAPPY, "io"), (380, C_HAPPY, "io"),
    (394, P(GUARD, dx=LANDX), "out"), (408, C_BACK1, "in"), (420, C_MID, "out"), (432, C_BACK2, "in"),
    (446, P(LAND_SQ, dx=X0), "back"), (462, C_GUARD, "hold"),
]
CK_HIT, CK_CATCH = 126, 190
CK_BITES = [218, 252, 286, 320]              # stage 1, 2, 3, then gone

def cookie_place():
    """where the cookie sits: just past the kicking foot at the hit"""
    (fx_, fy_), _ = tip(C_KICK, "legR", 30)
    x, y = body_to_root(C_KICK, (fx_, fy_))
    return x + CK_R - 10, y - 6

def held_root(p):
    (x, y), _ = tip(p, "armR", HELD)
    return body_to_root(p, (x, y))

def cookie_scene(ab, ids, aid):
    end = COOKIE_KEYS[-1][0]
    la = el("LinearAnimation", ab, duration=end, fps=60, loopValue="loop", name="Cookie", id=aid)
    panda_tracks(la, ids, COOKIE_KEYS)
    b, c = ids["bamboo"], ids["cookie"]
    for o in b["stumps"] + b["tops"] + b["stars"] + [f.id for f in b["frags"]]:
        show(la, o, [(0, 0)])
    for o in c["hide"]:
        if o not in c["inhand"] and o not in c["crumbs"] and o not in (c["fly"], c["star"]):
            show(la, o, [(0, 1)])            # platforms and pole
    # the flying cookie: on the pole, kicked up in an arc, lands in the raised paw
    x0, y0 = c["place"]
    x1, y1 = held_root(C_CATCH)
    T = CK_CATCH - CK_HIT
    vx, vy = (x1 - x0) / T, (y1 - y0 - 0.5 * G * T * T) / T
    fl = [(0, x0, y0, 0, "hold"), (CK_HIT, x0, y0, 0, "lin")]
    for f in range(CK_HIT + 2, CK_CATCH + 1, 2):
        t = f - CK_HIT
        fl.append((f, x0 + vx * t, y0 + vy * t + 0.5 * G * t * t, -0.21 * t, "lin"))
    fl.append((end - 26, x0, y0, 0, "hold"))
    for prop, k in ((13, 1), (14, 2), (15, 3)):
        la.append(keyframes(c["fly"], prop, [(r[0], r[k], r[4]) for r in fl]))
    show(la, c["fly"], [(0, 1), (CK_CATCH, 0), (end - 26, 1)])
    for prop in (16, 17):                    # a fresh cookie pops back onto the pole
        la.append(keyframes(c["fly"], prop, [(0, 1, "hold"), (end - 26, 0, "back"), (end - 12, 1, "hold")]))
        la.append(keyframes(c["star"], prop, [(0, 0, "hold"), (CK_HIT - 2, 0, "out"), (CK_HIT + 4, 1.3, "in"), (CK_HIT + 14, 0, "hold")]))
    la.append(keyframes(c["star"], 13, [(0, x0 - CK_R, "hold")]))
    la.append(keyframes(c["star"], 14, [(0, y0, "hold")]))
    # in the paw: whole, then three bites, then gone
    stages = c["inhand"]
    marks = [CK_CATCH] + CK_BITES
    for i, sid in enumerate(stages):
        show(la, sid, [(0, 0), (marks[i], 1), (marks[i + 1], 0)])
    # crumbs fall from the mouth at every bite
    rnd = random.Random(11)
    for k, cid in enumerate(c["crumbs"]):
        bite = CK_BITES[k % len(CK_BITES)]
        pose = {f: p for f, p, e in COOKIE_KEYS}[bite]
        mx, my = body_to_root(pose, (MOUTH[0] + rnd.uniform(-10, 30), MOUTH[1] + 30))
        fr = Frag(el("Node", None, id=cid), mx, my, 0, rnd.uniform(-2.5, 3.5), -rnd.uniform(1, 4), rnd.uniform(-0.3, 0.3), GROUND - 6)
        show(la, cid, [(0, 0), (bite, 1), (bite + 60, 0)])
        pts = [(0, fr.x, "hold")] + [(bite + t, fr.at(t)[0], "lin") for t in range(0, 61, 3)]
        la.append(keyframes(cid, 13, pts))
        la.append(keyframes(cid, 14, [(0, fr.y, "hold")] + [(bite + t, fr.at(t)[1], "lin") for t in range(0, 61, 3)]))
        la.append(keyframes(cid, 15, [(0, 0, "hold")] + [(bite + t, fr.at(t)[2], "lin") for t in range(0, 61, 3)]))

if __name__ == "__main__":
    order = sys.argv[1].split(",") if len(sys.argv) > 1 else ["bamboo", "cookie"]
    bg = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] != "-" else None
    out = sys.argv[3] if len(sys.argv) > 3 else "kpanda"
    if len(sys.argv) > 4:                 # single-scene file for the app: width, origin x, follow camera
        W, WX = int(sys.argv[4]), int(sys.argv[5])
        CAMERA = W / 2 if len(sys.argv) > 6 and sys.argv[6] == "cam" else None
    os.makedirs(out, exist_ok=True)
    if not os.path.exists(f"{out}/rive.yaml"):
        open(f"{out}/rive.yaml", "w").write(f"name: {out.replace('scene_', '')}\nlogs:\n  file: build/rive.log\n  problems: build/problems.log\n")
    open(f"{out}/scene.rml", "w").write(build(order, background=bg))
    print("ok", order)
