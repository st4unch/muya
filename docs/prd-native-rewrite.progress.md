---
status: active
prd: docs/prd-native-rewrite.md
started: 2026-11-03
---

## Faz Çıktıları
- Research + inventories: docs/native/{inventory-backend,inventory-frontend,research-terminal,research-ui}.md
- ADR-001 (software-architect): docs/native/adr-001-stack.md — Phase-1 gate GO (30+ cites, 0 false)
- PRD: quality review (0 P0 / 11 P1) + adversarial (qualified-yes, 5 SERIOUS) applied; architect GO + 5 amendments.
- Faz 0 task 1 (libghostty-vt build/link), 2026-11-03:
  - PASS: pinned Zig 0.15.2 (Homebrew `zig@0.15`; Homebrew `zig` 0.17 is rejected by Ghostty's build) builds libghostty-vt 0.2.2; Rust tests pass for bracketed paste, alt screen, a sequence split across two writes, Kitty keyboard push/pop, mouse tracking, cursor position (`native/spikes/vt-link`).
  - Throughput: 230 MB/s on one core for Claude-like output (100 sessions × 64 KB/s = 6.4 MB/s ≈ 3% of a core).
  - Reproducible build: PASS (2026-11-03). `native/scripts/ghostty-env.sh` builds libghostty-vt once per pinned commit, offline, in fixed user-independent paths (`/Users/Shared/muya-build/ghostty-<commit>`), Zig packages fetched with Ghostty's packaging script (hash-pinned by build.zig.zon); cargo links it through libghostty-vt-sys `pkg-config` (no clone/build in build.rs; clean cargo build 32 s -> 3.5 s). `--verify` = two clean builds byte-identical (sha256 f1ece39f…).
    - Causes found and fixed: (1) build dir and `~/.cache/zig` paths embedded (home dir leaked into the binary); (2) Zig names per-compilation dirs non-deterministically and records them in DWARF; (3) libtool archive header mtime/uid. Fix: fixed paths + `strip -S` + `libtool -static -D` (in that order; strip rewrites mtime). Shipped archive 1.9 MB, no `/Users/` strings; full-DWARF copy kept in `lib-debug/` for local debugging only.
    - Trade-off: libghostty frames in crash reports get function names, not line numbers.
  - S9 input — `max_scrollback` is BYTES, not lines (C/Rust docs say lines; measured). 120 cols: min one page = 377 rows ≈ 1.3 MB; 10 MB -> 9,089 rows; 11 MB -> 10,061 rows ≈ 10.3 MB; 100 MB -> 96,209 rows. ≈1 KB per 120-col row, memory stays at the limit. Empty terminal ≈ 0.1 MB at 25-100 terminals.
    - Budget at today's xterm scrollback (5000 lines, Terminal.tsx): ≈ 5.3 MB/session -> 25 sessions ≈ 130 MB, 100 ≈ 530 MB in muyad (authoritative state; UI replicas extra). Today WebKit alone is 1.2-2.0 GB at 7-25 sessions (docs/loadtest-results.md).
  - CPU: 577-589 MB/s with 25/100 terminals (long lines), 247 MB/s (short colored lines) -> 100 sessions × 64 KB/s ≈ 1-3% of one core. GPU: not applicable at this layer (no rendering); measured in S1.
  - Must for Faz 1: libghostty-vt-sys silently falls back to cloning Ghostty if pkg-config fails; muyad's build must fail instead (guard in its build.rs).

- Faz 0 task 2 — S2 signed hello bundle, 2026-11-03 (`native/spikes/hello-bundle`, `./build.sh [--notarize|--verify]`):
  - PASS: Swift 6 app (macOS 26 target) + nested Rust `muya-ptyd` / `muyad` in Contents/MacOS with SMAppService LaunchAgent plists; signed inside-out with Developer ID, hardened runtime, own identifier per executable; notarized (Accepted, ~24 s end to end), stapled, `spctl -a -vvv -t exec` = accepted, "Notarized Developer ID" (same user).
  - PASS reproducible: two clean builds give identical executables and CDHashes (ptyd 14ca9e29…, muyad 18e1a4c5…, app 642c6c9a…); no `/Users/` string in any binary (cargo/source/target paths remapped).
  - PASS peer gate (D10), daemons started by hand from the signed bundle: app→muyad→ptyd ok (8 ms); app→ptyd refused (identifier); unsigned app refused; Apple-signed `nc` refused; signed muyad binary running inside a ptyd PTY session refused by ptyd and muyad (getsid); same binary outside a session accepted. Team ID read from our own signature at runtime (nothing team-specific compiled in).
  - Measured: signature check p50 1.4 ms, p95 1.7 ms, max 3.1 ms (200 connections) -> check once per connection and keep connections open, never per message. Daemon idle CPU 0.0%, RSS 14 MB, physical footprint 5 MB, no growth over 200 connections; ptyd listening 0.5 ms after start. GPU: n/a.
  - Design clarifications for Faz 1: (a) the getsid refusal applies to the ptyd and client sockets only — the broker socket must accept `muya-mcp`, which runs inside a session; (b) `sockaddr_un` path limit 103 bytes: the socket dir must be checked (spike fails loudly) and needs a shorter fallback for very long home paths.
  - PASS SMAppService (operator approved registering, 2026-11-03; unregistered afterwards): `register()` -> `.enabled` immediately (status before first register reads `.notFound`, not `.notRegistered`); first hello 68-76 ms after register; agents get PATH=/usr/bin:/bin:/usr/sbin:/sbin (login env is S5's job). `kill -9` ptyd or muyad -> back in 100-180 ms; a second crash within 10 s waits 10 s (launchd throttle) -> `ThrottleInterval=1` brings it to 1.2 s.
  - MUST (measured): `ProcessType=Interactive` for ptyd and muyad. Default agents spawn as "daemon": keystroke path app->muyad->ptyd under 48 busy processes p95 77 ms, p99 92 ms, max 670 ms. Interactive: p50 18-20 us, p95 34-109 us, p99 90-570 us (app side is a CLI test client), muyad->ptyd p99 25 us. Idle either way p50 13-15 us. Persistent connections: first message pays the ~1.5 ms signature check once.
  - NOT YET: `spctl` on a clean second user — needs a second macOS account (operator). Approval states (`.requiresApproval`, disabled in Login Items) — S5.
  - S2 extended: Ghostty core MIT; compiled-in deps: Highway (Apache-2.0 / BSD-3), simdutf (Apache-2.0 OR MIT upstream; vendored copy has no header), Zig compiler_rt (MIT) -> third-party notices in Faz 5.
  - S2 extended, fallback engine (`native/spikes/vt-fallback`, alacritty_terminal 0.26.0): Kitty push/query/pop, split sequence and per-screen stacks PASS; FAIL: 4,097 × `ESC[>1u` panics (`title_stack.remove(0)` in `push_keyboard_mode`) — any program can crash the engine. Fixed on alacritty master, not in a release. libghostty-vt passes the same overflow test. Fallback usable only with a release > 0.26.0 (or pinned fixed commit) and panic isolation per session.

- Faz 0 task 3 — S3 IME / a11y, 2026-11-03 (`native/spikes/ime-lab`, `ImeLab --selftest [--activate]`): keystrokes are generated from the real layout (UCKeyTranslate reverse map of the current input source -> CGEvent, translated by the system) and fed through NSTextInputContext into an NSTextInputClient terminal view writing to a real PTY (`/bin/cat`) and into a TextKit 2 NSTextView.
  - PASS (Turkish Q, 181 characters on the layout, 5 dead keys): 217-character Turkish script incl. Option-layer symbols `@€{}[]\|~` -> 0 dropped / 0 duplicated in terminal and editor; Caps Lock i/ı -> İ/I; Backspace over ş erases the whole character; 5/5 dead keys via marked text (^ ~ ¨ ´ `, expected value computed from the layout); press-and-hold u -> ü (terminal erases the already-sent "u" with DEL and sends ü); a11y: terminal is an AXTextArea "Terminal" whose value VoiceOver's API reads out of process (single and multi-line), file tree is an AXOutline of AXRows, editor an AXTextArea.
  - Measured: per keystroke through the input chain, terminal view p50 19 us / p95 30 / p99 46 / max 617; NSTextView p50 281 us / p99 5.5 ms. Lab app peak RSS 104 MB, 0.28 s CPU for the whole run. GPU: n/a (S1).
  - MUST for ptyd (found by the test): set termios on the slave after the first open (macOS resets tty settings on first slave open); IUTF8 on, or Backspace leaves half a UTF-8 character (`a�` observed).
  - Press-and-hold works only when the app is active (window key) — same for Apple's NSTextView, so it is macOS behaviour, not ours.
  - Japanese IME (operator approved enabling it temporarily): editor (NSTextView) PASS. Terminal view PASS when focus reaches it after Japanese is selected ("nihongo" -> 日本語, 7 setMarkedText, 4 firstRect calls for the candidate window, run with editor first). Root cause of the earlier terminal FAIL, proven with `log stream`: when the input source is switched from the menu bar while a custom NSTextInputClient view already has focus, its context never forwards key events to the input method (zero `imkxpc_wouldHandleEvent`) until it is activated again; NSTextView handles this itself. Fix in the view: on `NSTextInputContext.keyboardSelectionDidChangeNotification`, deactivate/activate the context — asynchronously (doing it inside the notification deadlocked with the TSM UI server; the hung run left Japanese selected until restored by hand). Fix VERIFICATION PENDING: needs an activatable window (display awake, operator present) — after display sleep macOS refuses NSApp.activate, and press-and-hold/IME runs then fail for both views.
  - Test lessons: Kotoeri reads ANSI key codes (type romaji with kVK_ANSI_*, not the Turkish Q map); commit with Return (live conversion; Space picks the next candidate); input-source restore runs OUTSIDE the app (`ime-lab/run.sh` -> `restore-input`) so a hang cannot leave the operator on Japanese; activated runs need the operator idle ≥120 s but the display awake (display sleeps at 180 s here).
  - Activated-window runs only when the operator has been idle ≥120 s (HIDIdleTime), so typing is never captured.
  - NOT YET: listening to real VoiceOver speech (API-level check passed).
  - DECIDED (operator 2026-11-03): "pick the quality one, free; if STTextView wins, relicense Muya to GPL-3.0" -> S7 compares NSTextView (TextKit 2), STTextView, CodeEditTextView on the S7 criteria; architect decides on the numbers. Original note: STTextView is GPL-3.0 or paid commercial licence; Muya is MIT. Options: (a) TextKit 2 NSTextView + tree-sitter (Apple, no licence issue; best IME/a11y; 5 MB performance unproven -> S7), (b) STTextView commercial licence, (c) CodeEditTextView / CodeEditSourceEditor (MIT; 0.12 / 0.15, last releases 2025-07 / 2025-09), (d) relicense Muya to GPL-3.0.

- Faz 0 task 4 — S1 Metal renderer, 2026-11-03 (`native/spikes/metal-term`; libghostty-vt C API from Swift via a module map, linked from ghostty-env.sh's reproducible build): 25 real PTYs fed by a Python load generator (visible 1 MB/s, others 64 KB/s), every session a libghostty-vt terminal + render state, one Metal pass draws all visible panes (instanced cell quads: background pass with underline/strike/bar-cursor lines, glyph pass from a CoreText RGBA atlas incl. color emoji), dirty-row rebuild, triple-buffered instance buffers. Prototype is the heavier case: all 25 replicas live in the UI process.
  - Measured OFFSCREEN (display asleep; renders to a texture on a 120 Hz timer, Retina 2x cells 16x31 px, 6 panes of 80x26): 120 fps sustained, frame interval p95 9.4 ms; CPU per frame (update + encode) p50 2.7 / p95 3.6 ms; GPU per frame p50 1.35 / p95 4.7 ms; ~126 rows rebuilt/frame; process CPU 39 % (incl. parsing 2.6 MB/s); footprint 341 MB; switch of all 6 panes to hidden sessions p50 10.5 / p95 13.5 ms to GPU completion. 100 sessions x 64 KB/s, 1 visible: 120 fps, CPU 42 %, footprint 705 MB (100 scrollbacks in-process; in the design they live in muyad, budget 1.5 GB).
  - AC7 targets (>=55 fps, p95 <=25 ms, switch <=50 ms, RSS <1 GB) met offscreen with large margin. NOT YET: presented fps, input echo and switch latency to the screen (need the display awake); GPU power.
  - Render quality checked from PNG snapshots (`--snapshot`): 24-bit/256 colors, bold/italic/underline/inverse/faint/strike, Turkish, CJK, Korean, box drawing, emoji incl. 👍🏽 and 🇹🇷 (grapheme clustering, DEC 2027, turned on like the Ghostty app), block and bar cursor, alternate screen enter/leave with main screen intact, real `claude` trust dialog renders correctly; resize 110 -> 60 cols reflows and Claude redraws (old-width remnants come from Ink erasing by the old line count after reflow — expected in any reflowing terminal, not verified against Ghostty.app). Ligatures not implemented (AC11 set: off is the default); selection rendering not yet done.
  - Bugs found while building: a CGContext built on a Swift array's inout pointer reads freed memory (black PNG) — build images inside `withUnsafeMutableBytes`; `sips -c` crop produced black images, use `-Z` scaling to inspect.

- Faz 0 task 5 — S4 crash isolation + S9 daemon budget, 2026-11-03 (`native/spikes/crash-iso`: Rust `ptyd` with a fixed 1 MB memory-only ring + mode tracker per session and live fan-out; `muyad` with a libghostty-vt actor per session, re-adopt = replay ring + apply tracked modes; `run.sh [N]` kills -9 muyad A and compares every visible screen with a never-killed reference muyad B). Unit tests: ring vs reference on 3000 random pushes, tracker split sequences + per-screen Kitty stacks, tracker differential vs libghostty-vt on 200 random mode streams.
  - S4 PASS (25 sessions): PIDs 25/25 unchanged; muyad answering again 181-249 ms after kill -9 (re-adopt of 25 sessions, 26 MB replayed, 32 ms); 25/25 visible screens identical to the reference (cells: text + colors + style + cursor); session that set bracketed paste, mouse and Kitty flags 12 MB earlier (ring 1 MB): all modes restored, Shift+Enter encodes CSI 13;2u.
  - Lossy-replay case proven: a TUI with a header drawn once + scroll region loses the header after replay (24/25); a SIGWINCH size jiggle (`winch`) makes it repaint -> identical. Design MUST: muyad sends the resync winch after re-adopt; the tracker must also record DECSTBM (scroll region) and origin mode, or output after the repaint scrolls the wrong region.
  - S9 (100 sessions, 64 KB/s each, one 1 MB/s; steady state after 100 s, CPU from cputime over 10 s): muyad footprint 507 MB (<= 1.5 GB PASS), CPU 59-68 % (<= 150 % PASS); ptyd footprint 103-106 MB (< 200 MB PASS after fix), re-adopt of 100 sessions 123 ms, PIDs 100/100 unchanged, 99/100 identical (the 100th is the header TUI, fixed by winch).
  - Found and fixed: VecDeque ring doubled its capacity on overflow (ptyd 212 MB -> fixed 1 MB buffer, 106 MB); frames now one writev. ptyd CPU ~39 % at this stress load: 23 % is reading 6.4 MB/s from 100 PTYs with no client at all (kernel tty path), the rest is fan-out to two clients; thread-per-session vs single poll loop made no difference (39 % vs 40 %), so Faz 1 can choose either on design grounds.
  - Harness lesson: never kill by matching a command-line pattern — the killing shell's own command line matches too (it killed itself); kill the PIDs recorded at spawn.

- Faz 0 task 6 — S5 environment part, 2026-11-03 (hello-bundle `--envprobe`; agents registered for the run and unregistered after): a login + interactive shell started by the ptyd LaunchAgent (agent env has PATH=/usr/bin:/bin:/usr/sbin:/sbin) gets the SAME PATH as a Terminal.app-like clean login shell (incl. ~/.local/bin, ~/.bun/bin, /opt/homebrew/bin), `claude` resolves to ~/.local/bin/claude and runs (2.1.316). Difference: LANG=C.UTF-8 under the agent — ptyd must set LANG/LC_* from the user's locale like Terminal.app does. Test lesson: interactive shells print escape sequences before output lines; match markers anywhere in a line.
  - NOT YET (needs the operator present): TCC prompts when a session shell touches ~/Documents, ~/Desktop, iCloud; Keychain-stored Claude login under the agent; "agent disabled in Login Items" state; Full Disk Access on the app only.

- Faz 0 task 7 — S7 baseline, 2026-11-03 (`native/spikes/editor-lab/nstextview.swift`; 5.2 MB / 116,649-line TSX file built from this repo; every step renders the visible area into a bitmap, since an off-screen window may draw nothing):
  - NSTextView TextKit 2: open + first screen 39 ms; page scroll p50 3.6 / p95 7.9 ms; typing 1.35 ms/key; footprint +21 MB after open but +1,270 MB after scrolling the whole file — TextKit 2 keeps layout for everything it has laid out, and `invalidateLayout` does not give it back. FAIL on memory.
  - NSTextView TextKit 1, non-contiguous layout: open 38 ms; page scroll p50 1.2 / p95 1.65 ms; typing 0.66 ms/key; +49 MB after the full scroll. Best so far on every number.
  - Implication: STTextView is built on TextKit 2 (NSTextLayoutManager) — expect the same memory curve; CodeEditTextView has its own layout. Fetching both (GitHub via SwiftPM) was blocked by the auto-mode check (external code) -> operator approval needed to finish S7. Measurement lesson: without forcing a draw (`cacheDisplay`), scroll timings measure layout only (TextKit 1 showed 0.03 ms/page).

- Faz 0 — S0 (information only, D13), 2026-11-03 (`native/spikes/s0-xterm/switch-cost.mjs`): in today's stack a visible-only xterm design pays its cost at switch time: new xterm + WebGL + replay of held output to the next frame = WebKit p50 18 ms (64 KB) / 22 ms (256 KB) / 28 ms (1 MB), max 35 ms (Chromium headless 148-164 ms, software GL). Frame rate with only the visible terminals mounted is the 7-session figure already measured (62-64 fps WebKit, docs/loadtest-results.md) vs 11-14 fps with 25 mounted. So the Tauri app could reach ~60 fps at 25 sessions with ~30 ms switches; the native prototype does 120 fps, ~10 ms switches at 25 sessions (offscreen) with every replica live. Recorded for the operator; the native decision stands.

- Faz 0 — parity + corpus seeds, 2026-11-03:
  - `native/tools/gen-parity.mjs` -> `docs/native/parity.md` (334 rows: 151 commands, 29 events, 36 shortcuts, 34 dialogs, 10 Settings rows, 37 localStorage keys, 11 views, 4 viewer kinds, 13 token groups, 9 schemes; phase-tagged; `--check` fails a done row without evidence; 6/6 tests via `node --test 'native/tools/*.test.mjs'`). Code scan found 29 events vs the inventory's 20 (multi-line/constant `.emit` calls the inventory missed).
  - Corpus capture tool `native/spikes/crash-iso/src/bin/capture.rs` + `capture-free.steps.tmpl` (zero-cost screens, no prompt sent): runs a program on a PTY, answers terminal queries through libghostty-vt, encodes keys for the current modes, `wait-for` / `choose` / `snap` steps, writes `.bin` + `.txt` like the existing fixtures. Captured the trust dialog for Claude 2.1.317 and 2.1.78 at widths 60/80/120/160/240 (10 screens; not committed: the dialog prints the folder path, which contained the username — recapture under a neutral path in Faz 1).
  - NOT YET: idle + permission-mode screens. Findings while trying: (1) on this machine a login shell's PATH puts the old claude 2.1.78 first; claude 2.1.317 started there ignored Enter — the tool now uses a non-login shell and the claude path is passed explicitly; (2) Claude ignores Enter for seconds after drawing the trust dialog; (3) with the CLAUDE* environment markers removed (needed so screens look like a user's session), the trust dialog never accepted Enter (10 tries over 20 s) while Down worked; with the markers present it accepted after a 5 s wait — root cause not found (time-boxed). Also: 2.1.317's trust dialog defaults to "No, exit" for a temp folder; option order differs from 2.1.78 (`choose` handles both). The 5-hour usage limit was at 97 %, so no prompt-based captures (spinner, permission dialogs) were attempted.
  - Native design notes from this: ptyd must not pass the app's own CLAUDE* variables to sessions; resolve `claude` by capability, never by first-on-PATH (existing lesson).

- Faz 0 GATE (software-architect, 2026-11-03): CONDITIONAL-GO for Faz 1. S0 info; S1 PASS-with-pending (window fps/input echo/switch, GPU power: before Faz 2); S2 PASS-with-pending (spctl on a second user: before Faz 1 ends); S3 PASS-with-pending (Japanese fix verify, VoiceOver speech: before Faz 2); S4 PASS-with-pending (UI kill reattach <=500 ms, update-restart, parser recovery <=5 s: measure in Faz 1); S5 env PASS, TCC/Keychain/Login Items before the ptyd spawn path is final; S6 + S8 NOT STARTED -> written fallbacks in docs/native/fallbacks.md (gate condition met); S7 baseline (before Faz 3); S9 PASS; parity.md PASS; corpus tool partial (Faz 1).

- Faz 1 (started 2026-11-03), workspace `native/` (`eval "$(native/scripts/ghostty-env.sh)"; cd native; cargo build --workspace; cargo test --workspace`):
  - muya-proto v1: u32-length frames; JSON control messages, raw output/input frames; 16 MiB cap, 1 MiB chunks; hello/welcome handshake (same major, any minor). AC5 PASS: one major off -> typed `incompatible`, N-1 minor works, 10-minute fuzz run (arbitrary bytes, random splits) 0 crashes.
  - muya-core (AC1, in progress): validate + local_guard moved out of src-tauri (git mv); the Tauri app re-exports them under the old paths; `cargo tree -p muya-core | grep -c tauri` = 0; src-tauri `cargo test --lib` 421/423 with 2 timing tests failing only while the 10-minute fuzz loaded the CPU (pass 3/3 alone).
  - muya-peer: per-socket gate from S2 (identifier + our Team ID on the audit token, getsid refusal, unsigned dev builds accept same-user peers only), socket dir with a short per-user-temp fallback for the sun_path limit.
  - muya-ptyd v1: 8 unit tests (ring vs reference; tracker incl. DECSTBM, origin mode, XTSAVE/RESTORE, strings ended by ESC; differential vs libghostty-vt on 500 random streams — it caught two real mismatches: DECSTR is ignored by libghostty-vt, and ESC inside an OSC ends the string) + 7 integration tests on the real binary (handshake/roles, I/O + exit, IUTF8 + no CLAUDE*, late attach gets exactly 1 MB ring + modes after 3 MB, a dying client leaves sessions alive, resize + close, a process inside a session is refused).
  - muyad v1: actor per session (libghostty-vt, 5.5 MB scrollback in bytes), re-adopt = ring replay with terminal replies suppressed (old queries in the ring must not be answered again) -> tracked modes -> SIGWINCH resync; app attach sends Attached + a VT snapshot from the actor thread so no live byte overtakes it; key/paste/mouse encoded in muyad for current modes; LANG from the user's locale; build.rs fails without the pinned libghostty (no silent Ghostty clone).
  - AC2 PASS (`cargo test -p muyad --test ac2`): 25 sessions, kill -9 muyad -> listed again after 847 ms, 25/25 PIDs unchanged, session that set bracketed paste + mouse + Kitty 12 MB earlier: modes restored, Shift+Enter = CSI 13;2u, paste = ESC[200~hi ESC[201~, click = ESC[<0;5;3M reach the program.
  - Lesson: a long background cargo run holds the target-dir lock; other cargo commands block until it ends (looked like a hung test). Run long jobs with a separate --target-dir.
  - AC6 PASS (unsigned part, `cargo test -p muyad --test ac6`): muyactl is read-only (Spawn refused), a process inside a session is refused on muyad's client socket also after a double fork; a release muyad answers Inspect with "unexpected message" (no dump in release). The identifier check itself was proven with signed binaries in S2; recheck when the daemons are bundled.
  - AC23 PASS (`native/tests/ac23.sh 10`): 25 sessions printed a unique canary for 10 min; it is found nowhere under ~/Library/{Application Support/Muya, Caches, Logs, Saved Application State, Preferences, HTTPStorages, WebKit}, $TMPDIR or /tmp (TCC-protected folders not scanned on purpose). muyad 34 MB. First attempt hung: `grep -r` blocked reading a FIFO — the scan now uses `-D skip`; a killed grep would have printed a false PASS, that run was discarded.
  - AC3 parser parity: Rust port of src/lib/screenState.ts in muya-core (`screen`), JSON equal to the TypeScript parser on 234 cases (18 captured screens + cut-off variants, `native/tools/screen-golden.mjs`). Corpus size (>=200 real screens, >=2 versions) still open. muyad parses each session's screen at most every 100 ms and pushes `Screen` events on change; after kill -9 muyad the state is back in 854 ms (S4 criterion "parser recovers <= 5 s" PASS).
  - AC4: today's sidecar `tools/list` snapshot committed (37 tools, 36,023 bytes); `native/tests/ac4-tools-list.sh` byte-compares. Broker moved to muya-core behind a `BrokerHost` trait (events, vault, CyberArk, agent SSH, schedules, bridge); src-tauri implements it with AppHandle. Live check on a dev build with a fake HOME: list_servers ok, list_secrets refused while locked with the old message, sidecar tools/call ssh_list_servers through the broker ok. Hosting the broker in muyad is next.
  - muya-core now holds: validate, local_guard, screen, workspace_roots, fsutil, debuglog, inject, ssh (minus the PTY connect path), askpass, agent_ssh, agent_ops, broker — 122 tests; src-tauri 299; total unchanged (421). `cargo tree -p muya-core | grep -c tauri` = 0.
  - SECURITY fix found by a flaky test: on macOS FD_CLOEXEC is set only after a socket/PTY is created, so a fork-based spawn could leak ptyd's connection to muyad (a session talking to ptyd as muyad) or another session's PTY master into a new session. ptyd now spawns sessions with posix_spawn + POSIX_SPAWN_CLOEXEC_DEFAULT (+ setsid, default signals, empty mask; the slave opened in the child becomes the controlling tty). Test: a session starts with exactly fds 0-2 = the tty; Ctrl+C reaches it as SIGINT; SIGPIPE is default.
  - Other bugs fixed on the way: debug-log rotation race (two threads rotating lost lines; exists in today's app too -> CHANGELOG when merged); test dirs named by time collided under parallel tests; test-started ptyd now exits with its parent (no orphans).
  - Open: muyad and the Tauri app spawn helper processes (`claude agents --json`, git, ssh) with std Command — the same descriptor race can briefly keep a closed broker listener alive in a child (a restarted Muya could then see the socket as "owned elsewhere"). Plan: a muya-core spawn helper on posix_spawn + CLOEXEC_DEFAULT for every child process.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-11-03 | native/spikes/vt-link | libghostty-vt link + mode tests + throughput | Faz 0 task 1 |
| 2026-11-03 | native/scripts/ghostty-env.sh, native/spikes/vt-link | reproducible offline libghostty build + memory budget test | Faz 0 task 1 |
| 2026-11-03 | native/spikes/hello-bundle | signed/notarized app + nested daemons, peer gate, reproducible build | Faz 0 S2 |
| 2026-11-03 | native/spikes/vt-fallback, vt-link | Kitty keyboard tests incl. stack overflow | Faz 0 S2 ext |
| 2026-11-03 | native/spikes/ime-lab | IME / a11y self test on terminal view + NSTextView | Faz 0 S3 |
| 2026-11-03 | native/spikes/metal-term | Swift + libghostty-vt + Metal renderer, 25-PTY bench, snapshots | Faz 0 S1 |
| 2026-11-03 | native/spikes/crash-iso | ptyd ring/mode tracker + muyad re-adopt, kill -9 harness, 100-session budget | Faz 0 S4, S9 |
| 2026-11-03 | native/crates/{muya-proto,muya-core,muya-peer,muya-ptyd,muyad} | protocol v1, core extraction, peer gate, ptyd v1, muyad v1 | AC1 (partial), AC2, AC5 |
| 2026-11-03 | native/app | Faz 2 start: MuyaNative.app (swiftc, ad-hoc), Swift protocol client + tests, sidebar + Metal terminal + NSTextInputClient, run-dev.sh / verify.sh / measure.py, screenshots | Faz 2, AC7 (partial), AC9 shape |

## Kararlar
- Faz 1 design MUSTs from Faz 0 (architect, 2026-11-03), binding for implementation; the PRD text is not edited during implementation, these amend it: ProcessType=Interactive + ThrottleInterval=1 for ptyd/muyad; getsid refusal on ptyd + client sockets only (broker accepts muya-mcp from sessions); socket dir with a short fallback for the 103-byte sun_path limit; signature check once per connection, connections kept open; termios after first slave open, IUTF8 on; LANG/LC_* from the user's locale; no CLAUDE* variables into sessions; resolve claude by capability; tracker records DECSTBM + origin mode; SIGWINCH resync after re-adopt; fixed-capacity ring; muyad build.rs fails if pkg-config fails (no Ghostty clone); scrollback budget in bytes (max_scrollback is bytes); Faz 2 IME: re-activate the input context asynchronously on keyboardSelectionDidChange.
- Editor (architect, from S7): baseline = NSTextView TextKit 1 non-contiguous layout + tree-sitter; STTextView (TextKit 2) and CodeEditTextView are challengers once the fetch is approved; the GPL-3.0 relicense is only needed if STTextView wins on the numbers.
- Added risks: no energy/idle-power measurement yet (add to S1 with the display awake); SwiftPM fetches pinned by revision and hash once approved.
- PRD approved by software-architect (GO + 5 amendments) 2026-11-03.
- Operator 2026-11-03: editor = best free option by S7 measurement; relicensing Muya MIT -> GPL-3.0 is acceptable if STTextView wins.
- Operator 2026-11-03: quality over speed — every step reports CPU / memory / GPU; time is not a constraint.
- Operator 2026-11-03: editor 100% native (no webview); protocol-breaking update asks "now/later"; macOS 26 minimum; prefs migrate silently.
- Faz 2 start, 2026-11-03 (`native/app`): idle app = 0.0% CPU, 53 MB footprint, 0 wakeups; 50 MB `yes` through the visible session = 87 fps, renderer CPU p50 0.34 / p95 2.0 ms, GPU p50 0.21 / p95 2.1 ms, app ~130% CPU (reader thread = libghostty parse; lines/s bound). kill -9 + relaunch: same sessions and screen text. Open: muyad attach snapshot leaves the cursor on the last tab stop (client repairs it; upstream order should change); per-session replicas for all sessions (no Detach in protocol); IME preedit not drawn.

## Dersler
- Trust a subagent's "all green" only after rerunning: the broker move was correct, but rerunning the full workspace exposed a test-dir collision and a real descriptor-leak race.
- A scan that a killed process ends early can print PASS: discard such runs; `grep -r` must skip FIFOs (`-D skip`).
- Never kill by matching a command line pattern: the killing shell's own command line matches (it killed itself). Kill the PIDs recorded at spawn.
- Restore of operator-visible system state (input source) must run outside the process under test; a hung test left Japanese selected for 1-2 min.
- Off-screen measurements must force real work: an off-screen window may not draw (scroll timings were layout only); `sips -c` produced black crops, inspect with `-Z`.
- Before asserting a regression on a screen fingerprint, check what it covers (scrollback vs viewport) and that the reference saw the same input (a reference that attached late is not a reference).

## AC1 inventory (src-tauri/src → muya-core)

| Module | Status |
|---|---|
| agent_ops, agent_ssh, agents, askpass, broker (logic), debuglog, fsutil, history, inject, local_guard, opencode, screen, sessions, ssh (config/cmds), validate, workspace_roots, schedules, spawn | moved (earlier) |
| term_history, slash_commands, claude_settings, statusline, app_prefs | moved (36a8387, b2372c9) |
| file_history, agent_files, app_location | moved (c00af05) |
| vault, watcher (WatchState::start/set_open_files take host callbacks) | moved |
| credstore, cyberark | moved, no logic change (53ba839, 8691929); zeroize untouched; only `lock_store` extracted so the shim can add the UI event |
| fs (files/git/worktrees), pm, testutil | moved (7a13ded) |
| spotlight, login_item, bg_service | moved (2b68b84 renames + c7405f5); `bg_service::run()` stays in the shim (tauri runtime) |
| bridge, bridge_exec, bridge_mcp, bridge_remote | **moved** (46100b0): `BridgeHost` trait (emit / runtime / remote_state / running_sessions); src-tauri keeps `TauriBridgeHost(AppHandle)` + `#[tauri::command]` wrappers. Only AppHandle→host indirection changed; crypto/pairing/framing untouched |
| pty, ssh (PTY connect path), broker host shim, lib.rs | stay: Tauri Channel/AppHandle/State glue |
| titlebar, metrics | stay: UI/telemetry |

Checks: `cargo tree -p muya-core | grep -c tauri` = 0; no home-directory path in native crates/src-tauri/src; tsc clean; vitest 525/525; native workspace 347 pass; src-tauri `--lib` 125 pass (+3 ignored; the rest of the old 264 now run in muya-core); ac4-tools-list byte-identical.

## AC18 prefs migration + AC27 downgrade safety (2026-11-04)

- `muya_core::migrate::run(home)`: copies the Tauri webview's localStorage (keys `muya.*` / `apex.*`, UTF-16 values — tabs, workspaces, layout, theme, terminal prefs) into `~/Library/Application Support/com.staunch.muya/native/ui-prefs.json` (0600) and writes `migrated.json` (version marker + list of shared `~/.claude/muya-*.json` files). Read-only on the source: the sqlite db and its `-wal`/`-shm` are copied to a temp dir and queried there with `/usr/bin/sqlite3`. Shared `~/.claude/muya-*.json` are not copied (D12: shared as they are).
- Idempotent (marker version ≥ 1 → no-op). Fresh install → marker only. Corrupt/unreadable db → `Outcome::Unreadable`, nothing written, retried next launch.
- Tests (muya-core, 7): copy correct incl. Turkish/Japanese/emoji values, prefix filter, **sha256 of every pre-existing file identical before/after** (WAL fixture), second run no-op, corrupt db, older marker re-runs, UTF-16/Latin1 decode. Fixture is synthetic, built by a test helper.
- AC27 test `src-tauri/tests/downgrade_native_files.rs`: temp HOME; vault (Argon2 store), ssh servers, schedules, app prefs written as Tauri leaves them → native migration + muyad-style schedule rewrite → read back with the code the Tauri build re-exports: vault unlocks and reveals the secret, servers/schedules/prefs intact, Tauri webview data byte-identical.
- src-tauri deps removed (no use in `src-tauri/src` or `tests`, verified by grep + `cargo build` + `cargo test --lib`): notify, reqwest, scraper, rustls, tokio-rustls, dirs-next, rcgen, spake2-conflux, hkdf, rand, aes-gcm, argon2, security-framework, core-foundation, objc2, objc2-foundation, objc2-service-management. `sha2` moved to dev-dependencies (the AC27 test hashes files).
- Not wired yet: the native app must call `migrate::run` on first launch (native/app is out of this task's paths).

## Acceptance status (2026-11-04, branch `wip/native-rewrite`, 89 commits since main)

Strict: PASS needs a committed test or a key in `native/app/measurements.json`. Parity.md today: 31 verified, 5 wip, 297 todo (AC16 is far from done).

| AC | Status | Evidence / what is missing |
|---|---|---|
| AC1 | PASS | `cargo tree -p muya-core \| grep -c tauri` = 0; workspace tests green; bridge move 46100b0, inventory d014331 / 93360bd | 2026-11-05: `cargo test --workspace` 502 passed / 0 failed / 20 ignored, twice.
| AC2 | PASS | `cargo test -p muyad --test ac2` (347ae84): 25 sessions, kill -9 muyad, back in 847 ms, 25/25 PIDs, modes restored |
| AC3 | PASS | 17e9a8b: 640 captured screens, 2 Claude versions (2.1.317 / 2.1.310), widths 60-240, Rust = TS parser on all |
| AC4 | PASS | a92cd6c snapshot (37 tools) + `native/tests/ac4-tools-list.sh` byte-identical; broker e2e 3722e60 | 2026-11-05: `ac4-tools-list.sh` byte-identical (36262 bytes); `muyad --test broker` PASS with a freshly built sidecar.
| AC5 | PASS | muya-proto tests + 10-min fuzz, 0 crashes (Faz 1 notes above) |
| AC6 | PARTIAL | f693775 unsigned-build tests PASS (double-fork, no Inspect in release). The "same Team ID, different identifier" refusal was proven only in the S2 spike; re-test with the bundled signed daemons |
| AC7 | PASS | `ac7` key, real window: 99.9 fps, frame p95 2.9 ms, echo p50 6.8 ms, switch p50 8.6 ms, app RSS 130 MB (2b71440) | **2026-11-05 re-run: switch p50 27.4 ms (was 8.6, +219 %), still under the 50 ms target but regressed; see Regression run below** **2026-11-06 run 2 (0d48af3): grid now shows 4 tiles by default (AC7_VISIBLE=4): fps 68.0/tile, frame p95 1.6 ms, switch p50 22.8 / p95 34.8 ms (was 9.5 / 21.8: +140 %), echo not measurable in the 4-tile grid (n=0, script drift), CPU app 13.5 / muyad 23.4 / ptyd 12.4 %, app RSS 124 MB. Switch regression: see Regression run 2.** **2026-11-06 run 3 (f59b913, 6 tiles): release daemons fps 98.1, frame p95 2.9 ms, echo p50 8.7 / p95 15.6, switch p50 11.2 / p95 17.9, CPU app 27.1 / muyad 15.9 / ptyd 9.7 %, app RSS 157 MB; debug daemons fps 92.4, echo 9.1 / 15.5, switch 11.6 / 20.0, CPU 26.4 / 23.3 / 13.8, RSS 141 MB.**
| AC8 | PASS | `ac8` + `ac8_daemon`: UI 97.5 fps; muyad 563 MB / 89 % CPU, ptyd 114 MB (debug build) | **2026-11-05 re-run: fps 98.9, echo p50 9.4 ms, muyad 521 MB / 63 % CPU, ptyd 108 MB all fine, but session switch p50 69.9 ms / p95 177 ms (was 8.4 / 15.1) now FAILS the 50 ms target** **2026-11-06 run 2: fps 98.5, frame p95 3.2 ms, echo p50 8.0 / p95 14.5 ms, CPU app 12.4 / muyad 56.6 / ptyd 22.9 %, muyad 521 MB, ptyd 109 MB, app RSS 121 MB, but switch p50 54.9 / p95 100.5 ms (was 10.7 / 19.4) FAILS the 50 ms target; bisected to 2479991.** **2026-11-06 run 3: release daemons fps 99.3-99.6, echo p50 5.5-8.7, switch p50 11.7-11.9 / p95 16.4-17.0, CPU app 12.3 / muyad 24.7 / ptyd 15.2 %, muyad 521 MB, ptyd 109 MB; debug daemons fps 99.5-99.9, echo 4.6-8.2, switch 11.2-11.6 / 17.9-18.7, muyad 52.8 % (debug build; release 24.7 %), RSS 150-159 MB. Switch target PASS again (run 2: 54.9).**
| AC9 | PASS | `verify-ac9.sh`: 25 sessions, `kill -9`, relaunch, 5/5 runs. Sidebar lists all 25 at 357–370 ms after process start (p50 366, max ≤386, target 500); each session's screen-text hash equals the pre-kill hash (0 mismatches); 0 shell PIDs lost. Recorded in `measurements.json` (`ac9`) | 2026-11-05 re-run 5/5 PASS, sidebar lists 25 at 310-322 ms (p50 315), 0 mismatches, 0 PIDs lost. 2026-11-06 run 2: 5/5 PASS, sidebar lists 25 at p50 328 ms (max 335), 0 mismatches, 0 PIDs lost. 2026-11-06 run 3: 5/5 PASS, p50 316 ms (max 329), 0 mismatches.
| AC10 | PASS (real press-and-hold: NEEDS-OPERATOR) | `verify-ac10.sh` against the app's terminal view: Turkish 200-char run (ğ ş ç ı ö ü, İ/ı with caps lock) via CGEvent to the dev app pid, 200 typed = 200 received; Japanese marked-text run via the text-input API (40 compositions, 200 chars) exact; IME candidate rect within 3 px of the drawn cursor at two positions (`ime-anchor-*.png`); an AX script reads the terminal's visible lines. Fixed on the way: stale IME anchor with hidden cursor, wide chars split by spacer cell. Physical-keyboard press-and-hold stays NEEDS-OPERATOR | 2026-11-05: verify-ac10.sh 9/9 PASS. 2026-11-06 run 3: 9/9 PASS.
| AC11 | NEEDS-OPERATOR | 20 screenshot pairs vs Ghostty.app and sign-off file `docs/native/render-signoff.md` (does not exist) |
| AC12 | PARTIAL | auto-allow decision logic + tests (74fab80). Not measured end to end: UI closed, macOS notification ≤2 s |
| AC13 | OPEN | Editor not built (S7: TextKit 1 baseline 5.2 MB file 38 ms open, challengers not fetched) |
| AC14 | PASS | `ac14` key: create/rename/delete/mkdir, 0 missed, worst 365 ms (<1 s) |
| AC15 | PARTIAL (amended) | Literal `vmmap \| grep -c WebKit` = 0 is impossible: an empty AppKit window already shows 29 WebKit regions (`ac15` key). Amended: no WebKit linked (`otool -L` 0 lines), no WebContent helper, count ≤ empty window. Amended check PASS; needs PRD wording sign-off. Markdown/image/PDF views exist (55c390f) |
| AC16 | OPEN | parity.md: 31 verified / 5 wip / 297 todo |
| AC17 | NEEDS-OPERATOR | Needs a clean second macOS user + the last Tauri release with the native payload (Faz 5) |
| AC18 | PARTIAL | 94db65d: `migrate::run` + 7 tests (synthetic Tauri data, source sha256 unchanged). Not wired into the app's first launch; not run on a real captured data set |
| AC19 | DONE | Restart dialog (`RestartDialog.swift`): lists the live sessions, "Later" keeps all running (compat hello), "Restart service" sends Upgrade, waits for the daemons, reopens sessions from `upgrade.resume_plan`/`resume_done`. `verify-ac19.sh` in the real app: 3 sessions keep ids + screen hashes through "Later" and come back in the same folders with the same screen hashes after the restart; screenshots dark+light | 2026-11-05: verify-ac19.sh 20/20 PASS. 2026-11-06 run 2: 20/20 PASS. 2026-11-06 run 3: 20/20 PASS.
| AC20 | NEEDS-OPERATOR | Developer ID signing + `spctl` on a second user + 7-day dogfood (6a93ff8 is ad-hoc only) |
| AC21 | DONE | Onboarding screen (`Onboarding.swift`): explains the service, opens Login Items, polls `upgrade.status` every 2 s (`ptyd_linked`), continues by itself when ptyd is approved. `verify-ac21.sh` in the real app (unreachable ptyd, no real login items touched): typed `not_approved`, screen shown, no session can start, same process continues; polling CPU 0.03 % = idle; screenshots dark+light | 2026-11-05: verify-ac21.sh 11/11 PASS. 2026-11-06 run 2: 11/11 PASS. 2026-11-06 run 3: 11/11 PASS.
| AC22 | PARTIAL | 59042b9 `muyad --scheduler` + 855d656 lock tests: one owner in tests. The `launchctl print` check and the real background-agent migration are not run (plan only, 521a835) |
| AC23 | PASS | `native/tests/ac23.sh 10`: 25 sessions × 10 min, canary found nowhere (Faz 1 notes above) |
| AC24 | PARTIAL | `ac24` key: minimized app CPU 0.0 %, sleep/wake 25 → 25 sessions, 54.5 ms. Screen was locked, so the occlusion event was driven through the debug `occlude` hook (miniaturize also issued); repeat with a real occlusion |
| AC25 | PASS | ddc00c1: persisted idempotency key survives kill -9 (test) |
| AC26 | PASS (VoiceOver listening: NEEDS-OPERATOR) | `verify-ac26.py`: 35 surfaces (Sessions, Schedules, Settings, palette, Files, viewers, Inspector, SSH & Passwords, Queue, cleanup, scheduled prompt, dialogs, sheets), 554 controls, 0 unlabelled, 0 not focusable, 20 keyboard-only checks (list, dialogs, tree; Tab no longer trapped in prompt fields). Source is the in-app NSAccessibility walk: an external AXUIElement walk sees only a flat app element because the screen is locked (loginwindow frontmost, `CGSSessionScreenIsLocked`) | **2026-11-05 re-run: FAIL, 35 surfaces, 469 controls, 4 unlabelled (`SessionTabs` AXRadioGroup on the 4 Sessions surfaces, added in bdad948), 0 not focusable, 18 keyboard checks; fix = give SessionTabs an accessibility label** **2026-11-06 run 2: FAIL (5): 35 surfaces, 526 controls, 1 unlabelled (an AXTextField in the grid view, a message field of the new grid panels), keyboard checks: Sessions search no longer takes focus on arrival (e9f47e2 by design), Clean up dialog Esc check (698394e modal rewrite).** **2026-11-06 run 3: PASS, 35 surfaces, 526 controls, 0 unlabelled, 0 not focusable, 21 keyboard checks.**
| AC27 | PARTIAL | `src-tauri/tests/downgrade_native_files.rs` (94db65d): vault, servers, schedules, prefs read back with Tauri code. Not run by reinstalling a real last Tauri build |

| Spike | Status | Evidence / what is missing |
|---|---|---|
| S1 Metal renderer | PASS | 120 fps offscreen, 25 PTYs; now also in the real window (AC7). Ligatures off by default; quality set → AC11 |
| S2 signed bundle + peer gate | PARTIAL | Signed, notarized, reproducible, SMAppService PASS. Missing: `spctl` on a second user |
| S3 IME / a11y | PARTIAL | Turkish PASS; Japanese editor PASS, terminal fix (async re-activate) verification pending; VoiceOver speech not heard |
| S4 crash isolation | PASS | 25/25 PIDs, screens identical (crash-iso, 848bce2); kill -9 muyad → screen state back in 854 ms. Update-restart part is S8 |
| S5 environment | PARTIAL | PATH/LANG PASS. TCC prompts, Keychain Claude login under the agent, "agent disabled in Login Items", FDA-on-app-only not tested |
| S6 vault Touch ID | OPEN | Only a written fallback (docs/native/fallbacks.md) |
| S7 editor | PARTIAL | NSTextView TextKit 1 baseline measured; STTextView / CodeEditTextView not fetched |
| S8 update migration | OPEN | Written fallback only; Sparkle not integrated (6a93ff8 is bundle/sign prep) |

## Regression run 2026-11-05 (HEAD b97ae25, wip/native-rewrite)

Unit suites (rebuilt tree): `cargo test --workspace --no-fail-fast` 502 passed, 0 failed, 20 ignored (twice); `build.sh` 0 warnings; `build.sh test` 172 tests, 0 failures; `ac4-tools-list.sh` byte-identical; src-tauri `cargo test --lib` 39 passed (3 ignored); `tsc --noEmit` clean; vitest 525 passed (70 files).
Test-harness traps found (not product bugs): (1) `muyad/tests/p7.rs:297` fails when the suite runs with a custom `TMPDIR` (the daemon is started with a cleared env, the test looks in `std::env::temp_dir()`); (2) `muyad/tests/broker.rs:120` fails after any `cargo build/test` in `src-tauri`, because that build copies the stale prebuilt `binaries/muya-ssh-mcp-*` over `src-tauri/target/debug/muya-ssh-mcp`; run `cargo build --bin muya-ssh-mcp` first; (3) `muya-core agents.rs:757 branch_for_is_memoized_within_ttl` asserts "< 1 ms" and failed once on a busy machine (flaky, passed on re-run).

Real-app scripts (each on its own throwaway stack, app rebuilt first):
| Script | Result |
|---|---|
| verify.sh 6, verify-terminal 19, verify-files 36, verify-queue 19, verify-ssh 19, verify-ac9 5/5 runs, verify-ac10 9, verify-ac19 20, verify-ac21 11, verify-p3 52, verify-p4 49, verify-p6 14, verify-p7 14, verify-p12 6, verify-inspector (screenshots only) | PASS, 0 FAIL |
| verify-p0.sh | 7 PASS, 3 GAP (Shift+Enter, Cmd+R, Cmd+K bytes; already todo in parity.md) |
| verify-pages.sh | 79 PASS, 5 FAIL, 6 SKIP |
| verify-4e.sh | 72 PASS, 5 FAIL |
| verify-ac26.py | 39 PASS, 6 FAIL (SessionTabs unlabelled on 4 surfaces + 2 summary lines) |

Failures and causes:
- **Sessions grouped per project, `path=` filter, "history is still listed below"** (pages x2, 4e x1): the Sessions page is a flat card list since c3cee45 (`SessionsPage.swift:227` builds one `Group(cwd: "")`); the scripts still expect `group alpha 3`. Test drift after the restyle. Update the scripts or restore grouping.
- **SessionTabs has no accessibility label** (pages x1, 4e x1, ac26 x4): `SessionCards.swift:133` (bdad948) sets role radioGroup + value but no label. Real AC26 regression.
- **A setting changed <= 1 s before a SIGTERM is lost** (pages: "theme still Dark" + "theme applied at startup"; 4e: "setting off: nothing is reopened" + "no terminal exists"): b97ae25 put prefs behind a 1 s debounce (`PrefsLogic.swift` `LegacyStore`); `applicationWillTerminate` flushes (`main.swift:35`) but a plain `kill` bypasses it. Proven: with a 2 s sleep before the kill the 4e resume-off check passes. Real risk on crash or force-quit; add a SIGTERM handler that flushes, or shorten the window.
- **4e "a folder outside the chosen roots is never searched"**: the file is listed in the palette's recent "open" group (adad8a2), not by Spotlight; the script's `refuse` matches the name anywhere. Test drift.

Load (debug daemons, same script as measurements.json, one run each; old = committed numbers):
| | AC7 old | AC7 new | AC8 old | AC8 new |
|---|---|---|---|---|
| fps / tile | 99.9 | 90.9 (-9 %) | 97.5 | 98.9 |
| frame p95 ms | 2.9 | 2.3 | 5.0 | 4.4 |
| echo p50 / p95 ms | 6.8 / 11.4 | 7.7 / 14.8 (+13 / +30 %) | 9.6 / 13.5 | 9.4 / 15.1 (-2 / +12 %) |
| **switch p50 / p95 ms** | 8.6 / 16.8 | **27.4 / 40.7 (+219 %)** | 8.4 / 15.1 | **69.9 / 177 (+732 %)** |
| CPU app / muyad / ptyd % | 32.8 / 28.5 / 13.0 | 29.3 / 24.6 / 14.0 | 15.8 / 85.7 / 21.5 | 14.4 / 62.6 / 21.9 |
| app RSS peak MB | 130 | 137 | 148 | 144 |
| footprint app / muyad / ptyd MB | 196 / 135 / 29 | 214 / 139 / 29 | 224 / 523 / 108 | 228 / 521 / 108 |
GPU (system mean %) 40.1 -> 39.8 (AC7), 40.2 -> 39.0 (AC8). `muya-load` daemon only, 100 sessions: muyad 522 MB / 93 % CPU, ptyd 91 MB, echo p50 0.59 ms, tab switch p50 3.1 ms (unchanged: the slowdown is in the app, not the daemons).

Switch regression. A/B on AC8, pre-restyle app (eeec137) vs HEAD: switch p50 9.8 / 9.7 ms vs 47.5 / 54.3 ms (2 runs each). `git bisect` in a throwaway worktree (unbuildable commits skipped): **first bad = ea840d3 "WP2 agents panel, session header and composer"** (60 ms there, 12 ms at 60a05d2). Cause: a switch changes the selected row, `AgentsPanel.reload()` (`AgentsPanel.swift:130-146`, called from `refreshFrame`, `FrameWiring.swift:111`) sees a new signature (it contains `s === sel`) and removes and rebuilds every card, so cost grows with session count (100 sessions: +50 ms). Fix: update only the two affected cards, or use a reusable-row list. The fonts, 1.6x line height, 5 s stats timer and toasts are not the cause. The AC7 fps dip (-9 %) is within the noise seen here (one AC8 head run drew only 3.9 fps with the app at 0.8 % CPU, an unexplained stall that did not repeat).

Privacy: no real `/Users/<name>` path under native/ or docs/native (only synthetic `/Users/u`, `/Users/x`, `/Users/someone`, `/Users/Shared` and the leak gates in build.sh); `staunch` appears only in the bundle id `com.staunch.muya`, `st4unch` only as the public marketplace owner. OCR of all 278 screenshots added or changed since eeec137: 0 hits for username or e-mail, only synthetic paths (`/Users/someone/Projects/...`, `/Users/Shared/muya-faz4e-*`); two looked at by eye.

Not run: `native/tests/ac23.sh` (10-minute canary run).

## Needs the operator

| What | Why only the operator | Blocks |
|---|---|---|
| STTextView / GPL-3.0 licence decision + approval to fetch SwiftPM packages (STTextView, CodeEditTextView) | Licence change and external code | S7, AC13 |
| AC15 wording: accept the amended "no embedded browser" check | PRD owner decision; the literal check cannot pass on any AppKit app | AC15 |
| AC11 render sign-off (20 pairs vs Ghostty.app) | Visual judgement | AC11 |
| Touch ID unlock test (S6) | Needs a fingerprint and the real Keychain | S6, vault UI |
| Second macOS user: `spctl` (S2), clean-user update chain (AC17) | Needs a second account | S2, AC17, AC20 |
| Real IME press-and-hold + VoiceOver listening | Needs the display awake and the operator present | S3, AC10 |
| Developer ID signing + notarization of the native bundle | Real identity and notary credentials | AC20 |
| Sparkle EdDSA key (create, store the private key) | Secret that must be the operator's | S8, AC17 |
| Login Items approval and TCC prompts on a real session (S5, AC21) | System dialogs | S5, AC21 |
| 7-day dogfood | Calendar time | AC20 |
| History cleanup before any push (below) | Rewriting history needs approval; remote git is gated | push |

## History findings (git-verify, branch since main)

- Home path in history: commit d014331 (`docs/prd-native-rewrite.progress.md`, an inventory line); fixed in the working tree, still present in that commit. No other commit or file on the branch contains it.
- Screenshots (`native/app/screenshots/*.png`) added before the privacy fix 2b68b84 ("no longer show the owner of ls -l"): 2d4d271, 3f9ed60, e2bacd7, 2b71440. Later commits replaced them; the old blobs are still in history.
- Bundle id `com.staunch.muya` appears in docs; it is the product identifier, not a private path.
- Decision: if the branch is ever pushed, squash or filter these four commits plus d014331 first; nothing was rewritten here.

## ptyd flake + AC21 daemon side

- Flaky `late_attach_gets_ring_and_modes_after_bytes_scrolled_out`: root cause was the test, not the daemon. It waited for `end_seq >= 3_000_000`, but the program prints mode escapes + 3 MB + `DONE` as separate writes, so under load the late attach could land before `DONE` reached the ring and receive it live on top of the replay (+4 bytes in the length check). `Attach` (header + ring + subscribe under one lock) is correct. Reproduced 7 failures in ~200 runs under 12 CPU hogs x 8 parallel runners; after the fix (an early client waits for `DONE`, then the late attach) 200/200.
- AC21 daemon side: `muyad` no longer exits when ptyd is unreachable. It serves, links to ptyd lazily (`Muyad::offline` + `ensure_link`) and answers every request that needs ptyd with `ErrorCode::NotApproved` (no protocol change, the code existed). Once ptyd's socket answers, the next request links and re-adopts, same muyad process. Test: `crates/muyad/tests/ac21.rs`. Losing an established ptyd link still exits muyad (launchd restarts it and it re-adopts), unchanged.
- Also in ptyd: `spawn_session` now uses `ttyname_r` (the libc `ttyname` returns a pointer into one process-wide buffer; concurrent spawns are one thread per client). Hardening only: a test for it (`concurrent_spawns_each_get_their_own_tty`) did not fail before the change at a sane load (0/60), so this is not claimed as the cause of any flake. Test-load note: the machine has 511 ptys (`kern.tty.ptmx_max`) shared with every terminal; stress loops that open more than ~300 sessions fail with spawn errors that look like races.
- One unexplained single failure remains: `sessions_inherit_no_ptyd_sockets_under_concurrent_load` timed out once ("no reply", 10 s) in a full workspace run while other sessions were building; 30/30 under load afterwards, 3/3 workspace runs green.

## muyad Rpc: methods for the new app pages

- Added to `muyad` (`rpc.rs`, new `rpc_git.rs`): `migrate.run`, `agents.list`, `sessions.transcript`, `ssh.servers.*`, `ssh.psmp.*`, `cyberark.accounts.search`, `vault.status/list/unlock/add/update`, `workspace.set_roots`, `git.status/diff/worktrees/branches/log`, `plan.list/set_status`, `queue.run`. Tests in `native/crates/muyad/tests/rpc.rs`.
- Security decisions: `vault.unlock` and everything behind it answer the locked error (S6 undecided: a master password would cross the socket into a daemon with no idle-lock or Keychain gate); `queue.run` answers "not enabled in this build" (destructive). `cyberark.accounts.search` needs a logon, which needs a vault secret, so it answers the locked error.
- `git.*` / `plan.*` accept only folders inside the roots the app pushed with `workspace.set_roots`, the cwds of sessions the daemon spawned, or git worktrees of those (canonicalised, so `..` and symlinks cannot escape). Git runs with `GIT_OPTIONAL_LOCKS=0`, output capped (2 MiB), killed on cancel or after 20 s.
- Measured (`perf_git_log_with_parallel_search`, ignored test): 3 x `git.log(1000)` over a 5,000-commit repo took 0.45 s while `sessions.search` scanned 60 x 11 MB; muyad RSS 13.3 MB idle -> 17.0 MB, 1.05 s CPU in total, 0 afterwards.

## AC19 daemon side: protocol-incompatible update, "restart sessions now / later"

- Protocol minor 3 (`muya-proto`): `Error` gets an optional `detail` (`Incompat`: daemon / client / required / speak versions + live sessions with folder and Claude session id) on `Incompatible`; `Control::Upgrade` / `Control::Upgrading{plan, ptyd_restarting}`; `SessionInfo.cwd`. Plain errors keep their old JSON (no `detail` key); an old daemon's error without `detail` still parses.
- Decision for "later": the app reconnects with `Hello{major,minor} = Incompat::speak` (the daemon's own version). Safe because the daemon enforces the announced minor per connection (`min_minor`: detach 1, rpc 2, upgrade 3; above it -> `BadRequest`) and answers a message it cannot parse (a future type) with `BadRequest` instead of dropping the connection. The app limits itself to List/Attach/Key/Paste/Resize/Mouse/Close; a read-only list was not needed. Same mechanism between muyad and an older-major ptyd (`ensure_link` retries with ptyd's `speak`; shown by the `upgrade.status` rpc as `ptyd_compat`).
- "Now": app-only `Upgrade` -> muyad writes `resume-plan.json` (0600, next to the socket or `--state-dir`), ends the sessions (ptyd `Upgrade` if it is minor >= 3, else `Close` per session), answers `Upgrading`, both daemons exit 0 (launchd restarts them). New muyad serves `upgrade.resume_plan` / `upgrade.resume_done` / `upgrade.status` rpc. Claude ids: `claude agents --json` pid -> `getsid(pid)` == ptyd session leader.
- Tests: `muyad/tests/ac19.rs` (3, real binaries), `muya-ptyd/tests/ptyd.rs::version_skew_upgrade_and_minor_gating`, `muya-proto` N-1 matrix + wire shapes + fuzz seeds.

## AC12 daemon side: permission prompts with the UI closed

- `muyad::prompt_watch`: a screen-only sink on every session actor (installed by `Muyad::enable_prompt_watch`, called from `main.rs`; same `Cmd::Detach` path the app uses, key `usize::MAX`). It runs only when the already-parsed screen state *changes*, so no timer or polling; a pending auto-answer is one sleeping thread per prompt.
- No app attached (`apps` empty): new prompt -> notification at once (measured 117-141 ms after the screen was printed); with `autoApprove` true in the app's `prefs.json` (`~/Library/Application Support/MuyaNative`, read at decision time) the Allow key (option 1) is typed after 2 s, once per prompt (`answered` flag, re-checked after the sleep: app attached / setting off / prompt gone -> nothing). App attached: the daemon does neither (the app does both). Limit: a prompt already open when the app detaches is not picked up until the next screen change.
- Known layouts only: parser accepted the dialog (option 1 = Yes, last = No, keys 1..n), question starts with "Do you want to", tool in {Bash, Write, Edit, Read, Tool use}. Mutated corpus screens (No->Maybe, MCP title -> "Format disk", question reworded) are never answered.
- Notifier: `osascript display notification` (text passed as argv, not spliced), ~0.1 s, works from a LaunchAgent binary with an empty env on macOS 26. `UNUserNotificationCenter` needs a bundled app identity; a helper app inside Muya.app (own icon) is the upgrade path, not done here (outside this task's paths). No third-party tools.
- Tests `muyad/tests/ac12.rs` (5): corpus Bash/Edit/Write/MCP screens printed by a fake claude into a real PTY via ptyd: notified < 2 s, not answered before 2 s, answered exactly once, notified once; auto-allow off -> notify only; 3 unknown layouts -> silent; app attached -> silent; CPU with 25 idle sessions 0.229 % of a core without the watcher vs 0.221 % with it.

## Regression run 2 2026-11-06 (HEAD 0d48af3, clean worktree, wip/native-rewrite)

Unit suites: `cargo test --workspace --no-fail-fast` 507 passed, 0 failed, 20 ignored (twice, identical); `build.sh` 0 warnings; `build.sh test` 188 tests, 0 failures; `ac4-tools-list.sh` byte-identical (36262 bytes); src-tauri `cargo test --lib` 39 passed (3 ignored); `tsc --noEmit` clean; vitest 525 passed (70 files); `test-ghostty-env-lock.sh` ok. Built against a copy of the shared Ghostty cache (stub `ghostty-env.sh`), never the shared one.

Real-app scripts (sequential, own TMPDIRs, app rebuilt first):
| Script | Result |
|---|---|
| verify 6, files 36, queue 19, ssh 19, ac9 5/5 runs, ac10 9, ac19 20, ac21 11, p3 52, p4 53, p6 14, p7 14, p12 6, 4e 79, split 27, dividers (36 screens, no stray divider), inspector (screenshots), ghostty lock | PASS, 0 FAIL |
| verify-notify | 1 FAIL ("click selects session 1": the muya:// URL went elsewhere), PASS 15/15 on an immediate re-run: flaky |
| verify-terminal | 18 PASS, 1 FAIL: "six tiles: got 4" (grid default is 2x2 since c15fc45; test drift) |
| verify-pages | 88 PASS, 2 FAIL, 4 SKIP: "focus starts in the search box" and "tab moves focus to the list" (e9f47e2 deliberately stopped focusing the search field; test drift) |
| verify-ac26.py | 5 FAIL: 1 unlabelled AXTextField in grid view (new per-panel message field), Sessions keyboard x3 (same e9f47e2 focus change), Clean up dialog Esc check (698394e modal rewrite) |
| verify-p0 | 2 PASS, 2 FAIL, 6 GAP: key presses lost (p0 has no activation handling like p3's ensure_active); its inner verify-files fails on a fixed /tmp/muya-p0 path; verify-files itself 36/36 standalone |

Load (debug daemons, `measure-ac7.py`, one run each; AC7 with 4 visible tiles because the grid default changed):
| | AC7 old | AC7 new | AC8 old | AC8 new |
|---|---|---|---|---|
| fps / tile | 95.9 | 68.0 (4 tiles, 0.74 MB/s each) | 99.3 | 98.5 |
| frame p95 ms | 2.7 | 1.6 | 3.6 | 3.2 |
| echo p50 / p95 ms | 8.8 / 14.0 | n/a | 6.5 / 11.3 | 8.0 / 14.5 (+23 %) |
| switch p50 / p95 ms | 9.5 / 21.8 | 22.8 / 34.8 (+140 %) | 10.7 / 19.4 | **54.9 / 100.5 (+413 %, FAIL > 50)** |
| CPU app / muyad / ptyd % | 40.6 / 14.3 / 9.7 | 13.5 / 23.4 / 12.4 | 13.2 / 26.8 / 15.5 | 12.4 / 56.6 / 22.9 |
| RSS app MB (muyad / ptyd footprint) | 129 (140 / 30) | 124 (149 / 29) | 139 (526 / 110) | 121 (521 / 109) |

Switch regression: bisected (AC8 method, 100 sessions) between af8e824 and HEAD to 2479991 "composer Mode chip menu, esc hint, session-header collapse chevron" (good 630a7e9 13.6 ms, bad 2479991 51.2 ms, then stays ~51-55 ms). Files: SessionBar.swift / Composer.swift configure path on every selection.
Privacy: tracked files under native/ and docs/native contain no username (only gate scripts and placeholders /Users/u, /Users/x, /Users/someone, /Users/Shared); OCR of the 426 PNGs changed since eeec137: 0 real-name hits (23 hits are the mock paths /Users/someone/Projects/... and /Users/Shared/...).

## Regression run 3 2026-11-06 (HEAD f59b913, clean worktree)

Unit suites: `cargo test --workspace` 507 passed + 1 failed on the first pass (`muyad/tests/rpc.rs:97` `schedules_and_prefs_work_over_rpc`: the `UnixStream::connect(..).unwrap()` of a freshly started daemon, load average ~12), 508 passed / 0 failed / 20 ignored on the second: flaky under load. `build.sh` builds but prints 2 warnings (`Prefs.swift:94`, main-actor calls `layoutSubtreeIfNeeded` / `setPosition` in a nonisolated local func, from 835e75c); `build.sh test` 195 tests, 0 failures; `ac4-tools-list.sh` byte-identical; src-tauri lib 39 passed; tsc clean; vitest 525 passed; ghostty-lock test ok; muyad + ptyd release build ok.
Real-app scripts (one clean worktree, sequential): verify 6, terminal 20, files 36, queue 19, ssh 19, ac9 5/5, ac10 9, ac19 20, ac21 11, p0 7 (0 failures), p3 52, p6 14, p7 14, p12 6, pages 89, 4e 79, split 27, notify 16, switch-guard ok (0 rebuilds), toast-lift ok, dividers (36 screens, no stray divider), term-features 17 ok (re-run alone), inspector (screenshots), ac26 PASS: all 0 FAIL. verify-p4: 49 PASS / 4 FAIL (inspector restore, see below).
Failures: (1) verify-p4 "inspector width [0]" x2, "inspectorOpen false: got true", "inspector open: got hidden": introduced by 835e75c (Prefs.swift auto-open / narrow auto-hide of the inspector by window width, usePanelLayout rule): the script's window is narrower than 1280 so a stored open inspector is hidden; script expectation or product rule needs a decision. (2) verify-term-features failed only in the sequence ("run-dev: already running"): it keeps its state file in /tmp by default, so it collides with any other running dev stack; passes with its own TMPDIR (17 ok). (3) build warnings above. (4) cargo rpc.rs:97 flake.
Load (6-tile AC7, 100-session AC8; run 2 numbers in the section above, old = committed earlier numbers): release daemons AC8 muyad 24.7 % (debug 52.8 %: the 'doubling' of run 2 was the daemon build), switch p50 11.2-11.9 ms (old 10.7: +5-11 %), echo within noise, fps 99+; AC7 switch p50 11.2-11.6 (old 9.5: +18-22 %, p95 17.9-20.0 vs 21.8 better), fps 92-98 (old 95.9).

## Regression run 4 2026-11-11 (HEAD 7cf2463, clean worktree, release daemons for load)

Suites: `cargo test --workspace` 506 passed / 2 failed / 20 ignored on the first pass: both failures are `muyad/tests/broker.rs:53` "building the sidecar failed ... resource path `binaries/muya-ssh-mcp-aarch64-apple-darwin` doesn't exist" (the untracked prebuilt sidecar is not in a fresh worktree, a harness gap, not product code); with `src-tauri/binaries` copied in, `--test broker` passes. `build.sh` 0 warnings, `build.sh test` 195 tests / 0 failures, muyad + ptyd release build ok.
Real-app scripts, every `verify*.sh` once on its own TMPDIR (28 scripts + ac26): first pass green: 4e 79, ac10 10, ac21 11, ac9 5/5 (p50 315 ms), ac26 PASS (35 surfaces, 526 controls, 0 unlabelled), dividers, files 40, inspector, queue 19, split 27, ssh 19, switch-guard (0 rebuilds), term-features 17, terminal 20, toast-lift 4, verify 6. A block in the middle of the sequence failed with "app did not come up" / empty debug replies (ac19, notify, p0, p12, p3, p4, p6, p7, pages): the dev app hung at launch (macOS window-state restore) and left stacks behind. Re-run once each: ac19 20/0, notify 16/0, p0 7/0, p12 6/0, p4 57/0, p6 14/0, p7 14/0, pages 95/0 all PASS. verify-p3 failed twice with 31-33 FAIL on the real CGEvent path ("key path: CGEvent to the active app", 3-4 other MuyaNative instances running, my own leaked stacks among them) and passed 52/0 on the third run after those stacks were stopped (in-process key path): a focus/other-instance flake, not a product failure.
Load, RELEASE daemons, load average 2-4: AC7 (25 sessions, 6 tiles, 3x2) fps 60.0 (pinned; was 98.1 in run 3), frame p95 0.15 ms, echo p50 8.7-9.2 / p95 13.9, switch p50 14.9-18.1 / p95 23, CPU app 22.6-24.5 / muyad 14.4-15.2 / ptyd 9.1 %, app RSS 148-154 MB; AC8 (100 sessions) fps 59.7-60.0, echo p50 7.9-8.5 / p95 10.3-11.5, switch p50 6.4-7.4 / p95 21, CPU app 6 / muyad 22.2-22.4 / ptyd 15.6-16.1 %, muyad 520 MB, ptyd 109 MB, app RSS 205 MB. Flags: fps is exactly 60 in every run although `system_profiler` reports the display at 100 Hz (run 3 and earlier: 92-99 fps); `displaySyncEnabled` and the draw loop are unchanged since 11-03, so this looks like the compositor / display mode of the machine, to be re-checked on a normal display session; AC7 switch p50 is +30-60 % over run 3 (11.2) while AC8 switch is better (6.4-7.4 vs 11.7); AC8 app RSS 205 MB vs 138-159 (run 3).

## Regression run 5 (final) 2026-11-11 (HEAD 2223206, re-checked on af0a875)

Suites: `cargo test --workspace` 514 passed / 0 failed / 20 ignored (sidecar binary copied into the worktree: the 2 broker.rs:53 failures of run 4 are gone). `build.sh` 0 warnings, `build.sh test` 196 tests / 0 failures. Release build (`MUYA_RELEASE=1`): 0 `DebugServer` symbols (`nm`), the app launches and stays up.
Real-app scripts (each on its own TMPDIR, 0 leftover processes after every script): 4e 78 PASS / 1 FAIL, ac10 10/0, ac19 20/0, ac21 11/0, ac9 5/5, ac26 PASS (35 surfaces, 0 unlabelled), dividers, files 40, inspector, notify 16, p0 7, p12 6, p4 57, p6 14, p7 14, pages 89, queue 19, split 27, ssh 19, switch-guard (0 rebuilds), term-features 17, terminal 20, toast-lift 4, verify 6/0. verify-p3: needs an idle machine (real key events to the active app; failed 32/33 times on an unlocked screen with the operator's app in front; last good result 52/0 in run 4).
Failures: (1) verify-4e 57 + verify-ac26 32 FAIL on 2223206: `SessionsPage.debugState()` (SessionsPage.swift:569-570, `n.group!`) trapped on the clean-up banner row added in 5b4742f (test hook only); fixed in af0a875, both re-run green except (2). (2) verify-4e "the pref is stored" (`openAtLogin` not yet in prefs.json when read right after `settings-set`): repeatable (3 runs) on 2223206/af0a875, passes with a 2 s wait; prefs are now written through SecureFile (a7f6e1e), so the write lands later than the script reads: script/race, not yet fixed.
Load, RELEASE daemons, screen unlocked, load avg 2-3: AC7 (6 tiles 3x2) fps 91.3, frame p95 0.22 ms, echo p50 5.9 / p95 9.0, switch p50 13.3 / p95 18.0, CPU app 30.4 / muyad 17.2 / ptyd 9.6 %, app RSS 159 MB; AC8 (100 sessions) fps 99.9-100.0, echo p50 6.1-9.8 / p95 7.6-12.2, switch p50 11.3-15.0 / p95 13.6-17.2, CPU app 12 / muyad 28.3-28.8 / ptyd 19.4-19.5 %, muyad 520 MB, ptyd 109 MB, app RSS 208 MB. The 60 fps cap of run 4 was the locked screen. vs run 3 (release): fps equal, echo equal, AC8 switch +0-25 % (11.7-11.9 before), AC7 switch +19 %, muyad CPU +15 % (24.7 -> 28.5), app RSS +50 MB at AC8 (158 -> 208).
Glyph test pattern (box, blocks, braille, powerline) in the real app, dark: renders without missing glyphs, but the box-drawing rows look doubled/merged in height (line height 1.6 stretches vertical strokes) and the bottom corners (└ ┴ ┘ ╰ ╯) are hard to tell apart: worth a look by the operator (screenshot /tmp/muya-regr5/glyphs-dark.png, not committed).


## Perf A/B (f59b913 vs b35f9b1) 2026-11-11

AC8 (100 sessions, release daemons, 2 runs each, same machine, back to back):

| | muyad CPU % | ptyd CPU % | app RSS MB | switch p50 / p95 ms | echo p50 ms | fps |
|---|---|---|---|---|---|---|
| f59b913 (run 3) | 41.9 / 42.7 | 28.4 / 28.6 | 202 / 207 | 12.1 / 17.7, 12.7 / 17.4 | 9.8 / 10.2 | 100 |
| b35f9b1 (HEAD) | 43.9 / 43.4 | 28.5 / 28.2 | 210 / 206 | 12.3 / 15.8, 12.3 / 17.0 | 8.2 / 9.4 | 100 |

Conclusion: no code regression between the two commits (muyad per-client write queue, glyph atlas and SecureFile prefs cost nothing measurable). The run-3 absolute numbers (muyad 24.7 %, app RSS 158 MB) do not reproduce with the same f59b913 binary today (42 %, 205 MB; ptyd 15 -> 28 % too), so absolute numbers depend on machine state. The screen was reported locked during this A/B, so switch times are relative only.
