# Mini-PRD — Menu bar icon

## 1. Problem
With "Keep running when the window is closed" on (default), the red close button hides
the window (docs/prd-schedules-background.md). Muya then only shows in the Dock; the
operator expected a menu bar icon to see it is still running and to reopen or quit it.

## 2. Scope
- A menu bar (tray) icon, present while the Muya app runs, built from the panda logo
  (`src-tauri/icons/tray-icon.png`, 44 px, readable on light and dark bars).
- Its menu: **Open Muya** (show + focus the window), **Settings…** (show + open the
  Settings modal), **Quit Muya** (quit at once — same cleanup as a confirmed ⌘Q).
- Not in scope: a schedules list in the menu, a setting to hide the icon, `muya --scheduler`
  (it has no UI and stays icon-less).

## 3. Acceptance criteria
- AC1: `cargo build` succeeds with the tray feature; the running dev app shows the icon in the menu bar.
- AC2: Open Muya shows a hidden window; Settings… shows it and emits `menu:settings`.
- AC3: Quit Muya runs the same cleanup as ⌘Q (PTYs, own SSH masters, statusline) and exits.
- AC4: `cargo test --lib`, `npx tsc --noEmit`, `npm test -- --run` pass.

## 5. Integration
- Menu handling: `src-tauri/src/lib.rs` `.on_menu_event` (tray menus are dispatched there too).
- Quit cleanup: existing `"quit"` arm in the same handler → extracted to `quit_now`.
- Window show: existing `RunEvent::Reopen` arm → shared `show_main`.
- Cargo: `tauri` features `tray-icon`, `image-png`.
