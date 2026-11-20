// Form controls of the modal dialogs in token colours: a tick box (accent fill, white tick) and a select that looks like
// today's <select> (input background, control border, up/down chevrons) and opens a menu on click.

import AppKit

private func fillRounded(_ r: NSRect, radius: CGFloat, fill: NSColor?, stroke: NSColor?) {
    let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    if let fill { fill.setFill(); p.fill() }
    if let stroke { stroke.setStroke(); p.lineWidth = 1; p.stroke() }
}

public final class ThemedCheckbox: NSControl {
    public var isOn: Bool { didSet { needsDisplay = true } }
    public var onChange: ((Bool) -> Void)?
    public init(on: Bool = false) {
        isOn = on
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
        setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    public override func accessibilityPerformPress() -> Bool { toggle(); return true }
    private func toggle() { isOn.toggle(); onChange?(isOn) }
    public override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        if isOn {
            fillRounded(r, radius: 3.5, fill: Theme.dynamic(.accent), stroke: nil)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 4.2, y: 8.4)); p.line(to: NSPoint(x: 6.9, y: 11)); p.line(to: NSPoint(x: 11.8, y: 5.2))
            p.lineWidth = 1.8; p.lineCapStyle = .round; p.lineJoinStyle = .round
            Theme.dynamic(.primaryFg).setStroke(); p.stroke()
        } else {
            fillRounded(r, radius: 3.5, fill: Theme.dynamic(.bgInput), stroke: Theme.dynamic(.borderControl))
        }
    }
    public override func mouseDown(with event: NSEvent) { toggle() }
    public override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

public final class ThemedSelect: NSControl {
    public var titles: [String]
    public var selected: Int { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    public var onChange: ((Int) -> Void)?
    /// Inside a bordered field box: no border or fill of its own, one down chevron (a plain <select> of today's forms).
    public var plain = false { didSet { needsDisplay = true } }
    public var titleOfSelectedItem: String? { titles.indices.contains(selected) ? titles[selected] : nil }
    public init(_ titles: [String], selected: Int = 0) {
        self.titles = titles; self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func accessibilityValue() -> Any? { titles.indices.contains(selected) ? titles[selected] : nil }
    private var textFont: NSFont { ThemeFont.sans(13) }
    public override var intrinsicContentSize: NSSize {
        let widest = titles.map { ($0 as NSString).size(withAttributes: [.font: textFont]).width }.max() ?? 40
        return NSSize(width: ceil(widest) + 34, height: 30)
    }
    public override func draw(_ dirtyRect: NSRect) {
        if !plain { fillRounded(bounds.insetBy(dx: 0.5, dy: 0.5), radius: 7, fill: Theme.dynamic(.bgInput), stroke: Theme.dynamic(.borderControl)) }
        let a: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: Theme.dynamic(.text)]
        let t = titles.indices.contains(selected) ? titles[selected] : ""
        let sz = (t as NSString).size(withAttributes: a)
        (t as NSString).draw(at: NSPoint(x: plain ? 0 : 11, y: (bounds.height - sz.height) / 2), withAttributes: a)
        let c = Theme.dynamic(.textMuted); c.setStroke()
        let x = plain ? bounds.width - 6 : bounds.width - 15, y = bounds.midY
        if plain {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x - 4, y: y - 2)); p.line(to: NSPoint(x: x, y: y + 2)); p.line(to: NSPoint(x: x + 4, y: y - 2))
            p.lineWidth = 1.5; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
            return
        }
        for dir: CGFloat in [-1, 1] {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x - 3, y: y + dir * 4)); p.line(to: NSPoint(x: x, y: y + dir * 7)); p.line(to: NSPoint(x: x + 3, y: y + dir * 4))
            p.lineWidth = 1.3; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
        }
    }
    public override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (i, t) in titles.enumerated() {
            let item = NSMenuItem(title: t, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self; item.tag = i; item.state = i == selected ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.item(at: selected), at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
    @objc private func pick(_ s: NSMenuItem) { selected = s.tag; onChange?(s.tag) }
    public override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
