// A split view that draws no divider (and takes no width for it) while one of its panes is hidden.
//
// NSSplitView keeps its divider when an arranged subview is hidden / collapsed: a pane that is "gone" (the sidebar while a page or the
// grid is open, the inspector while it is closed) left a 1 px line down the middle of every screen. The frame uses this class
// for both splits, so a hidden pane never leaves a divider behind.

import AppKit

open class HidingDividerSplit: NSSplitView {
    /// True while any pane is hidden or collapsed.
    open var hasHiddenPane: Bool { arrangedSubviews.contains { $0.isHidden } || subviews.contains { $0.isHidden && arrangedSubviews.contains($0) } }

    open override var dividerThickness: CGFloat { hasHiddenPane ? 0 : super.dividerThickness }

    open override func drawDivider(in rect: NSRect) {
        if !hasHiddenPane { super.drawDivider(in: rect) }
    }
}
