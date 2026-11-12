---
status: active
prd: docs/prd-native-beta-offer.md
started: 2026-11-12
---

## Faz Çıktıları
- 2026-11-12: PRD written, architect decisions folded in. Worktree `../muya-native-beta-wt` on `feat/native-beta-offer` from local `main` (main has no muya-core, so the shared logic is a new standalone crate `crates/muya-switchover`).
- 2026-11-12: built (crate, Tauri commands, UI, Native side), e2e on synthetic user: happy round trip + badsha/wrongsigner/netcut PASS. Not driven: UI clicks (locked session), sessions-running in the real app, Claude answering (no login in a fake HOME). status stays `active` until the publish step.

## 2026-11-12 — Native takes classic's place (operator: "masaüstümde muya yoktu artık")
- Defect: the switch installed `/Applications/Muya Native.app` and trashed the classic app from wherever it ran (Desktop), so nothing was left where the operator launches Muya.
- Decision: **in place**. `target_app == source_app`: Native is installed at the exact path of the running classic bundle (same folder, same file name — read from the running bundle, never hard-coded), so Dock, Finder, Spotlight and Login Items keep pointing at it. Bundle identity is the bundle id (`com.staunch.muya.native`), not the file name; the menu bar / About show "Muya Native".
- Swap order in place: verify staged Native → classic to Trash (a running bundle may be moved) → install Native at the same path → launch → handshake → Done (`trashedSource` = that Trash entry). A failed handshake terminates only the new bundle's main executable (not a prefix match: the classic process still has the same path in its command line), trashes it and restores classic. Switch back is the mirror: classic is restored from the Trash to `from_path`; with no switch history it goes next to the running Native as `Muya.app`.
- Code: `crates/muya-switchover/src/swap.rs` (`in_place`, `Platform::terminate_launched`), `sysplatform.rs`, `src-tauri/src/switchover.rs` (`native_target`). Older installs that put Native in `/Applications/Muya Native.app` are still found by the offer check.
- Proof: unit tests (in-place order, rollback never uses the broad terminate) + `scripts/e2e-native-beta.sh happy` with a throwaway `Desktop/` folder: classic → Native lands at `Desktop/Muya.app` (bundle id native, no `Muya Native.app`), data intact, switch back restores classic at the same path.
