---
status: done
prd: docs/prd-mcp-compact-session.md
started: 2026-11-11
---

## Phase output
compact_session + usage implemented in broker.rs, muya_ssh_mcp.rs, remoteMessage.ts/App.tsx (submit flag), statusline.rs (all_status). cargo test --lib 422 pass, npm test 525 pass, tsc clean, sidecar tools/list shows both (39 tools). Not verified live: Claude TUI behaviour on Enter after typed /compact (autocomplete menu), and a real usage read from a live tab.

## Changes
| Date | File | Change | AC |
|---|---|---|---|
| 2026-11-11 | broker.rs, bin/muya_ssh_mcp.rs, statusline.rs, App.tsx, remoteMessage.ts(+test), SKILL.md, plugin.json 1.0.9 | compact_session + usage | AC1-7 |
