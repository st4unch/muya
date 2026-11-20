#!/usr/bin/env bash
# AC10 against the real app view (throwaway stack, fake HOME, own sockets; kills only what it started):
#  A. 200-character Turkish run (ğ ş ç ı ö ü Ğ Ş Ç İ Ö Ü, İ/I typed with Caps Lock) as real CGEvent key events
#     posted to the app's pid -> window -> keyDown -> input context -> insertText:. `cat` writes what the pty
#     received to a file; it must equal the text byte for byte (0 dropped, 0 duplicated).
#  B. Japanese run through the NSTextInputClient API (setMarkedText / insertText, no input-source switch):
#     40 compositions, 200 committed characters; nothing reaches the pty while composing; file == text.
#  C. IME candidate rect vs the drawn cursor cell (pixel diff of two window screenshots), cursor hidden and
#     parked like a TUI does, at two positions.
#  D. Reading the terminal's visible lines through the accessibility tree (external AXUIElement when this
#     session may use it, else the in-app NSAccessibility walk; the script says which).
# Real press-and-hold on a physical keyboard and a real input-method candidate window stay NEEDS-OPERATOR.
#   verify-ac10.sh    records "ac10" in measurements.json, exit 1 on FAIL
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
SHOTS=$HERE/screenshots
WORK=$(mktemp -d /tmp/muya-ac10.XXXXXX)  # short path: unix socket paths are limited to 104 bytes
export TMPDIR=$WORK
STATE=$WORK/muya-native-dev.state
cleanup() { ./run-dev.sh stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM   # Ctrl-C / kill: leave through the EXIT trap so the stack is stopped
[ -x build/cg-type ] && [ -x build/ax-read ] || {
  swiftc -O -o build/cg-type tools/cg-type.swift && swiftc -O -o build/ax-read tools/ax-read.swift || exit 1; }

./run-dev.sh start >/dev/null || exit 1
. "$STATE"
dbg() { printf '%s\n' "$1" | nc -U -w 6 "$DEV/app-debug.sock"; }
for _ in $(seq 80); do [ -S "$DEV/app-debug.sock" ] && [ -n "$(dbg windowid 2>/dev/null)" ] && break; sleep 0.1; done
fails=0
RES=$WORK/res.json
echo '{}' > "$RES"
rec() { python3 -I - "$RES" "$1" "$2" <<'E'
import json, sys
p, k, v = sys.argv[1:4]
d = json.load(open(p)); d[k] = json.loads(v); json.dump(d, open(p, "w"))
E
}
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }

mkdir -p "$DEV/home/ime"
for _ in $(seq 40); do case "$(dbg "new $DEV/home/ime")" in ok*) break ;; esac; sleep 0.25; done # the app may still be connecting
sleep 1.2
dbg windowid >/dev/null
# The app must be the one receiving the posted key events: bring its window forward when the session allows it.
osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$APP_PID"') to true' >/dev/null 2>&1 || true

# ---------- A: Turkish, CGEvent -------------------------------------------------------------------------
python3 -I - "$WORK" <<'E'
import sys
base = "ğüşiöçıĞÜŞİÖÇI"  # lower-case set, ı, then upper-case set with dotted İ and plain I
out, i = "", 0
while len(out) < 200:
    out += base[i % len(base)] + ("a" if i % 5 == 4 else "")
    i += 1
