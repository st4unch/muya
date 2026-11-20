# muya-switchover

Shared switch / update logic of Muya: manifest + minisign verification, the swap state machine with its rollback,
codesign / Team ID / notarization checks, folder and App-Translocation checks.

History: this was a vendored copy of `crates/muya-switchover` from the classic Muya side (`main`). Classic is frozen at
4.1.22 and no longer rebuilt, so **this copy is now the authoritative one**; the old files (`lib.rs`, `manifest.rs`,
`offer.rs`, `swap.rs`, `sysplatform.rs`, `target.rs`, `verify.rs`, `version.rs`) are unchanged except that `lib.rs`
declares three new modules. Classic's own copy on `main` keeps working because nothing it uses was changed.

Added for Muya 5 (docs/prd-muya-v5-replace.md):

| Module | What |
|---|---|
| `v5` | which kind of Muya a bundle id is (release / legacy `.native` / other), where an update lands (release: in place; legacy: `Muya.app` in the same folder), the build "Return to Muya Classic" installs (pinned URL + sha256), test-only id overrides (feature `e2e`) |
| `feed` | the Tauri updater's `latest.json` (shape, host allow-list, "newer than installed") |
| `launchd` | the launchd labels of a Muya bundle and the detached script that boots old jobs out after a swap |

Cargo feature `e2e` (never in a shipping build; `bundle.sh` refuses a shipping muyad that contains its override strings)
lets a test name throwaway ids, a local feed, a local pinned build and e2e launchd labels through the environment.
