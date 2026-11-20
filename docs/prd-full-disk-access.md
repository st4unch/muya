# PRD: Optional Full Disk Access step (Muya Native)

## 1. Goal
Muya Native has its own bundle id, so macOS asks again per folder (Documents, Desktop, Downloads, ...). Full Disk Access (FDA) ends those prompts in one switch. It also gives every session (Claude included) access to all the user's files, so it is strictly opt-in: a first-run step that can be skipped, plus an always-reachable Settings row. The app can never grant FDA itself; it only deep-links to the pane.

## 2. UX
- First run (real install only, once the background service runs and no other screen is up, FDA not granted, not dismissed): a card "Stop the repeated folder prompts?" with what it does, what it costs, steps, a status pill, and buttons `Show helper apps`, `Not now`, `Open Settings` (primary). Esc = Not now. "Not now" and Done store `fdaStepDismissed`; the step never returns on its own.
- Settings > Privacy: row "Full Disk Access" (bold 13 title, 12 helper, pill Granted / Not granted / Unknown, `Open Settings`) and row "Helper apps" (`Show helper apps`). Built with ModalLayout.settingRow like Beta.
- Status re-read whenever the app becomes active (user returns from System Settings); card/row update live.
- `Open Settings` opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.

## 3. What must be on the FDA list (research)
- Muya Native.app (`com.staunch.muya.native`): the user adds it with `+`. tccd logs show every request has `Sub:{com.staunch.muya.native}` with the responsible process = `muya-ptyd` (or `muyad`) at `Contents/MacOS`, resolved by BUNDLE_ATTRIBUTION to the app bundle. Shells and `claude` started by ptyd inherit ptyd as responsible process, not the GUI app.
- Whether a grant on the bundle covers the LaunchAgent helpers is NOT guaranteed: community reports show helpers launched by launchd instead of by the app lose bundle inheritance (mjtsai.com 2021 "macOS 11.4 breaks Full Disk Access for helper tools"); Orca issue #13921 (stablyai/orca) saw the main-process FDA check say "granted" while the detached helper still lacked it. Apple announced further FDA controls (developer.apple.com/news "Updates to Full Disk Access in macOS", 2026-10-02), so expect UX drift.
- Decision: the step tells the user to add Muya Native first, and says that if status stays Not granted (or sessions still prompt) the two helpers `muya-ptyd` and `muyad` (inside the bundle, `Contents/MacOS`) must be added to the same list too. `Show helper apps` selects them in Finder (falls back to the app in a dev build) so they can be dragged into the pane.
- Status detection: open `~/Library/Application Support/com.apple.TCC/TCC.db` read-only under the passwd home (never `$HOME`). EPERM/EACCES = Not granted, success = Granted, anything else = Unknown. No prompt: FDA is never requested programmatically. The probe runs in the app. A probe inside muya-ptyd (the process whose grant sessions get) needs a new wire message (PROTO_MINOR bump) and a ptyd restart on installed copies; deferred, see section 6.

## 4. Protection list (must not break)
- Login Items onboarding (ServiceGate/OnboardingView) and the restart dialog: FDA step waits while either is up and never shows while `store.problem != nil`.
- Dev stacks / fake HOME / verify scripts: the step is never offered there (`LoginItem.isRealHome`); `MUYA_TEST_FDA` (test hooks build) forces it.
- Vault Touch ID/auto-lock, SMAppService registration, prefs.json format (new key only).
- Settings Save/Close behaviour and existing rows; no daemon, wire or Rust change.

## 5. Integration
`Sources/Logic/FullDiskAccess.swift` (status, offer rule, wording, tested), `Sources/App/FullDiskAccessUI.swift` (model, Settings section, step card), `ServiceGate` in `Onboarding.swift` (offer / dismiss), `SettingsController` (Privacy group). Prefs via `store.prefs`.

## 6. Acceptance / known gaps
- Unit tests for classify/status/offer rule; screenshots dark + light of step and row in a dev mock build.
- Unverified: FDA grant on the bundle actually covering ptyd children (needs the operator's real grant); app-side probe may say Granted while ptyd lacks it. Follow-up: ptyd-side probe over muyad RPC.
