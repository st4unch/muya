// Size of the Settings dialog (5.0.2): wider, not taller. Today's SettingsModal is 480 wide and as tall as its content (at most 85 vh); the
// native dialog keeps that on a small window and, where there is room, goes to two columns of sections side by side (960 wide), so the
// long list (Full Disk Access, Helper apps, Paired Macs, Updates) no longer scrolls through one narrow strip. Pure so the clamps are
// unit-tested (Tests/SettingsSizingTests.swift); SettingsController only applies it.

import Foundation

public struct SettingsSizePlan: Equatable, Sendable {
    /// The most columns that fit this window (1...3); the dialog uses the fewest that need no vertical scroll, up to this.
    public var columns: Int
    /// Dialog width for `columns` columns.
    public var width: CGFloat
    public var maxHeight: CGFloat
    public var available: CGFloat

    public static let singleWidth: CGFloat = 480
    public static let columnTarget: CGFloat = 480        // a column grows to this when there is room
    public static let columnMin: CGFloat = 400
    public static let sidePadding: CGFloat = 20
    public static let columnGap: CGFloat = 24
    public static let maxColumns = 3

    /// Dialog width for `n` columns, never wider than `available`.
    public static func width(columns n: Int, available: CGFloat) -> CGFloat {
        if n <= 1 { return min(singleWidth, max(available, 360)).rounded() }
        return min(available, CGFloat(n) * columnTarget + CGFloat(n - 1) * columnGap + 2 * sidePadding).rounded()
    }

    /// `hostWidth/hostHeight`: the window the dialog sits over; `screenWidth/screenHeight`: the visible screen (nil = unknown).
    public static func plan(hostWidth: CGFloat, hostHeight: CGFloat, screenWidth: CGFloat? = nil, screenHeight: CGFloat? = nil) -> SettingsSizePlan {
        var avail = hostWidth * 0.94
        if let screenWidth { avail = min(avail, screenWidth - 40) }
        // The dialog is its own window, so the Muya window behind it does not cap its height — only the screen does.
        // It still grows no further than its content needs, so a short dialog stays short.
        var maxH = (hostHeight * 0.94).rounded()
        if let screenHeight { maxH = (screenHeight - 40).rounded() }
        var n = 1
        for k in 2 ... maxColumns where avail - 2 * sidePadding + columnGap >= CGFloat(k) * (columnMin + columnGap) { n = k }
        return SettingsSizePlan(columns: n, width: width(columns: n, available: avail), maxHeight: maxH, available: avail)
    }

    /// Width of one column of sections inside a dialog of `width`.
    public static func columnWidth(dialogWidth: CGFloat, columns: Int) -> CGFloat {
        let inner = dialogWidth - 2 * sidePadding
        return columns <= 1 ? inner : (inner - CGFloat(columns - 1) * columnGap) / CGFloat(columns)
    }

    /// How many leading sections go in each of `columns` columns so the tallest column is as short as possible (sections keep their order).
    public static func splitCounts(heights: [CGFloat], columns: Int, spacing: CGFloat = 22) -> [Int] {
        let n = heights.count, cols = max(1, min(columns, max(n, 1)))
        func colHeight(_ a: Int, _ b: Int) -> CGFloat { a >= b ? 0 : heights[a ..< b].reduce(0, +) + spacing * CGFloat(b - a - 1) }
        var best = [n], bestMax = CGFloat.greatestFiniteMagnitude
        func go(_ start: Int, _ left: Int, _ cuts: [Int], _ curMax: CGFloat) {
            if left == 1 {
                let m = max(curMax, colHeight(start, n))
                if m < bestMax { bestMax = m; best = cuts + [n - start] }
                return
            }
            for end in start ... n { go(end, left - 1, cuts + [end - start], max(curMax, colHeight(start, end))) }
        }
        go(0, cols, [], 0)
        return best
    }
}
