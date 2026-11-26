// The terminal pane: an MTKView that draws the selected session and turns keyboard input into
// muyad messages. Printable text and IME commits go through NSTextInputClient (layouts, dead
// keys, press-and-hold, input methods all work); named keys and control chords go to muyad as
// Key messages so it encodes them for the program's current modes.

import AppKit
import MetalKit

final class TerminalView: MTKView, NSTextInputClient {
    let renderer: TerminalRenderer
    unowned let store: Store
    private(set) var session: SessionModel?
    /// The view's grid changed (cols, rows): the session shown here is resized to it.
    var onGrid: ((TerminalView, Int, Int) -> Void)?
    /// A click landed in this view: make its session the selected one.
    var onFocusRequest: ((TerminalView) -> Void)?
    /// A path link's menu: "Open in Muya" (a file) / "Open Terminal Here" (a directory).
    var onOpenFile: ((URL) -> Void)?
    var onTerminalHere: ((String) -> Void)?
    private struct LinkHit { var row: Int, from: Int, to: Int; var path: String; var kind: TerminalPathLinks.Kind
        func contains(_ c: Int, _ r: Int) -> Bool { r == row && c >= from && c <= to } }
    private var linkHit: LinkHit?
    /// The token under the pointer that was already looked at (so moving along it costs nothing).
    private var linkProbe: (row: Int, from: Int, to: Int)?
    private var pressedLink: LinkHit?
    private var pressCell = (col: -1, row: -1)
    /// Test hooks: the titles of the last path menu a click opened, and whether to record it instead of popping it up.
    private(set) var lastPathMenu: [String]?
    nonisolated(unsafe) static var captureMenus = false
    func resetPathMenu() { lastPathMenu = nil }
    private var linkCache = TerminalPathLinks.Cache()
    private var trackingArea: NSTrackingArea?
    private var resignObserver: NSObjectProtocol?
    private var marked = NSAttributedString()
    private var keyboardObserver: NSObjectProtocol?
    private var scroll = ScrollAccumulator()
    private(set) var lastGrid = (cols: 0, rows: 0)
    private enum Drag { case none, report, select }
    private var drag = Drag.none
    private var lastReported = (col: -1, row: -1)
    private var autoscroll: Timer?
    private var lastDragEvent: NSEvent?

    init(store: Store) {
        self.store = store
        let shared = RenderShared.get(scale: NSScreen.main?.backingScaleFactor ?? 2)
        renderer = TerminalRenderer(shared: shared)
        super.init(frame: .zero, device: shared.device)
        colorPixelFormat = .bgra8Unorm
        delegate = renderer
        // Draw on demand: an idle terminal does no work at all.
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        autoResizeDrawable = true
        (layer as? CAMetalLayer)?.displaySyncEnabled = true
    }

