# PRD — Native Muya (Option D: no webview)

Status: APPROVED (architect GO, amendments applied) 2026-11-03 · Branch `wip/native-rewrite` (local only) · Owner: operator
Grounding: `docs/native/inventory-backend.md` (backend), `docs/native/inventory-frontend.md`
(UI), `docs/native/adr-001-stack.md` (stack decision), `docs/loadtest-results.md` (evidence),
`docs/native/research-terminal.md`, `docs/native/research-ui.md` (sources).
Drafted on Opus 5.5; subagents ran on Sonnet per the operator's global rule (D7).

## §0 Review Log

### Quality Review — 2026-11-03 (0 P0, 11 P1, 8 P2, 1 P3)
| ID | Title | Sev | Status | Note |
|---|---|---|---|---|
| G1 | Corpus has 18 screens, AC3 needs ≥200 | P1 | applied | verified (`src/lib/__fixtures__/claude-screens/`: 36 files = 18 pairs); capture task in Faz 0/1 |
| G2 | "25 MCP tools" wrong | P1 | applied | AC4 now = byte-identical `tools/list` snapshot |
| G3 | parity.md not seeded, "~" counts | P1 | applied | generated in Faz 0 with exact counts + phase tags |
| G4 | Features with no phase owner | P1 | applied | §10 phase→inventory map + named list |
| G5 | Non-binary ACs | P1 | applied | AC9/10/11/15/20 rewritten; no-webview AC added |
| G6 | Licence/Kitty kb "verified" overstated | P1 | applied | crate licence verified (MIT/Apache); Ghostty core licence + fallback Kitty kb moved to S2 |
| G7 | No rollback after cutover | P1 | applied | copy-only migration, Tauri data untouched, downgrade AC |
| G8 | SMAppService approval states | P1 | applied | §5, §12.5, AC added |
| G9 | Scrollback ring secrets | P1 | applied | ring memory-only; dump restricted |
| G10 | Existing scheduler agent | P1 | applied | D8: muyad sole owner, old agent retired, AC |
| G11 | No estimates / stop-loss / parser drift risk | P1 | applied | §10 estimates, stop-loss, R11 |
| G12 | Open questions answerable now | P2 | applied | answered, moved to decision log |
| G13 | One persona | P2 | applied | UC5/UC6 + a11y audit AC |
| G14 | Nested signing incl. Sparkle helpers | P2 | applied | Faz 5 signing checklist, S8 extended |
| G15 | Turkish strings, a11y settings | P2 | applied | D11 |
| G16 | Protocol fuzz/limits | P2 | applied | §7 |
| G17 | Ack/timeout/idempotency | P2 | applied | §7 |
| G18 | Per-session memory budget | P2 | applied | §14 |
| G19 | Sleep / occlusion | P2 | applied | AC added |
| G20 | Third-party notices | P3 | applied | Faz 5 task |

### Architect gate — 2026-11-03: GO (conditional) → 5 amendments applied (mode tracker detail, getsid peer check + R13, typing in muyad, chunking/resync, crash-loop + disk-full rows); Open Q1 decided (D15)

### Adversarial Challenge — 2026-11-03 (verdict: qualified-yes; 0 FATAL, 5 SERIOUS, 4 MINOR)
| ID | Title | Sev | Status | Note |
|---|---|---|---|---|
| A1 | Ring replay loses terminal modes after muyad restart | SERIOUS | applied | ptyd mode tracker (§5), S4/AC2 test input after re-adopt |
| A2 | TCC / Login Items / env under a LaunchAgent | SERIOUS | applied | S5 extended (agent disabled, FDA on app only, env diff) |
| A3 | Renderer fallback not executable | SERIOUS | applied | renderer treated as one-way-ish: S1 now includes the AC11 quality set; fail = re-decision |
| A4 | Native editor parity under-measured | SERIOUS | applied | AC13 feature checklist, R6 = High |
| V1 | Team-ID peer check lets an agent drive other sessions | SERIOUS | applied | per-socket signing identifiers, session children refused, `muyactl dump` off in release |
| F1 | Sparkle update + stale agent registration | MED | applied | S8/AC17 extended (update → ptyd crash → restart) |
| F3 | Parser drift with Claude updates | HIGH | applied | R11 + weekly canary; headless auto-approve exact-match only |
| D1 | Cheaper path: visible-only xterm mount + ptyd in Tauri | CONSIDER | logged (D13) | S0 measures it as information; operator chose Option D |
| E1-E6 | Evidence grades C/D | — | applied | each tied to a spike or AC |

