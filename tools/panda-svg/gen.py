"""Panda scenes built from the flattened gaming panda (flat.json) + props in the same style."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parts import P, G, path

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(OUT, exist_ok=True)
NAVY = "#000073"
LW = 11  # outline width of the original art

G["torso_back"] = [29, 30, 31, 32, 33]
G["arms"] = [35, 36, 44, 45, 46, 47]

def grp(*names):
    ids = sorted(i for n in names for i in G[n])
    return "".join(path(i) for i in ids)

# --- shared panda pieces -------------------------------------------------------
EYES_HAPPY = (f'<path d="M250 304 Q279 272 308 304" fill="none" stroke="{NAVY}" stroke-width="15" stroke-linecap="round"/>'
              f'<path d="M444 304 Q473 272 502 304" fill="none" stroke="{NAVY}" stroke-width="15" stroke-linecap="round"/>')
EYES_SHUT = (f'<path d="M252 296 Q279 318 306 296" fill="none" stroke="{NAVY}" stroke-width="14" stroke-linecap="round"/>'
             f'<path d="M446 296 Q473 318 500 296" fill="none" stroke="{NAVY}" stroke-width="14" stroke-linecap="round"/>')
EYES_DIZZY = "".join(
    f'<path d="M{cx} {cy} m-4 0 a4 4 0 1 1 8 0 a10 10 0 1 1 -18 -2 a17 17 0 1 1 30 6" fill="none" stroke="{NAVY}" stroke-width="9" stroke-linecap="round"/>'
    for cx, cy in ((279, 296), (473, 296)))
MOUTH_CHEW = f'<path d="M344 358 Q358 376 372 362 Q386 376 400 358" fill="none" stroke="{NAVY}" stroke-width="11" stroke-linecap="round" stroke-linejoin="round"/>'
MOUTH_O = f'<ellipse cx="373" cy="366" rx="17" ry="21" fill="{NAVY}"/><ellipse cx="373" cy="374" rx="9" ry="8" fill="#ef4141"/>'
BLUSH = '<ellipse cx="222" cy="352" rx="30" ry="15" fill="#ff8fb1" opacity=".75"/><ellipse cx="528" cy="352" rx="30" ry="15" fill="#ff8fb1" opacity=".75"/>'
SHADOW = f'<ellipse cx="375" cy="652" rx="205" ry="24" fill="{NAVY}" fill-opacity=".16"/>'

BASE_CSS = """
.v{transform-box:view-box}
.blink{animation:blink 4.2s infinite;transform-origin:375px 296px}
@keyframes blink{0%,92%,100%{transform:scaleY(1)}95%{transform:scaleY(.1)}}
"""

def svg(body, css, dur_note=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -110 750 836" preserveAspectRatio="xMidYMax meet">'
            f'<style>{BASE_CSS}{css}</style>{body}</svg>')

def head(eyes_block, mouth_block, extra=""):
    """Head + face. eyes_block/mouth_block are full <g> strings."""
    return grp("head") + eyes_block + grp("brows") + mouth_block + extra

def open_eyes(cls="blink"):
    return f'<g class="v {cls}">{grp("eyes")}</g>'

# --- props ----------------------------------------------------------------------
def leaf(x, y, rot, s=1.0):
    return (f'<path transform="translate({x} {y}) rotate({rot}) scale({s})" d="M0 0 C 18 -26 52 -34 78 -26 C 58 -6 26 4 0 0 Z" '
            f'fill="#5fb84a" stroke="{NAVY}" stroke-width="8" stroke-linejoin="round"/>')

def bamboo_piece(x0, x1, y=508, h=34, jag_left=False, jag_right=False):
    def end(x, side):
        d = -1 if side == "r" else 1
        return f"L{x} {y} L{x + d*10} {y+9} L{x - d*2} {y+17} L{x + d*9} {y+25} L{x} {y+h}"
    left = end(x0, "l") if jag_left else f"L{x0} {y} Q{x0-8} {y+h/2} {x0} {y+h}"
    right = end(x1, "r") if jag_right else f"Q{x1+8} {y+h/2} {x1} {y}"
    if jag_right:
        d = f"M{x0} {y+h} " + (f"Q{x0-8} {y+h/2} {x0} {y} " if not jag_left else "") + f"L{x1} {y} " + \
            f"L{x1-10} {y+9} L{x1+2} {y+17} L{x1-9} {y+25} L{x1} {y+h} Z"
    elif jag_left:
        d = f"M{x0} {y} L{x0+10} {y+9} L{x0-2} {y+17} L{x0+9} {y+25} L{x0} {y+h} L{x1} {y+h} Q{x1+8} {y+h/2} {x1} {y} Z"
    else:
        d = f"M{x0} {y} L{x1} {y} Q{x1+8} {y+h/2} {x1} {y+h} L{x0} {y+h} Q{x0-8} {y+h/2} {x0} {y} Z"
    nodes = "".join(f'<path d="M{nx} {y+2} V{y+h-2}" stroke="{NAVY}" stroke-width="7" stroke-linecap="round"/>'
                    for nx in range(x0 + 60, x1 - 20, 95))
    hi = f'<rect x="{x0+10}" y="{y+6}" width="{max(0, x1-x0-24)}" height="7" rx="3.5" fill="#b5e79a"/>'
    return f'<path d="{d}" fill="#7bc95f" stroke="{NAVY}" stroke-width="{LW}" stroke-linejoin="round"/>' + hi + nodes

def star(cx, cy, r, fill="#ffd23f"):
    import math
    pts = []
    for k in range(16):
        a = math.pi * k / 8 - math.pi / 2
        rr = r if k % 2 == 0 else r * 0.45
        pts.append(f"{cx + rr*math.cos(a):.1f},{cy + rr*math.sin(a):.1f}")
    return f'<polygon points="{" ".join(pts)}" fill="{fill}" stroke="{NAVY}" stroke-width="8" stroke-linejoin="round"/>'

def tofu(x, y, s=50):
    k = 0.38
    top = f"{x},{y} {x+s*k},{y-s*k*.8} {x+s+s*k},{y-s*k*.8} {x+s},{y}"
    side = f"{x+s},{y} {x+s+s*k},{y-s*k*.8} {x+s+s*k},{y+s-s*k*.8} {x+s},{y+s}"
    return (f'<polygon points="{side}" fill="#efe1bd" stroke="{NAVY}" stroke-width="8" stroke-linejoin="round"/>'
            f'<polygon points="{top}" fill="#fffdf4" stroke="{NAVY}" stroke-width="8" stroke-linejoin="round"/>'
            f'<rect x="{x}" y="{y}" width="{s}" height="{s}" fill="#fff7e2" stroke="{NAVY}" stroke-width="8" stroke-linejoin="round"/>')

def manti(x, y, s=1.0):
    return (f'<g transform="translate({x} {y}) scale({s})">'
            f'<path d="M-22 10 C -26 -6 -10 -20 0 -24 C 10 -20 26 -6 22 10 C 10 16 -10 16 -22 10 Z" fill="#f6d79a" stroke="{NAVY}" stroke-width="7" stroke-linejoin="round"/>'
            f'<path d="M-8 -14 Q0 -4 8 -14" fill="none" stroke="{NAVY}" stroke-width="5" stroke-linecap="round"/></g>')

def cloud(cx, cy, s, fill="#b9dc6c"):
    blobs = [(-34, 6, 26), (0, -10, 32), (34, 4, 26), (12, 20, 22), (-16, 22, 20)]
    out = "".join(f'<circle cx="{cx + dx*s:.1f}" cy="{cy + dy*s:.1f}" r="{r*s:.1f}" fill="{NAVY}"/>' for dx, dy, r in blobs)
    out += "".join(f'<circle cx="{cx + dx*s:.1f}" cy="{cy + dy*s:.1f}" r="{r*s - 7:.1f}" fill="{fill}"/>' for dx, dy, r in blobs)
    return out

# --- scene: bamboo snap (busy) ---------------------------------------------------
def scene_bamboo():
    css = """
