"""Short reactions the rail panda plays when the user pokes it (click) or points at it (hover).

python3 reactions.py giggle [FFFFFFFF]  -> scene_giggle/scene.rml   (2nd arg = preview background)

Each one starts and ends in the same relaxed pose (arms down, smiling), lasts 1-2 s, and stays
inside the usual 1000 x 1100 frame so the rail's crop needs no special case.
Root-space landmarks (measured on a marker grid): eyes (71,-50) and (261,-50), mouth (163,20),
belly (166,230), top of the head about y -310.
"""
import math, sys
from shapely.geometry import Polygon
import gen_panda as G
from gen_panda import el, solid, nid, keyframes, P, GUARD, CROUCH, LAND
from scenes2 import build, poly_shape

SMILE = P(GUARD, armL1=0, armL2=0, armR1=0, armR2=0)
HAPPY = P(SMILE, eyes="happy")
RED, YELLOW = "FFFF5C7A", "FFFFD54A"

def reach(pose, left=None, right=None, out=1, **k):
    """pose with the paws placed on root-space targets (2-bone IK)"""
    p = P(pose, **k)
    if left:
        p["armL1"], p["armL2"] = G.ik("armL", left, elbow_out=out)
    if right:
        p["armR1"], p["armR2"] = G.ik("armR", right, elbow_out=-out)
    return p

def pop(la, node, t0, t1, peak=1.15, rest=1.0):
    """scale a prop in from 0 with a small overshoot"""
    for prop in (16, 17):
        la.append(keyframes(node, prop, [(0, 0, "hold"), (t0, 0, "back"), (t0 + 10, peak, "io"), (t0 + 16, rest, "hold"), (t1, rest, "in"), (t1 + 8, 0, "hold")]))

# ---------------------------------------------------------------- click reactions
def giggle():
    """tickled: paws on the belly, shaking with laughter"""
    TICKLE = reach(HAPPY, (130, 250), (202, 250), mouth="open")
    keys = [(0, SMILE, "io"), (10, P(TICKLE, sy=96, dy=6), "out")]
    for i, f in enumerate(range(18, 90, 6)):
        s = 1 if i % 2 else -1
        keys.append((f, P(TICKLE, rot=4 * s, head=7 * s, sx=100 + 3 * s, sy=100 - 3 * s, dy=-6 if i % 2 else 2), "io"))
    keys += [(100, P(TICKLE, head=4), "io"), (118, HAPPY, "io"), (130, SMILE, "hold")]
    return build("giggle", keys)

def startle():
    """jumps out of its skin, a '!' pops over its head, then laughs it off"""
    UP = P(SMILE, armL1=135, armR1=-135, armL2=25, armR2=-25, lenAL=96, lenAR=96, mouth="open", hy=-14)
    keys = [(0, SMILE, "io"), (6, P(SMILE, sy=94, sx=104, dy=10, mouth="open"), "out"),
            (16, P(UP, dy=-150, sy=108, sx=95, legL1=18, legR1=-18, legL2=-30, legR2=30), "io"),
            (26, P(UP, dy=-165), "in"), (38, P(LAND, mouth="open"), "back"),
            (54, P(HAPPY, head=8), "io"), (76, P(HAPPY, head=-4, mouth="open"), "io"), (96, SMILE, "hold")]

    def props(world, front, back, ids):
        n = el("Node", front, x=330, y=-360, scaleX=0, scaleY=0, rotation=0.2, name="bang", id=nid())
        G.rect(n, 0, -20, 26, 80, YELLOW, "bar", stroke=7, radius=13)
        G.ellipse(n, 0, 48, 28, 28, YELLOW, stroke=7)
        return {"bang": n.get("id")}

    def extra(la, ids, pr, end):
        pop(la, pr["bang"], 12, 50, peak=1.3)
        la.append(keyframes(pr["bang"], 14, [(0, -360, "hold"), (12, -330, "out"), (26, -500, "io"), (50, -470, "hold")]))
    return build("startle", keys, props, extra)

def heart_poly(s):
    pts = []
    for k in range(48):
        t = 2 * math.pi * k / 48
        x = 16 * math.sin(t) ** 3
        y = -(13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))
        pts.append((x * s, y * s))
    return Polygon(pts)