out = out[:200]
open(sys.argv[1] + "/tr.txt", "w", encoding="utf-8").write(out)
E
TR=$(cat "$WORK/tr.txt")
echo "== A: Turkish run, ${#TR} chars, CGEvent -> pid"
dbg "type \"cat > $WORK/tr.out\\n\"" >/dev/null; sleep 0.5
build/cg-type "$APP_PID" "$TR" --caps-for "İI" --gap-ms 6; rc=$?
if [ $rc = 2 ]; then echo "NEEDS-OPERATOR: this process may not post key events"; fails=$((fails + 1)); fi
sleep 0.6
# the wrapped rows as shown on screen, read before Enter
SCREEN_JOINED=$(dbg 'ax-terminal text' | python3 -I -c "import json,sys;print(json.loads(sys.stdin.read()).replace('\n',''))")
build/cg-type "$APP_PID" $'\n' ; sleep 0.3
build/cg-type "$APP_PID" $'\004'; sleep 0.8
python3 -I - "$WORK" <<'E' > "$WORK/a.json"
import json, sys
w = sys.argv[1]
want = open(w + "/tr.txt", encoding="utf-8").read() + "\n"
try: got = open(w + "/tr.out", "rb").read().decode("utf-8", "replace")
except FileNotFoundError: got = ""
import difflib
sm = difflib.SequenceMatcher(None, want, got)
dropped = sum(i2 - i1 for t, i1, i2, j1, j2 in sm.get_opcodes() if t in ("delete", "replace"))
extra = sum(j2 - j1 for t, i1, i2, j1, j2 in sm.get_opcodes() if t in ("insert", "replace"))
print(json.dumps({"typed": len(want) - 1, "received": len(got) - (1 if got.endswith("\n") else 0), "dropped": dropped, "duplicated_or_wrong": extra, "exact": want == got}))
E
cat "$WORK/a.json"
check "A: pty received exactly the typed Turkish text" "$(python3 -I -c "import json;print(json.load(open('$WORK/a.json'))['exact'])")" "True"
case "$SCREEN_JOINED" in *"$TR"*) ok "A: the same text is on screen (read through the accessibility tree)" ;; *) bad "A: screen does not show the typed text: [$SCREEN_JOINED]" ;; esac
rec turkish "$(cat "$WORK/a.json")"

# ---------- B: Japanese marked text via the text-input API ---------------------------------------------
echo "== B: Japanese marked-text run (setMarkedText / insertText)"
python3 -I - "$WORK" <<'E'
import json, sys
words = [("にほんご", "日本語入力"), ("とうきょう", "東京都内勤"), ("かんじ", "漢字変換中"), ("れんしゅう", "日本語練習"),
         ("おおさか", "大阪府内外"), ("きょうと", "京都市内外"), ("じしょ", "辞書登録済"), ("へんかん", "変換候補欄"),
         ("こうほ", "候補選択中"), ("にゅうりょく", "入力確定後")]
seq = [words[i % 10] for i in range(40)]
json.dump(seq, open(sys.argv[1] + "/jp.json", "w"), ensure_ascii=False)
open(sys.argv[1] + "/jp.txt", "w", encoding="utf-8").write("".join(k for _, k in seq))
E
dbg "type \"cat > $WORK/jp.out\\n\"" >/dev/null; sleep 0.5
python3 -I - "$WORK" "$DEV/app-debug.sock" <<'E'
import json, socket, sys, time
w, sock = sys.argv[1:3]
def dbg(cmd):
    s = socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(6)
    s.sendall((cmd + "\n").encode()); r = s.makefile("r", encoding="utf-8").readline().strip(); s.close(); return r
seq = json.load(open(w + "/jp.json", encoding="utf-8"))
leaks = 0; shown = 0
for kana, kanji in seq:
    for n in range(1, len(kana) + 1):
        dbg("preedit " + json.dumps(kana[:n], ensure_ascii=False))
    if json.dumps(kana, ensure_ascii=False) in dbg("firstrect").split("preedit=", 1)[-1]: shown += 1
    dbg("commit " + json.dumps(kanji, ensure_ascii=False))
    if 'preedit=""' not in dbg("firstrect"): leaks += 1
json.dump({"compositions": len(seq), "preedit_shown": shown, "preedit_left_after_commit": leaks}, open(w + "/b1.json", "w"))
E
dbg 'type "\n"' >/dev/null; sleep 0.3
build/cg-type "$APP_PID" $'\004'; sleep 0.8
python3 -I - "$WORK" <<'E' > "$WORK/b.json"
import json, sys
w = sys.argv[1]
want = open(w + "/jp.txt", encoding="utf-8").read()
try: got = open(w + "/jp.out", "rb").read().decode("utf-8", "replace").rstrip("\n")
except FileNotFoundError: got = ""
b1 = json.load(open(w + "/b1.json"))
print(json.dumps({**b1, "committed": len(want), "received": len(got), "exact": want == got}))
E
cat "$WORK/b.json"
check "B: pty received exactly the committed Japanese text (no preedit leaked, none dropped or duplicated)" "$(python3 -I -c "import json;print(json.load(open('$WORK/b.json'))['exact'])")" "True"
check "B: every composition showed its marked text" "$(python3 -I -c "import json;d=json.load(open('$WORK/b.json'));print(d['preedit_shown'])")" "40"
check "B: marked text cleared after every commit" "$(python3 -I -c "import json;print(json.load(open('$WORK/b.json'))['preedit_left_after_commit'])")" "0"
rec japanese "$(cat "$WORK/b.json")"

