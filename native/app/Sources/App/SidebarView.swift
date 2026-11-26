// WP2/WP5 — the sidebar of today's Muya: the agents panel on top and, at the bottom, a "› FILES N" row that opens the file
// tree (collapsed by default, like src/redesign/FilesSection.tsx).

import AppKit

final class SidebarView: FillView {
    let agents: NSView, files: NSView
    /// The rail's Files item: the open-files list replaces the agents, the tree fills the panel (ControlScreen mode "files").
    let openFiles = OpenFilesList()
    var filesMode = false { didSet { if filesMode != oldValue { agents.isHidden = filesMode; openFiles.isHidden = !filesMode; files.isHidden = !expanded; needsLayout = true; needsDisplay = true } } }
    var onExpand: ((Bool) -> Void)?   // P4: muya.panels.filesOpen
    var expanded = false { didSet { onExpand?(expanded); files.isHidden = !expanded; needsLayout = true; needsDisplay = true } }
    var count: () -> Int = { 0 }
    /// The dragged height of the FILES section (header + tree); nil = fill what the agents list leaves (classic filesH).
    var filesHeight: CGFloat? { didSet { if filesHeight != oldValue { needsLayout = true; needsDisplay = true } } }
    var onFilesHeight: ((CGFloat?) -> Void)?
    private var dragging = false
    static let barHeight = SidebarGeometry.barHeight
    /// The two hint lines under the Files row (AgentList.tsx footer): 10 px padding, 12 px text, 4 px gap, 1 px rule above.
    static let hintHeight = SidebarGeometry.hintHeight

    init(agents: NSView, files: NSView) {
        self.agents = agents; self.files = files
        super.init(.bgPanel)
        trailing = true
        addSubview(agents); addSubview(files); addSubview(openFiles)
        (agents as? AgentsPanel)?.onWantedChange = { [weak self] in self?.needsLayout = true }
        openFiles.isHidden = true; openFiles.onResize = { [weak self] in self?.needsLayout = true }
        files.isHidden = true
        setAccessibilityRole(.group); setAccessibilityLabel("Sidebar")
    }
    required init?(coder: NSCoder) { fatalError() }

    private var geometry: SidebarGeometry { SidebarGeometry.layout(width: bounds.width, height: bounds.height, expanded: expanded, filesMode: filesMode, openFilesWanted: openFiles.wantedHeight, agentsWanted: (agents as? AgentsPanel)?.wantedHeight ?? 0, filesHeight: filesHeight) }
    var filesHeaderFrame: NSRect { geometry.header }
    override func layout() {
        super.layout()
        let g = geometry
        if let r = g.agents { agents.frame = r }
        if let r = g.openFiles { openFiles.frame = r }
        files.frame = g.tree
        window?.invalidateCursorRects(for: self)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if filesMode {   // the section header sits under the open files, the tree takes the rest; no hint lines
            let b = filesHeaderFrame
            Theme.dynamic(.border).setFill(); NSRect(x: 0, y: b.minY, width: bounds.width - 1, height: 1).fill()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState(); ctx.translateBy(x: 14 + 5, y: b.midY + 1); ctx.rotate(by: expanded ? .pi / 2 : 0); ctx.translateBy(x: -5, y: -5)
                ThemeIcons.draw(.chevronRight, in: ctx, size: 10, color: Theme.dynamic(.textMuted)); ctx.restoreGState()
            }
            let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(11, .semibold), .kern: 0.66, .foregroundColor: Theme.dynamic(.textMuted)]
            let t = "FILES" as NSString, w = t.size(withAttributes: a).width
            t.draw(at: NSPoint(x: 32, y: b.midY - t.size(withAttributes: a).height / 2 + 1), withAttributes: a)
            ("\(count())" as NSString).draw(at: NSPoint(x: 32 + w + 8, y: b.midY - 6), withAttributes: [.font: ThemeFont.sans(11), .foregroundColor: Theme.dynamic(.textFaint)])
            return
        }
        let b = filesHeaderFrame
        Theme.dynamic(.border).setFill(); NSRect(x: 0, y: b.minY, width: bounds.width - 1, height: 1).fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState(); ctx.translateBy(x: 14 + 5, y: b.midY); ctx.rotate(by: expanded ? .pi / 2 : 0); ctx.translateBy(x: -5, y: -5)
            ThemeIcons.draw(.chevronRight, in: ctx, size: 10, color: Theme.dynamic(.textMuted)); ctx.restoreGState()
        }
        let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(11, .semibold), .kern: 0.66, .foregroundColor: Theme.dynamic(.textMuted)]
        let t = "FILES" as NSString
        t.draw(at: NSPoint(x: 32, y: b.midY - t.size(withAttributes: a).height / 2), withAttributes: a)
        let n = "\(count())" as NSString, w = t.size(withAttributes: a).width
        n.draw(at: NSPoint(x: 32 + w + 8, y: b.midY - 7), withAttributes: [.font: ThemeFont.sans(11), .foregroundColor: Theme.dynamic(.textFaint)])
        // hint lines (today's footer of the agent list)
        let hy = bounds.height - Self.hintHeight
        Theme.dynamic(.border).setFill(); NSRect(x: 0, y: hy, width: bounds.width - 1, height: 1).fill()
        let sans: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textMuted)]
        let mono: [NSAttributedString.Key: Any] = [.font: ThemeFont.mono(12), .foregroundColor: Theme.dynamic(.textMuted)]
        for (i, (l, r)) in [("Drag to reorder · onto a session to split", "⌘1–9"), ("Switch workspace", "⌥⌘1–9 · ⌥⌘0 all")].enumerated() {
            let y = hy + 11 + CGFloat(i) * 19
            let rw = (r as NSString).size(withAttributes: mono).width
            let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail
            (l as NSString).draw(in: NSRect(x: 16, y: y, width: max(0, bounds.width - 1 - 32 - rw - 8), height: 16), withAttributes: sans.merging([.paragraphStyle: ps]) { $1 })
            (r as NSString).draw(at: NSPoint(x: bounds.width - 1 - 16 - rw, y: y), withAttributes: mono)
        }
    }
    /// The divider between the agents list and FILES (classic: the "Resize files section" handle on the section's top edge).
    var dividerFrame: NSRect? {
        guard expanded, !filesMode else { return nil }
        let y = filesHeaderFrame.minY
        return NSRect(x: 0, y: y - 3, width: bounds.width - 1, height: 7)
    }
    override func resetCursorRects() { if let d = dividerFrame { addCursorRect(d, cursor: .resizeUpDown) } }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let d = dividerFrame, d.contains(convert(point, from: superview)) { return self }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        let p0 = convert(event.locationInWindow, from: nil)
        if let d = dividerFrame, d.contains(p0) {
            if event.clickCount == 2 { filesHeight = nil; onFilesHeight?(nil); return }   // double-click: back to fill
            dragging = true; return
        }
        if filesHeaderFrame.contains(convert(event.locationInWindow, from: nil)) { expanded.toggle() } else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return super.mouseDragged(with: event) }
        let y = convert(event.locationInWindow, from: nil).y
        let h = bounds.height - Self.hintHeight - y   // section = from the pointer down to the hint lines
        filesHeight = max(FilesHeightLogic.clamp(h, available: bounds.height - Self.hintHeight), SidebarGeometry.barHeight)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return super.mouseUp(with: event) }
        dragging = false; onFilesHeight?(filesHeight)
    }
    /// The first click on the header works even when the window was not key (the operator comes back from another app).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
