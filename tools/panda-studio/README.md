# panda-studio — Muya's rigged panda, animated in Rive

Muya's rail panda (src/redesign/RailPanda.tsx) plays one `.riv` per scene from
`src/assets/panda/rive/`. This folder builds those files from text, with the
[Rive CLI](https://rive.app/docs/cli/getting-started): no editor, no hand-drawn frames.

```
./build_all.sh            # rebuild all 17 scenes and copy them into the app
python3 scenes2.py wave   # rebuild one scene into scene_wave/
python3 render.py scene_wave 2    # -> videos/wave.mp4 (2 loops, white background)
python3 crops.py          # rail crop squares, measured from frames/ (run render.py first)
```

Render previews with a background: `python3 scenes2.py wave FFFFFFFF`, then
`rive scene_wave --screenshot=out.png --advance=1s`. Rebuild with `build_all.sh`
afterwards: the app files must keep a transparent background.

## The rig

| File | What it holds |
|---|---|
| `art/panda.rml` | The artwork as RML: the panda's head (every expression), torso, belly, paws and the bamboo, converted from the artist's SVG by the Rive editor (artboards "Kungfu Panda" and "Faces"). |
| `gen_panda.py` | The rig and the first two scenes. Each arm and leg is ONE tube path skinned to a 2-bone chain (rubber hose: no visible elbow or knee). The paws ride the tip bone, and the feet always point at the floor. A pivoted body node handles moving, tilting and squashing. The thigh and upper-arm bones can stretch (bone `length`). There is FK (`tip`, `body_to_root`), 2-bone IK (`ik`), poses (`P(...)` relative to rest, in degrees) and keyframes with cubic easing. Faces: `eyes = open/shut/happy`, `mouth = grin/open`. It also builds the "bamboo" (splits that shatter two stalks) and "cookie" (parkour, flying kick, catch, eat) scenes. |
| `scenes2.py` | The other 15 scenes, one project each (`scene_<name>/scene.rml`). `build(name, keys, props, extra, size, origin)` adds the panda, props in front of or behind it, and extra tracks. |
| `svg_clean.py` | Turns the 4.1.12 jointed panda SVG into named parts for import (only needed to redo the art). |
| `rivecall.mjs`, `riveexport.mjs` | Call the Rive editor's MCP over HTTP: upload an SVG; export a `.rev`. Used to redo the art. |

## Adding a scene

1. In `scenes2.py`, write a function that returns `build("name", keys, ...)`. Keys are
   `(frame, pose, ease)`, at 60 fps. Start from `GUARD`, `CROUCH` or `LAND`, and use
   `walk_cycle`, `eat_pose`, `chew_keys`, `wobble` or `ik`. Add it to `SCENES`.
2. Look before you trust: run `python3 peek.py out name` (6 frames), and fix what reads wrong.
3. Run `render.py scene_name`, then `crops.py`, and add the scene to `SCENES` in `RailPanda.tsx`
   (artboard size + crop). Add it to `PandaScene`, `SCENE_MS` (its length × loops) and a pool
   in `src/lib/panda.ts`.
4. `./build_all.sh`.

Rules the operator set: the feet never show their soles to the viewer; the paws continue the
arm (same axis, same thickness); props are sized to the panda (bamboo taller than it); arms
open to the side when they hold something at the mouth.

## Redoing the art (rarely)

1. `git show e34775b:src/assets/panda/bamboo.svg > bamboo.svg`
2. `python3 svg_clean.py pow,bw,hL,hR bamboo.svg` → `panda_parts.svg`
3. With the Rive desktop app open: `node rivecall.mjs upload_asset @panda_parts.svg`. Then add
   it to an artboard (MCP `assets_tool addSvgInstance`) and run `node riveexport.mjs rev .`.
4. `rive create art_src --from-rev=<file>.rev`, then copy the artboards you need into
   `art/panda.rml` and update the ids in `gen_panda.py` (`HEAD`, `FACE`, the paw and bamboo ids).

## Credits

The head, body and paws come from "Cute Panda Playing Game" by Abdul Latif and "Panda sleeping
on bamboo" by bilal shehzad (LottieFiles, Lottie Simple License). The limbs are redrawn; the props are
drawn for Muya. See src-tauri/resources/THIRD_PARTY_LICENSES.txt.