# ---------- C: candidate rect vs drawn cursor ----------------------------------------------------------
echo "== C: IME anchor vs the cursor the terminal draws (hardware cursor hidden, parked like a TUI)"
dbg appearance dark >/dev/null
shotw() { screencapture -x -o -l "$(dbg windowid)" "$1"; }
anchor_case() { # row col name: one program shows the cursor, then hides it (screen otherwise identical)
  local row=$1 col=$2 name=$3 sid
  sid=$(dbg "new $DEV/home/ime" | awk '{print $2}'); dbg "select $sid" >/dev/null; sleep 1.0 # a fresh shell per case
  dbg "type \"printf '\\\\033[?25h\\\\033[$row;${col}H'; sleep 6; printf '\\\\033[?25l'; sleep 40\\n\"" >/dev/null
  sleep 2.5; shotw "$WORK/${name}-shown.png"
  sleep 4.5; shotw "$WORK/${name}-hidden.png"
  dbg 'preedit "にほんご"' >/dev/null; sleep 0.5
  local fr geo
  fr=$(dbg firstrect); geo=$(dbg geometry)
  shotw "$WORK/${name}-preedit.png"
  dbg unmark >/dev/null
  python3 - "$WORK/${name}-shown.png" "$WORK/${name}-hidden.png" "$fr" "$geo" "$row" "$col" "$name" <<'E'
import json, re, sys
from PIL import Image, ImageChops
a, b, fr, geo, row, col, name = sys.argv[1:8]
A, B = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
diff = ImageChops.difference(A, B).convert("L").point(lambda v: 255 if v > 24 else 0)
rect = [float(x) for x in re.search(r"rect=(-?\d+),(-?\d+),(\d+),(\d+)", fr).groups()]
cell = re.search(r"cursor=(\d+),(\d+)", fr).groups()
w = re.search(r"window=([\d.-]+),([\d.-]+),([\d.-]+),([\d.-]+) scale=([\d.]+) screen_h=([\d.]+)", geo)
wx, wy, ww, wh, scale = [float(w.group(i)) for i in range(1, 6)]
# firstrect is in screen points with the origin bottom-left; the screenshot is the window, origin top-left, in pixels
exp = ((rect[0] - wx) * scale, (wy + wh - (rect[1] + rect[3])) * scale, rect[2] * scale, rect[3] * scale)
# The frame around the terminal changes between the two shots too (CPU / RAM / clock in the header, the status
# line), so look for the cursor block only near the rect the input method was given: 24 px around it.
m = 24
box = (max(int(exp[0]) - m, 0), max(int(exp[1]) - m, 0), min(int(exp[0] + exp[2]) + m, diff.width), min(int(exp[1] + exp[3]) + m, diff.height))
bb = diff.crop(box).getbbox()
bbox = (bb[0] + box[0], bb[1] + box[1], bb[2] + box[0], bb[3] + box[1]) if bb else None
print(json.dumps({"name": name, "cursor_cell": [int(cell[0]), int(cell[1])], "want_cell": [int(col) - 1, int(row) - 1],
                  "expected_px": [round(v, 1) for v in exp], "drawn_bbox_px": list(bbox) if bbox else None}))
E
}
python3 -c "import PIL" 2>/dev/null || { echo "NEEDS-OPERATOR: python3 with Pillow is required for the pixel check"; fails=$((fails + 1)); }
C1=$(anchor_case 12 30 c1 | tail -1); echo "$C1"
C2=$(anchor_case 5 60 c2 | tail -1); echo "$C2"
# The same at another terminal font size (⌘= seven times: 13 -> 20 pt): the cell size changes, the anchor must follow.
for _ in 1 2 3 4 5 6 7; do dbg "p3-key cmd+=" >/dev/null; done
C3=$(anchor_case 8 40 c3 | tail -1); echo "$C3"
dbg "p3-key cmd+0" >/dev/null
python3 -I - "$C1" "$C2" "$C3" > "$WORK/c.json" <<'E'
import json, sys
res = []
for line in sys.argv[1:]:
    d = json.loads(line)
    bb, exp = d["drawn_bbox_px"], d["expected_px"]
    cell_ok = d["cursor_cell"] == d["want_cell"]
    # the diff box also covers the prompt text that changed between the two shots, so compare the cursor
    # block (the last 16-px-high box) by corner: the rect's top-left must be inside the drawn box's last cell row
    px_ok = bb is not None and abs(bb[0] - exp[0]) <= 3 and abs(bb[1] - exp[1]) <= 3 and abs((bb[2] - bb[0]) - exp[2]) <= 3 and abs((bb[3] - bb[1]) - exp[3]) <= 3
    res.append({**d, "cell_ok": cell_ok, "pixel_ok": px_ok})