## 1. Goal (Why)
Muya's job is running many Claude Code sessions side by side. In the WKWebView UI, 13 busy
sessions run at 27-29 fps and 25 at 11-14 fps, with 380-770 ms tab switches
(`docs/loadtest-results.md`, headless WebKit on the mock bundle). The goal is a fully native
macOS Muya that keeps 100 live sessions smooth, and in which **sessions never die because
the UI crashed, quit or updated**.

## 2. Non-goals
- No new product features during the rewrite (parity first; ideas go to a backlog).
- No Windows/Linux. No App Store build (Muya is not sandboxed: it spawns shells and reads any file).
- No change to the `muya-mcp` tool contract agents see (same tools, same JSON).
- No webview anywhere, including the editor (D2).

## 3. Background and context
- Backend: 151 Tauri commands, 20 events, 1 PTY byte `Channel`; 42 modules — 9 PURE,
  25 THIN, 8 COUPLED (`inventory-backend.md` §1-3). PTY pipeline: 32 KB reads, 128 KB
  batches, 8 ms pace (`src-tauri/src/pty.rs:239-305`).
- Broker/bridge drive UI-owned terminals through events `ssh-broker-open`, `ssh-broker-send`,
  `muya://deliver-message` (`broker.rs:607`, `:992`) — they need an acknowledged command bus.
- Schedules already run through a lock holder that can be the window or the
  `muya --scheduler` SMAppService agent (`inventory-frontend.md` §1 Schedules).
- UI: 8 views + Grid (1/1x2/2x2/3x2) + split groups (2-8), ~22 dialogs, 10 Settings rows,
  ~45 shortcuts, 121 invoke commands, 18 listened events, ~40 localStorage keys, 123 tokens,
  Monaco with HEAD diff + auto-save, Markdown/image/PDF viewers, cmdk palette, 9 terminal
  schemes, ~65 footer status fields (`inventory-frontend.md`). Exact counts are produced by
  the parity generator in Faz 0.
- Claude TUI screen parser `parseClaudeScreen` (`src/lib/screenState.ts`) drives status,
  permission dialogs, auto-approve and channel-prompt auto-accept; verified against Claude
  Code v2.1.285 with 18 fixture screens.
- Scheduled prompts are in-memory React state only (`src/App.tsx:1310`, no storage) — the
  native app keeps them in muyad memory (same behaviour, now survives UI restarts).
- Native menu accelerators: `src-tauri/src/lib.rs:240-273` (⌘N, ⌘W, ⌘O, ⌘⇧T, ⌘⇧H, ⌘Q, ⌘,).

