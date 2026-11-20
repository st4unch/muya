# Terminal emulation + GPU rendering for native Muya (research, 2026-11-03)

Need: 7-25+ concurrent Claude Code TUIs (truecolor, alt screen, mouse, OSC 8, Kitty keyboard), Rust backend, fully native UI.
Items marked (UNVERIFIED) were not confirmed from a primary source in this pass. No benchmark numbers for memory-per-terminal were found in any source; measure ourselves.

## 1. libghostty / libghostty-vt (Ghostty)

What exists today
- Ghostty latest git tag: v1.4.0 (tags v1.2.x, v1.3.x before it). https://github.com/ghostty-org/ghostty/tags (release date not checked).
- README: "libghostty is a cross-platform, zero-dependency C and Zig library for building terminal emulators". https://github.com/ghostty-org/ghostty
- Only libghostty-vt is shipped as a public library. Docs: https://libghostty.tip.ghostty.org/ . It does parsing, terminal state, scrollback, reflow on resize, key/mouse/focus encoding, paste, OSC/SGR parsers, search, formatter (text/VT/HTML), snapshot/restore, and a Render State API "for custom renderers", plus idle scrollback compression example.
- Official warning on the same page: "API is not yet stable. Breaking changes are expected... Use with caution in production code."
- No renderer, no PTY, no windowing in libghostty-vt. Ghostling (official demo, single C file, Raylib): https://github.com/ghostty-org/ghostling . It lists: 24-bit/256 color, Kitty keyboard protocol, Kitty graphics, mouse tracking (X10/normal/button/any, SGR/URxvt/UTF8), focus reports, reflow, scrollbar. It says it is a demo, not daily-use.
- Mitchell Hashimoto announcement: SIMD parser, fuzzed + Valgrind-tested, Kitty graphics, tmux control mode, "zero dependencies, not even libc". https://mitchellh.com/writing/libghostty-is-coming
- Ghostty README claims perf in the same class as Alacritty (within few percent), ~100x Terminal.app/iTerm on its benchmarks (vendor claim, not independent). Multi-threaded: read/write/render thread per terminal; Metal on macOS, CoreText font discovery.

Rust crates (crates.io, checked today)
- libghostty-vt 0.2.2 (2026-09-28), ~190k downloads; libghostty-vt-sys 0.2.2, ~83k. Repo https://github.com/uzaaft/libghostty-rs (MIT, pushed 2026-10-30, 403 stars). Active, de-facto Rust binding.
- Alternatives: ghostty-vt 0.8.0+ghostty.1.4.0 (2026-10-28, built from official source tarball), ghostty-vt-rs-sys 0.2.0 (prebuilt static libs), mnml-libghostty-vt, khostty-vt. Low download counts; several competing bindings = ecosystem not settled.
- gpui-libghostty 0.4.1-rc.1 (2026-11-02): "native libghostty terminal component for GPUI", macOS + Linux, needs Zig 0.17 and Xcode CLT. https://github.com/behzade/gpui-libghostty . Small project (909 downloads). Shows the pattern libghostty-vt + own GPU UI works in Rust.

Full-surface embedding (renderer + PTY) = GhosttyKit
- include/ghostty.h comment: "Ghostty's internal embedder API, a.k.a. libghostty-internal. The only consumer of this API is the macOS app... tailored to the needs of the macOS app and not designed for external use, hence why most functions are undocumented". https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h
- So embedding GhosttyKit's full Surface (Metal renderer + PTY) is technically possible (several third-party apps do it: manaflow-ai/cmux, cad0p/vvterm, Devora issue #221 discussing "internal API vs libghostty-vt decision") but it is unsupported, undocumented, and they keep forks/patch queues (vvterm issue #127 "upstream + patch-queue + weekly auto-merge probe"). Needs Zig toolchain to build the xcframework.
- License: Ghostty is MIT (from memory; license field not printed in this pass - UNVERIFIED but widely known).
- JetBrains adoption (UNVERIFIED): not found in this pass; do not rely on it.

