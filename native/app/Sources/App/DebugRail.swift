#if MUYA_TEST_HOOKS
// Test-hook commands of the sessions rail; only while MUYA_DEBUG_SOCKET is set.
//   rail-state            "collapsed=… page=… selected=… order=… pane: items=… offset=…"
//   rail-flip sessions|menu     what ‹ › do        rail-key left|right|up|down    a ⌃⌥ arrow through the shortcut router (no system event)
//   rail-pick <id>        a click on a rail item   sidebar-set open|closed     the header toggle, to a known state
//   mock-many             adds the 12-session mock list (a split group, a waiting one, an agent-opened one) for screenshots

import AppKit

extension DebugServer {
    func runRail(_ cmd: String, _ arg: String) -> String? {
        let c = controller
        switch cmd {
        case "rail-state":
            let r = c.frameView.rail
            return "collapsed=\(c.sidebarCollapsed) page=\(c.railPages.page) showsSessions=\(c.railPages.showsSessions) selected=\(c.store.selected.map { String($0.id) } ?? "-") order=\(c.agentsPanel.onScreenSessions.map { String($0.id) }.joined(separator: ",")) pane: \(r.sessionsPane.debugState()) paneHidden=\(r.sessionsPane.isHidden) switcherHidden=\(r.switcher.isHidden)"
        case "rail-flip": return c.railFlip(arg == "menu" ? .menu : .sessions) ? "ok" : "no-op"
        case "rail-key":
            let code: [String: UInt16] = ["left": VK.left, "right": VK.right, "up": VK.up, "down": VK.down]
            guard let kc = code[arg], let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .numericPad, .function], timestamp: 0, windowNumber: c.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: kc) else { return "error: rail-key left|right|up|down" }
            let used = (NSApp.delegate as? AppDelegate)?.shortcuts.handle(e) == nil
            return used ? "handled" : "passed-through"
        case "rail-pick": guard let id = UInt64(arg) else { return "error: rail-pick <id>" }; c.railPick(id); return "ok"
        case "sidebar-set":
            if c.sidebarCollapsed != (arg == "closed") { c.toggleSidebar() }
            return "collapsed=\(c.sidebarCollapsed)"
        case "mock-many": MockData.installMany(store: c.store); return "sessions=\(c.store.sessions.count)"
        default: return nil
        }
    }
}

extension MockData {
    /// Mock list for the rail screenshots: ids 1-3 stay as they are; 4-12 add idle shells, a second waiting Claude, an opencode and an agent-opened terminal.
    static func installMany(store: Store) {
        let ccp = store.home + "/Documents/claude-control-plane"
        let busy = "{\"busy\":true,\"activity\":{\"verb\":\"Thinking…\"},\"mode\":\"default\",\"modeDetected\":true}"
        let wait = "{\"modeDetected\":true,\"mode\":\"default\",\"permission\":{\"tool\":\"Bash\",\"target\":\"npm test\",\"question\":\"run\",\"options\":[{\"kind\":\"approve\",\"key\":\"1\"}]}}"
        let idle = "{\"modeDetected\":true,\"mode\":\"default\"}"
        func make(_ id: UInt64, _ name: String, _ cwd: String, kind: String?, screen: String?, status: String?, agent: String? = nil) -> SessionModel {
            let r = Replica(cols: 105, rows: 38, theme: store.theme)!
            r.write(Data("\u{1b}[2J\u{1b}[H\(name)\r\n".utf8))
            let s = SessionModel(id: id, pid: Int32(51_000 + id), name: name, cwd: cwd, replica: r)
            s.screen = screen.flatMap { ScreenSummary(json: $0) }; s.statusLine = status; s.kind = kind; s.openedBy = agent
            return s
        }
        let extra = [
            make(4, "iptv-2a", store.home + "/Documents/iptv", kind: "claude", screen: idle, status: "Claude · default"),
            make(5, "numbat-c3", store.home + "/Documents/numbat", kind: "claude", screen: busy, status: "Thinking…"),
            make(6, "serbest", store.home, kind: nil, screen: nil, status: nil),
            make(7, "build-watch", ccp, kind: nil, screen: nil, status: nil),
            make(8, "release-notes", ccp, kind: "claude", screen: wait, status: "Needs permission: Bash"),
            make(9, "api-review", ccp, kind: "opencode", screen: "{\"busy\":true,\"mode\":\"default\"}", status: "Working…"),
            make(10, "worker-1", ccp, kind: "claude", screen: busy, status: "Thinking…", agent: "muya-all"),
            make(11, "skills-envanter", store.home + "/control-plane", kind: "claude", screen: idle, status: "Claude · default"),
            make(12, "ssh-psmp", store.home, kind: nil, screen: nil, status: nil),
        ]
        store.installMock(Array(store.sessions.prefix(3)) + extra, selected: 1)
    }
}
#endif
