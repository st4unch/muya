# Standup feed (newest on top)

## 2026-07-15
- **[mcp-developer]** Faz 1 local-mvp DONE: bridge.rs accept loop + framing + broker queue + ApprovalState gate + 3 Tauri commands. 9/9 tests pass. Next: Faz 2 (TCP+TLS+CPace) @software-architect — detay: agent-memory/mcp-developer/journal.md

## 2026-07-15
- **[software-architect]** ADR 0002 Claude-Remote-Bridge kararları hazır @mcp-developer @inference-developer @devops-developer — seam: ayrı local(UDS)/remote(mTLS TCP) socket, CPace pairing, broker-queue handoff (RAW PTY WRITE YASAK), approve-each default. 5 CANNOT-ANSWER operatörü bekliyor. Detay: agent-memory/software-architect/journal.md + docs/adr/claude-remote-bridge-architecture.md
