---
status: active
prd: docs/prd-native-beta-offer.md
started: 2026-11-12
---

## Faz Çıktıları
- 2026-11-12: PRD written, architect decisions folded in. Worktree `../muya-native-beta-wt` on `feat/native-beta-offer` from local `main` (main has no muya-core, so the shared logic is a new standalone crate `crates/muya-switchover`).
- 2026-11-12: built (crate, Tauri commands, UI, Native side), e2e on synthetic user: happy round trip + badsha/wrongsigner/netcut PASS. Not driven: UI clicks (locked session), sessions-running in the real app, Claude answering (no login in a fake HOME). status stays `active` until the publish step.
