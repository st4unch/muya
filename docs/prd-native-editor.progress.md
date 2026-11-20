---
status: done
prd: docs/prd-native-editor.md
started: 2026-11-19
---

## Phase output
1. Engine spike + logic + tests (SyntaxHighlight.swift, EditorLogic.swift, EditorTests.swift): done, unit suite green.
2. EditorPane UI + wiring (EditorPane.swift, Viewers/UI/Shortcuts/main wiring): done.
3. verify-editor.sh (44 checks incl. perf budgets) green on the dev build; screenshots looked at. Not built/signed/released (task scope).

## Changes
| Date | File | What |
|---|---|---|
| 2026-11-19 | native/app/Sources/Logic/SyntaxHighlight.swift | windowed scanner + checkpoints |
| 2026-11-19 | native/app/Sources/Logic/EditorLogic.swift | codec, policy, document state machine, diff, go-to-line |
| 2026-11-19 | native/app/Tests/EditorTests.swift | 22 tests |
| 2026-11-19 | native/app/Sources/App/EditorPane.swift | editor view, ruler, minimap, diff, guards |
| 2026-11-19 | native/app/verify-editor.sh, measure-editor.sh, tools/editor-spike | live run + spike harness |

## Decisions
- Engine: NSTextView on an explicit TextKit 1 stack + own highlighter (ADR in the PRD). (b) CodeEditSourceEditor: see below.
- Highlight writes real text-storage attributes (TextKit 1 temporary attributes are O(file) on first far call).
