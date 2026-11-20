// The small icon button of the terminal search bar and of ModalShell's close X (28 px, no border, --text-muted). Its own file so the
// SSH sheet tool (verify-ssh.sh) can compile ModalParts without the terminal's search bar.

import AppKit

final class FindIconButton: NSControl {
    let glyph: GlyphIcon
    var onClick: (() -> Void)?
    var glyphSize: CGFloat = 12
    var side: CGFloat = 18 { didSet { sideW?.constant = side; sideH?.constant = side; needsDisplay = true } }
    private var sideW: NSLayoutConstraint?, sideH: NSLayoutConstraint?
    init(_ glyph: GlyphIcon, label: String, tip: String) {
        self.glyph = glyph
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        translatesAutoresizingMaskIntoConstraints = false
        sideW = widthAnchor.constraint(equalToConstant: 18); sideH = heightAnchor.constraint(equalToConstant: 18)
        sideW?.isActive = true; sideH?.isActive = true
        toolTip = tip; setAccessibilityRole(.button); setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState(); ctx.translateBy(x: (bounds.width - glyphSize) / 2, y: (bounds.height - glyphSize) / 2)
        glyph.draw(in: ctx, size: glyphSize, color: Theme.dynamic(.textMuted), stroke: 2)
        ctx.restoreGState()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
