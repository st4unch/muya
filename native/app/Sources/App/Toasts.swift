// P5 — generic toasts (src/redesign App toasts): a card in the window's top-right corner with a title, a message and up to two
// buttons; one at a time, closes on ×, after `seconds` (one-shot timer) or when an action ran. Used for the storage heads-up
// ("Claude's saved sessions take …") and notices; the Auto-allow suggestion keeps its own controller.

import AppKit

final class ToastCard: NSView {
    private let card = ThemedBox(.popover)
    var onClose: (() -> Void)?
    init(title: String, message: String, actions: [(String, Bool, () -> Void)]) {
        super.init(frame: .zero)
        let t = ThemedText.title(title)
        let m = ThemedText.helper(message); m.textColor = Theme.dynamic(.textTertiary); m.preferredMaxLayoutWidth = 276
        let close = ToastCloseButton(); close.onClick = { [weak self] in self?.onClose?() }
        let head = Kit.hstack([Kit.vstack([t, m], spacing: 4), close], spacing: 8, alignment: .top)
        var rows: [NSView] = [head]
        if !actions.isEmpty {
            let bs = actions.map { a -> ThemedButton in let b = ThemedButton(a.0, style: a.1 ? .primary : .ghost); b.onClick = { [weak self] in a.2(); self?.onClose?() }; return b }
            rows.append(Kit.hstack([NSView()] + bs, spacing: 8))
        }
        let col = Kit.vstack(rows, spacing: 10)
        col.translatesAutoresizingMaskIntoConstraints = false; card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(col); addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            col.topAnchor.constraint(equalTo: card.topAnchor, constant: 12), col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            widthAnchor.constraint(equalToConstant: 340),
        ])
        for v in rows { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        setAccessibilityRole(.group); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ToastCenter {
    private weak var host: NSView?
    private(set) var current: ToastCard?
    private var timer: Timer?
    /// Where the next toast goes vertically (below the Auto-allow toast when that one is up).
    var topInset: () -> CGFloat = { 66 }
    init(host: NSView?) { self.host = host }
    var isShown: Bool { current != nil }
    var title: String { current?.accessibilityLabel() ?? "" }

    func show(title: String, message: String, actions: [(String, Bool, () -> Void)] = [], seconds: TimeInterval = 12) {
        guard let host else { return }
        dismiss()
        let t = ToastCard(title: title, message: message, actions: actions)
        t.onClose = { [weak self] in self?.dismiss() }
        t.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(t, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([t.topAnchor.constraint(equalTo: host.topAnchor, constant: topInset()), t.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16)])
        current = t
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.dismiss() }
    }
    func dismiss() { timer?.invalidate(); timer = nil; current?.removeFromSuperview(); current = nil }
}
