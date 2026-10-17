# Mini-PRD — Right-click menu in terminals and Claude sessions

## 1. Problem
Right-click on a terminal or a Claude session does nothing (the app blocks the webview menu,
`src/main.tsx` l.43). The operator wants the usual terminal actions there: copy, paste and so on.

## 2. Scope
One menu, the same in every tab that runs in `AgentTerminal` (plain terminals, Claude sessions,
SSH tabs). Items, modelled on VS Code's and iTerm2's terminal menus:

| Item | Does | Shown / enabled |
|---|---|---|
| Copy | selection → OS clipboard | enabled only with a selection |
| Paste | OS clipboard → terminal (xterm `paste`, so bracketed paste works) | always |
| Paste as Path | clipboard with spaces and shell characters escaped (iTerm2 "Paste Escaping Special Characters") | always |
| Select All | selects the whole buffer | always |
| Open Link | the selection is an http(s) URL → default browser | only then |
| Find… (⌘F) | opens the in-terminal search | always |
| Clear Scrollback | clears what xterm shows; the running program is not touched | always |
| Bigger / Smaller / Default Text Size | same as ⌘= ⌘- ⌘0 | always |

- Right-click on a path link keeps opening the existing path menu (it wins).
- After an item runs, the keyboard goes back to the terminal.
- Esc or a click outside closes the menu; keys never reach the PTY while it is open.
- Not in scope: split / kill tab from the menu, "Search the web".

## 3. Acceptance criteria
- AC1: Pure helpers `escapeForShell` and `isWebUrl` — vitest.
- AC2: `TerminalContextMenu`: Copy disabled without a selection; Open Link only for a URL;
  each item calls its action and then `onClose` — vitest (Testing Library).
- AC3: `?mock=1`: right-click a terminal → menu shows; Paste writes the mock clipboard to the PTY —
  Playwright, dark + light screenshots.
- AC4: `npx tsc --noEmit`, `npm test -- --run` pass.

## 5. Integration
- `src/components/Terminal.tsx` l.292 `onCtxMenu` (path links), l.395 key handler (⌘F, font keys),
  `stepTerminalFont` from `src/lib/terminalPrefs.ts`. Rendered once for every tab: `src/App.tsx` l.2466.
- Menu parts: `MenuPopover` / `MenuItem` / `MenuSeparator` from `src/redesign/Menus.tsx` (used by
  the agent and workspace menus), portaled to `document.body` so the hidden terminal pool can't clip it.
- Clipboard: `copyToClipboard` (`src/lib/clipboard.ts`), read via `@tauri-apps/plugin-clipboard-manager`
  `readText` (WKWebView's `navigator.clipboard` is unreliable). Mock: `src/mock/installMock.ts` l.575.
- Links: `openUrl` from `@tauri-apps/plugin-opener` (as `src/components/ResourcesPage.tsx`).
