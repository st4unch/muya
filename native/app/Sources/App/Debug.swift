#if MUYA_TEST_HOOKS
// Test hook, off unless MUYA_DEBUG_SOCKET is set: a Unix socket speaking one command per line, so
// a script can drive the real app (type, switch, resize, appearance) and read its counters
// without needing accessibility permissions. Typing goes through the same Store input path a
// keystroke takes.

import AppKit
import Darwin
import Foundation

final class DebugServer {
    private let path: String
    let controller: MainController

    init(path: String, controller: MainController) {
        self.path = path
        self.controller = controller
    }

    func start() {
        var addr = sockaddr_un()
        // sun_path is 104 bytes including the terminating NUL: a longer path would be cut (or trap) and bind elsewhere.
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { NSLog("debug socket: path too long"); return }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        // Created 0600 in one step: no window in which another user could connect before the chmod.
        let oldMask = umask(0o177)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(oldMask)
        guard ok == 0, listen(fd, 4) == 0 else { NSLog("debug socket: \(String(cString: strerror(errno)))"); return }
        chmod(path, 0o600)
        let t = Thread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                // Same user only (the 0600 socket already says so; this is the second lock).
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { Darwin.close(c); continue }
                Thread.detachNewThread { [self] in serve(c) }
            }
        }
        t.name = "debug-socket"
        t.start()
    }

    /// One command per line; a client that sends more than this without a newline is dropped.
    static let maxLine = 64 * 1024

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            pending.append(contentsOf: buf[0 ..< n])
            if pending.count > Self.maxLine { return }
            while let nl = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[pending.startIndex ..< nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex ... nl)
                var reply = ""
                if line.hasPrefix("probe-") { reply = self.probe(line) } else { DispatchQueue.main.sync { reply = self.run(line) } }
                let out = Array((reply + "\n").utf8)
                _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
            }
        }
    }

    func post(chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow? = nil) {
        let w = window ?? controller.window
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: keyCode) else { continue }
            w.sendEvent(e)
        }
    }

    private func run(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let cmd = parts.first else { return "error: empty" }
        let arg = parts.count > 1 ? String(parts[1]) : ""
        let store = controller.store
        if let r = runExtra(String(cmd), arg) { return r }
        switch cmd {
        case "launch":
            // ms from process creation (kernel start time) to: sidebar listing the sessions, each restored screen.
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return "error: sysctl" }
            let tv = info.kp_proc.p_un.__p_starttime
            let start = Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
            func ms(_ d: Date) -> Int { Int(((d.timeIntervalSince1970 - start) * 1000).rounded()) }
            let snaps = store.snapshotTimes()
            let shown = store.sessionsShownAt.map(ms) ?? -1
            let per = store.sessions.compactMap { s in snaps[s.id].map { "\(s.id)=\(ms($0))" } }.joined(separator: ",")
            return "sessions=\(store.sessions.count) shown_ms=\(shown) snapshots=\(snaps.count) last_snapshot_ms=\(snaps.values.map(ms).max() ?? -1) per=\(per)"
        case "fullscreen": controller.window.toggleFullScreen(nil); return "ok"
        case "zoom": controller.window.zoom(nil); return "ok"
        case "windowid": return "\(controller.window.windowNumber)"
        case "sessions":
            return store.sessions.map { "\($0.id)\t\($0.name)\t\($0.cwd.abbreviatingHome(store.home))\t\($0.state.text)\(store.selected === $0 ? "\t*" : "")" }.joined(separator: "\n")
        case "select":
            guard let id = UInt64(arg), let s = store.sessions.first(where: { $0.id == id }) else { return "error: no such session" }
            store.select(s)
            return "ok"
        case "new":
            let before = store.sessions.count
            store.spawn(cwd: arg.isEmpty ? store.home : arg)
            return store.sessions.count > before ? "ok \(store.sessions.last!.id)" : "error: spawn failed"
        case "close":
            guard let id = UInt64(arg), let s = store.sessions.first(where: { $0.id == id }) else { return "error: no such session" }
            store.close(s)
            return "ok"
        case "type":
            // `type "echo hi\n"`: a JSON string; "\n" is the Enter key, everything else is text input.
            guard let data = arg.data(using: .utf8), let text = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else { return "error: type needs a JSON string" }
            var chunk = ""
            for ch in text {
                if ch == "\n" { store.sendText(chunk); chunk = ""; store.sendKey("enter", mods: 0) } else { chunk.append(ch) }
            }
            store.sendText(chunk)
            return "ok"
        case "key":
            let w = arg.split(separator: " ")
            guard let k = w.first else { return "error: key <name> [mods]" }
            store.sendKey(String(k), mods: w.count > 1 ? UInt16(w[1]) ?? 0 : 0)
            return "ok"
        case "nsevent":
            // Real NSEvents through window.sendEvent -> keyDown -> input context -> insertText:
            // everything a keyboard does except the HID layer.
            guard let data = arg.data(using: .utf8), let text = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else { return "error: nsevent needs a JSON string" }
            for ch in text {
                let code: UInt16 = ch == "\n" ? 36 : ch == "\t" ? 48 : 0
                post(chars: String(ch), keyCode: code, flags: [])
            }
            return "ok"
        case "nskey":
            // nskey <keyCode> [shift|alt|ctrl|cmd ...]  (126 = up arrow, 36 = return, ...)
            let w = arg.split(separator: " ").map(String.init)
            guard let c = w.first.flatMap({ UInt16($0) }) else { return "error: nskey <keyCode> [mods]" }
            var f: NSEvent.ModifierFlags = []
            for m in w.dropFirst() { switch m { case "shift": f.insert(.shift); case "alt": f.insert(.option); case "ctrl": f.insert(.control); case "cmd": f.insert(.command); default: break } }
            let chars = c == 126 ? String(UnicodeScalar(0xF700)!) : c == 125 ? String(UnicodeScalar(0xF701)!) : c == 123 ? String(UnicodeScalar(0xF702)!) : c == 124 ? String(UnicodeScalar(0xF703)!) : ""
            post(chars: chars, keyCode: c, flags: f)
            return "ok"
        case "click":
            // The sidebar row path (what a mouse click does): select through the table view.
            guard let row = Int(arg), row >= 0, row < store.sessions.count else { return "error: no such row" }
            controller.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return "ok"
        case "text": return store.selected?.replica.visibleText() ?? ""
        case "appearance":
            switch arg {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
            return "ok"
        case "window":
            let w = arg.split(separator: " ").compactMap { Double($0) }
            guard w.count == 2 else { return "error: window <w> <h>" }
            controller.window.setContentSize(NSSize(width: w[0], height: w[1]))
            return "ok"
        case "metrics":
            var m = controller.terminal.renderer.metricsSnapshot()
            m["grid"] = "\(store.grid.cols)x\(store.grid.rows)"
            m["sessions"] = store.sessions.count
            m["atlas_glyphs"] = controller.terminal.renderer.atlas.misses
            m["bytes_in_selected"] = store.selected?.replica.bytesIn ?? 0
            return String(decoding: (try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        case "theme":
            let t = controller.terminal
            return "app=\(NSApp.effectiveAppearance.name.rawValue) window=\(controller.window.effectiveAppearance.name.rawValue) view=\(t.effectiveAppearance.name.rawValue) renderer=\(t.renderer.theme.background.r == TerminalTheme.dark.background.r ? "dark" : "light")"
        case "colors": return store.selected?.replica.debugColors() ?? ""
        case "metrics-reset": controller.terminal.renderer.resetMetrics(); return "ok"
        default: return "error: unknown command \(cmd)"
        }
    }
}

// MARK: Faz 2b commands (selection, IME, scrollback, grid, latency probes)

extension DebugServer {
    func jsonString(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)) ?? Data(), as: UTF8.self)
    }

    private func decodeString(_ arg: String) -> String? {
        guard let d = arg.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) as? String
    }

    private func mouseEvent(_ type: NSEvent.EventType, _ view: TerminalView, col: Int, row: Int, flags: NSEvent.ModifierFlags, clicks: Int) -> NSEvent? {
        let m = view.metrics
        let o = m.origin(col: col, row: row)
        // A press lands in the left half of the cell (the cell is included), a drag / release in the right half.
        let fx = type == .leftMouseDown ? 0.25 : 0.75
        let p = view.convert(NSPoint(x: o.x + m.cellW * fx, y: o.y + m.cellH / 2), to: nil)
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: controller.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }

    /// Commands added in Faz 2b; nil = not one of these.
    func runExtra(_ cmd: String, _ arg: String) -> String? {
        let store = controller.store
        let w = arg.split(separator: " ").map(String.init)
        func tile(_ words: [String]) -> TerminalView {
            if let t = words.first(where: { $0.hasPrefix("tile=") }).flatMap({ Int($0.dropFirst(5)) }), t < controller.tileView.tiles.count { return controller.tileView.tiles[t].terminal }
            return controller.terminal
        }
        func flags(_ words: [String]) -> NSEvent.ModifierFlags {
            var f: NSEvent.ModifierFlags = []
            for m in words { switch m { case "shift": f.insert(.shift); case "opt": f.insert(.option); case "cmd": f.insert(.command); case "ctrl": f.insert(.control); default: break } }
            return f
        }
        switch cmd {
        case "grid":
            controller.setGrid(arg == "off" ? false : arg == "toggle" ? !controller.gridMode : true)
            controller.window.layoutIfNeeded()
            return "ok tiles=\(controller.tileView.shown) grid=\(controller.gridMode)"
        case "tiles":
            return controller.tileView.tiles.enumerated().filter { !$0.element.isHidden }.map { i, t in
                "\(i)\t\(t.terminal.session?.id.description ?? "-")\t\(t.terminal.lastGrid.cols)x\(t.terminal.lastGrid.rows)\t\(Int(t.frame.width))x\(Int(t.frame.height))\(t.focused ? "\t*" : "")"
            }.joined(separator: "\n")
        case "mouse":
            // mouse down|drag|up|move|right <col> <row> [clicks=N] [tile=N] [shift|opt|cmd]
            // move = the pointer arrives over the cell (hover); right = a right-click, answers with the titles of the menu it would show
            guard w.count >= 3, let col = Int(w[1]), let row = Int(w[2]) else { return "error: mouse down|drag|up|move|right <col> <row>" }
            let view = tile(w), f = flags(w)
            let clicks = w.first(where: { $0.hasPrefix("clicks=") }).flatMap { Int($0.dropFirst(7)) } ?? 1
            let type: NSEvent.EventType = w[0] == "down" ? .leftMouseDown : w[0] == "up" ? .leftMouseUp : w[0] == "move" ? .mouseMoved : w[0] == "right" ? .rightMouseDown : .leftMouseDragged
            guard let e = mouseEvent(type, view, col: col, row: row, flags: f, clicks: clicks) else { return "error: no event" }
            switch w[0] {
            case "down": view.mouseDown(with: e)
            case "up": view.mouseUp(with: e)
            case "move": view.mouseMoved(with: e)
            case "right": return view.menu(for: e)?.items.map { $0.isSeparatorItem ? "-" : $0.title }.joined(separator: "|") ?? "none"
            default: view.mouseDragged(with: e)
            }
            return "ok"
        case "bytes": return store.sessions.map { "\($0.id)\t\($0.replica.bytesIn)" }.joined(separator: "\n")
        case "selection": return jsonString(store.selected?.replica.selectedText() ?? "")
        case "copy":
            let view = controller.tileView.tiles.first { $0.terminal.session === store.selected }?.terminal ?? controller.terminal
            view.copy(nil)
            return jsonString(NSPasteboard.general.string(forType: .string) ?? "")
        case "clipboard":
            guard let t = decodeString(arg) else { return "error: clipboard <json string>" }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
            return "ok"
        case "paste":
            let view = controller.tileView.tiles.first { $0.terminal.session === store.selected }?.terminal ?? controller.terminal
            view.paste(nil)
            return "ok"
        case "clear-selection": store.selected?.replica.clearSelection(); controller.terminal.requestDraw(); return "ok"
        case "preedit", "commit":
            guard let t = decodeString(arg) else { return "error: \(cmd) <json string>" }
            let view = controller.tileView.tiles.first { $0.terminal.session === store.selected }?.terminal ?? controller.terminal
            if cmd == "preedit" {
                let attr = NSMutableAttributedString(string: t)
                attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: attr.length))
                view.setMarkedText(attr, selectedRange: NSRange(location: attr.length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                view.insertText(t, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            return "ok"
        case "unmark":
            let view = controller.tileView.tiles.first { $0.terminal.session === store.selected }?.terminal ?? controller.terminal
            view.unmarkText()
            return "ok"
        case "firstrect":
            let view = controller.tileView.tiles.first { $0.terminal.session === store.selected }?.terminal ?? controller.terminal
            let r = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
            let c = view.renderer.cursorCell
            return "cursor=\(c.x),\(c.y) rect=\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)) preedit=\(jsonString(view.preeditText))"
        case "wheel":
            // wheel <lines>: positive = scroll up (older output), through the same scrollWheel path a trackpad uses.
            guard let n = Double(arg.split(separator: " ").first ?? ""), let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(n * Double(controller.terminal.renderer.cellSizePoints.height)), wheel2: 0, wheel3: 0),
                  let e = NSEvent(cgEvent: cg) else { return "error: wheel <lines>" }
            let view = tile(w)
            view.scrollWheel(with: e)
            return "ok"
        case "scrollstate":
            guard let r = store.selected?.replica else { return "" }
            let s = r.scrollState
            return "history=\(s.history) offset_from_bottom=\(s.offsetFromBottom)"
        default: return runFaz3(cmd, arg)
        }
    }
}

