# PRD — Claude-to-Claude Remote Bridge

**Status:** Implemented — all 4 phases done & verified (2026-07-15)
**Owner:** staunch (operator)
**Implementer:** Claude Code (via `/prd-run`)
**Drafted with:** claude-fable-5 (user opted out of Opus 4.8; Fable 5 is newer/more capable)
**Depends on:** `docs/adr/claude-remote-bridge-architecture.md` (ADR 0002, 2026-07-15) · `docs/SYSTEM.md` (2026-06-16, stale — feature is net-new; grounding re-verified against current code)
**Target release:** Faz 1 (Local MVP)
**Production-readiness state:** Checklist complete — pending architect GO

---

## §0 Review Log

Adversarial analysis was performed at the ADR stage: `software-architect` applied the Mühendislik Karar Doktrini (≥3 options per decision, pre-mortem refutation, threat-model attack tree) — see ADR 0002 §Threat Model and per-decision pre-mortems. Findings from that pass are already folded into §8 (Security), §9 (Failure Modes), and §10 (Risk Register) below.

| ID | Severity | Title | Status | Notes |
|---|---|---|---|---|
| A1 | FATAL | localhost-spoofing to skip auth | applied | ADR D3 — separate UDS/TCP sockets; "localhost?" never gates auth. §8. |
| A2 | FATAL | MITM on first pairing | applied | ADR D2 — CPace PAKE + SAS binds PIN to pinned cert. §8. |
| A3 | SERIOUS | auto-run + prompt-injected peer → silent RCE | applied | §10 R1; auto-run gated by capped capability scope + sandbox even when approval is skipped. |
| A4 | SERIOUS | auto-run + memory-only audit → weak forensics | escalated-to-user → accepted | §10 R2 — operator's informed choice; memory-audit retained in-session. |
| A5 | HIGH | fan-out multiplies independent RCE surfaces | applied | §8 — each target independently gated by its own per-peer scope/approval. |

**Review rounds:** 1 (ADR-stage adversarial + this synthesis)
**Reviewer:** software-architect (ADR 0002)
**Recommend gate pass:** pending Phase 2c acceptance gate

---

## 1. Goal (Why)

Let one Muya user's Claude delegate work to another Muya user's Claude across two machines — ask a question, hand off a terminal task (SSH, research, code), and stream the result back — over a direct, mutually-authenticated peer-to-peer link. The operator drives it with a `/remote-claude` skill inside a terminal: "ask/have the remote Claude do X." Security is the whole point of the design, not a bolt-on: the receiving side runs terminal-capable work, so every inbound task is treated as untrusted regardless of who sent it.

## 2. Non-goals

- Does **not** introduce a relay/rendezvous server — topology is strictly direct peer-to-peer (ADR D1).
- Does **not** loosen the existing CSP (`tauri.conf.json:21`) — all network I/O stays in Rust; the frontend remains `ipc:`-only (ADR grounding).
- Does **not** ship public-internet reach in Faz 1 — LAN-only MVP, forward-compatible for internet later (operator answer Q3).
- Does **not** persist request payloads or task outputs to disk — memory-only (operator answer Q2).
- Does **not** write inbound payloads into a live PTY — payloads reach the remote Claude via a broker queue only (ADR D6).
- Does **not** change existing terminal/PTY, vault, or session features.

## 3. Background and context

Muya today is entirely local: every capability is a Tauri command invoked from the webview (`src-tauri/src/lib.rs:136` `generate_handler![...]`), and there is **no inbound network socket anywhere in the app** — this feature opens the first one, so the threat surface is net-new. Terminals run real shells via `pty.rs` (`pty_spawn` at `pty.rs:46`), which already strips `CLAUDE*`/`AI_AGENT` env for a clean session and uses a bounded `sync_channel(256)` backpressure queue for output — both patterns are reused by the bridge. There is no way today for two Muya instances to talk; users would manually copy/paste between machines or set up SSH by hand. Crypto deps are already in tree (`reqwest` with `rustls-tls`; `tokio` async — only the `net` feature must be added).

## 3.5 Industry context & benchmark

### How production systems solve this today

