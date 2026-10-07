# Mini-PRD: Muya Browser — a WebKit tab Claude can drive, plus a crawler

- Date: 2026-10-07
- Type: mini-PRD
- Operator decisions (2026-10-07): WebKit, not a bundled Chromium (no screencast, no extra
  process); add a crawler; **security restrictions are deferred** — the user may log in to
  sites in Muya's browser and have Claude work with that session.

## 1. Problem
Claude's web research and browser work happen outside Muya (the operator's Chrome via an
extension that asks which browser to use, or a separate Playwright window). The operator wants
it inside Muya: a browser the user can see and use, that Claude can also drive, visible or
hidden, plus a lightweight crawler for research.

## 2. Scope
- In:
  - **Browser page** (new rail item "Browser"): one WebKit webview embedded in the main
    window (Tauri child webview, `WebviewUrl::External`), following a React-rendered
    rectangle. Address bar, back / forward / reload, "Show to Claude only" ⇄ visible.
  - **Persistent profile**: the browser keeps its own cookies/logins across restarts in a data
    store separate from Muya's UI (`data_store_identifier`, macOS 14+; on older macOS it shares
    the default store).
  - **Hidden mode**: the same webview keeps running while the page is not on screen (parked
    off-screen, not `hide()`n, if hidden WebKit throttles — verified in phase 1).
  - **muya-mcp tools** (broker op → sidecar tool, like `ssh_*`):
    - `browser_open(url, show?)` — navigate; `show:true` brings the Browser page up.
    - `browser_read(mode)` — `markdown` (main content), `text`, `links`, or `elements`
      (numbered interactive elements: role, name, ref).
    - `browser_click(ref | selector)`, `browser_fill(ref | selector, value, submit?)`,
      `browser_press(key)`, `browser_scroll(direction)`, `browser_back()`.
    - `browser_screenshot()` — PNG of the page (`WKWebView takeSnapshot`), saved to a temp file,
      path returned.
    - `browser_wait(for: text | selector, timeoutSecs)`.
  - **Crawler tools** (no browser, in-process, reuse `reqwest`):
    - `web_fetch(url)` → main content as Markdown (`dom_smoothie` readability + `htmd`).
    - `web_crawl(url, maxPages≤50, depth≤3, sameSite=true)` → Markdown per page, honouring
      robots.txt; pages whose content is empty without JavaScript are rendered in the hidden
      browser instead.
- Out:
  - Security policy (allowlists, confirmations, prompt-injection labelling) — deferred by the
    operator; tracked as a follow-up.
  - Multiple browser tabs, downloads manager, file upload, bookmarks/history UI.
  - Using Safari/Chrome cookies (not possible from a WKWebView).
  - Network inspection, cross-origin iframe content.

## 3. Acceptance criteria (binary)
- [ ] AC1: Rail "Browser" shows a working page (address bar + back/forward/reload); typing a
  URL loads it; it fills the page area and follows window/panel resizes.
- [ ] AC2: Logging in to a site in the browser survives a Muya restart (cookie persists), and
  Muya's own UI storage is untouched.
- [ ] AC3: The remote page has no Tauri IPC (`window.__TAURI_INTERNALS__` undefined in it).
- [ ] AC4: With the Browser page not on screen, `browser_open` + `browser_read` still return the
  page's content (hidden mode works).
- [ ] AC5: `browser_read(elements)` returns numbered refs; `browser_click(ref)` and
  `browser_fill(ref, value, submit:true)` act on the right element (proved on a local test page
  with a form whose submit result is read back).
- [ ] AC6: `browser_screenshot` returns a path to a non-empty PNG of the current page.
- [ ] AC7: `web_fetch` returns Markdown of an article's main content (no nav/footer boilerplate)
  for a static page; `web_crawl` respects `maxPages`, `depth`, same-site, robots.txt.
- [ ] AC8: A JS-only page (empty without JS) fetched by `web_crawl` comes back with content via
  the hidden browser.
- [ ] AC9: The rebuilt sidecar lists all new tools (`tools/list`) and a live run against a dev
  instance (isolated socket) passes AC4–AC8.
- [ ] AC10: Idle cost: with the Browser page never opened, no browser webview exists (lazy).

## 4. Protection list
- Muya's main webview: CSP, capabilities, IPC surface unchanged (child label in no capability).
- Terminal pool / focus logic (`terminalVisibility.ts`, `terminalHosts.ts`) — the Browser page
  hides the Control page like other pages do.
- Existing muya-mcp tools and broker ops.

## 5. Integration / harmony
- Agent → app path: sidecar tool → broker op over the uid-checked UDS (`broker.rs`
  `handle_request`), app-side work via `AppHandle`, UI events like `muya://open-agent-session`
  (`broker.rs:1030`).
- Rail/pages: `RailItem` (`src/redesign/types.ts:106`), always-mounted secondary pages hidden
  with `display:none` (`App.tsx` "Secondary pages" block); Browser page follows that.
- Child webview: `Window::add_child` + `WebviewBuilder` (`tauri` feature `unstable`, tauri 2.11.3
  in `Cargo.lock`) — to verify against 2.11.3 in phase 1; JS results via `with_webview` →
  `WKWebView evaluateJavaScript:completionHandler:` (`objc2-web-kit` 0.3.2 already in the lock
  via wry); snapshot via `takeSnapshotWithConfiguration`.
- HTTP: `reqwest` 0.12 rustls already a dependency (`Cargo.toml:48`). New crates:
  `dom_smoothie` (MIT), `htmd` (Apache-2.0), `robotstxt` or equivalent (checked for advisories
  before adding). `spider` rejected: heavy, Linux-oriented default features; the crawl here is
  small and bounded.
- Break risk: `unstable` feature changes compile surface — full `cargo test --lib`, `tsc`,
  `npm test`, `npm run build` must stay green; child webview overlapping modals/menus (z-order
  above DOM) — Browser page hides the child webview while a modal is open.

## 6. Phases
1. Spike: child webview in 2.11.3, eval-with-result, snapshot, hidden-mode throttling (decide
   off-screen vs hide). Browser page UI (AC1–AC3, AC10).
2. Browser tools (AC4–AC6).
3. Crawler tools (AC7–AC8), sidecar + live run (AC9).
