#if MUYA_TEST_HOOKS
// Test-hook commands of the shortcut package (P3); only while MUYA_DEBUG_SOCKET is set.

import AppKit

extension DebugServer {
    func runP3(_ cmd: String, _ arg: String) -> String? {
        let c = controller
        guard let sc = (NSApp.delegate as? AppDelegate)?.shortcuts else { return nil }
        switch cmd {
        case "p3-state":
            // selected session id, sidebar / inspector / grid / viewer state, font size, quit hint, closed-tab count
            let sel = c.store.selected.map { String($0.id) } ?? "-"
            return "selected=\(sel) sessions=\(c.store.sessions.count) sidebar=\(c.sidebarCollapsed ? "hidden" : "shown") inspector=\(c.inspector.isHidden ? "hidden" : "shown") grid=\(c.gridMode) viewer=\(c.viewer.isHidden ? "hidden" : "shown") font=\(sc.fontSize) quithint=\(sc.quitHintVisible) closed=\(sc.closed.isEmpty ? 0 : 1) page=\(c.currentPage == nil ? "control" : "page") palette=\(c.palette.isOpen) cell=\(c.store.cell.w)x\(c.store.cell.h) active=\(NSApp.isActive) key=\(c.window.isKeyWindow) focus=\(c.window.firstResponder is TerminalView ? "terminal" : "other")"
        case "p3-panels":
            // sheets and panels currently open over the main window (the open / save dialogs)
            let kinds = NSApp.windows.compactMap { w -> String? in w is NSOpenPanel ? "open" : w is NSSavePanel ? "save" : nil }
            return kinds.isEmpty ? "none" : kinds.joined(separator: ",")
        case "p3-dismiss": for w in NSApp.windows { if let p = w as? NSSavePanel { p.cancel(nil) } }; return "ok"
        case "p3-createfile": return sc.createFile(URL(fileURLWithPath: arg)) ? "ok" : "error"
        case "p3-key":
            // p3-key <combo> (same combos as tools/cg-key.swift): a real NSEvent through NSApp.sendEvent, i.e. the key
            // monitor, the menu key equivalents, the window and TerminalView.keyDown. For a session where the app
            // cannot become the active app (so posted CGEvents are not delivered).
            guard let (code, flags, chars) = Self.parseCombo(arg),
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return "error: bad combo" }
            // A monitor that returns nil swallows the event in AppKit's own event loop; NSApp.sendEvent called by hand
            // does not honour that, so run the monitor first and only send what it left over.
            if sc.handle(e) == nil { return "ok" }
            NSApp.sendEvent(e)
            return "ok"
        case "p3-activate": NSApp.activate(ignoringOtherApps: true); c.window.makeKeyAndOrderFront(nil); return "ok"
        case "p3-selectall": c.terminal.selectAll(nil); return "ok"
        case "p3-focus-none": c.window.makeFirstResponder(nil); return "ok"
        case "p3-focus-terminal": c.window.makeFirstResponder(c.terminal); return "ok"
        case "p3-open": sc.receive(paths: [arg]); return "ok"
        default: return nil
        }
    }

    private static let comboCodes: [String: (UInt16, String)] = [
        "a": (0, "a"), "d": (2, "d"), "f": (3, "f"), "b": (11, "b"), "w": (13, "w"), "e": (14, "e"), "r": (15, "r"), "t": (17, "t"),
        "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"), "=": (24, "="), "9": (25, "9"), "-": (27, "-"), "0": (29, "0"),
        "o": (31, "o"), "u": (32, "u"), "c": (8, "c"), "k": (40, "k"), "l": (37, "l"), "n": (45, "n"), "q": (12, "q"),
        "return": (36, "\r"), "esc": (53, "\u{1B}"), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
    ]

    static func parseCombo(_ s: String) -> (UInt16, NSEvent.ModifierFlags, String)? {
        var f: NSEvent.ModifierFlags = []
        var name = ""
        for p in s.split(separator: "+").map(String.init) {
            switch p {
            case "cmd": f.insert(.command)
            case "shift": f.insert(.shift)
            case "opt": f.insert(.option)
            case "ctrl": f.insert(.control)
            default: name = p
            }
        }
        guard let (code, chars) = comboCodes[name] else { return nil }
        return (code, f, chars)
    }
}
#endif
