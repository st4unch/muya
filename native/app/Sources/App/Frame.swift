// WP1 — the application frame of today's Muya: a 48px header (logo, sidebar toggle, workspace chip, ⌘K search field,
// CPU / RAM / clock, theme, notifications, inspector toggle), a 64px rail with the page switcher, and a 28px footer with
// the live status. Sizes and colours come from src/redesign/{ControlHeader,Rail,Footer}.tsx via Theme/ThemeMetric.
// Everything is event-driven except the small stats timer (5 s, tolerant, stopped while the window is hidden).

import AppKit

/// A solid token-coloured view with optional 1px hairlines.
class FillView: NSView {
    var fill: Theme.Token { didSet { needsDisplay = true } }
    var top = false, bottom = false, trailing = false
    init(_ fill: Theme.Token) { self.fill = fill; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.dynamic(fill).setFill(); bounds.fill()
        Theme.dynamic(.border).setFill()
        if top { NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
        if bottom { NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
        if trailing { NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill() }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// 32x32 bordered icon button (header buttons).
final class FrameIconButton: NSControl {
    var icon: ThemeIcon { didSet { if icon != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    private var pressed = false
    /// Borderless variant (the grid panel's expand button: 28x28, radius 6, transparent, --text-muted icon).
    var plain = false { didSet { needsDisplay = true } }
    init(_ icon: ThemeIcon, label: String) {
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        toolTip = label; setAccessibilityLabel(label); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
    override func draw(_ dirtyRect: NSRect) {
        if plain {
            if pressed { let q = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6); Theme.dynamic(.bgSegment).setFill(); q.fill() }
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState(); ctx.translateBy(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2)
            ThemeIcons.draw(icon, in: ctx, size: 16, color: Theme.dynamic(.textMuted)); ctx.restoreGState()
            return
        }
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Theme.dynamic(pressed ? .bgSegment : .bgControl).setFill(); p.fill()
        Theme.dynamic(.borderControl).setStroke(); p.lineWidth = 1; p.stroke()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState(); ctx.translateBy(x: 8, y: 8)
        ThemeIcons.draw(icon, in: ctx, size: 16, color: Theme.dynamic(.textSecondary)); ctx.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        pressed = true; needsDisplay = true
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            pressed = bounds.contains(convert(e.locationInWindow, from: nil)); needsDisplay = true
            if e.type == .leftMouseUp { break }
        }
        let fire = pressed; pressed = false; needsDisplay = true
        if fire { onClick?() }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// Plain label drawn in a token colour and one of the theme fonts.
final class FrameText: NSView {
    var text: String { didSet { guard text != oldValue else { return }; invalidateIntrinsicContentSize(); needsDisplay = true; superview?.needsLayout = true } }
    var font: NSFont, color: Theme.Token
    init(_ text: String, font: NSFont, color: Theme.Token) { self.text = text; self.font = font; self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    private var attrs: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: Theme.dynamic(color)] }
    override var intrinsicContentSize: NSSize { let s = (text as NSString).size(withAttributes: attrs); return NSSize(width: ceil(s.width), height: ceil(s.height)) }
    override func draw(_ dirtyRect: NSRect) {
        let s = (text as NSString).size(withAttributes: attrs)
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail   // a frame narrower than the text cuts it with … instead of running under its neighbours
        (text as NSString).draw(in: NSRect(x: 0, y: (bounds.height - s.height) / 2, width: bounds.width, height: s.height), withAttributes: attrs.merging([.paragraphStyle: ps]) { $1 })
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: Rail

enum RailItem: String, CaseIterable {
    case control = "Control", files = "Files", sessions = "Sessions", queue = "Queue", kanban = "Kanban", resources = "Resources", ssh = "SSH", schedules = "Schedules"
    var icon: ThemeIcon {
        switch self {
        case .control: return .controlRail; case .files: return .filesRail; case .sessions: return .sessionsRail; case .queue: return .queueRail
        case .kanban: return .kanbanRail; case .resources: return .resourcesRail; case .ssh: return .sshRail; case .schedules: return .schedulesRail
        }
    }
}

final class RailView: FillView {
    var active: RailItem? = .control { didSet { if active != oldValue { needsDisplay = true } } }
    var onSelect: ((RailItem) -> Void)?
    var onSettings: (() -> Void)?
    private let size = NSSize(width: 48, height: 48)
    init() { super.init(.bgChrome); trailing = true; setAccessibilityRole(.toolbar); setAccessibilityLabel("Main navigation") }
    required init?(coder: NSCoder) { fatalError() }

    private func frameFor(_ i: Int) -> NSRect { NSRect(x: 8, y: 8 + CGFloat(i) * 54, width: 48, height: 48) }
    private var settingsFrame: NSRect { NSRect(x: 8, y: bounds.height - 56, width: 48, height: 48) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        func cell(_ r: NSRect, _ icon: ThemeIcon, _ label: String?, active: Bool) {
            if active { let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10); Theme.dynamic(.bgRailActive).setFill(); p.fill() }
            let color = Theme.dynamic(active ? .text : .textMuted)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState(); ctx.translateBy(x: r.midX - 10, y: r.minY + (label == nil ? 14 : 7))
            ThemeIcons.draw(icon, in: ctx, size: 20, color: color); ctx.restoreGState()
            if let label {
                let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(10, active ? .semibold : .medium), .foregroundColor: color]
                let s = (label as NSString).size(withAttributes: a)
                (label as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.minY + 30), withAttributes: a)
            }
        }
        for (i, item) in RailItem.allCases.enumerated() { cell(frameFor(i), item.icon, item.rawValue, active: item == active) }
        cell(settingsFrame, .settingsRail, nil, active: false)
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if settingsFrame.contains(p) { onSettings?(); return }
        if let i = RailItem.allCases.indices.first(where: { frameFor($0).contains(p) }) { onSelect?(RailItem.allCases[i]) }
    }
    // Accessibility: one button per item.
    override func accessibilityChildren() -> [Any]? {
        var out: [NSAccessibilityElement] = []
        for (i, item) in RailItem.allCases.enumerated() {
            let e = NSAccessibilityElement()
            e.setAccessibilityRole(.button); e.setAccessibilityLabel(item.rawValue); e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(frameFor(i)); out.append(e)
        }
        let s = NSAccessibilityElement()
        s.setAccessibilityRole(.button); s.setAccessibilityLabel("Settings"); s.setAccessibilityParent(self)
        s.setAccessibilityFrameInParentSpace(settingsFrame); out.append(s)
        return out
    }
}

// MARK: Header

final class HeaderView: FillView {
    let name = FrameText("Muya", font: ThemeFont.sans(15, .semibold), color: .text)
    let sidebarToggle = FrameIconButton(.panelLeft, label: "Hide sidebar")
    let themeButton = FrameIconButton(.themeMonitor, label: "Theme: system")
    let bellButton = FrameIconButton(.bell, label: "Notifications")
    let inspectorToggle = FrameIconButton(.panelRight, label: "Hide inspector")
    let stats = FrameText("", font: ThemeFont.mono(11), color: .textMuted)
    var workspace = "" { didSet { if workspace != oldValue { needsDisplay = true } } }
    var onSearch: (() -> Void)?
    /// The Workspace chip was clicked (its frame, for the menu); the title-bar double-click is handled by `onDoubleClick`.
    var onWorkspace: ((NSRect) -> Void)?
    var onDoubleClick: (() -> Void)?
    /// Grid mode (today's GridHeader): breadcrumb "Muya / Grid · N panels", Exit grid, layout segmented, Waiting first, Broadcast to all….
    var gridPanels: Int? { didSet { if gridPanels != oldValue { applyGridMode(); needsLayout = true; needsDisplay = true } } }
    let exitButton = ThemedButton("Exit grid"), waitingButton = ThemedButton("Waiting first"), broadcastButton = ThemedButton("Broadcast to all…")
    let layoutTabs = ThemedSegmented(options: GridChoice.allCases.map(\.label))
    var onExitGrid: (() -> Void)?, onWaitingFirst: (() -> Void)?, onBroadcast: (() -> Void)?
    var onLayout: ((GridChoice) -> Void)?
    private func applyGridMode() {
        let g = gridPanels != nil
        for v in [sidebarToggle, themeButton, bellButton, inspectorToggle, stats] as [NSView] { v.isHidden = g }
        for v in [exitButton, waitingButton, broadcastButton, layoutTabs] as [NSView] { v.isHidden = !g }
    }
    init() {
        super.init(.bgChrome); bottom = true
        [name, sidebarToggle, themeButton, bellButton, inspectorToggle, stats, exitButton, waitingButton, broadcastButton, layoutTabs].forEach(addSubview)
        for v in [exitButton, waitingButton, broadcastButton, layoutTabs] as [NSView] { v.isHidden = true }
        exitButton.onClick = { [weak self] in self?.onExitGrid?() }; waitingButton.onClick = { [weak self] in self?.onWaitingFirst?() }
        broadcastButton.onClick = { [weak self] in self?.onBroadcast?() }
        layoutTabs.compact = true
        layoutTabs.onChange = { [weak self] i in self?.onLayout?(GridChoice.allCases[i]) }
        setAccessibilityRole(.group); setAccessibilityLabel("Header")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 440 wide and centred when there is room; otherwise it fills the gap between the workspace chip and the CPU/RAM numbers.
    private var searchFrame: NSRect {
        let left = chipFrame.maxX + 12, right = rightLimit
        let w = min(440, max(80, right - left))
        let x = min(max((bounds.width - w) / 2, left), right - w)
        return NSRect(x: x, y: 8, width: w, height: 32)
    }
    /// Where the search field must end: before the CPU/RAM numbers, or before the buttons when the numbers had to give way.
    private var rightLimit: CGFloat = 0
    private var logoFrame: NSRect { NSRect(x: 88, y: 11, width: 26, height: 26) }
    private var crumbEnd: CGFloat {   // grid breadcrumb: "/", "Grid", "N panels"
        guard let n = gridPanels else { return 0 }
        func w(_ t: String, _ f: NSFont) -> CGFloat { (t as NSString).size(withAttributes: [.font: f]).width }
        return 88 + 26 + 10 + name.intrinsicContentSize.width + 16 + w("/", ThemeFont.sans(14)) + 16 + w("Grid", ThemeFont.sans(14, .medium)) + 16 + w("\(n) panel\(n == 1 ? "" : "s")", ThemeFont.sans(13))
    }
    /// "claude-control-plane  · 3" -> name and the muted "· 3" (today's WorkspaceButton: Workspace, name 500, "· count", chevron; gap 8).
    private var chipParts: (name: String, count: String) {
        if let r = workspace.range(of: "·") { return (workspace[..<r.lowerBound].trimmingCharacters(in: .whitespaces), "· " + workspace[r.upperBound...].trimmingCharacters(in: .whitespaces)) }
        return (workspace, "")
    }
    private static let chipLabel: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.textMuted)]
    var chipRectForTest: NSRect { chipFrame }
    private var chipFrame: NSRect {
        let p = chipParts
        let s = (p.name as NSString).size(withAttributes: [.font: ThemeFont.sans(13, .medium)])
        let w = ("Workspace" as NSString).size(withAttributes: Self.chipLabel).width
        let c = p.count.isEmpty ? 0 : (p.count as NSString).size(withAttributes: Self.chipLabel).width + 8
        let x = gridPanels != nil ? crumbEnd + 16 : 88 + 26 + 10 + name.intrinsicContentSize.width + 12 + 32 + 12
        return NSRect(x: x, y: 8, width: ceil(12 + w + 8 + s.width + 8 + c + 14 + 12 + 2), height: 32)
    }
    override func layout() {
        super.layout()
        name.frame = NSRect(x: 88 + 26 + 10, y: 8, width: name.intrinsicContentSize.width, height: 32)
        sidebarToggle.frame = NSRect(x: name.frame.maxX + 12, y: 8, width: 32, height: 32)
        if gridPanels != nil {
            var gx = bounds.width - 16
            for b in [broadcastButton, waitingButton] { let w = b.intrinsicContentSize.width; gx -= w; b.frame = NSRect(x: gx, y: 8, width: w, height: 32); gx -= 16 }
            let sw = layoutTabs.intrinsicContentSize.width; gx -= sw; layoutTabs.frame = NSRect(x: gx, y: 7, width: sw, height: 34); gx -= 16
            let ew = exitButton.intrinsicContentSize.width; gx -= ew; exitButton.frame = NSRect(x: gx, y: 8, width: ew, height: 32)
            return
        }
        var x = bounds.width - 16
        for b in [inspectorToggle, bellButton, themeButton] { x -= 32; b.frame = NSRect(x: x, y: 8, width: 32, height: 32); x -= 8 }
        let w = stats.intrinsicContentSize.width
        stats.frame = NSRect(x: x - w - 4, y: 8, width: w, height: 32)
        // A narrow window: the numbers go first, so the search field keeps at least ~200 pt and never runs under them.
        let statsFit = stats.frame.minX - 12 - (chipFrame.maxX + 12) >= 200
        stats.isHidden = !statsFit
        rightLimit = statsFit ? stats.frame.minX - 12 : x + 8 - 4
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // logo: black rounded square with a white "M"
        let l = NSBezierPath(roundedRect: logoFrame, xRadius: 7, yRadius: 7); Theme.dynamic(.primaryBg).setFill(); l.fill()
        let la: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(14, .bold), .foregroundColor: Theme.dynamic(.primaryFg)]
        let ls = ("M" as NSString).size(withAttributes: la)
        ("M" as NSString).draw(at: NSPoint(x: logoFrame.midX - ls.width / 2, y: logoFrame.midY - ls.height / 2), withAttributes: la)
        // workspace chip
        let c = chipFrame; let cp = NSBezierPath(roundedRect: c.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Theme.dynamic(.bgControl).setFill(); cp.fill(); Theme.dynamic(.borderControl).setStroke(); cp.stroke()
        let wl = ("Workspace" as NSString).size(withAttributes: Self.chipLabel)
        var cx = c.minX + 13
        ("Workspace" as NSString).draw(at: NSPoint(x: cx, y: c.midY - wl.height / 2), withAttributes: Self.chipLabel); cx += wl.width + 8
        let na: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(13, .medium), .foregroundColor: Theme.dynamic(.text)]
        let parts = chipParts, nl = (parts.name as NSString).size(withAttributes: na)
        (parts.name as NSString).draw(at: NSPoint(x: cx, y: c.midY - nl.height / 2), withAttributes: na); cx += nl.width + 8
        if !parts.count.isEmpty { (parts.count as NSString).draw(at: NSPoint(x: cx, y: c.midY - wl.height / 2), withAttributes: Self.chipLabel); cx += (parts.count as NSString).size(withAttributes: Self.chipLabel).width + 8 }
        if let ctx = NSGraphicsContext.current?.cgContext { ctx.saveGState(); ctx.translateBy(x: cx, y: c.midY - 7); ThemeIcons.draw(.chevronDown, in: ctx, size: 14, color: Theme.dynamic(.text)); ctx.restoreGState() }
        if let n = gridPanels {
            let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(14), .foregroundColor: Theme.dynamic(.textFaint)]
            var x = 88 + 26 + 10 + name.intrinsicContentSize.width + 16
            ("/" as NSString).draw(at: NSPoint(x: x, y: 15), withAttributes: a); x += ("/" as NSString).size(withAttributes: a).width + 16
            let g: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(14, .medium), .foregroundColor: Theme.dynamic(.text)]
            ("Grid" as NSString).draw(at: NSPoint(x: x, y: 15), withAttributes: g); x += ("Grid" as NSString).size(withAttributes: g).width + 16
            ("\(n) panel\(n == 1 ? "" : "s")" as NSString).draw(at: NSPoint(x: x, y: 16), withAttributes: [.font: ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.textMuted)])
            return
        }
        // search field
        let s = searchFrame; let sp = NSBezierPath(roundedRect: s.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Theme.dynamic(.bgInput).setFill(); sp.fill(); Theme.dynamic(.borderControl).setStroke(); sp.stroke()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState(); ctx.translateBy(x: s.minX + 12, y: s.midY - 7.5)
            ThemeIcons.draw(.search, in: ctx, size: 15, color: Theme.dynamic(.textMuted)); ctx.restoreGState()
        }
        let pa: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.textMuted)]
        let ph = ("Search sessions, files or commands…" as NSString)
        let phPS = NSMutableParagraphStyle(); phPS.lineBreakMode = .byTruncatingTail
        ph.draw(in: NSRect(x: s.minX + 36, y: s.midY - ph.size(withAttributes: pa).height / 2, width: max(0, s.width - 36 - 52), height: ph.size(withAttributes: pa).height), withAttributes: pa.merging([.paragraphStyle: phPS]) { $1 })
        let ka: [NSAttributedString.Key: Any] = [.font: ThemeFont.mono(10), .foregroundColor: Theme.dynamic(.textFaint)]
        let ks = ("⌘K" as NSString).size(withAttributes: ka)
        let kr = NSRect(x: s.maxX - ks.width - 22, y: s.midY - 9, width: ks.width + 12, height: 18)
        let kp = NSBezierPath(roundedRect: kr.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        Theme.dynamic(.bgSegment).setFill(); kp.fill(); Theme.dynamic(.border).setStroke(); kp.stroke()
        ("⌘K" as NSString).draw(at: NSPoint(x: kr.minX + 6, y: kr.midY - ks.height / 2), withAttributes: ka)
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if gridPanels == nil, searchFrame.contains(p) { onSearch?() }
        else if chipFrame.contains(p) { onWorkspace?(chipFrame) }
        else if event.clickCount == 2, onDoubleClick != nil { onDoubleClick?() }   // empty bar: like a standard title bar
        else { super.mouseDown(with: event) }
    }
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: Footer

