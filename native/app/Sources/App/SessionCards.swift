// WP6 — session cards of today's Muya's Sessions page: a bordered card per session with the name in mono, status pills, a
// meta row (folder · time · pid) and the action buttons on the card (.md / Attach / Resume / View …), plus the Terminal History
// list. Drawn views, no timers.

import AppKit

/// 22 px card button of today's Sessions page: mono 11, radius 5, optional 12 px icon (.md = download, Attach/Open = plug, Stop = square).
final class CardButton: NSControl {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var style: ThemedButton.Style = .ghost { didSet { needsDisplay = true } }
    var indigo = false { didSet { needsDisplay = true } }
    var iconPath: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onClick: (() -> Void)?
    private var pressed = false
    static let height: CGFloat = 22
    init(_ title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private static let labelFontCached = ThemeFont.mono(11, .semibold)
    private var labelFont: NSFont { Self.labelFontCached }
    private static func ap(_ dark: NSColor, _ light: NSColor) -> NSColor { NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light } }
    private var fg: NSColor { indigo ? Self.ap(ThemeRaw.indigo300, ThemeRaw.indigo700) : Theme.dynamic(style == .danger ? .dangerText : .text) }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: labelFont]).width) + 20 + (iconPath != nil ? 17 : 0), height: Self.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        var fill = Theme.dynamic(.bgControl), stroke = Theme.dynamic(.borderControl)
        if style == .danger { fill = Theme.dynamic(.dangerBtnBg); stroke = Theme.dynamic(.dangerBorder) }
        if indigo { fill = Self.ap(ThemeRaw.indigo950.withAlphaComponent(0.4), ThemeRaw.indigo50); stroke = Self.ap(ThemeRaw.indigo800, ThemeRaw.indigo200) }
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        fill.setFill(); p.fill(); stroke.setStroke(); p.lineWidth = 1; p.stroke()
        if pressed { NSColor.black.withAlphaComponent(0.12).setFill(); p.fill() }
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: fg]
        let ts = (title as NSString).size(withAttributes: attrs)
        var x = (bounds.width - ts.width - (iconPath != nil ? 17 : 0)) / 2
        if let iconPath, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState(); ctx.translateBy(x: x, y: (bounds.height - 12) / 2); ctx.scaleBy(x: 12 / 24, y: 12 / 24)
            ctx.setStrokeColor(fg.cgColor); ctx.setLineWidth(2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(SVGPath.parse(iconPath)); ctx.strokePath(); ctx.restoreGState(); x += 17
        }
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - ts.height) / 2), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) {
        pressed = true; needsDisplay = true
        let inside = { [self] in bounds.contains(convert(window!.mouseLocationOutsideOfEventStream, from: nil)) }
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            pressed = inside(); needsDisplay = true
            if e.type == .leftMouseUp { break }
        }
        let fire = pressed; pressed = false; needsDisplay = true
        if fire { onClick?() }
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 36 || event.keyCode == 49 { onClick?() } else { super.keyDown(with: event) } }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Status pill of a session card: mono 9 bold, radius 3, 15 px high.
final class CardPill: NSView {
    let text: String, fg: NSColor, bg: NSColor?, border: NSColor?
    init(_ text: String, fg: NSColor, bg: NSColor?, border: NSColor?) { self.text = text; self.fg = fg; self.bg = bg; self.border = border; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    private static let pillFont = ThemeFont.mono(8, .bold)
    private var attrs: [NSAttributedString.Key: Any] { [.font: Self.pillFont, .foregroundColor: fg, .kern: 0.3] }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil((text as NSString).size(withAttributes: attrs).width) + 12, height: 15) }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        if let bg { bg.setFill(); p.fill() }
        if let border { border.setStroke(); p.lineWidth = 1; p.stroke() }
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: 6, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class SessionCard: NSView {
    struct Pill { var text: String; var fg: Theme.Token; var bg: Theme.Token?; var border: Theme.Token? = nil; var dot: Theme.Token? = nil
        /// Tailwind colours of SessionsPage.tsx statusColor() (they are not design tokens in today's app): fg, bg, border.
        var raw: (NSColor, NSColor, NSColor)? = nil }
    var title = "" { didSet { needsDisplay = true } }
    var pills: [Pill] = [] { didSet { rebuild() } }
    var meta = "" { didSet { needsDisplay = true } }
    /// Live sessions: folder · branch icon + branch · clock icon + duration (today's meta row); wins over `meta`.
    var agentMeta: (folder: String, branch: String, duration: String)? { didSet { needsDisplay = true } }
    /// Past sessions: folder · clock icon + age · copy icon + session id (today's meta row); wins over `meta`.
    var histMeta: (folder: String, age: String, id: String)? { didSet { needsDisplay = true } }
    /// Small muted size after the name of a past session ("239 MB").
    var sizeText = "" { didSet { needsDisplay = true } }
    var model = "" { didSet { needsDisplay = true } }   // e.g. claude-sonnet-4.5, after the pills
    var snippet = "" { didSet { needsDisplay = true; needsLayout = true } }
    var selected = false { didSet { needsDisplay = true } }
    var attention = false { didSet { needsDisplay = true } }   // "needs you": amber card
    var actions: [(String, ThemedButton.Style, () -> Void)] = [] { didSet { rebuild() } }
    private static let folderPath = "M9 20H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H20a2 2 0 0 1 2 2v5M11 12a2 2 0 1 0 4 0 2 2 0 1 0-4 0M18 19c-2.8 0-5-2.2-5-5v8M18 19a2 2 0 1 0 4 0 2 2 0 1 0-4 0"   // lucide FolderGit2
    private static let branchPath = "M6 3v12M18 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM18 9a9 9 0 0 1-9 9"
    private static let copyPath = "M20 9h-9a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2v-9a2 2 0 0 0-2-2zM5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"
    private static let clockPath = "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zM12 6v6l4 2"
    private static let downloadPath = "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3"
    private static let plugPath = "M12 22v-5M9 8V2M15 8V2M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z"
    private static let stopPath = "M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z"

    private var pillViews: [CardPill] = [], buttons: [CardButton] = []
    private var needsYou: Pill?   // the dot pill ("NEEDS YOU") reads as a prefix before the name, like today's card
    static let height: CGFloat = 60
    static let snippetExtra: CGFloat = 16
    private static let nameFont = ThemeFont.mono(12, .bold)   // font-mono text-xs font-bold
    private static let prefixFont = ThemeFont.mono(9, .bold)
    private var prefixWidth: CGFloat { needsYou.map { ($0.text as NSString).size(withAttributes: [.font: Self.prefixFont, .kern: 0.3]).width + 14 } ?? 0 }

    override var isFlipped: Bool { true }
    private func rebuild() {
        (pillViews as [NSView] + buttons as [NSView]).forEach { $0.removeFromSuperview() }
        needsYou = pills.first { $0.dot != nil }
        pillViews = pills.filter { $0.dot == nil }.map { p in p.raw.map { CardPill(p.text, fg: $0.0, bg: $0.1, border: $0.2) } ?? CardPill(p.text, fg: Theme.dynamic(p.fg), bg: p.bg.map { Theme.dynamic($0) }, border: (p.border ?? p.bg).map { Theme.dynamic($0) }) }
        buttons = actions.map { a in
            let b = CardButton(a.0); b.style = a.1; b.onClick = a.2
            b.indigo = ["Attach", "Resume", "Open"].contains(a.0) && a.1 == .ghost
            b.iconPath = a.0 == ".md" ? Self.downloadPath : a.0 == "Stop" ? Self.stopPath : b.indigo ? Self.plugPath : nil
            return b
        }
        (pillViews as [NSView] + buttons as [NSView]).forEach(addSubview)
        needsLayout = true
    }
    private var rowCenter: CGFloat { 20 }
    override func layout() {
        super.layout()
        var x = bounds.width - 12
        let by = (SessionCard.height - CardButton.height) / 2
        for b in buttons.reversed() { let w = b.intrinsicContentSize.width; x -= w; b.frame = NSRect(x: x, y: by, width: w, height: CardButton.height); x -= 5 }
        let nameW = (title as NSString).size(withAttributes: [.font: Self.nameFont]).width
        var px = 13 + prefixWidth + min(nameW, max(60, x - 16 - 120)) + 8
        for p in pillViews { let w = p.intrinsicContentSize.width; p.frame = NSRect(x: px, y: rowCenter - 7.5, width: w, height: 15); px += w + 6 }
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5), p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)   // rounded-lg
        Theme.dynamic(attention ? .warningCardBg : .bgControl).setFill(); p.fill()   // bg-[var(--bg-control)]
        // border-neutral-200 / dark:border-neutral-700 (Tailwind literals of SessionsPage.tsx, not design tokens)
        let neutral = NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0x40 / 255.0, green: 0x40 / 255.0, blue: 0x40 / 255.0, alpha: 1) : NSColor(srgbRed: 0xE5 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 1) }
        (attention ? Theme.dynamic(.warningBorder) : selected ? Theme.dynamic(.borderSelected) : neutral).setStroke(); p.lineWidth = selected ? 1.5 : 1; p.stroke()
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail
        var nx: CGFloat = 13
        if let n = needsYou {
            Theme.dynamic(n.dot ?? n.fg).setFill(); NSBezierPath(ovalIn: NSRect(x: nx, y: rowCenter - 2.5, width: 5, height: 5)).fill()
            let pa: [NSAttributedString.Key: Any] = [.font: Self.prefixFont, .foregroundColor: Theme.dynamic(n.fg), .kern: 0.3]
            let sz = (n.text as NSString).size(withAttributes: pa)
            (n.text as NSString).draw(at: NSPoint(x: nx + 9, y: rowCenter - sz.height / 2), withAttributes: pa)
            nx += prefixWidth
        }
        let nameMax = max(60, (buttons.first?.frame.minX ?? bounds.width) - nx - 8 - pillViews.reduce(CGFloat(0)) { $0 + $1.frame.width + 6 })
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: Self.nameFont, .foregroundColor: Theme.dynamic(.text), .paragraphStyle: ps]
        (title as NSString).draw(in: NSRect(x: nx, y: rowCenter - 9, width: nameMax, height: 18), withAttributes: nameAttrs)
        let metaAttrs: [NSAttributedString.Key: Any] = [.font: ThemeFont.mono(10), .foregroundColor: Theme.dynamic(.textMuted), .paragraphStyle: ps]
        if !model.isEmpty {
            let mx = (pillViews.last?.frame.maxX ?? nx + (title as NSString).size(withAttributes: [.font: Self.nameFont]).width) + 8
            (model as NSString).draw(at: NSPoint(x: mx, y: rowCenter - 6), withAttributes: [.font: ThemeFont.mono(9), .foregroundColor: Theme.dynamic(.textFaint)])
        }
        if !sizeText.isEmpty {
            let mx = nx + min((title as NSString).size(withAttributes: [.font: Self.nameFont]).width, nameMax) + 6
            (sizeText as NSString).draw(at: NSPoint(x: mx, y: rowCenter - 6), withAttributes: [.font: ThemeFont.mono(9), .foregroundColor: Theme.dynamic(.textFaint)])
        }
        let my: CGFloat = 32   // top of the meta row (centre ≈ 39)
        if let m = histMeta, let ctx = NSGraphicsContext.current?.cgContext {
            var x: CGFloat = 13
            func seg(_ path: String?, _ text: String, maxW: CGFloat) {
                if let path {
                    ctx.saveGState(); ctx.translateBy(x: x, y: my + 1.5); ctx.scaleBy(x: 12 / 24, y: 12 / 24)
                    ctx.setStrokeColor(Theme.dynamic(.textMuted).cgColor); ctx.setLineWidth(2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                    ctx.addPath(SVGPath.parse(path)); ctx.strokePath(); ctx.restoreGState()
                }
                let lead: CGFloat = path == nil ? 0 : 16
                let w = min(maxW, (text as NSString).size(withAttributes: metaAttrs).width + 2)
                (text as NSString).draw(in: NSRect(x: x + lead, y: my, width: w, height: 15), withAttributes: metaAttrs); x += lead + w + 12
            }
            seg(nil, m.folder, maxW: max(80, bounds.width - 460)); seg(Self.clockPath, m.age, maxW: 90); seg(Self.copyPath, m.id, maxW: 300)
        } else if let m = agentMeta, let ctx = NSGraphicsContext.current?.cgContext {
            var x: CGFloat = 13
            func seg(_ path: String?, _ text: String, maxW: CGFloat) {
                if let path {
                    ctx.saveGState(); ctx.translateBy(x: x, y: my + 1.5); ctx.scaleBy(x: 12 / 24, y: 12 / 24)
                    ctx.setStrokeColor(Theme.dynamic(.textMuted).cgColor); ctx.setLineWidth(2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                    ctx.addPath(SVGPath.parse(path)); ctx.strokePath(); ctx.restoreGState()
                }
                let lead: CGFloat = path == nil ? 0 : 16
                let w = min(maxW, (text as NSString).size(withAttributes: metaAttrs).width + 2)
                (text as NSString).draw(in: NSRect(x: x + lead, y: my, width: w, height: 15), withAttributes: metaAttrs); x += lead + w + 12
            }
            seg(Self.folderPath, m.folder, maxW: max(80, bounds.width - 300)); seg(nil, m.branch, maxW: 140); seg(Self.clockPath, m.duration, maxW: 80)
        } else {
            (meta as NSString).draw(in: NSRect(x: 13, y: my, width: bounds.width - 26, height: 15), withAttributes: metaAttrs)
        }
        if !snippet.isEmpty {
            (snippet as NSString).draw(in: NSRect(x: 13, y: my + 17, width: bounds.width - 26, height: 15), withAttributes: [.font: ThemeFont.sans(11), .foregroundColor: Theme.dynamic(.accent), .paragraphStyle: ps])
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Section header: mono, tracked, e.g. "LIVE SESSIONS (7)" in green or "PAST SESSIONS (5)" in muted.
final class SessionSectionHeader: NSView {
    init(_ text: String, color: Theme.Token) {
        super.init(frame: .zero)
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: text, attributes: [.font: ThemeFont.mono(11, .bold), .kern: 0.8, .foregroundColor: Theme.dynamic(color)])
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0), l.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)])
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The "Terminal History" tab: one card per terminal with its command count and the last commands.
final class TermHistoryView: NSView {
    private let scroll = NSScrollView()
    private let doc = SessionsDocView()
    private let empty = NSTextField(labelWithString: "No terminal history yet.")
    var load: ((@escaping ([TermHistoryEntries]) -> Void) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = doc; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        empty.font = ThemeFont.sans(13); empty.textColor = Theme.dynamic(.textMuted); empty.alignment = .center
        addSubview(scroll); addSubview(empty)
        setAccessibilityLabel("Terminal history")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        empty.frame = NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
    }
    func reload() {
        load? { [weak self] list in self?.show(list) }
    }
    private func show(_ list: [TermHistoryEntries]) {
        doc.subviews.forEach { $0.removeFromSuperview() }
        empty.isHidden = !list.isEmpty
        let w = bounds.width, now = Date()
        var y: CGFloat = 8
        for e in list.sorted(by: { $0.updatedMs > $1.updatedMs }) {
            let c = SessionCard()
            c.title = e.name.isEmpty ? e.key : e.name
            c.meta = "\(e.cwd.isEmpty ? "—" : e.cwd) · \(e.total) command\(e.total == 1 ? "" : "s") · \(SessionsLogic.relativeTime(ms: Int64(e.updatedMs), now: now))"
            c.snippet = e.entries.suffix(2).map { "$ " + $0.cmd }.joined(separator: "   ")
            let ch = SessionCard.height + (c.snippet.isEmpty ? 0 : SessionCard.snippetExtra)
            c.frame = NSRect(x: 20, y: y, width: max(0, w - 40), height: ch); doc.addSubview(c); y += ch + 8
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(y, scroll.contentSize.height))
    }
}

