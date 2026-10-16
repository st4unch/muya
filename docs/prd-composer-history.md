# Mini-PRD — ↑/↓ prompt history in the Composer

## 1. Problem
The message box under Control forgets what was sent. The operator wants ↑ to bring back earlier
prompts, like a shell or Claude Code's own input.

## 2. Scope
- Every text sent from the Composer (Enter or the send button) is remembered, newest last.
  Same as the previous entry → not stored twice. At most 200 entries.
- Two lists: agent prompts and shell commands (the Composer's `target`), so a shell command never
  comes back as a Claude prompt and the other way round. Shared by all agents (one list per kind).
- ↑ on the first line of the box shows the previous entry; ↓ on the last line the next one; ↓ past
  the newest restores what was being typed before browsing. Only without Shift/⌘/⌥/Ctrl and when
  no text is selected. Elsewhere ↑/↓ move the caret as usual.
- Editing a recalled entry and sending it stores the edited text; browsing restarts from the newest.
- Kept in `localStorage` (`apex.composerHistory.agent` / `.shell`); unreadable storage = empty history.
- Not in scope: reading Claude Code's own `~/.claude/history.jsonl`, search (Ctrl+R).

## 3. Acceptance criteria
- AC1: Pure helpers `pushHistory` (dedupe last, cap 200) and `stepHistory` (↑/↓ with draft
  restore) — vitest.
- AC2: Composer: send → ↑ shows the sent text; ↑ twice shows the older one; ↓ back to the draft;
  ↑ with the caret below the first line does nothing — vitest (Testing Library).
- AC3: `?mock=1`: type + send two prompts, ↑ recalls them — Playwright, dark + light screenshot.
- AC4: `npx tsc --noEmit`, `npm test -- --run` pass.

## 5. Integration
- `src/redesign/Composer.tsx` `handleKeyDown` (l.61), send button (l.156); used by
  `src/redesign/ControlScreen.tsx` l.267 (`target` = agent/shell).
- localStorage keys follow the existing `apex.*` convention (`src/mock/installMock.ts` l.107).