final class FooterView: FillView {
    var left = "" { didSet { if left != oldValue { needsDisplay = true; superview?.needsLayout = true } } }
    var ready = true { didSet { if ready != oldValue { needsDisplay = true } } }
    /// Right of the status fields, left of the icon buttons: "UTF-8" (the grid variant shows `hint` instead).
    var right = "UTF-8" { didSet { if right != oldValue { needsDisplay = true } } }
    /// "v4.1.20" — the last item, after the icon buttons.
    var version = "" { didSet { if version != oldValue { needsDisplay = true; superview?.needsLayout = true } } }
    /// Chosen status fields ("Model  Opus"), drawn right-aligned before UTF-8 like the web footer.
    var fields: [(String, String)] = [] { didSet { if fields.map({ $0.0 + "\u{0}" + $0.1 }) != oldValue.map({ $0.0 + "\u{0}" + $0.1 }) { needsDisplay = true; superview?.needsLayout = true } } }
    /// Grid variant: "Tab to switch panels · ⌘↵ maximize" instead of UTF-8.
    var hint = "" { didSet { needsDisplay = true; superview?.needsLayout = true } }
    /// The message-box (composer) toggle is lit while the box is open.
    var composerOpen = true { didSet { if composerOpen != oldValue { needsDisplay = true } } }
    var onAppearance: ((NSRect) -> Void)?
    var onFields: ((NSRect) -> Void)?
    var onComposer: (() -> Void)?
    private var aaRect = NSRect.zero, chatRect = NSRect.zero, plusRect = NSRect.zero
    init() { super.init(.bgChrome); top = true; setAccessibilityRole(.staticText) }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityLabel() -> String? { "\(ready ? "Ready" : "Disconnected") \(left) \(right) Muya \(version)" }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if aaRect.contains(p) { onAppearance?(aaRect) } else if chatRect.contains(p) { onComposer?() } else if plusRect.contains(p) { onFields?(plusRect) } else { super.mouseDown(with: event) }
    }
    private static let rowH: CGFloat = 28, iconsW: CGFloat = 64   // three 20 pt buttons + two 2 pt gaps
    private var lineH: CGFloat { ceil(("Ag" as NSString).size(withAttributes: [.font: ThemeFont.sans(12)]).height) }
    private func width(_ s: String, _ font: NSFont = ThemeFont.sans(12)) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
    /// Where the web footer's one-line layout leaves room for the fields, and the wrapped rows when it does not.
    /// Like the web (Footer.tsx useStatusSecondLine): one line while the fields fit, otherwise ALL of them go to a
    /// second block under the first line, right-aligned, wrapping at the footer width.
    private func plan(width w: CGFloat) -> (single: Bool, rows: [[(k: String, v: String, w: CGFloat)]]) {
        let items = fields.map { (k: $0.0, v: $0.1, w: width("\($0.0) ") + width($0.1)) }
        if items.isEmpty { return (true, []) }
        let leftEnd = 28 + width(ready ? "Ready" : "Disconnected") + 18 + width(left)
        let midLeft = w - 16 - width("Muya \(version)") - 10 - Self.iconsW - 18 - width(hint.isEmpty ? right : hint)
        let total = items.reduce(0) { $0 + $1.w } + 14 * CGFloat(items.count - 1)
        if midLeft - 18 - total >= leftEnd + 18 { return (true, [items]) }
        var rows: [[(k: String, v: String, w: CGFloat)]] = [[]], used: CGFloat = 0
        for it in items {
            if !rows[rows.count - 1].isEmpty, used + 14 + it.w > w - 32 { rows.append([]); used = 0 }
            used += (rows[rows.count - 1].isEmpty ? 0 : 14) + it.w; rows[rows.count - 1].append(it)
        }
        return (false, rows)
    }
    /// 28 pt for one line; with the wrapped block: + rows × line height + 4 pt row gaps + 7 pt bottom padding (the web's numbers).
    func requiredHeight(width w: CGFloat) -> CGFloat {
        let p = plan(width: w)
        return p.single ? Self.rowH : Self.rowH + CGFloat(p.rows.count) * lineH + CGFloat(p.rows.count - 1) * 4 + 7
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let midY = Self.rowH / 2
        let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textMuted)]
        let faint: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textFaint)]
        func text(_ s: String, rightEdge: CGFloat, _ attrs: [NSAttributedString.Key: Any], _ cy: CGFloat? = nil) -> CGFloat {   // draws right-aligned, returns the left edge
            let ns = s as NSString, sz = ns.size(withAttributes: attrs)
            ns.draw(at: NSPoint(x: rightEdge - sz.width, y: (cy ?? midY) - sz.height / 2), withAttributes: attrs)
            return rightEdge - sz.width
        }
        Theme.dynamic(ready ? .success : .warning).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: midY - 3, width: 6, height: 6)).fill()
        let rs = (ready ? "Ready" : "Disconnected") as NSString
        rs.draw(at: NSPoint(x: 28, y: midY - rs.size(withAttributes: a).height / 2), withAttributes: a)
        let lw = rs.size(withAttributes: a).width
        let ls = left as NSString
        ls.draw(at: NSPoint(x: 28 + lw + 18, y: midY - ls.size(withAttributes: a).height / 2), withAttributes: a)
        // right to left, like the web flex row (gap 18; the icon group sits 8 pt closer to the version)
        let verLeft = text("Muya \(version)", rightEdge: bounds.width - 16, a)
        var gx = verLeft - 10                                       // right edge of the icon group
        plusRect = NSRect(x: gx - 20, y: midY - 10, width: 20, height: 20); gx = plusRect.minX - 2
        chatRect = NSRect(x: gx - 20, y: midY - 10, width: 20, height: 20); gx = chatRect.minX - 2
        aaRect = NSRect(x: gx - 20, y: midY - 10, width: 20, height: 20)
        if let ctx = NSGraphicsContext.current?.cgContext {
            func icon(_ i: ThemeIcon, _ r: NSRect, _ size: CGFloat, _ c: Theme.Token) {
                ctx.saveGState(); ctx.translateBy(x: r.midX - size / 2, y: r.midY - size / 2)
                ThemeIcons.draw(i, in: ctx, size: size, color: Theme.dynamic(c)); ctx.restoreGState()
            }
            icon(.textSize, aaRect, 14, .textMuted); icon(.chatRail, chatRect, 13, composerOpen ? .text : .textMuted); icon(.plus, plusRect, 12, .textMuted)
        }
        let mid = hint.isEmpty ? right : hint
        let x = text(mid, rightEdge: aaRect.minX - 18, hint.isEmpty ? a : faint) - 18
        let p = plan(width: bounds.width)
        for (r, row) in p.rows.enumerated() {                       // single line: one row right before the middle text; else rows under it
            var rx = p.single ? x : bounds.width - 16
            let cy = p.single ? midY : Self.rowH + CGFloat(r) * (lineH + 4) + lineH / 2
            for it in row.reversed() {
                let vl = text(it.v, rightEdge: rx, a, cy); _ = text("\(it.k) ", rightEdge: vl, faint, cy)
                rx -= it.w + 14
            }
        }
    }
}

