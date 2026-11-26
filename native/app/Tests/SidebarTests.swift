// Unit tests of the left column's geometry and of the rail routing (Sources/Logic/SidebarGeometry.swift, ScreenRoute.swift).

import Foundation

func runSidebarTests() {
    test("FILES section: collapsed = the header alone, the tree has no height (both modes)") {
        for files in [false, true] {
            let g = SidebarGeometry.layout(width: 264, height: 624, expanded: false, filesMode: files, openFilesWanted: 60)
            check(g.tree.height == 0, "collapsed tree is empty (filesMode \(files))")
            check(g.header.height >= SidebarGeometry.barHeight - 1, "header row stays")
        }
    }
    test("FILES section: expanded gives the tree room, and the header sits right above it") {
        for files in [false, true] {
            let g = SidebarGeometry.layout(width: 264, height: 624, expanded: true, filesMode: files, openFilesWanted: 60)
            check(g.tree.height > 100, "tree has height (filesMode \(files)): \(g.tree.height)")
            check(abs(g.tree.minY - g.header.maxY) <= 1, "tree under its header")
        }
    }
    test("FILES section: collapsing in Control hands the room back to the agents list; the header goes to the hint lines") {
        let open = SidebarGeometry.layout(width: 264, height: 624, expanded: true, filesMode: false, openFilesWanted: 0)
        let shut = SidebarGeometry.layout(width: 264, height: 624, expanded: false, filesMode: false, openFilesWanted: 0)
        check(shut.agents!.height > open.agents!.height, "agents grow")
        check(shut.header.maxY == 624 - SidebarGeometry.hintHeight, "header pinned above the hints")
        check(open.agents!.maxY == open.header.minY && shut.agents!.maxY == shut.header.minY, "nothing overlaps the header")
    }
    test("FILES section on the Files screen: collapsed = the header flush with the bottom edge, open files on top (classic)") {
        let g = SidebarGeometry.layout(width: 264, height: 624, expanded: false, filesMode: true, openFilesWanted: 90)
        check(g.header.maxY == 624, "header flush with the bottom: \(g.header)")
        check(g.openFiles!.minY == 0 && g.openFiles!.height == 90 && g.openFiles!.maxY <= g.header.minY, "open files on top, above the header")
        let tall = SidebarGeometry.layout(width: 264, height: 300, expanded: false, filesMode: true, openFilesWanted: 5000)
        check(tall.openFiles!.maxY <= tall.header.minY, "a long open-files list never runs under the header")
        let open = SidebarGeometry.layout(width: 264, height: 624, expanded: true, filesMode: true, openFilesWanted: 90)
        check(open.tree.maxY == 624, "expanded: the tree runs to the bottom, the section grew upward")
    }
    test("FILES section on Control: open, the agents list keeps what its rows need (at most half), the tree gets the rest") {
        let few = SidebarGeometry.layout(width: 264, height: 624, expanded: true, filesMode: false, openFilesWanted: 0, agentsWanted: 220)
        check(few.agents!.height == 220, "short list keeps its rows: \(few.agents!.height)")
        check(few.tree.maxY == 624 - SidebarGeometry.hintHeight, "tree runs down to the hint lines")
        let many = SidebarGeometry.layout(width: 264, height: 624, expanded: true, filesMode: false, openFilesWanted: 0, agentsWanted: 5000)
        check(many.agents!.height == 312, "long list scrolls past half the column: \(many.agents!.height)")
        let tiny = SidebarGeometry.layout(width: 264, height: 300, expanded: true, filesMode: false, openFilesWanted: 0, agentsWanted: 5000)
        check(tiny.tree.height >= 120 - 1, "the tree never drops below 120 px: \(tiny.tree.height)")
    }
    test("FILES section: header click target is inside the view in every state") {
        for exp in [false, true] { for files in [false, true] {
            let g = SidebarGeometry.layout(width: 264, height: 624, expanded: exp, filesMode: files, openFilesWanted: 60)
            check(g.header.minY >= 0 && g.header.maxY <= 624, "header inside (exp \(exp), files \(files))")
        } }
    }

    test("rail: only Files mode shows the Files screen; a page and the Files screen are never up together") {
        for item in RailTarget.allCases {
            let r = ScreenRoute.afterRail(item)
            check(r.filesScreenVisible == (item == .files), "\(item): files screen \(r.filesScreenVisible)")
            if r.page != nil { check(!r.filesMode, "\(item): page with filesMode") }
        }
    }
    test("rail: every pairwise transition lands on exactly the target's screen (8 x 8)") {
        let pages = ["sessions", "queue", "resources", "ssh", "schedules"]
        for from in RailTarget.allCases { for to in RailTarget.allCases {
            _ = ScreenRoute.afterRail(from)
            let r = ScreenRoute.afterRail(to)   // the route depends on the target only: nothing of `from` can linger
            let visiblePages = pages.filter { r.pageVisible($0) }
            switch to {
            case .control: check(visiblePages.isEmpty && !r.filesScreenVisible && r.railActive() == .control, "\(from) -> Control")
            case .files: check(visiblePages.isEmpty && r.filesScreenVisible && r.railActive() == .files, "\(from) -> Files")
            case .kanban: check(visiblePages == ["queue"] && !r.filesScreenVisible && r.railActive(queueTab: "kanban") == .kanban, "\(from) -> Kanban")
            default: check(visiblePages.count == 1 && !r.filesScreenVisible && r.railActive() == to, "\(from) -> \(to): \(visiblePages) \(r.railActive())")
            }
        } }
    }
}

func runSidebarControlFilesTests() {
    test("Control with open files: their cards sit between the agents and the FILES header, capped, nothing overlaps") {
        for expanded in [false, true] {
            let g = SidebarGeometry.layout(width: 264, height: 700, expanded: expanded, filesMode: false, openFilesWanted: 0, agentsWanted: 300, controlFilesWanted: 5 + 22 * 44 + 8)
            let of = g.openFiles!
            check(of.maxY == g.header.minY, "right above the FILES header (expanded \(expanded))")
            check(g.agents!.maxY == of.minY && g.agents!.height >= 120, "agents above it keep 120+ px: \(g.agents!)")
            check(of.height <= (g.header.minY) * 0.4 + 0.5, "at most 40% of the area above the header: \(of.height)")
        }
    }
    test("Control with few open files: the list takes only its rows; with none, no list and the agents are as before") {
        let few = SidebarGeometry.layout(width: 264, height: 700, expanded: false, filesMode: false, openFilesWanted: 0, controlFilesWanted: 5 + 44 + 8)
        check(few.openFiles!.height == 57, "one card: \(few.openFiles!.height)")
        let none = SidebarGeometry.layout(width: 264, height: 700, expanded: false, filesMode: false, openFilesWanted: 0, controlFilesWanted: 0)
        let old = SidebarGeometry.layout(width: 264, height: 700, expanded: false, filesMode: false, openFilesWanted: 0)
        check(none.openFiles == nil && none == old, "unchanged without open files")
    }
}
