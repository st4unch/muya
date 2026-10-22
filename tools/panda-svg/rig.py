"""Jointed panda rig: the original head/face (flat.json) on a body with shoulders, elbows,
hips and knees. Scenes give paw/foot targets over time; joint angles come from 2-bone IK,
sampled densely into CSS keyframes so props carried in a paw follow it exactly."""
import math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parts import P, G, path

NAVY = "#000073"
FUR = "#5f537b"      # dark fur of the original
FUR_SH = "#4b4167"   # its shade
LAV = "#b3b3d6"      # lavender shading of the original head
LW = 11

# ---- rig geometry (rig-local coordinates, sitting pose = root at 0,0) ----------
NECK = (375, 446)
SHOULDER = {"L": (286, 488), "R": (464, 488)}
UPPER, FORE, ARM_W, FORE_W = 64, 62, 60, 56
HIP = {"L": (318, 602), "R": (432, 602)}
THIGH, SHIN, LEG_W, SHIN_W = 42, 40, 74, 68
ROOT_PIVOT = (375, 420)

def ik(base, target, a, b, bend):
    """2-bone IK. bend: +1/-1 picks the elbow side; 'L'/'R' puts the elbow on that outer side
    (left = smaller x). Returns (upper_rot, lower_rot_rel) in degrees, 0 = pointing down."""
    bx, by = base; tx, ty = target
    dx, dy = tx - bx, ty - by
    d = max(abs(a - b) + 0.01, min(a + b - 0.01, math.hypot(dx, dy)))
    phi = math.atan2(dy, dx)
    alpha = math.acos(max(-1, min(1, (a * a + d * d - b * b) / (2 * a * d))))
    if isinstance(bend, str):
        xs = {sg: bx + a * math.cos(phi + sg * alpha) for sg in (1, -1)}
        sg = min(xs, key=xs.get) if bend == "L" else max(xs, key=xs.get)
    else:
        sg = 1 if bend > 0 else -1
    phi1 = phi + sg * alpha
    ex, ey = bx + a * math.cos(phi1), by + a * math.sin(phi1)
    tx2, ty2 = bx + d * math.cos(phi), by + d * math.sin(phi)
    phi2 = math.atan2(ty2 - ey, tx2 - ex)
    r1 = math.degrees(phi1) - 90
    r2 = math.degrees(phi2 - phi1)
    r2 = (r2 + 180) % 360 - 180
    return r1, r2

def end_point(base, r1, r2, a, b):
    t1 = math.radians(r1 + 90); ex, ey = base[0] + a * math.cos(t1), base[1] + a * math.sin(t1)
    t2 = math.radians(r1 + r2 + 90); return ex + b * math.cos(t2), ey + b * math.sin(t2)

# ---- drawing --------------------------------------------------------------------
def capsule(L, w, fill, outline):
    if outline:
        return f'<rect x="{-w/2}" y="{-w/2}" width="{w}" height="{L + w}" rx="{w/2}" fill="{NAVY}" stroke="{NAVY}" stroke-width="{2*LW}"/>'
    return f'<rect x="{-w/2}" y="{-w/2}" width="{w}" height="{L + w}" rx="{w/2}" fill="{fill}"/>'

def paw(outline):
    if outline:
        return f'<circle cy="4" r="{FORE_W/2 + 3}" fill="{NAVY}" stroke="{NAVY}" stroke-width="{2*LW}"/>'
    return (f'<circle cy="4" r="{FORE_W/2 + 3}" fill="{FUR}"/>'
            f'<path d="M-14 16 Q0 26 14 16" fill="none" stroke="{LAV}" stroke-width="5" stroke-linecap="round" opacity=".8"/>')

def foot(outline, side):
    """Sole (sitting, facing the viewer) and front foot (standing); scenes fade between them."""
    if outline:
        return (f'<g class="sole{side}"><ellipse cy="10" rx="47" ry="52" fill="{NAVY}" stroke="{NAVY}" stroke-width="{2*LW}"/></g>'
                f'<g class="front{side}"><ellipse cy="14" rx="40" ry="27" fill="{NAVY}" stroke="{NAVY}" stroke-width="{2*LW}"/></g>')
    beans = "".join(f'<ellipse cx="{x}" cy="{y}" rx="9" ry="10" fill="{NAVY}"/>' for x, y in ((-22, -12), (0, -24), (22, -12)))
    return (f'<g class="sole{side}"><ellipse cy="10" rx="47" ry="52" fill="{FUR}"/>'
            f'<ellipse cy="22" rx="25" ry="21" fill="{NAVY}"/>{beans}</g>'
            f'<g class="front{side}"><ellipse cy="14" rx="40" ry="27" fill="{FUR}"/>'
            f'<path d="M-22 22 Q0 32 22 22" fill="none" stroke="{LAV}" stroke-width="5" stroke-linecap="round" opacity=".7"/></g>')

