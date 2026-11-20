// The Inspector, drawn like today's Muya (src/redesign/Inspector.tsx + ActivityPanel.tsx): a 320px right panel with
//   NEEDS APPROVAL card(s)  - one per session waiting on a permission prompt (Allow / Deny / Open)
//   Changes N | Activity    - underlined tabs
//   Changes                 - git status rows (letter + path), "Review diff", the selected file's diff
//   Activity                - AGENT FILES (modified / read), LOCK / EDIT TELEMETRY, then the session's timeline
//   bottom card             - "No file conflicts" (green) or the conflicts (red)
// Review diff opens the "Uncommitted changes" dialog: file list on the left, before | after columns on the right.
// Reads only. Data comes through `InspectorSource` (interim: local git, see InspectorSource.swift).
// Refresh: on folder change, on show, and every 5 s while visible and the window is on screen; never otherwise.
// Every part paints from theme tokens in draw(_:) (a theme change repaints without code or timers).

import AppKit

// MARK: Drawing helpers

private func tok(_ t: Theme.Token) -> NSColor { Theme.dynamic(t) }

private func fillRounded(_ r: NSRect, radius: CGFloat, fill: NSColor?, stroke: NSColor?) {
    let inset: CGFloat = stroke == nil ? 0 : 0.5
    let p = NSBezierPath(roundedRect: r.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
    if let fill { fill.setFill(); p.fill() }
    if let stroke { stroke.setStroke(); p.lineWidth = 1; p.stroke() }
}

private func styled(_ s: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0, mode: NSLineBreakMode = .byTruncatingTail, align: NSTextAlignment = .left) -> NSAttributedString {
    let ps = NSMutableParagraphStyle(); ps.lineBreakMode = mode; ps.alignment = align
    var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: ps]
    if kern != 0 { a[.kern] = kern }
    return NSAttributedString(string: s, attributes: a)
}

