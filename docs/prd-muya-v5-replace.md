# Mini-PRD: Muya 5.0.0 - Native replaces classic in place

Status: operator decisions 2026-11-19 (option B, version 5.0.0, restore target classic 4.1.22).

## 1. What this is for

Muya Native stops being a side-by-side beta. Version 5.0.0 IS Muya: it lands in the same place as classic
(`Muya.app`), under classic's own identity (`com.staunch.muya`, Team 7PG95YYJ64), so every macOS permission the user gave
classic (Files and Folders, Accessibility, Screen Recording, Full Disk Access, notifications) is still valid. Classic 4.1.22
users get it through the update button they already know. A "Return to Muya Classic (4.1.22)" button undoes it.

## 2. ADR: why the same bundle id

macOS stores a permission against the app's *designated requirement* (identifier + signing team). Classic 4.1.22 says:
`identifier "com.staunch.muya" and anchor apple generic and ... leaf[subject.OU] = "7PG95YYJ64"`. A bundle with another
identifier gets a new requirement, so every prompt would come back. Same id = same requirement = grants carry over.

Cost accepted: no side-by-side install any more (one id = one app), the Native beta id (`com.staunch.muya.native`) becomes a
legacy id that must be cleaned up, and Native and classic now share one preferences domain and one WebKit store.

## 3. Findings that shape the design (all read from code, not assumed)

| Finding | Evidence | Consequence |
|---|---|---|
| The Tauri updater unpacks the `.app.tar.gz`, **strips the first path component** of each entry, deletes the old bundle and moves the new one to the SAME path/name. It verifies only the minisign signature. | tauri-plugin-updater 2.10.1 `updater.rs` macOS `install_inner`, `extract_path_from_executable` | Artifact = `Muya.app` tarball signed with the Tauri updater key; any file name works, the user's folder and file name are kept. No codesign check happens, so the app must be valid on its own. |
| After install, classic 4.1.22 calls `relaunch()`, which **spawns `Contents/MacOS/<CFBundleExecutable of the NEW Info.plist>` directly**, then exits. | tauri 2.11.3 `process.rs` `restart_macos_app`; `src/App.tsx` `runUpdate` | The executable name may differ from `muya`. But the new app is then an orphan whose "responsible process" is the dead classic, and muyad's peer gate **refuses exactly that** (`muya-peer` `refuse_reason`). v5 must re-launch itself through LaunchServices (`open -n`) when it detects this. |
| 4.1.22's update is **user-initiated** (banner, then "Restart"); there is no auto-install and no skip-version preference. | `src/App.tsx` lines 520-545 and 1031-1050 | Returning to 4.1.22 cannot trigger an immediate re-install. 4.1.22 will show the v5 banner again at its next launch; that is the wanted "offered later" behaviour. Nothing to set. |
| Beta (`.native`) apps that are already published verify a downloaded app against the identifier `com.staunch.muya.native`. | `muyad/src/switchover_host.rs` `beta_install` (`expected_id: NATIVE_BUNDLE_ID`), `verify.rs` `WrongIdentifier` | The native-beta pointer **cannot** deliver a `com.staunch.muya` app to them. A **bridge build** (same code, legacy id, version 4.1.27) goes to the native-beta pointer; once running it moves itself to Muya 5.0.0. |
| Classic's scheduler agent is `com.staunch.muya.scheduler`, `BundleProgram Contents/MacOS/muya --scheduler`. | classic 4.1.22 bundle plist | After the swap that path is gone: a broken KeepAlive job. v5 does not ship that plist and boots the job out at first launch. |
| Native's muyad/ptyd agents are `com.staunch.muya.muyad|ptyd` (labels carry no `.native`), `AssociatedBundleIdentifiers` names the bundle id. | `native/scripts/bundle/LaunchAgents/*.plist` | Labels stay; `AssociatedBundleIdentifiers` becomes the release id. |

## 4. Design

**Identity (one bundle script, three flavours).** `native/scripts/bundle.sh` takes `MUYA_FLAVOR`:

| Flavour | Bundle | Id | Used for |
|---|---|---|---|
| `release` (default) | `Muya.app` | `com.staunch.muya` | v5.0.0 |
| `bridge` | `Muya Native.app` | `com.staunch.muya.native` | 4.1.27, only on the native-beta pointer |
| e2e (`MUYA_E2E_ID`) | either | `com.staunch.muya.e2e[.native]` | the throwaway test copies; never the real id |

