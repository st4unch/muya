// Shared UI parts that look like today's Muya (src/components/modalKit.tsx: ghost / primary / danger buttons, the segmented
// control, the 32x18 switch, label + helper text, the bordered rows box; src/redesign: pills). Pages and dialogs build from
// these so every surface reads the same. All parts draw themselves from theme tokens in draw(_:), so a theme change repaints
// them with no extra code and no timers or animations (idle CPU stays 0).
import AppKit

private func fillRounded(_ r: NSRect, radius: CGFloat, fill: NSColor?, stroke: NSColor?, lineWidth: CGFloat = 1) {
    let inset = stroke == nil ? 0 : lineWidth / 2
    let path = NSBezierPath(roundedRect: r.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
    if let fill { fill.setFill(); path.fill() }
    if let stroke { stroke.setStroke(); path.lineWidth = lineWidth; path.stroke() }
}

/// A helper line with the web's line height (modalKit helperStyle: lineHeight 1.45 → 17.4 px at 12 px). Setting the text later keeps it.
public final class HelperField: NSTextField {
    private static let style: NSParagraphStyle = { let p = NSMutableParagraphStyle(); p.minimumLineHeight = 17.4; p.maximumLineHeight = 17.4; return p }()
    public override var stringValue: String {
        get { super.stringValue }
        set {
            let a = NSMutableAttributedString(string: newValue, attributes: [.font: font ?? ThemeFont.sans(12), .foregroundColor: textColor ?? Theme.dynamic(.textFaint), .paragraphStyle: Self.style])
            // The baseline sits at the bottom of the taller line box: lift the glyphs by half the extra height, like CSS centres them.
            a.addAttribute(.baselineOffset, value: (17.4 - ((font ?? ThemeFont.sans(12)).ascender - (font ?? ThemeFont.sans(12)).descender)) / 2, range: NSRange(location: 0, length: a.length))
            attributedStringValue = a
        }
    }
}

public enum ThemedText {
    /// "Group label": 11px / 600, uppercase, letter-spacing .06em, --text-muted (modalKit labelStyle).
    public static func label(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.attributedStringValue = NSAttributedString(string: s.uppercased(), attributes: [
            .font: ThemeFont.sans(11, .semibold), .kern: 0.66, .foregroundColor: Theme.dynamic(.textMuted)])
        return f
    }
    /// Helper line: 12px, --text-faint (modalKit helperStyle).
    public static func helper(_ s: String) -> NSTextField {
        let f = HelperField(wrappingLabelWithString: "")
        f.font = ThemeFont.sans(12); f.textColor = Theme.dynamic(.textFaint)
        f.stringValue = s
        return f
    }
    /// The same line with the font's natural line height (pages whose reference text is not modalKit's helperStyle).
    public static func plainHelper(_ s: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = ThemeFont.sans(12); f.textColor = Theme.dynamic(.textFaint)
        return f
    }
    /// Row title: bold 13px, --text (the Settings row title).
    public static func title(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = ThemeFont.sans(13, .semibold); f.textColor = Theme.dynamic(.text)
        return f
    }
}

/// ghost / primary / danger buttons: 32px high, radius 7, 13px.
public final class ThemedButton: NSControl {
    public enum Style { case ghost, primary, danger }
    /// Soft indigo look of the accent actions on pages (Attach / Resume / Open); applies on top of `.ghost`.
    public var indigo = false { didSet { needsDisplay = true } }
    /// Approval buttons of a waiting panel (src/redesign/GridPanel.tsx): Allow = warning amber fill, Deny = warning outline, Always = strong outline.
    public enum Tone { case none, allow, deny, always }
    public var tone = Tone.none { didSet { needsDisplay = true } }
    public var style: Style { didSet { needsDisplay = true } }
    public var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var icon: ThemeIcon? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Small mono key hint after the title ("Stop esc"), in --danger-kbd on danger buttons, --text-faint otherwise.
    /// Icon-only look (collapsed headers): no title, the icon centred.
    public var iconOnly = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var hint: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var pressed = false
    public var onClick: (() -> Void)?

    public init(_ title: String, style: Style = .ghost, icon: ThemeIcon? = nil) {
        self.title = title; self.style = style; self.icon = icon
        super.init(frame: .zero)
        setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var labelFont: NSFont { ThemeFont.sans(13, style == .primary ? .semibold : .regular) }
    private static func ap(_ dark: NSColor, _ light: NSColor) -> NSColor { NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light } }
    private var fg: NSColor {
        tone == .allow ? Theme.dynamic(.warningBtnFg) : tone == .deny ? Theme.dynamic(.warningText) : tone == .always ? Theme.dynamic(.textTertiary)
            : indigo ? Self.ap(ThemeRaw.indigo300, ThemeRaw.indigo700) : Theme.dynamic(style == .primary ? .primaryFg : style == .danger ? .dangerText : .text)
    }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var intrinsicContentSize: NSSize {
        if iconOnly { return NSSize(width: 30, height: 32) }
        let w = (title as NSString).size(withAttributes: [.font: labelFont]).width
        let hw = hint.map { ($0 as NSString).size(withAttributes: [.font: ThemeFont.mono(11)]).width + 6 } ?? 0
        return NSSize(width: ceil(w + hw) + (style == .primary ? 28 : 24) + (icon != nil ? 20 : 0), height: 32)
    }
    public override func draw(_ dirtyRect: NSRect) {
        var fill: NSColor, stroke: NSColor?
        switch style {
        case .ghost: fill = Theme.dynamic(.bgControl); stroke = Theme.dynamic(.borderControl)
        case .primary: fill = Theme.dynamic(.primaryBg); stroke = nil
        case .danger: fill = Theme.dynamic(.dangerBtnBg); stroke = Theme.dynamic(.dangerBorder)
        }
        switch tone {
        case .allow: fill = Theme.dynamic(.warningBtnBg); stroke = nil
        case .deny: fill = .clear; stroke = Theme.dynamic(.warningBorder)
        case .always: fill = .clear; stroke = Theme.dynamic(.borderStrong)
        case .none: break
        }
        if indigo { fill = Self.ap(ThemeRaw.indigo950.withAlphaComponent(0.4), ThemeRaw.indigo50); stroke = Self.ap(ThemeRaw.indigo800, ThemeRaw.indigo200) }
        fillRounded(bounds, radius: 7, fill: fill, stroke: stroke)
        if pressed { NSColor.black.withAlphaComponent(0.12).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: fg]
        if iconOnly, let icon, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState(); ctx.translateBy(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2)
            ThemeIcons.draw(icon, in: ctx, size: 14, color: fg); ctx.restoreGState(); return
        }
        let ts = (title as NSString).size(withAttributes: attrs)
        let iw: CGFloat = icon != nil ? 20 : 0
        let hintW = hint.map { ($0 as NSString).size(withAttributes: [.font: ThemeFont.mono(11)]).width + 6 } ?? 0
        var x = (bounds.width - ts.width - iw - hintW) / 2
        if let icon, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState(); ctx.translateBy(x: x, y: (bounds.height - 14) / 2)
            ThemeIcons.draw(icon, in: ctx, size: 14, color: fg); ctx.restoreGState(); x += 20
        }
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - ts.height) / 2), withAttributes: attrs)
        if let hint {
            let ha: [NSAttributedString.Key: Any] = [.font: ThemeFont.mono(11), .foregroundColor: tone == .allow || tone == .deny ? fg : Theme.dynamic(style == .danger ? .dangerKbd : .textFaint)]
            (hint as NSString).draw(at: NSPoint(x: x + ts.width + 6, y: (bounds.height - (hint as NSString).size(withAttributes: ha).height) / 2), withAttributes: ha)
        }
    }
    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; needsDisplay = true
        let inside = { [self] in bounds.contains(convert(window!.mouseLocationOutsideOfEventStream, from: nil)) }
        // Track until mouse up (no timers): the standard AppKit loop.
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            pressed = inside(); needsDisplay = true
            if e.type == .leftMouseUp { break }
        }
        let fire = pressed; pressed = false; needsDisplay = true
        if fire { onClick?(); sendAction(action, to: target) }
    }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onClick?(); sendAction(action, to: target) } else { super.keyDown(with: event) }
    }
    public override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Segmented control: 3px padding, radius 9 track (--bg-segment), 30px active pill (radius 7).
