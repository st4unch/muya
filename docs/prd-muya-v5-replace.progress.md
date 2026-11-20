---
status: active
prd: docs/prd-muya-v5-replace.md
started: 2026-11-19
---

## Faz Cikti
- Classic 4.1.22 release zip downloaded; its designated requirement is `identifier "com.staunch.muya" and anchor apple generic ... leaf[subject.OU] = "7PG95YYJ64"`. The Muya 5 release bundle prints the identical clause (AC1).
- Updater mechanics read from tauri-plugin-updater 2.10.1 and tauri 2.11.3 sources (see PRD section 3).
- Throwaway-id e2e (ids `com.staunch.muya.e2e[.native]`, real launchd with e2e labels, real notarization): `native/scripts/e2e-v5.sh`
  classic-update / orphan-control / return / bridge-move all PASS (see the summary file for the output).

## Degisiklikler
| Tarih | Dosya | Ne degisti | AC |
|-------|-------|-----------|-----|
| 2026-11-19 | native/crates/muya-switchover/src/v5.rs, feed.rs, launchd.rs | identity kinds, update target, pinned classic return, `latest.json` parse, launchd hand-over commands | 2,3,4,6,7 |
| 2026-11-19 | native/crates/muyad/src/switchover_host.rs | update from `latest.json`, legacy move, Return to classic (pinned), hand-over, e2e overrides | 3,4,5,6 |
| 2026-11-19 | native/crates/muyad/src/main.rs | e2e build also accepts the throwaway ids at the client gate | e2e |
| 2026-11-19 | native/app/Sources/Logic/V5Logic.swift, App/V5Startup.swift, App/BetaSection.swift, App/Onboarding.swift, App/main.swift, App/UI.swift, App/Dialogs.swift | app name from the bundle, start-up re-launch through LaunchServices, classic scheduler job clean-up, `.native` defaults copy, foreign-service handling, Settings > Updates, app-menu item, confirm dialogs that fit their text | 3,4,5,6 |
| 2026-11-19 | native/scripts/bundle.sh, bundle/Info.plist, bundle/LaunchAgents/*, sign.sh, app/build.sh | flavours release / bridge / e2e, `Muya.app` + `com.staunch.muya`, document types of classic carried over | 1,2 |
| 2026-11-19 | native/scripts/release-v5.sh, publish-v5.sh (not run), e2e-v5.sh | artifacts, publish steps for the release owner, e2e harness | 8 |
| 2026-11-19 | src-tauri/tauri.conf.json, src-tauri/Cargo.toml (+lock), package.json (+lock), CHANGELOG.md | 5.0.0 | 6 |

## Kararlar
- Same bundle id (operator option B). A bridge build (4.1.27, id `com.staunch.muya.native`) is needed because the published beta apps only accept that id from their updater.
- 4.1.22 has no auto-install and no skip-version preference: nothing to set before launching classic; its banner offers 5.0.0 again by design.
- Muya 5 does not ship classic's scheduler LaunchAgent and boots a leftover job out at first launch.
- Old-bundle launchd jobs are booted out from a detached script (the job being booted out is the one that runs the swap); the new app waits for them to be gone before it registers its own.
- A blocking decision was NOT taken: the muyad LaunchAgent still passes `--broker` only (no `--scheduler`), as in the beta. Classic's background scheduler agent therefore stops at the move; schedules fire while the Muya window runs (see the summary, "open points").

## Dersler
- A relaunch by the classic updater leaves the new app an orphan attributed to the dead classic pid; muyad refuses exactly that. Detected by the e2e control (orphan-control), fixed by the start-up re-launch.
