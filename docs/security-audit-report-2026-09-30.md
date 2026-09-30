# Security Audit Report — 2026-09-30

Branch `feat/ui-redesign-v0.4`. Six parallel read-only audits (model: sonnet):
Rust dependencies, npm dependencies, auth & secrets, backend injection & input
validation, frontend, infrastructure/build/release. Tools: `cargo audit` (RustSec DB
of 2026-09-30, 685 crates), `npm audit`, `gitleaks` (full history), manual code review.

## Executive summary

| Severity | Found | Fixed in this branch | Open |
|---|---|---|---|
| Critical | 0 | — | — |
| High | 1 | 1 | 0 |
| Medium | 3 | 1 | 2 (operator / by design) |
| Low | 12 | 9 | 3 |
| Info | 4 | — | — |

**Risk level after fixes: LOW.** The one High (agent → local RCE through an ssh
option) is fixed and regression-tested. The production npm tree is clean; Rust has one
upstream-blocked advisory (quick-xml, local plist parsing only).

## Findings

### HIGH — fixed
| ID | Where | Issue | Fix |
|---|---|---|---|
| H1 | `src-tauri/src/ssh.rs` `reject_injection`, `validate`, connect/scp argv | An agent could add an SSH server whose username/host started with `-` (e.g. `-oProxyCommand=sh${IFS}-c${IFS}…`; `${IFS}` dodged the whitespace rule). `ssh_run`/`ssh_scp` then passed it to ssh/scp as an option → command execution on the Muya host. | Leading `-` rejected for agent- and human-added servers; `--` before the ssh destination and scp operands (legacy records stay operands); `assemble_run_args` keeps forced options before `--`. Tests + live check with OpenSSH 10.3. Commit `ca845b3`. |

### MEDIUM
| ID | Where | Issue | Status |
|---|---|---|---|
| M1 | `scripts/publish-release.sh` | Updater signing key `~/.tauri/muya-update.key` has an empty password; whoever reads it can sign updates. | **Open — operator decision:** re-key with a passphrase kept in the Keychain; keep the key out of synced/backed-up folders. |
| M2 | `credstore.rs` `credstore_reveal_cred` → `SshPage.tsx` | "Reveal" returns a stored secret to the webview, kept in React state. | **Open — by design** (explicit reveal button). Residual: clear on lock/timer. |
| M3 | `MarkdownView.tsx` | Links in rendered `.md` navigate the whole webview away from the app; DOMPurify default config. | Fixed (see frontend commit): external links open in the browser, others ignored; forms/styles stripped. |

### LOW
| ID | Where | Issue | Status |
|---|---|---|---|
| L1 | Rust deps | h2 0.4.15 (RUSTSEC-2026-0258), rustls 0.23.41 (-0285), anyhow 1.0.102 (unsound, -0190) | Fixed: h2 0.4.19, rustls 0.23.45, anyhow 1.0.104 |
| L2 | Rust deps | quick-xml 0.39.4 (RUSTSEC-2026-0194/0195) via plist ← tauri | Open — upstream; only parses local plists |
| L3 | npm | esbuild (dev-only, Windows dev-server file read) | Open — not shipped, not reachable |
| L4 | `statusline.rs` | dir chmod after create (umask window); files 0644 via `fs::write` | Fixed: DirBuilder 0700, `create_new` 0600 |
| L5 | `debuglog.rs` | debug log created 0644 | Fixed: 0600 |
| L6 | `fs.rs` | `git worktree remove` without `--` | Fixed |
| L7 | `broker.rs` `register_mcp` | legacy `muya-ssh` MCP entry removed even if it is the user's own | Fixed: removed only when it points at `muya-ssh-mcp` |
| L8 | `agent.ts`, `SessionsPage.tsx` | session/attach id unquoted in resume command | Fixed (frontend commit): quoted + id shape checked |
| L9 | `ResourcesPage.tsx` | `openUrl` on marketplace-provided URLs without scheme check | Fixed (frontend commit): https only |
| L10 | `publish-release.sh` | release could ship without updater manifest | Fixed locally (scripts/ is not tracked in git) |
| L11 | repo root `latest.json` | generated artifact not ignored | Fixed: gitignored |
| L12 | `build-sign-notarize.sh` | fallback .p8 path in ~/Downloads | Open — operator hygiene: keep the key only in the Keychain profile |

### INFO
- `fs.rs` file commands accept any path (no workspace scope). Accepted for a local tool: only reachable with JS in the webview; CSP `script-src 'self'`, no remote content.
- `install_mcp` writes any command to `~/.claude.json` (marketplace install) — consider a confirmation dialog.
- Broker socket chmod 0600 after bind (peer-uid check backs it up).
- CSP keeps `style-src 'unsafe-inline'` (Monaco/xterm need it).

## Dependency CVE tables

**Rust (`cargo audit`)** — after fixes: 1 advisory group open (quick-xml, upstream);
warnings only for unmaintained/unsound crates pulled in by tauri (fxhash,
proc-macro-error, unic-*, event-listener, glib [Linux only]).

**npm** — `npm audit --omit=dev`: 0. Full: 1 low (esbuild, dev-only). All DOMPurify
copies are 3.4.16 (override works).

## Positive findings
- No secrets in git history (gitleaks: 2 false positives); no keys/.env tracked.
- Secrets resolved and injected in Rust (`Zeroizing`), never sent to JS except the
  explicit Reveal; askpass FIFO 0600, script `create_new` 0700; vault AES-256-GCM,
  atomic 0600 writes.
- Broker socket 0600 + `getpeereid` uid check; scp flag allow-list is fail-closed;
  `local_guard` canonicalises and fails closed on an empty root list.
- No `sh -c` over untrusted strings; git calls are argv with `--` where paths go.
- Frontend: no HTML sinks outside the two sanitised markdown renderers; terminal
  links need a click and only for paths that exist; mock backend absent from `dist/`;
  no secrets in localStorage; no devtools in release.
- Release: `set -euo pipefail`, keychain notary profile, codesign + spctl gates,
  minisign-verified https updater, sidecar signed with the app, no CI secret surface.

## Remediation priority
| Priority | Item |
|---|---|
| P0 | H1 — done |
| P1 | M1 updater key passphrase (operator) |
| P2 | L2 quick-xml when tauri/plist ship ≥0.41; M2 clear revealed secrets on lock |
| P3 | L12 .p8 hygiene; `install_mcp` confirmation; scope mutating fs commands to workspace roots |
