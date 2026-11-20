# Muya native rewrite: UI framework research

Date: 2026-11-03. Method: web search/extract only, no code changes. Items marked **[UNVERIFIED]** rest on a single source, a vendor's own claim, or my background knowledge and were not confirmed in this session.

Context: Muya = many Claude Code PTY terminal sessions + code editor + file tree + git changes + settings + kanban + schedules; menu-bar tray; auto-updater; Developer-ID signed and notarized, shipped outside the App Store. Keep the Rust backend (PTY, MCP broker over a unix socket, encrypted vault with Touch ID, SSH, schedules). The operator types Turkish, so IME and accent input are a hard requirement.

---

## 1. UI framework options

### 1a. Swift + AppKit/SwiftUI, Rust core behind UniFFI / swift-bridge / C ABI

**Terminal hosting.** The strongest evidence in this whole report. Ghostty's macOS app is Swift (AppKit + SwiftUI) over a Zig core (`libghostty`) with a Metal renderer and CoreText fonts ([ghostty.org/docs/about](https://ghostty.org/docs/about), [github.com/ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)). Independent embedders already ship:
- Calyx: native macOS terminal for supervising parallel coding agents (Claude Code and Codex approval inbox, agent sidebar), Swift 6.2, 103 releases in 6 months, all on libghostty. Write-up with the practical gotchas: [dev.to/yuu1ch13](https://dev.to/yuu1ch13/what-it-takes-to-embed-libghostty-in-a-swift-app-six-months-of-lessons-1m64). Gotchas: build with `-Doptimize=ReleaseFast` (debug build rendered much slower); the engine makes its own Metal device and your `CAMetalLayer` only supplies the drawable; bundle `terminfo` and `shell-integration` dirs or set `GHOSTTY_RESOURCES_DIR`.
- `Lakr233/libghostty-spm`: SwiftPM wrapper `GhosttyKit` / `GhosttyTerminal` ([swiftpackageregistry.com](https://swiftpackageregistry.com/Lakr233/libghostty-spm)). App-runtime disabled so the host app supplies its own.
- Caveat from the author: the current C header is "internal-only... not a good C API", used by commercial products but not yet a stable public API; the clean library plan starts with `libghostty-vt` ([mitchellh.com/writing/libghostty-is-coming](https://mitchellh.com/writing/libghostty-is-coming), Sep 2025). Expect API churn; pin a commit.
- Alternative: keep Muya's own Rust PTY and a Swift-side terminal view. SwiftTerm is the other Swift option **[UNVERIFIED, not researched this session; not GPU/Metal-first]**.

**Rust core bridge.**
- UniFFI (Mozilla): async via `#[uniffi::export(async_runtime = "tokio")]`; an adopter notes 0.32 wires Swift `Task` cancellation to `rust_future_cancel` ([uniffi-rs issue #2633](https://github.com/mozilla/uniffi-rs/issues/2633), a design-note quote inside that thread; treat as second-hand). `uniffi-bindgen-swift` generates headers, modulemap and Swift sources, with XCFramework-compatible output ([UniFFI guide](https://mozilla.github.io/uniffi-rs/next/swift/uniffi-bindgen-swift.html)). Callback interfaces / trait objects let Rust push events to Swift (needed for PTY output streams and vault-lock events).
- Weak points, from practitioners: XCFramework assembly is "fragile... missing any step results in hard-to-debug errors" ([substack walkthrough](https://mobilesystemdesign.substack.com/p/multiplatform-with-rust-on-ios-2c4)); "not a click-and-it-works setup" ([Swift Forums, Automerge-swift](https://forums.swift.org/t/the-state-of-swift-rust-interoperability/72205)). Ferrostar documents a working `uniffi-bindgen-swift` + XCFramework script ([Stadia Maps](https://stadiamaps.com/blog/ferrostar-building-a-cross-platform-navigation-sdk-in-rust-part-2)).
- Shipping adopters: Radix (Sargon), Automerge-swift, Ferrostar (all Swift Forums / Stadia threads above). 1Password runs a shared Rust core with native Swift/SwiftUI frontends over FFI and open-sourced Typeshare for the type sync ([1Password 8 story](https://1password.com/blog/1password-8-the-story-so-far), [Typeshare](https://1password.com/blog/typeshare-for-rust)). Mozilla ships UniFFI in Firefox mobile **[UNVERIFIED this session, widely known]**.
- Muya-specific: the MCP broker runs over a unix socket, so the sidecar and agents do not need FFI at all. Only the UI-to-core surface does. A pragmatic split is a small UniFFI surface (commands + event streams) while the broker stays an independent Rust process. Alternative: have the Swift app talk to a Rust daemon over the same unix socket (zero FFI, but second process to sign and supervise).
- `cargo-swift`, `swift-bridge` were not evaluated in depth **[UNVERIFIED]**. UniFFI has the largest user base.

**Maturity verdict:** high. Best IME/VoiceOver/menu/tray/DnD story because it is the platform's own stack.

### 1b. GPUI (Zed's UI framework) outside Zed

Facts found:
- Zed 1.0 shipped 2026-04-29 ([discussion #55271](https://github.com/zed-industries/zed/discussions/55271)).
- **GPUI is not usable from crates.io in 2026.** `gpui_macros`, `gpui_shared_string`, `gpui_util` have `publish = false`, so `cargo publish -p gpui` fails; `gpui-component 0.5.1` (2026-02-05) was the last crates.io release and later versions depend on `gpui` via git (same discussion, comments through 2026-08-20). The gpui.rs site itself says "For the near future, GPUI is tied to Zed" ([gpui.rs](https://gpui.rs)). A git dependency on Zed's monorepo is the only official route.
- Zed paused non-Zed GPUI work: "GPUI development is getting some major brakes put on it... pushing off anything that isn't directly related to Zed's use case" ([HN 47003569](https://news.ycombinator.com/item?id=47003569), quoting a Zed maintainer).
- Community forks exist: gpui-ce ([github.com/gpui-ce/gpui-ce](https://github.com/gpui-ce/gpui-ce), 1.4k stars, "mostly API compatible, but that is changing"), Kael, and unofficial crates.io re-publishes such as `gpui-platform-gpui-unofficial` (versions up to 1.27.0-pre, Oct 2026) ([lib.rs](https://lib.rs/crates/gpui-platform-gpui-unofficial)). A third-party-republished UI core for a security-sensitive app is a supply-chain concern.
- Longbridge's `gpui-component` has become "GPUI Kit" (`gpui-kit = "0.8.1"`, 75+ components, 18.7k stars, Apache-2.0, macOS/Windows/Linux/wasm): dock layout, virtual tables, code editor claimed stable at 200K lines with Tree-sitter highlighting and LSP, AccessKit roles built in ([github.com/longbridge/gpui-kit](https://github.com/longbridge/gpui-kit), [gpui-kit.com](https://gpui-kit.com)). **All feature claims are the vendor's own [UNVERIFIED].**
- Accessibility history: Zed was "opaque to screen readers" (HN comment, 2025); a 2025 article reports real-world screen-reader opacity for gpui-component despite ARIA docs ([BigGo](https://finance.biggo.com/news/202510280117_GPUI_Component_Rust_UI_Framework), [HN 45719004](https://news.ycombinator.com/item?id=45719004)). GPUI Kit's AccessKit integration is newer; I found no independent VoiceOver test **[UNVERIFIED]**.
- IME / Turkish press-and-hold in GPUI: **no usable evidence found** (search returned nothing relevant). Zed implements NSTextInputClient-style input on its own editor, but quality for generic GPUI text fields (settings, search boxes) is unproven **[UNVERIFIED]**. This must be spiked, not assumed.
- Terminal: Zed's terminal is alacritty_terminal rendered with GPUI, so GPU terminals are doable but we would own everything (selection, scrollback, links) **[UNVERIFIED: from background knowledge]**. Muya's current xterm-style behavior would have to be rebuilt.
- Positive: a Sparkle bridge crate (`sparkle-updater`) already advertises direct GPUI use ([tauri-plugin-sparkle-updater README](https://github.com/ahonn/tauri-plugin-sparkle-updater)).

**Maturity verdict:** best Rust-only performance story and a single-language codebase, but unpublished upstream, solo-fork risk, and unknown IME/a11y. Highest ecosystem risk of all options.

### 1c. egui, iced, Slint, Xilem/Masonry, Dioxus-native (Blitz)

From the 2026 hands-on survey ([blog.wybxc.cc/blog/rust-gui-survey-2026](https://blog.wybxc.cc/blog/rust-gui-survey-2026)) tested on macOS, corroborated where noted:

| Toolkit | IME | Screen reader | Notes |
|---|---|---|---|
| egui | works (survey tested macOS) | works; AccessKit on macOS enabled by default in eframe ([egui README](https://github.com/emilk/egui)) | immediate mode, no native menus out of the box, one-window-centric; good for tools, poor for docked pro IDE UX |
| Slint | works | works (AccessKit) | declarative DSL, native macOS menu bar via muda (1.17 changelog, [CHANGELOG](https://github.com/slint-ui/slint/blob/master/CHANGELOG.md)), SystemTrayIcon added in 1.17 ([extenly, Jul 2026](https://extenly.com/2026/07/09/slint-1-17-whats-new-in-the-modern-ui-toolkit)); licensing: GPLv3 / royalty-free / commercial, check terms for a closed-source app ([Rust forum](https://users.rust-lang.org/t/which-gui-framwork-should-i-choose/137581)). No code-editor widget or terminal widget |
| iced | works | screen reader cannot see window content | fails a11y |
| Xilem / Masonry | works (survey: both IME and a11y fine for Masonry) | works | project calls itself "alpha" ([docs.rs/xilem](https://docs.rs/xilem/latest/xilem)); text-input font fallback gap noted |
| Dioxus-native (Blitz) | not verified | `accessibility` feature flag exists ([lib.rs](https://lib.rs/crates/dioxus-native)) | experimental; 0.8.0-alpha in Jul 2026 |

Survey headline: only slint and egui have "solid support for IME and accessibility"; one earlier survey said 94% of 43 libraries are not production ready ([Rust Bytes](https://weeklyrust.substack.com/p/the-state-of-rust-gui-the-good-and)). None of these has a code-editor or terminal widget; all would need custom views for Muya's core surfaces. AccessKit's macOS adapter handles single- and multi-line text input but "not rich text or hypertext" ([AccessKit README](https://github.com/AccessKit/accesskit)), which matters for editor and terminal accessibility.

**Verdict:** egui and Slint are credible for tool-style UIs; neither fits a docked, multi-pane IDE-like app with a terminal and code editor without large custom work. iced, Xilem, Blitz are not ready.

---

## 2. Code editor replacing Monaco

**Swift route**
- **STTextView** (TextKit 2, NSTextView replacement, gutter with line numbers, 1.6k stars, v2.4.1, actively released) ([github.com/krzyzanowskim/STTextView](https://github.com/krzyzanowskim/STTextView), [SPI](https://swiftpackageindex.com/krzyzanowskim/STTextView)). Built for the author's Swift Studio. The author's own post warns TextKit 2 is "fragile" in edge cases ([blog.krzyzanowskim.com](https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land)). Inherits full NSTextInputClient, so Turkish/dead-key/press-and-hold behave like native macOS. Apple's WWDC26 "Elevate your app's text experience with TextKit" now makes `NSTextView`/`UITextView` conform to `NSTextViewportLayoutControllerDelegate` and demonstrates a code-editor-with-line-numbers pattern ([session 370](https://developer.apple.com/videos/play/wwdc2026/370)). This is a tailwind for building a custom editor on stock text views.
- **CodeEditSourceEditor** (tree-sitter highlighting, minimap, bracket matching, find/replace, inline messages) but its README says "currently in development and not ready for production use" ([github.com/CodeEditApp/CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor)). Check whether that notice is still current before ruling it out **[UNVERIFIED]**.
- **Runestone** (tree-sitter, handles huge files, strong reviews) is an iOS/UIKit text editor ([App Store listing](https://apps.apple.com/us/app/runestone-text-editor/id1548193893)); I believe it does not support macOS **[UNVERIFIED]**.
- Tree-sitter: C library, incremental, error tolerant, 20K-line JS file parsed in ~69 ms (Max Brunsfeld talk, [YouTube](https://www.youtube.com/watch?v=a1rC79DHpmY)). Highlight queries/grammars can be reused from the Rust side.
- **Diff view:** none of these ship one. Plan a custom two-column/inline diff view (NSTextView/STTextView read-only with attributed backgrounds) fed by libgit2 hunks from the Rust core.

**GPUI route**
- Zed's editor crate is not a reusable published component (it is inside the Zed monorepo, tied to its project/workspace model) **[UNVERIFIED: background knowledge, not checked in this session]**.
- GPUI Kit's editor: rope-backed, tree-sitter, LSP, claimed stable to 200K lines ([gpui-kit.com](https://gpui-kit.com), vendor claim **[UNVERIFIED]**). IME inside this custom editor is the open question.

**Other**: Monaco-in-WKWebView remains an escape hatch (keeps web code, but contradicts the "fully native" goal and keeps WebKit CPU/RAM cost; the project already removed the rail panda for ~30-35% CPU in WebKit).

**Verdict:** Swift + STTextView + tree-sitter is the lowest-risk native editor path. Budget real work for find bar, folding, minimap, and diff view regardless of option.

---

## 3. Auto-update outside the App Store

- **Sparkle 2** is the de facto standard: EdDSA (ed25519) signatures for archives, deltas and pkgs; delta updates via `BinaryDelta`/`generate_appcast`; requires HTTPS; recommends notarized Developer ID builds ([Sparkle docs](https://sparkle-project.org/documentation)). Key-rotation rules and security history: [Sparkle security doc](https://sparkle-project.org/documentation/security-and-reliability). Recent releases (2.9.x) include delta fixes for macOS 27, min target macOS 12, CocoaPods removed, and security fixes ([Sparkle releases](https://github.com/sparkle-project/sparkle/releases)).
- Signing gotchas: sign nested XPC services, `Autoupdate`, `Updater.app` inside-out with `-o runtime`, do not use `--deep` for the final app, and preserve entitlements for `Downloader.xpc` on 2.6+ ([Peter Steinberger, 2025](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)); older but consistent: [furbo.org](https://furbo.org/2019/08/16/catalina-app-notarization-and-sparkle). Appcast can be hosted on any static host or an update service ([FaynoSync](https://faynosync.com/docs/updaters/sparkle)).
- **Rust hosts:** `tauri-plugin-sparkle-updater` ships a standalone `sparkle-updater` Rust library with main-thread ownership, typed events and Gentle Reminders hooks "to use directly from GPUI or another native Rust host" (Sparkle 2.9.6) ([README](https://github.com/ahonn/tauri-plugin-sparkle-updater)). The Tauri updater (minisign-style signing, JSON manifest) is Tauri-only ([Tauri v2 docs](https://v2.tauri.app/plugin/updater)). No mature Rust-native updater with delta + sandbox-safe installer was found; Sparkle via bindings is the answer for any option.
- **Notarization with embedded Rust code:** a Rust staticlib linked into the main binary adds nothing special (one Mach-O). A `.dylib` or `.framework` embedded in `Contents/Frameworks` must be individually signed with the same Developer ID and hardened runtime (`-o runtime`), then the app signed last without `--deep` (Sparkle guides above; Apple notes dynamic `.dylib` XCFramework slices are macOS-only, and static `.a` is preferred in XCFrameworks ([Apple docs](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle))). Library validation applies: all embedded code must share the team ID, otherwise needs the `disable-library-validation` entitlement ([Eclectic Light](https://eclecticlight.co/2021/01/07/notarization-the-hardened-runtime)). Prefer static linking of the Rust core to avoid this entirely. Existing `scripts/build-sign-notarize.sh` already handles the sidecar, so reuse its pattern.

---

## 4. Menu-bar tray, global shortcuts, file associations, drag and drop

| Capability | Swift AppKit/SwiftUI | GPUI | Slint / egui |
|---|---|---|---|
| Menu-bar tray | `NSStatusItem` (full control; SwiftUI `MenuBarExtra` is limited, see [Multi blog](https://multi.app/blog/pushing-the-limits-nsstatusitem)) | not provided; use `tray-icon`/`objc2` or a Swift helper **[UNVERIFIED]** | Slint 1.17 `SystemTrayIcon` ([extenly](https://extenly.com/2026/07/09/slint-1-17-whats-new-in-the-modern-ui-toolkit)); egui via `tray-icon` crate **[UNVERIFIED]** |
| Global shortcuts | `KeyboardShortcuts` package: recorder UI, works while menu open, MAS-safe ([sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/keyboardshortcuts)) | via `global-hotkey` crate or Carbon **[UNVERIFIED]** | `global-hotkey` crate **[UNVERIFIED]** |
| Native menu bar | free (AppKit) | GPUI supports an app menu on macOS ("native menus" per a GPUI tutorial, [Medium](https://medium.com/rustaceans/rapid-gpui-component-based-desktop-development-part-1-5218017f6bff)) | Slint: muda-based, shortcuts shown in native menu (CHANGELOG above) |
| File associations (`CFBundleDocumentTypes`) | native Info.plist + `application(_:open:)` (current Tauri `fileAssociations` mechanism maps to the same plist) | works the same at the bundle level, but you must handle the open-file Apple event yourself **[UNVERIFIED]** | same |
| Drag and drop (files in/out, text) | native (`NSDraggingDestination`, SwiftUI `.onDrop`/`Transferable`) | file drop supported; drag-out, tabs reorder and rich pasteboard types need custom code **[UNVERIFIED]** | basic file drop |
| Launch at login / scheduler agent | `SMAppService` (Muya already uses it) | same, via FFI/objc2 | same |

---

## 5. Accessibility (VoiceOver) and IME (Turkish, press-and-hold)

| Option | VoiceOver | IME / accents (Turkish) | Evidence |
|---|---|---|---|
| Swift AppKit/SwiftUI + NSTextView/STTextView | full, platform-native | full: dead keys, press-and-hold accent popup, marked text, via `NSTextInputClient` | Apple HIG/WWDC26 a11y lab ([video](https://developer.apple.com/videos/play/wwdc2026/8005)); STTextView built on NSTextView semantics |
| Swift + libghostty terminal view | terminal content exposure is limited **[UNVERIFIED]**; Ghostty app itself is AppKit | Ghostty's macOS view implements `NSTextInputClient`; Calyx and Ghostty ship it, so press-and-hold and IME work in the terminal **[UNVERIFIED for press-and-hold specifically; test it]** | [Calyx write-up](https://dev.to/yuu1ch13/what-it-takes-to-embed-libghostty-in-a-swift-app-six-months-of-lessons-1m64) |
| GPUI / GPUI Kit | AccessKit roles claimed in Kit; Zed itself historically opaque | **no evidence either way**; must be spiked with Turkish layout, press-and-hold (a, c, g, i, o, s, u), and caps-lock `İ/ı` | [gpui-kit](https://github.com/longbridge/gpui-kit), [HN](https://news.ycombinator.com/item?id=45719004) |
| egui | works (AccessKit) | works in macOS survey test | [survey](https://blog.wybxc.cc/blog/rust-gui-survey-2026), [egui README](https://github.com/emilk/egui) |
| Slint | works | works | survey |
| iced | fails | works | survey |
| Xilem/Masonry | works | works | survey |

Note: the survey tested CJK composition, not Turkish press-and-hold specifically **[UNVERIFIED for Turkish]**. Press-and-hold accent popups (`ApplePressAndHoldEnabled`) go through `NSTextInputClient`/system text input; custom-rendered toolkits must re-implement this, and many do not. The Turkish dotted/dotless I rule is locale-dependent (`İ`/`ı`), which is a test case for any custom text engine.

---

## Comparison table

Scale: 5 = best. Risk column is overall delivery risk (lower is safer).

| Criterion | Swift + AppKit/SwiftUI (+ UniFFI, libghostty or own terminal) | GPUI (git dep or fork) | Slint | egui | iced / Xilem / Blitz |
|---|---|---|---|---|---|
| Maturity for pro desktop app | 5 | 3 | 3 | 3 | 1-2 |
| GPU terminal story | 5 (libghostty, Metal, proven by Ghostty and Calyx) | 3 (alacritty_terminal + custom view) | 1 | 1 | 1 |
| Code editor | 4 (STTextView + tree-sitter; diff custom) | 3 (Kit editor, unproven) | 1 | 1 | 1 |
| IME / Turkish | 5 | unknown (spike) | 3-4 | 3-4 | 3 |
| VoiceOver | 5 | 2-3 (unproven) | 3-4 | 3-4 | 1-3 |
| Tray / global shortcut / DnD / file assoc | 5 | 2-3 | 3 | 2 | 1-2 |
| Rust core integration | 3-4 (FFI layer, UniFFI) | 5 (same language) | 5 | 5 | 5 |
| Auto-update (Sparkle) | 5 | 4 (Rust crate exists) | 4 | 4 | 4 |
| Supply-chain / upstream risk | 2 low | 5 high (not on crates.io, Zed paused it, forks) | 3 (license check) | 2 | 4 |
| Overall | **Best** | Risky | Not enough widgets | Not enough widgets | Not ready |

---

## Ranked recommendation

1. **Swift (AppKit-first, SwiftUI where convenient) + Rust core via UniFFI (small command/event surface; broker and sidecars stay as separate Rust binaries on the unix socket) + libghostty (pinned) for terminals + STTextView + tree-sitter for the editor + Sparkle 2.** Only option with first-class IME, VoiceOver, menu bar, tray, DnD, file associations, and a proven agent-terminal precedent (Calyx). Cost: an FFI boundary and learning the XCFramework build; both are well trodden.
2. **Hybrid: native Swift shell + keep Rust PTY and a Swift-side terminal view (SwiftTerm or home-grown Metal), same editor stack.** Use if libghostty's unstable C API or its build (Zig toolchain) is unacceptable. Same UI benefits, less GPU polish.
3. **GPUI (via gpui-ce or git-pinned Zed) all-Rust.** Revisit only after a time-boxed spike proves Turkish press-and-hold, VoiceOver on the editor/terminal, and a stable dependency source. Do not start the rewrite on it blind.
4. Slint or egui for any small auxiliary tool windows only. iced, Xilem, Blitz: not now.

## Top 3 risks

1. **IME/accessibility regression in a custom-rendered stack** (applies to any non-AppKit path, and to terminal and editor views even in option 1). Mitigation: in week 1, build a test matrix (Turkish Q layout, press-and-hold for ğ ü ş ı ö ç, caps-lock İ/ı, VoiceOver reading editor, tree, terminal) and run it against libghostty view and STTextView before committing.
2. **libghostty API instability and build chain** (internal-only C header, Zig toolchain, ReleaseFast flag, terminfo/resources bundling). Mitigation: pin a commit, vendor an XCFramework built in CI, keep a thin Muya-owned terminal protocol so the view can be swapped; fall back to option 2.
3. **FFI boundary complexity and dependency health**: UniFFI/XCFramework packaging fragility, async/callback lifetime bugs (PTY streams, vault lock events), and, for the GPUI alternative, upstream publishing and fork continuity. Mitigation: keep the FFI surface small and event-based, leave the broker as an out-of-process Rust service, static-link the core to simplify signing (no library validation exceptions), and run Sparkle plus notarization through a pre-release dry run in the build script early.

## Source index (main)
- https://github.com/zed-industries/zed/discussions/55271
- https://news.ycombinator.com/item?id=47003569
- https://gpui.rs, https://github.com/gpui-ce/gpui-ce, https://github.com/longbridge/gpui-kit
- https://ghostty.org/docs/about, https://mitchellh.com/writing/libghostty-is-coming
- https://dev.to/yuu1ch13/what-it-takes-to-embed-libghostty-in-a-swift-app-six-months-of-lessons-1m64
- https://mozilla.github.io/uniffi-rs/next/swift/uniffi-bindgen-swift.html, https://github.com/mozilla/uniffi-rs/issues/2633
- https://forums.swift.org/t/the-state-of-swift-rust-interoperability/72205
- https://1password.com/blog/1password-8-the-story-so-far
- https://github.com/krzyzanowskim/STTextView, https://github.com/CodeEditApp/CodeEditSourceEditor
- https://developer.apple.com/videos/play/wwdc2026/370
- https://sparkle-project.org/documentation, https://github.com/sparkle-project/sparkle/releases
- https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears
- https://github.com/ahonn/tauri-plugin-sparkle-updater
- https://blog.wybxc.cc/blog/rust-gui-survey-2026, https://github.com/AccessKit/accesskit
- https://github.com/sindresorhus/keyboardshortcuts, https://multi.app/blog/pushing-the-limits-nsstatusitem
