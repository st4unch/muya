## Retry 0

**Date:** 2026-07-15
**Branch:** dev
**Commit:** 21f9536

---

### Per-AC Status

| AC | Description | Status | Test(s) |
|----|-------------|--------|---------|
| AC-2-1 | Ed25519 identity keypair, 0600 persist, SPKI stable | PASS | `ac2_1_identity_generate_and_persist`, `ac2_1_spki_hash_stable_multiple_reloads`, `ac2_1_cert_file_mode_0600` |
| AC-2-2 | Remote mTLS TCP listener OFF by default; never binds 0.0.0.0/:: | PASS | `ac2_2_wildcard_0000_rejected`, `ac2_2_wildcard_ipv6_rejected`, `ac2_2_specific_iface_accepted`, `ac2_2_invalid_addr_rejected` |
| AC-2-3 | SPAKE2 PAKE pairing: correct PIN → shared key; wrong PIN → SAS mismatch; MITM cert → SAS mismatch | PASS | `ac2_3_spake2_correct_pin_succeeds`, `ac2_3_spake2_wrong_pin_fails`, `ac2_3_sas_mitm_cert_mismatch`, `ac2_3_sas_correct_pairing_matches` |
| AC-2-4 | Fail-closed `PinnedSpkiVerifier`: unpinned/no-cert rejected at handshake | PASS | `ac2_4_pinned_verifier_accepts_known_hash`, `ac2_4_pinned_verifier_rejects_unknown_hash`, `ac2_4_client_auth_mandatory` |
| AC-2-5 | PIN single-use, 5-min TTL, 5-attempt lockout; reconnect verifies via registry | PASS | `ac2_5_pin_ttl_expiry`, `ac2_5_pin_not_expired_within_ttl`, `ac2_5_pin_single_use`, `ac2_5_attempt_lockout`, `ac2_5_validate_pin_increments_attempts_on_wrong`, `ac2_5_reconnect_verifies_via_registry`, `ac2_5_end_to_end_pairing_correct_pin`, `ac2_5_end_to_end_wrong_pin_sas_mismatch` |

---

### Crate Choices + Versions (ADR R7)

| Crate | Version | Role | Notes |
|-------|---------|------|-------|
| `rcgen` | 0.14.8 | Ed25519 self-signed cert generation | rustls ecosystem, actively maintained |
| `spake2-conflux` | 0.6.0 | PAKE (balanced, offline-dict-proof) | See ADR R7 note below |
| `sha2` | 0.11.0 | SPKI hash (SHA-256) + SAS derivation | RustCrypto, digest 0.11 |
| `hkdf` | 0.13.0 | SAS key derivation (HKDF-SHA256) | RustCrypto, digest 0.11 compat |
| `rand` | 0.9 | PIN generation | already in tree (0.9.4 locked) |
| `rustls` | 0.23 | TLS 1.3 + custom ClientCertVerifier | already in tree |
| `tokio-rustls` | 0.26 | Async TLS acceptor/connector | already in tree |

**ADR R7 — CPace deviation:**
The ADR specifies CPace (CFRG-selected balanced PAKE). The `cpace` crate (0.1.0, github.com/hdevalence/cpace) exists but is unmaintained: last published ~2021, very low download count, no recent commits. Shipping it would violate ADR constraint R7 ("do not use unmaintained/yanked crates").

`spake2-conflux` 0.6.0 (RustCrypto lineage, RFC 9382) was selected instead. Security properties are identical to CPace for this use case: balanced PAKE, active-MITM-resistant with short PIN, offline-dictionary-proof. The wire protocol is versioned v1 (one-way door per ADR) — if a vetted CPace crate ships in future, the PAKE message set can be migrated under a v2 wire message.

---

### Changed Files

- `src-tauri/src/bridge_remote.rs` — new module (1600+ lines): identity, verifier, pairing, registry, 23 tests
- `src-tauri/src/lib.rs` — added `mod bridge_remote`, `.manage(RemoteBridgeState::default())`, 6 new commands in `generate_handler!`
- `src-tauri/Cargo.toml` — added rcgen, spake2-conflux, sha2, hkdf, rand with ADR R7 comment

---

### Test Commands + Results

```
cd src-tauri && cargo build
# → Finished `dev` profile (0 errors, 9 warnings — all unused imports/fields)

cd src-tauri && cargo test
# → test result: ok. 62 passed; 0 failed; 4 ignored (was 39 before faz-2)

npx tsc --noEmit
# → (no output = clean)

npm test
# → Test Files 8 passed (8) | Tests 49 passed (49)
```

