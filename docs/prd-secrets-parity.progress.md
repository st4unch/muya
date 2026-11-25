---
status: active
---
# Progress — secrets parity (branch fix/secrets-parity, worktree scratchpad/wt-secrets)

Build env: `export PATH=/opt/homebrew/opt/zig@0.15/bin:$PATH; eval "$(native/scripts/ghostty-env.sh)"`. src-tauri needs `src-tauri/binaries/muya-ssh-mcp-aarch64-apple-darwin` (gitignored; copy from the main checkout) before `cargo build --bin muya-ssh-mcp`.

## Done (committed)
- Req 2a: `get_secret` result + MCP description carry a usage hint (`secret_refs::USAGE_HINT`): http_request, run_with_secrets env/stdin curl example, `muyactl secret exec --env API_KEY=NAME -- …`. run_with_secrets and muyactl exist and work.
- Req 2b: `http_request` broker op + sidecar tool (method/url/headers/body/timeout; https only, http for localhost; no redirects; reply redacted; audit log without values). Unit tests in broker.rs.
- Req 2c: SKILL.md updated, plugin.json 1.0.12, `tools-list.json` snapshot regenerated (ac4 byte-identical).
- Req 1 daemon: new RPCs `vault.reveal`, `vault.save` (add/edit with username+group, keeps key passphrase), `vault.remove`; `vault.add` accepts username/group (muyad/src/rpc.rs).
- Req 1 app: `SecretMeta` keeps id/username/group; Password Store pane has Name/User/Group/Kind/Value/Description, Show (30 s auto-hide), Copy (clipboard cleared after 30 s), Edit (form opens with stored value, all fields), Delete (confirm), Lock; kind list has api_key; filter covers user/group; sorted by group. Fixed the old Update bug (Swift sent `label`, daemon wanted `reference`; now everything goes through vault.save).
- Tests: Swift 330/0 (`native/app/build.sh test`); real-muyad e2e `native/crates/muyad/tests/secrets_parity.rs` PASSES (init, save with group, list, reveal, edit, add, remove, add_secret→get_secret→http_request 200 against a local auth server, run_with_secrets curl 200, no plaintext in any result, lock).
- Mock-mode screenshots (test values) in scratchpad/secrets-parity-shots (store-revealed / store-edit, dark+light).
- Dev-harness: run-dev.sh now passes MUYA_TEST_EXPECT_*/AUTOTAKEOVER/REREGISTER/JOBLOADED stubs; debug command `ssh-secret`; mock mode routes vault/ssh RPCs to FakeSSHRpc.

## In flight / uncommitted at time of writing
- Selection-preserving redraw in VaultPane (built, tests 330/0) and Mock.swift routing: commit them.

## Left
1. BLOCKER for GUI e2e with the real daemon: the dev app (run-dev.sh start) never connects to muyad ("Starting the background service…", app has no fd to muyad.sock) even with the stubs; control script verify-vault-unlock.sh fails the same way on this branch (probably from takeover commit 1841327 or dev-stack identity gating; unverified whether baseline passes). Needed for `native/app/verify-secrets-parity.sh` (written, not yet passing) — the old-vault-in-the-GUI proof with classic-vault helper (helper now takes `add <label> <secret> [group] [user]`).
2. `muyactl secret exec` end-to-end not run (needs a real Claude-session ancestor).
3. Visual comparison with classic mock (`npm run dev`, ?mock=1) screenshots; Native is still a table, classic uses cards — decide how far to go.
4. Fill the parity table statuses (the audit file lists the gaps; most are now closed), Touch ID enable/disable buttons + import/export/rekey are NOT done.
5. Run `cargo test` (native workspace) fully; CHANGELOG [5.0.2] lines; git-verify; final report.

