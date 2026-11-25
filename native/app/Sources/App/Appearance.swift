// P5 — the two footer popovers of today's Muya: Terminal appearance (src/redesign/TerminalAppearance.tsx: font size, line
// spacing, colours) and the status field picker (StatusPicker.tsx: which Claude status fields the footer shows).

import AppKit

final class StepperRow: NSView {
    private let value = NSTextField(labelWithString: "")
    var onStep: ((Int) -> Void)?
    var onReset: (() -> Void)?
    init(title: String, hint: String? = nil) {
        super.init(frame: .zero)
        let t = ThemedText.label(title)
        let minus = ThemedButton("−"), plus = ThemedButton("+"), reset = ThemedButton("Reset")
        value.font = ThemeFont.mono(13); value.textColor = Theme.dynamic(.text); value.alignment = .center
        value.setContentHuggingPriority(.required, for: .horizontal)
        minus.onClick = { [weak self] in self?.onStep?(-1) }; plus.onClick = { [weak self] in self?.onStep?(1) }; reset.onClick = { [weak self] in self?.onReset?() }
        minus.setAccessibilityLabel("Decrease \(title)"); plus.setAccessibilityLabel("Increase \(title)")
        let row = Kit.hstack([minus, value, plus, NSView(), reset], spacing: 8)
        var views: [NSView] = [t, row]
        if let hint { views.append(ThemedText.helper(hint)) }
        let col = Kit.vstack(views, spacing: 6)
        col.translatesAutoresizingMaskIntoConstraints = false; addSubview(col)
        NSLayoutConstraint.activate([col.topAnchor.constraint(equalTo: topAnchor), col.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     col.leadingAnchor.constraint(equalTo: leadingAnchor), col.trailingAnchor.constraint(equalTo: trailingAnchor)])
        value.widthAnchor.constraint(equalToConstant: 64).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ text: String) { value.stringValue = text }
}