.body{animation:hop 4s infinite;transform-origin:375px 640px}
@keyframes hop{0%,40%,58%,100%{transform:translateY(0) scale(1)}44%{transform:translateY(4px) scale(1.03,.97)}49%{transform:translateY(-22px)}}
.whole{animation:whole 4s infinite steps(1,end)}
@keyframes whole{0%{opacity:1}46%{opacity:0}88%{opacity:1}}
.shake{animation:shake 4s infinite}
@keyframes shake{0%,10%{transform:translate(0,0)}14%{transform:translate(-3px,1px)}18%{transform:translate(3px,-1px)}22%{transform:translate(-4px,0)}26%{transform:translate(4px,1px)}30%{transform:translate(-5px,-1px)}34%{transform:translate(5px,0)}38%{transform:translate(-6px,1px)}42%{transform:translate(6px,0)}46%,100%{transform:translate(0,0)}}
.bend{animation:bend 4s infinite;transform-origin:375px 525px}
@keyframes bend{0%,12%{transform:scaleY(1)}44%{transform:scaleY(1)}}
.hl{animation:hl 4s infinite;transform-origin:287px 528px;opacity:0}
.hr{animation:hr 4s infinite;transform-origin:452px 528px;opacity:0}
@keyframes hl{0%,45.9%{opacity:0;transform:none}46%{opacity:1;transform:rotate(0)}52%{opacity:1;transform:rotate(-38deg)}70%{opacity:1;transform:translate(-30px,40px) rotate(-60deg)}80%{opacity:0;transform:translate(-40px,90px) rotate(-80deg)}100%{opacity:0}}
@keyframes hr{0%,45.9%{opacity:0;transform:none}46%{opacity:1;transform:rotate(0)}52%{opacity:1;transform:rotate(38deg)}70%{opacity:1;transform:translate(30px,40px) rotate(60deg)}80%{opacity:0;transform:translate(40px,90px) rotate(80deg)}100%{opacity:0}}
.pow{animation:pow 4s infinite;transform-origin:375px 500px;opacity:0}
@keyframes pow{0%,45%{opacity:0;transform:scale(.2)}48%{opacity:1;transform:scale(1.15) rotate(10deg)}56%{opacity:1;transform:scale(1) rotate(20deg)}62%,100%{opacity:0;transform:scale(.6)}}
.chip{animation:chip 4s infinite;opacity:0}
@keyframes chip{0%,46%{opacity:0;transform:translate(0,0)}48%{opacity:1}62%{opacity:0;transform:var(--to)}100%{opacity:0}}
.eyes-open{animation:eo 4s infinite steps(1,end)}
@keyframes eo{0%{opacity:1}47%{opacity:0}86%{opacity:1}}
.eyes-happy{animation:eh 4s infinite steps(1,end);opacity:0}
@keyframes eh{0%{opacity:0}47%{opacity:1}86%{opacity:0}}
.brow{animation:brow 4s infinite;transform-origin:375px 208px}
@keyframes brow{0%,10%{transform:translateY(0)}20%,44%{transform:translateY(10px)}50%,100%{transform:translateY(0)}}
"""
    chips = "".join(
        f'<g class="v chip" style="--to:translate({dx}px,{dy}px) rotate({r}deg);animation-delay:{d}s">'
        f'<rect x="368" y="514" width="14" height="10" rx="3" fill="#7bc95f" stroke="{NAVY}" stroke-width="5"/></g>'
        for dx, dy, r, d in ((-80, -90, -120, 0), (90, -110, 140, 0.02), (-40, -150, 200, 0.04), (60, -60, -90, 0.01)))
    whole = (f'<g class="v whole"><g class="v shake">{bamboo_piece(170, 580)}{leaf(172, 512, 200, .9)}{leaf(578, 512, -20, .9)}</g></g>')
    halves = (f'<g class="v hl">{bamboo_piece(170, 375, jag_right=True)}{leaf(172, 512, 200, .9)}</g>'
              f'<g class="v hr">{bamboo_piece(375, 580, jag_left=True)}{leaf(578, 512, -20, .9)}</g>')
    body = (SHADOW + '<g class="v body">' + grp("legs", "torso_back") + whole + halves + grp("arms")
            + head(f'<g class="v eyes-open"><g class="v blink">{grp("eyes")}</g></g><g class="v eyes-happy">{EYES_HAPPY}</g>',
                   grp("mouth")).replace(grp("brows"), f'<g class="v brow">{grp("brows")}</g>')
            + "</g>" + f'<g class="v pow">{star(375, 500, 70)}{star(375, 500, 34, "#fff3a8")}</g>' + chips)
    return svg(body, css)

# --- scene: eating (tofu / manti) -------------------------------------------------
def eat_css(n, dur):
    """n pieces fly to the mouth one after another; mouth chews in between."""
    seg = 100 / (n + 1)
    css = ""
    for k in range(n):
        a = seg * k + 4
        css += (f".p{k}{{animation:p{k} {dur}s infinite;transform-origin:var(--o)}}\n"
                f"@keyframes p{k}{{0%,{a:.1f}%{{transform:translate(0,0) scale(1);opacity:1}}"
                f"{a+seg*.25:.1f}%{{transform:translate(var(--mx),calc(var(--my) - 40px)) scale(.85);opacity:1}}"
                f"{a+seg*.4:.1f}%{{transform:translate(var(--mx),var(--my)) scale(.45);opacity:1}}"
                f"{a+seg*.42:.1f}%,94%{{transform:translate(var(--mx),var(--my)) scale(.4);opacity:0}}"
                f"97%,100%{{transform:translate(0,0) scale(1);opacity:var(--back,1)}}}}\n")
    # chewing windows after each bite lands
    stops = []
    for k in range(n):
        a = seg * k + 4 + seg * .42
        stops.append((a, a + seg * .55))
    on = ";".join(f"{s:.1f}%{{opacity:1}}{e:.1f}%{{opacity:0}}" for s, e in stops)
    css += (".chew{animation:chew " + f"{dur}s infinite steps(1,end);opacity:0}}\n"
            "@keyframes chew{0%{opacity:0}" + "".join(f"{s:.1f}%{{opacity:1}}{e:.1f}%{{opacity:0}}" for s, e in stops) + "}\n"
            ".smile{animation:smile " + f"{dur}s infinite steps(1,end)}}\n"
            "@keyframes smile{0%{opacity:1}" + "".join(f"{s:.1f}%{{opacity:0}}{e:.1f}%{{opacity:1}}" for s, e in stops) + "}\n"
            ".jaw{animation:jaw .32s infinite alternate ease-in-out;transform-origin:372px 362px}\n"
            "@keyframes jaw{from{transform:scaleY(1)}to{transform:scaleY(.55) translateY(4px)}}\n"
            ".blush{animation:chew " + f"{dur}s infinite steps(1,end);opacity:0}}\n"
            ".hold{animation:hold " + f"{dur}s infinite ease-in-out;transform-origin:375px 560px}}\n"
            "@keyframes hold{0%,100%{transform:translateY(0)}50%{transform:translateY(-4px)}}\n")
    return css

def scene_tofu():
    dur = 6
    css = eat_css(3, dur)
    plate = (f'<ellipse cx="375" cy="548" rx="158" ry="30" fill="#ffffff" stroke="{NAVY}" stroke-width="{LW}"/>'
             f'<ellipse cx="375" cy="544" rx="118" ry="17" fill="#e6e6f7"/>')
    pieces = [(318, 482), (376, 482), (347, 428)]  # bottom-left, bottom-right, top
    order = [2, 1, 0]  # eat the top one first
    cubes = ""
    for k, idx in enumerate(order):
        x, y = pieces[idx]
        cx, cy = x + 34, y + 20
        cubes += (f'<g class="v p{k}" style="--o:{cx}px {cy}px;--mx:{372-cx}px;--my:{360-cy}px">{tofu(x, y)}</g>')
    body = (SHADOW + '<g class="v hold">' + grp("legs", "torso_back") + plate + grp("arms")
            + head(open_eyes(), f'<g class="v smile">{grp("mouth")}</g><g class="v chew"><g class="v jaw">{MOUTH_CHEW}</g></g>',
                   f'<g class="v blush">{BLUSH}</g>')
            + cubes + "</g>")
    return svg(body, css)

def scene_manti():
    dur = 6
    css = eat_css(3, dur) + """
