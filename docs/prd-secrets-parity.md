# Mini-PRD: Password Store parity + agents can use secrets (5.0.2)

**Goal.** (1) The Native Password Store shows and manages the operator's old (classic, MUYA-SSHVAULT v1) entries exactly like classic: id/user/group, reveal, copy, edit, delete, lock. (2) Agents can use a secret without seeing it: `get_secret` explains how, and an `http_request` tool does REST calls with the placeholder.

**Integration (§5).** Shares `muya-core::credstore` (same file format as classic) and the broker in `muya-core/src/broker.rs`; app talks to muyad over the existing RPC (`vault.*`); the MCP sidecar is `src-tauri/src/bin/muya_ssh_mcp.rs`. Nothing else changes. Protected: SSH page logic (other worker, branch fix/ssh-parity), vault unlock flow, auto-lock.

**Acceptance.** Old vault with username/group lists with those fields; Show/Copy/Edit/Delete/Lock work; `http_request` returns 200 against a local server that checks an Authorization header and no result contains the plaintext; `get_secret` text names http_request / run_with_secrets / muyactl secret exec.

Parity table: `docs/prd-secrets-parity.parity.md`. Progress: `docs/prd-secrets-parity.progress.md`.
