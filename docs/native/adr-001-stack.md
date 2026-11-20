# ADR-001 — Native Muya stack (Option D: no webview)

Status: PROPOSED (2026-11-03) · Author: software-architect · Supersedes: nothing
Doctrine: only resilience, security, operability, 100x headroom (25 -> 100 sessions) decide. Cost, effort, complexity do not.

## 0. Phase-1 gate (inventories vs code)

Verdict: **GO.** 30+ claims spot-checked by grep/sed, 0 false.
Checked OK: 151 `#[tauri::command]` (counted) and `generate_handler!` at lib.rs:463; 41 src/*.rs (+ bin = 42); `pty_spawn` pty.rs:77 (attribute line, fn at :78), `pty_write` :560(:561), `pty_kill` :640(:641); coalescing `MAX_BATCH 128*1024`, `FLUSH 8ms` pty.rs:281-282; event emits menu:new-file lib.rs:405, menu:quit-hint :446, fs-changed watcher.rs:291, fs-files-changed :294, schedules-changed const schedules.rs:31 / emit :1117, ssh-broker-open broker.rs:607, ssh-broker-send :992, rollback comment :1159; BROKER_OWNED_ELSEWHERE lib.rs:356-366; plugin lines Cargo.toml:41/45/67/68; frontend `View`/`Screen` App.tsx:148-149, tab kinds :99, `mountedViews` :420, `closedTabsRef` :816, Cmd+Shift+D :2258, `viewerKindFor` format.ts (pdfview branch), modalKit Cmd+Enter :126, TerminalGrid.tsx imported only by itself (dead, confirmed).
Nits (not false): fn-name line numbers point at the attribute line (off by 1). Both inventories correctly flag their own OPEN QUESTIONS; keep them as spike inputs (broker UI-ack, scheduled prompts persistence).

## 1. Context

Evidence (docs/loadtest-results.md): WebKit pays per `term.write`; 13+ busy sessions = 27-29 fps, 25 = 11-14 fps, switch ~380-770 ms; Chromium holds 50+; Rust side is ~38% CPU of one core, not the bottleneck. So the ceiling is the renderer/webview, and 100 sessions is unreachable in WKWebView.
Backend (inventory-backend): 151 commands, 20 events, 42 modules (9 PURE / 25 THIN / 8 COUPLED). Tauri leaks are few (`ipc::Response`, `Channel`, `AppHandle.emit`). Broker (UDS) + `muya-ssh-mcp` stdio sidecar already out-of-process; `muya --scheduler` already proves the "app binary as background agent" pattern.
Frontend (inventory-frontend): 8 views + Grid (1-6 panels) + split groups (2-8), ~22 dialogs, ~45 shortcuts, Monaco (md/img/pdf viewers), cmdk palette, Claude-TUI screen parser (`lib/screenState.ts`), path-link detection, channel-prompt auto-accept, Turkish strings/users (IME matters).
Platform: Xcode 27.2, Swift 6.4.2, macOS 26.6, Rust 1.93, M4 Pro. No Zig installed (libghostty needs it).

Hard requirements derived: (R1) 100 live sessions, 8+ visibly streaming, >=55 fps; (R2) a UI crash/relaunch/update must not kill session processes; (R3) secrets never on disk/argv, zeroized on lock; (R4) full IME + VoiceOver; (R5) notarized, auto-updating; (R6) every seam observable.

## 2. Options

| | A: Swift/AppKit + in-process Rust core (UniFFI) + libghostty-vt + own Metal | A+: Swift/AppKit + **out-of-process Rust daemons** + libghostty-vt + own Metal | B: Swift/AppKit + SwiftTerm | C: pure-Rust GPUI (+gpui-libghostty or alacritty_terminal) | D: Swift + full GhosttyKit surface |
|---|---|---|---|---|---|
| UI | AppKit | AppKit | AppKit | GPUI (git/fork dep) | AppKit |
| Emulation | libghostty-vt | libghostty-vt | SwiftTerm | alacritty_terminal / libghostty-vt | Ghostty core |
| Renderer | own Metal | own Metal | SwiftTerm Metal (young) | GPUI quads | Ghostty Metal (unsupported API) |
| PTY owner | UI process | detached daemon | UI process | UI process | Ghostty (in UI process) |
| UI crash kills sessions | YES | no | YES | YES | YES |
| IME / VoiceOver | first-class | first-class | first-class | unproven | first-class (Ghostty ships it) |
| Supply chain | Zig + pinned ghostty | same | Swift pkg | git dep on Zed monorepo / third-party republish | Zig + fork patch-queue |

## 3. Pre-mortems (Klein: "shipped; failed at 100 sessions / IME / notarization — why?")

**A (in-process).** (1) A libghostty (Zig) fault or Swift/UniFFI callback bug in the UI process takes 25 Claude sessions, with in-flight tool runs and uncommitted work, with it; user-visible data loss on every UI crash and every update relaunch. (2) Sparkle relaunch = all sessions die; operators stop updating. (3) UniFFI async/callback lifetimes across PTY streams cause deadlocks under load. Verdict: fails R2 by construction. Rejected.

**A+ (chosen; attacked hardest).**
- Two-copy VT state (daemon + UI replica) diverges: after reattach the UI replica is rebuilt from a snapshot, a resize race or truncated escape corrupts the screen. Mitigation: daemon is authoritative; UI reattach = `snapshot()` + sequence-numbered byte stream; resize is a daemon-ordered event; alt-screen TUIs (Claude) self-heal with SIGWINCH nudge. Spike S4.
- Daemon crash (it parses untrusted bytes with Zig code) kills all PTYs, so we merely moved the SPOF. Mitigation: **split into two daemons** — `muya-ptyd` (tiny, Rust, no VT, no network: owns PTY masters, children, a bounded output ring per session; crash-surface minimal) and `muyad` (VT state, screen parser, broker, vault, scheduler, bridge, git/fs; restartable, re-adopts PTYs from ptyd and replays the ring). Blast radius: muyad crash = status loss for seconds, zero process loss.
- macOS TCC / responsible-process: children of a LaunchAgent attribute file-access prompts to the agent, not Muya (we already burned a release on the "other apps data" prompt, L43), login-shell PATH/env, Claude CLI keychain OAuth reachable from agent children? Spike S5 is a hard gate.
- Protocol version skew between app, muyad, ptyd, sidecar after partial update; unauthenticated local IPC = local privilege boundary. Mitigation: versioned framed protocol from frame 1, handshake with min/max version, peer verification by audit token + SecCode requirement (not PID/UID alone; see ADR 0002 on SO_PEERCRED), per-user 0600 sockets in a private dir.
- 100 sessions memory: 100 VT states x 5k scrollback in daemon and visible ones again in UI. Mitigation: libghostty scrollback compression, daemon scrollback cap, UI replica only for attached sessions. Spike S9.
- Vault + Touch ID from a non-GUI process may not prompt or attribute correctly. Spike S6 decides who reads the Keychain.
- Notarization: multiple executables (app, ptyd, muyad, sidecar, Sparkle helpers) each need hardened runtime + correct nested signing order; SMAppService agent plist must be in bundle. Mitigation: signing script from day 1 (S2).

**B (SwiftTerm).** Research shows its Metal path has open issues exactly for our workload ("high main-thread CPU with multiple streaming TUI terminals", #658/#738); view is main-thread bound; Kitty keyboard protocol not documented; weaker conformance than Ghostty. At 100 sessions the main thread is the bottleneck we are escaping. Also in-process PTY (R2 fails) unless combined with daemons, at which point only the emulator is weaker. Rejected as primary; it is the **documented fallback emulator** if S2 (Zig/libghostty build) fails — keep `TerminalEngine` a Muya-owned protocol.

**C (GPUI).** (1) GPUI not publishable on crates.io; only git/fork (gpui-ce, third-party unofficial republish) — an unpatchable upstream with a "tied to Zed" stance in a security-sensitive, credential-holding app. (2) IME / Turkish press-and-hold: zero evidence found; VoiceOver historically opaque. (3) Editor, tree, menus, DnD, file associations, tray all rebuilt on a framework nobody else ships to a general audience. (4) Single process, R2 fails. Rejected; revisit only if S3 (IME matrix) is run against it and passes, which we do not expect to schedule.

**D (GhosttyKit full surface).** Binds PTY + renderer into the UI process (R2 fails, or requires patching Ghostty's termio), API explicitly unsupported/internal, every embedder runs a fork patch-queue (vvterm #127), 25 surfaces each own render/read/write threads and Metal device state (unmeasured), and our Claude-screen parser/snapshot/broker read access would need to reach into a black box. Best out-of-the-box polish, worst control. Rejected as primary; **retained as renderer-only fallback** if S1 shows our Metal renderer cannot reach parity (borrow its renderer through the vt render-state API instead of writing it).

## 4. Door classification (Bezos)

| Decision | Door | Why |
|---|---|---|
| Daemon split (ptyd/muyad) & PTY ownership outside UI | **ONE-WAY** | Everything (protocol, install, update, TCC identity) hangs off it; retrofitting later = rewrite. |
| Wire protocol (framing, versioning, session ids, sequence numbers) | **ONE-WAY** | Persisted across app updates; skew handling. Version from frame 1. |
| Bundle id / Team ID / Sparkle EdDSA key / data dir layout | **ONE-WAY** | Update continuity, Keychain ACLs, TCC grants. Reuse existing bundle id + Team. |
| AppKit as UI framework | **ONE-WAY** | Whole UI. Justified: only stack with proven IME/a11y/menu/tray/DnD. |
| libghostty-vt vs SwiftTerm/alacritty | two-way | Behind `TerminalEngine` protocol; daemon-side. |
| Own Metal renderer vs borrowed | two-way | Behind `TerminalRenderer`. |
| Editor component | two-way | Behind `EditorView` protocol. |
| Updater (Sparkle) | two-way after key fixed | Key is the one-way part. |

## 5. Decision

1. **UI: Swift, AppKit-first (SwiftUI only for leaf views).** NSWindow/NSSplitView/NSOutlineView/NSMenu/NSStatusItem/NSOpenPanel; Swift 6 strict concurrency; `NSTextInputClient` + `NSAccessibility` implemented on the terminal view.
2. **Terminal core: libghostty-vt (pinned commit, Zig pinned in CI, vendored XCFramework/static lib)** in the Rust daemon via the `libghostty-vt` crate, and in the UI as a replica for attached sessions via the C API. `TerminalEngine` stays a Muya-owned trait/protocol (SwiftTerm = fallback, alacritty_terminal = fallback on the Rust side).
3. **Renderer: own Metal renderer in Swift** on libghostty-vt's Render State API (shared glyph atlas across panes, CoreText shaping, damage-driven draw, one CAMetalLayer per visible pane, hidden sessions have no view and no render cost — the exact thing WebKit could not do). GhosttyKit renderer is the borrowed fallback.
4. **Boundary: out-of-process, NOT in-process FFI.** `muya-ptyd` (PTY/children/ring; tiny; launchd KeepAlive) + `muyad` (everything else Rust: VT, Claude screen parser, broker UDS server, vault, schedules, bridge, git/fs/watcher, agent_ops; reuses the 9 PURE + 25 THIN modules after Tauri-leak removal) + app (Swift UI client). Client protocol = versioned framed binary over per-user UDS (control + per-session byte streams with sequence numbers; snapshot on attach); peer verified by audit token + SecCode requirement. UniFFI is NOT on the hot path; use it only (optionally) for pure helpers where a Swift binding beats re-implementation. Sessions survive UI quit/crash/update; muyad crash and restart re-adopts ptyd's PTYs.
   - Screen parser (`parseClaudeScreen`) is ported to Rust inside muyad and runs against libghostty-vt screen text (not rendered pixels), for all sessions, UI open or not. Status (waiting/working/idle), approval Allow/Deny, channel-prompt auto-accept become daemon events. Golden corpus: capture current xterm-derived inputs from v2.1.285 and replay as fixtures; the TS and Rust parsers must produce identical `ScreenState` JSON before TS is deleted.
   - Process model for broker/sidecar: broker lives in muyad (single owner, replaces `BROKER_OWNED_ELSEWHERE` hack: launchd gives one instance). `muya-mcp` stdio sidecar unchanged (separate binary, own signing). `ssh-broker-open/send` and `deliver-message` become explicit command-bus requests with **ack + timeout** to the UI (closes the open question); with no UI attached, muyad queues or fails with a typed error.
5. **Editor: STTextView (TextKit 2) + tree-sitter** behind `EditorView`; markdown = swift-markdown rendering; PDF = PDFKit; images = NSImageView; diff/review = own NSView over the same editor. If S7 fails, the fallback requires a product decision (Monaco in a single WKWebView for the editor only) — see Open Q1.
6. **Updater: Sparkle 2 (new EdDSA key, new appcast).** Update flow is session-aware: app update replaces Muya.app; ptyd is never restarted by an update unless protocol-incompatible, in which case the operator is asked (it ends sessions). Existing users migrate via one last Tauri-updater release whose payload is the native .app (same bundle id/Team) carrying the Sparkle public key (S8).
7. **Migration: backend strangler, UI big-bang on branch.** (a) Extract `muya-core` (no tauri) and build ptyd/muyad + protocol + a headless CLI client + contract tests; Tauri app on `main` keeps shipping untouched (patch fixes only, per project rules). (b) Native app on `wip/native-rewrite` built against the daemons, gated by an inventory-derived parity checklist (151 commands, 20 events, ~45 shortcuts, 22 dialogs). (c) Cutover only when parity + S-gates + 7-day dogfood of 25 sessions. No attempt to make the Tauri UI talk to muyad (throwaway work).

## 6. Consequences

+ 100-session headroom: render cost scales with visible panes, not sessions; parsing is native and off the main thread; hidden sessions cost memory only.
+ R2: UI crash/update/relaunch never kills sessions; muyad crash is non-fatal; scheduler/approvals/notifications keep working with UI closed.
+ Security: secrets live in one hardened process (not in a UI process with a text-input surface); IPC is peer-verified; no network-facing code in ptyd.
+ Operability: each process has own logs, OTel-style spans per seam, `muyactl status/attach/dump`, crash reports per process, replayable ring for debugging.
- Cost accepted: 3 signed executables, installer/agent lifecycle (SMAppService), protocol versioning, own terminal renderer, Zig toolchain in CI, two VT copies, port of ~151 commands and all UI. Zig/ghostty API churn is managed by pinning.
- New failure classes: version skew, daemon install state, TCC attribution, replay fidelity after muyad restart. Each has a spike or test.
- `docs/` PRDs for ssh-cyberark etc. that assume Tauri `AppHandle` need seam updates (events -> command bus).

Disagree-and-commit notes: Research doc (research-ui.md) ranked in-process UniFFI first; rejected here on R2. Research also suggests libghostty-vt ranks above alacritty_terminal; agreed, with alacritty_terminal as daemon-side fallback.

## 7. Week-1 spikes (binary pass/fail; any FAIL on S1-S5 stops the rewrite plan for re-decision)

| # | Spike | PASS iff |
|---|---|---|
| S1 | Swift + libghostty-vt + Metal prototype, 25 live PTYs (loadtest generator: visible 1 MB/s, others 64 KB/s), 6 visible panes, M4 Pro | >=55 fps, frame p95 <=25 ms, tab switch p50 <=50 ms, UI RSS <1 GB; real `claude` TUI renders without artefacts (Kitty kb, 24-bit color, alt screen, resize) |
| S2 | Build chain: pinned Zig + libghostty-vt XCFramework reproducible in CI; hello-app signed, hardened, notarized, stapled with ptyd/muyad nested | `spctl -a -vv` accepted on a clean second Mac/user; identical artifact hash on two builds |
| S3 | IME/a11y matrix on the terminal view and STTextView: Turkish Q layout, press-and-hold g s c i o u, caps-lock İ/ı, Japanese marked text, VoiceOver reads terminal + editor + tree | all items work, zero dropped/duplicated characters in 200-char scripted typing run |
| S4 | Crash isolation: 25 sessions; `kill -9` UI; `kill -9` muyad; update-restart the app | 0 of 25 shell/claude PIDs lost; UI reattach <=500 ms with scrollback intact; muyad restart re-adopts 25 and status parser recovers all within 5 s |
| S5 | TCC/launchd: shells spawned by the ptyd LaunchAgent; run `claude`, touch ~/Documents, ~/Desktop, iCloud, Keychain-stored OAuth, user PATH (nvm/homebrew) under minimal GUI env on a synthetic second user | no unexpected permission prompts, `claude` authenticated and runs, PATH/env equal to Terminal.app login shell |
| S6 | Vault: Touch ID unlock with biometry-ACL Keychain item read by (a) muyad (b) UI-then-handoff; zeroize on lock | pick the variant where prompt shows correctly attributed to Muya, works at screen-lock/unlock, key absent from core dump / `vmmap` after lock |
| S7 | Editor: STTextView + tree-sitter on 5 MB file, 20 languages from lib/format.ts, find, undo, Turkish IME | 60 fps scroll, open <300 ms, no IME bug in S3 matrix. FAIL -> Open Q1 |
| S8 | Update migration: last-Tauri-release payload installs native .app; Sparkle then updates it; ptyd survives app update; skew handshake rejects incompatible daemon cleanly | all three transitions succeed on a clean user; sessions alive after app update |
| S9 | 100 sessions memory/CPU in daemon (5k scrollback, idle + 64 KB/s each) | muyad RSS <=1.5 GB, CPU <=150% of one core, ptyd RSS <200 MB |

## 8. Open product questions (operator)

1. **Editor fallback.** If STTextView cannot match Monaco (S7), is a single WKWebView hosting Monaco (editor only, no terminal) acceptable, or must the app be 100% webview-free? **CANNOT-ANSWER** by architecture; it is a product call. (Not needed until S7 result.)
2. **Updates and live sessions.** When a release changes the daemon protocol incompatibly, may the update end running sessions after a confirm prompt (default proposed: ask, never silent)? **CANNOT-ANSWER.**
3. **Minimum macOS version.** Dropping below macOS 14 constrains TextKit 2/Observation use; what is the oldest macOS you must support? **CANNOT-ANSWER** (I know only your M4/macOS 26 machine).
4. **Existing users' data.** localStorage keys (40) and Tauri-store prefs: migrate silently on first native launch (default proposed) or fresh start? **CANNOT-ANSWER** (how many other installs exist).
