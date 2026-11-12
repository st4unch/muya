# Mini-PRD: "Try the Muya Native beta" offer (classic → Native, and back)

- Date: 2026-11-12
- Type: mini-PRD (new feature, operator-approved scope)
- Architect review: `software-architect` (opus), 2026-11-12 — decisions folded in below.

## 1. What it is for (plain words)
Classic Muya (the Tauri app) offers its users the new Muya Native app. If they say yes, Native
**replaces** classic: it is downloaded, checked, installed, classic goes to the Trash (never
deleted), Native opens. Everything they set up is there. A "Switch back to classic" button in
Native undoes it. Native updates itself afterwards.

## 2. Operator decisions (binding)
- REPLACE, not side by side. Classic is moved to the Trash (recoverable).
- Ask once after the normal update flow: **Try it / Not now / Don't ask again**. Same offer in
  Settings → Beta (modalKit rows) for later.
- Native ships as a GitHub **prerelease**. A classic patch release carries the offer.
- Publish is the last step and needs the main session's go. Nothing is pushed by this work.
- No telemetry. Only GitHub downloads leave the Mac.

## 3. Design decisions (architect + code grounding)
| # | Decision |
|---|----------|
| G | **One shared pure crate `crates/muya-switchover`** (std + serde + sha2 + minisign-verify; no Tauri). Classic depends on it by path (`src-tauri/src/switchover.rs` = Tauri commands). Native (branch wip/native-rewrite) depends on the same crate from muyad; SwiftUI only draws dialogs. One implementation of verify/swap = one place to get wrong. Sparkle rejected (second update-verification path). |
| a | **Manifest** `native-beta.json` + detached minisign signature `native-beta.json.minisig`, signed with the existing Tauri updater key (public key already in `tauri.conf.json`). Fields: `schema:1, channel:"beta", version, build, pub_date, url, size, sha256, minClassicVersion, minMacos, notes`. `url` must be `https://github.com/st4unch/muya/…` (or `objects.githubusercontent.com`). **Team ID (7PG95YYJ64) and bundle ids are compiled-in constants, never read from the manifest.** |
| a2 | **Offer decision** is a pure function `offer::decide(input) -> Hidden(reason) \| Offer \| AlreadyInstalled`. Hide if: signature invalid; classic < `minClassicVersion`; manifest version ≤ installed Native version (never an older beta). On the after-update trigger also hide if "Don't ask again", or "Not now" less than 14 days ago for the same version; show at most once per version. Settings trigger ignores dismissal. State: `~/Library/Application Support/com.staunch.muya/native-offer.json`. |
| b | **Swap** (module `swap`, steps recorded in `switch.json` for crash recovery): refuse if classic runs translocated → stage in `~/Library/Caches/com.staunch.muya/switchover/<ver>/` → download off the UI thread with progress events → sha256 of the zip → `ditto -x -k` → verify the app: `codesign --verify --strict --deep`, designated requirement `anchor apple generic and identifier "<id>" and certificate leaf[subject.OU] = "7PG95YYJ64"`, `spctl -a -t exec -vv` must say accepted + Notarized Developer ID → only then drop quarantine → move existing Native (if any) to Trash → atomic rename into `/Applications` → launch Native with `--switched-from=classic` → wait ≤30 s for Native to write `native_healthy` in `switch.json` → move classic to Trash with `NSFileManager trashItemAtURL` (recoverable, "Put Back" works; never `rm`) → quit classic. **Any failure before the healthy handshake: the staged/installed Native is trashed, classic is untouched, a clear error is shown.** |
| c | **Live sessions**: `switch_preflight()` returns `pty_live` (terminals that die when classic quits), `agent_running` (from the existing `list_agent_sessions`, resumable in Native), `dirty_editors` (from the frontend). The dialog says "N sessions are running; they will be closed" and offers **Switch now** / **Not now** — never silent. |
| d | **Data carry-over** — see §4. Almost everything is already shared in place; only localStorage-held UI state is copied (existing `migrate.rs`). Keychain Touch-ID item is *not* shared (access rules tied to classic's signature): Native asks the user to unlock once with the master password (the user's own unlock) and creates its own item. Nothing is decrypted/re-encrypted outside a user unlock. |
| e | **Switch back** (Native → classic): if `switch.json.trashed_url` still exists and verifies (id `com.staunch.muya`, Team ID, spctl) restore it; otherwise download `releases/latest/download/latest.json`, verify its minisign signature + the tarball, then the same verify+swap mirrored. Native goes to the Trash. |
| f | **Native self-update**: same crate, same verify rules. Immutable release `native-v<ver>` holds the zip; a rolling prerelease tag `native-beta` holds only `native-beta.json` + `.minisig`, uploaded last. Poll at launch + every 6 h with ETag. Published with `--prerelease --latest=false` so classic's `releases/latest/latest.json` is untouched. A separate publish script is used (`publish-release.sh` has neither flag). |
| g | **Telemetry/privacy**: none. Requests go only to github.com / objects.githubusercontent.com. |

