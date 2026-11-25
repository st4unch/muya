// Size of the footer "status fields" popover (src/redesign/StatusPicker.tsx: 360 wide, 28 px rows, headings with 6/4 padding,
// the list capped at min(60vh, 460) and scrolling beyond that). Pure so the popover is as tall as its rows need and never taller
// than the screen allows; the AppKit view only applies it (Tests/FieldPickerTests.swift).

import Foundation

public enum FieldPickerLayout {
    public static let width: CGFloat = 360
    public static let rowHeight: CGFloat = 28
    public static let headingHeight: CGFloat = 25       // 6 top + 15 line (11 px, 600) + 4 bottom
    public static let rowGap: CGFloat = 1
    public static let searchBlock: CGFloat = 40         // 30 px field + 6 above + 4 below
    public static let noteHeight: CGFloat = 20          // "Status data appears for …"
    public static let emptyHeight: CGFloat = 34         // "No matching fields"
    public static let listPadding: CGFloat = 6          // top + bottom of the scrolled list
    public static let maxList: CGFloat = 460

    /// Height of the list content for `groups` headings and `rows` field rows (0 rows → the empty-state line).
    public static func contentHeight(groups: Int, rows: Int) -> CGFloat {
        if rows == 0 { return emptyHeight }
        return CGFloat(groups) * headingHeight + CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * rowGap + listPadding
    }

    /// The list viewport: all of the content up to `min(60 % of the screen, 460)`.
    public static func listHeight(groups: Int, rows: Int, screenHeight: CGFloat) -> CGFloat {
        min(contentHeight(groups: groups, rows: rows), min(screenHeight * 0.6, maxList))
    }

    /// The whole popover: search box, optional note, list.
    public static func popoverHeight(groups: Int, rows: Int, hasNote: Bool, screenHeight: CGFloat) -> CGFloat {
        searchBlock + (hasNote ? noteHeight : 0) + listHeight(groups: groups, rows: rows, screenHeight: screenHeight)
    }
}