Embeddability
- (a) Swift/AppKit: C API is easy to import; you write the Metal view yourself (libghostty-vt gives Render State, you draw). Or take GhosttyKit (unsupported).
- (b) Rust GPU UI: good - Rust bindings exist and are maintained; you draw with wgpu/Metal yourself.
Risks: API unstable; renderer is yours to build (font shaping, ligatures, selection, IME, scrollbar); Zig build dependency; Zig version churn (gpui-libghostty already needs Zig 0.17).

## 2. alacritty_terminal (used by Zed)
- crates.io: 0.26.0 released 2026-04-06; 0.25.1 Oct 2025; 0.25.0 Feb 2025; ~2.4M downloads; Apache-2.0. https://crates.io/crates/alacritty_terminal
- Contains grid, ANSI/VT parser (via vte), selection, PTY event loop (tty module), scrollback. No renderer. API is explicitly "for Alacritty's needs", semver-unstable between releases.
- Zed's `terminal` crate depends on alacritty_terminal + gpui; Zed's crate itself is GPL-3.0-or-later so you can copy nothing of it into a closed app. https://github.com/zed-industries/zed/blob/main/crates/terminal/Cargo.toml . terminal_view draws cells with GPUI.
- Emulation gaps (from general knowledge, UNVERIFIED for 0.26): Kitty keyboard protocol was added in Alacritty 0.13; no Kitty graphics, no Sixel; reflow on resize yes; OSC 8 yes.
- Perf: Alacritty is the speed reference (Ghostty README states parity). Memory: grid stores cells (~24 B? UNVERIFIED) x scrollback; no compression.
- Embeddability: pure Rust, trivial for (b); for (a) you would need FFI shim - not natural.
- Risk: moderate release cadence (2 releases/yr), single-purpose maintainers, no render-state API for incremental damage beyond its own `damage()`.

