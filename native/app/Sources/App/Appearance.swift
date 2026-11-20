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

final class FieldPickerController: NSObject, NSSearchFieldDelegate, NSPopoverDelegate {
    var onClose: (() -> Void)?
    func popoverDidClose(_ notification: Notification) { onClose?() }
    private let pop = NSPopover()
    private var chosen: [String]   // field ids (statusline.ts), like today's muya.footer.statusFields
    private let onChange: ([String]) -> Void
    private let list = NSStackView()
    private var data: [String: Any]?
    private let search = NSSearchField()
    init(chosen: [String], data: [String: Any]?, onChange: @escaping ([String]) -> Void) {
        self.chosen = chosen; self.data = data; self.onChange = onChange
        super.init()
        pop.behavior = .transient; pop.delegate = self
        search.placeholderString = "Filter fields"; search.delegate = self; search.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 2; list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = Kit.scroll(list, label: "Status fields"); scroll.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 460)); box.addSubview(search); box.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), search.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), search.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: 360), box.heightAnchor.constraint(equalToConstant: 460),
        ])
        let vc = NSViewController(); vc.view = box; pop.contentViewController = vc
        rebuild()
    }
    func show(from anchor: NSView, rect: NSRect) { pop.show(relativeTo: rect, of: anchor, preferredEdge: .minY) }
    func controlTextDidChange(_ obj: Notification) { rebuild() }
    private func rebuild() {
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        if data == nil {
            let n = ThemedText.helper("Status data appears for Claude sessions started from Muya")
            n.preferredMaxLayoutWidth = 330; list.addArrangedSubview(n)
        }
        for (g, fields) in StatusFieldCatalog.filtered(search.stringValue) {
            let h = ThemedText.label(g.uppercased()); list.addArrangedSubview(h)
            for f in fields {
                let on = chosen.contains(f.id)
                let val = StatusFieldCatalog.value(f.id, data)
                let b = ThemedButton((on ? "✓ " : "   ") + f.label + (val.map { "   \($0)" } ?? ""))
                b.onClick = { [weak self] in
                    guard let self else { return }
                    if let i = self.chosen.firstIndex(of: f.id) { self.chosen.remove(at: i) } else { self.chosen.append(f.id) }
                    self.onChange(self.chosen); self.rebuild()
                }
                list.addArrangedSubview(b); b.widthAnchor.constraint(equalToConstant: 336).isActive = true
            }
        }
    }
}
