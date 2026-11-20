---
status: active
prd: docs/prd-full-disk-access.md
---

# Progress: Optional Full Disk Access step

- [x] PRD written (research: tccd logs, mjtsai, Orca #13921, Apple news 2026-10-02)
- [x] `FullDiskAccess.swift` logic + `FDATests.swift` (5 tests)
- [x] Settings > Privacy row (+ Helper apps row), first-run step in ServiceGate
- [x] Debug hooks `fda-*`; screenshots in the session scratchpad (`fda-shots/`)
- [ ] Operator check on the real install: grant FDA to Muya Native, see whether ptyd children stop prompting; if not, the helpers must be added too
- [ ] Follow-up: ptyd-side probe (muya-proto minor bump + muyad RPC)