private func measured(_ a: NSAttributedString, width: CGFloat) -> CGFloat {
    ceil(a.boundingRect(with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
}

/// One line, clipped to `r` with an ellipsis, vertically centred.
private func drawLine(_ a: NSAttributedString, in r: NSRect, lineHeight: CGFloat = 16) {
    a.draw(with: NSRect(x: r.minX, y: r.midY - lineHeight / 2, width: max(r.width, 0), height: lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}

private func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

// MARK: Buttons and surfaces

/// 32px high, radius 7, 13px (Inspector.tsx buttons). Tones: control (Review diff), allow (amber fill), warn (amber outline).
final class PaneButton: NSControl {
    enum Tone { case control, allow, warn, primary }
    var tone: Tone { didSet { needsDisplay = true } }
    var title: String { didSet { setAccessibilityLabel(title); needsDisplay = true } }
    var onClick: (() -> Void)?
    private var pressed = false

    init(_ title: String, tone: Tone = .control) {
        self.title = title; self.tone = tone
        super.init(frame: .zero)
        setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.45; needsDisplay = true } }
    var naturalWidth: CGFloat { ceil(styled(title, labelFont, .black).size().width) + 22 }
    private var labelFont: NSFont { ThemeFont.sans(13, tone == .allow || tone == .primary ? .semibold : .regular) }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor?, stroke: NSColor?, fg: NSColor
        switch tone {
        case .control: fill = tok(.bgControl); stroke = tok(.borderControl); fg = tok(.text)
        case .allow: fill = tok(.warningBtnBg); stroke = nil; fg = tok(.warningBtnFg)
        case .warn: fill = nil; stroke = tok(.warningBorder); fg = tok(.warningText)
        case .primary: fill = tok(.primaryBg); stroke = nil; fg = tok(.primaryFg)
        }
        fillRounded(bounds, radius: 7, fill: fill, stroke: stroke)
        if pressed { NSColor.black.withAlphaComponent(0.12).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
        drawLine(styled(title, labelFont, fg, mode: .byClipping, align: .center), in: bounds)
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false; needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { fire() }
    }
    private func fire() { onClick?(); sendAction(action, to: target) }
    override func keyDown(with event: NSEvent) { if isEnabled, event.keyCode == 36 || event.keyCode == 49 { fire() } else { super.keyDown(with: event) } }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; fire(); return true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A rounded, bordered fill in token colours.
final class SurfaceView: NSView {
    var fill: Theme.Token? { didSet { needsDisplay = true } }
    var border: Theme.Token? { didSet { needsDisplay = true } }
    var radius: CGFloat { didSet { needsDisplay = true } }
    init(fill: Theme.Token?, border: Theme.Token?, radius: CGFloat) { self.fill = fill; self.border = border; self.radius = radius; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { fillRounded(bounds, radius: radius, fill: fill.map(tok), stroke: border.map(tok)) }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The 2-tab strip: 40px tabs, 18px apart, 2px underline on the active one, 1px rule below. `trailing` is a small mono hint on the right.
final class PaneTabBar: NSView {
    var titles: [String] { didSet { needsDisplay = true; accessibilityTabs = nil } }
    var selected = 0 { didSet { needsDisplay = true } }
    var trailing = "" { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    static let height: CGFloat = 41

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.radioGroup); setAccessibilityLabel("Inspector tabs")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    private func font(_ active: Bool) -> NSFont { ThemeFont.sans(13, active ? .medium : .regular) }
    func tabFrames() -> [NSRect] {
        var x: CGFloat = 16
        return titles.map { t in
            let w = ceil(styled(t, ThemeFont.sans(13, .medium), .black).size().width)
            defer { x += w + 18 }
            return NSRect(x: x, y: 0, width: w, height: 40)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        tok(.border).setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let frames = tabFrames()
        for (i, t) in titles.enumerated() {
            let active = i == selected, r = frames[i]
            drawLine(styled(t, font(active), tok(active ? .textStrong : .textMuted), mode: .byClipping), in: NSRect(x: r.minX, y: 0, width: r.width + 2, height: 38), lineHeight: 18)
            if active { tok(.text).setFill(); NSRect(x: r.minX, y: 38, width: r.width, height: 2).fill() }
        }
        if !trailing.isEmpty, let last = frames.last {
            let x = last.maxX + 14
            drawLine(styled(trailing, ThemeFont.mono(11), tok(.textMuted), mode: .byTruncatingMiddle, align: .right), in: NSRect(x: x, y: 0, width: bounds.width - 16 - x, height: 40))
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = tabFrames().firstIndex(where: { $0.insetBy(dx: -9, dy: 0).contains(p) }) { choose(i) }
    }
    private func choose(_ i: Int) { guard i != selected else { return }; selected = i; onSelect?(i) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: choose(max(0, selected - 1))
        case 124: choose(min(titles.count - 1, selected + 1))
        default: super.keyDown(with: event)
        }
    }

    private var accessibilityTabs: [NSAccessibilityElement]?
    override func accessibilityChildren() -> [Any]? {
        let frames = tabFrames()
        return titles.enumerated().map { i, t in
            let e = NSAccessibilityElement()
            e.setAccessibilityRole(.radioButton); e.setAccessibilityLabel(t); e.setAccessibilityValue(i == selected ? 1 : 0)
            e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(frames[i])
            return e
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: NEEDS APPROVAL

final class ApprovalsView: NSView {
    var items: [InspectorApproval] = [] { didSet { if items != oldValue { rebuild() } } }
    var onAllow: ((UInt64) -> Void)?
    var onDeny: ((UInt64) -> Void)?
    var onOpen: ((UInt64) -> Void)?
    private var buttons: [(allow: PaneButton, deny: PaneButton, open: PaneButton)] = []

    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Needs approval") }
    required init?(coder: NSCoder) { fatalError() }

    private func line(_ a: InspectorApproval) -> NSAttributedString {
        let s = NSMutableAttributedString(string: a.name, attributes: [.font: ThemeFont.sans(13, .semibold), .foregroundColor: tok(.text)])
        s.append(NSAttributedString(string: " " + a.summary, attributes: [.font: ThemeFont.sans(13), .foregroundColor: tok(.text)]))
        return s
    }
    private func code(_ a: InspectorApproval) -> String? {
        let c = a.tool + (a.tool.isEmpty || a.target.isEmpty ? "" : " → ") + a.target
        return c.isEmpty ? nil : c
    }

    private struct Geo { var card: NSRect; var text: NSRect; var code: NSRect?; var row: NSRect }
    private func geometry(_ width: CGFloat) -> [Geo] {
        var y: CGFloat = 16 + 14 + 10
        return items.map { a in
            let w = width - 32, inner = w - 24
            var cy = y + 12
            let th = measured(line(a), width: inner)
            let text = NSRect(x: 28, y: cy, width: inner, height: th); cy += th + 8
            var codeRect: NSRect?
            if code(a) != nil { codeRect = NSRect(x: 28, y: cy, width: inner, height: 27); cy += 27 + 8 }
            let row = NSRect(x: 28, y: cy, width: inner, height: 32); cy += 32 + 12
            defer { y = cy + 10 }
            return Geo(card: NSRect(x: 16, y: y, width: w, height: cy - y), text: text, code: codeRect, row: row)
        }
    }
    func height(for width: CGFloat) -> CGFloat {
        guard !items.isEmpty, let last = geometry(width).last else { return 0 }
        return last.card.maxY + 16 + 1
    }

    private func rebuild() {
        buttons.forEach { $0.allow.removeFromSuperview(); $0.deny.removeFromSuperview(); $0.open.removeFromSuperview() }
        buttons = items.map { a in
            let al = PaneButton("Allow", tone: .allow), de = PaneButton("Deny", tone: .warn), op = PaneButton("Open", tone: .warn)
            al.isEnabled = a.actionable; de.isEnabled = a.actionable
            al.onClick = { [weak self] in self?.onAllow?(a.id) }
            de.onClick = { [weak self] in self?.onDeny?(a.id) }
            op.onClick = { [weak self] in self?.onOpen?(a.id) }
            al.setAccessibilityLabel("Allow \(a.name)"); de.setAccessibilityLabel("Deny \(a.name)"); op.setAccessibilityLabel("Open \(a.name)")
            [al, de, op].forEach(addSubview)
            return (al, de, op)
        }
        needsLayout = true; needsDisplay = true
    }

    override func layout() {
        super.layout()
        for (g, b) in zip(geometry(bounds.width), buttons) {
            let open = b.open.naturalWidth, each = (g.row.width - open - 16) / 2
            b.allow.frame = NSRect(x: g.row.minX, y: g.row.minY, width: each, height: 32)
            b.deny.frame = NSRect(x: g.row.minX + each + 8, y: g.row.minY, width: each, height: 32)
            b.open.frame = NSRect(x: g.row.maxX - open, y: g.row.minY, width: open, height: 32)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty else { return }
        tok(.border).setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        drawLine(styled("NEEDS APPROVAL", ThemeFont.sans(11, .semibold), tok(.warningLabel), kern: 0.66), in: NSRect(x: 16, y: 16, width: bounds.width - 32, height: 14), lineHeight: 14)
        for (a, g) in zip(items, geometry(bounds.width)) {
            fillRounded(g.card, radius: 10, fill: tok(.warningCardBg), stroke: tok(.warningBorder))
            line(a).draw(with: g.text, options: [.usesLineFragmentOrigin])
            if let r = g.code, let c = code(a) {
                fillRounded(r, radius: 6, fill: tok(.warningCodeBg), stroke: nil)
                drawLine(styled(c, ThemeFont.mono(11.5), tok(.warningText), mode: .byTruncatingTail), in: r.insetBy(dx: 8, dy: 0))
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: Bottom card

/// "No file conflicts" (green) or the conflicted files (red). Margin 16, padding 12, radius 10.
final class StatusCard: NSView {
    enum Kind: Equatable { case ok(String), conflict(title: String, lines: [String]) }
    var kind: Kind = .ok("") { didSet { if kind != oldValue { needsDisplay = true; setAccessibilityLabel(accessibilityText) } } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.group) }
    required init?(coder: NSCoder) { fatalError() }

    var accessibilityText: String {
        switch kind { case let .ok(s): return "No file conflicts. \(s)"; case let .conflict(t, l): return "File conflicts: \(t). \(l.joined(separator: ", "))" }
    }
    private func title() -> NSAttributedString {
        switch kind {
        case .ok: return styled("No file conflicts", ThemeFont.sans(13, .medium), tok(.successCardText))
        case .conflict: return styled("File conflicts", ThemeFont.sans(13, .medium), tok(.dangerText))
        }
    }
    func height(for width: CGFloat) -> CGFloat {
        switch kind {
        case .ok(let sub):
            return 12 + 16 + 2 + measured(styled(sub, ThemeFont.sans(12), .black, mode: .byWordWrapping), width: width - 52) + 12
        case .conflict(let t, let lines):
            return 12 + 16 + 6 + 16 + CGFloat(lines.count) * 22 + 12 + (t.isEmpty ? 0 : 0)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .ok(let sub):
            fillRounded(bounds, radius: 10, fill: tok(.successCardBg), stroke: tok(.successCardBorder))
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState(); ctx.translateBy(x: 12, y: 12)
                ThemeIcons.draw(.check, in: ctx, size: 18, color: tok(.success), stroke: 2)
                ctx.restoreGState()
            }
            title().draw(with: NSRect(x: 40, y: 12, width: bounds.width - 52, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            styled(sub, ThemeFont.sans(12), tok(.textMuted), mode: .byWordWrapping).draw(with: NSRect(x: 40, y: 30, width: bounds.width - 52, height: bounds.height - 40), options: [.usesLineFragmentOrigin])
        case .conflict(let t, let lines):
            fillRounded(bounds, radius: 10, fill: tok(.dangerBtnBg), stroke: tok(.dangerBorder))
            title().draw(with: NSRect(x: 12, y: 12, width: bounds.width - 24, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            drawLine(styled(t, ThemeFont.sans(12), tok(.dangerText)), in: NSRect(x: 12, y: 34, width: bounds.width - 24, height: 16))
            for (i, l) in lines.enumerated() {
                drawLine(styled(l, ThemeFont.mono(12), tok(.dangerText), mode: .byTruncatingMiddle), in: NSRect(x: 12, y: 56 + CGFloat(i) * 22, width: bounds.width - 24, height: 16))
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: Rows

/// What one row of the Changes list / Activity list shows.
enum PaneRow: Equatable {
    case change(letter: String, token: Theme.Token, name: String, dir: String, trailing: String)
    case heading(String, size: CGFloat, before: CGFloat, after: CGFloat)
    case file(name: String, dir: String, modified: Bool, count: Int, path: String)
    case text(String, token: Theme.Token, after: CGFloat)
    case collision(file: String, note: String)
    case event(title: String, detail: String, time: String)
    case touched(name: String, dir: String, note: String)
}

final class PaneCell: NSTableCellView {
    var row: PaneRow = .text("", token: .textMuted, after: 0) { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        switch row {
        case let .change(letter, token, name, dir, trailing):
            var x: CGFloat = 16
            drawLine(styled(letter, ThemeFont.mono(12), tok(token), mode: .byClipping), in: NSRect(x: x, y: 0, width: 12, height: b.height)); x += 22
            var tw: CGFloat = 0
            if !trailing.isEmpty { tw = ceil(styled(trailing, ThemeFont.sans(11), .black).size().width); drawLine(styled(trailing, ThemeFont.sans(11), tok(.textMuted), align: .right), in: NSRect(x: b.width - 16 - tw, y: 0, width: tw, height: b.height)); tw += 8 }
            drawLine(pathText(name, dir), in: NSRect(x: x, y: 0, width: b.width - 16 - tw - x, height: b.height))
        case let .heading(t, size, before, _):
            drawLine(styled(t, ThemeFont.sans(size, .semibold), tok(.textMuted), kern: size * 0.06), in: NSRect(x: 16, y: before, width: b.width - 32, height: size + 3), lineHeight: size + 3)
        case let .file(name, dir, modified, count, _):
            // 7px dot (warning = modified, muted = read), mono name + folder, ×n on the right.
            (modified ? tok(.warning) : tok(.textMuted)).setFill()
            NSBezierPath(ovalIn: NSRect(x: 16, y: b.midY - 3.5, width: 7, height: 7)).fill()
            var tw: CGFloat = 0
            if count > 1 { let s = "×\(count)"; tw = ceil(styled(s, ThemeFont.mono(12), .black).size().width); drawLine(styled(s, ThemeFont.mono(12), tok(.textMuted), align: .right), in: NSRect(x: b.width - 16 - tw, y: 0, width: tw, height: b.height - 2)); tw += 8 }
            drawLine(pathText(name, dir), in: NSRect(x: 31, y: 0, width: b.width - 16 - tw - 31, height: b.height - 2))
        case let .text(t, token, _):
            styled(t, ThemeFont.sans(12), tok(token), mode: .byWordWrapping).draw(with: NSRect(x: 16, y: 0, width: b.width - 32, height: b.height), options: [.usesLineFragmentOrigin])
        case let .collision(file, note):
            fillRounded(NSRect(x: 16, y: 0, width: b.width - 32, height: b.height - 10), radius: 8, fill: tok(.dangerBtnBg), stroke: tok(.dangerBorder))
            drawLine(styled(file, ThemeFont.mono(12), tok(.dangerText), mode: .byTruncatingMiddle), in: NSRect(x: 27, y: 10, width: b.width - 54, height: 16))
            drawLine(styled(note, ThemeFont.sans(12), tok(.textMuted)), in: NSRect(x: 27, y: 28, width: b.width - 54, height: 16))
        case let .touched(name, dir, note):
            (tok(.warning)).setFill()
            NSBezierPath(ovalIn: NSRect(x: 16, y: b.midY - 3.5, width: 7, height: 7)).fill()
            let tw = ceil(styled(note, ThemeFont.sans(11), .black).size().width)
            drawLine(styled(note, ThemeFont.sans(11), tok(.textMuted), align: .right), in: NSRect(x: b.width - 16 - tw, y: 0, width: tw, height: b.height - 2))
            drawLine(pathText(name, dir == "/" ? "" : dir), in: NSRect(x: 31, y: 0, width: b.width - 16 - tw - 39, height: b.height - 2))
        case let .event(title, detail, time):
            var tw: CGFloat = 0
            if !time.isEmpty { tw = ceil(styled(time, ThemeFont.sans(11), .black).size().width); drawLine(styled(time, ThemeFont.sans(11), tok(.textMuted), align: .right), in: NSRect(x: b.width - 16 - tw, y: 4, width: tw, height: 16)); tw += 8 }
            drawLine(styled(title, ThemeFont.sans(12, .semibold), tok(.text)), in: NSRect(x: 16, y: 4, width: b.width - 32 - tw, height: 16))
            drawLine(styled(detail, ThemeFont.mono(11), tok(.textMuted), mode: .byTruncatingHead), in: NSRect(x: 16, y: 20, width: b.width - 32, height: 14), lineHeight: 14)
        }
    }

    private func pathText(_ name: String, _ dir: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: name, attributes: [.font: ThemeFont.mono(12), .foregroundColor: tok(.text)])
        if !dir.isEmpty { s.append(NSAttributedString(string: " " + dir, attributes: [.font: ThemeFont.mono(12), .foregroundColor: tok(.textMuted)])) }
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail
        s.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: s.length))
        return s
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Row highlight: --bg-selected, radius 6, 8px in from the sides (the web rows sit in an 8px padded list).
final class PaneRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        fillRounded(bounds.insetBy(dx: 8, dy: 1), radius: 6, fill: tok(.bgSelected), stroke: nil)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: The pane

final class FlippedBox: NSView { override var isFlipped: Bool { true } }

final class InspectorPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Tab: Int { case changes, files, activity }

    var source: InspectorSource = LocalGitSource()
    /// The daemon: Review of a branch reads through it (set by the app; nil in a bare pane).
    var muyad: MuyadGit?
    /// The Review dialog while it is open.
    private(set) weak var reviewPanel: ReviewPanel?
    /// Its window (a borderless child of the main window).
    private(set) weak var reviewWindow: NSWindow?
    var home = NSHomeDirectory()
    var onOpenFile: ((URL) -> Void)?
    /// Set by the host: false while the window is minimized / occluded / asleep (no polling then).
    var windowVisible: () -> Bool = { true }
    /// Sessions waiting on a permission prompt (set by the host); read on every refresh and by `refreshApprovals()`.
    var approvalsProvider: () -> [InspectorApproval] = { [] }
    var onAllow: ((UInt64) -> Void)?
    var onDeny: ((UInt64) -> Void)?
    var onOpenSession: ((UInt64) -> Void)?

    var cwd: String? { didSet { if cwd != oldValue { reset(); reload() } } }
    /// Files = what the session wrote (transcript + git); Activity = AGENT FILES, telemetry and the timeline.
    private(set) var tab: Tab = .changes { didSet { showTab() } }
    private(set) var snapshot = InspectorSnapshot()
    private(set) var events: [ActivityEvent] = []
    private(set) var touched: [InspectorFileRow] = []
    private(set) var diff = DiffResult()
    private(set) var selectedChange: GitChange?
    private(set) var loaded = false

    private let approvals = ApprovalsView()
    private let tabBar = PaneTabBar(titles: ["Changes", "Files", "Activity"])
    private let statusCard = StatusCard()
    private let emptyLabel = Kit.label("", size: 12, color: Token.textSecondary, lines: 0)
    private let changesTable = KeyTable()
    private let activityTable = KeyTable()
    private let filesTable = KeyTable()
    private let filesScroll: NSScrollView
    private let changesScroll: NSScrollView
    private let activityScroll: NSScrollView
    private let reviewButton = PaneButton("Review diff")
    private let diffText = NSTextView()
    private let diffScroll = NSScrollView()
    private let diffHeader = NSTextField(labelWithString: "")
    private let diffBox = FlippedBox()
    private var changesRows: [GitChange] = []
    private var activityRows: [PaneRow] = []
    private var timer: Timer?
    private var generation = 0
    private let queue = DispatchQueue(label: "inspector.read", qos: .utility)

    override init(frame: NSRect) {
        changesScroll = Kit.scroll(changesTable, label: "Changed files")
        activityScroll = Kit.scroll(activityTable, label: "Session activity")
        filesScroll = Kit.scroll(filesTable, label: "Files touched by the session")
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Inspector")
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func configure(_ t: NSTableView, id: String) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.resizingMask = .autoresizingMask
        t.addTableColumn(col)
        t.headerView = nil
        t.style = .plain
        t.backgroundColor = .clear
        t.dataSource = self; t.delegate = self
        t.usesAutomaticRowHeights = false
        t.intercellSpacing = .zero
        t.selectionHighlightStyle = .regular
        t.focusRingType = .none
    }

    private func build() {
        wantsLayer = true
        tabBar.onSelect = { [weak self] i in guard let self else { return }; self.tab = Tab(rawValue: i) ?? .changes }
        approvals.onAllow = { [weak self] id in self?.onAllow?(id); self?.refreshApprovals() }
        approvals.onDeny = { [weak self] id in self?.onDeny?(id); self?.refreshApprovals() }
        approvals.onOpen = { [weak self] id in self?.onOpenSession?(id) }
        configure(changesTable, id: "change")
        configure(activityTable, id: "activity")
        configure(filesTable, id: "file")
        filesTable.rowHeight = 28
        filesTable.target = self; filesTable.action = #selector(filesClicked)
        filesTable.setAccessibilityLabel("Files touched by the session")
        filesTable.onReturn = { [weak self] in self?.openTouched(self?.filesTable.selectedRow ?? -1) }
        changesTable.rowHeight = 32
        changesTable.setAccessibilityLabel("Changed files")
        activityTable.target = self; activityTable.action = #selector(activityClicked)
        activityTable.onReturn = { [weak self] in self?.openActivityRow(self?.activityTable.selectedRow ?? -1) }
        for s in [changesScroll, activityScroll, filesScroll] { s.scrollerStyle = .overlay; s.hasHorizontalScroller = false; s.automaticallyAdjustsContentInsets = false }

        reviewButton.onClick = { [weak self] in self?.reviewTapped() }
        reviewButton.setAccessibilityLabel("Review changes")
        reviewButton.toolTip = "Review every changed file, one diff at a time ([ and ] to move). Right-click for the branch review."

        diffText.isEditable = false; diffText.isSelectable = true; diffText.isRichText = true
        diffText.drawsBackground = false
        diffText.textContainerInset = NSSize(width: 8, height: 6)
        diffText.isHorizontallyResizable = true
        diffText.textContainer?.widthTracksTextView = false
        diffText.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diffText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diffText.setAccessibilityLabel("Diff")
        diffScroll.documentView = diffText
        diffScroll.hasVerticalScroller = true; diffScroll.hasHorizontalScroller = true
        diffScroll.drawsBackground = false; diffScroll.borderType = .noBorder; diffScroll.scrollerStyle = .overlay
        diffHeader.font = ThemeFont.mono(11); diffHeader.textColor = tok(.textMuted); diffHeader.lineBreakMode = .byTruncatingMiddle
        diffBox.addSubview(diffHeader); diffBox.addSubview(diffScroll)

        emptyLabel.alignment = .center
        emptyLabel.font = ThemeFont.sans(12); emptyLabel.textColor = tok(.textMuted)
        emptyLabel.preferredMaxLayoutWidth = 260

        for v in [approvals, tabBar, changesScroll, reviewButton, diffBox, activityScroll, filesScroll, emptyLabel, statusCard] as [NSView] { addSubview(v) }
        showTab()
    }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { tok(.bgPanel).setFill(); bounds.fill() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        var y: CGFloat = 0
        let ah = approvals.items.isEmpty ? 0 : approvals.height(for: w)
        approvals.isHidden = ah == 0
        approvals.frame = NSRect(x: 0, y: 0, width: w, height: ah); y += ah
        tabBar.frame = NSRect(x: 0, y: y, width: w, height: PaneTabBar.height); y += PaneTabBar.height
        let ch = statusCard.height(for: w - 32)
        statusCard.frame = NSRect(x: 16, y: max(y, h - 16 - ch), width: w - 32, height: ch)
        let bottom = statusCard.frame.minY - 16
        let body = NSRect(x: 0, y: y, width: w, height: max(0, bottom - y))
        if tab == .changes {
            let maxList = min(0.45 * (window?.contentLayoutRect.height ?? h), body.height - 44)
            let list = max(0, min(CGFloat(changesRows.count) * 32 + 20, maxList))
            changesScroll.frame = NSRect(x: 0, y: y, width: w, height: list)
            changesScroll.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
            var by = y + list + 4
            if changesRows.isEmpty { by = y + 10 }
            reviewButton.frame = NSRect(x: 16, y: by, width: w - 32, height: 32)
            let dy = by + 32 + 10
            diffBox.frame = NSRect(x: 0, y: dy, width: w, height: max(0, bottom - dy))
            diffHeader.frame = NSRect(x: 16, y: 0, width: w - 32, height: 16)
            diffScroll.frame = NSRect(x: 0, y: 20, width: w, height: max(0, diffBox.frame.height - 20))
        } else {
            activityScroll.frame = body; filesScroll.frame = body
        }
        emptyLabel.frame = NSRect(x: 24, y: body.minY + max(0, (body.height - 60) / 2), width: max(0, w - 48), height: 60)
        if tab == .changes && !changesRows.isEmpty { emptyLabel.frame.origin.y = body.maxY }   // not shown then anyway
    }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() { updateTimer() }
    override var isHidden: Bool { didSet { updateTimer(); if !isHidden { reload() } } }
    override func viewDidChangeEffectiveAppearance() { renderDiff(); needsDisplay = true }

    private func updateTimer() {
        timer?.invalidate(); timer = nil
        guard window != nil, !isHidden else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.windowVisible() else { return }
            self.reload()
        }
        t.tolerance = 2
        timer = t
    }

    private func reset() {
        generation += 1
        snapshot = InspectorSnapshot(); events = []; touched = []; diff = DiffResult(); selectedChange = nil; loaded = false
        render()
    }

    /// Re-reads which sessions wait for approval (cheap: no I/O). The host calls it when a session's screen state changes.
    func refreshApprovals() {
        let next = approvalsProvider()
        guard next != approvals.items else { return }
        approvals.items = next
        needsLayout = true; layoutSubtreeIfNeeded()
    }

    private func openActivityRow(_ i: Int) {
        guard i >= 0, i < activityRows.count, case let .file(_, _, _, _, path) = activityRows[i], FileManager.default.fileExists(atPath: path) else { return }
        onOpenFile?(URL(fileURLWithPath: path))
    }
    private func openTouched(_ i: Int) {
        guard i >= 0, i < touched.count, FileManager.default.fileExists(atPath: touched[i].path) else { return }
        onOpenFile?(URL(fileURLWithPath: touched[i].path))
    }
    @objc private func filesClicked() { openTouched(filesTable.clickedRow); filesTable.deselectAll(nil) }
    @objc private func activityClicked() { openActivityRow(activityTable.clickedRow); activityTable.deselectAll(nil) }

    private func reviewTapped() {
        if snapshot.status.changes.isEmpty { reviewMenu(); return }
        reviewWorkingTree()
    }
    /// Right-click on the button (or "Review diff" with nothing changed): working tree and branch reviews.
    private func reviewMenu() {
        let menu = NSMenu()
        let n = snapshot.status.changes.count
        let wt = NSMenuItem(title: n == 0 ? "Working tree (no changes)" : "Working tree changes (\(plural(n, "file", "files")))", action: #selector(reviewWorkingTree), keyEquivalent: "")
        wt.target = self; wt.isEnabled = n > 0
        menu.addItem(wt)
        if let b = snapshot.status.branch, !snapshot.status.detached, snapshot.root != nil {
            let item = NSMenuItem(title: "Branch \(b) against its base", action: #selector(reviewBranchTapped), keyEquivalent: "")
            item.target = self; item.isEnabled = muyad != nil
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: reviewButton.bounds.height + 2), in: reviewButton)
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func rightMouseDown(with event: NSEvent) {
        if reviewButton.frame.contains(convert(event.locationInWindow, from: nil)) { reviewMenu() } else { super.rightMouseDown(with: event) }
    }
    @objc private func reviewWorkingTree() { presentReview(on: window) }
    @objc private func reviewBranchTapped() { reviewBranch(on: window) }

    /// Review of the current branch against `main` / `master`, read through muyad (branch_detail, then branch_file_pair per file).
    /// `done` runs on the main thread with an error text when it could not open.
    func reviewBranch(on parent: NSWindow?, done: ((String?) -> Void)? = nil) {
        guard let git = muyad, let root = snapshot.root, let branch = snapshot.status.branch else { done?("muyad is not connected"); return }
        queue.async { [weak self] in
            let r = git.branchDetail(cwd: root, branch: branch)
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case let .failure(e): self.tabBar.trailing = "Review failed: " + e.text; done?(e.text)
                case let .success(info):
                    let model = ReviewModel.branch(info.name, base: info.base, files: info.changedFiles, status: info.changedStatus)
                    self.presentReview(on: parent, model: model, load: { f in
                        switch git.branchFilePair(cwd: root, base: info.base, branch: info.name, path: f.path) {
                        case let .success(p): return DiffParser.fromPair(old: p.old, new: p.new)
                        case let .failure(e): var d = DiffResult(); d.lines = [DiffLine(kind: .note, text: e.text)]; return d
                        }
                    }, onOpen: { [weak self] f in self?.onOpenFile?(URL(fileURLWithPath: root + "/" + f.path)) })
                    done?(nil)
                }
            }
        }
    }
    func select(tab t: Tab) { tab = t }

    /// Re-reads git and the transcript off the main thread; stale answers (the folder changed meanwhile) are dropped.
    func reload() {
        refreshApprovals()
        guard !isHidden, let cwd else { render(); return }
        generation += 1
        let gen = generation, src = source, home = home
        queue.async { [weak self] in
            let snap = src.snapshot(cwd: cwd)
            let ev = src.events(cwd: cwd, root: snap.root, home: home)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.apply(snap, ev)
            }
        }
    }

    func apply(_ snap: InspectorSnapshot, _ ev: [ActivityEvent]) {
        let changed = !loaded || snap != snapshot || ev != events
        loaded = true
        guard changed else { return }
        snapshot = snap; events = ev
        touched = InspectorPane.fileRows(events: ev, status: snap, root: snap.root)
        // Keep the selection across refreshes when the file is still changed.
        if let sel = selectedChange, let again = snap.status.changes.first(where: { $0.path == sel.path }) {
            if again != sel { selectedChange = again; loadDiff() }
        } else { selectedChange = snap.status.changes.first; loadDiff() }
        render()
    }

    static func fileRows(events: [ActivityEvent], status: InspectorSnapshot, root: String?) -> [InspectorFileRow] {
        var rows: [InspectorFileRow] = TranscriptParser.touchedFiles(events).map { InspectorFileRow(path: $0.path, time: $0.lastTouched, note: "\($0.edits) edit\($0.edits == 1 ? "" : "s")") }
        let known = Set(rows.map(\.path))
        if let root {
            for c in status.status.changes {
                let full = root + "/" + c.path
                if known.contains(full) { continue }
                let mtime = (try? FileManager.default.attributesOfItem(atPath: full))?[.modificationDate] as? Date
                rows.append(InspectorFileRow(path: full, time: mtime, note: InspectorFormat.statusWord(c)))
            }
        }
        return rows.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
    }

    private func loadDiff() {
        guard let c = selectedChange, let root = snapshot.root else { diff = DiffResult(); renderDiff(); return }
        let src = source, gen = generation
        queue.async { [weak self] in
            let d = src.diff(root: root, change: c)
            DispatchQueue.main.async {
                guard let self, gen == self.generation, self.selectedChange == c else { return }
                self.diff = d; self.renderDiff()
            }
        }
    }

    // MARK: Render

    private func showTab() {
        tabBar.selected = tab.rawValue
        let changes = tab == .changes
        changesScroll.isHidden = !changes; reviewButton.isHidden = !changes; diffBox.isHidden = !changes
        activityScroll.isHidden = tab != .activity; filesScroll.isHidden = tab != .files
        renderEmpty()
        needsLayout = true
    }

    private func render() {
        changesRows = snapshot.status.changes
        buildActivityRows()
        changesTable.reloadData(); activityTable.reloadData(); filesTable.reloadData()
        if let sel = selectedChange, let i = changesRows.firstIndex(where: { $0.path == sel.path }) {
            changesTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        var bits: [String] = []
        if let b = snapshot.status.branch { bits.append(b) }
        if snapshot.status.ahead > 0 { bits.append("↑\(snapshot.status.ahead)") }
        if snapshot.status.behind > 0 { bits.append("↓\(snapshot.status.behind)") }
        tabBar.titles = ["Changes \(changesRows.count)", "Files", "Activity"]
        tabBar.trailing = snapshot.status.ahead + snapshot.status.behind > 0 ? bits.joined(separator: " ") : ""
        reviewButton.isEnabled = !snapshot.status.changes.isEmpty || (muyad != nil && snapshot.root != nil)
        renderCard()
        renderDiff()
        renderEmpty()
        needsLayout = true
    }

    private func renderEmpty() {
        var msg = ""
        if cwd == nil { msg = "Select a session to inspect its folder." }
        else if !loaded { msg = "Reading…" }
        else if snapshot.root == nil, tab == .changes { msg = "This folder is not a git repository." }
        else if tab == .changes, snapshot.status.changes.isEmpty { msg = "No changes. The working tree is clean." }
        else if tab == .files, touched.isEmpty { msg = "No files touched yet." }
        emptyLabel.stringValue = msg
        emptyLabel.isHidden = msg.isEmpty
        // The list area stays visible under a clean tree so the card and branch stay readable.
        if tab == .changes { changesScroll.isHidden = cwd == nil || !loaded || snapshot.root == nil; reviewButton.isHidden = changesScroll.isHidden; diffBox.isHidden = changesScroll.isHidden }
    }

    private func renderCard() {
        let card = snapshot.card
        let watched = (snapshot.root == nil ? 0 : 1) + card.otherWorktrees.count
        let others = card.otherWorktrees.prefix(3).map { w in ((w.path as NSString).lastPathComponent) + (w.branch.map { " (\($0))" } ?? "") }.joined(separator: ", ")
        if card.isEmpty {
            statusCard.kind = .ok("\(plural(watched, "worktree watched", "worktrees watched")) · \(plural(changesRows.count, "change", "changes"))")
            statusCard.toolTip = others.isEmpty ? nil : "Also checked out: " + others
        } else {
            var lines = card.files.prefix(6).map { $0 }
            if card.files.count > 6 { lines.append("and \(card.files.count - 6) more") }
            statusCard.kind = .conflict(title: card.title, lines: lines)
            statusCard.toolTip = others.isEmpty ? nil : "Also checked out: " + others
        }
    }

    private func renderDiff() {
        guard let c = selectedChange else { diffText.textStorage?.setAttributedString(NSAttributedString()); diffHeader.stringValue = ""; return }
        diffHeader.stringValue = c.path + (diff.binary ? "   binary" : c.isConflicted ? "   conflict markers highlighted" : "   +\(diff.added)  −\(diff.removed)")
        diffText.textStorage?.setAttributedString(InspectorPane.attributed(diff))
    }

    static func attributed(_ d: DiffResult) -> NSAttributedString {
        let font = ThemeFont.mono(11)
        let out = NSMutableAttributedString()
        if d.binary { return NSAttributedString(string: "Binary file: no text diff.", attributes: [.font: font, .foregroundColor: tok(.textMuted)]) }
        let wOld = max(3, String(d.lines.compactMap(\.oldNo).max() ?? 0).count), wNew = max(3, String(d.lines.compactMap(\.newNo).max() ?? 0).count)
        func pad(_ n: Int?, _ w: Int) -> String { let s = n.map(String.init) ?? ""; return String(repeating: " ", count: max(0, w - s.count)) + s }
        for l in d.lines {
            let (fg, bg, sign): (NSColor, NSColor?, String)
            switch l.kind {
            case .add: (fg, bg, sign) = (tok(.text), tok(.success).withAlphaComponent(0.20), "+")
            case .del: (fg, bg, sign) = (tok(.text), tok(.dangerText).withAlphaComponent(0.20), "−")
            case .hunk: (fg, bg, sign) = (tok(.accent), tok(.accent).withAlphaComponent(0.10), " ")
            case .meta, .note: (fg, bg, sign) = (tok(.textMuted), nil, " ")
            case .context: (fg, bg, sign) = (tok(.text), nil, " ")
            }
            let gutter = (l.kind == .hunk || l.kind == .meta || l.kind == .note) ? "" : pad(l.oldNo, wOld) + " " + pad(l.newNo, wNew) + " "
            let line = NSMutableAttributedString(string: gutter, attributes: [.font: font, .foregroundColor: tok(.textFaint)])
            line.append(NSAttributedString(string: sign + " " + l.text + "\n", attributes: [.font: font, .foregroundColor: fg]))
            if let bg { line.addAttribute(.backgroundColor, value: bg, range: NSRange(location: 0, length: line.length)) }
            out.append(line)
        }
        if d.truncated { out.append(NSAttributedString(string: "… diff cut here (too large to show)\n", attributes: [.font: font, .foregroundColor: tok(.textMuted)])) }
        return out
    }

    // MARK: Activity rows

    private func buildActivityRows() {
        var rows: [PaneRow] = []
        let root = snapshot.root ?? cwd ?? ""
        func shown(_ path: String) -> (name: String, dir: String) {
            let rel = InspectorFormat.displayPath(path, cwd: root, home: home)
            let n = (rel as NSString).lastPathComponent, d = (rel as NSString).deletingLastPathComponent
            return (n.isEmpty ? rel : n, d == "/" ? "" : d)
        }
        rows.append(.heading("AGENT FILES", size: 11, before: 16, after: 10))
        var split = AgentFiles.split(events)
        // Files git sees changed that the transcript does not mention still count as modified.
        if let r = snapshot.root, events.isEmpty {   // no transcript: git is the only source of "modified"
            let known = Set(split.modified.map(\.path) + split.read.map(\.path))
            for c in snapshot.status.changes where !known.contains(r + "/" + c.path) { split.modified.append(AgentFile(path: r + "/" + c.path, count: 1)) }
        }
        if cwd == nil {
            rows.append(.text("Select a session to see the files its agent read and changed.", token: .textMuted, after: 10))
        } else if split.modified.isEmpty && split.read.isEmpty {
            rows.append(.text("This session hasn't read or changed any files yet.", token: .textMuted, after: 10))
        } else {
            for (title, files, modified, gap) in [("MODIFIED", split.modified, true, CGFloat(0)), ("READ", split.read, false, CGFloat(8))] where !files.isEmpty {
                rows.append(.heading("\(title) · \(files.count)", size: 10, before: gap, after: 4))
                for f in files { let s = shown(f.path); rows.append(.file(name: s.name, dir: s.dir, modified: modified, count: f.count, path: f.path)) }
            }
        }
        rows.append(.heading("LOCK / EDIT TELEMETRY", size: 11, before: 16, after: 10))
        let watched = (snapshot.root == nil ? 0 : 1) + snapshot.card.otherWorktrees.count
        let edits = snapshot.status.changes.count
        rows.append(.text("\(plural(watched, "worktree watched", "worktrees watched")) · \(edits) uncommitted \(edits == 1 ? "change" : "changes") tracked", token: .textMuted, after: 10))
        if snapshot.card.isEmpty {
            rows.append(.text("No file collisions across worktrees.", token: .successCardText, after: 10))
        } else {
            for f in snapshot.card.files.prefix(6) { rows.append(.collision(file: f, note: snapshot.card.title)) }
        }
        if !events.isEmpty {
            rows.append(.heading("TIMELINE", size: 11, before: 6, after: 8))
            for e in events.reversed().prefix(200) {
                rows.append(.event(title: e.title, detail: InspectorFormat.displayPath(e.detail, cwd: root, home: home), time: InspectorFormat.ago(e.time)))
            }
        }
        activityRows = rows
    }

    private func height(of row: PaneRow, width: CGFloat) -> CGFloat {
        switch row {
        case .change: return 32
        case let .heading(_, size, before, after): return before + size + 3 + after
        case .file: return 28
        case let .text(t, _, after): return measured(styled(t, ThemeFont.sans(12), .black, mode: .byWordWrapping), width: width - 32) + after
        case .collision: return 64
        case .event: return 38
        case .touched: return 28
        }
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === changesTable ? changesRows.count : tableView === filesTable ? touched.count : activityRows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView === changesTable ? 32 : tableView === filesTable ? 28 : height(of: activityRows[row], width: tableView.bounds.width)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaneRowView() }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === changesTable || tableView === filesTable { return true }
        if case .file = activityRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("pane-cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? PaneCell) ?? { let c = PaneCell(); c.identifier = id; return c }()
        if tableView === changesTable {
            let c = changesRows[row]
            cell.row = .change(letter: c.isUntracked ? "?" : c.badge, token: Self.token(for: c), name: c.path, dir: "", trailing: c.kinds.contains(.staged) && !c.isUntracked ? "staged" : "")
            cell.setAccessibilityLabel("\(InspectorFormat.statusWord(c)) \(c.path)")
        } else if tableView === filesTable {
            let f = touched[row]
            let rel = InspectorFormat.displayPath(f.path, cwd: snapshot.root ?? cwd ?? "", home: home)
            cell.row = .touched(name: (rel as NSString).lastPathComponent, dir: (rel as NSString).deletingLastPathComponent, note: f.note + (f.time == nil ? "" : " · " + InspectorFormat.ago(f.time)))
            cell.setAccessibilityLabel("\(f.path), \(f.note)")
        } else {
            let r = activityRows[row]
            cell.row = r
            switch r {
            case let .file(name, dir, modified, count, _): cell.setAccessibilityLabel("\(modified ? "Modified" : "Read") \(name) \(dir)\(count > 1 ? ", \(count) times" : "")")
            case let .event(title, detail, _): cell.setAccessibilityLabel("\(title) \(detail)")
            case let .heading(t, _, _, _): cell.setAccessibilityLabel(t)
            case let .text(t, _, _): cell.setAccessibilityLabel(t)
            case let .collision(f, n): cell.setAccessibilityLabel("\(f), \(n)")
            case .change, .touched: break
            }
        }
        return cell
    }

    static func token(for c: GitChange) -> Theme.Token {
        if c.isConflicted { return .dangerText }
        if c.isUntracked { return .textMuted }
        switch c.y != " " ? c.y : c.x {
        case "A": return .success
        case "D": return .dangerText
        default: return .warning
        }
    }
    static func color(for c: GitChange) -> NSColor { tok(token(for: c)) }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === changesTable else { return }
        let i = changesTable.selectedRow
        guard i >= 0, i < changesRows.count, changesRows[i] != selectedChange else { return }
        selectedChange = changesRows[i]
        loadDiff()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, !activityRows.isEmpty { activityTable.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<activityRows.count)) }
    }

    // MARK: Test / debug hooks

    var changeRowCount: Int { changesRows.count }
    func selectChange(path: String) { if let i = changesRows.firstIndex(where: { $0.path == path }) { selectChange(at: i) } }
    func selectChange(at i: Int) { changesTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }
    var diffString: String { diffText.string }
    var approvalCount: Int { approvals.items.count }
}

struct InspectorFileRow: Equatable {
    var path: String
    var time: Date?
    var note: String
}

/// The terminal area plus the Inspector on its right (320px, 260-520); the pane starts hidden (View > Inspector, ⌥⌘I).
final class InspectorSplit: HidingDividerSplit, NSSplitViewDelegate {
    let inspector: InspectorPane
    private var width: CGFloat = ThemeMetric.inspectorWidth

    init(content: NSView, inspector: InspectorPane) {
        self.inspector = inspector
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(content)
        addArrangedSubview(inspector)
        setHoldingPriority(.init(260), forSubviewAt: 1)
        inspector.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var dividerColor: NSColor { tok(.border) }

    func toggle() {
        let show = inspector.isHidden
        let wanted = width   // the layout pass below resizes the pane and splitViewDidResizeSubviews would overwrite `width` with that
        inspector.isHidden = !show
        if show { layoutSubtreeIfNeeded(); width = wanted; setPosition(max(bounds.width - wanted, 320), ofDividerAt: 0) }
        adjustSubviews()
    }

    func splitView(_ s: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { max(320, s.bounds.width - ThemeMetric.inspectorWidthMax) }
    func splitView(_ s: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { s.bounds.width - ThemeMetric.inspectorWidthMin }
    func splitView(_ s: NSSplitView, canCollapseSubview v: NSView) -> Bool { false }
    func splitViewDidResizeSubviews(_ n: Notification) { if !inspector.isHidden, inspector.frame.width > 100 { width = inspector.frame.width } }
}

extension MainController {
    /// Wires the pane to the app: where `~` is, whether the window is on screen, double-click opens a file, approvals.
    func installInspector() {
        inspector.home = store.home
        let st = store
        inspector.muyad = MuyadGit { method, params in
            if Thread.isMainThread { return .failure("muyad calls must not block the main thread") }
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out: Result<Any, RpcText> = .failure("muyad did not answer")
            nonisolated(unsafe) let p = params
            DispatchQueue.main.async {
                _ = MainActor.assumeIsolated {
                    st.call(method, p) { r in
                        switch r { case let .success(v): out = .success(v); case let .failure(e): out = .failure(RpcText(describe(e))) }
                        sem.signal()
                    }
                }
            }
            return sem.wait(timeout: .now() + 20) == .timedOut ? .failure("muyad did not answer in time") : out
        }
        let env = ProcessInfo.processInfo.environment
        if env["MUYA_MOCK"] == "1", env["MUYA_DEBUG_SOCKET"] != nil { inspector.source = MockInspectorSource() }   // dev mock mode: the web mock's 14 changes
        inspector.windowVisible = { [weak self] in (self?.windowVisible ?? true) && !(self?.sleeping ?? false) }
        inspector.onOpenFile = { [weak self] url in
            self?.openViewer(url, FileKind.detect(url))
        }
        inspector.approvalsProvider = { [weak st] in
            guard let st else { return [] }
            return st.sessions.compactMap { s in
                guard s.exited == nil, let sc = s.screen, sc.permission else { return nil }
                let p = InspectorApproval.parse(promptKey: sc.promptKey)
                return InspectorApproval(id: s.id, name: s.name, tool: p.tool, target: p.target, question: p.question, actionable: sc.approveKey != nil)
            }
        }
        inspector.onAllow = { [weak st] id in st?.answerPrompt(session: id, approve: true) }
        inspector.onDeny = { [weak st] id in st?.answerPrompt(session: id, approve: false) }
        inspector.onOpenSession = { [weak st] id in if let s = st?.sessions.first(where: { $0.id == id }) { st?.select(s) } }
        // Verification hook: open the pane on a tab at launch (verify-inspector.sh).
        if let t = ProcessInfo.processInfo.environment["MUYA_INSPECTOR_TAB"] {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                (self.inspector.superview as? InspectorSplit)?.toggle()
                self.inspector.select(tab: t == "files" ? .files : t == "activity" ? .activity : .changes)
                self.inspector.cwd = self.store.selected?.cwd
                if let f = ProcessInfo.processInfo.environment["MUYA_INSPECTOR_FILE"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.inspector.selectChange(path: f) }
                }
            }
        }
    }

    @objc func toggleInspector() {
        guard let split = inspector.superview as? InspectorSplit else { return }
        split.toggle()
        if !inspector.isHidden { inspector.cwd = store.selected?.cwd }
        if !panelLayoutLocked { onInspectorChoice?(!inspector.isHidden) }   // an automatic hide / show runs with the layout locked
    }
}

// MARK: Review changes (the "Uncommitted changes" dialog)

/// Two columns of one file's diff: before on the left, after on the right, 18px rows, line numbers and a +/− sign.
final class SideBySideView: NSView {
    var rows: [SideRow] = [] { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var message: String?
    static let rowHeight: CGFloat = 18
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(rows.count) * Self.rowHeight + 8) }

    private var font: NSFont { ThemeFont.mono(12) }
    override func draw(_ dirtyRect: NSRect) {
        if let message {
            drawLine(styled(message, ThemeFont.sans(12), tok(.textMuted), mode: .byTruncatingTail), in: NSRect(x: 16, y: 8, width: bounds.width - 32, height: 18))
            return
        }
        let half = floor((bounds.width - 1) / 2)
        let first = max(0, Int((dirtyRect.minY - 4) / Self.rowHeight)), last = min(rows.count - 1, Int((dirtyRect.maxY - 4) / Self.rowHeight))
        guard first <= last else { return }
        tok(.border).setFill(); NSRect(x: half, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        for i in first...last {
            let r = rows[i], y = 4 + CGFloat(i) * Self.rowHeight
            if let sep = r.separator {
                tok(.accent).withAlphaComponent(0.10).setFill(); NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight).fill()
                drawLine(styled(sep, font, tok(.textMuted), mode: .byTruncatingTail), in: NSRect(x: 12, y: y, width: bounds.width - 24, height: Self.rowHeight), lineHeight: Self.rowHeight)
                continue
            }
            // A modified line (del on the left, add on the right): the changed characters get a stronger fill, like Monaco's diff editor.
            var spans: (old: [Range<Int>], new: [Range<Int>]) = ([], [])
            if let l = r.left, let rr = r.right, l.kind == .del, rr.kind == .add { spans = CharDiff.spans(old: l.text, new: rr.text) }
            side(r.left, x: 0, width: half, y: y, old: true, changed: spans.old)
            side(r.right, x: half + 1, width: bounds.width - half - 1, y: y, old: false, changed: spans.new)
        }
    }
    private func side(_ l: DiffLine?, x: CGFloat, width: CGFloat, y: CGFloat, old: Bool, changed: [Range<Int>] = []) {
        guard let l else { return }
        let rect = NSRect(x: x, y: y, width: width, height: Self.rowHeight)
        if l.kind == .del { tok(.dangerText).withAlphaComponent(0.25).setFill(); rect.fill() }
        else if l.kind == .add { tok(.success).withAlphaComponent(0.25).setFill(); rect.fill() }
        let charW = ("M" as NSString).size(withAttributes: [.font: font]).width
        for r in changed {   // stronger fill under the characters that differ
            (old ? tok(.dangerText) : tok(.success)).withAlphaComponent(0.45).setFill()
            NSRect(x: x + 56 + CGFloat(r.lowerBound) * charW, y: y + 1, width: CGFloat(r.count) * charW, height: Self.rowHeight - 2).fill()
        }
        let no = old ? l.oldNo : l.newNo
        drawLine(styled(no.map(String.init) ?? "", font, tok(.textFaint), mode: .byClipping, align: .right), in: NSRect(x: x, y: y, width: 36, height: Self.rowHeight), lineHeight: Self.rowHeight)
        let sign = l.kind == .del ? "−" : l.kind == .add ? "+" : " "
        drawLine(styled(sign, font, tok(.textMuted), mode: .byClipping), in: NSRect(x: x + 42, y: y, width: 10, height: Self.rowHeight), lineHeight: Self.rowHeight)
        drawLine(styled(l.text, font, tok(.text), mode: .byClipping), in: NSRect(x: x + 56, y: y, width: max(0, width - 60), height: Self.rowHeight), lineHeight: Self.rowHeight)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The file list on the left of the dialog (260px, bordered, radius 8; rows: letter + path, selected = --bg-selected).
private final class ReviewList: NSView {
    var files: [ReviewFile] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    static let rowHeight: CGFloat = 30
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    var docHeight: CGFloat { CGFloat(files.count) * Self.rowHeight + 8 }

    override func draw(_ dirtyRect: NSRect) {
        let first = max(0, Int((dirtyRect.minY - 4) / Self.rowHeight)), last = min(files.count - 1, Int((dirtyRect.maxY - 4) / Self.rowHeight))
        guard first <= last else { return }
        for i in first...last {
            let f = files[i], y = 4 + CGFloat(i) * Self.rowHeight
            if i == selected { fillRounded(NSRect(x: 4, y: y, width: bounds.width - 8, height: Self.rowHeight), radius: 6, fill: tok(.bgSelected), stroke: nil) }
            let token: Theme.Token = f.code == "A" || f.code == "U" || f.code == "?" ? .success : f.code == "D" || f.code == "!" ? .dangerText : .warning
            drawLine(styled(f.code == "U" ? "?" : f.code, ThemeFont.mono(12), tok(token), mode: .byClipping), in: NSRect(x: 12, y: y, width: 12, height: Self.rowHeight), lineHeight: 18)
            drawLine(styled(f.path, ThemeFont.mono(12), tok(.text), mode: .byTruncatingHead), in: NSRect(x: 32, y: y, width: bounds.width - 44, height: Self.rowHeight), lineHeight: 18)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int((p.y - 4) / Self.rowHeight)
        if files.indices.contains(i) { onSelect?(i) }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The × in the dialog title bar: 28 x 28, no border, --text-muted.
private final class CloseCross: NSControl {
    var onClick: (() -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityRole(.button); setAccessibilityLabel("Close") }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY), d: CGFloat = 4.5
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x - d, y: c.y - d)); p.line(to: NSPoint(x: c.x + d, y: c.y + d))
        p.move(to: NSPoint(x: c.x + d, y: c.y - d)); p.line(to: NSPoint(x: c.x - d, y: c.y + d))
        p.lineWidth = 1.6; p.lineCapStyle = .round
        tok(.textMuted).setStroke(); p.stroke()
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The Review changes dialog body (modalKit ModalShell look): title + ×, the changed files on the left, one file's
/// before | after on the right, "File 1 of N · [ and ] to move" and Open in editor / Prev / Next below.
/// `[` and `]` move between files (see `ReviewWindow`).
final class ReviewPanel: NSView {
    private(set) var model: ReviewModel
    /// Reads one file's diff; runs off the main thread.
    var load: (ReviewFile) -> DiffResult = { _ in DiffResult() }
    var onClose: (() -> Void)?
    var onOpenFile: ((ReviewFile) -> Void)?

    private let list = ReviewList()
    private let listScroll = NSScrollView()
    private let diffView = SideBySideView()
    private let diffScroll = NSScrollView()
    private let close = CloseCross()
    private let prevButton = PaneButton("← Prev")
    private let nextButton = PaneButton("Next →")
    private let openButton = PaneButton("Open in editor")
    private var titleText = "", footerText = "", pathText = ""
    private var generation = 0
    private let queue = DispatchQueue(label: "review.read", qos: .userInitiated)
    private var lastDiff = DiffResult()

    static let headerHeight: CGFloat = 56, footerHeight: CGFloat = 58, listWidth: CGFloat = 260

    init(model: ReviewModel, frame: NSRect = NSRect(x: 0, y: 0, width: 1240, height: 660)) {
        self.model = model
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(model.title)
        build()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        list.onSelect = { [weak self] i in guard let self, i != self.model.index else { return }; self.model.select(i); self.refresh() }
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true; listScroll.drawsBackground = false; listScroll.borderType = .noBorder; listScroll.scrollerStyle = .overlay
        listScroll.setAccessibilityLabel("Changed files")
        diffScroll.documentView = diffView
        diffScroll.hasVerticalScroller = true; diffScroll.drawsBackground = false; diffScroll.borderType = .noBorder; diffScroll.scrollerStyle = .overlay
        diffView.setAccessibilityLabel("Diff")
        close.onClick = { [weak self] in self?.onClose?() }
        prevButton.onClick = { [weak self] in self?.prevTapped() }
        nextButton.onClick = { [weak self] in self?.nextTapped() }
        openButton.onClick = { [weak self] in self?.openTapped() }
        prevButton.setAccessibilityLabel("Previous file"); nextButton.setAccessibilityLabel("Next file")
        for v in [listScroll, diffScroll, close, prevButton, nextButton, openButton] as [NSView] { addSubview(v) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var listRect: NSRect { NSRect(x: 12, y: Self.headerHeight + 12, width: Self.listWidth, height: max(0, bounds.height - Self.headerHeight - Self.footerHeight - 24)) }
    private var rightRect: NSRect { NSRect(x: 12 + Self.listWidth + 12, y: listRect.minY, width: max(0, bounds.width - 36 - Self.listWidth), height: listRect.height) }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        close.frame = NSRect(x: w - 20 - 28, y: (Self.headerHeight - 28) / 2, width: 28, height: 28)
        listScroll.frame = listRect.insetBy(dx: 1, dy: 1)
        list.frame = NSRect(x: 0, y: 0, width: listScroll.frame.width, height: max(list.docHeight, listScroll.frame.height))
        let r = rightRect
        diffScroll.frame = NSRect(x: r.minX + 1, y: r.minY + 37, width: max(0, r.width - 2), height: max(0, r.height - 38))
        diffView.frame = NSRect(x: 0, y: 0, width: diffScroll.frame.width, height: max(CGFloat(diffView.rows.count) * SideBySideView.rowHeight + 8, diffScroll.frame.height))
        let by = h - Self.footerHeight + (Self.footerHeight - 32) / 2
        nextButton.frame = NSRect(x: w - 20 - nextButton.naturalWidth, y: by, width: nextButton.naturalWidth, height: 32)
        prevButton.frame = NSRect(x: nextButton.frame.minX - 8 - prevButton.naturalWidth, y: by, width: prevButton.naturalWidth, height: 32)
        openButton.frame = NSRect(x: prevButton.frame.minX - 8 - openButton.naturalWidth, y: by, width: openButton.naturalWidth, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        fillRounded(bounds, radius: 12, fill: tok(.bgPanel), stroke: tok(.border))
        tok(.border).setFill()
        NSRect(x: 1, y: Self.headerHeight - 1, width: w - 2, height: 1).fill()
        NSRect(x: 1, y: h - Self.footerHeight, width: w - 2, height: 1).fill()
        drawLine(styled(titleText, ThemeFont.sans(15, .semibold), tok(.text)), in: NSRect(x: 20, y: 0, width: w - 80, height: Self.headerHeight - 1), lineHeight: 22)
        fillRounded(listRect, radius: 8, fill: nil, stroke: tok(.border))
        let r = rightRect
        fillRounded(r, radius: 8, fill: nil, stroke: tok(.border))
        tok(.border).setFill(); NSRect(x: r.minX + 1, y: r.minY + 36, width: r.width - 2, height: 1).fill()
        let right = "before · after"
        let rw = ceil(styled(right, ThemeFont.mono(12), .black).size().width)
        drawLine(styled(right, ThemeFont.mono(12), tok(.textMuted), mode: .byClipping, align: .right), in: NSRect(x: r.maxX - 12 - rw, y: r.minY, width: rw, height: 36), lineHeight: 18)
        drawLine(styled(pathText, ThemeFont.mono(12), tok(.textMuted), mode: .byTruncatingTail), in: NSRect(x: r.minX + 12, y: r.minY, width: r.width - 36 - rw, height: 36), lineHeight: 18)
        drawLine(styled(footerText, ThemeFont.sans(12), tok(.textMuted)), in: NSRect(x: 20, y: h - Self.footerHeight, width: openButton.frame.minX - 32, height: Self.footerHeight), lineHeight: 16)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func cancelOperation(_ sender: Any?) { onClose?() }

    // MARK: State

    /// Syncs every control with the model and starts reading the current file's diff.
    func refresh() {
        titleText = model.title; footerText = model.footer
        setAccessibilityLabel(model.title)
        prevButton.isEnabled = model.canPrev
        nextButton.isEnabled = model.canNext
        let f = model.current
        openButton.isEnabled = f != nil && !(f?.isFolder ?? true) && f?.code != "D" && onOpenFile != nil
        list.files = model.files; list.selected = model.index
        if f != nil {
            let top = listScroll.contentView
            let y = 4 + CGFloat(model.index) * ReviewList.rowHeight
            if y < top.bounds.minY || y + ReviewList.rowHeight > top.bounds.maxY { top.scroll(to: NSPoint(x: 0, y: max(0, y - 40))); listScroll.reflectScrolledClipView(top) }
        }
        generation += 1
        guard let f else { lastDiff = DiffResult(); showDiff(lastDiff, loading: false); needsLayout = true; needsDisplay = true; return }
        pathText = f.path
        if f.isFolder {
            var d = DiffResult(); d.lines = [DiffLine(kind: .note, text: "A new folder: open it in the file tree to see what is inside.")]
            lastDiff = d; showDiff(d); return
        }
        let gen = generation, loader = load
        diffView.message = "Loading…"; diffView.rows = []
        needsLayout = true; needsDisplay = true
        queue.async { [weak self] in
            let d = loader(f)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.lastDiff = d; self.showDiff(d)
            }
        }
    }

    private func showDiff(_ d: DiffResult, loading: Bool = false) {
        diffView.message = d.binary ? "Binary file: no text diff." : nil
        diffView.rows = d.binary ? [] : SideBySide.rows(d)
        if let f = model.current ?? nil { let c = d.lineCounts; headerCounts = d.binary ? "binary" : "+\(c.added)  −\(c.removed)"; pathText = f.path } else { pathText = ""; headerCounts = "" }
        diffScroll.contentView.scroll(to: .zero)
        needsLayout = true; needsDisplay = true
    }
    private var headerCounts = ""

    /// `[` / `]`. True when the key was one of ours.
    @discardableResult func handle(key: String) -> Bool {
        let before = model.index
        guard model.handle(key: key) else { return false }
        if model.index != before { refresh() }
        return true
    }

    private func prevTapped() { if model.prev() { refresh() } }
    private func nextTapped() { if model.next() { refresh() } }
    private func openTapped() { if let f = model.current { onOpenFile?(f) } }

    // MARK: Test hooks

    /// The diff as text, one line per diff line (hunk headers and notes included).
    var diffString: String { lastDiff.binary ? "Binary file: no text diff." : lastDiff.lines.filter { $0.kind != .meta }.map(\.text).joined(separator: "\n") + "\n" }
    var footerString: String { footerText }
    /// Path and counts of the file shown ("path   +n  −m").
    var headerString: String { pathText + (headerCounts.isEmpty ? "" : "   " + headerCounts) }
    var currentIndex: Int { model.index }
    var sideRows: [SideRow] { diffView.rows }
}

/// A grey-out of the app under the dialog (modalKit: rgba(0,0,0,.5)); a click on it closes the dialog.
final class ReviewBackdrop: NSView {
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.withAlphaComponent(0.5).setFill(); bounds.fill() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// The dialog window: borderless, clear, child of the main window. Swallows `[` and `]` before any focused control.
final class ReviewWindow: NSWindow {
    weak var panel: ReviewPanel?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let k = event.charactersIgnoringModifiers, k == "[" || k == "]", panel?.handle(key: k) == true { return }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { panel?.onClose?() }
}

extension InspectorPane {
    /// Opens Review changes over `parent` for the working tree (or, with `model`, any other change set).
    @discardableResult
    func presentReview(on parent: NSWindow?, model: ReviewModel? = nil, load: ((ReviewFile) -> DiffResult)? = nil, onOpen: ((ReviewFile) -> Void)? = nil) -> ReviewPanel {
        reviewWindow.map { $0.parent?.removeChildWindow($0); $0.orderOut(nil) }
        var m = model ?? ReviewModel.workingTree(snapshot.status.changes)
        if model == nil, let root = snapshot.root { m.title = "Uncommitted changes · " + (root as NSString).lastPathComponent }
        let root = snapshot.root, src = source
        let panel = ReviewPanel(model: m)
        panel.load = load ?? { f in
            guard let root, let c = f.change else { return DiffResult() }
            return src.diff(root: root, change: c)
        }
        panel.onOpenFile = onOpen ?? { [weak self] f in
            guard let root else { return }
            self?.onOpenFile?(URL(fileURLWithPath: root + "/" + f.path))
        }
        panel.refresh()
        reviewPanel = panel

        let win = ReviewWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = true
        win.contentView = panel
        win.panel = panel
        win.isReleasedWhenClosed = false
        reviewWindow = win

        var backdrop: ReviewBackdrop?
        var observer: NSObjectProtocol?
        // modalKit ModalShell: 1240 wide (24px margin each side at most), 64vh of body + header + footer, centred.
        func place() {
            guard let parent else { win.center(); return }
            // Today's dialog is 64vh of the webview, and the webview covers the whole window (the title bar is overlaid): use the whole content view, not the area below the title bar.
            let c = parent.contentLayoutRect, vh = parent.contentView?.bounds.height ?? c.height
            let w = min(1240, c.width - 48)
            let h = min(0.85 * vh, 0.64 * vh + 24 + ReviewPanel.headerHeight + ReviewPanel.footerHeight)
            let content = parent.contentView?.convert(parent.contentView!.bounds, to: nil) ?? .zero
            let f = parent.convertToScreen(NSRect(x: content.midX - w / 2, y: content.midY - h / 2, width: w, height: h))
            win.setFrame(f, display: true)
        }
        panel.onClose = { [weak win, weak parent, weak self] in
            guard let win else { return }
            if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
            backdrop?.removeFromSuperview(); backdrop = nil
            parent?.removeChildWindow(win)
            win.orderOut(nil)
            if self?.reviewWindow === win { self?.reviewWindow = nil }
            parent?.makeKeyAndOrderFront(nil)
        }
        if let parent, let content = parent.contentView {
            let b = ReviewBackdrop(frame: content.bounds)
            b.autoresizingMask = [.width, .height]
            b.onClick = { [weak panel] in panel?.onClose?() }
            content.addSubview(b, positioned: .above, relativeTo: nil)
            backdrop = b
            parent.addChildWindow(win, ordered: .above)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main) { _ in MainActor.assumeIsolated { place() } }
        }
        place()
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(panel)
        return panel
    }
}

// MARK: Dev mock (MUYA_MOCK=1)

/// The web UI's mock Inspector data (src/mock: 14 changes, agent files, 3 worktrees) so ui-diff compares style, not content.
/// Only installed in the dev mock mode; a normal launch never sees it.
final class MockInspectorSource: InspectorSource {
    private let changes: [(String, Character, Character)] = [
        ("src-tauri/src/pty.rs", " ", "M"), ("src-tauri/src/agents.rs", " ", "M"), ("tasks/todo.md", " ", "M"), ("src/App.tsx", " ", "M"),
        ("src/components/Terminal.tsx", " ", "M"), ("src/components/FileTree.tsx", " ", "M"), ("docs/prd-redesign-v0.4.md", "A", " "),
        ("src-tauri/src/fs.rs", " ", "M"), ("src-tauri/src/ssh.rs", " ", "M"), ("docs/handoff-2026-09-30.md", "?", "?"),
        ("package.json", " ", "M"), ("src/lib/tabs.ts", " ", "M"), ("src-tauri/Cargo.lock", " ", "M"), ("README.md", " ", "M"),
    ]
    func snapshot(cwd: String) -> InspectorSnapshot {
        var snap = InspectorSnapshot()
        snap.root = cwd
        snap.status.branch = "main"
        snap.status.changes = changes.map { GitChange(path: $0.0, origPath: nil, x: $0.1, y: $0.2) }
        snap.card = ConflictCard(operation: nil, files: [], otherWorktrees: [Worktree(path: cwd + "-a", branch: "a"), Worktree(path: cwd + "-b", branch: "b")], isLinkedWorktree: false)
        return snap
    }
    func diff(root: String, change: GitChange) -> DiffResult {
        var d = DiffResult()
        func ctx(_ t: String, _ o: Int, _ n: Int) -> DiffLine { DiffLine(kind: .context, text: t, oldNo: o, newNo: n) }
        func del(_ t: String, _ o: Int) -> DiffLine { DiffLine(kind: .del, text: t, oldNo: o, newNo: nil) }
        func add(_ t: String, _ n: Int) -> DiffLine { DiffLine(kind: .add, text: t, oldNo: nil, newNo: n) }
        switch change.path {
        case "src-tauri/src/pty.rs":   // a changed word and a changed argument, so the character-level highlight shows
            d.lines = [ctx("pub fn spawn(shell: &str) -> Result<Pty> {", 41, 41),
                       del("    let child = Command::new(cmd).arg(\"-l\").spawn()?;", 42), add("    let child = Command::new(command).arg(\"-i\").spawn()?;", 42),
                       ctx("    Ok(Pty::new(child))", 43, 43), ctx("}", 44, 44)]
            d.added = 1; d.removed = 1
        default:
            d.lines = [del("const answer = 41;", 1), add("const answer = 42;", 1), ctx("export default answer;", 2, 2)]
            d.added = 1; d.removed = 1
        }
        return d
    }
    func events(cwd: String, root: String?, home: String) -> [ActivityEvent] {
        let now = Date()
        func e(_ k: ActivityEvent.Kind, _ p: String, _ ago: Double) -> ActivityEvent {
            ActivityEvent(time: now.addingTimeInterval(-ago), kind: k, title: k == .read ? "Read" : "Edit", detail: p, path: p)
        }
        return [e(.read, cwd + "/README.md", 600), e(.read, cwd + "/README.md", 590), e(.read, cwd + "/src/redesign/ActivityPanel.tsx", 500), e(.read, "/etc/hosts", 400),
                e(.edit, cwd + "/src/App.tsx", 300), e(.edit, cwd + "/src/App.tsx", 200), e(.edit, cwd + "/src/App.tsx", 100), e(.edit, cwd + "/src-tauri/src/lib.rs", 50)]
    }
}