| Pattern | Source | Takeaway |
|---|---|---|
| Balanced PAKE for PIN pairing | CFRG selected **CPace** as the balanced-PAKE winner ([PAKE overview](https://en.wikipedia.org/wiki/Password-authenticated_key_agreement)) | A short PIN can bootstrap MITM-resistant trust without a CA — but only via PAKE; naive PIN-as-HMAC leaks to offline dictionary attack. |
| SPKI public-key pinning (TOFU) | [OWASP Certificate/Public-Key Pinning](https://owasp.org/www-community/controls/Certificate_and_Public_Key_Pinning), [Android Wi-Fi TOFU](https://source.android.com/docs/core/connect/wifi-tofu) | Pin the SPKI hash, not the full cert — survives cert rotation, stable identity across reconnects. |
| Unix-domain socket + filesystem perms for same-user auth | [MySQL socket auth](https://dev.mysql.com/doc/mysql-security-excerpt/8.0/en/socket-pluggable-authentication.html) | Kernel-enforced owner-only (0600) socket is a robust "local = same user" boundary — no uid guesswork. |
| HITL / elicitation before tool execution | [MCP spec — tools & elicitation](https://modelcontextprotocol.io/specification/2025-06-18/server/tools) | Human approval of the exact action before execution is the standard control for agent-triggered side effects. |

### Known failure modes (drive Risk Register + Failure Modes)

| Failure | Source | Consequence |
|---|---|---|
| `SO_PEERCRED` peer-cred is spoofable / non-portable | [CVE-2025-14282 peercred bypass](https://www.openwall.com/lists/oss-security/2025/12/16/2), [Nuxt IPC socket bypass](https://dailycve.com/nuxt-dev-server-ipc-socket-permission-bypass-ghsa-5gvc-46gq-948j-dc-jun2026-458/) | Cannot rely on peer-cred to prove "local" — use separate sockets + fs perms instead (ADR D3). |
| Prompt-injection → RCE in AI agents | [Trail of Bits: prompt-injection→RCE](https://blog.trailofbits.com/2025/10/22/prompt-injection-to-rce-in-ai-agents/), [OWASP MCP05 command injection](https://owasp.org/www-project-mcp-top-10/2025/MCP05-2025%E2%80%93Command-Injection&Execution) | A trusted-but-injected peer can relay attacker instructions — inbound tasks must be untrusted-by-default + sandboxed. |
| HTTP/2 rapid-reset DoS | CVE-2023-44487 (ADR D1 pre-mortem) | Avoid HTTP machinery for a 2-peer link — raw tokio-rustls + length-prefixed frames instead. |
| mTLS client-cert not enforced | [tokio-rustls #83](https://github.com/rustls/tokio-rustls/issues/83) | The "no client cert" path must be explicitly fail-closed in the verifier. |

### Alternatives considered (full refutation in ADR 0002)

Transport: axum/hyper HTTP2 · gRPC · QUIC(quinn) — all rejected/deferred vs raw `tokio-rustls` (D1). Pairing: SPAKE2 · PSK+HMAC — rejected vs CPace (D2). Local boundary: single loopback TCP · `SO_PEERCRED` — rejected vs separate UDS/TCP sockets (D3).

## 4. Actors & use cases

**Actor:** the operator (a human) on each machine, driving their local Claude. The remote machine's Claude has its own human-defined model/config.

- **UC1 — Advisory question.** Operator A: "`/remote-claude` ask peer *lab-mac*: what's the best way to X?" → request crosses the bridge → remote Claude answers → answer streams back into A's terminal. (Capability: `research`.)
- **UC2 — Delegated terminal task.** Operator A: "`/remote-claude` have *lab-mac* run the nightly SSH backup and report." → inbound task shown to B for approval (or auto-run if B pre-authorized this peer+capability) → runs in a sandboxed cwd on B → output streams back to A. (Capability: `shell`.)
- **UC3 — First pairing.** B clicks "Pair (Remote)" → Muya shows an 8-digit PIN → A enters it when dialing B's address → CPace + SAS confirm → SPKI pinned under label "lab-mac". Subsequent connects need no PIN.
- **UC4 — Local same-machine bridge.** Two Claude sessions on one host talk over the owner-only UDS with **no PIN/crypto** (operator requirement).
- **UC5 — Fan-out.** Operator A sends one research task to peers *lab-mac* + *build-box*; each is independently gated by its own per-peer scope/approval; results stream back tagged by peer.

## 5. Scope

**In scope (Faz 1–3):** direct P2P bridge; local UDS (no-auth) + remote mTLS TCP (paired); CPace PIN pairing + SPKI pinning; per-peer capability scope (`research`/`shell`/`file`); approve-each default + per-peer auto-run opt-in; sandboxed inbound execution; memory-only audit; length-prefixed JSON envelope with streaming; new "chat" view with a clearly-separated **Remote / Local** UI; `/remote-claude` skill integration via broker queue; 1:1 and fan-out send.

**Out of scope (this PRD):** public-internet/NAT traversal (deferred, design forward-compatible); disk persistence of transcripts; OS-level sandbox (seatbelt/landlock) beyond worktree+env-strip isolation (follow-on hardening); Windows named-pipe local path (flagged platform work — macOS-first).

## 6. Architecture & seam (from ADR 0002)

New Rust module `src-tauri/src/bridge.rs` (Bounded Context — owns its model; crosses to pty/agents only via the versioned envelope). **Two separate listeners:** LOCAL = Unix-domain socket, mode 0600, per-user app-data dir; REMOTE = `tokio-rustls` mTLS TCP, off by default, bound to a specific interface, **never `0.0.0.0`** (startup assertion + test). Trust = *which socket accepted the connection*, never a runtime "is-localhost?" check. Identity = per-peer self-signed **Ed25519** keypair in OS keychain. Frame = length-prefixed (u32 BE, ≤16 MB) JSON envelope (ADR D6). Inbound payload → **broker queue** the `/remote-claude` skill polls (never a raw PTY write).

**Tauri commands:** `bridge_local_listen`, `bridge_remote_listen(enable, iface)`, `bridge_pair_invite`, `bridge_pair_connect`, `bridge_pair_confirm_sas`, `bridge_list_peers`, `bridge_revoke_peer`, `bridge_send`, `bridge_approve`, `bridge_set_capability`. **Events:** `bridge://pairing-request`, `bridge://sas-compare`, `bridge://inbound-request`, `bridge://stream-chunk`, `bridge://stream-end`, `bridge://peer-status`, `bridge://error`. **Capability delta:** add scoped `bridge:*` set to `capabilities/default.json`; no CSP change.

## 7. Phases & binary acceptance criteria

### Faz 0 — Prep (✅ done)
- **AC-0-1:** `tokio` gains `net` feature; `rustls`/`tokio-rustls` direct deps added; `cargo build` + `cargo test` green.
- **AC-0-2:** `bridge.rs` scaffolded + registered in `lib.rs` `generate_handler!`; empty `bridge_local_listen(true)`/`(false)` bind then unbind a UDS without error.
- **AC-0-3:** New `"chat"` view added to `App.tsx:342` view enum + nav button; screen shows two visually-separated sections labeled **Remote** and **Local** (no logic yet).

### Faz 1 — Local MVP (✅ done)
- **AC-1-1:** Owner-only UDS listener (mode 0600) accepts a connection from the same uid; a **second local uid** connecting is refused by the kernel (perm denied) — proven by a test.
- **AC-1-2:** Length-prefixed JSON envelope round-trips: a canonical `request` frame in → matching `response` frame out; a frame declaring length > 16 MB is rejected **before** parse.
- **AC-1-3:** Broker queue holds inbound requests; `/remote-claude` skill reads from the queue (never from a raw socket); no inbound bytes reach a PTY directly.
- **AC-1-4 (contract test, Golden Rule §2):** a mock peer sends a canonical envelope over the UDS → receiver emits `bridge://inbound-request` **and** produces a matching `response` frame end-to-end.
- **AC-1-5:** approve-each wired: an inbound `shell` task is NOT executed until `bridge_approve(req_id, "allow")`; `bridge_approve(req_id, "deny")` blocks it.

### Faz 2 — Remote mTLS + pairing (✅ done)
- **AC-2-1:** Ed25519 identity keypair generated on first run, stored 0600 in keychain/app-data; SPKI hash derivable.
- **AC-2-2:** Remote mTLS TCP listener is **off by default**; when enabled it binds a specific interface and a test asserts it **never** binds `0.0.0.0`.
- **AC-2-3:** CPace pairing: two hosts with the correct PIN complete pairing and pin each other's SPKI; a **wrong PIN** fails; a simulated MITM presenting its own cert **fails closed** (SAS mismatch).
- **AC-2-4:** A dial with **no client cert** or an **unpinned** cert is rejected at handshake (fail-closed verifier).
- **AC-2-5:** PIN is single-use, 5-min TTL, ≤5 attempts then lockout; reconnect after pairing needs no PIN and re-verifies the pinned SPKI.

### Faz 3 — Task handoff, files, streaming, capability enforcement (✅ done)
- **AC-3-1:** `shell` task from a paired peer runs in a **dedicated worktree/cwd** with env stripped (incl. `CLAUDE*` + secrets); does not inherit the operator's live shell.
- **AC-3-2:** Task output streams back as `chunk` frames terminated by `end`, backpressured by the bounded queue (a runaway job OOMs neither side).
- **AC-3-3:** Per-peer capability scope enforced server-side: a `research`-scoped peer requesting `shell` is **rejected + logged**; an over-16 MB or over-scope payload is blocked.
- **AC-3-4:** Per-peer **auto-run opt-in**: a peer explicitly set to auto-run within capability `research` executes without per-request approval; the **same** peer requesting `shell` (not auto-run-granted) still requires approval. Default (no opt-in) = approve-each.
- **AC-3-5:** Memory-only audit: every inbound request+decision+output-hash is recorded in an **in-session** audit log queryable via a command; nothing is written to disk; restart clears it.
- **AC-3-6:** Fan-out: `bridge_send` to two peers dispatches independently; each target enforces its **own** scope/approval; results stream back tagged per peer.
- **AC-3-7 (R1 invariant):** The `shell` capability is **not auto-run-eligible by default** — attempting to grant auto-run for `shell` via `bridge_set_capability` is refused (or requires an explicit separate override flag), proven by a test; `research`/`file` may be auto-run-granted. This makes the R1 mitigation a binary, testable guarantee, not just prose.

## 8. Security review

- **Auth/identity:** per-peer Ed25519 self-signed, SPKI-pin TOFU, no CA (ADR D1). Remote = fail-closed mTLS verifier accepting only pinned SPKIs (tokio-rustls #83). Local = kernel-enforced owner-only UDS — **"localhost" never gates auth** (kills spoof class E; ADR D3).
- **First-contact MITM:** CPace PAKE + 6-digit SAS binds the human PIN to the pinned cert; PIN single-use/TTL/lockout throttles online guessing; offline-dictionary-proof (ADR D2). **SAS UX must force compare/enter** — a "just click OK" flow silently downgrades to plain TOFU (tracked risk R3).
- **RCE crux (elevated by auto-run choice):** every inbound task is untrusted regardless of peer trust. Default approve-each with a human-readable command diff. **Auto-run** is per-peer explicit opt-in, bounded to a **capped capability scope**, and STILL runs sandboxed (dedicated cwd, env-strip, `validate.rs` guards). `shell` capability should not be auto-run-eligible by default (R1 mitigation).
- **Fan-out:** each target independently gated — no shared approval that could blanket-authorize multiple RCE surfaces (A5).
- **Prompt-injection:** payloads never written to a live PTY (broker queue only, ADR D6); the receiving `/remote-claude` skill renders the request for approval before handing to Claude.
- **Audit/repudiation:** memory-only in-session audit (operator chose no-disk) — accepted weaker forensics (R2).
- **Rate limiting / DoS:** length-prefix rejects oversized frames pre-parse; bounded queue backpressure; pairing lockout.

## 9. Failure modes & recovery

| Dependency / surface | Failure | Recovery |
|---|---|---|
| Remote peer offline | dial times out | `bridge://peer-status` = offline; request queued client-side or errored back to the sender; no partial execution. |
| mTLS handshake fails (unpinned/no cert) | connection rejected | fail-closed; `bridge://error`; peer stays unpaired; no data crosses. |
| Pairing MITM / wrong PIN | SAS mismatch or PAKE fail | pairing aborts; PIN burned; operator retries with a fresh PIN. |
| Runaway remote task output | flood | bounded queue backpressures the sender; `end`/error frame; task killable via existing pty kill path. |
| Malformed / oversized frame | parse/DoS attempt | rejected before parse (length cap); connection dropped; logged in-session. |
| Keychain unavailable | identity key can't load | remote bridge refuses to start (fail-closed); local UDS still works. |
| App restart | memory audit + queues lost | by design (no-disk); pairings persist (registry), in-flight requests are dropped, not silently resumed. |

## 10. Risk register

| ID | Risk | Sev | Likelihood | Mitigation | Owner |
|---|---|---|---|---|---|
| R1 | Auto-run + prompt-injected peer → silent RCE | Critical | Medium (auto-run opt-in exists) | Auto-run bounded to capped capability scope; `shell` not auto-run-eligible by default; sandbox+env-strip even when approval skipped; per-peer opt-in explicit | operator/impl |
| R2 | Memory-only audit → weak forensics after restart | High | High (by design) | Accepted (operator choice); in-session audit retained; document the tradeoff in UI | operator |
| R3 | SAS "click-OK" fatigue silently downgrades pairing to TOFU | High | Medium | Force digit compare/entry in UI, not a single confirm button; block until entered | impl |
| R4 | Remote listener accidentally binds `0.0.0.0` in a refactor | Critical | Low | Startup assertion + dedicated test (AC-2-2); default-off | impl |
| R5 | Fan-out blanket-authorizes multiple RCE surfaces | High | Medium | Independent per-peer scope/approval; no shared approval path (AC-3-6) | impl |
| R6 | Hand-rolled frame parser bug (memory-safety/DoS) | Medium | Medium | cargo-fuzz target on the parser; length cap; reject-before-parse | impl |
| R7 | CPace crate immaturity / vuln | Medium | Low | Pin a vetted crate + version; audit; versioned PAKE wire format for swap | impl |

## 11. Cost & performance budget

- Latency: LAN request→response overhead target < 50 ms excluding remote task runtime.
- Frame cap: 16 MB hard max; bounded queue ≈ 2 MB in flight (reuse `pty.rs` sizing).
- No cloud/infra cost (P2P, no server). Memory-only → bounded by session.

## 12. Compliance

Personal-use tool, direct P2P, no third-party data processor, no disk persistence of payloads (operator choice) — minimizes data-at-rest exposure (KVKK/GDPR data-minimization aligned). If public-internet reach is added later, revisit (peers could be external parties). No PII collected by the bridge itself beyond peer labels the operator chooses.

## 13. Backwards compatibility & migration

Net-new feature; no existing behavior changes. All one-way-door formats versioned from v1: PAKE wire messages, envelope `v`, pinned-peer registry schema (ADR D2/D5/D6). Remote listener ships **off by default** — zero change to existing installs until explicitly enabled.

## 14. Open questions

All Phase-1-blocking product-intent questions were answered by the operator (2026-07-15): exec posture = per-peer auto-run opt-in; network = LAN-now/internet-later; retention = memory-only; fan-out = yes. Remaining, **non-blocking** for Faz 1:
- OQ1 (Faz 2+): exact capability taxonomy beyond `research`/`shell`/`file` — adopted architect default; operator may refine before Faz 3.
- OQ2 (Faz 2+): public-internet NAT-traversal approach (QUIC vs port-forward guidance) — deferred with the internet phase.
- OQ3 (platform): Windows local path (named pipe + owner-only DACL) — macOS-first; revisit for Windows builds.

## 15. Decision log

| # | Decision | Alternatives | Why | Relates to |
|---|---|---|---|---|
| D1 | Raw tokio-rustls + length-prefixed JSON | axum/hyper, gRPC, QUIC | smallest attack surface for a 2-peer link; no HTTP DoS/smuggling (ADR D1) | AC-1-2, AC-3-2 |
| D2 | CPace PAKE + SAS + SPKI pin | SPAKE2, PSK+HMAC | CFRG winner; MITM-resistant first contact; offline-dictionary-proof (ADR D2) | AC-2-3..5 |
| D3 | Separate UDS(local)/TCP(remote) sockets | single loopback TCP, SO_PEERCRED | trust = which socket accepted you; kills localhost-spoof structurally (ADR D3) | AC-1-1, AC-2-2 |
| D4 | Layered exec: approve-each default + per-peer auto-run opt-in (capped scope) + sandbox + memory-audit | auto-run default, approve-only | operator chose auto-run opt-in; layering bounds blast radius (ADR D4 + operator Q1) | AC-3-3..5 |
| D5 | Memory-only audit, no disk | disk audit, full transcript | operator privacy choice (Q2); accept weaker forensics (R2) | AC-3-5 |
| D6 | LAN-only MVP, internet-forward-compatible | internet-now | operator Q3; smaller MVP attack surface | §5, OQ2 |
| D7 | Fan-out supported, per-peer independent gating | 1:1 only | operator Q4; each target its own scope/approval (R5) | AC-3-6 |
| D8 | Broker queue for payload handoff, never raw PTY write | direct PTY write | PTY write is itself an injection vector (ADR D6) | AC-1-3 |

## 16. Appendix — research log

Primary sources (all fetched by architect during ADR 0002): tokio-rustls [repo](https://github.com/rustls/tokio-rustls) + [#83](https://github.com/rustls/tokio-rustls/issues/83); [CPace/PAKE](https://en.wikipedia.org/wiki/Password-authenticated_key_agreement); [RFC 9383](https://www.rfc-editor.org/info/rfc9383/); [OWASP pinning](https://owasp.org/www-community/controls/Certificate_and_Public_Key_Pinning); [CVE-2025-14282 peercred](https://www.openwall.com/lists/oss-security/2025/12/16/2); [MySQL socket auth](https://dev.mysql.com/doc/mysql-security-excerpt/8.0/en/socket-pluggable-authentication.html); [MCP tools/elicitation](https://modelcontextprotocol.io/specification/2025-06-18/server/tools); [OWASP MCP05](https://owasp.org/www-project-mcp-top-10/2025/MCP05-2025%E2%80%93Command-Injection&Execution); [Trail of Bits prompt-injection→RCE](https://blog.trailofbits.com/2025/10/22/prompt-injection-to-rce-in-ai-agents/).
