#if MUYA_TEST_HOOKS
// Test-hook commands of the header / sidebar / file-tree fixes; only while MUYA_DEBUG_SOCKET is set. Every click is a real mouse
// event routed through the window's own hit-testing (never a CGEvent to the system).
//   uf-click <x> <y> [clicks] [send]   press+release at a point of the frame view (top-left origin); `send` goes through window.sendEvent
//   uf-ws-click                        click the Workspace chip; prints the menu the click asked for
//   uf-divider-drag <dy>               drag the Files divider by dy points (negative = up)
//   uf-divider-dbl                     double-click the Files divider
//   uf-state                           window frame / zoom / full screen, the Files section height
//   uf-tree-click <path>               one click in the middle of the row of that path in the Files tree (after files-expand)
//   uf-tree-chevron <path>             one click on the triangle of that row
//   uf-root-state                      roots and whether each is expanded
//   uf-mark-opened <id> <name>         marks a session as opened by an agent
//   uf-fields [mock|none] [filter]     opens the footer status-field popover (mock = sample status data) and returns its size
//   uf-fields-close                    closes it
//   uf-settings                        opens Settings and returns its size "w h columns"

import AppKit

extension DebugServer {
    func runUiFixes(_ cmd: String, _ arg: String) -> String? {
        let c = controller
        guard cmd.hasPrefix("uf-") else { return nil }
        let w = arg.split(separator: " ").map(String.init)
        func ev(_ t: NSEvent.EventType, _ p: NSPoint, _ n: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1)
        }
        func click(_ p: NSPoint, clicks: Int = 1, send: Bool = false, post: Bool = false) {   // p in window coordinates
            for n in 1 ... clicks {
                guard let down = ev(.leftMouseDown, p, n), let up = ev(.leftMouseUp, p, n), let v = c.window.contentView!.superview!.hitTest(p) else { continue }
                // A table tracks the press until the release arrives from the event queue: post it from another thread.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { NSApp.postEvent(up, atStart: false) }
                v.mouseDown(with: down)
            }
        }
        c.window.makeKey()   // an inactive dev app: its first click would otherwise only activate the window
        func winPoint(_ x: CGFloat, _ y: CGFloat) -> NSPoint { c.frameView.convert(NSPoint(x: x, y: y), to: nil) }
        switch cmd {
        case "uf-click":
            guard w.count >= 2, let x = Double(w[0]), let y = Double(w[1]) else { return "error: uf-click x y [clicks] [send]" }
            click(winPoint(x, y), clicks: w.count > 2 ? Int(w[2]) ?? 1 : 1, send: w.last == "send")
            return "ok"
        case "uf-ws-click":
            var titles: [String] = []
            MainController.menuHook = { m in titles = m.items.map { $0.isSeparatorItem ? "-" : ($0.state == .on ? "✓ " : "") + $0.title } }
            defer { MainController.menuHook = nil }
            let chip = c.frameView.header.chipRectForTest
            click(c.frameView.header.convert(NSPoint(x: chip.midX, y: chip.midY), to: nil))
            return titles.isEmpty ? "error: no menu" : titles.joined(separator: "|")
        case "uf-ws-popup":   // really opens the menu for N seconds (a screenshot of the screen can be taken meanwhile)
            MainController.menuAutoCancel = Double(arg) ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let chip = c.frameView.header.chipRectForTest
                let p = c.frameView.header.convert(NSPoint(x: chip.midX, y: chip.midY), to: nil)
                if let v = c.window.contentView!.superview!.hitTest(p), let e = ev(.leftMouseDown, p, 1) { v.mouseDown(with: e) }
                MainController.menuAutoCancel = 0
            }
            return "scheduled"
        case "uf-divider-drag":
            guard let sb = c.sidebar, let d = sb.dividerFrame, let dy = Double(arg) else { return "error: no divider (open FILES first)" }
            let p0 = sb.convert(NSPoint(x: d.midX, y: d.midY), to: nil), p1 = NSPoint(x: p0.x, y: p0.y - CGFloat(dy))   // window coords are bottom-up
            guard let v = c.window.contentView!.superview!.hitTest(p0), let e0 = ev(.leftMouseDown, p0, 1), let e1 = ev(.leftMouseDragged, p1, 1), let e2 = ev(.leftMouseUp, p1, 1) else { return "error: no hit" }
            v.mouseDown(with: e0); v.mouseDragged(with: e1); v.mouseUp(with: e2)
            return "ok hit=\(type(of: v)) height=\(sb.filesHeight.map { String(Int($0)) } ?? "fill")"
        case "uf-divider-dbl":
            guard let sb = c.sidebar, let d = sb.dividerFrame else { return "error: no divider" }
            click(sb.convert(NSPoint(x: d.midX, y: d.midY), to: nil), clicks: 2)
            return "ok height=\(sb.filesHeight.map { String(Int($0)) } ?? "fill")"
        case "uf-state":
            let f = c.window.frame
            return "frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)) zoomed=\(c.window.isZoomed) fullscreen=\(c.window.styleMask.contains(.fullScreen)) filesHeight=\(c.sidebar?.filesHeight.map { String(Int($0)) } ?? "fill") divider=\(c.sidebar?.dividerFrame != nil) action=\(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "unset")"
        case "uf-tree-click":
            let o = c.files.outline
            guard let n = c.files.node(path: arg), case let row = o.row(forItem: n), row >= 0 else { return "error: not visible" }
            let r = o.rect(ofRow: row)
            click(o.convert(NSPoint(x: r.minX + 80, y: r.midY), to: nil), post: true)
            let hit = c.window.contentView!.superview!.hitTest(o.convert(NSPoint(x: r.minX + 80, y: r.midY), to: nil))
            return "posted hit=\(sequence(first: hit, next: { $0?.superview }).prefix(5).map { v in v.map { String(describing: type(of: $0)) } ?? "-" })"
        case "uf-tree-chevron":
            let o = c.files.outline
            guard let n = c.files.node(path: arg), case let row = o.row(forItem: n), row >= 0 else { return "error: not visible" }
            let r = o.disclosureFrame(row: row)
            click(o.convert(NSPoint(x: r.midX, y: r.midY), to: nil), post: true)
            return "posted frame=\(r)"
        case "uf-root-state":
            return c.files.roots.map { "\($0.path)=\(c.files.outline.isItemExpanded($0) ? "open" : "closed")" }.joined(separator: "\n")
        case "uf-fields":
            c.statusData = w.first == "none" ? nil : ["model": ["display_name": "Opus 5.5", "id": "claude-opus-5-5"], "effort": ["level": "high"], "version": "2.1.245",
                "context_window": ["used_percentage": 42, "remaining_percentage": 58, "context_window_size": 1_000_000, "total_input_tokens": 420_000, "total_output_tokens": 18_500],
                "cost": ["total_cost_usd": 1.84, "total_duration_ms": 2_520_000], "rate_limits": ["five_hour": ["used_percentage": 31]], "session_name": "demo", "cwd": "/work/demo"]
            let ft = c.frameView.footer
            ft.onFields?(NSRect(x: ft.bounds.width - 60, y: 6, width: 20, height: 20))
            if w.count > 1, let p = c.fieldPicker { p.debugSetFilter(w.dropFirst().joined(separator: " ")) }
            return "ok \(c.fieldPicker?.debugWindowID ?? 0)"
        case "uf-fields-id": return "\(c.fieldPicker?.debugWindowID ?? 0)"
        case "uf-fields-rect":   // the popover's frame and the window's, so a check can prove it stays inside
            guard let p = c.fieldPicker, let pv = p.debugContentView, let pw = pv.window else { return "error: no field menu open" }
            // The popover's WINDOW is bigger than the menu: it carries a transparent shadow margin. Measure the menu.
            let f = pw.convertToScreen(pv.convert(pv.bounds, to: nil)), w = c.window.frame
            return "popover=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)) window=\(Int(w.minX)),\(Int(w.minY)),\(Int(w.width)),\(Int(w.height))"
        case "uf-fields-close": c.fieldPicker?.debugClose(); return "ok"
        case "uf-settings":
            c.settings.show()
            // show() sizes the window; the columns only settle once the content has laid out, so measure after that.
            c.settings.window.contentView?.layoutSubtreeIfNeeded()
            let f = c.settings.window.frame
            return "\(Int(f.width)) \(Int(f.height)) \(c.settings.debugColumns) scrolls=\(c.settings.debugScrolls) hidden=\(Int(c.settings.debugOverflow)) screen=\(Int(c.settings.debugScreenHeight))"
        case "uf-click-row":   // uf-click-row <path>: one click in the middle of that row, converted through the frame view like uf-click
            let o = c.files.outline
            guard let n = c.files.node(path: arg), case let row = o.row(forItem: n), row >= 0 else { return "error: not visible" }
            let r = o.rect(ofRow: row), pt = o.convert(NSPoint(x: r.minX + 80, y: r.midY), to: c.frameView)
            click(winPoint(pt.x, pt.y), clicks: 1, send: true)
            return "ok"
        case "uf-tree-state":   // sidebar section open?, rows, expanded folders, the file open in the viewer
            return "section=\(c.sidebar?.expanded == true ? "open" : "closed") rows=\(c.files.outline.numberOfRows) expanded=[\(c.files.debugExpanded.map { ($0 as NSString).lastPathComponent }.joined(separator: ","))] viewer=\(c.viewer.url?.lastPathComponent ?? "-")"
        case "uf-mark-opened":
            guard w.count >= 2, let id = UInt64(w[0]), let s = c.store.sessions.first(where: { $0.id == id }) else { return "error: no session" }
            c.store.markOpened(s, by: w.dropFirst().joined(separator: " ")); return "ok"
        default: return nil
        }
    }
}
#endif
