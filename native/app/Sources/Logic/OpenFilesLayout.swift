// The open-files list's layout decisions (src/redesign/OpenFilesList.tsx): the card column scrolls inside its own frame
// (classic: `overflow: auto` on the list under a fixed "Files N" title), a card's name is truncated to the width left before the
// close button, and only that button closes. Pure so it is unit-tested (Tests/OpenFilesLayoutTests.swift); OpenFilesList draws it.

import Foundation

public struct OpenFilesLayout: Equatable, Sendable {
    public static let rowHeight: CGFloat = 44
    public static let titleTop: CGFloat = 52      // Files mode: the "Files N" title row sits above the cards
    public static let compactTop: CGFloat = 5     // Control mode: no title (the FILES header below carries the count)
    public static let bottomPad: CGFloat = 8
    public static let cardInset: CGFloat = 10     // card x from the list's left edge
    public static let cardTrail: CGFloat = 11     // and from its right edge
    public static let closeSize: CGFloat = 24     // classic: the × button is 24x24 ...
    public static let closeMargin: CGFloat = 6    // ... 6 px from the card's right edge
    public static let nameLead: CGFloat = 10
    public static let dotSlot: CGFloat = 14       // the unsaved dot (7 px) and its gap, next to the name

    public var width: CGFloat
    public var height: CGFloat
    public var count: Int
    public var compact: Bool

    public init(width: CGFloat, height: CGFloat, count: Int, compact: Bool) {
        self.width = width; self.height = height; self.count = count; self.compact = compact
    }

    public var top: CGFloat { compact ? Self.compactTop : Self.titleTop }
    /// Where the cards live: from `top` to the bottom edge, never beyond the frame.
    public var viewport: CGRect { CGRect(x: 0, y: top, width: width, height: max(height - top, 0)) }
    public var contentHeight: CGFloat { CGFloat(count) * Self.rowHeight + Self.bottomPad }
    public var maxOffset: CGFloat { max(contentHeight - viewport.height, 0) }
    public func clamp(_ offset: CGFloat) -> CGFloat { min(max(offset, 0), maxOffset) }
    public var scrolls: Bool { maxOffset > 0 }

    /// The height the list asks its parent for: everything when the parent has the room (the parent caps it, the list then scrolls).
    public static func wantedHeight(count: Int, compact: Bool) -> CGFloat { (compact ? compactTop : titleTop) + CGFloat(count) * rowHeight + bottomPad }

    /// A card in list coordinates for the given scroll offset.
    public func card(_ i: Int, offset: CGFloat) -> CGRect {
        CGRect(x: Self.cardInset, y: top + CGFloat(i) * Self.rowHeight - offset, width: width - Self.cardInset - Self.cardTrail, height: Self.rowHeight - 4)
    }
    /// The cards that intersect the viewport (all that has to be drawn).
    public func visible(offset: CGFloat) -> Range<Int> {
        guard count > 0, viewport.height > 0 else { return 0..<0 }
        let first = max(Int(floor(offset / Self.rowHeight)), 0)
        let last = min(Int(ceil((offset + viewport.height) / Self.rowHeight)), count)
        return first < last ? first..<last : 0..<0
    }
    /// The offset that brings card `i` fully into view with the least movement.
    public func offsetRevealing(_ i: Int, from offset: CGFloat) -> CGFloat {
        guard i >= 0, i < count else { return clamp(offset) }
        let y = CGFloat(i) * Self.rowHeight
        if y < offset { return clamp(y) }
        if y + Self.rowHeight > offset + viewport.height { return clamp(y + Self.rowHeight - viewport.height) }
        return clamp(offset)
    }
    /// The × button: the only close target of a card.
    public static func closeRect(card: CGRect) -> CGRect {
        CGRect(x: card.maxX - closeMargin - closeSize, y: card.minY + (card.height - closeSize) / 2, width: closeSize, height: closeSize)
    }
    /// The width a card's name (and its folder line) may use: everything left of the × button, less the dot when the file is unsaved.
    public static func nameWidth(card: CGRect, dirty: Bool) -> CGFloat {
        max(closeRect(card: card).minX - 4 - (card.minX + nameLead) - (dirty ? dotSlot : 0), 0)
    }

    public enum Hit: Equatable, Sendable { case none, open(Int), close(Int) }
    /// What a click at `p` (list coordinates) does: ignored outside the viewport, closes only on the × button, opens anywhere else on a card.
    public func hit(_ p: CGPoint, offset: CGFloat) -> Hit {
        guard viewport.contains(p) else { return .none }
        for i in visible(offset: offset) {
            let c = card(i, offset: offset)
            guard c.contains(p) else { continue }
            return Self.closeRect(card: c).contains(p) ? .close(i) : .open(i)
        }
        return .none
    }
}