    required init(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Accessibility (AC10 / AC26): the terminal is one text area whose value is the visible screen.
    // Screen readers and the Accessibility API read the rows; asked for only on demand (main thread).

    private var axText: String { session?.replica.visibleText() ?? "" }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { session.map { "Terminal, \($0.name)" } ?? "Terminal" }
    override func accessibilityValue() -> Any? { axText }
    override func accessibilityNumberOfCharacters() -> Int { (axText as NSString).length }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: (axText as NSString).length) }
    override func accessibilitySelectedText() -> String? { session?.replica.selectedText() ?? "" }
    override func accessibilitySelectedTextRange() -> NSRange { NSRange(location: (axText as NSString).length, length: 0) }
    override func accessibilityString(for range: NSRange) -> String? {
        let t = axText as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= t.length else { return nil }
        return t.substring(with: range)
    }
    override func accessibilityLine(for index: Int) -> Int {
        let t = axText as NSString
        return t.substring(to: max(0, min(index, t.length))).filter { $0 == "\n" }.count
    }
    override func accessibilityRange(forLine line: Int) -> NSRange {
        var start = 0, n = 0
        let t = axText as NSString
        t.enumerateSubstrings(in: NSRange(location: 0, length: t.length), options: [.byLines, .substringNotRequired]) { _, r, enclosing, stop in
            if n == line { start = r.location; stop.pointee = true; _ = enclosing }
            n += 1
        }
        let rowRange = t.lineRange(for: NSRange(location: min(start, t.length), length: 0))
        return NSRange(location: rowRange.location, length: rowRange.length)
    }
    override var isFlipped: Bool { true }
    private var schemeObserver: Any?
    var findBar: TerminalFindBar?
    var findMatches: [FindMatch] = []
    var findCurrent: Int?

    // MARK: Layout and appearance

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
        applyAppearance()
        resignObserver.map(NotificationCenter.default.removeObserver)
        resignObserver = window.map { NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: $0, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.clearLink() } } }
        if schemeObserver == nil {
            schemeObserver = NotificationCenter.default.addObserver(forName: TerminalSchemeState.didChange, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.applyAppearance() } }
        }
        if keyboardObserver == nil {
            // Switching input source while focused does not attach the new input method until the
            // context is re-activated (ime-lab S3); NSTextView does this itself, a custom view must.
            keyboardObserver = NotificationCenter.default.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.window?.firstResponder === self, let ctx = self.inputContext else { return }
                DispatchQueue.main.async {
                    guard self.window?.firstResponder === self else { return }
                    ctx.deactivate(); ctx.activate()
                }
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Read the new value on the next turn: right inside the callback it can still be the old one.
        DispatchQueue.main.async { [weak self] in self?.applyAppearance() }
    }

    private func updateScale() {
        let s = window?.backingScaleFactor ?? 2
        guard s != renderer.scale else { updateGrid(); return }
        renderer.setScale(s)
        updateGrid()
    }

    func applyAppearance() {
        let theme = TerminalTheme.current(for: effectiveAppearance)
        renderer.theme = theme
        store.applyTheme(theme)
        let bg = theme.background
        clearColor = MTLClearColor(red: Double(bg.r) / 255, green: Double(bg.g) / 255, blue: Double(bg.b) / 255, alpha: 1)
        requestDraw()
    }

    override func layout() {
        super.layout()
        updateGrid()
        layoutFind()
    }

    private func updateGrid() {
        let scale = renderer.scale
        let px = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard px.width > 0, px.height > 0 else { return }
        let g = renderer.gridFor(drawable: px)
        store.cell = (renderer.atlas.cellW, renderer.atlas.cellH)
        guard g.cols != lastGrid.cols || g.rows != lastGrid.rows else { return }
        lastGrid = (g.cols, g.rows)
        renderer.setGrid(cols: g.cols, rows: g.rows)
        onGrid?(self, g.cols, g.rows)
        requestDraw()
    }

    func show(_ s: SessionModel?) {
        if session !== s { cancelComposition(); drag = .none; autoscroll?.invalidate(); clearLink() }
        session = s
        renderer.replica = s?.replica
        // A session takes the grid of the view that shows it.
        if let s, lastGrid.cols > 0 { store.ensureSize(s, cols: lastGrid.cols, rows: lastGrid.rows) }
        requestDraw()
    }

    /// Fires once, on the main thread, after the GPU has finished the next frame of this view.
    func notifyAfterNextFrame(_ f: @escaping () -> Void) {
        renderer.onNextFrameCompleted = f
        requestDraw()
    }

    /// AC24: set while the window is occluded / minimized / the Mac sleeps; draws are dropped and one is
    /// requested per visible tile when the window shows again. Main thread only.
    nonisolated(unsafe) static var drawingSuspended = false

    /// Safe from any thread; draws coalesce to the display refresh.
    func requestDraw() {
        if Thread.isMainThread { if !Self.drawingSuspended { needsDisplay = true } } else { DispatchQueue.main.async { [weak self] in if !Self.drawingSuspended { self?.needsDisplay = true } } }
    }

    // MARK: Keyboard

    private static let named: [UInt16: String] = [
        36: "enter", 76: "enter", 48: "tab", 53: "escape", 51: "backspace", 117: "delete",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "page_up", 121: "page_down", 114: "insert",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    static func mods(_ f: NSEvent.ModifierFlags) -> UInt16 {
        var m: UInt16 = 0
        if f.contains(.shift) { m |= modShift }
        if f.contains(.option) { m |= modAlt }
        if f.contains(.control) { m |= modCtrl }
        if f.contains(.command) { m |= modSuper }
        return m
    }

    /// P3: the key as a chord (layout-aware character, modifiers) for the shortcut map.
    static func chord(_ e: NSEvent) -> KeyChord {
        let f = e.modifierFlags
        return KeyChord(keyCode: e.keyCode, chars: e.charactersIgnoringModifiers ?? "", cmd: f.contains(.command), shift: f.contains(.shift), alt: f.contains(.option), ctrl: f.contains(.control))
    }

    /// Set by the shortcut router: ⌘= / ⌘- / ⌘0 (+1 / -1 / 0).
    nonisolated(unsafe) static var onFontStep: ((Int) -> Void)?

    /// Shift+Enter, ⌘R/L/A/E/D/U, ⌘C, ⌘⇧C, Option+arrows, font keys (ShortcutLogic.swift, Terminal.tsx's key handler).
    /// True when the key was used.
    @discardableResult
    func performKeyAction(_ k: KeyChord) -> Bool {
        guard let a = TerminalKeys.action(k) else { return false }
        switch a {
        case .write(let s): store.sendText(s)
        case .copyOrInterrupt: if copySelection() == nil { store.sendText("\u{03}") }
        case .launchClaude: store.sendText("claude \(NewAgentCommand.flag(for: store.permissionMode))\r")
        case .font(let d): Self.onFontStep?(d)
        case .search: showFind()
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), performKeyAction(Self.chord(event)) { return }
        let m = Self.mods(event.modifierFlags)
        if event.modifierFlags.contains(.command) { return } // menu shortcuts are handled by performKeyEquivalent
        if let name = Self.named[event.keyCode] {
            store.sendKey(name, mods: m)
            return
        }
        if event.modifierFlags.contains(.control), let c = event.charactersIgnoringModifiers, c.unicodeScalars.count == 1 {
            store.sendKey(c == " " ? "space" : c.lowercased(), mods: m)
            return
        }
        // Everything else (layouts, dead keys, IME) goes through the input context.
        _ = inputContext?.handleEvent(event)
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        cancelComposition()
        store.sendText(text)
    }

    private func cancelComposition() {
        guard marked.length > 0 || !renderer.preedit.isEmpty else { return }
        marked = NSAttributedString()
        renderer.preedit = ""
        requestDraw()
    }

    override func doCommand(by selector: Selector) {
        // Named keys never get here (handled in keyDown); swallow the rest so AppKit does not beep.
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        renderer.preedit = marked.string
        requestDraw()
    }

    func unmarkText() {
        let t = marked.string
        cancelComposition()
        if !t.isEmpty { store.sendText(t) }
    }

    /// The composition currently shown (debug socket / tests).
    var preeditText: String { renderer.preedit }

    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// The input method's candidate window goes next to the cursor cell.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let cs = renderer.cellSizePoints
        let c = renderer.cursorCell
        let pad = CGFloat(renderer.paddingPx) / renderer.scale
        let g = IMEAnchor.cellRect(col: c.x, row: c.y, cellW: Double(cs.width), cellH: Double(cs.height), padding: Double(pad))
        let r = NSRect(x: g.x, y: g.y, width: g.w, height: g.h)
        return window?.convertToScreen(convert(r, to: nil)) ?? .zero
    }

    // MARK: Context menu (today's TerminalContextMenu: Copy, Paste, Select All, Clear Scrollback, text size)

    override func menu(for event: NSEvent) -> NSMenu? {
        let (c, r) = cell(at: event)
        if linksActive(event), let hit = linkHit, hit.contains(c, r) { return pathMenu(for: hit) }   // a right-click on a path link
        return contextMenu()
    }

    /// Today's TerminalContextMenu.tsx, item for item: Copy, Paste, Paste as Path, Select All, Open Link (when the selection is
    /// a web URL), Find…, Clear Scrollback, text size.
    func contextMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ key: String = "", _ enabled: Bool = true, _ run: @escaping () -> Void) {
            let i = BlockMenuItem(title: title, run: run); i.isEnabled = enabled; m.addItem(i)
            if !key.isEmpty { i.attributedTitle = NSAttributedString(string: title + "    " + key, attributes: [.font: NSFont.menuFont(ofSize: 0)]) }
        }
        let selection = session?.replica.selectedText() ?? ""
        add("Copy", "⌘C", session?.replica.hasSelection ?? false) { [weak self] in self?.copy(nil) }
        add("Paste", "⌘V") { [weak self] in self?.paste(nil) }
        add("Paste as Path") { [weak self] in self?.pasteAsPath() }
        add("Select All", "⌘A") { [weak self] in self?.selectAll(nil) }
        if TerminalFind.isWebURL(selection) {
            m.addItem(.separator())
            add("Open Link") { if let u = URL(string: selection.trimmingCharacters(in: .whitespacesAndNewlines)) { NSWorkspace.shared.open(u) } }
        }
        m.addItem(.separator())
        add("Find…", "⌘F") { [weak self] in self?.showFind() }
        add("Clear Scrollback") { [weak self] in self?.clearScrollback() }
        m.addItem(.separator())
        add("Bigger Text", "⌘=") { TerminalView.onFontStep?(1) }
        add("Smaller Text", "⌘-") { TerminalView.onFontStep?(-1) }
        add("Default Text Size", "⌘0") { TerminalView.onFontStep?(0) }
        return m
    }

    /// "Paste as Path": the clipboard text with spaces and shell characters backslashed, a trailing newline dropped (iTerm2's
    /// "Paste Escaping Special Characters"). Copied files (Finder) paste as their paths.
    func pasteAsPath() {
        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let text = urls.isEmpty ? (pb.string(forType: .string) ?? "") : urls.map(\.path).joined(separator: "\n")
        let escaped = text.split(separator: "\n", omittingEmptySubsequences: true).map { TerminalFind.escapeForShell(String($0)) }.joined(separator: " ")
        if !escaped.isEmpty { store.paste(escaped) }
    }

    func clearScrollback() {
        session?.replica.clearScrollback()
        findMatches = []; findCurrent = nil
        requestDraw()
    }

    // MARK: Edit menu

    /// The pasteboard ⌘V reads. The test hooks point it at a private one so a test never touches the operator's clipboard.
    nonisolated(unsafe) static var pasteboard: NSPasteboard = .general

    @objc func paste(_ sender: Any?) {
        let pb = Self.pasteboard
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let types = (pb.types ?? []).map(\.rawValue)
        switch PasteLogic.decide(filePaths: urls.map(\.path), string: pb.string(forType: .string), hasImage: PasteLogic.hasImage(types: types)) {
        case .text(let t): store.paste(t)
        case .emptyPasteForImage: store.paste("", allowEmpty: true)   // Claude Code reads the image itself (see PasteLogic)
        case .nothing: break
        }
    }

    @objc func copy(_ sender: Any?) { _ = copySelection() }

    @objc override func selectAll(_ sender: Any?) {
        session?.replica.selectAll()
        requestDraw()
    }

    /// Puts the selected text on the general pasteboard; returns it (nil when nothing is selected).
    @discardableResult
    func copySelection() -> String? {
        guard let t = session?.replica.selectedText(), !t.isEmpty else { return nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        return t
    }

    @objc func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return session?.replica.hasSelection ?? false }
        return true
    }

    // MARK: Mouse

    var metrics: CellMetrics {
        let cs = renderer.cellSizePoints
        return CellMetrics(cellW: Double(cs.width), cellH: Double(cs.height), padding: Double(renderer.paddingPx / Float(renderer.scale)))
    }

    private func cell(at event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        let c = metrics.cell(atX: Double(p.x), y: Double(p.y), cols: max(renderer.cols, 1), rows: max(renderer.rows, 1))
        return (c.col, c.row)
    }

    private func pointer(_ event: NSEvent, rectangle: Bool = false) -> Replica.Pointer {
        let p = convert(event.locationInWindow, from: nil)
        let (c, r) = cell(at: event)
        let s = Double(renderer.scale)
        return Replica.Pointer(col: c, row: r, x: Double(p.x) * s, y: Double(p.y) * s, timeNs: UInt64(event.timestamp * 1e9), rectangle: rectangle)
    }

    private var gestureGeometry: Replica.GestureGeometry {
        Replica.GestureGeometry(cols: renderer.cols, cellWpx: renderer.atlas.cellW, paddingPx: Int(renderer.paddingPx), heightPx: Int(bounds.height * renderer.scale))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocusRequest?(self)
        guard let s = session else { return }
        let m = Self.mods(event.modifierFlags)
        let (c, r) = cell(at: event)
        pressCell = (c, r)
        pressedLink = nil
        if event.clickCount == 1, linksActive(event), let hit = linkHit, hit.contains(c, r) { pressedLink = hit }
        switch MouseRoute.decide(programTracksMouse: s.replica.mouseTracking, shift: event.modifierFlags.contains(.shift)) {
        case .report:
            drag = .report
            s.replica.clearSelection() // any click that goes to the program also drops the old selection
            requestDraw()
            lastReported = (c, r)
            store.sendMouse(session: s, col: c, row: r, button: "left", action: "press", mods: m)
        case .select:
            drag = .select
            lastDragEvent = event
            s.replica.selectionPress(pointer(event), repeatIntervalNs: UInt64(NSEvent.doubleClickInterval * 1e9), repeatDistance: Double(metrics.cellW * renderer.scale) / 2)
            requestDraw()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = session else { return }
        switch drag {
        case .report:
            let (c, r) = cell(at: event)
            guard (c, r) != lastReported else { return }
            lastReported = (c, r)
            store.sendMouse(session: s, col: c, row: r, button: "left", action: "motion", mods: Self.mods(event.modifierFlags))
        case .select:
            lastDragEvent = event
            let (c, r) = cell(at: event)
            if pressedLink != nil, (c, r) != pressCell { pressedLink = nil }   // a drag is a selection, not a click on the link
            s.replica.selectionDrag(pointer(event, rectangle: event.modifierFlags.contains(.option)), geometry: gestureGeometry)
            updateAutoscroll(for: event)
            requestDraw()
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none; autoscroll?.invalidate(); autoscroll = nil; pressedLink = nil }
        guard let s = session else { return }
        let (c, r) = cell(at: event)
        if let hit = pressedLink, drag == .select, hit.contains(c, r) {   // press and release on the same link, no drag: its menu
            s.replica.selectionRelease(col: c, row: r); requestDraw()
            let menu = pathMenu(for: hit)
            lastPathMenu = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
            if !Self.captureMenus { menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self) }
            return
        }
        switch drag {
        case .report: store.sendMouse(session: s, col: c, row: r, button: "left", action: "release", mods: Self.mods(event.modifierFlags))
        case .select: s.replica.selectionRelease(col: c, row: r); requestDraw()
        case .none: break
        }
    }

    /// Dragging above or below the view keeps scrolling (and extending the selection) while the button is held.
    private func updateAutoscroll(for event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        guard y < 0 || y > bounds.height else { autoscroll?.invalidate(); autoscroll = nil; return }
        guard autoscroll == nil else { return }
        autoscroll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, self.drag == .select, let s = self.session, let e = self.lastDragEvent else { return }
            let y = self.convert(e.locationInWindow, from: nil).y
            s.replica.scroll(lines: y < 0 ? -1 : 1) // flipped view: y < 0 is above the top
            var p = self.pointer(e)
            p.row = y < 0 ? 0 : max(self.renderer.rows - 1, 0)
            s.replica.selectionDrag(p, geometry: self.gestureGeometry)
            self.requestDraw()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let s = session else { return }
        let cs = renderer.cellSizePoints
        let lines = scroll.lines(delta: Double(event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? cs.height : 1)))
        guard lines != 0 else { return }
        clearLink()
        if s.replica.mouseTracking && !event.modifierFlags.contains(.shift) {
            let (c, r) = cell(at: event)
            for _ in 0 ..< abs(lines) {
                store.sendMouse(session: s, col: c, row: r, button: lines > 0 ? "wheel_up" : "wheel_down", action: "press", mods: Self.mods(event.modifierFlags))
            }
        } else {
            s.replica.scroll(lines: -lines)
            requestDraw()
        }
    }

    // MARK: Path links (classic's terminal path links: hover a path that exists, click or right-click for its menu)

    /// False while the program owns the mouse (and Shift is not held): the click is the program's.
    private func linksActive(_ event: NSEvent) -> Bool {
        guard let s = session else { return false }
        return MouseRoute.decide(programTracksMouse: s.replica.mouseTracking, shift: event.modifierFlags.contains(.shift)) == .select
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        guard linksActive(event) else { clearLink(); return }
        let (c, r) = cell(at: event)
        hover(col: c, row: r)
    }

    override func mouseExited(with event: NSEvent) { clearLink() }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let h = linkHit else { return }
        let g = IMEAnchor.cellRect(col: h.from, row: h.row, cellW: metrics.cellW, cellH: metrics.cellH, padding: metrics.padding)
        addCursorRect(NSRect(x: g.x, y: g.y, width: g.w * Double(h.to - h.from + 1), height: g.h), cursor: .pointingHand)
    }

    func clearLink() {
        linkProbe = nil
        guard linkHit != nil || renderer.link != nil else { return }
        linkHit = nil
        renderer.link = nil
        window?.invalidateCursorRects(for: self)
        requestDraw()
    }

    /// The path token at a cell of the visible screen, resolved against the session's current directory (main thread; a stat).
    func linkInfo(col: Int, row: Int) -> (token: TerminalPathLinks.Token, path: String, kind: TerminalPathLinks.Kind)? {
        guard let s = session, let t = TerminalPathLinks.token(cells: s.replica.rowCells(row), column: col) else { return nil }
        let p = TerminalPathLinks.resolve(t.text, cwd: SessionModel.currentDirectory(of: s.pid) ?? s.cwd, home: store.home)
        return (t, p, TerminalPathLinks.kind(ofPath: p))
    }

    /// The pointer is over a cell: underline the path token there once it is known to exist. Resolution (a stat) runs off the
    /// main thread and is remembered per (cwd, token); a token already looked at is not looked at again while the pointer stays on it.
    func hover(col c: Int, row r: Int) {
        if let p = linkProbe, p.row == r, c >= p.from, c <= p.to { return }
        clearLink()
        guard let s = session, let t = TerminalPathLinks.token(cells: s.replica.rowCells(r), column: c) else { return }
        let probe = (row: r, from: t.startCol, to: t.endCol)
        linkProbe = probe
        let cwd = SessionModel.currentDirectory(of: s.pid) ?? s.cwd
        let home = store.home
        func apply(_ path: String, _ kind: TerminalPathLinks.Kind) {
            guard kind != .none else { return }
            linkHit = LinkHit(row: probe.row, from: probe.from, to: probe.to, path: path, kind: kind)
            renderer.link = probe
            window?.invalidateCursorRects(for: self)
            requestDraw()
        }
        if let hit = linkCache[cwd, t.text] { apply(hit.path, hit.kind); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let path = TerminalPathLinks.resolve(t.text, cwd: cwd, home: home)
            let kind = TerminalPathLinks.kind(ofPath: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.linkCache[cwd, t.text] = (path, kind)
                guard self.session === s, let now = self.linkProbe, now == probe else { return }
                apply(path, kind)
            }
        }
    }

    /// The menu a click on this cell would open (debug socket / tests); nil when the cell is not on an existing path.
    func pathMenu(col: Int, row: Int) -> NSMenu? {
        guard let i = linkInfo(col: col, row: row), i.kind != .none else { return nil }
        return pathMenu(for: LinkHit(row: row, from: i.token.startCol, to: i.token.endCol, path: i.path, kind: i.kind))
    }

    /// The underlined link right now: "row from to kind path", or "none" (debug socket / tests).
    var linkState: String {
        guard let h = linkHit else { return "none" }
        return "row=\(h.row) from=\(h.from) to=\(h.to) kind=\(h.kind.rawValue) path=\(h.path) underlined=\(renderer.link != nil)"
    }

    /// Classic's path menu: a 📁 / 📄 header, then Open in Muya (file) or Open Terminal Here (directory), Reveal in Finder, Copy Path.
    private func pathMenu(for hit: LinkHit) -> NSMenu {
        let m = NSMenu()
        let header = NSMenuItem(title: TerminalPathLinks.header(path: hit.path, kind: hit.kind), action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())
        for title in TerminalPathLinks.menuTitles(for: hit.kind) {
            m.addItem(BlockMenuItem(title: title) { [weak self] in self?.runPathAction(title, path: hit.path, kind: hit.kind) })
        }
        return m
    }

    func runPathAction(_ title: String, path: String, kind: TerminalPathLinks.Kind) {
        let url = URL(fileURLWithPath: path)
        switch title {
        case "Open in Muya": onOpenFile?(url)
        case "Open Terminal Here": onTerminalHere?(PathActions.terminalDirectory(for: url, isDirectory: kind == .dir))
        case "Reveal in Finder": NSWorkspace.shared.activateFileViewerSelecting([url])
        case "Copy Path": Self.pasteboard.clearContents(); Self.pasteboard.setString(path, forType: .string)
        default: break
        }
    }
}
