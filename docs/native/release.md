# Native release prep (Faz 5 prep, 2026-11-04)

Scripts live in `native/scripts/`. Everything here is local and ad-hoc: nothing was notarized, uploaded or signed with a real identity.

## Order of a release

| # | Step | Command | Status |
|---|---|---|---|
| 1 | Notices regenerated | `native/scripts/notices.sh` | done (349 rows) |
| 2 | Licence check | `native/scripts/licence-check.sh` | done: 348 components, 0 copyleft, 0 unknown |
| 3 | Assemble `Muya.app` | `native/scripts/bundle.sh` | done |
| 4 | Sign inside-out | `native/scripts/sign.sh` (ad-hoc) / `MUYA_SIGN_IDENTITY=... sign.sh` | ad-hoc done; real identity NOT run |
| 5 | Notarize + staple | (see `spikes/hello-bundle/build.sh --notarize`) | operator |
| 6 | Sparkle key + appcast | not set up yet | operator |
| 7 | Gatekeeper on a clean second user | `spctl -a -vvv -t exec Muya.app` | operator (needs a second macOS account) |

## Signing order (sign.sh)

1. `muya-ptyd` (`com.staunch.muya.ptyd`) 2. `muyad` (`.muyad`) 3. `muyactl` (`.muyactl`) 4. `muya-ssh-mcp` (`.mcp`)
5. Sparkle helpers (XPC services, Autoupdate, Updater.app, deepest first; the loop is in place, no framework is bundled yet)
6. The app (`com.staunch.muya`).

Each executable keeps the identifier `muya-peer` expects (`APP_ID`, `PTYD_ID`, ...): the peer gate matches identifier plus our Team ID, so re-signing under another identifier breaks the sockets. Hardened runtime on everything; entitlement files (`bundle/app.entitlements`, `bundle/daemon.entitlements`) are empty on purpose, add an entitlement only with a measured need.

## Bundle layout (bundle.sh)

`Contents/MacOS/{MuyaNative, muya-ptyd, muyad, muyactl, muya-ssh-mcp}`, `Contents/Library/LaunchAgents/com.staunch.muya.{ptyd,muyad}.plist` (`BundleProgram`, `ProcessType=Interactive`, `ThrottleInterval=1`, `AssociatedBundleIdentifiers=com.staunch.muya`, from the S2 spike measurements), `Contents/Resources/THIRD_PARTY_NOTICES.md`.
Rust builds go to `native/target-release` (release, `--locked`, paths remapped); the sidecar is built from `src-tauri` into `native/target-release/sidecar` (~3 min cold).

## What was run

- `bundle.sh`: builds. Its leak gate (`strings | grep /Users/`) first FAILED on the prebuilt `src-tauri/binaries/muya-ssh-mcp-*` (cargo registry paths from the home directory); bundle.sh now builds the sidecar with path remapping instead. The prebuilt copy must not be shipped.
- `sign.sh` (ad-hoc): `codesign --verify --deep --strict` passes ("valid on disk", "satisfies its Designated Requirement"); flags `adhoc,runtime`, no Team ID. `spctl -a -vv` = **rejected**, as expected for ad-hoc.
- Launch test with a temp HOME and temp sockets: bundled `muya-ptyd`, `muyad`, `MuyaNative` started by hand, two sessions created and a command typed through the app, the sidebar listed both from the bundled daemons (`release-bundle-launch.png`, no user name visible); all three processes stopped by PID. Ad-hoc daemons log "unsigned build — accepting same-user peers", so the identifier + Team ID gate is only exercised with a real signature (see operator list).

## Licences

No GPL/AGPL/LGPL in the cargo graph (cargo metadata, all platforms, 348 crates); `webpki-roots` is CDLA-Permissive-2.0 (added to the allow list). The Swift app has no packages. Ghostty core, Highway, simdutf and Zig compiler_rt are listed by hand. The ADR note (Muya may move to GPL-3.0 if STTextView is chosen) is therefore the only copyleft question, and it is undecided: re-run `licence-check.sh` after that choice, it reports copyleft entries explicitly.

## Needs the operator

- Developer ID identity: `MUYA_SIGN_IDENTITY="Developer ID Application: ..." native/scripts/sign.sh` (adds `--timestamp`), then notarize with the `apex-notary` keychain profile and staple.
- Re-run the peer-gate checks (identifier + Team ID, getsid refusal) on the real-signed bundle (AC6 note in the progress doc).
- `spctl` on a clean second macOS account; SMAppService approval states (S5).
- Sparkle EdDSA key and appcast; then add the framework and sign its helpers (step 5 of the order).
- STTextView / licence decision.
- Bundle id is `com.staunch.muya` (matches `muya-peer`); the app's `Info.plist` in `native/scripts/bundle/` is the release one, `native/app/Info.plist` stays the dev one.