def heart():
    """paws clasped at the chest, swaying, while a heart floats up"""
    CLASP = reach(HAPPY, (150, 150), (182, 150), mouth="grin")
    keys = [(0, SMILE, "io"), (14, P(CLASP, sy=97), "io")]
    for i, f in enumerate(range(30, 120, 22)):
        s = 1 if i % 2 else -1
        keys.append((f, P(CLASP, rot=5 * s, head=10 * s, dy=-4), "io"))
    keys += [(128, P(CLASP, mouth="open"), "io"), (146, SMILE, "hold")]

    def props(world, front, back, ids):
        n = el("Node", front, x=166, y=-380, scaleX=0, scaleY=0, name="heart", id=nid())
        poly_shape(n, heart_poly(5.2), RED, "heart")
        small = el("Node", front, x=360, y=-300, scaleX=0, scaleY=0, name="heart2", id=nid())
        poly_shape(small, heart_poly(2.8), RED, "heart2")
        return {"h": n.get("id"), "h2": small.get("id")}

    def extra(la, ids, pr, end):
        pop(la, pr["h"], 16, 120, peak=1.25)
        la.append(keyframes(pr["h"], 14, [(0, -380, "hold"), (16, -380, "io"), (120, -470, "hold")]))
        pop(la, pr["h2"], 46, 120, peak=1.2)
        la.append(keyframes(pr["h2"], 14, [(0, -300, "hold"), (46, -300, "io"), (120, -420, "hold")]))
    return build("heart", keys, props, extra)

def sneeze():
    """ah... ah... ahh-CHOO! then rubs its nose"""
    def ah(n):
        return P(SMILE, hy=-10 - 4 * n, head=-4 - 2 * n, sy=101 + n, eyes="shut", mouth="open", rot=-2 - n)
    CHOO = P(SMILE, hy=14, head=6, sy=92, sx=106, dy=10, rot=7, eyes="shut", mouth="open", armL1=25, armR1=-25, armL2=-20, armR2=20)
    RUB = reach(P(SMILE, eyes="happy", head=-4), right=(175, -12), lenAR=96)
    keys = [(0, SMILE, "io"), (12, ah(0), "io"), (20, P(SMILE, eyes="shut"), "io"), (32, ah(1), "io"), (40, P(SMILE, eyes="shut", hy=-4), "io"),
            (54, ah(2), "in"), (60, CHOO, "back"), (76, P(CHOO, rot=3, sy=98), "io"),
            (92, RUB, "io"), (100, P(RUB, head=4), "io"), (108, P(RUB, head=-6), "io"), (116, P(RUB, head=3), "io"),
            (130, P(SMILE, eyes="happy"), "io"), (144, SMILE, "hold")]

    def props(world, front, back, ids):
        rnd = __import__("random").Random(3)
        puffs = []
        for k in range(6):
            a = -1.25 + k * 0.5 + rnd.uniform(-0.15, 0.15)       # a fan from left-down to right-down
            puffs.append((G.ellipse(front, 0, 0, 70, 60, "FFF2F0FA", stroke=6).get("id"),
                          a, rnd.uniform(230, 330), rnd.uniform(1.1, 1.8)))
        return {"puffs": puffs}

    def extra(la, ids, pr, end):
        for pid, a, dist, sc in pr["puffs"]:          # a burst of little clouds from the nose
            x0, y0 = 175, 10
            la.append(keyframes(pid, 13, [(0, x0, "hold"), (60, x0, "out"), (86, x0 + math.sin(a) * dist, "hold")]))
            la.append(keyframes(pid, 14, [(0, y0, "hold"), (60, y0, "out"), (86, y0 + 40 + math.cos(a) * dist * 0.45, "hold")]))
            for prop in (16, 17):
                la.append(keyframes(pid, prop, [(0, 0, "hold"), (60, 0.3, "out"), (86, sc, "hold")]))
            la.append(keyframes(pid, 18, [(0, 0, "hold"), (60, 1, "lin"), (84, 1, "lin"), (104, 0, "hold")]))
    return build("sneeze", keys, props, extra)

def dizzy():
    """poked on the head: stars circle it while it wobbles, then it shakes it off"""
    DAZE = P(SMILE, eyes="shut", mouth="open", armL1=20, armR1=-20, armL2=-15, armR2=15)
    keys = [(0, SMILE, "io"), (6, P(SMILE, sy=92, hy=10, eyes="shut"), "out")]
    for i, f in enumerate(range(16, 112, 12)):
        a = i * math.pi / 2
        keys.append((f, P(DAZE, rot=6 * math.sin(a), head=12 * math.sin(a), dx=10 * math.sin(a), hy=4 * math.cos(a)), "io"))
    for i, f in enumerate(range(118, 142, 4)):    # brr: a quick head shake
        keys.append((f, P(HAPPY, head=12 if i % 2 else -12), "io"))
    keys += [(150, HAPPY, "io"), (166, SMILE, "hold")]

    def props(world, front, back, ids):
        return {"stars": [G.star(front, 166, -340, f"star{k}").get("id") for k in range(3)]}

    def extra(la, ids, pr, end):
        for k, sid in enumerate(pr["stars"]):
            pts_x, pts_y = [], []
            for f in range(10, 116, 4):
                a = (f - 10) * 0.11 + k * 2 * math.pi / 3
                pts_x.append((f, 166 + 150 * math.cos(a), "lin"))
                pts_y.append((f, -330 + 40 * math.sin(a), "lin"))
            la.append(keyframes(sid, 13, [(0, 166, "hold")] + pts_x))
            la.append(keyframes(sid, 14, [(0, -330, "hold")] + pts_y))
            for prop in (16, 17):
                la.append(keyframes(sid, prop, [(0, 0, "hold"), (10, 0, "back"), (20, 0.62, "io"), (106, 0.62, "in"), (116, 0, "hold")]))
            la.append(keyframes(sid, 15, [(0, 0, "hold"), (10, 0, "lin"), (116, 6, "hold")]))
    return build("dizzy", keys, props, extra)

