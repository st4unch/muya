# Step output — SSH Agent Broker Faz 3.1 (AC11–AC16)

Spec date coded against: MCP `2025-06-18` (matches the existing `muya-ssh` proxy;
tools use `inputSchema` JSON Schema objects, `isError` tool-result contract).

Scope: INFRASTRUCTURE ONLY — the secret-operation ENGINE + an EMPTY registry.
No real aws/git/kubectl operations are defined (operator authors them later in
`~/.claude/muya-agent-ops.json`; absent/empty file ⇒ zero ops).

## AC status

| AC | Status | Evidence |
|----|--------|----------|
| AC11 `description` + `token` kind | ✅ | `credstore.rs`: `description` (`#[serde(default)]`) on `Credential`/`CredMeta`/`CredInput`; `valid_secret_kind()` accepts `password\|key\|token`. Tests `ac11_credential_without_description_deserializes`, `ac11_token_kind_is_valid`. |
| AC12 `list_secrets` op + tool | ✅ | `credstore::list_meta()` (unlocked-gated) → broker `list_secrets` → proxy tool. Projects `{name=label, description, kind}`, never the secret. Tests `ac12_credmeta_has_no_secret_field`; live `tools/list` shows the tool. |
| AC13 `agent_ops.rs` registry | ✅ | `OpDefinition{name,description,program,pinnedArgv,allowedFlags,deniedFlags,secretId,envMap}`; `load_ops_from` (absent/empty ⇒ `[]`, malformed ⇒ hard error); `save_ops` via `credstore::atomic_write`; `resolve_op` unknown ⇒ `"no such operation"`. Tests `ac13_unknown_op_errors`, `ac13_absent_registry_is_empty`, `ac13_registry_round_trips`. |
| AC14 fail-closed `enforce_arg_policy` | ✅ | PURE fn. Rejects: leading-`-` positional, hard-denied flags (`-c --endpoint-url --kubeconfig --output -o --query`) + op deny-list, unknown flags (not on allow-list), word-shaped non-pinned subcommands. Flag values must be `--flag=value`. Tests: clean pass + 6 rejection cases. |
| AC15 `run_operation` engine + `list_operations` | ✅ | `execute_op` = policy → `build_op_env` → `std::process::Command` `env_clear().envs()` argv-only, NO shell, 256 KiB-capped concurrent stdout/stderr capture. `build_op_env` PURE: `{{secret}}`, `{{secret.json:FIELD}}` (multi-var expansion), literals. Broker `run_operation` resolves secret in Rust, injects into CHILD env, reuses the N=4 concurrency semaphore. `list_operations` → name+description only (no program/secret). Tests `ac15_build_op_env_maps_secret_into_vars`, `ac15_missing_secret_errors`, `ac15_execute_op_captures_stdout` (real `/bin/echo` subprocess → "hi", no secret in output), `op_meta_hides_program_and_secret`. |
| AC16 UI description + token | ✅ | `SshPage.tsx` StoreTab: description input + `token` select option; `CredMeta`/draft/`credInput` carry `description`; `CredentialPicker` `CredMeta` widened; mockBackend projects description. vitest `credential description + token kind (AC16)`. |

## Test output

- Backend: `test result: ok. 168 passed; 0 failed; 6 ignored` (was 152 → +16 new).
- agent_ops module: 13/13 pass.
- Frontend: `Test Files 14 passed`, `Tests 86 passed` (was 82).
- `tsc --noEmit`: clean.
- Proxy: `cargo build --bin muya-ssh-mcp` finished, no errors.

## Live observation (Golden Rule §2)

- Fed real JSON-RPC (`initialize` + `tools/list`) into the built `muya-ssh-mcp`
  binary → tools surface = `[ssh_list_servers, ssh_open, ssh_run, list_secrets,
  list_operations, run_operation]`. The 3 new tools are present on the real MCP wire.
- `execute_op` unit test spawns `/bin/echo` as a genuine child process and asserts
  captured stdout + absence of the injected secret — the engine's core exec path is
  observed, not mocked.

### Gap (honest)

`run_operation` end-to-end through the LIVE app broker UDS is NOT exercised headless:
the broker listener starts inside the Tauri `setup` hook (`block_on`) and needs the
full GUI runtime. Same constraint as Faz 1/2 (which used Docker/`#[ignore]` live
tests). To fully validate in-app: unlock the store, author an op in
`~/.claude/muya-agent-ops.json` with `program:"/bin/echo"`, call `run_operation` from
an agent, confirm stdout returns and no secret leaks. Recommended before Faz 3.2.

## New MCP tools (proxy) / broker ops (app UDS)

| MCP tool | broker op (private wire) | returns |
|----------|--------------------------|---------|
| `list_secrets` | `{op:"list_secrets"}` | `[{name,description,kind}]` (no secret) |
| `list_operations` | `{op:"list_operations"}` | `[{name,description}]` (no program/secret) |
| `run_operation` | `{op:"run_operation",operation,args}` | `{ok,stdout,stderr,exitCode}` (no secret) |

## Files

- Created: `src-tauri/src/agent_ops.rs`, `docs/prd-verify/step-output-phase3.md`
- Modified: `src-tauri/src/credstore.rs`, `src-tauri/src/broker.rs`,
  `src-tauri/src/bin/muya_ssh_mcp.rs`, `src-tauri/src/lib.rs`,
  `src/components/SshPage.tsx`, `src/components/CredentialPicker.tsx`,
  `src/components/SshPage.test.tsx`, `src/dev/mockBackend.ts`

## Deviations

- Arg policy: flag values MUST be `--flag=value` (space-form bare-word values are
  rejected as possible subcommands). Conservative Phase-3.1 fail-closed default;
  revisit when real ops land (Faz 3.2). Documented in `agent_ops.rs` header.
- Added minimal `agent_ops_list` / `agent_ops_upsert` Tauri commands for a future
  ops-management UI. The broker reads the registry directly via `load_ops` (file-
  based); agents have NO path to upsert (it is a Tauri command, not a broker op).