// MARK: Faz 3a commands (file tree, viewers, occlusion, sleep / wake)

extension DebugServer {
    func runFaz3(_ cmd: String, _ arg: String) -> String? {
        let c = controller, f = c.files
        let w = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch cmd {
        case "files": return f.visibleRows().joined(separator: "\n")
        case "files-root": return f.root?.path ?? ""
        case "files-roots": return f.rootSummary()
        case "files-expand": return f.expand(path: arg) ? "ok" : "error: not found"
        case "files-hidden": f.setShowHidden(arg == "on"); return "ok hidden=\(f.showHidden)"
        case "files-stats": return "reloads=\(f.reloads) events=\(f.eventsSeen) hidden=\(f.showHidden)"
        case "files-select": return f.select(path: arg) ? "ok" : "error: not visible"
        case "files-menu": return f.select(path: arg) ? f.menuTitles().joined(separator: "|") : "error: not visible"
        case "files-open":
            guard f.select(path: arg), let n = f.node(path: arg) else { return "error: not visible" }
            f.open(n); return "ok"
        case "files-terminal":
            guard f.select(path: arg) else { return "error: not visible" }
            f.menuTerminal(); return "ok"
        case "files-copypath":
            guard f.select(path: arg) else { return "error: not visible" }
            f.menuCopyPath(); return jsonStringFaz3(NSPasteboard.general.string(forType: .string) ?? "")
        case "files-rename":
            // files-rename <path> <new name>
            guard w.count == 2, f.select(path: w[0]), let n = f.node(path: w[0]) else { return "error: files-rename <path> <name>" }
            return f.rename(n, to: w[1]).map { "error: \($0)" } ?? "ok"
        case "files-trash":
            guard f.select(path: arg), let n = f.node(path: arg) else { return "error: not visible" }
            f.trash(n, confirm: false); return f.lastTrashed.map { "ok \($0.path)" } ?? "ok"
        case "viewer-open":
            let url = URL(fileURLWithPath: arg)
            c.openViewer(url, FileKind.detect(url)); return c.viewer.contentDescription
        case "viewer": return c.viewer.isHidden ? "hidden" : c.viewer.contentDescription
        case "viewer-close": c.closeViewer(); return "ok"
        case "editor-bench": return c.viewer.currentSession?.debugBench(Int(arg) ?? 40) ?? "no editor"
        case "viewer-open-ms": return "\(c.viewer.lastOpenMs)"
        case "md-edit": c.viewer.debugToggleMarkdownEdit(); return "ok"
        case "editor-fold": c.viewer.currentSession?.debugFold(Int(arg) ?? 1); return c.viewer.currentSession?.debugState ?? "no editor"
        case "editor-cursor": c.viewer.currentSession?.debugAddCursor(Int(arg) ?? 0); return c.viewer.currentSession?.debugSelections ?? "no editor"
        case "editor-addnext": c.viewer.currentSession?.debugAddNext(); return c.viewer.currentSession?.debugSelections ?? "no editor"
        case "editor-selections": return c.viewer.currentSession?.debugSelections ?? "no editor"
        case "editor-diff-text": return jsonStringFaz3((c.viewer.currentSession?.debugDiffStrings).map { $0.0 + "\n=====\n" + $0.1 } ?? "")
        case "editor-cmd-s":
            // A synthesized ⌘S handed to the app's key handler (what the local event monitor calls); nothing reaches the system.
            guard let sc = (NSApp.delegate as? AppDelegate)?.shortcuts,
                  let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: c.window.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) else { return "error" }
            c.window.makeFirstResponder(arg == "terminal" ? c.terminal : c.window.contentView)
            return sc.handle(ev) == nil ? "handled" : "passed"
        case "editor-diff-frames": return c.viewer.currentSession?.debugDiffFrames ?? "no editor"
        case "viewer-open-anyway": c.viewer.debugOpenAnyway(); return "ok"
        case "editor-live": return "live=\(EditorSession.live) kept=\(c.viewer.sessions.count)"
        case "editor-state": return c.viewer.currentSession?.debugState ?? "no editor"
        case "editor-type": c.viewer.currentSession?.debugType(arg.replacingOccurrences(of: "\\n", with: "\n")); return c.viewer.currentSession?.debugState ?? "no editor"
        case "editor-caret": c.viewer.currentSession?.debugSetCaret(Int(arg) ?? 0); return "ok"
        case "editor-save": return c.viewer.currentSession.map { "\($0.save())" } ?? "no editor"
        case "editor-answer": EditorGuard.testAnswer = arg; return "ok"
        case "editor-toggle": c.viewer.currentSession?.debugToggle(arg); return c.viewer.currentSession?.debugState ?? "no editor"
        case "editor-undo": c.viewer.currentSession?.debugUndo(); return c.viewer.currentSession?.debugState ?? "no editor"
        case "editor-goto": let p = LineIndex.parse(arg); c.viewer.currentSession?.goTo(line: p?.line ?? 1, column: p?.column); return "ok"
        case "editor-find": c.viewer.currentSession?.debugFind(); return "ok"
        case "editor-text": return jsonStringFaz3(c.viewer.currentSession?.currentText ?? "")
        case "editor-close":
            guard let p = c.viewerPath else { return "no file" }
            var res = "pending"; c.closeFile(p) { res = $0 ? "closed" : "kept" }; return res
        case "editor-sheet":
            guard let sh = c.window.attachedSheet else { return "no sheet" }
            let r: NSApplication.ModalResponse = arg == "first" ? .alertFirstButtonReturn : arg == "second" ? .alertSecondButtonReturn : .alertThirdButtonReturn
            c.window.endSheet(sh, returnCode: r); return "ok"
        case "editor-sheet-title": return c.window.attachedSheet.map { _ in "sheet" } ?? "none"
        case "editor-quit": return "\(c.confirmQuit())"
        case "editor-reconcile": c.viewer.reconcileAll(); return "ok"
        case "viewer-scroll": return "\(c.viewer.scrollForTest(fraction: CGFloat(Double(arg) ?? 0)))"
        case "minimize": c.window.miniaturize(nil); return "ok"
        case "restore": c.window.deminiaturize(nil); return "ok"
        case "visibility": return "visible=\(c.windowVisible) suspended=\(TerminalView.drawingSuspended) occlusion=\(c.window.occlusionState.contains(.visible)) minimized=\(c.window.isMiniaturized)"
        case "occlude":
            // Simulates the state the real notification produces (the real one is also observed).
            c.setWindowVisible(arg != "on" && arg != "yes"); return "ok"
        case "sleep": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared); return "ok"
        case "wake": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
            let r = c.lastWakeResync
            return "ok wakes=\(c.wakeCount) sessions=\(r?.sessionsBefore ?? -1)->\(r?.sessionsAfter ?? -1) resync_ms=\(Int((r?.seconds ?? 0) * 1000))"
        case "ssh-reload", "ssh-connect", "ssh-unlock", "ssh-state", "ssh-form", "gallery", "gallery-close", "fonts", "composer", "rail", "dialog", "session-menu", "drop", "dump-views", "session-collapse", "mode-menu", "window-rect", "ssh-section", "ssh-secret", "resources-tab", "terminal-scheme", "toast-lift", "toast-panels", "app-activate", "status-fields", "status-footer", "footer-composer", "footer-height", "appearance-popover", "term-find", "term-menu", "term-link", "term-link-hover", "term-link-state", "term-link-capture", "term-link-menu", "term-link-run", "term-paste-path", "term-clear-scrollback": return runTheme(cmd, arg)
        case "ws-rows", "ws-select", "ws-choose", "ws-list", "ws-palette", "ws-state": return runWorkspaceScope(cmd, arg)
        case "of-state", "of-scroll", "of-overdraw", "of-click": return runFilesPanel(cmd, arg)
        case "rail-state", "rail-flip", "rail-key", "rail-pick", "sidebar-set", "mock-many": return runRail(cmd, arg)
        default: return runFaz4(cmd, arg) ?? runQueue(cmd, arg) ?? runP6(cmd, arg) ?? runP3(cmd, arg) ?? runSplit(cmd, arg) ?? runP4(cmd, arg) ?? runP7(cmd, arg) ?? runP12(cmd, arg) ?? runAC1921(cmd, arg) ?? runUiFixes(cmd, arg)
        }
    }

    private func jsonStringFaz3(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }
}

