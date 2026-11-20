// WP4 — grid panel chrome (src/redesign/GridPanel.tsx): the inline approval bar of a waiting panel (Allow, Deny, "Don't ask again
// (this project)") or the message bar of the others ("Message <name>…"), 58px high at the bottom of the panel, and the
// "Empty panel" card. Header and border styling live in Tile (UI.swift) with the same tokens.

import AppKit

/// Grid state shared by the header controls and the tiles (layout choice, waiting first, the operator's own cell picks).
enum GridState {
    nonisolated(unsafe) static var layout = GridChoice.twoByTwo
    nonisolated(unsafe) static var waitingFirst = false
    nonisolated(unsafe) static var picked: [UInt64]?
    nonisolated(unsafe) static var shownIds: [UInt64] = []
}

final class TileActionBar: FillView {
    static let height: CGFloat = 58
    private let allow = ThemedButton("Allow", style: .ghost)
    private let deny = ThemedButton("Deny", style: .ghost)
    private let always = ThemedButton("Don't ask again (this project)", style: .ghost)
    var sessionID: UInt64 = 0
    var onAnswer: ((UInt64, Bool) -> Void)?
    var onAlways: ((UInt64) -> Void)?

    init() {
        super.init(.bgChrome)
        allow.hint = "Y"; deny.hint = "N"   // <span mono 11>Y</span> / N of GridPanel.tsx
        top = true
        allow.tone = .allow; deny.tone = .deny; always.tone = .always
        [allow, deny, always].forEach(addSubview)
        allow.onClick = { [weak self] in guard let self else { return }; self.onAnswer?(self.sessionID, true) }
        deny.onClick = { [weak self] in guard let self else { return }; self.onAnswer?(self.sessionID, false) }
        always.onClick = { [weak self] in guard let self else { return }; self.onAlways?(self.sessionID) }
        setAccessibilityRole(.group); setAccessibilityLabel("Permission request")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the bar for a session that is waiting for permission; hides it otherwise. Returns whether it is shown.
    @discardableResult
    func configure(_ s: SessionModel?) -> Bool {
        let on = s?.exited == nil && s?.screen?.permission == true && s?.screen?.approveKey != nil
        sessionID = s?.id ?? 0
        always.isHidden = !(on && s?.screen?.alwaysKey != nil)
        if let label = s?.screen?.alwaysLabel, !always.isHidden { always.title = GridPlan.alwaysAllowText(label); always.toolTip = label; always.setAccessibilityLabel(label) }
        else if !always.isHidden { always.title = "Always allow" }
        isHidden = !on
        return on
    }
    override func layout() {
        super.layout()
        let y = (bounds.height - 34) / 2
        allow.frame = NSRect(x: 14, y: y, width: allow.intrinsicContentSize.width + 4, height: 34)
        deny.frame = NSRect(x: allow.frame.maxX + 8, y: y, width: deny.intrinsicContentSize.width + 4, height: 34)
        always.frame = NSRect(x: deny.frame.maxX + 8, y: y, width: always.intrinsicContentSize.width, height: 34)
    }
}

/// "Message <name>…" box of a panel (the web's panel composer): Return sends.
final class TileInputBar: FillView {
    private let field = NSTextField()
    var onSend: ((String) -> Void)?
    var session: SessionModel? { didSet { field.placeholderAttributedString = NSAttributedString(string: session.map { "Message \($0.name)…" } ?? "", attributes: [.font: ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.textMuted)]) } }
    init() {
        super.init(.bgChrome)
        top = true
        field.font = ThemeFont.sans(13); field.textColor = Theme.dynamic(.text); field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.target = self; field.action = #selector(send)
        field.setSpokenLabel("Message to this panel")
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func send() {
        guard let t = DialogsLogic.trimmed(field.stringValue) else { return }
        field.stringValue = ""; onSend?(t)
    }
    override func layout() { super.layout(); field.frame = NSRect(x: 26, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 52), height: 18) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let r = NSRect(x: 14, y: (bounds.height - 34) / 2, width: bounds.width - 28, height: 34)
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Theme.dynamic(.bgInput).setFill(); p.fill(); Theme.dynamic(.borderControl).setStroke(); p.stroke()
    }
}

/// A grid cell no session fills (today's EmptyGridPanel): head "○ Empty panel", centred "Waiting for a task" + two buttons.
final class EmptyPanelView: NSView {
    private let assign = ThemedButton("Assign from Queue")
    private let swap = ThemedButton("Swap panel")
    nonisolated(unsafe) static var assignHandler: (() -> Void)?
    nonisolated(unsafe) static var swapHandler: ((NSView) -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(assign); addSubview(swap)
        assign.onClick = { EmptyPanelView.assignHandler?() }
        swap.onClick = { [weak self] in if let s = self?.swap { EmptyPanelView.swapHandler?(s) } }
        setAccessibilityRole(.group); setAccessibilityLabel("Empty panel")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let w1 = assign.intrinsicContentSize.width, w2 = swap.intrinsicContentSize.width, total = w1 + 8 + w2
        assign.frame = NSRect(x: (bounds.width - total) / 2, y: bounds.midY + 22, width: w1, height: 32)
        swap.frame = NSRect(x: assign.frame.maxX + 8, y: bounds.midY + 22, width: w2, height: 32)
    }
    override func draw(_ dirtyRect: NSRect) {
        // card: --bg-terminal fill, 1px --border, radius 10 (drawn here: with wantsUpdateLayer AppKit would never call draw)
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.dynamic(.bgTerminal).setFill(); card.fill()
        NSGraphicsContext.saveGraphicsState(); card.addClip()
        Theme.dynamic(.bgPanel).setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 49).fill()
        Theme.dynamic(.border).setFill(); NSRect(x: 0, y: 48, width: bounds.width, height: 1).fill()
        Theme.dynamic(.textFaint).setStroke(); let ring = NSBezierPath(ovalIn: NSRect(x: 14.75, y: 20.75, width: 7.5, height: 7.5)); ring.lineWidth = 1.5; ring.stroke()
        ("Empty panel" as NSString).draw(at: NSPoint(x: 30, y: 17), withAttributes: [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textMuted)])
        let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.textMuted)]
        let t = "Waiting for a task" as NSString, sz = t.size(withAttributes: a)
        t.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: bounds.midY - 6), withAttributes: a)
        NSGraphicsContext.restoreGraphicsState()
        Theme.dynamic(.border).setStroke(); card.lineWidth = 1; card.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true; needsLayout = true }
}

/// The chevron after a panel's name (GridPanel.tsx "Choose session for this panel"): 22x22, no border, --text-muted.
final class PanelChevron: NSControl {
    var onClick: (() -> Void)?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        toolTip = "Choose session for this panel"; setAccessibilityRole(.button); setAccessibilityLabel(toolTip)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState(); ctx.translateBy(x: 4, y: 4)
        ThemeIcons.draw(.chevronDown, in: ctx, size: 14, color: Theme.dynamic(.textMuted)); ctx.restoreGState()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