def limb(kind, side, outline):
    base = SHOULDER[side] if kind == "arm" else HIP[side]
    a, b, w1, w2 = (UPPER, FORE, ARM_W, FORE_W) if kind == "arm" else (THIGH, SHIN, LEG_W, SHIN_W)
    k = f"{kind}{side}"
    end = paw(outline) if kind == "arm" else f'<g class="j ft{side}">{foot(outline, side)}</g>'
    return (f'<g transform="translate({base[0]} {base[1]})"><g class="j {k}1">{capsule(a, w1, FUR, outline)}'
            f'<g transform="translate(0 {a})"><g class="j {k}2">{capsule(b, w2, FUR, outline)}'
            f'<g transform="translate(0 {b})">{end}</g></g></g></g></g>')

TORSO_D = "M284 428 C 232 470 206 556 218 612 C 232 664 518 664 532 612 C 544 556 518 470 466 428 Z"

def torso():
    return (f'<clipPath id="tc"><path d="{TORSO_D}"/></clipPath>'
            f'<path d="{TORSO_D}" fill="{FUR}" stroke="{NAVY}" stroke-width="{2*LW}" stroke-linejoin="round"/>'
            f'<g clip-path="url(#tc)"><ellipse cx="375" cy="590" rx="118" ry="84" fill="#ffffff"/>'
            f'<path d="M486 470 C 520 540 520 610 488 664 L 560 664 L 560 460 Z" fill="{FUR_SH}" opacity=".55"/></g>')

def head_paths():
    return "".join(path(i) for i in G["head"])

# ---- face variants (rig-local, inside the head group) -----------------------------
FACE = {
  "eyes_open": lambda: '<g class="blink">' + "".join(path(i) for i in G["eyes"]) + "</g>",
  "eyes_wide": lambda: '<g transform="translate(375 296) scale(1.13) translate(-375 -296)">' + "".join(path(i) for i in G["eyes"]) + "</g>",
  "eyes_happy": lambda: (f'<path d="M250 304 Q279 272 308 304" fill="none" stroke="{NAVY}" stroke-width="15" stroke-linecap="round"/>'
                         f'<path d="M444 304 Q473 272 502 304" fill="none" stroke="{NAVY}" stroke-width="15" stroke-linecap="round"/>'),
  "eyes_shut": lambda: (f'<path d="M252 292 L306 304" fill="none" stroke="{NAVY}" stroke-width="14" stroke-linecap="round"/>'
                        f'<path d="M500 292 L446 304" fill="none" stroke="{NAVY}" stroke-width="14" stroke-linecap="round"/>'),
  "eyes_dizzy": lambda: "".join(
      f'<path d="M{cx} {cy} m-4 0 a4 4 0 1 1 8 0 a10 10 0 1 1 -18 -2 a17 17 0 1 1 30 6" fill="none" stroke="{NAVY}" stroke-width="9" stroke-linecap="round"/>'
      for cx, cy in ((279, 296), (473, 296))),
  "mouth_open": lambda: "".join(path(i) for i in G["mouth"]),
  "mouth_chew": lambda: f'<g class="jaw"><path d="M344 358 Q358 376 372 362 Q386 376 400 358" fill="none" stroke="{NAVY}" stroke-width="11" stroke-linecap="round" stroke-linejoin="round"/></g>',
  "mouth_o": lambda: f'<ellipse cx="373" cy="366" rx="17" ry="21" fill="{NAVY}"/><ellipse cx="373" cy="374" rx="9" ry="8" fill="#ef4141"/>',
  "mouth_grin": lambda: f'<path d="M336 352 Q372 400 408 352 Z" fill="{NAVY}" stroke="{NAVY}" stroke-width="8" stroke-linejoin="round"/><path d="M352 372 Q372 392 392 372 Q372 380 352 372 Z" fill="#ef4141"/>',
  "blush": lambda: '<ellipse cx="222" cy="352" rx="30" ry="15" fill="#ff8fb1" opacity=".8"/><ellipse cx="528" cy="352" rx="30" ry="15" fill="#ff8fb1" opacity=".8"/>',
}
EYES = ["eyes_open", "eyes_wide", "eyes_happy", "eyes_shut", "eyes_dizzy"]
MOUTHS = ["mouth_open", "mouth_chew", "mouth_o", "mouth_grin"]

