// Split Control (today's src/redesign/SplitArea.tsx + App.tsx "Split Control"): a split group shows its terminals side by side in the
// Control area (2–8 panes, `SplitLogic.layout`), each with a 26 px header (state dot, name, focus ×, close ×) and draggable column dividers.
// `SplitModel` holds the groups (persisted under today's `muya.splitGroups` / `muya.splitGroupsCollapsed`); `SplitChrome` draws the
// headers, dividers and focus outline around the TileContainer's tiles. No timers: everything is event-driven.

import AppKit

/// Split state of the main controller: the groups, which are collapsed in the agent list, the pane shown alone, the column widths.
final class SplitModel {
    var groups: [SplitGroup] = []
    var collapsed: Set<String> = []
    var zoom: UInt64?
    var fractions: [String: [Double]] = [:]
    /// Groups or collapse state changed (persist + redraw).
    var onChange: (() -> Void)?
    /// Set by "Split" (⌘⇧D, the header button): the session that was split, so the clone that arrives next joins its group.
    var pendingAnchor: String?
    var pendingKnownIds: Set<UInt64> = []

    nonisolated static func key(_ s: SessionModel) -> String { "\(s.id)" }
    nonisolated static func key(id: UInt64) -> String { "\(id)" }

    func group(of s: SessionModel?) -> SplitGroup? { s.flatMap { SplitLogic.groupOf(groups, Self.key($0)) } }

    func load(_ l: LegacyStore) {
        groups = (l.get(PrefKeys.splitGroups)).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }.flatMap(SplitLogic.decode) ?? []
        collapsed = Set(PrefCodec.stringList(l.get(PrefKeys.splitCollapsed)) ?? [])
    }

    func save(_ l: LegacyStore) {
        let data = try? JSONSerialization.data(withJSONObject: SplitLogic.encode(groups))
        l.set(PrefKeys.splitGroups, data.flatMap { String(data: $0, encoding: .utf8) })
        l.set(PrefKeys.splitCollapsed, PrefCodec.encode(list: collapsed.sorted()))
    }

    /// Drops closed sessions from the groups (a group left with one dissolves). True when something changed.
    @discardableResult
    func resolve(existing: Set<String>) -> Bool {
        let next = SplitLogic.resolve(groups, existing: existing)
        guard next != groups else { return false }
        groups = next
        let ids = Set(next.map(\.id)); collapsed = collapsed.filter { ids.contains($0) }
        return true
    }
}

/// One pane's 26 px header.
final class SplitPaneHeader: NSView {
    static let height: CGFloat = 26
    var session: SessionModel?
    var focused = false { didSet { needsDisplay = true } }
    var zoomed = false { didSet { needsDisplay = true } }
    var showsZoom = true
    var onFocus: (() -> Void)?, onZoom: (() -> Void)?, onClose: (() -> Void)?
    private var closeRect: NSRect { NSRect(x: bounds.width - 26, y: 3, width: 20, height: 20) }
    private var zoomRect: NSRect { NSRect(x: bounds.width - 48, y: 3, width: 20, height: 20) }
    override var isFlipped: Bool { true }

    func update(_ s: SessionModel, focused: Bool, zoomed: Bool) {
        let changed = session !== s || self.focused != focused || self.zoomed != zoomed || s.state.text != lastState || s.name != lastName
        session = s; self.focused = focused; self.zoomed = zoomed; lastState = s.state.text; lastName = s.name
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Pane \(s.name)")
        if changed { needsDisplay = true }
    }
    private var lastState = "", lastName = ""