.steam path{animation:steam 2.4s infinite ease-in-out;opacity:0}
@keyframes steam{0%{opacity:0;transform:translateY(10px)}40%{opacity:.8}100%{opacity:0;transform:translateY(-40px)}}
"""
    bowl = (f'<path d="M232 520 Q238 612 375 616 Q512 612 518 520 Z" fill="#ffffff" stroke="{NAVY}" stroke-width="{LW}" stroke-linejoin="round"/>'
            f'<path d="M248 556 Q375 590 502 556" fill="none" stroke="#4d73e0" stroke-width="12" stroke-linecap="round"/>'
            f'<path d="M262 578 Q375 606 488 578" fill="none" stroke="#4d73e0" stroke-width="5" stroke-linecap="round" opacity=".7"/>'
            f'<ellipse cx="375" cy="520" rx="143" ry="24" fill="#fffdf6" stroke="{NAVY}" stroke-width="{LW}"/>')
    # dumplings that stay in the bowl
    stay = "".join(manti(x, y, 1.15) for x, y in ((292, 510), (458, 510), (326, 526), (424, 526)))
    sauce = "".join(f'<ellipse cx="{x}" cy="{y}" rx="{rx}" ry="{ry}" fill="#d93a22"/>' for x, y, rx, ry in
                    ((318, 506, 10, 4), (402, 510, 12, 4), (446, 526, 8, 3), (300, 526, 7, 3)))
    mint = "".join(f'<circle cx="{x}" cy="{y}" r="3.5" fill="#3f8f35"/>' for x, y in ((340, 503), (432, 504), (376, 528)))
    steam = ('<g class="steam">' + "".join(
        f'<path d="M{x} 470 q-10 -16 0 -32 q10 -16 0 -32" fill="none" stroke="#c9c9e6" stroke-width="7" stroke-linecap="round" style="animation-delay:{d}s"/>'
        for x, d in ((250, 0), (500, 1.2))) + "</g>")
    flyers = ""
    for k, (x, y) in enumerate(((375, 508), (352, 516), (398, 516))):
        flyers += f'<g class="v p{k}" style="--o:{x}px {y}px;--mx:{372-x}px;--my:{360-y}px">{manti(x, y, 1.35)}</g>'
    body = (SHADOW + '<g class="v hold">' + grp("legs", "torso_back") + bowl + stay + sauce + mint + grp("arms")
            + head(open_eyes(), f'<g class="v smile">{grp("mouth")}</g><g class="v chew"><g class="v jaw">{MOUTH_CHEW}</g></g>',
                   f'<g class="v blush">{BLUSH}</g>')
            + flyers + steam + "</g>")
    return svg(body, css)

# --- scene: fart and run (busy, rare) ----------------------------------------------
def scene_fart():
    css = """
