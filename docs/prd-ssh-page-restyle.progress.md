---
status: done
prd: docs/prd-ssh-page-restyle.md
started: 2026-10-05
---

## Phase Outputs
- tsc clean; vitest 359/359; `npm run build` OK.
- Regression test "an idle lock on another tab shows up…" (SshPage.test.tsx) fails on the old code and passes on the new.
- AC1: grep finds no palette color classes in SshPage.tsx / CredentialPicker.tsx.
- AC4: WebKit (Playwright) + browser mock (`?mock=1`, now stateful lock/unlock with sample servers and credentials). Servers, server form, CyberArk, store locked and store unlocked were screenshotted in dark and light. All readable, no page errors.
- Not done: a real-app store lock/unlock in a dev instance. That needs a master password typed into a test store, which is off-limits.

## Changes
| Date | File | What changed | AC |
|-------|-------|-----------|-----|
| 2026-10-06 | src/components/SshPage.tsx (+test) | page-level `vault-locked` listener, refresh on tab switch + window focus; tokens, labels, icon buttons | AC1-AC3 |
| 2026-10-06 | src/components/sshStyles.ts (new), CredentialPicker.tsx | shared token-based control styles | AC1 AC2 |
| 2026-10-06 | src/index.css | `.muya-select` themed dropdown (token-colored chevron) | AC2 |
| 2026-10-06 | src/mock/installMock.ts | stateful mock store + sample SSH config for browser screenshots | AC4 |

## Decisions
- Row "Connect" is a ghost button. White (primary) is kept for a card's single main action, like "+ New agent".
- Dropdown chevron drawn from two gradients so its color is a token. An SVG data URI can't read CSS variables.

## Lessons
