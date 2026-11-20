// WP9 — popovers of today's Muya as in-window cards (not NSPopover: no arrow, the card sits under/over its button with a
// 7px gap and the popover surface of the theme: --bg-panel, 1px --border, radius 12, shadow). A transparent catcher over the
// window closes the card on an outside click, Escape closes it too.
import AppKit

final class OverlayPopover: NSView {
    enum Edge { case belowTrailing, belowLeading, aboveTrailing }
    private let card = ThemedBox(.popover)
    private let content: NSView
    private let width: CGFloat
    var onClose: (() -> Void)?
    private(set) var isShown = false

    init(content: NSView, width: CGFloat, inset: NSEdgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)) {
        self.content = content; self.width = width
        super.init(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: inset.top), content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset.bottom),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset.left), content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset.right),
            card.widthAnchor.constraint(equalToConstant: width),
        ])
        card.wantsLayer = true
        card.shadow = NSShadow()
        card.layer?.shadowColor = NSColor.black.cgColor; card.layer?.shadowOpacity = 0.35; card.layer?.shadowRadius = 14; card.layer?.shadowOffset = CGSize(width: 0, height: -6)
        addSubview(card)
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { close() }
    }
    override func cancelOperation(_ sender: Any?) { close() }
    override var acceptsFirstResponder: Bool { true }

    func show(in window: NSWindow, anchor: NSView, anchorRect: NSRect? = nil, edge: Edge) {
        guard let root = window.contentView, !isShown else { return }
        frame = root.bounds; autoresizingMask = [.width, .height]
        root.addSubview(self)
        card.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: card.fittingSize.height)
        let a = convert(anchorRect ?? anchor.bounds, from: anchor)   // anchor rect in this (flipped) coordinate space
        var x: CGFloat, y: CGFloat
        switch edge {
        case .belowTrailing: x = a.maxX - size.width; y = a.maxY + 7
        case .belowLeading: x = a.minX; y = a.maxY + 7
        case .aboveTrailing: x = a.maxX - size.width; y = a.minY - 7 - size.height
        }
        x = max(8, min(x, bounds.width - size.width - 8)); y = max(8, y)
        card.translatesAutoresizingMaskIntoConstraints = true
        card.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        isShown = true
        window.makeFirstResponder(self)
    }

    func close() {
        guard isShown else { return }
        isShown = false
        removeFromSuperview()
        onClose?()
    }
}

enum NotificationsPopover {
    /// "NOTIFICATIONS" heading + "No notifications." (the native app has no notification feed yet, like the web mock's empty state).
    static func make() -> OverlayPopover {
        let head = ThemedText.label("Notifications")
        let body = NSTextField(labelWithString: "No notifications.")
        body.font = ThemeFont.sans(13); body.textColor = Theme.dynamic(.textMuted)
        let col = Kit.vstack([head, body], spacing: 14)
        col.setAccessibilityLabel("Notifications. No notifications.")
        return OverlayPopover(content: col, width: 379, inset: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
    }
}
