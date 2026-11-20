#if MUYA_TEST_HOOKS
// Test-hook commands of the state-restore package (P4); only while MUYA_DEBUG_SOCKET is set.

import AppKit

extension DebugServer {
    func runP4(_ cmd: String, _ arg: String) -> String? {
        let c = controller
        let split = c.inspector.superview as? InspectorSplit
        switch cmd {
        case "p4-state":
            let side = c.rootSplit.arrangedSubviews.first
            let sideW = side.map { $0.isHidden ? 0 : Int($0.frame.width.rounded()) } ?? 0
            let files = c.openFilePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ",")
            let l = c.store.legacy
            return "agents=\(c.sidebarCollapsed ? "hidden" : "shown") agentsW=\(sideW) inspector=\(c.inspector.isHidden ? "hidden" : "shown") inspectorW=\(c.inspector.isHidden ? 0 : Int(c.inspector.frame.width.rounded())) filesOpen=\(c.sidebar?.expanded == true) grid=\(c.gridMode) openFiles=\(files.isEmpty ? "-" : files) history=\(c.composer.text.history.count) font=\(c.store.prefs.int("terminalFontSize")) theme=\(c.store.prefs.string("appearance")) autoApprove=\(c.store.prefs.bool("autoApprove")) writes=\(l.writeCount)"
        case "p4-agents-width": c.rootSplit.setPosition(CGFloat(Double(arg) ?? 260), ofDividerAt: 0); return "ok"
        case "p4-toggle-sidebar": c.toggleSidebar(); return "ok"
        case "p4-inspector":
            c.toggleInspector(); return "ok"
        case "p4-inspector-width":
            guard let split else { return "error" }
            split.setPosition(split.bounds.width - CGFloat(Double(arg) ?? 320), ofDividerAt: 0); return "ok"
        case "p4-files": c.sidebar?.expanded = arg == "1"; return "ok"
        case "p4-files-click":   // a real click (hit-tested through the window) on the middle of the sidebar's FILES header
            guard let sb = c.sidebar else { return "error: no sidebar" }
            let p = sb.convert(NSPoint(x: sb.bounds.width / 2, y: sb.filesHeaderFrame.midY), to: nil)
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return "error: no event" }
                if let v = c.window.contentView!.superview!.hitTest(e.locationInWindow) { t == .leftMouseDown ? v.mouseDown(with: e) : v.mouseUp(with: e) }   // not window.sendEvent: a window that is not key swallows the first click
            }
            let hit = c.window.contentView!.superview!.hitTest(p)
            return "expanded=\(sb.expanded) hit=\(hit.map { String(describing: type(of: $0)) } ?? "-") bar=\(sb.filesHeaderFrame) p=\(p) chain=\(sequence(first: hit, next: { $0?.superview }).prefix(6).map { v in v.map { "\(type(of: $0)) \($0.convert($0.bounds, to: nil))" } ?? "-" })"
        case "screens":   // which page views / the Files screen are visible right now, and the rail highlight (rail pairwise test)
            let pages: [(String, NSView)] = [("sessions", c.sessionsPage), ("schedules", c.schedulesPage), ("queue", c.queuePage), ("ssh", c.sshPage), ("resources", c.resourcesPage)]
            let shown = pages.filter { !$0.1.isHidden }.map(\.0)
            let filesVisible = c.filesHome.superview != nil && !c.filesHome.isHidden
            return "pages=\(shown.isEmpty ? "-" : shown.joined(separator: ",")) filesScreen=\(filesVisible) rail=\(c.frameView.rail.active?.rawValue ?? "-") filesMode=\(c.filesMode) sidebarFilesMode=\(c.sidebar?.filesMode == true) expanded=\(c.sidebar?.expanded == true)"
        case "paste-test":   // paste-test text <t> | file <path> | image | none: fills a PRIVATE pasteboard (never the operator's clipboard) and presses ⌘V in the selected terminal
            let pb = NSPasteboard(name: NSPasteboard.Name("com.staunch.muya.paste-test"))
            pb.clearContents()
            let w = arg.split(separator: " ", maxSplits: 1).map(String.init)
            switch w.first ?? "" {
            case "text": pb.setString(w.count > 1 ? w[1] : "", forType: .string)
            case "file": if w.count > 1 { pb.writeObjects([URL(fileURLWithPath: w[1]) as NSURL]) }
            case "image":
                let img = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in NSColor.systemRed.setFill(); r.fill(); return true }
                if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) {
                    pb.setData(png, forType: .png); pb.setData(t, forType: .tiff)
                }
            default: break
            }
            TerminalView.pasteboard = pb; defer { TerminalView.pasteboard = .general }
            let view = c.tileView.tiles.first { $0.terminal.session === c.store.selected }?.terminal ?? c.terminal
            view.paste(nil)
            return "ok types=\((pb.types ?? []).map(\.rawValue).joined(separator: ","))"
        case "p4-grid": c.setGrid(arg == "1"); return "ok"
        case "p4-history": c.composer.text.history.append(arg); return "ok"
        case "p4-open": c.openViewer(URL(fileURLWithPath: arg), FileKind.detect(URL(fileURLWithPath: arg))); return "ok"
        case "p4-settings-bottom":   // scrolls the Settings window to its last row (the open-source footer line)
            func find(_ v: NSView) -> NSScrollView? { if let s = v as? NSScrollView { return s }; for x in v.subviews { if let r = find(x) { return r } }; return nil }
            guard let sv = c.settings.window.contentView.flatMap(find), let doc = sv.documentView else { return "error" }
            doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? doc.bounds.height : 0)); sv.reflectScrolledClipView(sv.contentView); return "ok"
        case "v5-return-dialog": c.settings.show(); c.settings.beta.confirmSwitchBack(); return "ok"   // the confirm dialog of "Return to Muya Classic" (docs/prd-muya-v5-replace.md)
        case "v5-dialog-dismiss": Dialogs.shared.dismiss(); return "ok"
        case "v5-menu-titles":   // the app menu's items, to prove "Return to Muya Classic (4.1.22)…" is there
            return (NSApp.mainMenu?.items.first?.submenu?.items.map(\.title) ?? []).joined(separator: "|")
        case "p4-quit": NSApp.terminate(nil); return "ok"
        default: return nil
        }
    }
}
#endif
