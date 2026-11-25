// Settings dialog sizing: wide where there is room, single column and clamped where there is not.

import Foundation

func runSettingsSizingTests() {
    test("settings size plan: 2 columns at 1120 and 1913, 1 column when small, clamped to the screen") {
        typealias P = SettingsSizePlan
        let a = P.plan(hostWidth: 1120, hostHeight: 732)
        check(a.columns == 2 && a.width == 1024 && a.maxHeight == 688, "1120 window: \(a)")
        let b = P.plan(hostWidth: 1913, hostHeight: 1000)
        check(b.columns == 3 && b.width == 1528 && b.maxHeight == 940, "1913 window grows to three columns: \(b)")
        let c = P.plan(hostWidth: 800, hostHeight: 600)
        check(c.columns == 1 && c.width == 480, "800 window stays one column: \(c)")
        let d = P.plan(hostWidth: 380, hostHeight: 500)
        check(d.columns == 1 && d.width == 360, "tiny window never below 360: \(d)")
        let e = P.plan(hostWidth: 1913, hostHeight: 1000, screenWidth: 700, screenHeight: 500)
        check(e.columns == 1 && e.width <= 660 && e.maxHeight == 460, "screen clamp: \(e)")
        // A tall screen behind a short Muya window: the dialog may use the screen, not the window, so it need not scroll.
        let f = P.plan(hostWidth: 1913, hostHeight: 1000, screenWidth: 1920, screenHeight: 1200)
        check(f.maxHeight == 1160, "the screen sets the height, not the window behind it: \(f)")
        check(P.columnWidth(dialogWidth: 1024, columns: 2) == 480 && P.columnWidth(dialogWidth: 480, columns: 1) == 440, "column widths")
    }
    test("settings size plan: sections are split into columns, balanced and in order") {
        typealias P = SettingsSizePlan
        check(P.splitCounts(heights: [100, 100, 100, 100], columns: 2) == [2, 2], "even")
        check(P.splitCounts(heights: [300, 50, 50, 50], columns: 2) == [1, 3], "one big section on its own")
        check(P.splitCounts(heights: [100, 100, 100, 100, 100, 100], columns: 3) == [2, 2, 2], "three columns")
        check(P.splitCounts(heights: [100], columns: 3) == [1], "degenerate")
        let h: [CGFloat] = [120, 200, 90, 260, 140, 110, 300]
        let c = P.splitCounts(heights: h, columns: 3)
        check(c.reduce(0, +) == h.count && c.count == 3, "all sections placed: \(c)")
    }
}
