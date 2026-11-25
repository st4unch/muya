# Password Store parity: classic vs native (read-only audit)

Paths: classic = <repo>, native = worktree wt-secrets `native/`.
`C:` = classic, `N:` = native. Classic UI is `src/components/SshPage.tsx` (Password Store tab, lines ~1000-1520) over `src-tauri/src/credstore.rs` (thin Tauri wrappers) and the engine now shared as `native/crates/muya-core/src/credstore.rs`.
Note: `native/app/Sources/Vault/*` is the Obsidian NOTES vault ("Vault Source"), NOT the password store. The Password Store UI is `VaultPane` in `native/app/Sources/SSH/SSHPage.swift:381-430, 534-730`, model in `SSHLogic.swift:127-140, 355-385`, client in `SSHService.swift:70-125`.

## Root cause summary: why old entries "disappear"
The daemon side is fine: `vault.list` returns every stored credential (id, label, username, secretKind, description, group) from the same v1 blob (`rpc.rs:569`, `credstore.rs:724`; the old-JSON test at `credstore.rs:1527` covers missing `description`/`group`). The loss is in the Swift layer:
1. `SecretMeta` decodes only label/description/kind (`SSHLogic.swift:128-138`). `id`, `username`, `group` are dropped. Nothing can be grouped, searched by username/group, or addressed by id.
2. Rows are keyed by label only. Old stores can hold duplicate labels (classic upsert allowed this; `add_credential` rejects them); the Swift list has no id so duplicates are indistinguishable and the label-based `update` hits the first.
3. No reveal / copy / edit / delete RPCs are wired (daemon has no `vault.reveal`, `vault.remove`, `vault.edit`, `vault.import`, `vault.rekey`, `vault.export` in `rpc.rs`; Swift `SSHMethod` lists only list/unlock/add/update/status/init, `SSHService.swift:19`). Old passwords are listed (names only) but cannot be seen, copied or deleted.
4. The pane header text states "values are never shown" (`SSHPage.swift:139, 401`): a deliberate design that is the opposite of classic's eye icon.
5. BUG: Update sends `{"label":..., "secret":...}` (`SSHService.swift:119-121`) but the daemon requires `reference` (`rpc.rs:201-205`) -> "bad parameters", Update never works against the real daemon (the mock in SSHService.swift:205-208 hides it).
6. Possible: Touch ID item from classic lives in classic's Keychain access group, so native shows no Touch ID until one master-password unlock (`rpc.rs:529-536`); expected, documented.
7. Store path is `$HOME/.claude/muya-ssh-vault.enc` (`credstore.rs:290`). If muyad runs under a different HOME (dev/fake HOME), it sees a different/empty store ("There is no password store on this Mac yet").

## Parity table

