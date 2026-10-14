# Muya — project rules for Claude

## UI and design (L65, enforced)
- Build every new dialog, form or settings row from `src/components/modalKit.tsx` (ModalShell, Segmented, Switch, and the label/helper/input/button styles), the same parts SettingsModal uses. Copy SettingsModal's row markup: bold 13px title, helper line, control on the right.
- Never mix style systems (for example `sshStyles` together with modalKit). Colors only via `var(--token)`. UI text in English.
- Before saying a UI change is done:
  1. Add mock handlers in `src/mock/`.
  2. Open `http://localhost:1420/?mock=1` with Playwright, in both dark and light.
  3. Look at the screenshots and compare them with SettingsModal.

## Running and testing
- Never kill the host Muya (`/Users/<you>/Desktop/Muya.app`). Only `target/debug/muya` dev instances may be stopped, by that path. Run dev instances with a fake `HOME`.
- `cargo build` copies the prebuilt `binaries/muya-ssh-mcp-*`. Run `cargo build --bin muya-ssh-mcp` before testing the sidecar.
- Check full suites before a release: `cargo test --lib` (in src-tauri), `npx tsc --noEmit`, `npm test -- --run`.

## Release
- **Version = one patch step above the last release** (4.1.1 → 4.1.2), even for big features. Minor/major only when the operator asks (`MUYA_VERSION_BUMP=minor|major`). Run the `release-version-check` agent or `bash scripts/check-version.sh` before bumping and building. The release scripts and the project hook (`.claude/hooks/release-version-guard.sh`) refuse a wrong number (L67).
- Bump the version in `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml` and `package.json`, and add a `CHANGELOG.md` entry.
- Bump `claude-plugin/muya-mcp/.claude-plugin/plugin.json` when the skill docs change.
- Then run `bash scripts/build-sign-notarize.sh` and `bash scripts/publish-release.sh` (on main).
- New features need a mini-PRD (`docs/prd-<feature>.md` + `.progress.md`) before code.
