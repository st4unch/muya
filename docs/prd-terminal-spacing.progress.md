---
status: done
prd: docs/prd-terminal-spacing.md
started: 2026-10-05
---

## Phase Outputs
- tsc clean; vitest 358/358 (new: store steps/clamps, popover rows, an open terminal re-spaced live); `npm run build` OK; no operator paths.
- Live (isolated dev instance, saved prefs, `stty size` in its terminal): line 1.0 → 36×85, line 1.6 → 23×85 (36÷1.6≈23), line 1.0 + letter 4 px → 36×57. The setting reaches xterm, and the PTY grid follows it.
- **Not observed:** clicking the popover in a real window. The dev window renders blank to screen capture while it is behind other windows. The click → store → live re-space path is covered by the component tests.

## Changes
| Date | File | What changed | AC |
|-------|-------|-----------|-----|
| 2026-10-05 | src/lib/terminalPrefs.ts | `lineHeight` / `letterSpacing` with clamps and step helpers | AC1 |
| 2026-10-05 | src/redesign/TerminalAppearance.tsx (+test) | `Stepper` row; LINE SPACING and LETTER SPACING rows | AC2 |
| 2026-10-05 | src/components/Terminal.tsx (+test) | xterm built from the prefs; live re-space + refit | AC3 |

## Decisions
- The default stays at 1.6 (today's look) so nobody's terminal changes on update. Users tighten it themselves.
- Line spacing is rounded to tenths so repeated ±0.1 steps don't drift.

## Lessons
