| 2026-07-15T14:12:54+03:00 | prd-claude-remote-bridge | src-tauri/src/bridge.rs | yeni: UDS listener scaffold (bind/unbind 0600) | AC-0-2 |
| 2026-07-15T14:12:54+03:00 | prd-claude-remote-bridge | src-tauri/Cargo.toml | tokio net + rustls + tokio-rustls deps | AC-0-1 |
| 2026-07-15T14:12:54+03:00 | prd-claude-remote-bridge | src/App.tsx | chat view + Remote/Local UI kabuğu | AC-0-3 |
| 2026-07-15T14:20:57+03:00 | prd-claude-remote-bridge | src-tauri/src/bridge.rs | Faz 1: accept loop, envelope framing (16MB guard), broker queue, approval gate | AC-1-1..1-5 |
| 2026-07-15T19:24:22+03:00 | prd-claude-remote-bridge | src-tauri/src/bridge_remote.rs | Faz 2: Ed25519 identity, tokio-rustls mTLS, SPAKE2 pairing+SAS+SPKI pin, invitee handler | AC-2-1..2-5 |
| 2026-07-15T19:38:15+03:00 | prd-claude-remote-bridge | src-tauri/src/bridge_exec.rs | Faz 3: sandboxed exec, capability enforce, auto-run gate, memory audit, fan-out | AC-3-1..3-7 |
