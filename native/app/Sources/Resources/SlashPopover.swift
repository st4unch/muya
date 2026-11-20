// The slash-commands popover (today's SlashCommandsPopover): a filter field over a list grouped Built-in /
// Project / User / Skills. Type to filter, ↑/↓ and Enter pick, Esc or a click outside closes. It hangs over the
// terminal area; picking a command types `/name ` into the selected terminal.

import AppKit

@MainActor
final class SlashPopover: NSView, NSTextFieldDelegate {
    private let field = Kit.field("Filter commands…", label: "Filter slash commands")
    private let listStack = NSStackView()
    private let scroll = NSScrollView()
    private let card = ThemedBox(.popover)
    private(set) var items: [SlashItem] = []
    private(set) var shown: [SlashItem] = []
    private(set) var index = 0
    private(set) var loading = false
    var onPick: ((String) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical; listStack.alignment = .leading; listStack.spacing = 0
        let flipped = FlippedDoc(); flipped.translatesAutoresizingMaskIntoConstraints = false; listStack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(listStack)
        NSLayoutConstraint.activate([listStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 4), listStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -4), listStack.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 4), listStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -4)])
        scroll.documentView = flipped; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityLabel("Slash commands")
        flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        card.addSubview(field); card.addSubview(scroll)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 420), card.heightAnchor.constraint(lessThanOrEqualToConstant: 400),
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -90),
            field.topAnchor.constraint(equalTo: card.topAnchor, constant: 10), field.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10), field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            scroll.heightAnchor.constraint(equalToConstant: 320),
        ])
        isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Slash commands")
    }
    required init?(coder: NSCoder) { fatalError() }

    var isOpen: Bool { !isHidden }

    func open(agent: String, disk: [SlashItem] = [], loading: Bool = false) {
        items = SlashLogic.merge(agent: agent, disk: disk); self.loading = loading
        field.stringValue = ""; index = 0
        isHidden = false
        refilter()
        window?.makeFirstResponder(field)
    }

    /// The disk commands arrived after the popover opened.
    func update(agent: String, disk: [SlashItem]) { items = SlashLogic.merge(agent: agent, disk: disk); loading = false; refilter() }

    func close() { guard isOpen else { return }; isHidden = true; onClose?() }

    func type(_ q: String) { field.stringValue = q; index = 0; refilter() }

    var selectedName: String? { shown.indices.contains(index) ? shown[index].name : nil }

    func move(_ d: Int) { index = SlashLogic.move(index, by: d, count: shown.count); render() }
    func pickSelected() { if let n = selectedName { close(); onPick?(n) } }

    private func refilter() { shown = SlashLogic.grouped(SlashLogic.filter(items, query: field.stringValue)); index = min(index, max(0, shown.count - 1)); render() }

    private func render() {
        listStack.arrangedSubviews.forEach { listStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        var at = 0
        for g in SlashSource.allCases {
            let rows = shown.filter { $0.source == g }
            if rows.isEmpty { continue }
            let h = NSTextField(labelWithString: g.heading); h.font = .systemFont(ofSize: 11, weight: .semibold); h.textColor = Theme.dynamic(.textMuted)
            let hb = NSStackView(views: [h]); hb.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 4, right: 0)
            listStack.addArrangedSubview(hb)
            for it in rows {
                let row = SlashRow(item: it, active: at == index); let me = at
                row.onPick = { [weak self] in self?.index = me; self?.pickSelected() }
                listStack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                at += 1
            }
        }
        if shown.isEmpty {
            let l = NSTextField(labelWithString: loading ? "Loading…" : "No matching commands"); l.font = .systemFont(ofSize: 12); l.textColor = Theme.dynamic(.textMuted)
            let b = NSStackView(views: [l]); b.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 0); listStack.addArrangedSubview(b)
        }
        layoutSubtreeIfNeeded()
        if index == 0 { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
        else if let v = listStack.arrangedSubviews.compactMap({ $0 as? SlashRow }).first(where: { $0.active }) { v.scrollToVisible(v.bounds) }
    }

    func controlTextDidChange(_ obj: Notification) { index = 0; refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): pickSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    /// A click outside the card closes it (the card itself swallows its own clicks).
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { close() }
    }
}

private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

final class SlashRow: NSView {
    let item: SlashItem
    let active: Bool
    var onPick: (() -> Void)?
    init(item: SlashItem, active: Bool) {
        self.item = item; self.active = active
        super.init(frame: .zero)
        let n = NSTextField(labelWithString: "/\(item.name)"); n.font = ThemeFont.mono(12.5); n.textColor = Theme.dynamic(.text); n.lineBreakMode = .byTruncatingTail
        n.setContentHuggingPriority(.required, for: .horizontal); n.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        n.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
        let d = NSTextField(labelWithString: item.description); d.font = .systemFont(ofSize: 12); d.textColor = Theme.dynamic(.textMuted); d.lineBreakMode = .byTruncatingTail
        d.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let s = NSStackView(views: [n, d]); s.orientation = .horizontal; s.spacing = 10; s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false; addSubview(s)
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), s.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 28)])
        setAccessibilityElement(true); setAccessibilityRole(.menuItem); setAccessibilityLabel("/\(item.name) \(item.description)")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard active else { return }
        Theme.dynamic(.bgSegment).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onPick?() }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }
}