// MARK: Container

/// Header on top, rail on the left, footer at the bottom, the existing content in the rest. The window uses a full-size
/// content view with a transparent title bar, so the header sits where the traffic lights are (78px reserved on the left).
final class FrameView: NSView {
    let header = HeaderView(), rail = RailView(), footer = FooterView()
    let content: NSView
    /// Dropping files on the window (today's drop overlay): `onDrop` gets the file URLs.
    var onDrop: (([URL]) -> Void)?
    private let dropOverlay = DropOverlay()
    var contentInset: NSEdgeInsets { NSEdgeInsets(top: ThemeMetric.headerHeight, left: ThemeMetric.railWidth, bottom: max(ThemeMetric.footerHeight, footer.requiredHeight(width: bounds.width)), right: 0) }
    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        [content, rail, header, footer].forEach(addSubview)
        addSubview(dropOverlay); dropOverlay.isHidden = true
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let i = contentInset
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: i.top)
        footer.frame = NSRect(x: 0, y: bounds.height - i.bottom, width: bounds.width, height: i.bottom)
        rail.frame = NSRect(x: 0, y: i.top, width: i.left, height: bounds.height - i.top - i.bottom)
        content.frame = NSRect(x: i.left, y: i.top, width: bounds.width - i.left, height: bounds.height - i.top - i.bottom)
        dropOverlay.frame = content.frame
    }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }

    func showDropOverlay(_ on: Bool) { dropOverlay.isHidden = !on }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        showDropOverlay(true); return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { showDropOverlay(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropOverlay(false)
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onDrop?(urls); return true
    }
}

