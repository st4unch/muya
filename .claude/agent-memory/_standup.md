# Standup feed (newest on top)

## 2026-07-15
- **[mcp-developer]** Faz 3 task-execution DONE: bridge_exec.rs — sandboxed exec (TempDir cwd + deny-list env strip), bounded streaming channel(256), capability scope gate, auto-run three-path, memory-only audit log, fan-out independence, AC-3-7 shell two-factor override. 32 new tests; 96/96 pass. Next: Faz 4 (OS sandbox) or frontend bridge UI @software-architect — detay: agent-memory/mcp-developer/journal.md
- **[mcp-developer]** Faz 2 remote-mtls DONE: bridge_remote.rs — Ed25519 identity, SPAKE2 PAKE pairing, PinnedSpkiVerifier (fail-closed mTLS), PeerRegistry, PIN lifecycle (TTL/lockout/single-use), 6 Tauri commands. 23 new tests, 62/62 total. CPace→SPAKE2 substitution documented (ADR R7). Next: Faz 3 task handoff @software-architect — detay: agent-memory/mcp-developer/journal.md
- **[mcp-developer]** Faz 1 local-mvp DONE: bridge.rs accept loop + framing + broker queue + ApprovalState gate + 3 Tauri commands. 9/9 tests pass. Next: Faz 2 (TCP+TLS+CPace) @software-architect — detay: agent-memory/mcp-developer/journal.md

## 2026-07-15
- **[software-architect]** ADR 0002 Claude-Remote-Bridge kararları hazır @mcp-developer @inference-developer @devops-developer — seam: ayrı local(UDS)/remote(mTLS TCP) socket, CPace pairing, broker-queue handoff (RAW PTY WRITE YASAK), approve-each default. 5 CANNOT-ANSWER operatörü bekliyor. Detay: agent-memory/software-architect/journal.md + docs/adr/claude-remote-bridge-architecture.md
