import json, os
W = os.path.dirname(os.path.abspath(__file__))
P = json.load(open(os.path.join(W, "flat.json")))
G = {
  "shadow": [0], "bag": list(range(1, 12)),
  "legs": [12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28],
  "torso": [29, 30, 31, 32, 33, 35, 36, 44, 45, 46, 47],
  "pad": [34, 37, 38, 39, 40, 41, 42, 43],
  "head": [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 71, 72, 73, 74],
  "eyes": [62, 63, 64, 65, 66, 67, 75, 76, 77, 78, 79, 80], "brows": [81, 82], "mouth": [68, 69, 70],
}
def path(i):
    x = P[i]
    a = f'd="{x["d"]}" transform="matrix({",".join(map(str, x["m"]))})"'
    a += f' fill="{x["fill"]}"'
    if x["fo"] != "1": a += f' fill-opacity="{x["fo"]}"'
    if x["op"] < 1: a += f' opacity="{x["op"]}"'
    return f"<path {a}/>"
def group(name, cls=None, extra=""):
    c = f' class="{cls}"' if cls else ""
    return f'<g{c}{extra}>' + "".join(path(i) for i in G[name]) + "</g>"
def draw_order(names):
    """Paths of the named groups in the original painting order."""
    ids = sorted(i for n in names for i in G[n])
    return "".join(path(i) for i in ids)