extension DebugServer {
    /// Latency probes run on the debug thread: they wait for a finished frame, which needs the main queue free.
    func probe(_ line: String) -> String {
        let w = line.split(separator: " ").map(String.init)
        let store = controller.store
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var t0 = 0.0, t1 = 0.0
        var failure: String?
        DispatchQueue.main.sync {
            func view(for s: SessionModel) -> TerminalView { controller.tileView.tiles.first { $0.terminal.session === s }?.terminal ?? controller.terminal }
            switch w[0] {
            case "probe-echo":
                guard let s = store.selected else { failure = "error: no session"; return }
                let marker = w.count > 1 ? w[1] : "Q"
                let v = view(for: s)
                s.replica.armProbe(Data(marker.utf8)) {
                    DispatchQueue.main.async { v.notifyAfterNextFrame { t1 = CACurrentMediaTime(); sem.signal() } }
                }
                t0 = CACurrentMediaTime()
                store.sendText(marker)
            case "probe-switch":
                guard w.count > 1, let id = UInt64(w[1]), let s = store.sessions.first(where: { $0.id == id }) else { failure = "error: no such session"; return }
                t0 = CACurrentMediaTime()
                store.select(s)
                view(for: s).notifyAfterNextFrame { t1 = CACurrentMediaTime(); sem.signal() }
            default: failure = "error: unknown probe"
            }
        }
        if let failure { return failure }
        if sem.wait(timeout: .now() + 3) != .success {
            DispatchQueue.main.sync { store.selected?.replica.disarmProbe() }
            return "timeout"
        }
        return String(format: "%.2f", (t1 - t0) * 1000)
    }
}
#endif
