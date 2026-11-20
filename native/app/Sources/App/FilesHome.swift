// WP5 — the Files page of today's Muya when no file is open: header "Files", the empty state "No file open — Pick a file in
// the tree on the left, or search with ⌘K." The tree itself is the sidebar's FILES section (opened by the rail's Files item);
// opened files use the existing viewer on top of this view.

import AppKit

final class FilesHome: FillView {
    var count = 0 { didSet { needsDisplay = true } }
    init() {
        super.init(.bgApp)
        setAccessibilityRole(.group); setAccessibilityLabel("Files")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        func centered(_ s: String, _ y: CGFloat, _ a: [NSAttributedString.Key: Any]) {
            let sz = (s as NSString).size(withAttributes: a); (s as NSString).draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: y), withAttributes: a)
        }
        let mid = bounds.midY
        centered("No file open", mid - 30, [.font: ThemeFont.sans(15, .semibold), .foregroundColor: Theme.dynamic(.text)])
        centered("Pick a file in the tree on the left, or search with ⌘K.", mid - 4, [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textMuted)])
        centered("Images and PDFs open here too.", mid + 16, [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textMuted)])
    }
}