| feature | classic file:line | native file:line | status | note |
|---|---|---|---|---|
| Decode MUYA-SSHVAULT v1 file (all fields) | credstore.rs engine (same code) | muya-core/src/credstore.rs:36-38, 53-72, 260-271; old-format test :1527 | OK | Shared engine; username, group, description, secretKind, keyPassphrase all decoded with serde defaults |
| Create store (init) | SshPage.tsx:1029 `credstore_init` | SSHPage.swift:556-580, SSHService.swift:113; rpc.rs:548 | OK | Empty/duplicate guards present |
| Unlock with master | SshPage.tsx:1038-1041 | SSHPage.swift:536-580; rpc.rs:279 `vault_unlock` | OK | |
| Touch ID unlock | SshPage.tsx:1057-1060, 1246-1258 | SSHPage.swift:539-549; rpc.rs:529-536 | OK/partial | Needs one master unlock first when item is in classic's keychain group (`touchidReenableNeeded`) |
| Enable/Disable Touch ID button | SshPage.tsx:1070, 1078, 1339 | only `enableTouchId` flag on unlock sheet (SSHPage.swift:559); rpc `vault.touchid.enable/disable` exist (rpc.rs:561-568) but no Swift button | GAP | Cannot disable Touch ID from the UI |
| Lock now button | SshPage.tsx:1050, 1345; credstore.rs:22 | `vault.lock` exists (rpc.rs:522); no Lock button in VaultPane | GAP | |
| Auto-lock 15 min idle | App.tsx:1218-1224 | muyad/src/vault_idle.rs:14, 55; `vault.activity` rpc.rs:544, SSHDaemon.swift:44 | OK | Env `MUYA_VAULT_IDLE_SECS` override |
| Locked UI event / clear revealed | SshPage.tsx:1020 `muya://vault-locked` | SSHPage.swift:534 `vaultWasLocked` | OK | |
| List credentials | SshPage.tsx:1300-1306, 1417+ | SSHService.swift:70-77; SSHLogic.swift:355-366 | GAP | Names only; id/username/group dropped (SSHLogic.swift:128-138) |
| Groups (cards per group, group field, datalist) | SshPage.tsx:1297-1306, 1417, 1507 | none; `group` not decoded; `vault.add` has no group param (rpc.rs:175-181; add_credential sets group "" at credstore.rs:~797) | MISSING | Old grouped entries all appear flat |
| Description | SshPage.tsx:1005, 1200 | SSHLogic.swift:130-134; SSHPage.swift:393 | OK (list) / GAP (edit) | Shown; editable only on add, not on update (SSHService.swift:119) |
| Username column / field | CredMeta.username; CredForm | not decoded or shown | MISSING | |
| Secret kind (password/key/token/api_key) | credstore.rs:109 valid_secret_kind | SSHLogic.swift:252 `["password","key","token"]` | GAP | Native picker lacks `api_key`; existing api_key entries show as raw string |
| Reveal (eye) | SshPage.tsx:1173-1181, 1443-1462; credstore.rs:87 | none (muya-core `reveal_cred` credstore.rs:643 unused by rpc) | MISSING | Needs `vault.reveal` RPC + eye button + auto-hide on lock |
| Copy value | SshPage.tsx:1187-1190, 1446 | none | MISSING | Needs reveal RPC; clipboard auto-clear advisable |
| Edit credential | SshPage.tsx:1199-1200, 1449, 1487 | SSHPage.swift:691-730 "Update value" only | GAP | Cannot edit name/username/description/group/kind; muya-core `edit_credential` (credstore.rs:950) is wired only for the broker (broker_host.rs:133) |
| Update value | SshPage.tsx:1155 upsert | SSHService.swift:119-121 -> rpc.rs:583-586 | BUG | Client sends `label`, daemon expects `reference` (rpc.rs:201-205): always fails with bad parameters on the real daemon |
| Add credential | SshPage.tsx:1320, 1155 | SSHPage.swift:691-730; rpc.rs:573 | GAP | No username, group, keyPassphrase; rejects duplicate label |
| Delete credential | SshPage.tsx:1164 `credstore_cred_remove` | no RPC (muya-core credstore.rs:856 exists) | MISSING | |
| Search | SshPage.tsx:1355 (label, username, group, note, kind) | SSHLogic.swift:362 (label, description only) | GAP | |
| Import key / secret from file | SshPage.tsx:1111, 1127, 1379 | none (muya-core credstore.rs:532, 576) | MISSING | |
| Export one credential to file | SshPage.tsx:1146 | none (credstore.rs:615) | MISSING | |
| Export encrypted backup / master | SshPage.tsx:1088, 1100 | none (credstore.rs:661, 519) | MISSING | |
| Rekey (change master) | credstore.rs:97 | none (credstore.rs:680) | MISSING | |
| Agent surface (list/get/add/update secret via MCP) | broker | broker.rs:1602 list_secrets, :1666 get_secret; broker_host.rs:133 | OK | Agents see old entries fine |

## Fix order (suggested)
1. Fix `vault.update` param (`reference`) in SSHService.swift or accept `label` in rpc.rs.
2. Add id/username/group/kind to `SecretMeta`; group + sort by group; search over all fields.
3. Add daemon RPCs `vault.reveal`, `vault.upsert/edit`, `vault.remove` (+ import/export later) calling the existing muya-core fns; add eye/copy/edit/delete buttons, Lock and Touch ID toggle.
4. Add `api_key` to kind list.