public final class ThemedSegmented: NSControl {
    public var options: [String] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var selected: Int { didSet { needsDisplay = true } }
    public var onChange: ((Int) -> Void)?
    /// Dense toolbar variant (the grid header's layout picker): padding 3, gap 4, 28px buttons of their own width (text 12 + 2x10), track radius 8, button radius 6.
    public var compact = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var compactFont: NSFont { ThemeFont.sans(12) }
    private func compactWidths() -> [CGFloat] { options.map { ceil(($0 as NSString).size(withAttributes: [.font: compactFont]).width) + 20 } }
    public init(options: [String], selected: Int = 0) {
        self.options = options; self.selected = selected
        super.init(frame: .zero)
        setAccessibilityRole(.radioGroup)
    }
    required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize {
        if compact { return NSSize(width: compactWidths().reduce(0, +) + 6 + 4 * CGFloat(max(0, options.count - 1)), height: 34) }
        let w = options.map { ($0 as NSString).size(withAttributes: [.font: ThemeFont.sans(13, .semibold)]).width + 28 }.max() ?? 40
        return NSSize(width: w * CGFloat(options.count) + 6 + 2 * CGFloat(max(0, options.count - 1)), height: 36)
    }
    private func segment(_ i: Int) -> NSRect {
        if compact { let ws = compactWidths(); return NSRect(x: 3 + ws[..<i].reduce(0, +) + 4 * CGFloat(i), y: 3, width: ws[i], height: 28) }
        let n = CGFloat(options.count), w = (bounds.width - 6 - 2 * (n - 1)) / n
        return NSRect(x: 3 + CGFloat(i) * (w + 2), y: 3, width: w, height: bounds.height - 6)
    }
    public override func draw(_ dirtyRect: NSRect) {
        fillRounded(bounds, radius: compact ? 8 : 9, fill: Theme.dynamic(.bgSegment), stroke: nil)
        for (i, o) in options.enumerated() {
            let r = segment(i), active = i == selected
            if active { fillRounded(r, radius: compact ? 6 : 7, fill: Theme.dynamic(.bgSegmentActive), stroke: nil) }
            let a: [NSAttributedString.Key: Any] = [.font: compact ? ThemeFont.sans(12, active ? .medium : .regular) : ThemeFont.sans(13, active ? .semibold : .medium),
                .foregroundColor: Theme.dynamic(active ? .text : .textMuted)]
            let sz = (o as NSString).size(withAttributes: a)
            (o as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: a)
        }
    }
    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = options.indices.first(where: { segment($0).contains(p) }), i != selected { selected = i; onChange?(i); sendAction(action, to: target) }
    }
    public override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// 32x18 on/off switch, accent track when on, round knob.