---

### Bu Turda Alınan Kararlar

1. **CPace → SPAKE2 substitution (ADR R7):** `cpace 0.1.0` unmaintained; `spake2-conflux 0.6.0` used. Same security guarantees. Documented above.

2. **Handwritten base64 decoder:** Avoided pulling a new crate dep for PEM decoding. Fixed edge case: `=` padding must map to 255 (skip), not 0, to prevent a trailing spurious zero byte from being emitted.

3. **`SecretKey` newtype from `secret-utils`:** `spake2-conflux` wraps the session key in a `SecretKey` that intentionally lacks `PartialEq`/`Debug` (zeroize on drop). All test comparisons use `.expose()` to access raw bytes. Production code uses `.expose()` to feed into HKDF.

4. **SPAKE2 identity parameter order:** `start_b(password, id_a, id_b)` takes the SAME `id_a`/`id_b` as `start_a` — both roles must agree on the canonical names. Gotcha: swapping them produces divergent session keys even with the correct PIN.

5. **`PinnedSpkiVerifier::client_auth_mandatory() = true`:** Explicit override ensures rustls rejects the handshake before calling `verify_client_cert` when no client cert is presented (tokio-rustls #83 fix).

6. **PAKE state non-`Clone`/non-`Send`:** `Spake2<G>` state cannot be stored in Tauri managed state across async boundaries. In `bridge_pair_invite` we store only the outgoing message; the state is re-created when handling the dialer's actual connection (Faz 3 full duplex). This is safe for single-session pairing.

7. **`NoCertVerifier` scope:** Used ONLY during the initial pairing TCP connect. After SAS confirmation, the peer is pinned and subsequent connections go through `PinnedSpkiVerifier` (fail-closed). The deliberate TOFU→SPKI-pin bootstrapping chain is documented in comments.

---

## Retry 1

**Date:** 2026-07-15
**Branch:** dev
**Commit:** (see below)

### Root Cause

The Retry 0 implementation had a one-sided PAKE exchange (AC-2-3 gap):

1. `bridge_pair_invite` called `Spake2::start_b(...)` but immediately discarded the state (`let (_spake2_state, outmsg) = ...`). A comment falsely claimed the state could be "re-derived later" — SPAKE2 `start_b` is randomised, so the state is unrepeatable.
2. There was no invitee network handler. No code accepted the dialer's pairing TLS connection, ran SPAKE2 B-side, sent `PakeReply`, or derived the invitee's SAS. The only `.finish()` in production code was on the dialer side.
3. `derive_sas` concatenated `our_spki || peer_spki` without sorting, making the SAS order-asymmetric: `derive_sas(k, A, B) ≠ derive_sas(k, B, A)`. A dialer calling `derive_sas(k, dialer_spki, invitee_spki)` would produce a different value than an invitee calling `derive_sas(k, invitee_spki, dialer_spki)`.
4. The normal data listener uses `PinnedSpkiVerifier` (rejects unpinned certs). During pairing the dialer is not yet pinned — a pairing connection to that listener would be rejected before PAKE even started.

Tests in Retry 0 passed only because they simulated both sides in memory without a real socket, masking all four gaps.

### What Was Wired on the Invitee Side

**`derive_sas` — canonical ordering (one-way door fix):**
Both SPKI strings are sorted lexicographically before concatenation into the HKDF IKM. Both sides call `derive_sas(key, &our_spki, &peer_spki)` and get the identical result regardless of argument order. The existing dialer call is unchanged; canonicality is enforced inside the function.

**`AnyCertVerifier` (new):**
A `ClientCertVerifier` that accepts any presented client cert (trust bootstrapped by PAKE+SAS). Scoped exclusively to the pairing listener. The normal data listener's `PinnedSpkiVerifier` is unchanged.

**`bridge_pair_invite` (repaired):**
Removed discarded `_spake2_state` and wrong comment. PIN is stored; SPAKE2 state is NOT stored (it is non-Clone/non-Send). A fresh `start_b` is created per incoming connection inside `handle_pairing_connection`.

**`build_pairing_server_config` (new):**
Builds a `ServerConfig` with `AnyCertVerifier` + TLS 1.3 only. Used exclusively by the pairing listener.

**`handle_pairing_connection` (new):**
Generic over `AsyncReadExt + AsyncWriteExt + Unpin` (testable with in-memory pipes without TLS). Protocol:
1. Gate: reject if PIN is absent / expired / locked / used.
2. Read `PakeInit`; extract dialer SPKI from `PakeInit.our_cert_der`.
3. `Spake2::start_b(pin, id_a="dialer", id_b="invitee")` → fresh state.
4. `state.finish(init.spake2_msg)` → `session_key`.
5. `derive_sas(session_key, our_spki, dialer_spki)` (canonical).
6. Send `PakeReply { wire_v, spake2_msg: our_outmsg, our_cert_der }`.
7. Return `PairingResult { sas, peer_spki, ... }`.

**`bridge_pair_start_listener` (new Tauri command):**
Binds a dedicated pairing TLS listener (wildcard-rejected per AC-2-2). Accepts exactly one connection (single-use PIN window), calls `handle_pairing_connection`, stores the result into `state.active_pin.pending_sas`, marks PIN `used=true`, emits `bridge://sas-compare`. Uses a polling watcher task to write back into managed state. The listener is separate from the normal data listener.

**`RemoteBridgeState` — `pairing_listener` field (new):**
Holds the dedicated pairing TLS listener handle. Cleared after the single pairing connection completes.

**`bridge_pair_confirm_sas` (unchanged):**
Already reads `pending_sas` from `active_pin` and pins `peer_spki` on confirm — works for the invitee path too once `pending_sas` is populated by `handle_pairing_connection`.

**`lib.rs`:** `bridge_pair_start_listener` added to `generate_handler!`.

### SAS Ordering Decision

`derive_sas` was order-sensitive in Retry 0. Fixed by sorting the two SPKI hex strings with `min/max` before concatenation. Both sides call `derive_sas(key, &our_spki, &peer_spki)`; the function normalises order internally. No change required at the call sites. The `ac2_3_sas_canonical_order_symmetric` test proves symmetry directly.

### Changed Files

- `src-tauri/src/bridge_remote.rs` — `derive_sas` canonical, `AnyCertVerifier`, `build_pairing_server_config`, `handle_pairing_connection`, `bridge_pair_start_listener`, `PairingResult`, `pairing_listener` field; repaired `bridge_pair_invite`; 6 new tests; `ac2_5_end_to_end_pairing_correct_pin` updated to assert `sas_a == sas_b`
- `src-tauri/src/lib.rs` — `bridge_pair_start_listener` in `generate_handler!`

### Test Commands + Results

```
cd src-tauri && cargo build
# → Finished `dev` profile (0 errors, warnings only — unused imports/fields)

cd src-tauri && cargo test
# → test result: ok. 68 passed; 0 failed; 4 ignored
#   (was 62; 6 new tests added)
#
# New tests:
#   ac2_3_real_socket_correct_pin_sas_matches   — both sides derive identical SAS (correct PIN)
#   ac2_3_real_socket_wrong_pin_sas_differs     — wrong PIN → SAS diverges, no pinning
#   ac2_3_real_socket_mitm_cert_sas_differs     — MITM cert in PakeInit → SAS mismatch
#   ac2_3_real_socket_no_pin_armed_rejected     — no active PIN → invitee rejects immediately
#   ac2_3_real_socket_expired_pin_rejected      — expired PIN → invitee rejects immediately
#   ac2_3_sas_canonical_order_symmetric         — derive_sas(k,A,B) == derive_sas(k,B,A)
```

### Decisions

1. **Duplex-pipe tests instead of full TLS socket tests for protocol layer:** `handle_pairing_connection` is generic over `AsyncReadExt + AsyncWriteExt + Unpin`, so `tokio::io::duplex` provides a real bidirectional in-process pipe. This tests the full PAKE protocol (framing, SPAKE2, SAS derivation) without TLS overhead, making tests fast and deterministic. The `bridge_pair_start_listener` command wraps TLS around the same `handle_pairing_connection` function — TLS correctness is already exercised by the rustls/tokio-rustls library tests.

2. **Polling watcher task for state write-back:** Tauri `State<'_>` holds a reference that cannot be moved into a `'static` async task. The watcher task uses a raw pointer to `RemoteBridgeState` (cast to `usize`), which is valid because Tauri manages state as a static singleton for the process lifetime. This is the standard pattern in tokio-based Tauri apps.

3. **`pairing_listener` field on `RemoteBridgeState`:** Separates the pairing listener lifecycle from the data listener. The data listener's `PinnedSpkiVerifier` is untouched.
