// The top of the left panel in Files mode (src/redesign/OpenFilesList.tsx): "Files <n>" and the files open in the viewer
// (one card each: name, folder, a close ×), or "No open files. Pick one in the tree below, or with ⌘K."

import AppKit

final class OpenFilesList: NSView {
    var paths: [String] = [] { didSet { if paths != oldValue { needsDisplay = true; onResize?() } } }
    var current: String? { didSet { needsDisplay = true } }
    /// Files with unsaved edits: an amber dot after the name.
    var dirty = Set<String>() { didSet { if dirty != oldValue { needsDisplay = true } } }
    var home = NSHomeDirectory()
    var onOpen: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onResize: (() -> Void)?
    private static let rowH: CGFloat = 44, top: CGFloat = 52

    /// Height the list wants: the empty state is 99 px (title row + one line), each file card adds 44.
    static let emptyText = "No open files. Pick one in the tree below, or with ⌘K."
    private static let emptyAttrs: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textMuted)]
    /// The empty hint wraps like the web's (line height 18): one more line adds 18 px.
    private var emptyTextHeight: CGFloat { ceil((Self.emptyText as NSString).boundingRect(with: NSSize(width: max(bounds.width - 32, 40), height: 200), options: .usesLineFragmentOrigin, attributes: Self.emptyAttrs).height / 18) * 18 }
    var wantedHeight: CGFloat { paths.isEmpty ? max(99, 63 + emptyTextHeight) : Self.top + CGFloat(paths.count) * Self.rowH + 12 }
    override func layout() { super.layout(); onResize?() }

    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityRole(.group); setAccessibilityLabel("Open files") }
    required init?(coder: NSCoder) { fatalError() }

    private func rowRect(_ i: Int) -> NSRect { NSRect(x: 10, y: Self.top + CGFloat(i) * Self.rowH, width: bounds.width - 21, height: Self.rowH - 4) }

    override func draw(_ dirtyRect: NSRect) {
        let t = "Files" as NSString, ta: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(14, .semibold), .foregroundColor: Theme.dynamic(.text)]
        t.draw(at: NSPoint(x: 16, y: 23), withAttributes: ta)
        ("\(paths.count)" as NSString).draw(at: NSPoint(x: 16 + t.size(withAttributes: ta).width + 6, y: 24), withAttributes: [.font: ThemeFont.sans(14), .foregroundColor: Theme.dynamic(.textMuted)])
        if paths.isEmpty {
            (Self.emptyText as NSString).draw(with: NSRect(x: 16, y: 59, width: bounds.width - 32, height: emptyTextHeight), options: .usesLineFragmentOrigin, attributes: Self.emptyAttrs)
            return
        }
        for (i, p) in paths.enumerated() {
            let r = rowRect(i), on = p == current
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            if on { Theme.dynamic(.bgSelected).setFill(); path.fill(); Theme.dynamic(.borderSelected).setStroke(); path.lineWidth = 1; path.stroke() }
            let name = (p as NSString).lastPathComponent
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(13, on ? .semibold : .regular), .foregroundColor: Theme.dynamic(.text)]
            (name as NSString).draw(at: NSPoint(x: r.minX + 10, y: r.minY + 5), withAttributes: nameAttrs)
            if dirty.contains(p) {
                Theme.dynamic(.warning).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.minX + 10 + (name as NSString).size(withAttributes: nameAttrs).width + 7, y: r.minY + 11, width: 7, height: 7)).fill()
            }
            let dir = ((p as NSString).deletingLastPathComponent).abbreviatingHome(home)
            let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingHead
            (dir as NSString).draw(in: NSRect(x: r.minX + 10, y: r.minY + 22, width: r.width - 44, height: 14), withAttributes: [.font: ThemeFont.mono(11), .foregroundColor: Theme.dynamic(.textMuted), .paragraphStyle: ps])
            ("×" as NSString).draw(at: NSPoint(x: r.maxX - 22, y: r.minY + 8), withAttributes: [.font: ThemeFont.sans(15), .foregroundColor: Theme.dynamic(.textMuted)])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, path) in paths.enumerated() where rowRect(i).contains(p) {
            if p.x > rowRect(i).maxX - 30 { onClose?(path) } else { onOpen?(path) }
            return
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