public final class ThemedSwitch: NSControl {
    public var isOn: Bool { didSet { needsDisplay = true } }
    public var onChange: ((Bool) -> Void)?
    public init(isOn: Bool = false) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 18))
        setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 18) }
    public override func draw(_ dirtyRect: NSRect) {
        fillRounded(NSRect(x: 0, y: 0, width: 32, height: 18), radius: 9, fill: Theme.dynamic(isOn ? .accent : .borderControl), stroke: nil)
        let knob = NSRect(x: isOn ? 16 : 2, y: 2, width: 14, height: 14)
        (Theme.dynamic(isOn ? .bgPanel : .textMuted)).setFill(); NSBezierPath(ovalIn: knob).fill()
    }
    public override func mouseDown(with event: NSEvent) { isOn.toggle(); onChange?(isOn); sendAction(action, to: target) }
    public override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    public override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
}

/// Status pill: 11px / 600 text on a tinted rounded fill (e.g. "Working · 4m 15s", "Bypass permissions on").
public final class ThemedPill: NSView {
    public var text: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var fg: NSColor { didSet { needsDisplay = true } }
    public var bg: NSColor? { didSet { needsDisplay = true } }
    public var border: NSColor? { didSet { needsDisplay = true } }
    public var dot: NSColor? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public init(_ text: String, fg: NSColor, bg: NSColor? = nil, border: NSColor? = nil, dot: NSColor? = nil) {
        self.text = text; self.fg = fg; self.bg = bg; self.border = border; self.dot = dot
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    private var attrs: [NSAttributedString.Key: Any] { [.font: ThemeFont.sans(11, .semibold), .foregroundColor: fg] }
    public override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: attrs).width) + 16 + (dot != nil ? 12 : 0), height: 20)
    }
    public override func draw(_ dirtyRect: NSRect) {
        fillRounded(bounds, radius: bounds.height / 2, fill: bg, stroke: border)
        var x: CGFloat = 8
        if let dot { dot.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - 3, width: 6, height: 6)).fill(); x += 12 }
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: x, y: bounds.midY - sz.height / 2), withAttributes: attrs)
    }
    public override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Bordered block (modalKit rowsBox: 1px --border, radius 10) — cards, grouped rows, and with `popover` the dialog /
/// popover surface (radius 12, --bg-panel fill, popover shadow).
public final class ThemedBox: NSView {
    public enum Kind { case rows, card, popover }
    public var kind: Kind { didSet { needsDisplay = true } }
    public init(_ kind: Kind = .rows) {
        self.kind = kind
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .rows: fillRounded(bounds, radius: 10, fill: nil, stroke: Theme.dynamic(.border))
        case .card: fillRounded(bounds, radius: 10, fill: Theme.dynamic(.bgPanel), stroke: Theme.dynamic(.border))
        case .popover: fillRounded(bounds, radius: 12, fill: Theme.dynamic(.bgPanel), stroke: Theme.dynamic(.border))
        }
    }
    public override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
