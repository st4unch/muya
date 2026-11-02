# Mini-PRD — smooth terminal and screen switching

## 1. Problem
Switching sessions, Control ↔ Grid, and focus / restore of a split pane stutter. Measured
in WebKit (mock app, 3 sessions): click → second painted frame median 95 ms, worst frame
~52 ms. Every time a terminal is shown it builds a new WebGL renderer (new GPU context,
shaders, glyph atlas, full redraw) and every hide throws it away
(`src/lib/webglRenderer.ts`, `Terminal.tsx` `active` effect). The new view also appears
in one hard cut.

## 2. Outcome
- Switching back to a recently used terminal reuses its renderer: no rebuild, no blank frame.
- The incoming terminal / screen fades in briefly (≈140 ms, opacity only) instead of a hard
  cut; nothing animates when macOS "Reduce motion" is on.
- Click → second frame median at least 30% lower than the 95 ms baseline in the same
  WebKit measurement (`scratchpad/switchperf.mjs`), worst frame lower too.

## 3. Scope
- In: WebGL renderer reuse (warm pool), the `active` show/hide path in `Terminal.tsx`, a
  fade-in class for the terminal slot / split panes / grid panels / page switch.
- Out: terminal scrollback size, xterm upgrade, Monaco editor, window resize animation.

## 4. Behaviour
- `webglRenderer.ts`: `park(lease)` on hide keeps the context alive in a most-recent-first
  list of hidden renderers, capped at `WARM_HIDDEN = 6`; the oldest beyond the cap is
  suspended (today's behaviour). `unpark(lease)` on show. `release()` also unparks.
  Visible + warm stays under WebKit's 16-context cap (grid shows at most 9).
- `Terminal.tsx`: hide → `park` instead of `suspend`. Show → if the lease is still live,
  unpark and fit at once (layout effect, before paint); otherwise today's rAF re-acquire.
- Fade: CSS keyframes `muya-fade-in` (opacity .55 → 1, 140 ms ease-out) on the element
  that becomes visible; `@media (prefers-reduced-motion: reduce)` turns it off.

## 5. Integration (evidence)
- Lease API: `src/lib/webglRenderer.ts:19-67` (`acquireWebgl`, `suspend`, `release`).
- Show/hide: `src/components/Terminal.tsx:131-145` (`attachRenderer`), `:631-647` (`active`
  effect), unmount release `:627`.
- 16-context cap history: comment at `Terminal.tsx:315-316`.
- Views: `src/redesign/SplitArea.tsx`, `GridScreen.tsx`, `ControlScreen.tsx`; pages are
  kept mounted and hidden (L1), so a fade must key on becoming visible, not on mount.

## 6. Protection list
PTY never killed on hide (L1); focus goes only to the picked terminal (focusToken);
GPU-loss retry (3×) then DOM fallback; resize while hidden refits on show (L3);
split focus / restore, drag-to-group, Grid full screen.

## 7. Acceptance criteria
- AC1: unit test — parking 7 leases suspends exactly the oldest one; unpark removes from
  the list; release of a parked lease unparks it.
- AC2: `switchperf.mjs` in WebKit: median click → second frame ≤ 66 ms (−30%).
- AC3: fade class present on the shown terminal slot and absent under reduced motion
  (CSS rule check), screenshots dark + light show no blank/black terminal after a switch.
- AC4: tsc clean, npm tests and cargo tests pass.
- AC5: real debug build with cua-driver: switch between 3 sessions, terminal text visible
  right after each switch (when the display is awake).
