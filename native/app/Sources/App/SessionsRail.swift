// Sessions rail (docs/prd-sessions-rail.md): while the Agents column is closed, the left rail has two pages, Sessions (one compact
// item per session, same order and split grouping as the Agents list) and Menu (today's icons). Page state and geometry live in
// Logic/SessionsRailLogic.swift; this file draws the pane and the ‹ › switcher and wires them to MainController.

import AppKit

/// What the rail shows for one session.
struct RailSession {
    let id: UInt64, name: String, monogram: String, tooltip: String
    let waiting: Bool
    let kindIcon: ThemeIcon, kindColor: NSColor, stateColor: NSColor
    let splitGroup: String?
}

/// ‹ [two dots] › at the top of the rail.
final class RailSwitcher: NSView {
    var page: RailPage = .sessions { didSet { if page != oldValue { needsDisplay = true } } }
    var onFlip: ((RailPage) -> Void)?
    override var isFlipped: Bool { true }
    private var left: NSRect { NSRect(x: 6, y: 5, width: 20, height: 22) }
    private var right: NSRect { NSRect(x: 38, y: 5, width: 20, height: 22) }
    override func draw(_ dirtyRect: NSRect) {
        func chevron(_ r: NSRect, _ dir: CGFloat, _ on: Bool) {
            let p = NSBezierPath(); p.lineWidth = 1.6; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: NSPoint(x: r.midX - 2 * dir, y: r.midY - 4)); p.line(to: NSPoint(x: r.midX + 2 * dir, y: r.midY)); p.line(to: NSPoint(x: r.midX - 2 * dir, y: r.midY + 4))
            Theme.dynamic(on ? .text : .textFaint).setStroke(); p.stroke()
        }
        chevron(left, -1, page == .menu); chevron(right, 1, page == .sessions)   // the arrow that goes somewhere is the bright one
        for (i, p) in [RailPage.sessions, .menu].enumerated() {
            Theme.dynamic(p == page ? .text : .textFaint).setFill()
            NSBezierPath(ovalIn: NSRect(x: 32 - 8 + CGFloat(i) * 11 - 2.5 + 2.5, y: 13.5, width: 5, height: 5)).fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if left.contains(p) { onFlip?(.sessions) } else if right.contains(p) { onFlip?(.menu) }
        else if p.x < 32 { onFlip?(.sessions) } else { onFlip?(.menu) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func accessibilityChildren() -> [Any]? {
        [("Sessions page", RailPage.sessions, left), ("Menu page", .menu, right)].map { label, _, r in
            let e = NSAccessibilityElement(); e.setAccessibilityRole(.button); e.setAccessibilityLabel(label); e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(r); return e
        }
    }
}

/// The scrolling column of compact session items.
final class RailSessionsPane: NSView, NSViewToolTipOwner {
    var sessions: [RailSession] = [] { didSet { rows = RailGeometry.rows(groups: sessions.map(\.splitGroup)); offset = RailGeometry.clamp(offset: offset, content: rows.height, viewport: bounds.height); refreshToolTips(); needsDisplay = true } }
    var selectedID: UInt64? { didSet { if selectedID != oldValue { revealSelected(); needsDisplay = true } } }
    var onPick: ((UInt64) -> Void)?
    private var rows: (rows: [RailGeometry.Row], height: CGFloat) = ([], 0)
    private(set) var offset: CGFloat = 0 { didSet { if offset != oldValue { refreshToolTips(); needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var isHidden: Bool { didSet { if !isHidden { refreshToolTips() } } }

    private func rect(_ r: RailGeometry.Row) -> NSRect { NSRect(x: 8, y: r.y - offset, width: 48, height: RailGeometry.itemHeight) }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); offset = RailGeometry.clamp(offset: offset, content: rows.height, viewport: s.height); refreshToolTips() }
    func revealSelected() {
        guard let i = sessions.firstIndex(where: { $0.id == selectedID }), rows.rows.indices.contains(i) else { return }
        offset = RailGeometry.reveal(rowY: rows.rows[i].y, offset: offset, viewport: bounds.height)
    }
    func debugState() -> String { "items=\(sessions.count) offset=\(Int(offset)) content=\(Int(rows.height)) viewport=\(Int(bounds.height)) selected=\(selectedID.map(String.init) ?? "-")" }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for r in rows.rows {
            let s = sessions[r.index], f = rect(r)
            guard f.maxY > 0, f.minY < bounds.height else { continue }
            if let g = r.group {   // a thin bracket along the members of one split
                let first = r.index == 0 || sessions[r.index - 1].splitGroup != g, last = r.index == sessions.count - 1 || sessions[r.index + 1].splitGroup != g
                let top = f.minY + (first ? 6 : -RailGeometry.itemGap), bottom = f.maxY - (last ? 6 : -RailGeometry.itemGap)
                Theme.dynamic(.borderStrong).setFill(); NSBezierPath(roundedRect: NSRect(x: 2, y: top, width: 2, height: bottom - top), xRadius: 1, yRadius: 1).fill()
            }
            let p = NSBezierPath(roundedRect: f, xRadius: 10, yRadius: 10)
            if s.waiting { Theme.dynamic(.warningCardBg).setFill(); p.fill(); p.lineWidth = 1.5; Theme.dynamic(.warningBorder).setStroke(); p.stroke() }
            else if s.id == selectedID { Theme.dynamic(.bgRailActive).setFill(); p.fill() }
            let sel = s.id == selectedID
            ctx.saveGState(); ctx.translateBy(x: f.midX - 8, y: f.minY + 8); ThemeIcons.draw(s.kindIcon, in: ctx, size: 16, color: s.kindColor); ctx.restoreGState()
            let dot = NSRect(x: f.midX + 5, y: f.minY + 5, width: 9, height: 9)   // status dot on the icon's corner, with a rail-coloured edge
            Theme.dynamic(sel && !s.waiting ? .bgRailActive : .bgChrome).setFill(); NSBezierPath(ovalIn: dot).fill()
            s.stateColor.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: 1.75, dy: 1.75)).fill()
            let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(10, sel ? .semibold : .medium), .foregroundColor: Theme.dynamic(sel ? .text : .textMuted)]
            let w = (s.monogram as NSString).size(withAttributes: a).width
            (s.monogram as NSString).draw(at: NSPoint(x: f.midX - w / 2, y: f.minY + 31), withAttributes: a)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let r = rows.rows.first(where: { rect($0).contains(p) }) { onPick?(sessions[r.index].id) }
    }
    override func scrollWheel(with event: NSEvent) {
        offset = RailGeometry.clamp(offset: offset - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8), content: rows.height, viewport: bounds.height)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    private func refreshToolTips() {
        removeAllToolTips()
        guard !isHidden else { return }
        for r in rows.rows { let f = rect(r).intersection(bounds); if !f.isEmpty { addToolTip(f, owner: self, userData: UnsafeMutableRawPointer(bitPattern: r.index + 1)) } }
    }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        let i = Int(bitPattern: userData) - 1
        return sessions.indices.contains(i) ? sessions[i].tooltip : ""
    }
    override func accessibilityChildren() -> [Any]? {
        rows.rows.map { r in
            let e = NSAccessibilityElement(); e.setAccessibilityRole(.button); e.setAccessibilityLabel(sessions[r.index].tooltip.replacingOccurrences(of: "\n", with: ", "))
            e.setAccessibilityParent(self); e.setAccessibilityFrameInParentSpace(rect(r)); return e
        }
    }
}

