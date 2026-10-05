# Mini-PRD — Terminal line and letter spacing

## 1. Problem
Terminal line height is fixed at 1.6 (`Terminal.tsx`). Claude's output (tables, lists)
looks too airy, and there is no way to tighten it.

## 2. Goal
The terminal appearance popover (the FONT SIZE section) also sets **line spacing** and
**letter spacing**. Like font size, they apply to every open terminal at once and are
remembered.

## 3. Out of scope
Per-tab spacing, the font family, and spacing in Monaco or the markdown viewer.

## 4. Acceptance criteria (binary)
- AC1 `TerminalPrefs` gains `lineHeight` (1.0–2.0, steps of 0.1, default 1.6, which is
  today's value) and `letterSpacing` (0–4 px, whole px, default 0). Out-of-range or
  missing stored values clamp or fall back to the default. Older stored prefs without
  these fields still load.
- AC2 The popover shows LINE SPACING and LETTER SPACING rows with −/+/Reset, like font
  size. − and + are disabled at the limits.
- AC3 A change re-styles every open terminal live (xterm `options.lineHeight` /
  `letterSpacing`), then refits so the PTY gets its new grid. Hidden tabs refit when
  shown.
- AC4 tsc, vitest, `npm run build` are green; colors only via tokens; UI text in English.

## 5. Integration (evidence)
- Store: `src/lib/terminalPrefs.ts` (`validate`, `setTerminalPrefs`, localStorage key
  `muya.terminalPrefs`).
- UI: `src/redesign/TerminalAppearance.tsx` (FONT SIZE row pattern, `stepBtn`).
- Terminal: `src/components/Terminal.tsx:189-196` creates xterm with `lineHeight: 1.6`.
  The live font-size effect (`Terminal.tsx:607-612`) calls `syncRef.current()`, and the
  new effect copies that pattern.

## 6. Protection list
Font size steps and ⌘+ ⌘− ⌘0, color schemes, PTY resize on show (L3).