## 3.5 Industry context & benchmark
| System | Approach | Takeaway |
|---|---|---|
| Ghostty (macOS) | Zig core + Swift/AppKit UI + own Metal renderer | Native IME/a11y and speed come from AppKit + own renderer (`research-ui.md`) |
| Zed | GPUI + alacritty_terminal | Fast, but GPUI is not on crates.io; no IME/VoiceOver evidence (`research-ui.md` §1b) |
| SwiftTerm apps | AppKit + SwiftTerm | Open issues on main-thread CPU with several streaming TUIs (#658, #738) |
| tmux | One server owns PTYs + VT state | Survives client crash; a server crash loses everything |
| zellij resurrection | Restores layout/commands, not live processes | = our ptyd-crash recovery model (respawn + `claude --resume`) |
| libghostty-vt crate 0.2.2 | VT parser + render-state API (`ghostty_render_state_update` consumes dirty state), no renderer/PTY | crates.io licence MIT OR Apache-2.0 (checked); upstream: "API is not yet stable" (https://libghostty.tip.ghostty.org/) |

Chosen: ADR-001 Option A+ (§5). Rejected: in-process UniFFI (UI crash kills sessions),
SwiftTerm primary, GPUI, full GhosttyKit (unsupported internal API, owns the PTY), one
tmux-style daemon (a VT-parser fault on untrusted bytes would kill every PTY — D9).
Compliance: no new regulated data; secrets stay in one hardened process.

## 4. User flow
Operator opens Muya → sees every running session (also ones started while the UI was
closed) → picks one; its terminal appears in <50 ms with full scrollback → types (Turkish
included) → quits or updates Muya → sessions keep running → reopens → everything is where
it was.

## 4.5 Use cases
1. **25 busy agents.** 25 Claude sessions, 6 visible in Grid, all streaming: ≥55 fps, typing
   echo ≤30 ms, switching ≤50 ms.
2. **Update mid-work.** Sparkle update while 12 sessions run tool calls; app relaunches; the
   12 PIDs are unchanged and the output during the restart is in scrollback. A
   protocol-incompatible update asks "restart sessions now / later" (D3).
3. **Approval while the window is closed.** Permission prompt with the UI closed → muyad
   detects it, notification fires; auto-approve (if on) answers after its 2 s delay.
4. **Agent opens a session via MCP.** Another Claude calls `open_session`; muyad starts it with
   no UI attached; the UI shows it when opened.
5. **SSH with the vault.** Operator unlocks the vault with Touch ID, opens a PSMP server tab,
   the password is injected at the prompt; the vault auto-locks after 15 min idle and the
   secret is gone from muyad memory.
6. **Keyboard + VoiceOver only.** A user navigates the session list, dialogs, file tree and
   terminal with VoiceOver and the keyboard, never touching the mouse.

## 5. Architecture
Three signed executables + the existing sidecar in one bundle (ADR-001 §5):
- **`muya-ptyd`** (Rust, tiny; LaunchAgent via SMAppService, KeepAlive): owns PTY masters,
  children, a bounded **memory-only** output ring per session (sequence-numbered, never
  written to disk) and a **mode tracker** — a few hundred bytes per session recording the
  last DECSET/DECRST private modes, Kitty keyboard flags, bracketed paste, mouse modes,
  alt-screen and title. On re-adopt muyad receives modes + ring, so input encoding is right
  even when the mode-setting bytes have scrolled out of the ring (A1). The tracker handles
  sequences split across reads, keeps main- and alt-screen modes separately with a Kitty
  keyboard flag stack per screen (`CSI > u` push / `CSI < u` pop), and handles XTSAVE /
  XTRESTORE (`CSI ? s` / `CSI ? r`), DECSTR and RIS; CI differentially fuzzes it against
  libghostty-vt's mode state. No VT parsing beyond that tracker, no network, no secrets.
- **`muyad`** (Rust): libghostty-vt state per session (authoritative), ported screen parser,
  broker UDS server (single owner; replaces `BROKER_OWNED_ELSEWHERE`), vault/credstore,
  **schedules (sole owner; the old `muya --scheduler` agent is unregistered on first native
  launch — D8)**, bridge, git/fs/watcher, agent_ops, statusline. Re-adopts ptyd's PTYs on
  restart.
- **`Muya.app`** (Swift 6, AppKit-first; SwiftUI only for leaf views; macOS 26+): client.
  Metal terminal renderer on a UI-side libghostty-vt replica for attached sessions only
  (updated once per frame — the render-state update consumes dirty state);
  `NSTextInputClient` + `NSAccessibility` on the terminal view; STTextView + tree-sitter
  editor; PDFKit; Sparkle 2 (non-sandboxed layout, no Sparkle XPC services).
- **`muya-mcp`** stdio sidecar: unchanged tools, talks to muyad's broker socket.
- **Agent registration states** (G8): the app reads `SMAppService.status` for ptyd/muyad on
  launch. `.requiresApproval` or disabled → onboarding screen with an "Open Login Items"
  button; session start returns a typed error until approved. Never silent.
- **Peer identity** (V1): each socket accepts one signing identifier, not just the Team ID —
  client socket: `Muya.app`; broker socket: `muya-mcp` (+ the app); ptyd socket: `muyad`.
  The signing identifier is the real gate. In addition, a peer whose session id (`getsid`)
  matches any ptyd PTY session is refused (session children: shells, `claude`, agents —
  this survives double-forks, unlike an ancestor check). Residual risk: a same-user process
  that fully detaches and runs the signed app binary (R13). `muyactl` in release builds is read-only (`status`, `sessions`,
  `doctor`); `attach`/`dump` exist only in debug builds.
- **Code layout:** `muya-core` crate (no Tauri) holds the PURE + THIN modules after removing
  the Tauri leaks (`tauri::ipc::Response` in `read_file_bytes`, `Channel` in `pty_spawn`,
  `AppHandle.emit` → an event-sink trait, copying `watcher.rs`'s `impl Fn` pattern).

## 6. Data model
- Session registry (muyad): id, name, cwd, agent kind, pty id, seq, opened-by, parser status.
  Persisted to `~/Library/Application Support/Muya/sessions.json` (0600) for respawn +
  `claude --resume` after a reboot or ptyd crash. No terminal content on disk.
- UI prefs: **copied** (never moved or deleted) from the Tauri app's localStorage and
  Tauri-store files on first native launch, then kept in `UserDefaults` + Application Support
  JSON (D4, D12). Existing `~/.claude/muya-*.json` files are shared as they are.
- Vault, schedules, servers, PSMP profiles, operations registry: unchanged on-disk formats, so
  the Tauri build can still read them (downgrade path).

## 7. API contracts
- **Agent-facing MCP:** unchanged; AC4 diffs `tools/list` byte-for-byte.
- **Client protocol v1** (one-way door): length-prefixed frames, max 16 MiB; handshake with
  min/max version; minor versions only add fields, unknown fields ignored; a `cargo fuzz`
  target on the frame decoder; N-1 client vs N daemon matrix test. Messages cover list /
  attach / detach / input / resize / spawn / close sessions, the 151 commands grouped by
  area, and server events (the 20 events + parser state).
- **Typing into sessions** (`ssh-send`, `deliver-message`): executed by muyad, which writes
  straight to ptyd — no UI round-trip. muyad keeps an in-memory dedupe LRU (10 min) on the
  idempotency key; the ack means "typed"; a timeout returns the typed error "outcome
  unknown, not retried automatically".
- **UI requests** (`open-session`, `ssh-open`): idempotent by session id; ack timeout 10 s,
  queue cap 64, TTL 5 min while no UI is attached, then a typed error to the caller.
- **Large payloads and slow clients:** payloads over 1 MiB (snapshots, large file reads) are
  chunked; each client's output queue is capped, and on overflow the client is resynced
  from snapshot + sequence number, never blocked.
- **CLI:** `muyactl status | sessions | doctor` (release); `attach | dump` (debug only).

## 8. Native UI
Parity list `docs/native/parity.md` is **generated** in Faz 0 from the two inventories: one
row per command, event, shortcut, dialog, Settings row, localStorage key, view, viewer kind,
token group and terminal scheme, each tagged with its phase. "Verified" = an automated test id
or a screenshot path in the row; a check fails if a `done` row has neither.
Look: same layout and design tokens (dark/light), JetBrains Mono / IBM Plex Sans, the 9
schemes; native menus with the existing accelerators; fades 140 ms, off under Reduce Motion;
Reduce Transparency and Increase Contrast respected. UI text English (Turkish strings in
`ScheduledPromptModal` become English — D11).

## 9. Auth, secrets, security
- Secrets only in muyad memory; never argv/env/disk; zeroized on lock; Touch ID variant per
  S6. The UI holds a secret only while the user types it.
- The real boundary is the code-signing requirement per socket (§5); the 0700 socket dir is
  defence in depth only. Hardened runtime on every executable blocks same-user injection.
- Terminal content (which can contain secrets) is memory-only in ptyd and muyad.
- Rust statically linked into each daemon; every executable signed individually (no
  `--deep`), entitlements preserved, then notarized.
- ptyd has no network code; the bridge keeps mTLS + SPAKE2.
- Headless auto-approve keeps today's opt-in, 2 s delay and exact dialog match; an unknown
  dialog layout is never answered (F3).

## 10. Phases
Estimates are for one engineer + agents; **stop-loss:** if a phase overruns its estimate by
50%, stop and re-decide with the operator.

| Faz | Est. | Content | Inventory sections | Exit gate |
|---|---|---|---|---|
| **0 — Spikes + seeds** | 2-3 wk | S0-S9 (ADR §7 + below); `parity.md` generator; corpus capture tool (record real `claude` screens across modes/dialogs/widths/versions) | — | S1-S5 PASS (any FAIL → stop, re-decide); S6-S9 PASS or written fallback; parity.md exists |
| **1 — Core + daemons** | 4-6 wk | `muya-core`; ptyd (+ mode tracker), muyad, protocol v1, `muyactl`; Rust screen parser + ≥200-screen corpus; broker/sidecar/schedules on muyad; contract + fuzz tests | backend §1-6 | AC1-AC6, AC21-AC23 |
| **2 — Terminal app MVP** | 6-8 wk | Swift app: session list, agent cards, terminal (Metal), Control/Grid/splits, input/IME, search, path links + action menu, mouse, footer status fields, approvals/approval cards, notifications panel + toasts, tray, auto-approve, composer (history, slash popover), broadcast, header CPU/RAM readout, fullscreen Esc guard, title-bar double-click, terminal History view | frontend §2, §5, §7 (terminal keys) | AC7-AC12, AC24-AC25 |
| **3 — Files** | 6-8 wk | file tree + watcher + context menu, STTextView editor (save, dirty guard, auto-save, find/replace, multi-cursor, folding, 20 languages), HEAD diff, review-changes dialog (`[`/`]`), local file versions + restore, Markdown/image/PDF viewers, Finder drop, File Access Gate | frontend §3, §4 | AC13-AC15 |
| **4 — Remaining views** | 6-8 wk | Inspector (Changes/Files/Activity, worktree conflict card), Sessions (search/export), Queue (push/merge, branch DAG), Branches, Kanban, Schedules (+ scheduled prompt modal), SSH/PSMP + CyberArk browser + vault UI, Resources/Marketplace, New Agent modal (worktrees), Cleanup dialog, Settings, command palette (+ Spotlight search), all shortcuts | frontend §1, §6, §7 | AC16, AC26 |
| **5 — Ship** | 3 wk | Sparkle + EdDSA key; signing order checklist (ptyd, muyad, sidecar, Sparkle helpers, app); third-party notices regenerated + licence check; prefs copy-migration; last Tauri release carrying the native app; 7-day dogfood; cutover | frontend §9 | AC17-AC20, AC27 |

Added spikes (on top of ADR-001 §7):
- **S0 (information, non-blocking):** in today's Tauri app, mount xterm only for visible
  sessions and measure 25/100 sessions with the load generator (D13).
- **S1 extended:** the AC11 quality set (ligatures off/on, emoji, wide CJK, selection, IME
  preedit) is part of S1 — the renderer has no cheap fallback, so its quality is proven first.
- **S2 extended:** record the Ghostty core licence and that the fallback engine passes a Kitty
  keyboard test.
- **S4 extended:** after `kill -9 muyad`, Shift+Enter, mouse click and bracketed paste still
  reach a long-running Claude session correctly.
- **S5 extended:** cases "agent disabled in Login Items", "Full Disk Access granted to the app
  only", login-shell env diff vs Terminal.app.
- **S8 extended:** Sparkle replaces the bundle while ptyd runs → then `kill -9 ptyd` → the
  restarted ptyd is the new binary and the handshake is correct.

## 11. Acceptance criteria (binary)
Load numbers use `scripts/loadtest/` (visible 1 MB/s, others 64 KB/s) ported to drive the
native app; machine: M4 Pro, macOS 26, on power, display awake unless stated.
- AC1: `cargo test -p muya-core` passes and `cargo tree -p muya-core | grep -c tauri` = 0.
- AC2: ptyd + muyad run 25 sessions headless; `kill -9 muyad` → 25 PIDs unchanged, listed again ≤5 s, and a scripted Shift+Enter / bracketed paste / mouse click into a session that set those modes >10 MB of output earlier is encoded correctly.
- AC3: corpus ≥200 captured screens (modes, all dialog types, spinner variants, widths 60-240, ≥2 Claude versions); Rust parser `ScreenState` JSON = TS parser output on 100%.
- AC4: `tools/list` from the sidecar against muyad is byte-identical to the committed snapshot of today's output; existing sidecar/broker tests pass.
- AC5: handshake rejects a client one major version off with a typed error; N-1 minor client works; fuzz target runs 10 min with 0 crashes.
- AC6: a client signed with our Team ID but a different identifier (e.g. `muyactl`) is refused on the client socket; a session child is refused, also after a double-fork; `muyactl dump` absent in the release build.
- AC7: 25 sessions streaming, 6 visible: ≥55 fps, frame p95 ≤25 ms, input echo p50 ≤30 ms, switch p50 ≤50 ms, UI RSS <1 GB.
- AC8: 100 sessions at 64 KB/s, 1 visible: UI ≥55 fps; muyad RSS ≤1.5 GB, CPU ≤150 %; ptyd RSS <200 MB.
- AC9: `kill -9` of the app with 25 sessions → relaunch shows all 25 ≤500 ms after launch; each session's screen text hash equals the pre-kill hash; 0 PIDs lost.
- AC10: scripted 200-char Turkish Q run (press-and-hold ğ ş ç ı ö ü, İ/ı with caps lock) and a Japanese marked-text run: 0 dropped/duplicated chars; IME candidate window anchored at the TUI cursor; an XCUITest/Accessibility API script reads the terminal's visible lines and the editor text.
- AC11: 20 named screenshot pairs (Muya vs Ghostty.app, same `claude` session: 24-bit colour, alt screen, resize, Kitty keyboard, mouse tracking, OSC 8 links, emoji, CJK, selection) signed off by the operator in `docs/native/render-signoff.md`.
- AC12: permission prompt with the UI closed → macOS notification ≤2 s; with auto-approve on, it is answered after 2 s with the UI closed; an unknown dialog layout is not answered.
- AC13: editor: 5 MB file opens <300 ms and scrolls at 60 fps; passes the AC10 IME run; checklist all pass — find/replace (regex), multi-cursor, folding, undo/redo, the 20 languages of `src/lib/format.ts`, HEAD diff, dirty guard, auto-save.
- AC14: file tree reflects an external `touch`/`rm` within 1 s.
- AC15: Markdown, image and PDF open in native views (PDFKit / NSImageView / native Markdown view), and `vmmap <app pid> | grep -c WebKit` = 0 and `otool -L` lists no WebKit.
- AC16: `docs/native/parity.md` has 100% rows `verified` with evidence.
- AC17: clean macOS 26 user: last Tauri release → native app via its updater; Sparkle then updates the native app; sessions alive across that update; then `kill -9 ptyd` → new ptyd binary, correct handshake.
- AC18: first native launch copies tabs, settings and terminal prefs from a captured real Tauri data set with no prompt; the Tauri data files are byte-identical afterwards.
- AC19: protocol-incompatible update shows "restart sessions now / later"; "later" leaves sessions running; "now" restarts them and resumes each Claude conversation.
- AC20: `spctl -a -vv` accepts the bundle on a second user; 7-day dogfood with ≥13 sessions daily: 0 session losses in muyad logs and 0 crash reports for ptyd/muyad/Muya in `~/Library/Logs/DiagnosticReports`.
- AC21: ptyd/muyad not approved in Login Items → onboarding screen shown, session start returns the typed error, approving resumes without relaunch.
- AC22: after migration exactly one scheduler owner exists (`launchctl print` shows no `muya --scheduler` agent) and a test schedule fires exactly once.
- AC23: no terminal content on disk: after 25 sessions × 10 min, `grep` for a canary string printed in a session finds nothing under `~/Library` and `$TMPDIR`.
- AC24: window occluded with 25 streaming sessions: UI CPU ≤5 %; sleep/wake cycle: 0 sessions lost, statuses correct within 5 s.
- AC25: a `deliver-message` retried with the same idempotency key types its text once, also when the app was killed between the two attempts (test).
- AC26: Accessibility Inspector audit of the 8 views + dialogs: 0 unlabelled controls; full keyboard navigation of list, dialogs, tree.
- AC27: downgrade: reinstalling the last Tauri build after the native app reads vault, schedules, servers and prefs without loss.

## 12. Risk register
| # | Risk | Sev | Lik | Mitigation | Owner |
|---|---|---|---|---|---|
| R1 | libghostty-vt API churn / Zig build breaks | H | M | Pin commit + Zig; `TerminalEngine` contract tests; alacritty_terminal / SwiftTerm fallbacks; S2 | core |
| R2 | Own Metal renderer misses quality | H | M | Quality set inside S1 (week 1); AC11; fail = re-decision (no cheap fallback) | UI |
| R3 | IME/VoiceOver gaps in custom views | H | M | S3 week 1; `NSTextInputClient` before other terminal features; AC10, AC26 | UI |
| R4 | TCC / Login Items / env under a LaunchAgent | H | M | S5 extended; onboarding for approval states; AC21 | core |
| R5 | Screen parser port drifts from TS | H | M | ≥200-screen corpus, AC3 | core |
| R6 | Native editor slower to reach Monaco parity (no webview fallback) | H | H | Faz 3 6-8 wk; AC13 checklist; Runestone as alternative component; stop-loss | UI |
| R7 | Protocol/version skew | M | M | Handshake, N-1 matrix, fuzz (AC5); asked restart (AC19) | core |
| R8 | Update/migration breaks installs | H | L | S8 extended; copy-only migration; AC17/18/27 | release |
| R9 | Months of work while main keeps changing | M | H | Shared `muya-core`; main gets patch fixes only; parity re-generated weekly | operator |
| R10 | Memory: two VT copies × 100 sessions | M | M | UI replica only for attached sessions; scrollback cap; §14 budget; AC8 | core |
| R11 | Claude TUI changes silently break the parser (headless auto-approve) | H | H | Weekly canary: real `claude` against the corpus; unknown layout never auto-answered | core |
| R12 | Single-operator bus factor; toolchain (Zig/Xcode/notary) changes on macOS 26 | M | M | Everything scripted; pinned toolchains (`.zig-version`); docs per phase | operator |
| R13 | A same-user process that fully detaches runs the signed app binary and connects | M | L | Hardened runtime; getsid check; per-socket identifiers; muyad never exposes vault values over the client socket | core |

## 12.5 Failure modes & recovery
| Component fails | Effect | Recovery |
|---|---|---|
| Muya.app crash | No UI | Relaunch, reattach; sessions untouched (AC9) |
| muyad crash | Status/broker/vault down for seconds | launchd restarts; re-adopts PTYs with modes + ring; vault re-locks |
| ptyd crash | Live sessions and in-flight tool runs are lost | launchd restarts; muyad respawns from `sessions.json` with `claude --resume`; incident logged and shown |
| ptyd/muyad not approved or disabled | No sessions can start | Onboarding screen + typed errors (AC21) |
| Update replaces ptyd binary while running | Old ptyd keeps running until it exits | Version check on reconnect; protocol-incompatible → asked restart (AC19) |
| libghostty parse fault | muyad crash → row above | Fuzz in CI |
| Socket peer check fails | Client refused | Typed error + log; `muyactl doctor` |
| Sparkle feed unreachable | No update | Retry; manual download link |
| Keychain/Touch ID unavailable | Vault locked | Master-password path (unchanged) |
| launchd KeepAlive crash loop (ptyd or muyad) | Repeated restarts, throttled by launchd | Banner after 3 restarts in 60 s with `muyactl doctor` output; crash reports kept |
| `sessions.json` write fails (disk full) | Reboot recovery may be stale | Keep running; banner; retry on next change |

## 13. Edge cases
Screen lock/sleep with streaming sessions (AC24); full reboot (respawn + resume); 1 MB/s
single-session flood; huge paste; resize storms while detached; session exits while
detached; two app instances; second macOS user (own daemons); clock change for schedules;
unsigned dev builds against release daemons (refused); Claude version changes dialog text
(R11); hardware cursor parked away from the visual input (IME anchor, AC10).

## 14. Performance & cost budget
AC7/AC8. Per session in muyad: ≤12 MB with 5k scrollback (100 × 12 MB = 1.2 GB < 1.5 GB);
ptyd ring 1 MB per session, mode tracker <1 KB. Idle: app ≤1 % CPU, muyad ≤2 %, ptyd ≤0.5 %;
occluded + streaming app ≤5 % (AC24). Launch to first frame ≤300 ms with daemons running.

## 15. Out of scope
New features; Windows/Linux; App Store; MCP contract changes; bridge protocol changes;
GPU-accelerated editor beyond TextKit 2.

## 15.5 Decision log
| # | Decision | By | Alternatives | Why |
|---|---|---|---|---|
| D1 | Stack = ADR-001 A+ | software-architect | in-process UniFFI, SwiftTerm, GPUI, GhosttyKit | Only option keeping sessions alive on UI crash/update with proven IME/a11y |
| D2 | Editor 100% native, no webview fallback | operator | Monaco in one WKWebView | Operator 2026-11-03 |
| D3 | Protocol-incompatible updates ask "now / later" | operator | wait until sessions closed | Operator 2026-11-03 |
| D4 | Prefs/tabs migrate silently | operator | fresh start | Operator 2026-11-03 |
| D5 | Minimum macOS 26 | operator | 14, 15 | Operator 2026-11-03 |
| D6 | Backend strangler, UI big-bang on branch | software-architect | full big-bang | Keeps `main` shippable |
| D7 | Subagents on Sonnet | operator global rule | Opus reviewers per skill | User rule overrides skill |
| D8 | muyad is the sole scheduler owner; old agent unregistered | orchestrator | keep lock-holder model | One owner by construction; no double fire (AC22) |
| D9 | Two daemons, not one tmux-style server | software-architect | single daemon | A parser fault on untrusted bytes must not kill PTYs |
| D10 | Per-socket signing identifiers; session children refused | orchestrator (from V1) | Team ID only | Prompt-injected agent must not drive other sessions |
| D11 | Turkish strings become English | project rule (UI text English) | keep | CLAUDE.md UI rule |
| D12 | Migration is copy-only; formats stay Tauri-readable | orchestrator (from G7) | move | Downgrade path (AC27) |
| D13 | S0 measures the cheaper Tauri path as information only | orchestrator | make it a gate | Operator chose Option D for quality; S0 numbers are reported to the operator |
| D14 | Scheduled prompts stay memory-only, now in muyad | orchestrator | persist | Same behaviour as today (`App.tsx:1310`) |
| D15 | Vault: UI reads the biometry Keychain item via `LAContext`, hands the key to muyad over the signed socket | software-architect | muyad reads it | Prompt attribution is reliable from a GUI process; S6 verifies |
| D16 | Typing requests run in muyad with an in-memory dedupe LRU | software-architect | UI-side dedupe | A UI crash would lose the dedupe set and allow a double type |

## 16. Production-readiness checklist
- [x] Risk register ≥5 (12) · [x] Failure modes per component · [x] Use cases ≥3 (6)
- [x] Decision log · [x] Open questions numbered · [x] Security review (§9)
- [x] Performance budget (§14) · [x] Compliance (no new regulated data; notices in Faz 5)
- [x] Inventory cites verified by the architect gate (30+, 0 false) and quality review (6 more)
- [x] Research claims carry URLs in `docs/native/research-*.md` (UNVERIFIED marked there)
- [x] Migration + downgrade story (§6, AC17-AC19, AC27)

## 17. Open questions
None open. (Former Q1 decided by software-architect, D15.)

## 18. Appendix — research log
`docs/native/research-terminal.md`, `docs/native/research-ui.md`, `docs/native/adr-001-stack.md`;
crates.io checks 2026-11-03: libghostty-vt 0.2.2 (MIT OR Apache-2.0), gpui-libghostty
0.4.1-rc.1, alacritty_terminal 0.26.0, uniffi 0.32.2. Review sources: SMAppService approval
(https://developer.apple.com/forums/thread/721919), Sparkle signing
(https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears), libghostty
stability (https://libghostty.tip.ghostty.org/), zellij resurrection
(https://zellij.dev/documentation/session-resurrection).
