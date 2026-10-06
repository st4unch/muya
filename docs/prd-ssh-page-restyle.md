# Mini-PRD — SSH page in the app's design + stale "unlocked" fix

## 1. Problem
- The SSH page (Servers / CyberArk / Password Store) predates the v0.4 design. It uses
  Tailwind palette colors (indigo/violet primary buttons, neutral/emerald/rose/amber
  text) instead of the theme tokens, and its own control sizes and labels. It looks
  like a different app next to the Control screen and Settings.
- Bug: the page can show the store as unlocked while agents are told it is locked.
  The 15-minute idle auto-lock emits `muya://vault-locked`, but only the Password
  Store tab listens. SshPage stays mounted, so on any other tab (or another page) the
  lock is missed and the page keeps the stale `store` and `creds`.

## 2. Goal
- The SSH page uses the same tokens and control styles as SettingsModal and the
  Control screen.
- The page's lock state always matches the backend.

## 3. Out of scope
Layout changes and new functions. Other legacy pages (Sessions, Resources, Kanban).

## 4. Acceptance criteria (binary)
- AC1 `SshPage.tsx` and `CredentialPicker.tsx` contain no Tailwind palette color
  classes (indigo/violet/neutral/emerald/rose/amber/…/white/black). Every color comes
  from a `var(--token)`.
- AC2 Primary buttons use `--primary-bg` / `--primary-fg`. Secondary buttons use the
  Settings ghost style (control border + background, 7px radius). Icon-only actions
  are borderless icon buttons. Inputs use `--bg-input` / `--border-control` and an
  accent focus border. Field labels use the Settings label style (11px, uppercase,
  muted). The active tab is underlined in `--text` (no indigo).
- AC3 When `muya://vault-locked` fires while the page shows Servers or CyberArk (or
  the page is hidden), the page re-reads `credstore_status` and clears the credential
  list. The status is also re-read on every tab switch and when the window regains
  focus.
- AC4 Light and dark screenshots of all three tabs (locked and unlocked) are taken
  with the browser mock, and nothing is unreadable or broken.
- AC5 tsc, vitest and `npm run build` are green.

## 5. Integration (evidence)
- Style constants: `SshPage.tsx:99-106` (CARD/INPUT/BTN/BTN_GHOST) and the same
  constants in `CredentialPicker.tsx:19-24`.
- Reference design: `SettingsModal.tsx:16-36` (labelStyle, ghostBtn); tokens in
  `src/styles/tokens.css`; hover rule `.rd-icon-btn` in `src/redesign/redesign.css`.
- Lock event: `credstore.rs:380-385` emits on every lock. The only listener is
  `SshPage.tsx:1011` (StoreTab). The page is kept mounted at `App.tsx:2319`.
- Browser mock: `src/mock/installMock.ts` (`?mock=1`).

## 6. Protection list
Every SSH page function: add/edit/delete server, PSMP profiles, CyberArk logon/list,
store init/unlock/Touch ID/lock/import/export/reveal/copy, and the credential picker.
