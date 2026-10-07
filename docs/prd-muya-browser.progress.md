---
status: active
prd: docs/prd-muya-browser.md
started: 2026-10-07
---

## Phase Outputs

## Changes
| Date | File | What changed | AC |
|-------|-------|-----------|-----|

## Decisions
- 2026-10-07 operator: WebKit instead of bundled Chromium + screencast (resource cost); add a crawler; defer security restrictions (users may log in and let Claude use the session).
- Crawler built in-house on reqwest + dom_smoothie + htmd instead of `spider` (heavy, Linux-oriented defaults; bounded crawl doesn't need it).

## Lessons
