# Security Audit Report — 2026-10-02

Follow-up to `security-audit-report-2026-09-30.md`. Branch `feat/ui-redesign-v0.4` at
v4.0.3. Three parallel read-only audits (model: sonnet): OSV / dependency CVEs, license
compliance, and a review of the code added since the last audit (`9feabe0..170b11a`:
image/PDF viewers, Files rail, Sessions search, title bar, perf pass). Tools:
`osv-scanner`, `cargo audit` (686 crates), `npm audit`, `cargo license`,
`license-checker-rseidelsohn`, manual review.

## Summary

| Area | Before | After this pass |
|---|---|---|
| Rust advisories (vulnerabilities) | 1 HIGH (quick-xml, 2 IDs) + 1 unsound | **0** |
| npm (production) | 0 | 0 |
| npm (incl. dev) | 1 low (esbuild) | **0** |
| New-code review | 0 High / 0 Medium, 2 Low, 1 Info worth fixing | fixed |
| License blockers (GPL/AGPL/SSPL/unknown) | none | none |
| Third-party notices shipped | **missing** | shipped + in-app |

**Risk level: LOW.**

## Dependency CVEs (OSV / cargo audit / npm audit)

| Package | Advisory | Severity | Shipped | Action |
|---|---|---|---|---|
| quick-xml 0.39.4 (← plist 1.9.0 ← tauri) | RUSTSEC-2026-0194, -0195 | HIGH 7.5 | yes | **Fixed:** plist 1.10.1 → quick-xml 0.42.0 (`cargo update -p plist`) |
| event-listener 5.4.1 (← zbus ← tauri-plugin-opener) | RUSTSEC-2026-0221 (unsound) | — | yes | **Fixed:** 5.4.2 |
| esbuild 0.27.7 (← vite) | GHSA-g7r4-m6w7-qqqr | LOW 2.5 | no (dev) | **Fixed:** vite 7.3.6 / esbuild 0.28.2 (`npm update vite esbuild`) |
| glib 0.18.5 (gtk3, Linux only) | RUSTSEC-2024-0429 | — | no (not in the macOS build) | upstream (tauri/wry gtk-rs bump) |
| fxhash, proc-macro-error, unic-* | unmaintained | — | transitive | no action available |

pdfjs-dist 6.3.289 and dompurify 3.4.16: no advisories, latest versions.

## New code review

| ID | Severity | Where | Issue | Status |
|---|---|---|---|---|
| N1 | Low | `fs.rs` `read_file_bytes` | 200 MB cap + webview copies → memory spike; file could grow after the size check | **Fixed:** 100 MB cap enforced while reading (`take`) |
| N2 | Low (pre-existing, surfaced) | `sessions.rs` `resolve_transcript` | content search accepted any webview-supplied path (or a cwd/id with `..`) → substring oracle on any readable file (e.g. `~/.ssh`) | **Fixed:** shared `checked_transcript_path` — canonical `.jsonl` under `~/.claude/projects` only; regression test incl. `..` and symlink escape |
| N3 | Info | `titlebar.rs` `defaults` spawn | absolute path, fixed args | no action |

Verified safe: SVG via `blob:` in `<img>` (no script, CSP blocks fetches); pdf.js v6 has
no eval path (CVE-2024-4367 class), no remote fetches, no annotation/link layer;
`muya.openFiles` restore is validated and only opens viewers; session names render as
text (no HTML sink); `sessionQuery` regex is linear.

## Licenses

645 Rust crates / 56 npm production packages: all permissive or weak-copyleft.
- MPL-2.0 (file-level, unmodified): cssparser, cssparser-macros, dtoa-short, selectors,
  option-ext — source availability noted in the notices file. dompurify and r-efi are
  dual-licensed (Apache/MIT chosen).
- OFL-1.1 fonts (IBM Plex Sans, JetBrains Mono): bundling allowed, text included.
- **Gap fixed:** no license texts shipped with the binary. Now
  `tools/third-party-notices.mjs` generates `src-tauri/resources/THIRD_PARTY_LICENSES.txt`
  (468 packages linked/bundled into the app, each package's own LICENSE/NOTICE files, an
  appendix of standard texts for packages that only name their license, and the MPL
  source note). Bundled as an app resource; Settings › "Open-source licenses" opens it.
  `--check` mode added to the release checklist.

## Still open (from 2026-09-30)
- M1 updater signing key without a passphrase (operator).
- M2 revealed vault secret kept in React state (by design; clear on lock).
- L12 `.p8` notary key in `~/Downloads` (operator hygiene).
