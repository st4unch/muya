# PRD — SSH Configuration with CyberArk PAM + PSMP + Encrypted Credential Store

**Feature slug:** `ssh-cyberark`
**Author:** spec-first-feature pipeline (PM phase), Opus 4.8
**Date:** 2026-07-24
**Grounding:** `docs/SYSTEM.md` (refreshed 2026-07-24)
**Status caveat:** Phase 2a extended web research (encrypted-store CVEs, OWASP param verification) was interrupted by an account spend limit; industry claims without a source URL are tagged `[NEEDS-WEB-VERIFY]`. CyberArk API claims are sourced. Autonomous review (Phase 2c) was run **inline** by the orchestrator (Opus 4.8), not via subagents, for the same reason.

## §0 Review Log

| ID | Severity | Title | Status | Note |
|---|---|---|---|---|
| G1 | P1 | Phase 2a extended research incomplete (spend limit) | flagged | Non-CyberArk industry claims tagged `[NEEDS-WEB-VERIFY]`; operator/next-session can confirm |
| A1 | SERIOUS | Direct-SSH password injection is inherently leaky | applied | Mitigated in §9; PSMP is the recommended path; direct-inject gated + documented as best-effort |
| A2 | SERIOUS | Keychain auto-unlock ⇒ store readable whenever macOS session is unlocked | applied | Auto-lock + manual lock + Touch ID re-auth + `ThisDeviceOnly` accessibility (§9) |
| A3 | FATAL-if-wrong | AES-GCM nonce reuse breaks confidentiality+integrity | applied | Random 96-bit nonce per encryption, stored with ciphertext; unit test asserts uniqueness (Faz 0 AC) |
| A4 | CONSIDER | Master-password loss = unrecoverable store | applied | Explicit destructive-warning UX + optional encrypted export; documented no-recovery |

### Round 2 — software-architect acceptance gate + prd-devils-advocate (2026-07-24, opus subagents)

| ID | Severity | Title | Status | Note |
|---|---|---|---|---|
| ARCH1 | Critical | `keyring` crate cannot gate Keychain item behind biometry + device-only | applied | Switched to `security-framework` for the Touch-ID/`kSecAccessControl`/device-only item (§5/§9/§10/§15.5-D4/AC0.5); `keyring` only as non-biometric fallback |
| ARCH2 | Serious | CyberArk `reveal`-to-JS is an uncovered leak surface | applied | Added §12 R10 + §9 rule: reveal off-by-default, masked, never to a terminal, cleared on unmount |
| PM1 | Serious | PSMP may fall back to INTERACTIVE password prompt → secret in scrollback | applied | §12.5 + §9: detect/prefer non-interactive, warn; documented |
| PM2 | Serious | Argon2id KDF on UI/command thread freezes app; low params → brute-forceable | applied | §14/§9: KDF runs off the command executor; calibrate to ~0.7 s, memory ≥46 MiB |
| PM3 | Serious | `muya-ssh-config.json` not atomically written → corruption on race | applied | §12.5: temp-file + atomic rename; same for `.enc` blob |
| PM4 | Serious | No master-password-CHANGE (re-key) path; crash mid-rewrite loses store | applied | §11 AC1.5 + §12.5: backup-then-atomic-rekey |
| AA1 | Serious | Assumes target `PasswordAuthentication` enabled → direct-inject hangs on key-only hosts | applied | §13 + O6 |
| AA2 | Serious | Assumes CyberArk retrieve returns a PASSWORD; `secretType:"key"` returns an SSH key | applied | §13 + O7: detect secretType, handle/reject keys |
| AA3 | Consider | Assumes single PVWA; load-balanced deployments need sticky session or re-logon | applied | §12.5 + O8 |
| EA2 | Minor | §3.5 "1Password/Bitwarden use Argon2id" partly false | applied | Corrected in §3.5 (1Password=PBKDF2+Secret Key; Bitwarden Argon2id opt-in since 2023) |
| EA1 | Consider | PSMP syntax still `[NEEDS-WEB-VERIFY]`, core of Faz 2 | RESOLVED | Verified 2026-07-24: `vaultUser@targetUser[#domain]@targetMachine[#port]@proxyAddress`, `@`/`#` delimiters configurable (CyberArk PSM-for-SSH docs + community). Builder + 5 tests match. |

**Review rounds:** 2 (round 1 inline; round 2 = software-architect gate + prd-devils-advocate, opus subagents)
**Reviewer model:** claude-opus-4-8
**Architect verdict:** NO-GO → after applying ARCH1+ARCH2 (both doc-only, done above) the required fixes are satisfied; re-gate dispatched after the operator-answer scope change (below).

### Operator answers (2026-07-24) — scope change applied
- #1/#6 → key auth **in scope**: general SSH connection manager, supports password AND SSH-key auth (using existing keys; key generation still out). New §2.1, D7, R14, AC2.4/2.5.
- #2/#7 → CyberArk stores **passwords**; manager still routes key-type accounts to the key path.
- #3 → auto-lock trigger = **macOS screen lock** (D8), not idle timer.
- #4 → RADIUS **push 2FA in scope** (D9); logon waits for phone approval.
- #5 → re-run architect gate (dispatched).