// MARK: - Wiring

extension MainController {
    /// Rebuilds what the rail shows from the Agents list (same order, same split groups).
    func syncRail() {
        guard let f = frameView else { return }
        let groups = splitModel.groups
        let items = agentsPanel.onScreenSessions.map { s -> RailSession in
            let (icon, color) = s.kindIconChoice
            let status = s.statusLine ?? (s.exited != nil || s.screen == nil ? (s.state.text == "Shell" ? "Idle" : s.state.text) : s.state.text)
            let tip = [s.name, status, s.cwd.abbreviatingHome(store.home)].joined(separator: "\n") + (s.openedByTooltip.map { "\n" + $0 } ?? "")
            return RailSession(id: s.id, name: s.name, monogram: RailMonogram.make(s.name), tooltip: tip, waiting: agentsPanel.group(of: s) == .waiting,
                               kindIcon: icon, kindColor: color, stateColor: s.state.color, splitGroup: groups.first { $0.keys.contains(SplitModel.key(s)) }?.id)
        }
        f.rail.pages = railPages
        f.rail.sessionItems = items
        f.rail.selectedID = store.selected?.id
    }

    /// A click on a rail item: the same as clicking the card in the Agents list.
    func railPick(_ id: UInt64) {
        guard let s = store.sessions.first(where: { $0.id == id }) else { return }
        agentsPanel.onSelect?(s)
    }

    @discardableResult func railFlip(_ p: RailPage) -> Bool {
        guard railPages.flip(to: p) else { return false }
        return true
    }

    /// ⌃⌥↑ / ⌃⌥↓: the previous / next session as listed on screen (column open or closed).
    @discardableResult func stepListedSession(_ d: Int) -> Bool {
        agentsPanel.reloadNow()
        let listed = agentsPanel.onScreenSessions
        guard let id = SessionStep.neighbor(of: store.selected?.id, in: listed.map(\.id), delta: d) else { return false }
        railPick(id); return true
    }

    @objc func railShowSessionsPage() { railFlip(.sessions) }
    @objc func railShowMenuPage() { railFlip(.menu) }
    @objc func previousListedSession() { stepListedSession(-1) }
    @objc func nextListedSession() { stepListedSession(1) }
}

extension ShortcutRouter {
    /// ⌃⌥ + arrow (RailKeys). Flips only count while the column is closed, so with it open ← → pass through to whoever has focus.
    func performRail(_ a: RailKeyAction) -> Bool {
        switch a {
        case .flip(let p): return controller.railFlip(p)
        case .step(let d): return controller.stepListedSession(d)
        }
    }
}
