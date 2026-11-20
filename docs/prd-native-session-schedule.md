# Mini-PRD: Native — "Schedule…" on a session + app icon

## 1. What it does
Right-click a session (agents list row, grid panel header "…" menu, Sessions page live row) → **Schedule…** opens the
normal schedule editor, pre-filled for THAT session. At the chosen time/repeat the prompt (or shell command) is typed
into that existing session and submitted. Run history records ok / failed per run.
Second part: the native bundle gets the Muya icon, and the release bundle is "Muya Native" (id without `.dev`).

## 2. Model
`Job.target: Option<TargetSession { id: u64, name, cwd }>` (muya-core `schedules.rs`, camelCase, omitted when none →
old stores load unchanged). `JobInput.target` likewise. With a target the job does NOT start `claude -p`; it types
`prompt` into the session via a host-supplied sender (`ScheduleState::set_session_sender`).

## 3. Behaviour
- Fire (timer or Run now): sender(target, prompt). Ok → run `success`, output "Sent to <name>". Session gone / exited /
  no sender in this process → run `failed` with the reason ("The session “x” is no longer running…"). Never opens a new one.
- muyad (`--scheduler`) installs the sender: checks the session is live, types the text, Enter 150 ms later (same as the
  app's Scheduled Prompt).
- Folder/timeout/bypass/chrome are ignored for targeted jobs (editor hides them).

## 4. UI (native)
Editor reuses ScheduleEditor/ModalParts; session mode: title "Schedule for session", Name pre-filled with the session
name, a read-only "Session" group (name + cwd) in place of Folder, no Options other than On. Card shows "Session: name".
The session menu item "Schedule prompt…" becomes "Schedule…" (the in-memory one-shot sheet stays reachable from the
Schedules page button and the palette).

## 5. Integration (evidence)
- Schedules store/RPC: `schedules.save/list/runs` → `muya-core/src/schedules.rs` (`upsert`, `launch`), `muyad/src/rpc.rs:248`.
- Sender wiring: `muyad/src/scheduler_host.rs::spawn` (owns the Muyad handle); typing uses ptyd `Frame::Input` (`muyad/src/lib.rs send_input`).
- Menu: `FrameWiring.swift sessionMenu(for:)` is the single source for agents row + grid header; Sessions page live-row menu `SessionsPage.menuNeedsUpdate`.
- Protected: Tauri app (`src-tauri/src/schedules.rs`, own copy — untouched), headless jobs unchanged (target None path identical).

## 6. Acceptance
1 target round-trips save→list→save (Rust unit + Swift draft test). 2 fire → sender receives (target, prompt). 3 gone
target → failed run with reason, no new session. 4 live: "echo SCHED" 1 min ahead via right-click on a shell session →
screen shows SCHED, history ok. 5 bundle has icon (CFBundleIconFile + Resources/*.icns); release name "Muya Native",
id `com.staunch.muya.native`; dev unchanged. 6 build.sh 0 warnings, build.sh test + cargo tests pass.