# ---- timeline -------------------------------------------------------------------
def ease(u):
    return u * u * (3 - 2 * u)

def lerp(a, b, u):
    return a + (b - a) * u

class Timeline:
    """keys: list of (pct, dict). Numeric/tuple values are interpolated with smoothstep."""
    def __init__(self, keys):
        self.keys = sorted(keys, key=lambda k: k[0])
    def at(self, pct, name, default=None):
        ks = [(t, d[name]) for t, d in self.keys if name in d]
        if not ks: return default
        if pct <= ks[0][0]: return ks[0][1]
        for (t0, v0), (t1, v1) in zip(ks, ks[1:]):
            if t0 <= pct <= t1:
                if isinstance(v0, str) or isinstance(v1, str) or t1 == t0:
                    return v0 if pct < t1 else v1
                u = ease((pct - t0) / (t1 - t0))
                if isinstance(v0, tuple):
                    return tuple(lerp(x, y, u) for x, y in zip(v0, v1))
                return lerp(v0, v1, u)
        return ks[-1][1]
    def discrete(self, name):
        """[(pct, value)] change points for a string-valued track."""
        return [(t, d[name]) for t, d in self.keys if name in d]

def kf(name, frames, fmt):
    body = "".join(f"{p:.1f}%{{transform:{fmt(v)}}}" for p, v in frames)
    return f"@keyframes {name}{{{body}}}\n"

def steps_opacity(cls, changes, value, dur):
    """opacity 1 while the discrete track equals value."""
    seq = []
    for t, v in changes:
        seq.append((t, 1 if v == value else 0))
    if not seq or seq[0][0] > 0: seq.insert(0, (0, seq[0][1] if seq else 0))
    body = "".join(f"{t:.1f}%{{opacity:{o}}}" for t, o in seq) + f"100%{{opacity:{seq[-1][1]}}}"
    name = "o_" + cls.replace(" ", "_")
    return f".{cls}{{animation:{name} {dur}s infinite steps(1,end)}}@keyframes {name}{{{body}}}\n"

