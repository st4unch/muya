---
status: done
prd: docs/prd-control-split.md
started: 2026-10-08
---

## Phase Outputs
- 2026-10-08 phases 1–3: pure helpers + tests (`lib/controlSplit.ts`, 21 tests), visibility layer `inSplit`,
  `SplitArea`, header Split button (wide + collapsed), ⌘⇧D, list pick → focused pane, persistence `muya.splitKeys`.
  Live in a native WKWebView (real mouse/key events, mock backend): 8 panes → button disabled (AC1);
  click pane → highlight + header + keyboard follow, keys reach only that PTY (AC4); list pick replaces the
  focused pane and takes the keyboard (AC5); × closes, agent stays (AC6); Files rail → Control keeps split and
  keyboard (AC7); reload keeps the split (AC8); closing down to one → single slot (AC9); ⌘⇧D adds a pane, no Ctrl+D.
  Suite: frontend 397 ✅, tsc ✅, build ✅. Not live: real Tauri app with 8 real Claude sessions (AC10 done in
  WKWebView with mock PTYs).

## Changes
| Date | File | What changed | AC |
|-------|-------|-----------|-----|
| 2026-10-08 | src/lib/controlSplit.ts (+test) | layout, add/close/place/resolve panes | AC1, AC2, AC5, AC6, AC8 |
| 2026-10-08 | src/lib/terminalVisibility.ts (+test) | `inSplit` layer | AC3, AC7 |
| 2026-10-08 | src/redesign/SplitArea.tsx | panes, native mousedown focus (portals bypass React events) | AC3, AC4 |
| 2026-10-08 | src/redesign/SessionHeader.tsx, icons.tsx, ControlScreen.tsx | Split button + icon, split area wiring | AC1 |
| 2026-10-08 | src/App.tsx | split state, handlers, ⌘⇧D, active-tab gated on pane membership | AC1–AC9 |

## Decisions
- Shortcut ⌘⇧D, not ⌘D: ⌘D already sends Ctrl+D (EOF) to the terminal (`Terminal.tsx` cmdMap).
- Picking an agent already in a pane just focuses it (no swap) — simpler and expected.
- Selected tab counts as visible in split mode only once it is in a pane (else focus fires while it is still pooled).
- 2026-10-08 operator: split inside Control (no Grid screen), up to 8 panes.

## Lessons
- L54: every layer that hides a terminal belongs in `terminalIsVisible` — the split adds one.
- L1: never unmount a terminal; panes only move hosts between slots.
