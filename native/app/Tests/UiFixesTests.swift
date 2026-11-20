// Unit tests of Sources/Logic/UiFixesLogic.swift and the Files-section height in SidebarGeometry.

import Foundation

func runUiFixesTests() {
    test("workspace menu: one row per folder, first-seen order, counts, folder name as title") {
        let r = WorkspaceMenuLogic.rows(cwds: ["/a/proj", "/b/other", "/a/proj", "", "/"])
        check(r.map(\.path) == ["/a/proj", "/b/other", "/"], "order and dedupe: \(r.map(\.path))")
        check(r[0] == .init(path: "/a/proj", title: "proj", count: 2) && r[1].count == 1, "counts")
        check(r[2].title == "/", "root keeps a title")
        check(WorkspaceMenuLogic.rows(cwds: []).isEmpty, "empty")
    }
    test("files height: parse clamps to 120...2000, junk = fill") {
        check(FilesHeightLogic.parse("300") == 300 && FilesHeightLogic.parse("5") == 120 && FilesHeightLogic.parse("99999") == 2000, "clamped")
        check(FilesHeightLogic.parse(nil) == nil && FilesHeightLogic.parse("abc") == nil && FilesHeightLogic.parse("nan") == nil, "fill")
    }
    test("files height: a dragged height is used, the agents list keeps 120, collapsed ignores it") {
        let fill = SidebarGeometry.layout(width: 264, height: 700, expanded: true, filesMode: false, openFilesWanted: 0, agentsWanted: 100)
        let g = SidebarGeometry.layout(width: 264, height: 700, expanded: true, filesMode: false, openFilesWanted: 0, agentsWanted: 100, filesHeight: 250)
        check(g.header.height + g.tree.height == 250, "section = 250: \(g.header.height + g.tree.height)")
        check(g.tree.maxY == 700 - SidebarGeometry.hintHeight && g.agents!.maxY == g.header.minY, "tree down to the hints, agents above the header")
        check(fill.tree.height != g.tree.height, "differs from fill")
        let big = SidebarGeometry.layout(width: 264, height: 700, expanded: true, filesMode: false, openFilesWanted: 0, filesHeight: 2000)
        check(big.agents!.height >= 120, "agents keep 120: \(big.agents!.height)")
        let small = SidebarGeometry.layout(width: 264, height: 700, expanded: true, filesMode: false, openFilesWanted: 0, filesHeight: 10)
        check(small.header.height + small.tree.height >= 120, "section never below 120")
        let shut = SidebarGeometry.layout(width: 264, height: 700, expanded: false, filesMode: false, openFilesWanted: 0, filesHeight: 400)
        check(shut.tree.height == 0, "collapsed ignores the height")
    }
    test("collapsed roots: toggle, set, prune") {
        var c = CollapsedRoots()
        check(c.isExpanded("/a"), "open by default")
        c.toggle("/a"); check(!c.isExpanded("/a") && c.isExpanded("/b"), "collapsed")
        c.toggle("/a"); check(c.isExpanded("/a"), "open again")
        c.set("/a", expanded: false); c.set("/b", expanded: false); c.prune(keeping: ["/b"])
        check(c.isExpanded("/a") && !c.isExpanded("/b"), "pruned")
    }
    test("title bar double-click: Maximize/unset = zoom, Minimize, None") {
        check(TitleBarAction.from(defaultsValue: nil) == .zoom && TitleBarAction.from(defaultsValue: "Maximize") == .zoom, "zoom")
        check(TitleBarAction.from(defaultsValue: "Minimize") == .minimize && TitleBarAction.from(defaultsValue: "None") == .none, "minimize / none")
        check(TitleBarAction.from(defaultsValue: "Fill") == .zoom, "unknown = zoom, never full screen")
    }
    test("progress strip: turn progress only with the chat box open, update notice either way") {
        check(StripVisibility.showsProgress(working: true, composerOpen: true), "working + chat open")
        check(!StripVisibility.showsProgress(working: true, composerOpen: false), "working + chat closed: hidden")
        check(!StripVisibility.showsProgress(working: false, composerOpen: true), "idle")
        check(StripVisibility.shows(working: false, updateReady: true, composerOpen: false), "update notice with chat closed")
        check(!StripVisibility.shows(working: true, updateReady: false, composerOpen: false), "no strip at all")
    }
    test("progress strip: terminal frame is unchanged by idle -> working with the chat box closed") {
        func terminalHeight(working: Bool, composerOpen: Bool) -> CGFloat {
            1000 - StripVisibility.height(working: working, updateReady: false, composerOpen: composerOpen, full: 34)
        }
        check(terminalHeight(working: false, composerOpen: false) == terminalHeight(working: true, composerOpen: false), "chat closed: same terminal height")
        check(terminalHeight(working: false, composerOpen: true) != terminalHeight(working: true, composerOpen: true), "chat open: strip takes its row")
    }
    test("session origin: tooltip only for agent-opened sessions") {
        check(SessionOrigin.tooltip(openedBy: "api-work") == "Opened by api-work" && SessionOrigin.tooltip(openedBy: nil) == nil, "tooltip")
    }
}