def build(tl, dur, make_props=None, root_fn=None, extra_css="", step=1.0, behind="", front="", shadow=True, camera="", view_h=836, head_extra=""):
    """Render a full scene SVG from a timeline.
    tracks: root=(dx,dy,rot,sx,sy) head=deg armL/armR/legL/legR=(tx,ty) [targets]
    bendL/bendR (arm elbow side, default), foot='sole'|'front', eyes, mouth, blush 0/1."""
    pcts = [round(i * step, 3) for i in range(int(100 / step) + 1)]
    css = (".j{transform-box:view-box;transform-origin:0 0}"
           ".blink{animation:blink 4.2s infinite;transform-box:view-box;transform-origin:375px 296px}"
           "@keyframes blink{0%,93%,100%{transform:scaleY(1)}96%{transform:scaleY(.1)}}"
           ".jaw{animation:jaw .3s infinite alternate ease-in-out;transform-box:view-box;transform-origin:372px 362px}"
           "@keyframes jaw{from{transform:scaleY(1)}to{transform:scaleY(.5) translateY(5px)}}\n")
    frames = {k: [] for k in ("root", "head", "armL1", "armL2", "armR1", "armR2", "legL1", "legL2", "legR1", "legR2", "ftL", "ftR")}
    paws = {"L": [], "R": []}
    for p in pcts:
        rx, ry, rr, sx, sy = tl.at(p, "root", (0, 0, 0, 1, 1))
        if root_fn: rx, ry, rr, sx, sy = root_fn(p, (rx, ry, rr, sx, sy))
        frames["root"].append((p, (rx, ry, rr, sx, sy)))
        frames["head"].append((p, tl.at(p, "head", 0)))
        for s in "LR":
            tgt = tl.at(p, "arm" + s)
            r1, r2 = ik(SHOULDER[s], tgt, UPPER, FORE, tl.at(p, "bend" + s, s))
            frames[f"arm{s}1"].append((p, r1)); frames[f"arm{s}2"].append((p, r2))
            paws[s].append((p, end_point(SHOULDER[s], r1, r2, UPPER, FORE)))
            ltgt = tl.at(p, "leg" + s)
            l1, l2 = ik(HIP[s], ltgt, THIGH, SHIN, tl.at(p, "lbend" + s, s))
            frames[f"leg{s}1"].append((p, l1)); frames[f"leg{s}2"].append((p, l2))
            frames[f"ft{s}"].append((p, -(l1 + l2) + tl.at(p, "ftrot" + s, 0)))
    px, py = ROOT_PIVOT
    css += kf("k_root", frames["root"], lambda v: f"translate({v[0]:.1f}px,{v[1]:.1f}px) translate({px}px,{py}px) rotate({v[2]:.1f}deg) scale({v[3]:.3f},{v[4]:.3f}) translate({-px}px,{-py}px)")
    css += f".root{{animation:k_root {dur}s infinite linear}}\n"
    nx, ny = NECK
    css += kf("k_head", frames["head"], lambda v: f"translate({nx}px,{ny}px) rotate({v:.1f}deg) translate({-nx}px,{-ny}px)")
    css += f".head{{animation:k_head {dur}s infinite linear}}\n"
    for k in ("armL1", "armL2", "armR1", "armR2", "legL1", "legL2", "legR1", "legR2", "ftL", "ftR"):
        css += kf("k_" + k, frames[k], lambda v: f"rotate({v:.1f}deg)") + f".{k}{{animation:k_{k} {dur}s infinite linear}}\n"
    # discrete tracks
    for s in "LR":
        ch = tl.discrete("foot") or [(0, "sole")]
        css += steps_opacity(f"sole{s}", ch, "sole", dur) + steps_opacity(f"front{s}", ch, "front", dur)
    eyes_ch = tl.discrete("eyes") or [(0, "eyes_open")]
    mouth_ch = tl.discrete("mouth") or [(0, "mouth_open")]
    blush_ch = tl.discrete("blush") or [(0, "0")]
    face = ""
    for e in EYES:
        if any(v == e for _, v in eyes_ch):
            css += steps_opacity(e, eyes_ch, e, dur); face += f'<g class="{e}">{FACE[e]()}</g>'
    for m in MOUTHS:
        if any(v == m for _, v in mouth_ch):
            css += steps_opacity(m, mouth_ch, m, dur); face += f'<g class="{m}">{FACE[m]()}</g>'
    if any(v == "1" for _, v in blush_ch):
        css += steps_opacity("blush", blush_ch, "1", dur); face += f'<g class="blush">{FACE["blush"]()}</g>'
    props_back, props_front, pcss = make_props(paws, pcts, frames) if make_props else ("", "", "")
    css += pcss
    brows = "".join(path(i) for i in G["brows"])
    head = f'<g class="head">{head_paths()}{face}<g class="brows">{brows}</g>{head_extra}</g>'
    legs = limb("leg", "L", True) + limb("leg", "L", False) + limb("leg", "R", True) + limb("leg", "R", False)
    arms = limb("arm", "L", True) + limb("arm", "L", False) + limb("arm", "R", True) + limb("arm", "R", False)
    shadow_css = kf("k_sh", [(p, v) for p, v in frames["root"]], lambda v: f"translate({v[0]:.1f}px,0) scale({max(.55, 1 - abs(v[1]) / 260):.3f},1)")
    css += shadow_css + f".sh{{animation:k_sh {dur}s infinite linear;transform-box:view-box;transform-origin:375px 652px}}\n"
    sh = f'<ellipse class="sh" cx="375" cy="652" rx="200" ry="24" fill="{NAVY}" fill-opacity=".16"/>' if shadow else ""
    inner = f'{behind}{sh}<g class="root">{torso()}{legs}{head}{props_back}{arms}{props_front}</g>{front}'
    if camera: inner = f'<g class="{camera}">{inner}</g>'
    body = f'<g transform="translate(0 110)">{inner}</g>'
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 750 {view_h}" preserveAspectRatio="xMidYMax meet">'
           f'<style>{css}{extra_css}</style>{body}</svg>')
    return svg, paws, pcts

def track_css(name, frames, fmt, dur):
    return kf("k_" + name, frames, fmt) + f".{name}{{animation:k_{name} {dur}s infinite linear;transform-box:view-box;transform-origin:0 0}}\n"
