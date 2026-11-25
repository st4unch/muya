// Footer status-field popover sizing: as tall as its rows need, capped, never the old fixed 460.

import Foundation

func runFieldPickerTests() {
    test("field picker: compact rows, capped list, filtered list shrinks") {
        typealias L = FieldPickerLayout
        check(L.rowHeight == 28, "classic row height")
        check(L.contentHeight(groups: 1, rows: 3) == 25 + 3 * 28 + 2 * 1 + 6, "one group of three rows")
        check(L.listHeight(groups: 6, rows: 40, screenHeight: 900) == 460, "long list is capped at 460")
        check(L.listHeight(groups: 6, rows: 40, screenHeight: 500) == 300, "and at 60% of a small screen")
        check(L.listHeight(groups: 1, rows: 2, screenHeight: 900) < 120, "two rows do not get a 460 box")
        check(L.contentHeight(groups: 0, rows: 0) == L.emptyHeight, "no match shows one empty line")
        check(L.popoverHeight(groups: 1, rows: 3, hasNote: true, screenHeight: 900) == L.searchBlock + L.noteHeight + L.contentHeight(groups: 1, rows: 3), "search + note + list")
        check(L.popoverHeight(groups: 6, rows: 40, hasNote: false, screenHeight: 900) == 40 + 460, "full popover")
    }
}
