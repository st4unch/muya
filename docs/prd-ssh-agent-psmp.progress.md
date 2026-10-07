---
status: done
prd: docs/prd-ssh-agent-psmp.md
started: 2026-10-07
---

## Phase Outputs
- Unit tests: 7 new in `ssh.rs` (AC1–AC8), all 362 lib tests + sidecar test green.
- Live (AC9): rebuilt sidecar against a dev app on an isolated socket + fake HOME. `tools/list` shows
  `ssh_update_server`, `ssh_list_psmp_profiles`, `psmpProfile`. Calls: profile list (no vault user) ✅;
  `@` in username refused ✅; PSMP add by name and case-insensitive name ✅ (`gokay#corp.local` accepted);
  unknown profile → "Available: corp-psmp" ✅; direct opencti → updated to PSMP + target `gatar` ✅;
  operator server update refused ✅; config file shows psmp/profile id/agentAdded/agentAccess/sshOptions None ✅.
- Not live-tested: an actual connection through a real PSMP (no PSMP here); the connect string is covered by
  `agent_add_psmp_server_by_profile_name` (same builder as operator servers).

## Changes
| Date | File | What changed | AC |
|-------|-------|-----------|-----|
| 2026-10-07 | src-tauri/src/ssh.rs | `agent_add_server_in` takes a PSMP profile; new `agent_update_server_in`, `agent_psmp_profiles`, `check_agent_target`; tests | AC1–AC8 |
| 2026-10-07 | src-tauri/src/broker.rs | `update_server`, `list_psmp_profiles` ops; `psmpProfile` on add + in `ServerMeta` | AC1, AC5–AC9 |
| 2026-10-07 | src-tauri/src/bin/muya_ssh_mcp.rs | `psmpProfile` param, `ssh_update_server`, `ssh_list_psmp_profiles` tools | AC9 |
| 2026-10-07 | README.md, claude-plugin/muya-mcp (1.0.2) | document the new tools | — |

## Decisions
- PSMP username may contain `#` (CyberArk domain accounts) but never the profile's user delimiter; host may contain neither delimiter nor `@`.
- `update_server` resolves the alias with the same rule as `open`; ownership (agentAdded) is enforced inside `ssh.rs` so every caller gets it.
- Operator approved the scope on 2026-10-07 ("fix'i çıkalım"): agents pick an existing PSMP profile by name and may fix only the servers they added; profiles stay operator-only.

## Lessons
