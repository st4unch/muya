---
status: done
prd: docs/prd-menubar-icon.md
started: 2026-10-15
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-15 | src-tauri/src/lib.rs | build_tray + tray_* menu arms; show_main/quit_now shared with Dock reopen and ⌘Q | AC1-AC3 |
| 2026-10-15 | src-tauri/Cargo.toml | tauri features tray-icon, image-png | AC1 |
| 2026-10-15 | src-tauri/icons/tray-icon.png | 44 px panda, (R) mark removed | AC1 |
| 2026-10-15 | SettingsModal.tsx, README.md | helper text mentions the menu bar icon | — |

## Doğrulama (dev instance, fake HOME, AX-driven)
- Tray menu read via AX: Open Muya / Settings… / --- / Quit Muya; tooltip "Muya".
- Red close → 0 windows, process alive → Open Muya → 1 window.
- Hidden → Settings… → window frontmost, Settings modal open (screenshot).
- Quit Muya → dev process exited; host Muya untouched.
- cargo test --lib 393 ok · tsc clean · vitest 441 ok.

## Kararlar
- Colored panda icon, not a template image: a one-color silhouette of the panda was an unreadable blob at 22 pt; the black-and-white logo reads on both bar colors.
- Tray Quit skips the ⌘Q double-press guard: the window may be hidden, so the "press again" hint would never be seen.

## Dersler
