---
status: done
prd: docs/prd-launch-at-login.md
started: 2026-10-04
---

## Phase Outputs
- tsc clean; vitest 346/346; cargo test --lib 349 passed; `npm run build` OK; no operator paths.
- Live: isolated dev instance (HOME=/tmp/muyaT; a stand-in `claude` on PATH logs its args); tabs were seeded into the dev instance's own WebKit storage.
  - AC3: Resume ON + a restored tab with a session id → `--resume 1111… --dangerously-skip-permissions` in cwd=/tmp/muyaT, once, with no click.
  - AC4: Resume ON + no Claude tabs → exactly one `claude --dangerously-skip-permissions` in the workspace.
  - AC5: Resume OFF → nothing started.
- Bug found live and fixed: the launch effect ran before the `terminalPtyIdsRef` sync effect, saw no pty and never resumed. It is now declared after the sync.
- Not observed live: the Settings switches clicked in the real window (cua-driver can't see the webview; covered by vitest). The login item only takes effect at the next login. The plist was written for this Mac by hand (same content the app writes) and passes `plutil -lint`.

## Changes
| Date | File | What changed | AC |
|-------|-------|-----------|-----|
| 2026-10-04 | src-tauri/src/login_item.rs (new), lib.rs | LaunchAgent `open -a <bundle>`; resolves the bundle behind translocation; refreshed at startup | AC2 |
| 2026-10-04 | src/components/SettingsModal.tsx, src/lib/startup.ts | Startup group with 2 switches | AC1 |
| 2026-10-04 | src/App.tsx | `resumeTab` extracted; launch effects | AC3-AC5 |

## Decisions
- No tauri-plugin-autostart: adding it bumped tauri (88 lock changes) and npm could not fetch it (TLS). A hand-written LaunchAgent (~40 lines, no dependencies) does the same thing.

## Lessons