.panda{animation:run 7s infinite;transform-origin:375px 640px}
@keyframes run{
 0%,24%{transform:translate(0,0)}
 27%{transform:translate(0,6px) scale(1.04,.95)}
 30%{transform:translate(0,-14px)}
 33%,40%{transform:translate(0,0)}
 44%{transform:translate(90px,-30px) rotate(8deg)}
 48%{transform:translate(200px,0) rotate(8deg)}
 52%{transform:translate(320px,-30px) rotate(8deg)}
 56%{transform:translate(440px,0) rotate(8deg)}
 60%{transform:translate(560px,-30px) rotate(8deg)}
 64%,78%{transform:translate(800px,0) rotate(8deg)}
 79%{transform:translate(-800px,0)}
 86%{transform:translate(-400px,-20px)}
 92%{transform:translate(-120px,0)}
 96%,100%{transform:translate(0,0)}}
.cloud{animation:cloud 7s infinite;transform-origin:150px 600px;opacity:0}
@keyframes cloud{0%,26%{opacity:0;transform:scale(.2)}30%{opacity:1;transform:scale(.9)}40%{opacity:1;transform:scale(1)}60%{opacity:.9;transform:scale(1.25) translateY(-20px)}74%,100%{opacity:0;transform:scale(1.45) translateY(-40px)}}
.c2{animation-delay:.12s}
.stink path{animation:stink 7s infinite;opacity:0}
@keyframes stink{0%,30%{opacity:0;transform:translateY(0)}36%{opacity:1}62%{opacity:0;transform:translateY(-50px)}100%{opacity:0}}
.calm{animation:calm 7s infinite steps(1,end)}
@keyframes calm{0%{opacity:1}29%{opacity:0}94%{opacity:1}}
.shock{animation:shock 7s infinite steps(1,end);opacity:0}
@keyframes shock{0%{opacity:0}29%{opacity:1}94%{opacity:0}}
.wide{transform-origin:375px 296px;transform:scale(1.12)}
.sweat{animation:sweat 7s infinite;opacity:0}
@keyframes sweat{0%,31%{opacity:0;transform:translateY(0)}34%{opacity:1}42%{opacity:1;transform:translateY(14px)}46%,100%{opacity:0}}
"""
    stink = ('<g class="stink">' + "".join(
        f'<path d="M{x} 600 q-12 -14 0 -28 q12 -14 0 -28" fill="none" stroke="#7fa83a" stroke-width="7" stroke-linecap="round" style="animation-delay:{d}s"/>'
        for x, d in ((110, 0), (160, .15), (205, .3))) + "</g>")
    sweat = f'<path class="v sweat" d="M560 205 q-14 22 0 30 q14 -8 0 -30 Z" fill="#8fd3ff" stroke="{NAVY}" stroke-width="6" stroke-linejoin="round"/>'
    body = (SHADOW.replace("<ellipse", '<ellipse class="v panda"')
            + f'<g class="v cloud">{cloud(150, 600, 1.25)}</g><g class="v cloud c2">{cloud(90, 640, .7)}</g>' + stink
            + '<g class="v panda">' + grp("legs", "torso_back", "arms")
            + head(f'<g class="v calm"><g class="v blink">{grp("eyes")}</g></g><g class="v shock"><g class="v wide">{grp("eyes")}</g></g>',
                   f'<g class="v calm">{grp("mouth")}</g><g class="v shock">{MOUTH_O}</g>',
                   f'<g class="v shock">{BLUSH}</g>' + sweat)
            + "</g>")
    return svg(body, css)

# --- scene: roll in, dizzy, roll out (idle) ----------------------------------------
def scene_roll():
    css = """