enum AppearancePopover {
    /// The card above the footer's Aa button (OverlayPopover: --bg-panel, 1px border, radius 12). Returns it so the caller can close it.
    @discardableResult
    static func show(in window: NSWindow, from anchor: NSView, rect: NSRect, size: Int, spacing: Double, scheme: String = "muya", onSize: @escaping (Int) -> Void, onSpacing: @escaping (Double) -> Void, onScheme: @escaping (String) -> Void = { _ in }) -> OverlayPopover {
        let sizeRow = StepperRow(title: "FONT SIZE", hint: "In a terminal: ⌘+ larger · ⌘− smaller · ⌘0 default")
        let lineRow = StepperRow(title: "LINE SPACING")
        var sz = size, ls = spacing
        sizeRow.set("\(sz) px"); lineRow.set(String(format: "%.1f", ls))
        sizeRow.onStep = { d in sz = min(TerminalKeys.fontMax, max(TerminalKeys.fontMin, sz + d)); sizeRow.set("\(sz) px"); onSize(sz) }
        sizeRow.onReset = { sz = TerminalKeys.fontDefault; sizeRow.set("\(sz) px"); onSize(sz) }
        lineRow.onStep = { d in ls = min(2.0, max(1.0, (ls * 10).rounded() / 10 + Double(d) * 0.1)); lineRow.set(String(format: "%.1f", ls)); onSpacing(ls) }
        lineRow.onReset = { ls = 1.6; lineRow.set("1.6"); onSpacing(1.6) }
        let colors = ThemedText.label("COLORS")
        let rows = TerminalSchemes.all.map { SchemeRow(id: $0.id, label: $0.label, on: $0.id == scheme) }
        for r in rows { r.onPick = { id in for o in rows { o.on = o.id == id }; onScheme(id) } }
        let list = Kit.vstack(rows, spacing: 1)
        list.alignment = .leading
        let col = Kit.vstack([sizeRow, lineRow, colors, list], spacing: 14)
        col.alignment = .leading
        for v in [sizeRow, lineRow, list] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        for r in rows { r.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        let pop = OverlayPopover(content: col, width: 300, inset: NSEdgeInsets(top: 14, left: 12, bottom: 12, right: 12))
        pop.setAccessibilityLabel("Terminal appearance")
        pop.show(in: window, anchor: anchor, anchorRect: rect, edge: .aboveTrailing)
        return pop
    }
}

/// One colour scheme of the popover: tick, a swatch drawn from the scheme's own palette (background, "A", six colour dots) and its name.
final class SchemeRow: NSControl {
    let id: String, label: String
    var on: Bool { didSet { needsDisplay = true } }
    var onPick: ((String) -> Void)?
    private var hover = false
    init(id: String, label: String, on: Bool) {
        self.id = id; self.label = label; self.on = on
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityRole(.radioButton); setAccessibilityLabel(label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func accessibilityValue() -> Any? { on ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onPick?(id); return true }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onPick?(id) }
    override func draw(_ dirtyRect: NSRect) {
        if hover { Theme.dynamic(.bgSelected).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        if on { ("✓" as NSString).draw(at: NSPoint(x: 10, y: (bounds.height - 16) / 2), withAttributes: [.font: ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.accent)]) }
        // The swatch shows the scheme as it looks under the current appearance ("muya" follows it).
        let t = TerminalTheme.fixed(id) ?? TerminalTheme.current(for: effectiveAppearance, scheme: "muya")
        let sw = NSRect(x: 30, y: (bounds.height - 18) / 2, width: 4 + 10 + 2 + 6 * 8 + 3, height: 18)
        let p = NSBezierPath(roundedRect: sw.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        t.background.color.setFill(); p.fill(); Theme.dynamic(.border).setStroke(); p.lineWidth = 1; p.stroke()
        ("A" as NSString).draw(at: NSPoint(x: sw.minX + 5, y: sw.minY + 3), withAttributes: [.font: ThemeFont.mono(10), .foregroundColor: t.foreground.color])
        for (i, k) in [1, 2, 3, 4, 5, 6].enumerated() {   // red green yellow blue magenta cyan
            t.ansi[k].color.setFill()
            NSBezierPath(ovalIn: NSRect(x: sw.minX + 20 + CGFloat(i) * 8, y: sw.midY - 3, width: 6, height: 6)).fill()
        }
        let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.text)]
        (label as NSString).draw(at: NSPoint(x: sw.maxX + 8, y: (bounds.height - 16) / 2), withAttributes: a)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One group heading of the field popover (classic MenuHeading: 11 px / 600, letter-spaced, --text-muted, 6/4 padding).
private final class FieldHeadingView: NSView {
    private let text: String
    init(_ t: String) { text = t.uppercased(); super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        (text as NSString).draw(at: NSPoint(x: 14, y: 6), withAttributes: [.font: ThemeFont.sans(11, .semibold), .kern: 0.66, .foregroundColor: Theme.dynamic(.textMuted)])
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One status field: check mark, label on the left, live value right-aligned (classic StatusPicker row: 28 px, 13 px label, 12 px muted value).
private final class FieldRowView: NSControl {
    let id: String, label: String, value: String?
    var on: Bool { didSet { needsDisplay = true } }
    var onPick: ((String) -> Void)?
    private var hover = false
    init(id: String, label: String, value: String?, on: Bool) {
        self.id = id; self.label = label; self.value = value; self.on = on
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityRole(.checkBox); setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func accessibilityValue() -> Any? { on ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onPick?(id); return true }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onPick?(id) }
    override func draw(_ dirtyRect: NSRect) {
        if hover { Theme.dynamic(.bgSelected).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        let lf = ThemeFont.sans(13), vf = ThemeFont.sans(12)
        if on { ("✓" as NSString).draw(at: NSPoint(x: 10, y: (bounds.height - lf.boundingRectForFont.height) / 2), withAttributes: [.font: lf, .foregroundColor: Theme.dynamic(.accent)]) }
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail
        let valueText = value ?? "—"
        let vAttrs: [NSAttributedString.Key: Any] = [.font: vf, .foregroundColor: Theme.dynamic(.textMuted), .paragraphStyle: ps]
        let lAttrs: [NSAttributedString.Key: Any] = [.font: lf, .foregroundColor: Theme.dynamic(.text), .paragraphStyle: ps]
        let right = bounds.width - 10
        let labelW = min((label as NSString).size(withAttributes: lAttrs).width.rounded(.up), right - 30 - 60)
        let valueW = min((valueText as NSString).size(withAttributes: vAttrs).width.rounded(.up), max(right - (30 + labelW + 8), 0))
        (label as NSString).draw(in: NSRect(x: 30, y: (bounds.height - lf.boundingRectForFont.height) / 2, width: labelW, height: 18), withAttributes: lAttrs)
        (valueText as NSString).draw(in: NSRect(x: right - valueW, y: (bounds.height - vf.boundingRectForFont.height) / 2, width: valueW, height: 16), withAttributes: vAttrs)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The scrolled list: headings and rows laid out top-down at fixed heights (classic StatusPicker spacing), no autolayout.
private final class FieldListView: NSView {
    override var isFlipped: Bool { true }
    var width: CGFloat = FieldPickerLayout.width
    func layoutRows(_ views: [NSView], heights: [CGFloat]) {
        subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0
        for (v, h) in zip(views, heights) {
            let inset: CGFloat = v is FieldRowView ? 4 : 0
            v.frame = NSRect(x: inset, y: y, width: width - 2 * inset, height: h)
            addSubview(v); y += h + (v is FieldRowView ? FieldPickerLayout.rowGap : 0)
        }
        frame = NSRect(x: 0, y: 0, width: width, height: max(y + FieldPickerLayout.listPadding, 1))
    }
}

final class FieldPickerController: NSObject, NSSearchFieldDelegate, NSTextFieldDelegate, NSPopoverDelegate {
    var onClose: (() -> Void)?
    func popoverDidClose(_ notification: Notification) { onClose?() }
    private let pop = NSPopover()
    private var chosen: [String]   // field ids (statusline.ts), like today's muya.footer.statusFields
    private let onChange: ([String]) -> Void
    private let listView = FieldListView()
    private let scroll = NSScrollView()
    private var data: [String: Any]?
    private let search = NSTextField()
    private lazy var searchBox = FieldBox(search, height: 30)
    private let note = ThemedText.plainHelper("Status data appears for Claude sessions started from Muya")
    private let empty = NSTextField(labelWithString: "No matching fields")
    private let box = NSView()
    private var heightConstraint: NSLayoutConstraint!
    private var scrollHeight: NSLayoutConstraint!
    init(chosen: [String], data: [String: Any]?, onChange: @escaping ([String]) -> Void) {
        self.chosen = chosen; self.data = data; self.onChange = onChange
        super.init()
        pop.behavior = .transient; pop.delegate = self
        search.placeholderString = "Filter fields"; search.delegate = self
        note.font = ThemeFont.sans(11); note.textColor = Theme.dynamic(.textMuted)
        empty.font = ThemeFont.sans(13); empty.textColor = Theme.dynamic(.textMuted)
        scroll.documentView = listView; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.setAccessibilityLabel("Status fields")
        for v in [searchBox, note, scroll, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 100)
        heightConstraint = box.heightAnchor.constraint(equalToConstant: 300)
        NSLayoutConstraint.activate([
            searchBox.topAnchor.constraint(equalTo: box.topAnchor, constant: 6), searchBox.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), searchBox.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            note.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 4), note.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14), note.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor), scrollHeight,
            empty.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14), empty.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 10),
            box.widthAnchor.constraint(equalToConstant: FieldPickerLayout.width), heightConstraint,
        ])
        let vc = NSViewController(); vc.view = box; pop.contentViewController = vc
        rebuild()
    }
    /// The popover is centred on the + icon, which sits near the window's right edge: slide it left (the arrow then
    /// points beside the icon) so it stays inside the window. The limit is the WINDOW's right edge, not the anchor's —
    /// the footer is narrower than the window, and measuring against it let the menu hang outside.
    func show(from anchor: NSView, rect: NSRect) {
        let half = max(FieldPickerLayout.width, pop.contentSize.width) / 2
        var limit = anchor.bounds.maxX
        if let content = anchor.window?.contentView {
            limit = anchor.convert(NSPoint(x: content.bounds.maxX, y: 0), from: content).x
        }
        let overflow = rect.midX + half - (limit - 8)
        pop.show(relativeTo: overflow > 0 ? rect.offsetBy(dx: -overflow, dy: 0) : rect, of: anchor, preferredEdge: .minY)
    }
    #if MUYA_TEST_HOOKS
    func debugSetFilter(_ t: String) { search.stringValue = t; rebuild() }
    func debugClose() { pop.close() }
    var debugWindowID: Int { pop.contentViewController?.view.window?.windowNumber ?? 0 }
    var debugWindow: NSWindow? { pop.contentViewController?.view.window }
    var debugContentView: NSView? { pop.contentViewController?.view }
    #endif
    func controlTextDidChange(_ obj: Notification) { rebuild() }
    private func rebuild() {
        let groups = StatusFieldCatalog.filtered(search.stringValue)
        var views: [NSView] = [], heights: [CGFloat] = []
        var rows = 0
        for (g, fields) in groups {
            views.append(FieldHeadingView(g)); heights.append(FieldPickerLayout.headingHeight)
            for f in fields {
                let r = FieldRowView(id: f.id, label: f.label, value: StatusFieldCatalog.value(f.id, data), on: chosen.contains(f.id))
                r.onPick = { [weak self] id in
                    guard let self else { return }
                    if let i = self.chosen.firstIndex(of: id) { self.chosen.remove(at: i) } else { self.chosen.append(id) }
                    self.onChange(self.chosen); self.rebuild()
                }
                views.append(r); heights.append(FieldPickerLayout.rowHeight); rows += 1
            }
        }
        listView.layoutRows(views, heights: heights)
        let screenH = pop.contentViewController?.view.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 800
        let hasNote = data == nil
        note.isHidden = !hasNote; empty.isHidden = rows != 0
        scroll.isHidden = rows == 0
        let list = FieldPickerLayout.listHeight(groups: groups.count, rows: rows, screenHeight: screenH)
        scrollHeight.constant = rows == 0 ? 0 : list
        heightConstraint.constant = FieldPickerLayout.popoverHeight(groups: groups.count, rows: rows, hasNote: hasNote, screenHeight: screenH)
        scroll.verticalScroller?.alphaValue = 1
        pop.contentSize = NSSize(width: FieldPickerLayout.width, height: heightConstraint.constant)
    }
}
