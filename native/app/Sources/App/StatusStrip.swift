// WP2 — the strip above the message box (src/redesign/ProgressStrip.tsx): "● <verb>" in success green, the mono progress line
// ("4m 15s · ↓ 16.9k tokens · thought for 3s") and, on the right, "Update ready" + Restart (the dev mock mode only: the native
// app has no updater yet). Hidden when there is nothing to say.

import AppKit

final class StatusStrip: FillView {
    static let height: CGFloat = 34
    private var heightC: NSLayoutConstraint!
    private var verb = "", progress = "", update = false
    private let restart = ThemedButton("Restart")
    var onRestart: (() -> Void)? { didSet { restart.onClick = { [weak self] in self?.onRestart?() } } }
    private var sig = ""

    init() {
        super.init(.bgTerminal)
        top = true
        translatesAutoresizingMaskIntoConstraints = false
        heightC = heightAnchor.constraint(equalToConstant: 0); heightC.isActive = true
        isHidden = true
        addSubview(restart); restart.isHidden = true
        setAccessibilityRole(.group); setAccessibilityLabel("Progress")
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ s: SessionModel?, updateReady: Bool, composerOpen: Bool = true) {
        let working = s?.exited == nil && (s?.screen?.busy == true || s?.screen?.activity != nil)
        let shown = StripVisibility.showsProgress(working: working, composerOpen: composerOpen)
        let v = shown ? (s?.screen?.activity ?? "Working…") : ""
        let p = shown ? (s?.progress ?? "") : ""
        let n = "\(v)|\(p)|\(updateReady)"
        guard n != sig else { return }; sig = n
        verb = v; progress = p; update = updateReady
        let show = StripVisibility.shows(working: working, updateReady: updateReady, composerOpen: composerOpen)
        heightC.constant = show ? Self.height : 0; isHidden = !show
        restart.isHidden = !updateReady
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        restart.frame = NSRect(x: bounds.width - 16 - 70, y: 4, width: 70, height: 26)
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.dynamic(.bgTerminal).setFill(); bounds.fill()
        Theme.dynamic(.borderSubtle).setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        var x: CGFloat = 28
        if !verb.isEmpty {
            Theme.dynamic(.success).setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - 3, width: 6, height: 6)).fill(); x += 14
            let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.successText)]
            let s = verb as NSString; s.draw(at: NSPoint(x: x, y: bounds.midY - s.size(withAttributes: a).height / 2), withAttributes: a); x += s.size(withAttributes: a).width + 12
        }
        if !progress.isEmpty {
            let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.mono(12), .foregroundColor: Theme.dynamic(.textMuted)]
            let s = progress as NSString; s.draw(at: NSPoint(x: x, y: bounds.midY - s.size(withAttributes: a).height / 2), withAttributes: a)
        }
        if update {
            let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textMuted)]
            let s = "Update ready" as NSString
            s.draw(at: NSPoint(x: bounds.width - 16 - 70 - 12 - s.size(withAttributes: a).width, y: bounds.midY - s.size(withAttributes: a).height / 2), withAttributes: a)
        }
    }
}
