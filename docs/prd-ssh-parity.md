# Mini-PRD: Native SSH tab 1:1 with classic Muya (5.0.2)

Operator requirement: the Native SSH tab is identical to classic visually, functionally and in use. Reuse classic code where possible.

## Parity table (classic -> Native)
| Feature | Classic | Native | Status |
|---|---|---|---|
| Server list, groups, add/edit/delete | src/ SSH page, ssh.rs | native/app/Sources/SSH/SSHPage.swift (ServersPane) | done earlier (ssh-ui) |
| PSMP profiles CRUD | ssh.rs psmp_profiles | PSMPPane + rpc ssh.psmp.* | done earlier |
| CyberArk config/logon/test/accounts | cyberark.rs | rpc cyberark.* in muyad rpc.rs | daemon done (this branch), UI untested e2e |
| Connect direct + stored password | ssh_pty_connect + pty injection | muyad `ssh.connect` (crates/muyad/src/ssh_connect.rs) + Swift SSHService.connect | code done, NOT e2e-proven |
| Connect PSMP (vault password, withhold typed challenge) | pty::run_with_injection | ssh_connect.rs Injector (unit-tested) | code done, NOT e2e-proven |
| Key auth | build_connect_command | same (muya_core::ssh) | code done, NOT e2e-proven |
| Agent ssh_open / ssh_send | broker + app events | muyad broker_host.rs emit("ssh-broker-open/send") | code done, NOT e2e-proven |
| Agent idle reaper (reap_idle, 30 min, 5 min loop) | src-tauri/src/lib.rs:391 | none in native | MISSING (task added by controller) |
| ControlMaster only for direct, never PSMP (L41) | build_connect_command | shared muya_core::ssh, to confirm | TO VERIFY |
| Visual parity (spacing/fonts/icons) | mock=1 screenshots | ssh-shots harness | NOT started |