## 4. Data carry-over table
| Store | Where | Native on first launch | Test |
|---|---|---|---|
| Workspaces, tabs/layout, merge queue/kanban, UI flags | WebKit localStorage (`apex.*`, `muya.*`) | copied once into `native/ui-prefs.json` by `migrate.rs` (classic untouched) | existing migrate tests + e2e |
| Settings, app prefs | `~/.claude/muya-settings.json`, `muya-app.json` | read in place | e2e |
| Schedules (+runs, status, requests) | `~/.claude/muya-schedules*.json`, `muya-schedule-runs/` | read in place; LaunchAgent `com.staunch.muya.scheduler` shared | e2e |
| SSH servers | `~/.claude/muya-ssh-config.json` | in place | e2e |
| Vault config / entries | `muya-vault-config.json`, `muya-ssh-vault.enc`, prefs | in place; key in Keychain `com.staunch.muya.vault` — unlocked by the user once in Native | e2e: unlock prompt shown, no silent decrypt |
| Saved sessions / history / scrollback | `Application Support/com.staunch.muya/session-archive`, `term-history` | in place | e2e |
| Login item / background service | `login_item`, `bg_service` | re-registered for Native on first launch | e2e |
Known limit: UI prefs changed in Native do not flow back to classic (migrate is one-way).

## 5. Integration (existing code this hooks into)
- Updater UI: `src/App.tsx` `runUpdate` (~L1021) and the `check_update` menu event (~L999); progress strip. The offer appears **after** the normal update flow finishes with "up to date" or after an install is declined — it never interrupts an update.
- Settings: `src/components/SettingsModal.tsx` rows built from `modalKit.tsx` (`rowsBox`, `rowStyle`, `Switch`, `ghostBtn`) — a new "Beta" group.
- Rust: `src-tauri/src/lib.rs` registers commands (`invoke_handler`); trash helper pattern already exists (objc2-foundation `NSFileManager`) for sessions; `app_location.rs` provides the translocation check.
- Native: `native/crates/muyad` hosts the same crate; Swift `ModalParts.swift` (`settingRow`, `rowsBox`) for the Settings > Beta rows.
- Release: `scripts/check-version.sh`, `build-sign-notarize.sh`, `publish-release.sh` unchanged; new `scripts/publish-native-beta.sh`.

## 6. Acceptance criteria (binary)
- AC1 `offer::decide` unit tests cover: sig-invalid, classic too old, older/equal beta, after-update once-per-version, not-now 14 d, dismissed forever, settings ignores dismissal, already installed.
- AC2 Manifest parser rejects: wrong schema, non-https/foreign host url, bad sha256 length, missing fields, bad signature.
- AC3 Verify unit tests: bad sha → no swap; wrong Team ID output → no swap; spctl rejected → no swap; ad-hoc signed app → no swap.
- AC4 Swap state machine tests (fake ops): failure at each step leaves classic untouched; healthy-handshake timeout rolls back; crash recovery from `switch.json`.
- AC5 Classic UI: offer dialog (once), Settings > Beta rows, progress, error, sessions warning — screenshots dark+light, looked at.
- AC6 Native: Settings > Beta (Switch back, Check for beta update), first-launch Keychain notice, self-update using the same crate.
- AC7 Full suites green (cargo test --lib, tsc, vitest, vite build, native build.sh test, cargo test -p muyad -p muya-ptyd).
- AC8 END-TO-END on a synthetic user (fake HOME, Finder PATH, temp "Applications", local HTTP server serving manifest + notarized Native zip): offer once → Try it → classic in Trash, Native launches → workspaces/settings/schedules/SSH list present → New agent answers → Switch back restores classic with data. Failure paths: bad sha, wrong signer, network cut mid-download, sessions running.
- AC9 No `/Users/…` path in committed files; no push.

## 7. Protection list (must not break)
Normal update flow (`runUpdate`, `check()`), `latest.json` / `publish-release.sh` (classic channel untouched), the shared `~/.claude/muya-*.json` formats, vault encryption and Keychain item `com.staunch.muya.vault`, the host Muya and the operator's `~/Desktop/Muya Native.app` (never touched by tests), the wip/native-rewrite working state of the main tree.

## 8. Risks
1. Keychain item access across two signing identities → mitigated by the master-password unlock notice; tested. 2. Classic quits before Native is healthy → handshake + trash only after healthy. 3. Native published as "latest" → separate script, `--latest=false`, tag prefix `native-v`. 4. Ad-hoc Native passes sha but must fail Team ID → unit + e2e test. 5. Settings drift on switch-back (documented).