## 3. wezterm-term / termwiz
- wezterm-term is NOT published on crates.io (git dependency only; crates.io query returned nothing). termwiz 0.23.3 last published 2025-03-20 (crates.io API). 
- wezterm repo: pushed 2026-10-26 (active commits), but last tagged release is 20240203-110809-5046fc22 (Feb 2024). License reported by GitHub as "other/NOASSERTION" (MIT-style, verify before use). https://github.com/wezterm/wezterm
- Emulation: very complete (Kitty keyboard, Kitty/iTerm2/Sixel graphics, OSC 8, etc.) - from docs, UNVERIFIED in this pass. Renderer not included (wezterm's own is wgpu/OpenGL in the GUI crate, not reusable).
- Risk: git-only dependency, stale releases, tightly coupled to wezterm workspace. Lower priority.

## 4. SwiftTerm (Miguel de Icaza)
- MIT, 1.75k stars, pushed 2026-11-02, releases v1.99.0 (2026-10-08), 1.99.1, 1.99.2 (2026-10-29): 2.0 line in prerelease. https://github.com/migueldeicaza/SwiftTerm
- Features (README): VT100/xterm, 256/truecolor, mouse, OSC 8 hyperlinks, selection, search, bidi, Sixel + iTerm2 + Kitty graphics, thread-safe Terminal, "Optional GPU-accelerated rendering via Metal (macOS, iOS, visionOS)". Kitty keyboard protocol: not listed in README (UNVERIFIED).
- Adopters: Secure Shellfish, La Terminal, CodeEdit (commercial SSH clients).
- Perf: has vtebench-based benchmark suite (PERFORMANCE.md, Tools/SwiftTermBenchmarks) but no published numbers found. Metal path is young: open PRs "Metal: keep row cache across scrolls" (#636), "Retry frames refused by Metal renderer" (#642); closed issue #658 "High main-thread CPU with multiple streaming TUI terminals: glyph metrics dominate Metal draw" and #738 "Metal renderer hot paths while a TUI redraws". Exactly our workload (many streaming TUIs) - main-thread cost was a real problem and is being fixed.
- Embeddability: (a) Swift/AppKit: native, drop-in NSView. (b) Rust: no (Swift only).
- Risk: AppKit view is main-thread bound; Swift-only; emulation less battle-tested than Ghostty/Alacritty for edge cases though it uses esctest and Ghostty tests.

## 5. Others
- Rio: sugarloaf 0.5.29 (2026-11-01) is a wgpu/Metal text renderer crate usable standalone; rio-backend was not found by name on crates.io in this pass (UNVERIFIED). Rio backend is itself derived from alacritty_terminal. https://github.com/raphamorim/rio . Rio is a possible renderer reference.
- vt100 crate: 0.18.1 (2026-10-19). Small, pure Rust screen-state parser, no scrollback beyond simple, no Kitty protocols - fine for headless screen scraping (e.g. read_session), not for a rich UI.
- vte: parser only (used by alacritty).

## Comparison

| | Emulation | Renderer incl. | Rust embed | Swift embed | License | Last release | Stability |
|---|---|---|---|---|---|---|---|
| libghostty-vt | best (Kitty kb+gfx, reflow, SIMD) | no (render-state API) | yes, 3+ bindings | yes (C) | MIT (UNVERIFIED) | active, Rust 0.2.2 Sep 2026 | API unstable (official warning) |
| GhosttyKit full | best | Metal | via C | yes | MIT | tied to Ghostty 1.4.0 | internal, unsupported |
| alacritty_terminal | good, no graphics | no | yes (native) | awkward | Apache-2.0 | 0.26.0 Apr 2026 | semver-unstable but proven (Zed) |
| wezterm-term | very good | no | git only | no | MIT-ish | stale tags | poor packaging |
| SwiftTerm | good, graphics yes | Metal optional | no | yes (native view) | MIT | 1.99.2 Oct 2026 | 2.0 in flux, Metal perf bugs |
| vt100 | basic | no | yes | no | MIT | Oct 2026 | simple |

## Ranked recommendation (many concurrent terminals, best quality + speed, Rust backend)

1. libghostty-vt (via libghostty-vt Rust crate) + own Metal/wgpu renderer. Best emulation fidelity for Claude Code TUIs (Kitty keyboard, reflow, fast parser), one headless terminal state per session fits Rust backend threads, render-state API gives dirty-row data, scrollback compression exists. Pin an exact Ghostty commit.
2. alacritty_terminal + own renderer. Safest, boring, Apache-2.0, proven in Zed with many terminals; less rich (no graphics) and you own the render work as well.
3. SwiftTerm (Metal view). Fastest route to a working AppKit UI, but multi-TUI main-thread cost is a documented issue; fine as a fallback if the UI layer is Swift.
4. GhosttyKit full surface: best result visually for free, but unsupported internal API; only if willing to maintain a fork.
5. wezterm-term, vt100: not recommended for UI (vt100 ok for headless scraping).

Top 3 risks of the winner (libghostty-vt)
1. Unstable C/Rust API: breaking changes expected; multiple competing Rust bindings. Mitigate: pin Ghostty commit, wrap behind our own trait so alacritty_terminal can be swapped in.
2. We must build the renderer ourselves: glyph atlas, CoreText shaping, wide/emoji, selection, IME, cursor, scrollbar, OSC 8 hit-testing. Ghostty's own renderer is not reusable. Largest schedule cost; GPU cost with 25 live terminals needs damage-based redraw and hidden-tab throttling.
3. Zig toolchain in the build (version churn, e.g. Zig 0.17 in gpui-libghostty) and macOS packaging/notarization of the static lib; also memory per terminal with 5-10k scrollback is unmeasured (UNVERIFIED) - benchmark 25 sessions early.

Sources (consolidated)
- https://github.com/ghostty-org/ghostty , https://libghostty.tip.ghostty.org/ , https://mitchellh.com/writing/libghostty-is-coming , https://github.com/ghostty-org/ghostling
- https://github.com/uzaaft/libghostty-rs , https://crates.io/crates/libghostty-vt , https://github.com/behzade/gpui-libghostty
- https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h , https://github.com/manaflow-ai/cmux , https://github.com/cad0p/vvterm/issues/127
- https://crates.io/crates/alacritty_terminal , https://github.com/zed-industries/zed/tree/main/crates/terminal
- https://github.com/wezterm/wezterm , https://crates.io/crates/termwiz
- https://github.com/migueldeicaza/SwiftTerm (README, PERFORMANCE.md, issues #658, #738, PR #636, #642)
- https://github.com/raphamorim/rio , https://crates.io/crates/sugarloaf , https://crates.io/crates/vt100
