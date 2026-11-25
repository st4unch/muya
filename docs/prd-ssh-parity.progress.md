---
status: active
---
# Progress: ssh-parity (branch fix/ssh-parity, worktree wt-ssh)

## Done (committed: ebbc71e + later)
- muyad: `ssh.connect` rpc, password injection (direct + PSMP, challenge withheld), CyberArk rpc (`cyberark.*`, `ssh.cyberark.*`), broker `ssh_open`/`ssh_send` handled in daemon (crates/muyad/src/{ssh_connect,broker_host,rpc,main}.rs). cargo build ok.
- Swift: Connect button calls `ssh.connect` (SSHService.connect), `.notWired` PSMP/stored-login text removed; `Store.selectWhenAdopted`; debug command `ssh-connect <title>`; unit test updated. `native/app/build.sh test`: 330 tests, 0 failures.
- Docker env in native/scripts/e2e-ssh/: Dockerfile, entrypoint.sh, psmp-gw.sh, docker-compose.yml (ports 2201 password `dba`, 2202 key `keyuser`, 2203 PSMP gateway user `vaultuser@dba@ssh-pw`, env E2E_TARGET_PW/E2E_VAULT_PW/E2E_PUBKEY/E2E_CHALLENGE/E2E_OTP). Verified with plain ssh via pty: direct login OK, PSMP login OK (Vault Password prompt -> proxied to target).
- run.sh (ui|agent|all) + mcp_call.py (MCP stdio client for sidecar) written, uncommitted until this note; sidecar built via `cargo build --bin muya-ssh-mcp` in src-tauri (needs empty placeholder src-tauri/binaries/muya-ssh-mcp-aarch64-apple-darwin; gitignored).

## In flight / BLOCKER
- run.sh ui: app never connects to the dev muyad: app says `unreachable(... muyad.sock: Connection refused)`, phase "Done. The service runs the new version". Same failure in existing `app/verify-vault-unlock.sh` (baseline) => env/takeover-logic issue (base commit 1841327 takeover/recovery code in RestartDialog.swift `recoverIfNeeded`/`sweepSockets`), NOT my SSH change. Observation: python hello to muyad.sock works BEFORE the app starts, refused AFTER the app starts => the app's recovery path probably removes/replaces the dev socket. Next step: with MUYA_SOCKET set (tests only) skip the service recovery/takeover, or drive the daemon with a python client (role app, hello then rpc `ssh.connect`, attach to the session) which the peer gate accepts.
- Operator's daemons (pid 68760/68761) were checked alive and untouched.

## Left
1. Fix/bypass the blocker above, then run `native/scripts/e2e-ssh/run.sh all`; fix failures (direct, key, PSMP, PSMP+OTP withheld; agent ssh_run/ssh_open/ssh_send/ssh_session_open/exec/ssh_scp; no password in results/screens/logs).
2. Port agent-SSH idle reaper into muyad: 5-min loop calling `muya_core::agent_ssh::reap_idle(&store, IDLE_TIMEOUT)` (classic caller src-tauri/src/lib.rs:391), confirm BUFFER_CAP 512 KB, test: idle session closed, busy one not. Verify ControlMaster only for direct, never PSMP (classic a9f95fc/f928bbc/4c8db08, lesson L41).
3. Visual parity: classic `npm run dev` + `?mock=1` Playwright screenshots (dark+light) vs `native/app/verify-ssh.sh` shots; fix differences.
4. `cargo test` (native workspace), `native/app/build.sh test`, CHANGELOG [5.0.2] lines, commit with trailer, no push, no /Users/ paths (grep before commit).

## Update (usage limit reached)
- MUYA_SOCKET now disables service recovery/takeover/registration (ServiceState.recoveryDisabled in RestartDialog.swift, set in main.swift via Logic/ServiceRecoveryPolicy.swift; test Tests/ServiceRecoveryPolicyTests.swift). NOT yet built or run: do `native/app/build.sh test` + `build.sh`, then `native/scripts/e2e-ssh/run.sh all`. muya-all approved this change.
- Still TODO: idle reaper in muyad (+test), ControlMaster check, visual parity, cargo test, CHANGELOG [5.0.2].

