// Grid rules of today's Muya (src/redesign/GridScreen.tsx, gridKeys.ts): the four layouts and how many cells they have, which
// sessions the cells show (waiting first, an explicit pick per cell), and the swap/append rule of the "choose session" menu.

import Foundation

enum GridChoice: String, CaseIterable {
    case one = "1", oneByTwo = "1x2", twoByTwo = "2x2", threeByTwo = "3x2"
    var label: String { switch self { case .one: return "1"; case .oneByTwo: return "1×2"; case .twoByTwo: return "2×2"; case .threeByTwo: return "3×2" } }
    var shape: (cols: Int, rows: Int) { switch self { case .one: return (1, 1); case .oneByTwo: return (2, 1); case .twoByTwo: return (2, 2); case .threeByTwo: return (3, 2) } }
    var capacity: Int { shape.cols * shape.rows }
}

enum GridPlan {
    /// The sessions the cells show, in cell order. `picked` (the operator's own choice per cell) wins over the list order; with
    /// `waitingFirst` the waiting ones come first; the selected session is always among them when it exists.
    static func visible(ids: [UInt64], waiting: Set<UInt64>, waitingFirst: Bool, picked: [UInt64]?, selected: UInt64?, capacity: Int) -> [UInt64] {
        var base = picked.map { $0.filter(ids.contains) } ?? ids
        if waitingFirst { base = base.filter(waiting.contains) + base.filter { !waiting.contains($0) } }
        var out = Array(base.prefix(max(capacity, 0)))
        if let s = selected, ids.contains(s), !out.contains(s), !out.isEmpty { out[out.count - 1] = s }
        return out
    }

    /// `assignGridCell` of gridKeys.ts: choosing `pick` for the cell at `targetIndex` (nil = an empty cell). A session that is
    /// already in another cell trades places with the target; an empty cell appends the pick.
    static func assign(_ visible: [UInt64], targetIndex: Int?, pick: UInt64) -> [UInt64] {
        guard let i = targetIndex else { return visible.filter { $0 != pick } + [pick] }
        guard visible.indices.contains(i), visible[i] != pick else { return visible }
        var next = visible
        if let j = next.firstIndex(of: pick) { next[j] = visible[i] }
        next[i] = pick
        return next
    }

    /// Cell rectangles (origin top-left) for a grid of `cols` x `rows` inside `width` x `height` with the page padding and gap of the web (16 / 12).
    static func cells(cols: Int, rows: Int, width: Double, height: Double, padding: Double = 16, gap: Double = 12) -> [(x: Double, y: Double, w: Double, h: Double)] {
        guard cols > 0, rows > 0 else { return [] }
        let cw = (width - 2 * padding - gap * Double(cols - 1)) / Double(cols), ch = (height - 2 * padding - gap * Double(rows - 1)) / Double(rows)
        return (0 ..< cols * rows).map { i in (padding + Double(i % cols) * (cw + gap), padding + Double(i / cols) * (ch + gap), cw, ch) }
    }

    /// Short button text for Claude's "allow always" option, honest about how long it lasts (GridPanel.tsx alwaysAllowText):
    /// Bash rules are saved to the project ("don't ask again"), edit approvals end with the session. The full text is the tooltip.
    static func alwaysAllowText(_ label: String) -> String {
        let l = label.lowercased()
        if l.range(of: "don'?t ask again", options: .regularExpression) != nil { return "Don't ask again (this project)" }
        if l.contains("session") { return "Allow all this session" }
        return "Always allow"
    }
}