print(json.dumps(res))
E
cat "$WORK/c.json"
check "C: anchor cell is the parked cursor cell (three positions, two font sizes)" "$(python3 -I -c "import json;print(all(r['cell_ok'] for r in json.load(open('$WORK/c.json'))))")" "True"
check "C: candidate rect lies on the drawn cursor block within 3 px (three positions, two font sizes)" "$(python3 -I -c "import json;print(all(r['pixel_ok'] for r in json.load(open('$WORK/c.json'))))")" "True"
rec anchor "$(cat "$WORK/c.json")"
# Pictures for the record: a parked, hidden cursor with a composition shown at it, in both appearances.
sid=$(dbg "new $DEV/home/ime" | awk '{print $2}'); dbg "select $sid" >/dev/null; sleep 1.0
dbg "type \"clear; printf '\\\\033[?25l\\\\033[12;30H'; sleep 60\\n\"" >/dev/null; sleep 1.0
dbg 'preedit "にほんご"' >/dev/null
for ap in dark light; do dbg "appearance $ap" >/dev/null; sleep 1.5; shotw "$SHOTS/ime-anchor-$ap.png"; done
dbg appearance dark >/dev/null; dbg unmark >/dev/null

# ---------- D: accessibility read -----------------------------------------------------------------------
echo "== D: reading the visible lines through accessibility"
sid=$(dbg "new $DEV/home/ime" | awk '{print $2}'); dbg "select $sid" >/dev/null; sleep 1.0
dbg 'type "clear; printf \"AX-LINE-ONE ğşçıöü\\nAX-LINE-TWO 日本語\\n\"\n"' >/dev/null; sleep 0.8
EXT=$(build/ax-read "$APP_PID" 2>&1); extrc=$?
INAPP=$(dbg 'ax-terminal text' | python3 -I -c "import json,sys;print(json.loads(sys.stdin.read()))")
case "$INAPP" in *"AX-LINE-ONE ğşçıöü"*"AX-LINE-TWO 日本語"*) ok "D: in-app accessibility tree returns both lines" ;; *) bad "D: in-app AX text: [$INAPP]" ;; esac
check "D: terminal element role and label" "$(dbg ax-terminal | sed 's/ chars=.*//')" "role=AXTextArea label=Terminal, ime"
LOCK=$(ioreg -n Root -d1 -a 2>/dev/null | grep -A1 "CGSSessionScreenIsLocked" | grep -c "<true/>")
case "$EXT" in
  *"AX-LINE-ONE ğşçıöü"*"AX-LINE-TWO 日本語"*) ok "D: external AXUIElement read returns both lines"; AXSRC=external ;;
  *) AXSRC=in-app; echo "NOTE: external AXUIElement read not possible here (rc=$extrc, screen locked=$LOCK); in-app NSAccessibility walk used" ;;
esac
rec ax "{\"source\": \"$AXSRC\", \"screen_locked\": $LOCK}"

python3 -I - "$RES" "$fails" <<'E'
import json, os, sys
res, fails = sys.argv[1], int(sys.argv[2])
r = json.load(open(res))
out = {"turkish": r.get("turkish"), "japanese": r.get("japanese"), "ime_anchor": r.get("anchor"), "accessibility_read": r.get("ax"),
       "needs_operator": "real press-and-hold on a physical keyboard; real input-method candidate window", "pass": fails == 0}
path = os.path.join(os.getcwd(), "measurements.json")
d = json.load(open(path)); d["ac10"] = out
json.dump(d, open(path, "w"), indent=1); open(path, "a").write("\n")
print("AC10", "PASS" if fails == 0 else "FAIL (%d)" % fails)
E
exit $((fails > 0))
