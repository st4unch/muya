# Mini-PRD — Open at login + resume Claude on launch

## 1. Problem
After the Mac restarts, Muya stays closed until opened by hand, and restored Claude
tabs sit idle until each one is clicked (`activateTerminal`, src/App.tsx:704).

## 2. Goal
Two switches in Settings:
- **Open Muya at login** — Muya starts when the user logs in.
- **Resume Claude sessions on launch** — every restored tab that held a Claude
  conversation rejoins it on startup without a click. If nothing was restored, one
  fresh Claude session opens in the selected workspace (home if none).

## 3. Out of scope
Restoring SSH tabs (stays inert by design, src/App.tsx:160), auto-unlocking the vault.

## 4. Acceptance criteria (binary)
- AC1 Settings shows both switches; each reflects the real current state on open.
- AC2 Turning "Open at login" on creates the macOS launch agent for the running app
  path; off removes it (`autolaunch` plugin `isEnabled` round-trips).
- AC3 With "Resume on launch" on, starting Muya with restored Claude tabs sends each
  tab its own `claude --resume <id>` once, without clicking; the flag clears
  (`needsResume:false`) so a later click does not resume twice.
- AC4 With it on and no restored Claude tab, exactly one Claude tab opens on launch.
- AC5 With it off, behaviour is unchanged (resume on click).
- AC6 No operator paths in shipped code; tsc, vitest, cargo test green.

## 5. Integration (evidence)
- Plugins registered in `src-tauri/src/lib.rs:90-105`; capabilities in
  `src-tauri/capabilities/default.json` → add `tauri-plugin-autostart` the same way.
- Resume command: `resumeCommand` (src/lib/tabs.ts:72) + `applyStatusline`, used by
  `activateTerminal` (src/App.tsx:704) → extract a shared `resumeTab(key)`.
- Restored tabs carry `needsResume` (src/App.tsx:172); pty ids in `terminalPtyIds`
  (src/App.tsx:1196).
- New Claude tab: same spec as `onOpenClaudeHere` (src/App.tsx:2044).
- Settings UI: `SettingsModal.tsx` `Switch` (line 344), preferences in localStorage
  `muya.*` like `muya.gridLayout` (src/App.tsx:376).

## 6. Protection list
Click-to-resume, SSH tab restore, file tab restore, session poll, updater.
