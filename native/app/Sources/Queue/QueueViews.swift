// The two custom-drawn views of the Queue page: the commit graph (draws only the rows in view, so 5,000
// commits scroll without cost) and the Kanban board (cards dragged between columns, keyboard-movable).

import AppKit

// MARK: Shared look (today's Muya: src/components/QueuePage.tsx, PrdBoard.tsx, BranchDag)

enum QT {
    /// The violet of the page icons and section labels: indigo-500 (dark) / -600 (light), src/styles/tokens.css:25-26.
    static let indigo = NSColor(name: nil) { ap in ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ThemeRaw.indigo500 : ThemeRaw.indigo600 }

    /// lucide icon paths (24x24 viewBox) for the glyphs the theme icon set does not have.
    static let gitBranch = ["M6 3v12", "M15 6a3 3 0 1 0 6 0 3 3 0 1 0-6 0", "M3 18a3 3 0 1 0 6 0 3 3 0 1 0-6 0", "M18 9a9 9 0 0 1-9 9"]
    static let pullRequest = ["M15 18a3 3 0 1 0 6 0 3 3 0 1 0-6 0", "M3 6a3 3 0 1 0 6 0 3 3 0 1 0-6 0", "M13 6h3a2 2 0 0 1 2 2v7", "M6 9v12"]
    static let zap = ["M13 2 3 14h9l-1 8 10-12h-9l1-8z"]
    static let shieldCheck = ["M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z", "m9 12 2 2 4-4"]
    static let layers = ["m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z", "m22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65", "m22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65"]
    static let clock = ["M2 12a10 10 0 1 0 20 0 10 10 0 1 0-20 0", "M12 6v6l4 2"]
    static let alert = ["m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3", "M12 9v4", "M12 17h.01"]
    static let circleCheck = ["M2 12a10 10 0 1 0 20 0 10 10 0 1 0-20 0", "m9 12 2 2 4-4"]
    static let folder = ["M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"]
    static let fileCode = ["M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z", "M14 2v6h6", "m10 13-2 2 2 2", "m14 17 2-2-2-2"]

    /// Draws stroked 24x24 lucide paths at `origin` (flipped view coordinates) scaled to `size`.
    static func glyph(_ paths: [String], at origin: NSPoint, size: CGFloat, color: NSColor, stroke: CGFloat = 2) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y); ctx.scaleBy(x: size / 24, y: size / 24)
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(stroke); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for d in paths { ctx.addPath(SVGPath.parse(d)); ctx.strokePath() }
        ctx.restoreGState()
    }

    static func attrs(_ size: CGFloat, _ weight: NSFont.Weight = .regular, color: Theme.Token = .textMuted, kern: CGFloat = 0, italic: Bool = false, mono: Bool = true) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: mono ? ThemeFont.mono(size, weight) : ThemeFont.sans(size, weight), .foregroundColor: Theme.dynamic(color)]
        if kern != 0 { a[.kern] = kern }
        if italic { a[.obliqueness] = 0.2 }
        return a
    }
    static func draw(_ s: String, at p: NSPoint, _ a: [NSAttributedString.Key: Any]) { (s as NSString).draw(at: p, withAttributes: a) }
    static func width(_ s: String, _ a: [NSAttributedString.Key: Any]) -> CGFloat { ceil((s as NSString).size(withAttributes: a).width) }
}

