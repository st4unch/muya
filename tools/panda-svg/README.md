# panda-svg — the rail panda's scenes (src/assets/panda/*.svg)

Muya's sidebar panda (src/redesign/RailPanda.tsx) shows one self-animating SVG per scene as an
`<img>`: no player, no script, plain CSS keyframes inside the file. This folder builds the jointed
ones from text.

```
python3 scenes2.py     # bamboo, tofu, manti, fart, roll  -> out2/
python3 scenes3.py     # angry (click), hello (hover)      -> out3/
node frames.mjs "$PWD/out3/angry.svg" /tmp/angry 0.2 1.0 2.5   # PNG stills at those seconds
```

Copy a finished SVG into `src/assets/panda/` and look at the stills at full size before you do.

| File | What it holds |
|---|---|
| `flat.json`, `parts.py` | The original panda's paths (head, eyes, brows, mouth, body), flattened from "Cute Panda Playing Game". `G` names the groups. |
| `rig.py` | The jointed body: shoulders, elbows, hips and knees with 2-bone IK; `Timeline` keys at 0-100 % of the loop; faces (`eyes_*`, `mouth_*`, `blush`); `build()` writes the SVG and its CSS. |
| `gen.py` | Props in the same style (bamboo, leaves, stars, tofu, mantı, clouds). |
| `scenes2.py` | The busy and idle scenes. |
| `scenes3.py` | The mouse reactions. It adds the angry face (`eyes_angry`, `mouth_angry`, `mouth_shout`) to the rig. |

The scenes that stand (`STAND`) use the 750 x 836 view and show at 58 px, so a reaction swaps in
at the same size as the scene it interrupts.

Credits: "Cute Panda Playing Game" by Abdul Latif and "Panda sleeping on bamboo" by bilal shehzad
(LottieFiles, Lottie Simple License). See src-tauri/resources/THIRD_PARTY_LICENSES.txt.