/// "Drop to open" hint over the content while files are dragged over the window.
final class DropOverlay: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Theme.dynamic(.bgApp).withAlphaComponent(0.85).setFill(); bounds.fill()
        let r = bounds.insetBy(dx: 24, dy: 24), p = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        p.setLineDash([8, 6], count: 2, phase: 0); p.lineWidth = 2
        Theme.dynamic(.accent).setStroke(); p.stroke()
        let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(15, .semibold), .foregroundColor: Theme.dynamic(.accent)]
        let t = "Drop files to open them" as NSString, sz = t.size(withAttributes: a)
        t.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: a)
    }
}

// MARK: Live numbers (CPU / RAM of this app) — a 5 s tolerant timer, only while the window is visible

final class FrameStats {
    private var timer: Timer?
    private var lastCPU = 0.0, lastWall = 0.0
    var onUpdate: ((_ cpuPercent: Int, _ ramMB: Int, _ clock: String) -> Void)?
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }
    static func cpuSeconds() -> Double {
        var t = task_thread_times_info(); var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &t) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count) } }
        var basic = task_basic_info(); var bc = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size)
        let r2 = withUnsafeMutablePointer(to: &basic) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(bc)) { task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &bc) } }
        guard r == KERN_SUCCESS, r2 == KERN_SUCCESS else { return 0 }
        func s(_ v: time_value_t) -> Double { Double(v.seconds) + Double(v.microseconds) / 1e6 }
        return s(t.user_time) + s(t.system_time) + s(basic.user_time) + s(basic.system_time)
    }
    func start() {
        stop(); lastCPU = Self.cpuSeconds(); lastWall = ProcessInfo.processInfo.systemUptime; tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 2.5
    }
    func stop() { timer?.invalidate(); timer = nil }
    func tick() {
        let cpu = Self.cpuSeconds(), wall = ProcessInfo.processInfo.systemUptime
        let pct = wall - lastWall >= 1 ? Int(((cpu - lastCPU) / (wall - lastWall) * 100).rounded()) : 0
        lastCPU = cpu; lastWall = wall
        onUpdate?(max(0, pct), Self.footprintMB(), Self.fmt.string(from: Date()))
    }
}