/// A label with a fixed mono / kerned look whose text can be replaced without losing it.
final class MonoLabel: NSTextField {
    private let attrs: [NSAttributedString.Key: Any]
    private let upper: Bool
    var text: String { didSet { render() } }
    init(_ text: String = "", size: CGFloat = 11, weight: NSFont.Weight = .regular, color: Theme.Token = .textMuted, tint: NSColor? = nil, kern: CGFloat = 0, upper: Bool = false, italic: Bool = false, mono: Bool = true) {
        self.text = text; self.upper = upper
        var a = QT.attrs(size, weight, color: color, kern: kern, italic: italic, mono: mono)
        if let tint { a[.foregroundColor] = tint }
        attrs = a
        super.init(frame: .zero)
        isBezeled = false; drawsBackground = false; isEditable = false; isSelectable = false
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func render() { attributedStringValue = NSAttributedString(string: upper ? text.uppercased() : text, attributes: attrs) }
}

/// The page header band: violet icon, bold title, optional "N docs" pill, hairline under it. The tab switcher sits at the right.
final class QueueHeader: NSView {
    var icon: [String] = QT.pullRequest { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true } }
    var pill: String? { didSet { needsDisplay = true } }
    var border = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        QT.glyph(icon, at: NSPoint(x: 20, y: 16), size: 16, color: QT.indigo, stroke: 2)
        let ta = QT.attrs(14, .semibold, color: .text, mono: false)
        QT.draw(title, at: NSPoint(x: 44, y: 24.5 - (title as NSString).size(withAttributes: ta).height / 2), ta)
        if let pill {
            let pa = QT.attrs(10, .regular, color: .textFaint)
            let x = 44 + QT.width(title, ta) + 8, w = QT.width(pill, pa) + 16
            let r = NSRect(x: x, y: 15, width: w, height: 19)
            Theme.dynamic(.bgControl).setFill(); NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            QT.draw(pill, at: NSPoint(x: x + 8, y: r.midY - (pill as NSString).size(withAttributes: pa).height / 2), pa)
        }
        if border { Theme.dynamic(.border).setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One card of the queue list (a branch): bordered rounded box; the selected card gets the selection colours.
final class QueueRowView: NSTableRowView {
    override var isFlipped: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 4.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        Theme.dynamic(isSelected ? .bgSelected : .bgControl).setFill(); p.fill()
        Theme.dynamic(isSelected ? .borderSelected : .border).setStroke(); p.lineWidth = 1; p.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class QueueRowCell: NSTableCellView {
    let name = MonoLabel("", size: 12, weight: .bold, color: .text)
    let detail = MonoLabel("", size: 10, color: .textMuted)
    let pill = ThemedPill("", fg: Theme.dynamic(.textMuted))
    init() {
        super.init(frame: .zero)
        for v in [name, detail, pill] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), name.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            pill.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 10), pill.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor), detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
        ])
        textField = name
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The "BRANCH TOPOLOGY DAG" card: title band, the graph in between, the legend footer.
final class BranchCard: NSView {
    static let band: CGFloat = 36, footer: CGFloat = 28
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        Theme.dynamic(.bgInput).setFill(); p.fill()
        NSGraphicsContext.saveGraphicsState(); p.addClip()
        Theme.dynamic(.bgTableHead).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.band).fill()
        NSRect(x: 0, y: bounds.height - Self.footer, width: bounds.width, height: Self.footer).fill()
        Theme.dynamic(.border).setFill()
        NSRect(x: 0, y: Self.band - 1, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - Self.footer, width: bounds.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
        Theme.dynamic(.border).setStroke(); p.lineWidth = 1; p.stroke()
        QT.glyph(QT.gitBranch, at: NSPoint(x: 12, y: 11), size: 14, color: QT.indigo, stroke: 2)
        let ta = QT.attrs(10, .bold, color: .text, kern: 0.8)
        QT.draw("BRANCH TOPOLOGY DAG", at: NSPoint(x: 34, y: Self.band / 2 - 7), ta)
        let la = QT.attrs(8, .regular, color: .textMuted, kern: 0.5)
        let y = bounds.height - Self.footer / 2
        let items: [(String, Theme.Token)] = [("DEPLOYABLE", .success), ("DRAFTING", .accent), ("CONFLICT / AHEAD", .warning)]
        for (i, it) in items.enumerated() {
            let w = QT.width(it.0, la) + 12
            let x: CGFloat = i == 0 ? 12 : i == 1 ? (bounds.width - w) / 2 : bounds.width - 12 - w
            Theme.dynamic(it.1).setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: y - 3, width: 6, height: 6)).fill()
            QT.draw(it.0, at: NSPoint(x: x + 12, y: y - 5), la)
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// "PRODUCTION BRANCHES (PRD)" and friends: a coloured glyph + kerned label on the left, a count pill on the right.
final class BranchSection: NSView {
    let glyph: [String], label: String, tone: Theme.Token
    var count = 0 { didSet { needsDisplay = true } }
    init(glyph: [String], label: String, tone: Theme.Token) { self.glyph = glyph; self.label = label; self.tone = tone; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }
    override func draw(_ dirtyRect: NSRect) {
        let c = Theme.dynamic(tone)
        QT.glyph(glyph, at: NSPoint(x: 0, y: 8), size: 12, color: c, stroke: 2)
        let a = QT.attrs(10, .bold, color: tone, kern: 0.8)
        QT.draw(label, at: NSPoint(x: 16, y: bounds.midY - 7), a)
        let n = "\(count)", na = QT.attrs(9, .bold, color: tone)
        let w = QT.width(n, na) + 10, r = NSRect(x: bounds.width - w, y: bounds.midY - 7, width: w, height: 14)
        c.withAlphaComponent(0.15).setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        QT.draw(n, at: NSPoint(x: r.minX + 5, y: r.midY - (n as NSString).size(withAttributes: na).height / 2), na)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: Commit graph

final class DagView: NSView {
    static let rowHeight: CGFloat = 24
    static let laneWidth: CGFloat = 14
    private(set) var commits: [CommitNode] = []
    private(set) var rows: [DagRow] = []
    private(set) var selected = -1
    /// Rows drawn since creation: the benchmark checks that scrolling really paints.
    private(set) var rowsDrawn = 0
    private(set) var maxLanes = 1
    var onSelect: ((Int) -> Void)?
    private var textX: CGFloat = 40

    private static let colors: [NSColor] = DagLayout.palette.map { RGB($0).color }
    private static let subjectAttrs = QT.attrs(11, color: .text, mono: false)
    private static let metaAttrs = QT.attrs(10, color: .textMuted)
    private static let refAttrs = QT.attrs(9, .bold, color: .text)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Commit graph")
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(commits c: [CommitNode], laneRows r: [DagRow]) {
        commits = c; rows = r
        maxLanes = min(16, max(1, r.reduce(1) { max($0, $1.laneCount) }))
        textX = CGFloat(maxLanes) * Self.laneWidth + 22
        selected = c.isEmpty ? -1 : min(max(selected, 0), c.count - 1)
        setFrameSize(NSSize(width: max(frame.width, 600), height: CGFloat(c.count) * Self.rowHeight + 8))
        needsDisplay = true
        updateAccessibilityValue()
        onSelect?(selected)
    }

    private func x(_ lane: Int) -> CGFloat { CGFloat(min(lane, 15)) * Self.laneWidth + 14 }
    private func color(_ lane: Int) -> NSColor { Self.colors[lane % Self.colors.count] }

    override func draw(_ dirty: NSRect) {
        guard !rows.isEmpty else { return }
        let h = Self.rowHeight
        let first = max(0, Int(dirty.minY / h) - 1), last = min(rows.count - 1, Int(dirty.maxY / h) + 1)
        guard first <= last else { return }
        if first <= selected, selected <= last {
            Theme.dynamic(.bgSelected).setFill()
            NSRect(x: 0, y: CGFloat(selected) * h, width: bounds.width, height: h).fill()
        }
        rowsDrawn += last - first + 1
        for i in first...last {
            let r = rows[i], top = CGFloat(i) * h, mid = top + h / 2, bottom = top + h
            let nx = x(r.lane)
            let path = NSBezierPath()
            path.lineWidth = 1.6
            func stroke(_ lane: Int, _ from: NSPoint, _ to: NSPoint) {
                color(lane).setStroke()
                path.removeAllPoints(); path.move(to: from); path.line(to: to); path.stroke()
            }
            for l in r.through { stroke(l, NSPoint(x: x(l), y: top), NSPoint(x: x(l), y: bottom)) }
            for l in r.incoming { stroke(l, NSPoint(x: x(l), y: top), NSPoint(x: nx, y: mid)) }
            for l in r.outgoing { stroke(l, NSPoint(x: nx, y: mid), NSPoint(x: x(l), y: bottom)) }
            let merge = commits[i].parents.count > 1
            let dot = NSRect(x: nx - 4, y: mid - 4, width: 8, height: 8)
            Theme.dynamic(.bgInput).setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            color(r.lane).setFill(); NSBezierPath(ovalIn: merge ? dot.insetBy(dx: 1, dy: 1) : dot).fill()
            if merge { color(r.lane).setStroke(); let ring = NSBezierPath(ovalIn: dot); ring.lineWidth = 1.5; ring.stroke() }
            // Text: ref pills, subject, then short sha and author at the right.
            var tx = textX
            let c = commits[i]
            for ref in c.refs.prefix(3) {
                let s = NSAttributedString(string: ref, attributes: Self.refAttrs)
                let w = s.size().width + 10
                let pill = NSRect(x: tx, y: mid - 8, width: w, height: 16)
                color(r.lane).withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
                s.draw(at: NSPoint(x: tx + 5, y: mid - s.size().height / 2))
                tx += w + 6
            }
            let metaW: CGFloat = 170
            let sub = NSAttributedString(string: c.subject, attributes: Self.subjectAttrs)
            let avail = max(0, bounds.width - metaW - tx - 12)
            sub.draw(with: NSRect(x: tx, y: mid - 8, width: avail, height: 16), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            NSAttributedString(string: "\(c.short)  \(c.author)", attributes: Self.metaAttrs)
                .draw(with: NSRect(x: bounds.width - metaW, y: mid - 7, width: metaW - 12, height: 14), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }
    }

    // MARK: Selection and keys

    func select(_ i: Int, scroll: Bool = true) {
        guard !commits.isEmpty else { return }
        let n = min(max(i, 0), commits.count - 1)
        guard n != selected else { return }
        let old = selected
        selected = n
        for r in [old, n] where r >= 0 { setNeedsDisplay(NSRect(x: 0, y: CGFloat(r) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)) }
        if scroll { scrollToVisible(NSRect(x: 0, y: CGFloat(n) * Self.rowHeight - 4, width: 10, height: Self.rowHeight + 8)) }
        updateAccessibilityValue()
        onSelect?(n)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        select(Int(convert(event.locationInWindow, from: nil).y / Self.rowHeight), scroll: false)
    }

    override func keyDown(with event: NSEvent) {
        let page = max(1, Int((enclosingScrollView?.contentView.bounds.height ?? 400) / Self.rowHeight) - 1)
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 125: select(cmd ? commits.count - 1 : selected + 1)
        case 126: select(cmd ? 0 : selected - 1)
        case 121: select(selected + page)
        case 116: select(selected - page)
        case 115: select(0)
        case 119: select(commits.count - 1)
        default: super.keyDown(with: event)
        }
    }

    private func updateAccessibilityValue() {
        guard selected >= 0, selected < commits.count else { setAccessibilityValue("No commits"); return }
        let c = commits[selected]
        setAccessibilityValue("Commit \(selected + 1) of \(commits.count): \(c.short) by \(c.author): \(c.subject)")
    }

    // MARK: Benchmark

    /// Scrolls through the whole log in `step`-pixel jumps, drawing every frame; returns frame times in ms.
    func benchmark(step: CGFloat = 72) -> [Double] {
        guard let sv = enclosingScrollView, !commits.isEmpty else { return [] }
        var times: [Double] = []
        let maxY = max(0, frame.height - sv.contentView.bounds.height)
        var y: CGFloat = 0
        while y < maxY {
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
            // A FULL repaint of the visible area every frame (what a scroll blit saves is not counted), into
            // a bitmap, so it paints even when the window is hidden or covered.
            let r = visibleRect
            guard let rep = bitmapImageRepForCachingDisplay(in: r) else { break }
            let t0 = DispatchTime.now().uptimeNanoseconds
            cacheDisplay(in: r, to: rep)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            y += step
        }
        sv.contentView.scroll(to: .zero); sv.reflectScrolledClipView(sv.contentView)
        return times
    }
}

// MARK: Kanban board

final class KanbanView: NSView {
    static let headerHeight: CGFloat = 44, cardHeight: CGFloat = 64, gap: CGFloat = 8, pad: CGFloat = 16, columnWidth: CGFloat = 288, edge: CGFloat = 17
    /// Width of the four fixed-width columns plus the gutters; a narrower window scrolls sideways (today's board does too).
    static let minWidth: CGFloat = edge * 2 + columnWidth * 4 + pad * 3
    private(set) var board = KanbanBoard(cards: [])
    private(set) var selectedSlug: String?
    var onMove: ((String, KanbanColumn) -> Void)?
    private var cwd = ""
    private var dragSlug: String?, dragStart = NSPoint.zero, dragPoint = NSPoint.zero, dragging = false
    private var dropColumn: KanbanColumn?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(NSSize(width: max(newSize.width, Self.minWidth), height: newSize.height)) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Kanban board")
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(board b: KanbanBoard, cwd dir: String, keepSelection: String? = nil) {
        board = b; cwd = dir
        if let keepSelection { selectedSlug = keepSelection }
        if selectedSlug == nil || !b.cards.contains(where: { $0.slug == selectedSlug }) { selectedSlug = KanbanColumn.allCases.lazy.compactMap { b.cards(in: $0).first }.first?.slug }
        let rowsMax = KanbanColumn.allCases.map { b.cards(in: $0).count }.max() ?? 0
        let h = Self.headerHeight + Self.edge * 2 + 16 + CGFloat(rowsMax) * (Self.cardHeight + Self.gap)
        setFrameSize(NSSize(width: frame.width, height: max(h, enclosingScrollView?.contentView.bounds.height ?? h)))
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) { super.resize(withOldSuperviewSize: oldSize); needsDisplay = true }

    // MARK: Geometry

    func columnFrame(_ c: KanbanColumn) -> NSRect {
        let i = CGFloat(KanbanColumn.allCases.firstIndex(of: c) ?? 0)
        return NSRect(x: Self.edge + i * (Self.columnWidth + Self.pad), y: Self.edge, width: Self.columnWidth, height: bounds.height - Self.edge * 2)
    }
    func cardFrame(_ slug: String) -> NSRect? {
        guard let card = board.cards.first(where: { $0.slug == slug }) else { return nil }
        let col = card.column, idx = board.cards(in: col).firstIndex(where: { $0.slug == slug }) ?? 0
        let cf = columnFrame(col)
        return NSRect(x: cf.minX + 10, y: cf.minY + Self.headerHeight + CGFloat(idx) * (Self.cardHeight + Self.gap), width: cf.width - 20, height: Self.cardHeight)
    }
    func card(at p: NSPoint) -> KanbanCard? { board.cards.first { cardFrame($0.slug)?.contains(p) == true } }
    func column(at p: NSPoint) -> KanbanColumn? { KanbanColumn.allCases.first { columnFrame($0).insetBy(dx: -Self.pad / 2, dy: 0).contains(NSPoint(x: p.x, y: columnFrame($0).midY)) } }

    // MARK: Drawing

    private static func tone(_ c: KanbanColumn) -> Theme.Token {
        switch c { case .draft: return .textFaint; case .active: return .accent; case .review: return .warning; case .done: return .success }
    }
    private static func glyph(_ c: KanbanColumn) -> [String] {
        switch c { case .draft: return QT.fileCode; case .active: return QT.clock; case .review: return QT.alert; case .done: return QT.circleCheck }
    }

    override func draw(_ dirty: NSRect) {
        for col in KanbanColumn.allCases {
            let cf = columnFrame(col)
            let isDrop = dragging && dropColumn == col
            let bg = NSBezierPath(roundedRect: cf.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            Theme.dynamic(.bgApp).setFill(); bg.fill()
            // The coloured 2px top edge, clipped to the rounded column.
            NSGraphicsContext.saveGraphicsState(); bg.addClip()
            Theme.dynamic(Self.tone(col)).setFill(); NSRect(x: cf.minX, y: cf.minY, width: cf.width, height: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            if isDrop { Theme.dynamic(.accent).withAlphaComponent(0.10).setFill(); bg.fill() }
            (isDrop ? Theme.dynamic(.accent) : Theme.dynamic(.border)).setStroke(); bg.lineWidth = isDrop ? 1.5 : 1; bg.stroke()
            QT.glyph(Self.glyph(col), at: NSPoint(x: cf.minX + 12, y: cf.minY + 17), size: 12, color: Theme.dynamic(.textMuted), stroke: 2)
            QT.draw(col.title.uppercased(), at: NSPoint(x: cf.minX + 30, y: cf.minY + 16), QT.attrs(10, .bold, color: .text, kern: 0.6, mono: false))
            let list = board.cards(in: col), n = "\(list.count)", na = QT.attrs(9, .regular, color: .textFaint)
            let w = max(20, QT.width(n, na) + 12), pr = NSRect(x: cf.maxX - 12 - w, y: cf.minY + 14, width: w, height: 18)
            Theme.dynamic(.bgControl).setFill(); NSBezierPath(roundedRect: pr, xRadius: 9, yRadius: 9).fill()
            QT.draw(n, at: NSPoint(x: pr.midX - QT.width(n, na) / 2, y: pr.midY - (n as NSString).size(withAttributes: na).height / 2), na)
            if list.isEmpty {
                let ea = QT.attrs(10, .regular, color: .textFaint, italic: true)
                QT.draw("No PRDs", at: NSPoint(x: cf.midX - QT.width("No PRDs", ea) / 2, y: cf.minY + 66), ea)
            }
            for c in list where !(dragging && c.slug == dragSlug) { if let f = cardFrame(c.slug) { drawCard(c, in: f, ghost: false) } }
        }
        if dragging, let s = dragSlug, let c = board.cards.first(where: { $0.slug == s }) {
            let w = Self.columnWidth - 20
            drawCard(c, in: NSRect(x: dragPoint.x - w / 2, y: dragPoint.y - Self.cardHeight / 2, width: w, height: Self.cardHeight), ghost: true)
        }
    }

    private func drawCard(_ c: KanbanCard, in f: NSRect, ghost: Bool) {
        let sel = c.slug == selectedSlug
        let path = NSBezierPath(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        if ghost { let sh = NSShadow(); sh.shadowBlurRadius = 10; sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowOffset = NSSize(width: 0, height: -3); sh.set() }
        Theme.dynamic(sel ? .bgSelected : .bgControl).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        Theme.dynamic(sel ? .borderSelected : .border).setStroke()
        path.lineWidth = sel && window?.firstResponder === self ? 2 : 1; path.stroke()
        let ta = QT.attrs(13, .semibold, color: .text, mono: false)
        NSAttributedString(string: c.title, attributes: ta)
            .draw(with: NSRect(x: f.minX + 10, y: f.minY + 9, width: f.width - 20, height: 32), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        NSAttributedString(string: c.status.isEmpty ? "no status" : c.status, attributes: QT.attrs(10, color: .textMuted))
            .draw(with: NSRect(x: f.minX + 10, y: f.maxY - 20, width: f.width - 20, height: 14), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let c = card(at: p) { selectedSlug = c.slug; dragSlug = c.slug; dragStart = p; dragPoint = p } else { dragSlug = nil }
        dragging = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragSlug != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragging, hypot(p.x - dragStart.x, p.y - dragStart.y) > 4 { dragging = true }
        guard dragging else { return }
        dragPoint = p; dropColumn = column(at: p)
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragging = false; dragSlug = nil; dropColumn = nil; needsDisplay = true }
        // The last drag position, not the up event's: autoscrolling a wide board moves the view under a fixed window point.
        guard dragging, let s = dragSlug, let col = column(at: dragPoint) else { return }
        onMove?(s, col)
    }

    // MARK: Keyboard

    func moveSelection(dx: Int, dy: Int) {
        guard let s = selectedSlug, let cur = board.cards.first(where: { $0.slug == s }) else { return }
        var col = cur.column
        var idx = board.cards(in: col).firstIndex(where: { $0.slug == s }) ?? 0
        if dy != 0 { idx += dy }
        if dx != 0 {
            var c = col
            repeat { c = KanbanBoard.neighbour(of: c, step: dx) } while board.cards(in: c).isEmpty && c != KanbanBoard.neighbour(of: c, step: dx)
            if !board.cards(in: c).isEmpty { col = c }
        }
        let list = board.cards(in: col)
        guard !list.isEmpty else { return }
        selectedSlug = list[min(max(idx, 0), list.count - 1)].slug
        if let f = selectedSlug.flatMap(cardFrame) { scrollToVisible(f.insetBy(dx: 0, dy: -8)) }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }

    override func keyDown(with event: NSEvent) {
        let opt = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 123 where opt: moveSelectedCard(step: -1)
        case 124 where opt: moveSelectedCard(step: 1)
        case 123: moveSelection(dx: -1, dy: 0)
        case 124: moveSelection(dx: 1, dy: 0)
        case 125: moveSelection(dx: 0, dy: 1)
        case 126: moveSelection(dx: 0, dy: -1)
        default: super.keyDown(with: event)
        }
    }

    func moveSelectedCard(step: Int) {
        guard let s = selectedSlug, let c = board.cards.first(where: { $0.slug == s }) else { return }
        let target = KanbanBoard.neighbour(of: c.column, step: step)
        if target != c.column { onMove?(s, target) }
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        board.cards.map { c in
            let el = NSAccessibilityElement()
            el.setAccessibilityParent(self)
            el.setAccessibilityRole(.button)
            el.setAccessibilityLabel("\(c.title), \(c.column.title)")
            el.setAccessibilityFrameInParentSpace(cardFrame(c.slug) ?? .zero)
            el.setAccessibilitySelected(c.slug == selectedSlug)
            el.setAccessibilityCustomActions(KanbanColumn.allCases.filter { $0 != c.column }.map { col in
                NSAccessibilityCustomAction(name: "Move to \(col.title)") { [weak self] in self?.onMove?(c.slug, col); return true }
            })
            return el
        }
    }
}


// MARK: Queue page lists (QUEUE and TRACKED PROJECTS)

/// Today's small indigo action button of the Queue page (mono 11px, radius 5).
final class IndigoButton: NSControl {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    let plus: Bool
    var onClick: (() -> Void)?
    private var pressed = false
    init(_ title: String, plus: Bool = false) {
        self.title = title; self.plus = plus
        super.init(frame: .zero)
        setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var attrs: [NSAttributedString.Key: Any] { var a = QT.attrs(11, .bold, color: .text, mono: true); a[.foregroundColor] = NSColor.white; return a }
    override var intrinsicContentSize: NSSize { NSSize(width: QT.width(title, attrs) + 22 + (plus ? 16 : 0), height: 26) }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let r = bounds.insetBy(dx: 0.5, dy: 0.5), p = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        (dark ? ThemeRaw.indigo500 : ThemeRaw.indigo600).setFill(); p.fill()
        (dark ? ThemeRaw.indigo400 : ThemeRaw.indigo700).setStroke(); p.lineWidth = 1; p.stroke()
        if pressed { NSColor.black.withAlphaComponent(0.15).setFill(); p.fill() }
        let a = attrs, tw = QT.width(title, a), total = tw + (plus ? 16 : 0)
        var x = (bounds.width - total) / 2
        if plus {
            QT.glyph(["M5 12h14", "M12 5v14"], at: NSPoint(x: x, y: bounds.midY - 5.5), size: 11, color: .white, stroke: 2.5); x += 16
        }
        QT.draw(title, at: NSPoint(x: x, y: bounds.midY - (title as NSString).size(withAttributes: a).height / 2), a)
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; needsDisplay = true
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            pressed = bounds.contains(convert(e.locationInWindow, from: nil)); needsDisplay = true
            if e.type == .leftMouseUp { break }
        }
        let fire = pressed; pressed = false; needsDisplay = true
        if fire { onClick?() }
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 36 || event.keyCode == 49, isEnabled { onClick?() } else { super.keyDown(with: event) } }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One project card, as in today's Queue page: name + branch, then path, ahead/behind, changed, uncommitted, age;
/// "+ Add to queue" at the right (or Push / Merge / x once the project is queued).
final class ProjectCard: NSView {
    static let height: CGFloat = 58
    let project: TrackedProject
    let queued: Bool
    /// nil = still checking.
    var mergeClean: Bool? { didSet { needsDisplay = true } }
    let add = IndigoButton("Add to queue", plus: true)
    let push = IndigoButton("Push")
    let merge = ThemedButton("Merge")
    let remove = ThemedButton("×")
    init(_ p: TrackedProject, queued: Bool) {
        project = p; self.queued = queued
        super.init(frame: .zero)
        for b in queued ? [push, merge, remove] : [add] { addSubview(b) }
        add.setAccessibilityLabel("Add \(p.name) to the queue"); push.setAccessibilityLabel("Push \(p.branch)")
        merge.setAccessibilityLabel("Merge \(p.branch) into \(p.base)"); remove.setAccessibilityLabel("Remove \(p.name) from the queue")
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var x = bounds.width - 12
        for b in (queued ? [remove, push, merge] : [add]) {
            let w = queued && b === remove ? 28 : b.intrinsicContentSize.width
            x -= w; b.frame = NSRect(x: x, y: (bounds.height - 26) / 2, width: w, height: 26); x -= 6
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        Theme.dynamic(.bgControl).setFill(); path.fill()
        Theme.dynamic(.border).setStroke(); path.lineWidth = 1; path.stroke()
        let p = project
        let na = QT.attrs(12, .bold, color: .text)
        QT.draw(p.name, at: NSPoint(x: 13, y: 11), na)
        var x = 13 + QT.width(p.name, na) + 10
        let ba = QT.attrs(10, color: .textMuted)
        if p.isGit {
            QT.glyph(QT.gitBranch, at: NSPoint(x: x, y: 13.5), size: 11, color: Theme.dynamic(.textMuted), stroke: 2)
            let label = queued ? "\(p.branch) → \(p.base)" : p.branch
            QT.draw(label, at: NSPoint(x: x + 14, y: 12), ba); x += 14 + QT.width(label, ba) + 8
            if queued {
                let (t, tone): (String, Theme.Token) = mergeClean == nil ? ("checking…", .textFaint) : mergeClean! ? ("READY", .successText) : ("CONFLICT", .dangerText)
                let pa = QT.attrs(8, .bold, color: tone)
                if mergeClean == nil { QT.draw(t, at: NSPoint(x: x, y: 14), pa) } else {
                    let w = QT.width(t, pa) + 12, pr = NSRect(x: x, y: 11, width: w, height: 16)
                    Theme.dynamic(mergeClean! ? .successBg : .dangerPillBg).setFill(); NSBezierPath(roundedRect: pr, xRadius: 4, yRadius: 4).fill()
                    QT.draw(t, at: NSPoint(x: pr.minX + 6, y: pr.midY - 5), pa)
                }
            }
        } else {
            QT.draw("not a git repository", at: NSPoint(x: x, y: 12), ba)
        }
        // Second line.
        var cx: CGFloat = 13
        let y: CGFloat = 35
        if !queued {
            QT.glyph(QT.folder, at: NSPoint(x: cx, y: y + 1), size: 11, color: Theme.dynamic(.textMuted), stroke: 2)
            let path = ProjectCard.short(p.path)
            let pw = min(280, QT.width(path, ba))
            NSAttributedString(string: path, attributes: ba).draw(with: NSRect(x: cx + 15, y: y, width: pw, height: 14), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            cx += 15 + pw + 14
        }
        guard p.isGit else { return }
        let ab = "↑\(p.ahead) ↓\(p.behind)"
        QT.draw(ab, at: NSPoint(x: cx, y: y), ba); cx += QT.width(ab, ba) + 14
        let ch = "\(p.changed) changed"
        QT.draw(ch, at: NSPoint(x: cx, y: y), ba); cx += QT.width(ch, ba) + 14
        if p.dirty > 0 {
            var wa = QT.attrs(10, color: .warning); wa[.underlineStyle] = NSUnderlineStyle.single.rawValue
            let d = "\(p.dirty) uncommitted"
            QT.draw(d, at: NSPoint(x: cx, y: y), wa); cx += QT.width(d, wa) + 14
        }
        if !queued {
            let age = p.age()
            QT.glyph(QT.clock, at: NSPoint(x: cx, y: y + 1.5), size: 10, color: Theme.dynamic(.textMuted), stroke: 2)
            QT.draw(age, at: NSPoint(x: cx + 13, y: y), ba)
        }
    }

    static func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The scrolling document of the Queue tab: QUEUE (n), its cards or the empty line, TRACKED PROJECTS (n), its cards.
final class QueueListView: NSView {
    let queueLabel = MonoLabel("", size: 10, weight: .bold, tint: QT.indigo, kern: 0.8, upper: true)
    let queueHint = MonoLabel("Queue is empty — add a project below.", size: 11, color: .textFaint, italic: true)
    let trackedLabel = MonoLabel("", size: 10, weight: .bold, color: .textMuted, kern: 0.8, upper: true)
    let trackedHint = MonoLabel("No projects — open a terminal in a project folder.", size: 11, color: .textFaint)
    private(set) var queueCards: [ProjectCard] = [], trackedCards: [ProjectCard] = []
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [queueLabel, queueHint, trackedLabel, trackedHint] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(queued: [ProjectCard], tracked: [ProjectCard]) {
        (queueCards + trackedCards).forEach { $0.removeFromSuperview() }
        queueCards = queued; trackedCards = tracked
        (queued + tracked).forEach(addSubview)
        queueLabel.text = "Queue (\(queued.count))"; trackedLabel.text = "Tracked projects (\(tracked.count))"
        queueHint.isHidden = !queued.isEmpty; trackedHint.isHidden = !tracked.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let x: CGFloat = 21, w = max(200, bounds.width - 41)
        var y: CGFloat = 11
        func put(_ v: NSView, _ h: CGFloat) { v.frame = NSRect(x: x, y: y, width: w, height: h) }
        put(queueLabel, 14); y += 30
        if queueCards.isEmpty { put(queueHint, 14); y += 45 } else {
            for c in queueCards { put(c, ProjectCard.height); y += ProjectCard.height + 8 }
            y += 22
        }
        put(trackedLabel, 14); y += 21
        if trackedCards.isEmpty { put(trackedHint, 14); y += 30 }
        for c in trackedCards { put(c, ProjectCard.height); y += ProjectCard.height + 8 }
        let h = y + 12
        if abs(frame.height - h) > 0.5, let sv = enclosingScrollView { setFrameSize(NSSize(width: frame.width, height: max(h, sv.contentView.bounds.height))) }
    }
}

/// The Branches tab's scrolling document: the topology card, the grouped branch list, its action bar and the status line.
final class BranchesDoc: NSView {
    private var card: NSView?, table: NSTableView?, bar: NSView?, detail: NSView?
    override var isFlipped: Bool { true }
    func install(card: NSView, table: NSTableView, bar: NSView, detail: NSView) {
        self.card = card; self.table = table; self.bar = bar; self.detail = detail
        for v in [card, table, bar, detail] { v.translatesAutoresizingMaskIntoConstraints = true; addSubview(v) }
    }
    func relayout() { needsLayout = true }
    override func layout() {
        super.layout()
        guard let card, let table, let bar, let detail else { return }
        let w = min(696, max(300, bounds.width - 40)), x = (bounds.width - w) / 2
        var y: CGFloat = 12
        card.frame = NSRect(x: x, y: y, width: w, height: 420); y += 432
        let n = table.numberOfRows
        let th = n > 0 ? table.rect(ofRow: n - 1).maxY : 0
        table.frame = NSRect(x: x, y: y, width: w, height: th)
        table.tableColumns.first?.width = w
        y += th + 8
        bar.frame = NSRect(x: x, y: y, width: w, height: 32); y += 40
        detail.frame = NSRect(x: x, y: y, width: w, height: 14); y += 26
        if let sv = enclosingScrollView, abs(frame.height - max(y, sv.contentView.bounds.height)) > 0.5 { setFrameSize(NSSize(width: frame.width, height: max(y, sv.contentView.bounds.height))) }
    }
}