Dev builds stay `com.staunch.muya.dev`. Executable stays `MuyaNative` (the Tauri relaunch reads `CFBundleExecutable`).

**Delivery to classic 4.1.22.** `Muya-5.0.0-arm64.app.tar.gz` (root `Muya.app/`, no AppleDouble entries), minisig, `latest.json`
in the exact shape `publish-release.sh` writes.

**Native updates itself from `latest.json`** (the same feed), signature checked with the compiled-in updater key.
The old `native-beta` poll is gone from v5.

**Legacy move (bridge and any `.native` app).** Update plan = same folder, file name `Muya.app`, expected id `com.staunch.muya`,
old bundle trashed only after the new one proved itself. The old app's launchd jobs are booted out (labels shared by both
bundles), the `.native` preferences domain is copied into the new domain (keys that are not yet set), classic's scheduler job is
booted out.

**Return to Muya Classic (4.1.22).** Settings button + app-menu item. Pinned in the build: URL of `Muya-4.1.22-arm64.zip`,
its sha256, id `com.staunch.muya`, Team 7PG95YYJ64. Download -> sha256 -> unpack -> codesign + Team + `spctl` notarization ->
swap in place -> launch classic with `--switched-from=native` (classic 4.1.22 writes the handshake marker) -> boot out the v5
agents. Rollback to v5 if classic does not report healthy. Data: nothing to migrate back (Native only copies; classic ignores
`native/` files; `src-tauri/tests/downgrade_native_files.rs` guards this).

## 5. Integration (evidence)

- Swap machine, verification, rollback, folder checks: reused as is (`native/crates/muya-switchover`: `swap.rs`, `verify.rs`,
  `target.rs`, `sysplatform.rs`); only new pure modules are added.
- Classic data migration: reused (`muya-core/src/migrate.rs`, copy-only; `~/.claude/muya-*.json` shared in place). Paths do not
  depend on the bundle id (`Application Support/com.staunch.muya/native/` is already the classic id's folder).
- Peer gate: `muyad/src/main.rs:118` already accepts `APP_ID` and `APP_NATIVE_ID`; v5 connects as `APP_ID`.
- Protection list (must not break): beta self-update of `.native` builds, classic 4.1.22's own switch-to-Native offer, the
  handshake marker, ptyd session re-adoption on muyad restart, notarization gate in `scripts/notarize.sh`.

## 6. Risks

| Risk | Handling |
|---|---|
| No side-by-side install | stated in CHANGELOG; Return-to-classic is the way back |
| Shared preferences domain (classic Tauri + Native in `com.staunch.muya`) | Native stores almost nothing in defaults (checked: no `UserDefaults` keys of its own); legacy copy only fills unset keys |
| Stale Login Items / BTM entries | scheduler and old-bundle jobs booted out; macOS drops entries whose bundle is gone; a "background item added" notice is expected once; NOT verifiable on a synthetic home |
| Updater rollback | the Tauri updater has none; the user keeps the old bundle only in a temp dir that is deleted on success. Native-driven swaps (legacy move, return) keep the old app in the Trash and roll back on a failed handshake |
| Orphaned relaunch refused by muyad | self re-launch through LaunchServices, unit-tested decision + e2e |
| Return target vulnerable to a swapped download | sha256 + Team ID + notarization all pinned/compiled in; URL host allow-list |

## 7. Acceptance criteria (binary)

1. `codesign -d -r-` of the v5 release bundle and of classic 4.1.22 print the identical `identifier ... and anchor ... OU` clause.
2. Release bundle: `CFBundleIdentifier=com.staunch.muya`, name `Muya`, folder `Muya.app`; dev stays `.dev`.
3. A classic-4.1.22 copy, driven by the real Tauri updater code path against a local feed, ends as v5 at the same path with its data
   and with working daemons.
4. v5 -> "Return to classic" ends as classic 4.1.22 at the same path; classic's own updater then offers v5 again (no auto-install).
5. A `.native` bridge copy ends as `Muya.app` in the same folder.
6. After each swap no job label points into the Trash or a missing path (verified with real `launchctl` on e2e labels).
7. Unit tests for target/identity/pin/legacy logic pass; `native/app/build.sh test`, `cargo test --workspace` pass.
8. Artifacts signed with Developer ID, notarized, stapled; tarball signature verifies with the public updater key.