final class SessionsDocView: NSView { override var isFlipped: Bool { true } }


/// The two tabs of today's Sessions page: an icon + label each, the active one on a soft pill with an indigo icon.
final class SessionTabs: NSControl {
    var titles: [String]
    var selected = 0 { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?
    private static let icons = ["M12 22v-5M9 8V2M15 8V2M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z", "m7 11 2-2-2-2M11 13h4M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z"]
    init(_ titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 40).isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.radioGroup); setAccessibilityLabel("Sessions view")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func accessibilityValue() -> Any? { titles.indices.contains(selected) ? titles[selected] : nil }
    private func frame(_ i: Int) -> NSRect {
        var x: CGFloat = 0
        for (j, t) in titles.enumerated() {
            let w = ceil((t as NSString).size(withAttributes: [.font: ThemeFont.sans(14, .semibold)]).width) + 52
            if j == i { return NSRect(x: x, y: 4, width: w, height: 32) }
            x += w + 4
        }
        return .zero
    }
    override func draw(_ dirtyRect: NSRect) {
        for (i, t) in titles.enumerated() {
            let r = frame(i), active = i == selected
            if active { Theme.dynamic(.bgSegment).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState(); ctx.translateBy(x: r.minX + 12, y: r.midY - 8); ctx.scaleBy(x: 16 / 24, y: 16 / 24)
                ctx.setStrokeColor((active ? ThemeRaw.indigo400 : Theme.dynamic(.textFaint)).cgColor); ctx.setLineWidth(2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                ctx.addPath(SVGPath.parse(Self.icons[min(i, 1)])); ctx.strokePath(); ctx.restoreGState()
            }
            let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(14, .semibold), .foregroundColor: Theme.dynamic(active ? .text : .textFaint)]
            let sz = (t as NSString).size(withAttributes: a)
            (t as NSString).draw(at: NSPoint(x: r.minX + 36, y: r.midY - sz.height / 2), withAttributes: a)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = titles.indices.first(where: { frame($0).contains(p) }), i != selected { selected = i; onChange?(i) }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
