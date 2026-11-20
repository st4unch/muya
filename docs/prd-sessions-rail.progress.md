---
status: done
---
# Progress: sessions rail
- Logic + tests: Logic/SessionsRailLogic.swift, Tests/SessionsRailTests.swift (6 tests, suite 306 ok at the time).
- UI: Sources/App/SessionsRail.swift, RailView pages in Frame.swift, View menu items, ShortcutRouter chord hook.
- Hooks (dev only): Sources/App/DebugRail.swift (rail-state, rail-flip, rail-key, rail-pick, sidebar-set, mock-many).
- Verified in mock mode: ⌃⌥ arrows handled when closed, ← → pass through when open, ↑ ↓ step; screenshots dark/light.
- Decision: ← = Sessions page, → = Menu page (Sessions is page one).