def peekaboo():
    """hides its eyes behind its paws, then pops out: boo!"""
    HIDE = reach(SMILE, (80, -55), (252, -55), lenAL=104, lenAR=104, mouth="grin", hy=8)
    BOO = P(HAPPY, armL1=105, armR1=-105, armL2=30, armR2=-30, lenAL=96, lenAR=96, mouth="open", dy=-30, sy=104)
    keys = [(0, SMILE, "io"), (16, HIDE, "io"), (30, P(HIDE, head=6), "io"), (44, P(HIDE, head=-6), "io"),
            (58, P(HIDE, head=0, sy=96, dy=8), "io"), (66, BOO, "back"), (96, P(BOO, dy=0, sy=100), "io"),
            (112, P(HAPPY, mouth="open"), "io"), (130, SMILE, "hold")]
    return build("peekaboo", keys)

def aww():
    """paws to its cheeks, all bashful and pleased"""
    STRONG = P(SMILE, armL1=110, armR1=-110, armL2=62, armR2=-62, lenAL=118, lenAR=118, eyes="happy", mouth="grin", sx=106, sy=98)
    keys = [(0, SMILE, "io"), (12, P(CROUCH, armL1=60, armR1=-60), "out"), (24, STRONG, "back"),
            (38, P(STRONG, sx=110, head=-6, armL2=78, armR2=-78), "io"), (52, P(STRONG, head=6), "io"),
            (66, P(STRONG, sx=110, head=-6, armL2=78, armR2=-78, mouth="open"), "io"), (84, STRONG, "io"),
            (100, HAPPY, "io"), (114, SMILE, "hold")]
    return build("aww", keys)

# ---------------------------------------------------------------- hover reactions
def notice():
    """the pointer arrives: the panda looks up, tilts its head and gives a little wave"""
    LOOK = P(HAPPY, head=-9, hy=-6, armR1=-120, armR2=-30, lenAR=92)
    keys = [(0, SMILE, "io"), (12, P(SMILE, hy=-6, head=-4), "io"), (22, LOOK, "back")]
    for i, f in enumerate(range(32, 68, 9)):
        keys.append((f, P(LOOK, armR2=-30 + (32 if i % 2 == 0 else -14)), "io"))
    keys += [(80, P(HAPPY, head=-4), "io"), (96, SMILE, "hold")]
    return build("notice", keys)

def hop():
    """the pointer arrives: a small happy hop"""
    keys = [(0, SMILE, "io"), (8, P(SMILE, sy=93, sx=105, dy=10, eyes="happy"), "out"),
            (18, P(HAPPY, dy=-70, sy=106, sx=96, armL1=40, armR1=-40, mouth="open"), "io"),
            (28, P(LAND, eyes="happy", armL1=10, armR1=-10), "back"), (36, P(HAPPY, dy=-30, sy=103), "io"),
            (44, P(HAPPY, sy=97, dy=4), "back"), (58, HAPPY, "io"), (72, SMILE, "hold")]
    return build("hop", keys)

CLICK = {"giggle": giggle, "startle": startle, "heart": heart, "sneeze": sneeze, "dizzy": dizzy, "peekaboo": peekaboo, "aww": aww}
HOVER = {"notice": notice, "hop": hop}
REACTIONS = {**CLICK, **HOVER}

if __name__ == "__main__":
    names = sys.argv[1].split(",") if len(sys.argv) > 1 and sys.argv[1] != "all" else list(REACTIONS)
    bg = sys.argv[2] if len(sys.argv) > 2 else None
    for n in names:
        orig = build.__defaults__
        build.__defaults__ = orig[:4] + (bg,) + orig[5:]
        print(REACTIONS[n]())
        build.__defaults__ = orig
