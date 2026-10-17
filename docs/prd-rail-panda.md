# Mini-PRD — The panda in the sidebar

## 1. Problem
The left rail has empty space between Schedules and the Settings gear. The operator wants a moving
panda there that reacts to Claude: lazy while nothing runs, busy while agents work.

## 2. Scope
- A small SVG panda (black/white, theme tokens) living in the rail's empty space, scenes in turn:
  - **Idle (no agent working):** eats bamboo · somersaults between bamboo stalks · the bamboo
    disappears and it sleeps (Zz) · rolls down a hill like a ball · kung-fu chops a stalk.
  - **Working (any agent working):** wakes up with a stretch, then breaks bamboo, smashes stones,
    eats tofu, kung-fu chops — in turn.
- Click the panda → it does a trick right away.
- Hidden when the space is too short (< 96 px). `prefers-reduced-motion` → still panda, no motion.
  Animations stop while the window is hidden. CSS transforms only (GPU), no timers faster than the
  scene switch (~every 6 s).
- Settings → Appearance → "Panda in the sidebar" switch (on by default), saved per Mac.
- Not in scope: sounds, panda in other places, per-agent pandas.

## 3. Acceptance criteria
- AC1: `pandaScenes(busy)` / `nextScene` pure helpers: idle list, busy list, wake first on idle→busy
  — vitest.
- AC2: RailPanda renders the scene for `busy`, hides under 96 px, honours the switch — vitest.
- AC3: `?mock=1` Playwright WebKit: panda visible in the rail in dark + light, idle and working;
  screenshots of several scenes.
- AC4: tsc + full test suites pass.

## 5. Integration
- `src/redesign/Rail.tsx` (flex spacer before Settings), rendered from `src/App.tsx` (`<Rail active=… />`).
- Busy = some agent VM has status "working" (`agentVMs` in App, same data the agent list uses).
- Colors: new tokens in `src/styles/tokens.css` (both themes). Switch row from `modalKit` in
  `src/components/SettingsModal.tsx` Appearance group; pref in localStorage `apex.panda`.