    override func draw(_ dirtyRect: NSRect) {
        let waiting = session?.screen?.permission == true && session?.exited == nil
        Theme.dynamic(waiting ? .warningCardBg : focused ? .bgSelected : .bgPanel).setFill(); bounds.fill()
        Theme.dynamic(.border).setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard let s = session else { return }
        s.state.color.setFill(); NSBezierPath(ovalIn: NSRect(x: 10, y: 10, width: 6, height: 6)).fill()
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail
        (s.name as NSString).draw(in: NSRect(x: 22, y: 5, width: max(0, zoomRect.minX - 28), height: 16), withAttributes: [.font: ThemeFont.sans(12, focused ? .semibold : .medium), .foregroundColor: Theme.dynamic(.text), .paragraphStyle: ps])
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if showsZoom {
            ctx.saveGState(); ctx.translateBy(x: zoomRect.minX + 4, y: zoomRect.minY + 4)
            ThemeIcons.draw(zoomed ? .minimize : .maximize, in: ctx, size: 12, color: Theme.dynamic(zoomed ? .accent : .textMuted)); ctx.restoreGState()
        }
        ctx.saveGState(); ctx.translateBy(x: closeRect.midX, y: closeRect.midY); ctx.rotate(by: .pi / 4); ctx.translateBy(x: -5, y: -5)
        ThemeIcons.draw(.plus, in: ctx, size: 10, color: Theme.dynamic(.textMuted)); ctx.restoreGState()   // a plus turned 45° = ×
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.contains(p) { onClose?() } else if showsZoom, zoomRect.contains(p) { onZoom?() } else { onFocus?() }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// 1 px accent outline of the focused pane; never takes the mouse.
final class SplitOutline: NSView {
    var on = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard on else { return }
        Theme.dynamic(.accent).setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A draggable column divider (5 px hit area over the 1 px gap).
final class SplitDivider: NSView {
    var index = 0
    var onDrag: ((Int, CGFloat) -> Void)?   // divider index, horizontal movement in points
    override var isFlipped: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        var last = event.locationInWindow.x
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let x = e.locationInWindow.x
            if e.type == .leftMouseDragged { onDrag?(index, x - last); last = x } else { break }
        }
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
}

/// The headers, dividers and outlines around the split panes; owned by the TileContainer.
final class SplitChrome {
    private(set) var active = false
    private var headers: [SplitPaneHeader] = [], outlines: [SplitOutline] = [], dividers: [SplitDivider] = []
    private(set) var sessions: [SessionModel] = []
    var fractions: [Double] = []
    var onFocus: ((SessionModel) -> Void)?, onZoom: ((SessionModel) -> Void)?, onClose: ((SessionModel) -> Void)?
    var onFractions: (([Double]) -> Void)?
    private weak var host: NSView?
    private var zoomed = false

    init(host: NSView) { self.host = host }

    func deactivate() {
        guard active else { return }
        active = false
        for v in headers as [NSView] + outlines + dividers { v.isHidden = true }
        host?.layer?.backgroundColor = nil
    }

    /// Shows `sessions` as panes (`focused` outlined). `zoomed`: one pane alone (its button restores the split).
    func configure(sessions: [SessionModel], focused: SessionModel?, zoomed: Bool, fractions: [Double]?) {
        guard let host else { return }
        active = true; self.sessions = sessions; self.zoomed = zoomed
        let (cols, _) = SplitLogic.layout(sessions.count)
        self.fractions = (fractions?.count == cols) ? fractions! : Array(repeating: 1 / Double(cols), count: cols)
        while headers.count < sessions.count {
            let h = SplitPaneHeader(), o = SplitOutline()
            h.onFocus = { [weak self, weak h] in if let s = h?.session { self?.onFocus?(s) } }
            h.onZoom = { [weak self, weak h] in if let s = h?.session { self?.onZoom?(s) } }
            h.onClose = { [weak self, weak h] in if let s = h?.session { self?.onClose?(s) } }
            headers.append(h); outlines.append(o); host.addSubview(h); host.addSubview(o)
        }
        while dividers.count < 3 {
            let d = SplitDivider(); d.index = dividers.count
            d.onDrag = { [weak self] i, dx in self?.drag(i, dx) }
            dividers.append(d); host.addSubview(d)
        }
        for (i, h) in headers.enumerated() {
            let on = i < sessions.count
            h.isHidden = !on; outlines[i].isHidden = !on
            if on { h.showsZoom = true; h.update(sessions[i], focused: sessions[i] === focused, zoomed: zoomed); outlines[i].on = sessions[i] === focused }
        }
    }

    /// Test hook: what dragging divider `i` by `dx` points does.
    func simulateDrag(_ i: Int, _ dx: CGFloat) { drag(i, dx) }

    private func drag(_ i: Int, _ dx: CGFloat) {
        guard let host, host.bounds.width > 0 else { return }
        fractions = SplitLogic.moveDivider(fractions, index: i, delta: Double(dx / host.bounds.width))
        onFractions?(fractions)
        host.needsLayout = true
    }

    /// Frames of the panes' tiles (below the header); also places the headers, outlines and dividers.
    func layout(tiles: [Tile], bounds: NSRect) {
        guard active, let host else { return }
        effectiveBackground(host)
        let n = sessions.count
        let (cols, rows) = SplitLogic.layout(n)
        let gap: CGFloat = 1
        let cellH = (bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let usableW = bounds.width - gap * CGFloat(cols - 1)
        var colX: [CGFloat] = [], colW: [CGFloat] = [], x: CGFloat = 0
        for c in 0 ..< cols { let w = CGFloat(fractions[c]) * usableW; colX.append(x); colW.append(w); x += w + gap }
        for i in 0 ..< n {
            let r = i / cols, c = i % cols
            let rect = NSRect(x: colX[c], y: CGFloat(r) * (cellH + gap), width: colW[c], height: cellH)
            headers[i].frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: SplitPaneHeader.height)
            outlines[i].frame = rect
            if i < tiles.count { tiles[i].frame = NSRect(x: rect.minX, y: rect.minY + SplitPaneHeader.height, width: rect.width, height: max(0, rect.height - SplitPaneHeader.height)) }
        }
        for (i, d) in dividers.enumerated() {
            let on = i < cols - 1
            d.isHidden = !on
            if on { d.frame = NSRect(x: colX[i] + colW[i] - 2, y: 0, width: 5, height: bounds.height); d.window?.invalidateCursorRects(for: d) }
        }
    }

    private func effectiveBackground(_ host: NSView) {
        host.effectiveAppearance.performAsCurrentDrawingAppearance { host.layer?.backgroundColor = Theme.dynamic(.border).cgColor }
    }
}