### Round 3 — architect re-gate (2026-07-24, opus)
| ID | Severity | Title | Status | Note |
|---|---|---|---|---|
| ARCH-RG1 | Critical | Key-auth `ssh -i` temp-file writes plaintext key to disk → violates §9 no-plaintext-on-disk + CyberArk guarantee | applied | Switched to **ssh-agent-only** (`SSH_AUTH_SOCK`, never on disk); §9/§2.1/D7/Faz2/R14/AC2.4/§13 updated |
| RG-n1 | Minor | Master-pw re-key must update/invalidate Keychain-cached key | applied | AC1.5 note added |
| RG-n2 | Minor | AC2.5 abort time must be concrete | applied | Pinned ≤10 s |
| RG-n3 | Minor | RADIUS 60 s must be per-request (response) timeout | applied | §14 clarified |

**Architect round-3 verdict:** NO-GO on ARCH-RG1 only → **now applied per the architect's binary done-criteria** (ssh-agent-only, fs-watch-verified AC2.4). All other items GO. Effective status: **GO once ARCH-RG1 lands** — which it now has. Re-gate #4 optional (operator's call, O5).

---

## 1. Goal (Why)

Give the operator (security-ops) a single place in Muya to **manage SSH targets and connect to them, with credentials brokered safely** — either pulled just-in-time from **CyberArk PAM**, routed through a **PSMP jump server** (password injected by CyberArk, never seen by the client), or supplied from Muya's **own encrypted credential store**. No secret is ever written to disk in plaintext, to logs, to process argv, or to PTY scrollback.

**Ne işe yarayacak (plain):** Ortadaki yeni "SSH" sekmesinden sunucularını ekle, CyberArk'a bağlan, hangi şifreyi kullanacağını seç, tek tıkla terminal sekmesinde SSH oturumu açılsın — şifreyi elle kopyalamadan, hiçbir yere sızdırmadan.

## 2. Non-goals (v1 explicitly out of scope)

- SSH **key generation** (creating new keypairs). Using EXISTING private keys for auth **IS in scope** — see §2.1.
- Session **recording/replay** or keystroke logging.
- CyberArk **safe administration** (creating/editing/deleting accounts or safes) — read + retrieve only.
- **Port-forwarding / tunnel** management UI (the PSMP `#port#tunnel` syntax is supported in the string builder but no dedicated UI).
- Non-SSH protocols (RDP, Telnet), non-macOS builds, multi-user/team sharing of the local store.
- SSO/OIDC to CyberArk.

## 2.1 In scope — operator-confirmed (2026-07-24)

This is a general **SSH remote connection manager**, so it must handle **every auth type the operator's fleet uses**:
- **Password auth** (typed/injected) — from local store, CyberArk, or prompt.
- **SSH key auth** (using an EXISTING private key) — key sourced from the local encrypted store or imported by the user; connect via an **ephemeral in-process ssh-agent only** (`SSH_AUTH_SOCK`), never written to disk (§9, ARCH-RG1).
- **RADIUS push-notification 2FA** on CyberArk logon (operator has this) — the logon/test flow waits for the phone-approval / handles the challenge, with an extended timeout.
- CyberArk itself stores **passwords** in the operator's environment (§ operator answer #2), but the manager handles key-type CyberArk accounts too where present.

## 3. Background and Context

Muya today (`SYSTEM.md §9`) has **no at-rest secret storage**: config is plain JSON under `~/.claude/muya-*.json`, and the remote bridge writes certs as permission-restricted plain files (`bridge_remote.rs:136`). This feature introduces the app's first encrypted credential store and first OS-Keychain use. It reuses existing infrastructure: view routing (`App.tsx:345`/`:1313`/`:1455`), the `invoke()` config-panel convention (`VaultConfigPanel.tsx`), the `generate_handler!` registry (`lib.rs:160`), the `portable-pty` spawn (`pty.rs:46`) for opening SSH in a terminal tab, and `reqwest` 0.12 (rustls) for CyberArk REST.

## 3.5 Industry Context & Benchmark

