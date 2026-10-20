# Mini-PRD: Rive panda (our own rigged character in the rail)

## 1. Problem
The rail panda is a mix of other people's Lottie clips and an SVG (docs/prd-rail-panda.md). They
are fixed films: the character changes between scenes, nothing can be added or adjusted, and the
operator asked for a panda of our own that can learn new moves. A rigged panda was built in Rive
(tools/panda-studio) with 17 scenes; the rail should play those instead.

## 2. Scope
- In: play the 17 Rive scenes in the rail with the Rive web runtime (`@rive-app/canvas-lite`,
  MIT); new scene pools per mood; drop the Lottie scenes, lottie-web and the old SVG; keep the
  teacher's status board (HTML over the scene); credits; the generator in `tools/panda-studio`.
- Out: data-bound text inside the .riv (the board stays HTML), clicks on the panda, any release.

## 3. Acceptance criteria
- AC1: each of the 17 scenes loads in the rail and draws (canvas not blank) in the mock UI, in
  dark and light, with no console error.
- AC2: busy → teacher first (board shows Claude's verb), then gaming/cookie/bamboo/dance/
  traveller/business in turns; busy → idle plays `celebrate` once; idle takes turns among
  wave/flip/bow/roll/fart/bamboo_eat/tofu_eat/manti; 5 quiet minutes → `sleep`.
- AC3: no scene twice in a row unless it is the mood's only one (unit test).
- AC4: the runtime and the wasm load from the app bundle (no CDN request); the app CSP allows
  wasm compilation (`'wasm-unsafe-eval'`) and nothing else new.
- AC5: nothing runs while the panda is hidden, switched off or the window is hidden (one Rive
  instance at most, cleaned up on scene change/unmount).
- AC6: `npx tsc --noEmit`, `npm test -- --run`, `npm run build` pass; `lottie-web` is gone from
  package.json.

## 4. Design
- `src/assets/panda/rive/<scene>.riv` (built with `rive <scene> --once`, unsigned, no scripts).
- `src/redesign/RivePanda.tsx`: lazy `import("@rive-app/canvas-lite")` + `rive.wasm?url`,
  `RuntimeLoader.setWasmUrl`, one `Rive` per mounted scene on a DPR-sized canvas, `Fit.Contain`,
  bottom-aligned, crop box per scene (`Layout` minX/minY/maxX/maxY) so the panda fills the rail.
- `src/lib/panda.ts`: new `PandaScene` union, `SCENE_MS` from each scene's length × loops, new
  pools; `firstScene`/`nextScene`/`boardText` keep their contracts.

## 5. Integration (evidence)
- Rail mount point: `src/redesign/RailPanda.tsx:172` (LottiePanda) and `:159-170` (sleep <img>);
  the board: `RailPanda.tsx:34-54`, shown when `scene === "teaching"` at `:158`.
- Scene logic: `src/lib/panda.ts:28-38` (union), `:52-62` (SCENE_MS), `:67-71` (pools), `:74-77`
  (firstScene); tests `src/lib/panda.test.ts:24-80`, `src/redesign/RailPanda.test.tsx`.
- CSP: `src-tauri/tauri.conf.json:25` (`script-src 'self'` → add `'wasm-unsafe-eval'`).
- Credits: `src-tauri/resources/THIRD_PARTY_LICENSES.txt:11-16`.
- Settings switch `pandaEnabled` and the quiet/sleep timer are unchanged (`panda.ts:10-26`,
  `RailPanda.tsx:69-104`).

## 6. Protection list
Panda switch in Settings, sleep-after-5-minutes, hidden-window pause, rail layout (min height
72 px), the teacher's board text, and everything outside the rail.
