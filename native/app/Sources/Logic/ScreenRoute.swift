// Which screen of the terminal area is up (src/App.tsx view state): the terminals, the rail's Files mode (a mode of the terminal area, not a page),
// or exactly one page. Pure so every rail transition is unit-tested pairwise (Tests/SidebarTests.swift); MainController applies it.
// Rule the old code broke: Files -> Control left the Files screen up because the route was only re-applied when the *page* changed.

import Foundation

public enum RailTarget: String, CaseIterable, Sendable {
    case control = "Control", files = "Files", sessions = "Sessions", queue = "Queue", kanban = "Kanban", resources = "Resources", ssh = "SSH", schedules = "Schedules"
}

public struct ScreenRoute: Equatable, Sendable {
    /// nil = the terminal area (Control or Files mode), else the page shown over it.
    public var page: String?
    public var filesMode: Bool

    public static let control = ScreenRoute(page: nil, filesMode: false)

    /// The route after the rail item is clicked.
    public static func afterRail(_ item: RailTarget) -> ScreenRoute {
        switch item {
        case .control: return ScreenRoute(page: nil, filesMode: false)
        case .files: return ScreenRoute(page: nil, filesMode: true)
        case .kanban: return ScreenRoute(page: "queue", filesMode: false)   // Queue and Kanban are two tabs of one page
        default: return ScreenRoute(page: item.rawValue.lowercased(), filesMode: false)
        }
    }

    /// Which views must be visible for this route: the Files screen only in Files mode without a page, never together with a page.
    public var filesScreenVisible: Bool { filesMode && page == nil }
    /// "No file open" is the Files screen's EMPTY state: it must go the moment the viewer shows a file, or it covers it
    /// (the viewer and this view fill the same area). Operator report, 2026-11-26: a file opened and the screen still said
    /// "No file open".
    public func filesEmptyStateVisible(fileOpen: Bool) -> Bool { filesScreenVisible && !fileOpen }
    public func pageVisible(_ name: String) -> Bool { page == name }
    /// The rail highlight.
    public func railActive(queueTab: String = "queue") -> RailTarget {
        guard let page else { return filesMode ? .files : .control }
        switch page {
        case "queue": return queueTab == "kanban" ? .kanban : .queue
        default: return RailTarget(rawValue: page.prefix(1).uppercased() + page.dropFirst()) ?? (page == "ssh" ? .ssh : .control)
        }
    }
}
