# Mini-PRD: agents add and fix PSMP servers

- Date: 2026-10-07
- Type: mini-PRD
- Follows: `docs/prd-ssh-agent-add-server.md` (D2 rejected PSMP "because it needs an operator PSMP profile id")

## 1. Problem
A user asked their agent to register 6 servers behind CyberArk PSMP and to fix two it had
added earlier. `ssh_add_server` can only create direct servers (`ssh.rs:400` forces
`connection_type: "direct"`), takes no profile, and rejects `@` in the username, so the
agent could neither add the PSMP servers nor repair the broken ones. The operator's own
PSMP servers on another machine were added by an agent editing `~/.claude/muya-ssh-config.json`
directly — the tool never supported it.

## 2. Scope
- In:
  - `ssh_add_server` takes an optional `psmpProfile`: the NAME (or id) of a PSMP profile the
    operator already defined. With it the server is `connectionType: "psmp"`, `host` = target
    address, `username` = target account.
  - New `ssh_list_psmp_profiles`: profile name + PSMP address only (no vault user, no ids beyond the name).
  - New `ssh_update_server`: change label / host / username / port / credential / PSMP profile
    (or back to direct) of a server **the agent added** (`agentAdded: true`). Operator-added
    servers are refused.
  - `ssh_list_servers` shows each PSMP server's profile name.
- Out:
  - Agents creating, editing or deleting PSMP profiles (the profile decides where the vault
    password goes — operator only).
  - `sshOptions`, jump hosts, CyberArk credential sources for agents (unchanged).
  - Detecting agents that edit the config JSON directly (separate follow-up).
  - UI changes (the existing "added by agent" badge already covers PSMP servers).

## 3. Acceptance criteria (binary)
- [ ] AC1: `ssh_add_server` with `psmpProfile` naming an existing profile stores `connectionType: "psmp"`, that profile's id, `agentAdded: true`, `agentAccess: true`, `sshOptions: None`.
- [ ] AC2: An unknown `psmpProfile` is refused and the error lists the profile names that exist; nothing is written.
- [ ] AC3: For a PSMP server the username may contain `#` (domain accounts, e.g. `user#corp.local`) but not the profile's user delimiter, whitespace, control chars, or a leading `-`; the host may not contain either delimiter. Direct servers keep today's rules (no `@`).
- [ ] AC4: The connect command of an agent-added PSMP server is `vaultUser@targetUser@targetAddress@psmpAddress` (same builder as operator servers).
- [ ] AC5: `ssh_update_server` on an agent-added server applies only the given fields, keeps its id, `agentAdded`, `agentAccess`, and `sshOptions: None`; can switch direct ⇄ PSMP.
- [ ] AC6: `ssh_update_server` on an operator-added server is refused and the config file is unchanged.
- [ ] AC7: `ssh_update_server` that would duplicate another server's host+port+user is refused.
- [ ] AC8: `ssh_list_psmp_profiles` returns name + psmpAddress for every profile, never `vaultUser`.
- [ ] AC9: The rebuilt sidecar lists the new tools and parameters (`tools/list`), and a live call against the running app adds and updates a PSMP server.

## 4. Protection list
- Operator-added servers: never modified by an agent (AC6).
- `reject_injection` rules for direct servers; `validate_psmp_profile`; `build_connect_command`.
- Existing `ssh_add_server` calls without `psmpProfile` behave exactly as today.
- No secret value or vault user ever crosses to the agent.

## 5. Integration / harmony
- Auth / trust boundary: broker socket + uid check (`broker.rs`), opt-in via `agentAccess`
  (`broker.rs:264 agent_visible`), provenance via `agentAdded` (`ssh.rs:66`).
- Data: `SshConfig.servers` / `SshConfig.psmp_profiles` in `~/.claude/muya-ssh-config.json`
  (`ssh.rs:148`), saved atomically through `save_config` (`ssh.rs:227`).
- Conventions: pure `*_in(cfg, …)` helpers in `ssh.rs` with unit tests (`agent_add_server_in`
  `ssh.rs:367`, `upsert_server_in` `ssh.rs:280`); broker op → sidecar tool pair
  (`broker.rs:518 add_server`, `muya_ssh_mcp.rs:342/1093`); alias = label else id (`broker.rs:254`).
- Break risk: changing `agent_add_server_in`'s signature (only caller `broker.rs:537`);
  `ServerMeta` gains an optional field (skipped when absent, so old consumers are unaffected).
