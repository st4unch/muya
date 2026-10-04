---
status: done
prd: docs/prd-open-reopen.md
started: 2026-10-04
---

## Phase Outputs
- cargo test --lib 355 passed; tsc clean; vitest 354/354; `npm run build` OK; no operator paths.
- Live (isolated dev instance, HOME=/tmp/muyaT, a stand-in `claude` logs its args, keys sent by cua-driver to the dev pid only):
  - T2: ⌘K → typed `zqxprobe` → Enter opened ~/…/zqxprobe-notes.md (a Spotlight-indexed probe file) in the md viewer (`muya.openFiles` shows `mdview:<path>`).
  - T4: ⌘W ×2 (terminal, then a Claude tab with a session id) → ⌘⇧T reopened the Claude tab first with `--resume 1111… --dangerously-skip-permissions`, then the terminal. A third ⌘⇧T with an empty history did nothing. A closed file came back with ⌘⇧T in the same viewer.
  - T3: ⌘O opened the macOS "Open" panel (window listed by title).
- **Not observed:** picking a file inside the Open panel. The panel runs in a separate system process that cua-driver can't type into. The chosen paths go through `openFile`, the same function the ⌘K test exercised. SSH reopen is covered by a unit test only.

## Changes
| Date | File | What changed | AC |
|-------|-------|-----------|-----|
| 2026-10-04 | src-tauri/src/spotlight.rs (new), lib.rs | `spotlight_search` (mdfind -name, filtered + ranked); File menu Open… ⌘O, Reopen Closed Tab ⌘⇧T | AC1 AC2 AC4 AC5 |
| 2026-10-04 | src/redesign/CommandPalette.tsx (+test) | "On this Mac" group, query callback | AC3 |
| 2026-10-04 | src/lib/tabs.ts (+test) | `pushClosed`, `reopenSpec` | AC5 |
| 2026-10-04 | src/App.tsx | debounced Spotlight search; closed-tab history in closeTerminal; menu listeners | AC3-AC5 |

## Decisions
- mdfind is read for up to 2000 lines, not 400 (PRD AC2). Build output and node_modules hits are filtered out after reading, so 400 lines often left nothing real. The 3 s budget still caps it.
- Spotlight via `mdfind -name` (file-name match, like Finder's default search). No new dependency.

## Lessons