## Update (resumed) — state at commit after 7c55c4f
- DONE: classic-made vault (classic's ORIGINAL credstore code via native/tools/classic-vault, fake HOME) opens in real muyad and lists with user+group, reveals (test `a_vault_made_by_classic_opens_and_shows_its_entries`; both secrets_parity tests pass). `cargo test --workspace` green (one flaky ptyd fd test passed on rerun), `native/app/build.sh test` 330/0. CHANGELOG [5.0.2] lines added.
- STILL OPEN: (1) GUI e2e with the real daemon: dev app gets `connect failed: connection closed` right after the handshake (the `.list` request) on this branch, same for the old verify-vault-unlock.sh; muyad stays alive and muyactl/Rust clients work, so the cause is in the app<->dev-stack path (not in this work). `verify-secrets-parity.sh` therefore unrun. (2) Screenshots are mock-mode (FakeSSHRpc), test values; the last retake failed ("could not create image from window"), the committed-to-scratchpad shots predate the selection fix. (3) `muyactl secret exec` e2e, classic card-look compare, Touch ID/import/export buttons.

## Update 3 (after muya-all's request)
- DONE: `muyactl secret exec` e2e against real muyad (test `muyactl_secret_exec_reaches_200_and_stays_redacted`: fake `claude` lists the test process as the session, muyactl child is tied by ancestry, curl gets 200, output redacted). Touch ID button ("Turn on/off Touch ID") in the Password Store toolbar + service.setTouchId + Fake rpc + Swift test (330/0).
- NOT DONE (decision for the operator/next worker): classic's CARD layout per group. Native stays a table sorted by group with a Group column; real cards need a new view (grouped sections) — only worth it if the operator wants the look, not the function.
- Real data check: nothing committed carries real data (no images or fixtures in this branch; tests use test-pass-/test-token- values; no home paths).
- SCREENSHOTS STILL OWED (screen was locked; mock mode, test values; dark + light each):
  store-list, store-revealed (Show on lab-admin), store-edit (Edit ci-deploy-key), toolbar fit check at 1120 px (7 buttons + filter).
  Command (from native/app): `export TMPDIR=$(mktemp -d /tmp/muya-m.XXXXXX); ./run-mock.sh start; . $TMPDIR/muya-native-dev.state; d(){ printf '%s\n' "$1" | nc -U -w 5 $DEV/app-debug.sock; }; d "rail SSH"; d "ssh-section vault"; d "ssh-secret show lab-admin"; for t in dark light; do d "appearance $t"; sleep 1.3; screencapture -x -o -l "$(d windowid)" <out>/store-revealed-$t.png; done; d "ssh-secret edit ci-deploy-key"; …same for store-edit…; d "ssh-form cancel"; ./run-mock.sh stop`. Then LOOK at each image. Output dir: scratchpad/secrets-parity-shots. After the dev-app connection fix: run `native/app/verify-secrets-parity.sh` (real daemon + classic vault in the GUI).

## Update 4 — classic card layout built (code only, NOT yet looked at)
- New `native/app/Sources/SSH/PasswordStoreCards.swift` (+ `CredGroup`/`CredKindName` logic in SSHLogic.swift, Swift test, 331/0). Spec from classic: `docs/prd-secrets-parity.cards-spec.md` (SshPage.tsx L1314-1475).
- VaultPane now: row 1 = status (green "Unlocked · N") left, [Add credential (primary, plus)] [Enable/Disable Touch ID] [Lock] right; row 2 = full-width search ("Search credentials — label, username, group, note…"). Group cards (chevron, name 14/500, "(N)", collapsible, persisted in UserDefaults `muya.vault.collapsed`, forced open while searching, Ungrouped last) holding a 1/2/3-column grid (breakpoints 768/1536 on page width) of credential cards: radius 10, 1px border, padding 16, label 14/500 + mono 12 "user · kind" (SSH key / API key names), description 12 faint, 4 action buttons 28 px on the right (eye, copy→check 1.5 s, pencil, trash), revealed value in a mono 12 --bg-segment block (max 160).
- Narrow (<760 px) degrades instead of overflowing: Touch ID label shortens, Lock loses its word (icon + tooltip); the card grid drops to 1 column.
- Geometry checked via debug socket `ssh-secret layout` (mock, 1056 px pane: Lab group 2 columns, cards 482 wide; Ungrouped 124 high). Pixels NOT looked at: screen locked.
- Deviations / not done: delete asks for confirmation (classic deletes at once); no per-card Export, no Import SSH key / Import credential / Export backup buttons (muya-core has credstore_import_key / import_secret / export_cred / export — need RPC + save/open panels); edit uses the form sheet, not in-place card editing; icons draw at 14 px (ModalButton iconOnly) vs classic 16.
- Screenshots owed: as in Update 3, plus `ssh-secret collapse Lab` (collapsed state), a narrow window (<760 px) shot, and compare each side by side with classic mock (`npm run dev`, localhost:1420/?mock=1, SSH → Password Store, dark+light).

## Update 5 — export/import built (needs eyes)
- RPCs `vault.export_backup` (sealed copy of the store, still encrypted; default name muya-ssh-vault.enc.bak like classic), `vault.export_cred` (plain text, 0600, classic's per-card Export), `vault.import_key`, `vault.import_secret` — all call classic's muya-core functions. Gate `vault_operator_only()` in rpc.rs `call_as`: reveal/save/remove/add/update/export/import refuse `Caller::Agent` (test `an_agent_caller_is_refused_…`). Real-muyad test `export_backup_export_card_and_imports_work` (backup has no plaintext, 0600 export, imports) passes.
- UI: toolbar Import SSH key / Import credential / Export backup (below 900 px they fold into a "More" menu), per-card Export (download icon, 5th action). Import = form (name, user, + kind/group/description) then NSOpenPanel, like classic. NSSavePanel/NSOpenPanel flows are untested in the GUI (modal panels): check by hand when the screen is unlocked.
- Still different from classic: delete confirm sheet; edit is a form sheet; "Export master password" (store-create screen) not ported.

## Update 6 — the three differences closed; WAITING ON THE SCREEN
- Delete: classic deletes at once (no confirm) — now the same. Edit/New/Import: classic renders an in-place CredForm card (2-column grid: Label | Username, Kind | Secret, Group, Description, Cancel/Save; key = 96 px textarea) — now the same: edit replaces the card in its grid cell, new/import forms sit above the groups (`CredFormCard`, PasswordStoreCards.swift). The old form sheets for add/edit/import are removed.
- "Export master password" ported to the create screen: classic's text (AES-256-GCM sentence + the plaintext warning), Create + ghost "Export master password" (needs ≥4 chars typed, else "type the master password above first, then export it"; save panel "Export master password (PLAINTEXT)", default muya-master-password.txt; message "⚠️ Master password written in plaintext to: … — store it somewhere safe."). RPC `vault.export_master` (operator-only, 0600, value wrapped in Zeroizing, not logged); test in secrets_parity.rs.
- Verified through the debug socket in mock mode (not pixels): edit saves in place (group changed), new credential appears, delete removes, layout numbers sane. Debug commands: `ssh-secret new|import [key]|formset <id> <v>|formsave|formcancel|formstate|layout|rows|show|copy|edit|delete|collapse|lock`.
## EXACTLY WHAT IS LEFT (needs the unlocked screen)
1. Screenshots, mock mode, dark + light, each LOOKED AT and compared with classic (`npm run dev`, http://localhost:1420/?mock=1, SSH → Password Store): (a) list with groups, (b) Show on lab-admin (revealed block), (c) in-place edit card, (d) New credential card above groups, (e) Import SSH key card, (f) collapsed group (`ssh-secret collapse Lab`), (g) narrow window <760 px and 760–900 px (More menu), (h) create-store sheet with the master-export button + warning (needs real daemon or mock with an uninitialised store). Command: see Update 3 plus `ssh-secret edit|new|import`.
2. NSSavePanel / NSOpenPanel flows, by hand: Export backup, per-card Export, Import SSH key, Import credential (file picker), Export master password. Check default file names and that exported files are 0600 (`ls -l`).
3. `native/app/verify-secrets-parity.sh` once the dev-app↔muyad connection is fixed (other worker).
Test values only everywhere; nothing with real data is committed.

## Update 7 — verified on the real stack (HEAD after this commit)
- verify-secrets-parity.sh (after merging 79d8e89): 10 PASS, FAILS=0 (classic-made vault with group+user opens in the GUI, Show/Copy/in-place Edit/Lock).
- Screenshots a–h dark+light in scratchpad/secrets-parity-shots next to classic-*.png from the classic mock. Status line now has the open-padlock glyph and "Unlocked · N item(s)"; Touch ID button has the fingerprint glyph.
- Panels, driven with cua-driver against the dev app, files only in ~/Documents with zz-muya names, deleted afterwards:
  Export backup: title "Export encrypted store backup", default name muya-ssh-vault.enc.bak, result file -rw------- , starts {"magic":"MUYA-S…", no plaintext; status line "Encrypted backup exported to: …".
  Per-card Export: title "Export password", default old-router.txt, file -rw------- containing the test value, status "Password exported to: …".
  Export master password: title "Export master password (PLAINTEXT)", default muya-master-password.txt, file -rw-------, status warning shown in the sheet.
  Import SSH key: card opens (Name, User name); "Choose file…" opens the NSOpenPanel titled "Select SSH private key file" on Documents. The panel's file list is rendered out of process and ignores events sent to a background app (pixel click, double click, typeahead, ⌘⇧G all had no effect), so picking a file could not be driven without bringing the app to the front; I did not do that. Import through the RPC is covered by test export_backup_export_card_and_imports_work. Import credential panel not opened (same code path, title "Select file containing the secret value").
- Typing a full path into a NSSavePanel name field turns "/" into ":" (system behaviour) — only plain file names were used.
