// The top of the left panel in Files mode (src/redesign/OpenFilesList.tsx): "Files <n>" and the files open in the viewer
// (one card each: name, folder, a close ×), or "No open files. Pick one in the tree below, or with ⌘K."

import AppKit

final class OpenFilesList: NSView {
    var paths: [String] = [] { didSet { if paths != oldValue { scrollOffset = layoutModel.clamp(scrollOffset); needsDisplay = true; onResize?() } } }
    var current: String? { didSet { revealCurrent(); needsDisplay = true } }
    /// Files with unsaved edits: an amber dot after the name.
    var dirty = Set<String>() { didSet { if dirty != oldValue { needsDisplay = true } } }
    var home = NSHomeDirectory()
    var onOpen: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onResize: (() -> Void)?
    /// Control mode: the same cards without the "Files N" title, above the FILES header (SidebarView sets it).
    var compact = false { didSet { if compact != oldValue { scrollOffset = 0; needsDisplay = true; onResize?() } } }
    /// How far the cards are scrolled (classic: the list is `overflow: auto`). Kept inside OpenFilesLayout's range.
    private(set) var scrollOffset: CGFloat = 0
    var layoutModel: OpenFilesLayout { OpenFilesLayout(width: bounds.width, height: bounds.height, count: paths.count, compact: compact) }

    /// Height the list wants: the empty state is 99 px (title row + one line), each file card adds 44.
    static let emptyText = "No open files. Pick one in the tree below, or with ⌘K."
    private static let emptyAttrs: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textMuted)]
    /// The empty hint wraps like the web's (line height 18): one more line adds 18 px.
    private var emptyTextHeight: CGFloat { ceil((Self.emptyText as NSString).boundingRect(with: NSSize(width: max(bounds.width - 32, 40), height: 200), options: .usesLineFragmentOrigin, attributes: Self.emptyAttrs).height / 18) * 18 }
    var wantedHeight: CGFloat { paths.isEmpty ? max(99, 63 + emptyTextHeight) : OpenFilesLayout.wantedHeight(count: paths.count, compact: compact) }
    override func layout() { super.layout(); scrollOffset = layoutModel.clamp(scrollOffset); revealCurrent(); onResize?() }

    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityRole(.group); setAccessibilityLabel("Open files") }
    required init?(coder: NSCoder) { fatalError() }

    private func revealCurrent() {
        guard let c = current, let i = paths.firstIndex(of: c) else { return }
        let o = layoutModel.offsetRevealing(i, from: scrollOffset)
        if o != scrollOffset { scrollOffset = o; needsDisplay = true }
    }
    func scroll(to offset: CGFloat) { scrollOffset = layoutModel.clamp(offset); needsDisplay = true }
    override func scrollWheel(with event: NSEvent) {
        guard layoutModel.scrolls else { return super.scrollWheel(with: event) }
        scroll(to: scrollOffset - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()   // AppKit does not clip to the frame by itself: nothing may land on the FILES header or tree
        if compact {   // Control: a hairline above the cards separates them from the agents list
            if !paths.isEmpty { Theme.dynamic(.border).setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
            if paths.isEmpty { return }
        }
        let t = "Files" as NSString, ta: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(14, .semibold), .foregroundColor: Theme.dynamic(.text)]
        if !compact {
            t.draw(at: NSPoint(x: 16, y: 23), withAttributes: ta)
            ("\(paths.count)" as NSString).draw(at: NSPoint(x: 16 + t.size(withAttributes: ta).width + 6, y: 24), withAttributes: [.font: ThemeFont.sans(14), .foregroundColor: Theme.dynamic(.textMuted)])
        }
        if paths.isEmpty && !compact {
            (Self.emptyText as NSString).draw(with: NSRect(x: 16, y: 59, width: bounds.width - 32, height: emptyTextHeight), options: .usesLineFragmentOrigin, attributes: Self.emptyAttrs)
            return
        }
        let m = layoutModel
        // Cards are clipped to the list's own viewport: nothing is drawn over the title above or outside the frame (the
        // sidebar's FILES header and tree sit right next to it).
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: m.viewport.intersection(bounds)).addClip()
        for i in m.visible(offset: scrollOffset) {
            let p = paths[i], r = m.card(i, offset: scrollOffset), on = p == current
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            if on { Theme.dynamic(.bgSelected).setFill(); path.fill(); Theme.dynamic(.borderSelected).setStroke(); path.lineWidth = 1; path.stroke() }
            let name = (p as NSString).lastPathComponent, isDirty = dirty.contains(p)
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(13, on ? .semibold : .regular), .foregroundColor: Theme.dynamic(.text)]
            // The name ends before the × (the dot, when unsaved, sits right after it): tail-truncated like classic's rd-ellipsis.
            let room = OpenFilesLayout.nameWidth(card: r, dirty: isDirty)
            let tail = NSMutableParagraphStyle(); tail.lineBreakMode = .byTruncatingTail
            let nameW = min((name as NSString).size(withAttributes: nameAttrs).width, room)
            (name as NSString).draw(in: NSRect(x: r.minX + OpenFilesLayout.nameLead, y: r.minY + 5, width: room, height: 17), withAttributes: nameAttrs.merging([.paragraphStyle: tail]) { $1 })
            if isDirty {
                Theme.dynamic(.warning).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.minX + OpenFilesLayout.nameLead + nameW + 7, y: r.minY + 11, width: 7, height: 7)).fill()
            }
            let dir = ((p as NSString).deletingLastPathComponent).abbreviatingHome(home)
            let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingHead
            (dir as NSString).draw(in: NSRect(x: r.minX + OpenFilesLayout.nameLead, y: r.minY + 22, width: OpenFilesLayout.nameWidth(card: r, dirty: false), height: 14), withAttributes: [.font: ThemeFont.mono(11), .foregroundColor: Theme.dynamic(.textMuted), .paragraphStyle: ps])
            let x = OpenFilesLayout.closeRect(card: r)
            let g = ("×" as NSString), ga: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(15), .foregroundColor: Theme.dynamic(.textMuted)], gs = g.size(withAttributes: ga)
            g.draw(at: NSPoint(x: x.midX - gs.width / 2, y: x.midY - gs.height / 2), withAttributes: ga)
        }
        if m.scrolls {   // a thin scroll thumb on the right edge
            let track = m.viewport.insetBy(dx: 0, dy: 2), th = max(track.height * m.viewport.height / m.contentHeight, 24)
            let y = track.minY + (track.height - th) * (scrollOffset / m.maxOffset)
            Theme.dynamic(.textFaint).withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.width - 5, y: y, width: 3, height: th), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch layoutModel.hit(p, offset: scrollOffset) {
        case .close(let i): onClose?(paths[i])
        case .open(let i): onOpen?(paths[i])
        case .none: break
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
