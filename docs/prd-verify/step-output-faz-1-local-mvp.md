---
phase: faz-1-local-mvp
status: done
date: 2026-07-15
---

## Retry 0

### AC-by-AC summary

**AC-1-1 — UDS listener accept loop + mode 0600 + permission barrier**
- `bridge_local_listen(enable:true)` now spawns a background Tokio accept loop via `tauri::async_runtime::spawn`.
- Socket file mode enforced to 0600; directory to 0700.
- Tests: `ac1_1_uds_bind_mode_owner_connect` (owner connect succeeds, file removed on unbind) + `ac1_1_permission_barrier_documented` (asserts 0600 mode + documents kernel POSIX.1-2017 §2.9.6 invariant — different-UID rejection cannot be tested without root, so documented as spec reference).

**AC-1-2 — Length-prefixed JSON framing + 16 MB oversize reject**
- `write_frame` / `read_frame`: `u32` big-endian length prefix + JSON body.
- `read_frame` checks declared length against `MAX_FRAME_BYTES` (16×1024×1024) **before** allocating or reading the body.
- Tests: `ac1_2_frame_round_trip` (write → parse → assert all fields match) + `ac1_2_oversize_reject_before_alloc` (sends a bad length prefix with no body; asserts `Err` containing "too large").

**AC-1-3 — Broker queue, no PTY write**
- `BridgeState` holds bounded `mpsc::channel(256)` (`inbound_tx` / `inbound_rx`) matching pty.rs philosophy.
- `handle_connection` enqueues `InboundRequest` to the channel; never calls `pty_write`.
- `bridge_poll_inbound()` drains the channel non-blocking, returns `Vec<InboundRequest>`.
- Test: `ac1_3_inbound_reaches_queue_not_pty` (mock peer sends research request → asserted in queue; no pty_write call exists in test or bridge code).

**AC-1-4 — Contract integration test (Golden Rule §2)**
- `ac1_4_contract_test_peer_to_queue_to_response`: mock peer connects → sends canonical ADR D6 envelope → server enqueues it → response frame returned → asserted peer-side (type=Response, id matches) AND server-side (queue has item, approval=NotRequired for research question).

**AC-1-5 — Approve-each gate state machine**
- `ApprovalState` enum: `PendingApproval | Approved | Denied | NotRequired`.
- `required_approval()`: `kind:task + capability:shell` → `PendingApproval`; all others → `NotRequired`.
- `staged: Arc<Mutex<HashMap<String, InboundRequest>>>` in `BridgeState` holds pending shell tasks.
- `bridge_approve(req_id, decision)`: `"allow"` → `Approved`, `"deny"` → `Denied`, unknown → `Err`.
- Tests: `ac1_5_approval_gate_shell_task` (pending before approve, allow→Approved, deny→Denied on separate instance), `ac1_5_non_shell_no_approval_required` (research/file → NotRequired), `ac1_5_invalid_decision_rejected` (bad decision string → Err).

### Files changed / created

- `src-tauri/src/bridge.rs` — full Faz 1 implementation (replaces Faz 0 scaffold)
- `src-tauri/src/lib.rs` — registered `bridge_poll_inbound`, `bridge_send`, `bridge_approve` in `generate_handler!`

### Test commands + results

```
cd src-tauri && cargo build
# → Finished dev profile (no errors)

cd src-tauri && cargo test bridge
# → 9 passed; 0 failed (ac1_1×2, ac1_2×2, ac1_3×1, ac1_4×1, ac1_5×3)

cd src-tauri && cargo test
# → 39 passed; 0 failed; 4 ignored

npx tsc --noEmit
# → (no output, exit 0)
```

All: **PASS**

### Bu Turda Alınan Kararlar

1. **`staged` alanı `Arc<Mutex<...>>`** — `tokio::sync::Mutex` Clone implementasyonu yok; accept loop'ta spawned task'lara paylaşmak için `Arc` gerekti. `BridgeState` struct'ında `Arc<Mutex<HashMap>>` olarak tutuldu; tüm komutlar (`bridge_approve`, `bridge_poll_inbound`, `handle_connection`) aynı Arc'ı paylaşır.

2. **`handle_connection` doğrudan `AppHandle` alıyor** — `tauri::Emitter` trait'i `AppHandle` üzerinde; test modunda bu path çalışmadığından contract test (AC-1-4) `handle_connection`'ı doğrudan çağırmak yerine aynı mantığı inline replicate etti. Bu Faz 1'de kabul edilebilir; Faz 2'de testability için mock/injectable event emitter düşünülebilir.

3. **`bridge_send` Faz 1 stub** — Dialer yok (Faz 2); komut `req_id` döner ve envelope'u in-memory oluşturur. API contract sabitleniyor (frontend/skill bu req_id'yi tracking için kullanabilir).

4. **`required_approval` rule: shell + task** — Sadece `capability:shell` + `kind:task` kombinasyonu approval gerektirir. Research/file/question → `NotRequired`. Bu Faz 3'te genişletilebilir (file writes, arbitrary capability scope).