### How production systems solve this today
- **CyberArk PAM REST (v10)** is the modern integration surface; the SOAP-style `CyberArkAuthenticationService.svc/Logon` is deprecated. Source: [CyberArk PAM web services docs](https://docs.cyberark.com/pam-self-hosted/latest/en/content/webservices/implementing%20privileged%20account%20security%20web%20services%20.htm).
- **PSMP (Privileged Session Manager for SSH)** is a hardened SSH proxy: the client SSHes to PSMP, which authenticates the user against the Vault, pulls the target secret, and **injects** it into the target session — the operator never sees the credential. Connection syntax: `ssh vaultuser@targetuser@targetaddress@psmp-address` (delimiters `@`/`#` configurable). Source: CyberArk PSM-for-SSH docs `[NEEDS-WEB-VERIFY]` (corroborated by community cheat-sheets in Phase-0 research).
- **Encrypted desktop credential stores** derive an encryption key from a master password via a strong KDF and gate OS-keychain items behind biometrics. Note (evidence correction, EA2): the specific KDFs vary — **1Password uses PBKDF2-HMAC-SHA256 plus a device Secret Key**, and **Bitwarden defaulted to PBKDF2 for years, adding Argon2id only as an opt-in (2023+)**. Argon2id remains the current OWASP-recommended memory-hard choice for new designs, which is why we pick it here — but the "everyone uses Argon2id" framing is inaccurate. `[NEEDS-WEB-VERIFY exact vendor params]`

### Chosen approach + rationale
- **Auth to CyberArk:** v10 `POST /PasswordVault/API/auth/{method}/Logon`, fall back to legacy `.svc/Logon` if v10 404s. Returns a **raw session token** used verbatim as the `Authorization` header (no `Bearer`), ~20-min idle lifetime; always `Logoff` when done.
- **Local store:** AES-256-GCM, key = Argon2id(master password); the derived key (not the password) is cached in macOS Keychain behind Touch ID for auto-unlock (operator-chosen "Model A"). Chosen over Keychain-only (poor portability/export) and Stronghold (heavier dependency, less transparent) — see §15.5. **Keychain crate correction (ARCH1):** the biometry + device-only gated item MUST be written via the `security-framework` crate (exposes `kSecAccessControl` biometry + `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`); the `keyring` crate writes generic-password items and CANNOT enforce those flags, so it is used only for a non-biometric fallback path.
- **SSH:** PSMP path preferred (no client-side secret handling); direct-inject path supported but treated as best-effort (§9).

### Relevant standards / RFCs / advisories
- **OWASP Password Storage Cheat Sheet** — Argon2id recommended params for interactive use. `[NEEDS-WEB-VERIFY]` (target: memory ≥ 19 MiB, iterations tuned to ~0.5–1 s on target hardware, parallelism 1).
- **NIST SP 800-38D** — AES-GCM: unique nonce per key mandatory; 96-bit random nonce acceptable within limits. `[NEEDS-WEB-VERIFY]`
- **RFC 4252/4256** — SSH password vs keyboard-interactive auth (affects injection path).

### Compliance constraints
| Regime | Constraint on this design |
|---|---|
| NIST SP 800-53 **IA-5 / AC-6** | Credentials encrypted at rest; least-privilege pull; audit of retrieval. `[NEEDS-WEB-VERIFY]` |
| PCI-DSS v4 **Req 8** | Strong auth + no shared/plaintext credential storage. `[NEEDS-WEB-VERIFY]` |
| ISO 27001 **A.9** | Access control + secret handling. `[NEEDS-WEB-VERIFY]` |
| **KVKK** (TR) | Personal/credential data protected; local-only, encrypted, no exfil — satisfied by design (nothing leaves the device except to the operator's own CyberArk). |

## 4. User Flow

1. Operator opens the new **SSH** tab (middle area).
2. **First run:** creates a local store master password → Keychain (Touch ID) offer → store unlocked.
3. **Servers tab:** adds a target (label, host, port, user, connection type, credential source). Dedup blocks a second identical `(host,port,user)`.
4. **CyberArk tab (optional):** enters API URL + auth method + username → password prompt (session-only) → **Test Connection** (real Logon→Logoff) → on success, browse/search accounts, attach one to a server or pull on demand.
5. **Connect:** clicks Connect on a server → Muya builds the SSH command (PSMP syntax or direct), opens a **new terminal tab** via PTY; for direct+password source, the secret is pulled at connect-time, injected into the PTY, then zeroized.
6. **Lock:** manual "Lock" button or inactivity timeout re-locks the store (Touch ID to re-open).

## 4.5 Use Cases — Concrete Scenarios

**UC1 — Ferhat (sysadmin) connects through PSMP:** Has a bastion (PSMP). Adds server `prod-db` (address `10.0.0.5`, target user `oracle`, type PSMP, PSMP profile `bastion1`, vault user `ferhat`). Clicks Connect → terminal opens `ssh ferhat@oracle@10.0.0.5@bastion1` → PSMP injects the Vault credential → he's in. No password ever touched Muya.

**UC2 — Selin pulls a one-off password from CyberArk:** Needs the local `root` on a jump-less host. Configures CyberArk, tests connection (green), searches accounts for `web-01`, clicks "Use for this server" (reason: "incident INC-4412"). Connect → Muya retrieves the secret, injects into the direct SSH session, zeroizes. Retrieval is logged in CyberArk's audit with her reason.

**UC3 — Operator stores a personal lab credential:** Has a homelab box not in CyberArk. Adds it to the **local encrypted store** (username + password), sets source = "local store". Connect works offline; on next app launch, Touch ID unlocks the store automatically; after 15 min idle it re-locks.

## 5. Architecture

**New Rust modules** (registered in `generate_handler!`, `lib.rs:160`; state via `.manage`):
- `credstore.rs` — encrypted store: Argon2id KDF (**run off the command executor thread** so unlock never freezes the UI, PM2), AES-256-GCM seal/open with **atomic temp+rename writes** (PM3), `zeroize` on secrets, Keychain integration via **`security-framework`** for the biometry/device-only key item (ARCH1), in-memory unlock state + auto-lock timer, and a **master-password re-key** operation (backup → re-encrypt → atomic rename, PM4).
- `cyberark.rs` — `reqwest` client (rustls, **TLS verify on**): logon/logoff, list accounts, retrieve password, test-connection. Session token held in memory only.
- `ssh.rs` — server CRUD + dedup, `muya-ssh-config.json` persistence, connection-string builder (PSMP + direct), `ssh_connect` → hands a command to the frontend to spawn via existing `pty_spawn`.

**New frontend:** `src/components/SshPage.tsx` — new `view === "ssh"` (union `App.tsx:345`, nav button `~:1359`, render block `~:1490`, import `~:56`). Three sub-tabs: **Sunucular / CyberArk / Şifre Store**. Talks to Rust via `invoke()`; opens terminals by reusing the terminal-tab creation path.

**Data at rest:**
- `~/.claude/muya-ssh-config.json` — non-secret: servers, PSMP profiles, CyberArk connection meta (URL/method/tls). **No passwords.**
- `~/.claude/muya-ssh-vault.enc` — AES-256-GCM sealed blob of local credentials.
- **macOS Keychain** — the Argon2id-derived store key (Touch ID gated); ephemeral CyberArk token stays in RAM only.

## 6. Data Model

`muya-ssh-config.json`:
```jsonc
{
  "version": 1,
  "servers": [{
    "id": "uuid", "label": "prod-db",
    "host": "10.0.0.5", "port": 22, "username": "oracle",
    "connectionType": "psmp" | "direct",
    "psmpProfileId": "uuid|null",
    "credentialSource": { "kind": "local" | "cyberark" | "prompt",
                          "localCredId": "uuid|null",
                          "cyberarkAccountId": "string|null" },
    "lastConnectedAt": "ISO8601|null", "tags": ["..."]
  }],
  "psmpProfiles": [{ "id":"uuid","label":"bastion1","psmpAddress":"bastion.corp",
                     "vaultUser":"ferhat","userDelim":"@","paramDelim":"#" }],
  "cyberark": { "baseUrl":"https://pvwa.corp","authMethod":"Cyberark|LDAP|RADIUS|Windows",
                "tlsVerify":true, "caCertPath":"string|null" }
}
```
Encrypted blob (`muya-ssh-vault.enc`), decrypted shape:
```jsonc
{ "version":1, "kdf":{"algo":"argon2id","salt":"b64","m":47104,"t":3,"p":1},  // m in KiB (≥46 MiB); t tuned to ~0.7s
  "credentials":[{"id":"uuid","label":"homelab-root","username":"root",
    "secretKind":"password" | "key",
    "secret":"<password OR private-key PEM, plaintext-in-memory-only>",
    "keyPassphrase":"<optional, if the key is encrypted>"}] }
```
On-disk format: `magic || version || salt || nonce || AES-256-GCM(ciphertext+tag)`.

**Dedup:** normalize `(host.toLowerCase(), port||22, username)`; reject/merge on collision (binary rule for AC).

## 7. API Contracts

**Tauri commands (new):**
| Command | In → Out |
|---|---|
| `ssh_list_servers` | () → `Server[]` |
| `ssh_upsert_server` | `Server` → `Ok \| DuplicateError` |
| `ssh_remove_server` | `id` → `Ok` |
| `ssh_build_connect_cmd` | `id` → `{ program:"ssh", args:[...] }` (no secret in args for PSMP) |
| `credstore_status` | () → `{ initialized, unlocked, autoLockInSec }` |
| `credstore_init` | `masterPw` → `Ok` |
| `credstore_unlock` | `masterPw \| viaKeychain` → `Ok \| BadPassword` |
| `credstore_lock` | () → `Ok` |
| `credstore_cred_list` | () → `{id,label,username}[]` (no secret) |
| `credstore_cred_upsert` | `{label,username,secret}` → `Ok` |
| `credstore_cred_remove` | `id` → `Ok` |
| `cyberark_test_connection` | `{baseUrl,method,username,password}` → `{ok,detail}` (Logon→Logoff) |
| `cyberark_logon` | `{...}` → `{sessionId}` (token in Rust memory, not returned raw) |
| `cyberark_list_accounts` | `{search,filter,offset,limit}` → `{value[],count}` |
| `cyberark_retrieve_secret` | `{accountId,reason}` → used internally at connect-time; never returns to JS unless explicitly "reveal" |
| `cyberark_logoff` | () → `Ok` |

**CyberArk REST (outbound, from `cyberark.rs`):**
- Logon: `POST {base}/PasswordVault/API/auth/{method}/Logon` body `{username,password,concurrentSession:true}` → token string. Fallback `POST {base}/PasswordVault/WebServices/auth/Cyberark/CyberArkAuthenticationService.svc/Logon` on 404.
- List: `GET {base}/PasswordVault/API/Accounts?search=&filter=&offset=&limit=` header `Authorization: <token>`.
- Retrieve: `POST {base}/PasswordVault/API/Accounts/{id}/Password/Retrieve` body `{reason}` → plaintext.
- Logoff: `POST {base}/PasswordVault/API/Auth/Logoff`.

## 8. Frontend

`SshPage.tsx`, mounted like other pages. Three sub-tabs. Reuses styling conventions from `VaultConfigPanel.tsx`. Connect action creates a terminal tab (existing path) rather than a bespoke terminal. `oncontextmenu` stays disabled in production (L5). Master-password and CyberArk-password inputs use `type=password`, never logged, cleared on unmount.

## 9. Auth, Secrets, Security

**Threat model — top 3 attackers:**
1. **Local malware / another user process** reading `~/.claude`: mitigated by AES-256-GCM at rest, Keychain item `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, no plaintext secret on disk. `[NEEDS-WEB-VERIFY]` (Keychain accessibility constant).
2. **Walk-up at an unlocked, idle Mac:** the store **auto-locks when the macOS screen locks / display sleeps** (operator-chosen trigger — subscribe to the screen-lock/`com.apple.screenIsLocked` notification), plus a manual Lock button; Touch ID (`kSecAccessControl` biometry) to re-open. (Idle-timer is a secondary option, off by default.)
3. **Network MITM on CyberArk API:** mitigated by **TLS verification always on**; internal CA trusted only via explicit `caCertPath` — there is **no "disable verification" toggle**.

**Rules (binary):**
- CyberArk master password: **never persisted**, held in Rust memory, `zeroize` on logoff/drop.
- No secret in: logs, process **argv**, PTY scrollback, or `muya-ssh-config.json`.
- Direct-SSH injection: password written to the child PTY **stdin** only (never argv/env), after the password prompt, with echo suppressed; buffer zeroized immediately after. Documented as best-effort vs PSMP (A1). Prefer `SSH_ASKPASS` one-shot helper over raw prompt-timing where feasible (architect optional).
- AES-GCM: fresh random 96-bit nonce per seal, stored alongside ciphertext; **never reused** (A3).
- Argon2id params persisted in the blob header for forward-compat; KDF runs **off the command thread** (PM2).
- **Reveal path (ARCH2):** revealing a CyberArk/local secret to the UI is **off by default**, masked, shown only on explicit user action, **never rendered into a terminal**, and cleared from JS state on unmount. It is outside the Rust zeroize boundary — treat as a distinct, audited surface (R10).
- **PSMP interactive fallback (PM1):** if a PSMP connection prompts interactively for the target password (misconfigured safe/account), that secret would land in scrollback — detect and warn; do not assume PSMP always injects.
- **No-swap (architect optional):** best-effort `mlock` the decrypted blob + CyberArk token; `zeroize` alone does not prevent swap-out.
- **SSH key auth (operator-confirmed scope) — ssh-agent ONLY, never on disk (ARCH-RG1):** the private key is loaded into an ephemeral in-process ssh-agent via the agent protocol (`SSH_AGENTC_ADD_IDENTITY`) exposed on a per-connection `SSH_AUTH_SOCK`; `ssh` picks it up from the socket. **Never** `ssh -i <file>`, never `ssh-add <file>`, never any plaintext key bytes on disk at any point. The identity is removed from the agent and the in-memory copy zeroized after the session ends. This preserves the §9 attacker-1 "no plaintext secret on disk" invariant and CyberArk's never-touches-disk guarantee.
- **RADIUS push 2FA (operator has it):** CyberArk logon may block pending phone approval; the logon/test flow uses an extended timeout (up to ~60 s) and surfaces "approve on your phone" rather than failing early; handles a returned challenge if the API uses challenge-response.

## 10. Phases

**Faz 0 — Secure crypto core (no UI). ✅ DONE 2026-07-24.** Crates `aes-gcm`, `argon2`, `zeroize` added. `credstore.rs`: init/unlock/lock/status, seal/open (AES-256-GCM, random 96-bit nonce), Argon2id KDF run off the command thread, atomic temp+rename writes, master-password re-key. Commands registered in `lib.rs`. 7 unit tests pass (AC0.1-0.4, 0.6, re-key, no-plaintext-on-disk). **Sequencing note:** the macOS Keychain / Touch-ID auto-unlock + `security-framework` + the `credstore_rekey` command moved to **Faz 1**, because Touch-ID/biometry cannot be verified in a headless `cargo test` (Golden Rule §3 — ship only what's proven). Faz 0 unlock is master-password-based; the tested crypto core is the same one Keychain will feed.

**Faz 1 — SSH page + Servers + local store UI + Keychain auto-unlock.** New `ssh` view; `SshPage.tsx` (3 tabs skeleton); `ssh.rs` server CRUD + dedup + `muya-ssh-config.json`; Şifre Store tab (create master, list/add/remove creds). **Keychain integration (moved from Faz 0):** `security-framework` device-only + `kSecAccessControl` biometry item caches the derived key, Touch-ID auto-unlock, auto-lock on macOS screen-lock (D8), `credstore_rekey` command that also updates/invalidates the Keychain item — all verified live in the running app.

**Faz 2 — Connect (PSMP + direct, password + key).** Connection-string builder (PSMP variants + direct); `ssh_build_connect_cmd`; open terminal tab via existing PTY. **Password** path: inject via PTY at connect-time, zeroize. **Key** path: load into an ephemeral in-process **ssh-agent** (`SSH_AUTH_SOCK`), never on disk (ARCH-RG1); remove identity + zeroize after session. Detect key-only hosts and password-rejecting hosts (AA1).

**Faz 3 — CyberArk (incl. RADIUS push 2FA).** `cyberark.rs`: config wizard, **real** test-connection (Logon→Logoff, v10 + .svc fallback) that **waits for RADIUS push approval** (extended timeout), account list (search/filter/paginate), retrieve secret (password or key per `secretType`); wire CyberArk as a credential source; retrieval reason captured.

## 11. Acceptance Criteria (binary)

**Faz 0**
- AC0.1: `cargo test` passes; a round-trip test seals `{secret:"x"}` and opens it back to `"x"`.
- AC0.2: unlock with wrong master password returns `BadPassword`, never plaintext.
- AC0.3: a test asserts 1000 seals produce 1000 **distinct** nonces.
- AC0.4: after `credstore_lock`, `credstore_cred_list` returns `Locked` error (no data).
- AC0.5 (**moved to Faz 1** — needs live Touch ID): Keychain item written via `security-framework` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `kSecAccessControl` biometry; verified by reading it back only after unlock (ARCH1).
- AC0.6: unlocking (Argon2id derive) does NOT block the command thread — a concurrent `credstore_status` call returns while a derive is in flight (PM2).

**Faz 1**
- AC1.1: SSH nav tab renders `SshPage`; switching away and back does not unmount the control-view terminal (L1 preserved).
- AC1.2: adding server `(10.0.0.5,22,oracle)` twice → second returns `DuplicateError`; list has 1.
- AC1.3: `muya-ssh-config.json` written with the server; contains **no** password field.
- AC1.4: creating a master password then adding a local cred, locking, unlocking via master password, `cred_list` shows it (secret not returned).
- AC1.5: changing the master password re-encrypts the blob atomically (backup kept until success); after change, old password fails and new password unlocks; a simulated crash mid-rekey leaves the original blob intact (PM4). **The Keychain-cached derived-key item is updated/invalidated in the same operation** so Touch-ID unlock never uses a stale key (architect note).

**Faz 2**
- AC2.1: for a PSMP server, `ssh_build_connect_cmd` returns args `["ferhat@oracle@10.0.0.5@bastion1"]` (no secret anywhere).
- AC2.2: Connect opens a new terminal tab running the ssh command (observed live).
- AC2.3: for a direct server with local-store **password** source, the secret is injected via PTY stdin (verified: not present in `ps` args nor terminal scrollback).
- AC2.4: for a server with **key** source, **no plaintext key file is ever created on disk** (fs-watch over the temp dir + home during connect shows zero key writes); the key is delivered only via `SSH_AUTH_SOCK` (ephemeral in-process ssh-agent); the identity is removed from the agent after the session and the in-memory copy zeroized (ARCH-RG1).
- AC2.5: connecting with a password to a key-only host (`PasswordAuthentication no`) does not hang — it aborts with an actionable message within **≤10 s** (AA1).

**Faz 3**
- AC3.1: Test Connection against a reachable PVWA with valid creds → `{ok:true}`; with bad creds → `{ok:false}` + reason; **real** Logon/Logoff (verified against operator's instance). With **RADIUS push**, the call waits for phone approval (extended timeout) and shows "approve on your phone"; approval → `{ok:true}`, denial/timeout → `{ok:false}` + reason.
- AC3.2: account list returns ≥1 account for a known safe with correct `{id,name,safeName,address,userName}` fields.
- AC3.3: retrieve for a permitted account returns a usable secret; a dual-control/locked account returns a clear 403 message, no hang.
- AC3.4: TLS: pointing at an untrusted-cert PVWA fails closed with a cert error (no silent bypass).

## 12. Risk Register

| ID | Risk | Sev | Likelihood | Mitigation | Owner |
|---|---|---|---|---|---|
| R1 | AES-GCM nonce reuse → confidentiality+integrity loss | Critical | Low | Random 96-bit nonce/seal, stored w/ ciphertext; AC0.3 test | impl |
| R2 | Keychain auto-unlock ⇒ store readable on unlocked idle Mac | High | Med | Auto-lock 15 min + manual lock + Touch ID re-auth + device-only accessibility | impl |
| R3 | Master password lost ⇒ store unrecoverable | High | Med | Destructive-warning UX; optional encrypted export; documented no-recovery | operator |
| R4 | Direct-SSH injection leaks secret (ps/echo/scrollback) | High | Med | PTY-stdin only, echo off, zeroize; prefer PSMP; documented best-effort | impl |
| R5 | CyberArk token expiry mid-session → 401 | Med | High | Detect 401 → prompt re-logon; ~20-min backstop | impl |
| R6 | Dual-control/exclusive account blocks retrieve → 403 | Med | Med | Surface clear message + guidance; no hang | impl |
| R7 | User forced to disable TLS verify for internal CA → MITM | High | Med | No disable toggle; add-CA path only; fail closed | impl |
| R8 | Secret lingers in memory / swap | Med | Low | `zeroize`; minimize lifetime; no clone-to-String where avoidable | impl |
| R9 | Tauri capability blocks outbound net / ssh spawn | Low | Low | Resolved (O2): `reqwest`+`portable-pty` run in Rust core, bypass frontend capability gate; verify no CSP/http-plugin path | impl |
| R10 | CyberArk/local secret **revealed to UI** leaks (JS heap, screen, scrollback) | High | Med | Reveal off-by-default, masked, never to terminal, cleared on unmount; outside zeroize boundary (ARCH2) | impl |
| R11 | Password used against a key-only host hangs at prompt | Med | Med | Now that key auth is in scope, pick the right method per server; detect password-rejecting host and abort with guidance (AA1) | impl |
| R14 | SSH private key exposed during key-auth connect | High | Low | **ssh-agent-only** (`SSH_AUTH_SOCK`), key bytes never on disk (ARCH-RG1); identity removed + memory zeroized after session | impl |
| R12 | Config/blob file corruption on concurrent write | Med | Med | Atomic temp+rename for both `.json` and `.enc` (PM3) | impl |
| R13 | KDF freezes UI or is set too weak to avoid freeze | Med | Med | Off-thread derive + calibrate to ~0.7 s, memory ≥46 MiB (PM2) | impl |

## 12.5 Failure Modes & Recovery

| Dependency/Component | Failure | Recovery |
|---|---|---|
| CyberArk PVWA | unreachable / DNS | test-connection times out (5 s) with actionable message; config saved, retry later |
| CyberArk TLS | untrusted cert | fail closed; prompt to add internal CA cert path |
| macOS Keychain | access denied / no biometry | fall back to master-password prompt each unlock; store still usable |
| `ssh` binary | missing/not on PATH | Connect surfaces "ssh not found"; no crash |
| PSMP host | refuses connection | terminal shows PSMP error verbatim; server config untouched |
| Encrypted blob | corrupted/tampered | GCM tag verify fails → "store corrupted"; offer restore-from-export |
| PSMP (interactive fallback) | PSMP prompts for target password instead of injecting | detect interactive prompt, warn secret may hit scrollback; recommend fixing safe/account config (PM1) |
| CyberArk behind load balancer | token bound to a node; next call hits another → 401 | on unexpected 401 after successful logon, re-logon once transparently; document sticky-session requirement (AA3) |
| Config / `.enc` write | crash or concurrent write mid-save | atomic temp-file + rename; never write in place (PM3) |
| Master-password re-key | crash during re-encrypt | keep original blob until new one is fsync'd + renamed; original stays valid (PM4) |

## 13. Edge Cases and Error Handling

- Empty/whitespace host or username → validation error before save.
- Port out of range → rejected.
- RADIUS challenge (2FA push/OTP) during Logon → v1 surfaces the challenge as a follow-up prompt if the API returns one (else O3).
- Concurrent connect clicks → idempotent per server; secret pulled once.
- App quit while unlocked → in-memory secrets dropped/zeroized; blob stays sealed.
- CyberArk returns HTML error page (not JSON) → detect content-type, show raw status.
- **Target has `PasswordAuthentication no` (key-only host)** → direct-inject would hang at a prompt that never accepts a password; detect repeated prompt / `Permission denied` and abort with "target rejects password auth — use PSMP or an SSH key (v2)" (AA1).
- **CyberArk account is `secretType:"key"` (SSH private key, not a password)** → retrieve returns a key; v1 routes it to the **key auth path (ssh-agent only, never on disk, ARCH-RG1)**, not the password-prompt path (AA2; key auth is in scope per §2.1). The Vault's key never touches disk.
- **CyberArk user lacks REST/API entitlement** → `/API/auth` returns 403 even with correct creds; test-connection distinguishes 401 (bad creds) from 403 (no API permission) in its message.

## 14. Performance & Cost Budget

- Argon2id derive target **~0.7 s** on Apple Silicon, **memory ≥ 46 MiB** (above the OWASP 19 MiB floor — RAM is not scarce on target hardware; architect recommendation), `t` tuned to hit the time target, `p=1`. Derive runs **off the command thread** so the UI never blocks (PM2). Params stored in blob header. `[NEEDS-WEB-VERIFY exact OWASP numbers]`
- CyberArk test-connection timeout **5 s** for non-2FA; **up to ~60 s** when RADIUS push 2FA is enabled (waiting for phone approval, D9) — this is the `reqwest` **per-request (response) timeout**, not the connect timeout (architect note). List/retrieve timeout **10 s**.
- Store operations local, sub-ms aside from KDF. No cloud cost (local tool; CyberArk is the operator's own infra).

## 15. Out of Scope

See §2. Also: automatic CyberArk account onboarding, credential rotation, SIEM export of Muya-side audit, and Windows/Linux ports.

## 15.5 Decision Log

| # | Decision | Alternatives | Why | AC |
|---|---|---|---|---|
| D1 | Store model = encrypted file (AES-256-GCM, Argon2id key) + Keychain-cached key, Touch ID auto-unlock (**Model A**) | Keychain-only; Stronghold plugin | Operator-confirmed; portable + exportable + transparent crypto vs Keychain-only lock-in / Stronghold opacity | Faz 0/1 |
| D2 | CyberArk master password **session-only** | Store encrypted in vault | Operator-confirmed; CyberArk best practice — master secret never at rest | §9 |
| D3 | SSH = **PSMP + direct-inject** both | PSMP-only | Operator-confirmed; direct-inject documented as best-effort (R4) | Faz 2 |
| D4 | Crates: `aes-gcm`, `argon2`, `zeroize`, **`security-framework`** (biometry/device-only Keychain), `keyring` (fallback only) | `keyring`-only (rejected: no biometry/`kSecAccessControl`); ring/RustCrypto lower-level | ARCH1: `security-framework` is the only crate that enforces Touch-ID + device-only accessibility required by §9/R2 | Faz 0 |
| D5 | v10 REST logon with `.svc` fallback | v10-only; .svc-only | Modern primary + compatibility with older PVWA | Faz 3 |
| D6 | Argon2id params `m≥47104 KiB (≥46 MiB), t=3→tuned, p=1`, ~0.7 s, off-thread | OWASP 19 MiB floor | Architect: raise memory well above floor on Apple Silicon; tunable in blob header (PM2) | Faz 0 |
| D7 | Support **both password and SSH key** auth (using existing keys; key generation out); key auth via **ephemeral in-process ssh-agent only, never on disk** | password-only (rejected by operator); `ssh -i` temp file (rejected by architect ARCH-RG1 — violates no-plaintext-on-disk) | Operator: general SSH manager; Architect: ssh-agent preserves §9 invariant + CyberArk guarantee | Faz 2 |
| D8 | Auto-lock trigger = **macOS screen lock**, not idle timer | 15-min idle timer | Operator preference #3 | Faz 1 |
| D9 | RADIUS **push 2FA** in scope; logon waits for approval (~60 s) | defer 2FA | Operator has push 2FA #4 | Faz 3 |

## 16. Production-Readiness Checklist

- [x] Risk Register ≥ 5 risks w/ mitigation + owner (9)
- [x] Failure Modes & Recovery per external dep
- [x] ≥ 3 use cases with personas
- [x] SYSTEM.md references verified (cites from refreshed 2026-07-24 doc)
- [~] Industry claims sourced — CyberArk sourced; others `[NEEDS-WEB-VERIFY]` (spend limit)
- [x] Compliance row per regime
- [x] Security threat model top-3 attackers
- [x] Cost/perf budget with numbers
- [x] Migration story (§below)
- [x] Decision Log complete
- [x] Open Questions numbered + owned
- [x] No P0/P1 risk without owner
- [x] Rollback semantics (§below)

**Migration/back-compat:** additive only — new files, new commands, new view. No existing schema touched. Rollback = delete the two `muya-ssh-*.json/.enc` files + Keychain item; no impact on existing Muya state.

## 17. Open Questions

1. **O1 (RESOLVED, operator 2026-07-24):** auto-lock trigger = **when the macOS screen locks / display sleeps** (not a fixed idle timer). Idle-timer optional/off by default.
2. **O2 (RESOLVED, impl):** Tauri capability change is NOT needed — `reqwest` (HTTPS) and `portable-pty` spawn run in the Rust core and bypass the frontend capability gate (`capabilities/default.json`). Verify only that no CSP / frontend http-plugin path is used (architect finding).
6. **O6 (RESOLVED, operator 2026-07-24):** it's a general SSH connection manager — support **all** auth types the fleet uses (password AND key). Key auth moved into scope (§2.1). (AA1)
7. **O7 (RESOLVED, operator 2026-07-24):** operator's CyberArk stores **passwords**; the manager still handles key-type accounts generically via the key path. (AA2)
8. **O8 (impl):** is your PVWA behind a load balancer needing sticky sessions? Design re-logs-on on unexpected 401; confirm this is acceptable. *Owner: impl/operator. Deadline: Faz 3.* (AA3)
3. **O3 (RESOLVED, operator 2026-07-24):** operator HAS RADIUS **push-notification** 2FA → **in scope for v1**. Logon/test waits for phone approval (extended timeout), handles challenge-response if used (§2.1, Faz 3).
4. **O4 (operator):** PSMP delimiter defaults — assume `@`/`#`; expose override per profile? *Default: expose override, prefill `@`/`#`.*
5. **O5 (process):** architect GO acceptance gate could not run (spend limit). Accept inline review, or wait to dispatch `software-architect` before Phase 3? *Owner: operator.*

## 18. Appendix — Research Log

- CyberArk PAM web services — https://docs.cyberark.com/pam-self-hosted/latest/en/content/webservices/implementing%20privileged%20account%20security%20web%20services%20.htm (v10 logon, Accounts, Retrieve, Logoff; token-as-Authorization; ~20-min idle).
- SecApps CyberArk REST API Guide 2026 — https://secappslearning.com/post/cyberark-rest-api-complete-guide-2026-authentication-automation-powershell-apis-examples-best-practices (auth methods, pagination, error handling).
- PSMP SSH syntax — CyberArk PSM-for-SSH docs `[NEEDS-WEB-VERIFY]` (corroborated by community cheat-sheets).
- OWASP Password Storage / NIST SP 800-38D (Argon2id, GCM nonce) — `[NEEDS-WEB-VERIFY]` (Phase 2a extended research interrupted by spend limit).