.roll{animation:roll 6s infinite;transform-origin:375px 430px}
@keyframes roll{
 0%{transform:translateX(-820px) rotate(-720deg)}
 26%{transform:translateX(0) rotate(0)}
 29%{transform:translateY(12px) scale(1.06,.92)}
 33%,72%{transform:translate(0,0)}
 100%{transform:translateX(820px) rotate(720deg)}}
.wob{animation:wob 1s infinite ease-in-out;transform-origin:375px 430px}
@keyframes wob{0%,100%{transform:rotate(-5deg)}50%{transform:rotate(5deg)}}
.dizzy{animation:dz 6s infinite steps(1,end);opacity:0}
@keyframes dz{0%{opacity:0}27%{opacity:1}64%{opacity:0}}
.norm{animation:nm 6s infinite steps(1,end)}
@keyframes nm{0%{opacity:1}27%{opacity:0}64%{opacity:1}}
.orbit{animation:orbit 1.1s infinite linear;transform-origin:375px 40px}
@keyframes orbit{to{transform:rotate(360deg)}}
.stars{animation:dz 6s infinite steps(1,end);opacity:0}
.sh{animation:shr 6s infinite}
@keyframes shr{0%{opacity:0}22%{opacity:0}26%,72%{opacity:1}76%,100%{opacity:0}}
"""
    import math
    kf = "".join(f"{p}%{{transform:translate({180*math.cos(2*math.pi*p/100):.0f}px,{52*math.sin(2*math.pi*p/100):.0f}px)}}" for p in range(0, 101, 10))
    css += "@keyframes orb{" + kf + "}\n.orb{animation:orb 1.2s infinite linear}\n"
    stars = ('<g class="v stars">' + "".join(
        f'<g class="v orb" style="animation-delay:-{d}s">{star(375, 20, 34)}</g>' for d in (0, .4, .8)) + "</g>")
    body = (SHADOW.replace("<ellipse", '<ellipse class="v sh"')
            + '<g class="v roll"><g>' + grp("legs", "torso_back", "arms")
            + '<g class="v wob">' + head(f'<g class="v norm">{grp("eyes")}</g><g class="v dizzy">{EYES_DIZZY}</g>',
                   grp("mouth")) + "</g>"
            + "</g></g>" + stars)
    return svg(body, css)

SCENES = {"bamboo": scene_bamboo, "tofu": scene_tofu, "manti": scene_manti, "fart": scene_fart, "roll": scene_roll}
if __name__ == "__main__":
    for name, fn in SCENES.items():
        s = fn()
        open(os.path.join(OUT, f"{name}.svg"), "w").write(s)
        print(name, len(s))