## Update 2026-11-21
- Merged takeover fixes (278fff6 / 5035281). Dev app now connects. `native/scripts/e2e-ssh/run.sh ui`: GREEN (direct pw, key, PSMP, PSMP + typed challenge withheld; no secret in screens/logs). `run.sh agent` (agent_e2e.py): ssh_run / ssh_open / ssh_send / ssh_session_open+exec green for direct and PSMP; key: ssh_run/open/send green; ssh_scp key green.
- Fixed in muyad: ssh_open emit started a nested tokio runtime (panic -> "empty response from Muya app"); now resolved on its own thread.
- Idle reaper ported: broker_host.rs `start_idle_reaper` (5 min tick, IDLE_TIMEOUT 30 min, spawned from `MuyadBrokerHost::spawn`); BUFFER_CAP 512 KB unchanged in agent_ssh.rs. Test: `cargo test -p muyad --lib reaper -- --ignored` (ignored by default: real bash PTY races HOME/cwd of other muyad tests) passes: idle session closed, busy one kept; cadence test runs always.
- ControlMaster parity: shared muya_core::ssh (build_connect_command PSMP -> ControlMaster=no + ControlPath=none, test ssh.rs:1329; direct -> auto reuse). Nothing Native-specific to change.
- Findings (classic-shared code, not changed): (1) agent_ssh::open only probes the shell after injecting a password, so ssh_session_open hangs/times out when no prompt appears (ControlMaster already open from an earlier ssh_run, or key-only login). (2) ssh_scp reports "complete" even with exit code 255 (text says so).
- OPEN: ssh_scp to the password server (2201) fails "Host key verification failed" in the fake HOME although known_hosts has [127.0.0.1]:2201 (key server 2202 works) - not diagnosed. Visual parity screenshots (classic mock vs Native) not done. e2e harness: PSMP sim now uses sshd password auth for the vault password (ssh's own prompt, like real PSMP); ControlPath override in direct servers' sshOptions because the fake HOME path is too long for ssh's 104-byte socket limit.
- Tests: native `cargo test --workspace` green except `concurrent_spawns_each_get_their_own_tty` (flaky under parallel PTY load, passes alone); `native/app/build.sh test` 332/0.

## Update 2026-11-21 (later)
- Reaper + ssh_open fix committed (e852830). Lesson L92: an earlier stash pop had left them out of 1a02dd0.
- ssh_scp "Host key verification failed" diagnosed: NOT a Native bug. build_scp_command deliberately sets no host-key option (production keeps strict checking on; the agent cannot pass -o), and OpenSSH reads known_hosts from the account's real home (getpwuid), not $HOME, so a fake-HOME harness cannot supply one without touching the real ~/.ssh. e2e now asserts scp runs and stops exactly at host-key verification.
- `run.sh all`: FAILS=0 (UI direct/key/PSMP/PSMP+OTP; agent ssh_run/open/send/session_open+exec/scp-host-key for direct, key, PSMP).
- Flaky ptyd/muyad PTY tests: origin/main (a45a4eb) `cargo test --workspace` fails 3/3 in muyad `ac6`; branch failed once in `p2` and once in ptyd `concurrent_spawns...`; all pass alone. Pre-existing PTY-load flakiness on main, not introduced here.
- OPEN: visual side-by-side vs classic (dark+light).

## Update 2026-11-21 (visual)
- Committed: session_open fix (conservative probe gate; 3 tests: password still injects, no-prompt login opens with nothing injected, silence writes nothing); `scp_upload_download_live` run against a throwaway container: upload + download verified.
- Classic reference shot (mock data): docs/research/ssh-parity/classic-ssh-servers-mock.jpg. VISUAL GAP IS LARGE, not spacing: classic SSH page = header "SSH Configuration" + tabs Servers | CyberArk | Password Store (no separate PSMP tab), "N server(s)" + "Add server" button top right, a search field ("Search servers — label, host, username, group, tag…"), collapsible group sections ("Production (2)") holding a 2-column grid of server CARDS (label bold, `user@host:port · type · …` mono line, per-card Connect button + edit + delete icons). Native today = table + bottom buttons + 4 tabs incl. PSMP. Needs an SSHPage.swift rework (cards, groups collapse, per-card actions, PSMP profiles moved into the server form / elsewhere). Not started; dark-mode classic shot and Native side-by-side still to take after the rework.

## HANDOFF (read this first) - state at 1ef06c5 + this commit
Already DONE (do not redo): session_open change (2230cd8; password path unchanged, `may_probe` quiet-login second condition, never writes password bytes without a prompt, 3 tests in muya-core agent_ssh); scp live transfer (`cd native && cargo test -p muya-core --lib scp_upload_download_live -- --ignored --nocapture` needs a container on 127.0.0.1:2222, testuser / Sup3rSecret!, e.g. `docker run -d --rm --name muya-ssh-test -p 127.0.0.1:2222:22 -e MODE=password -e SSH_USER=testuser -e 'SSH_PASS=Sup3rSecret!' e2e-ssh-ssh-pw` after `docker compose build` in native/scripts/e2e-ssh; PASSED: upload + download); reaper e852830; e2e `native/scripts/e2e-ssh/run.sh all` FAILS=0.
REMAINING (3):
1. Native SSH page rework to match classic (SSHPage.swift): tabs Servers | CyberArk | Password Store (PSMP profiles leave the tab bar), "N server(s)" + "Add server" button top right, search field "Search servers — label, host, username, group, tag…", collapsible group headers "Production (2)", 2-column grid of server CARDS (bold label, mono `user@host:port · type · …` line, Connect button + edit + delete icons per card). Reference: docs/research/ssh-parity/classic-ssh-servers-mock.jpg. Build only from modalKit-style parts; update tools/ssh-shots.swift + Tests/SSHTests.swift.
2. Visual side-by-side, dark + light, test data only: classic via `npx vite --port <free>` in the main repo + `http://localhost:<port>/?mock=1` (rail "SSH"), screens still needed: Servers list (both themes), Add/Edit server form (direct + PSMP), CyberArk tab, Password Store tab (locked + unlocked), PSMP profile form. Native via `native/app/verify-ssh.sh` (screenshots/ssh-*.png).
3. `verify-ssh.sh` has 1 failing assertion "Unlock calls the daemon and the list appears" (vault unlock flow changed by the Touch ID work; not caused here) - fix the fake or the check, then regenerate vault-*.png only if they look right (the regenerated ones were degraded, so they were reverted in 8d9f004).
Also: classic-shared `ssh_scp` prints "complete" on exit 255 (text says exit code; left unchanged). Flaky PTY-load tests (muyad ac6/p2, ptyd concurrent_spawns) exist on origin/main too.

## DECISION (muya-all): SSHPage rework is IN SCOPE for 5.0.2 - do it FIRST when work resumes
Gap list (classic reference shot: docs/research/ssh-parity/classic-ssh-servers-mock.jpg; classic UI = `npx vite --port <free>` in the main repo, `?mock=1`, rail "SSH"):
- Tabs: classic = Servers | CyberArk | Password Store. Native has a 4th PSMP tab -> remove it from the tab bar BUT DO NOT DELETE the feature: find where classic reaches PSMP profiles (look in src/ SSH page + server form; probably inside the Add/Edit server form) and put it there. If impossible, tell muya-all instead of dropping it.
- Header: "SSH Configuration" + "N server(s)" count + "Add server" button top right.
- Search field: "Search servers — label, host, username, group, tag…".
- Group sections: collapsible headers with counts ("Production (2)", "Ungrouped (1)").
- Server list: 2-column grid of CARDS (bold label, mono `user@host:port · type · …` line), NOT a table.
- Per-card actions: Connect button + edit icon + delete icon (Native today: table + Add/Connect/Edit/Delete buttons at the bottom).
- Code: native/app/Sources/SSH/SSHPage.swift (736 lines; ServersPane/PSMPPane/CyberArkPane/VaultPane), SSHForm.swift; update tools/ssh-shots.swift + Tests/SSHTests.swift; build from modalKit-style parts.
- Then dark+light side-by-side shots (screens listed in the HANDOFF block above).

## Known PRE-EXISTING failure (not a regression)
`native/app/verify-ssh.sh` fails 1 assertion: "Unlock calls the daemon and the list appears". Broken by the Touch ID / vault unlock work (the unlock flow no longer matches the fake in tools/ssh-shots.swift). Not caused by ssh-parity; the vault-*.png it regenerates look degraded, so they were reverted in 8d9f004.
