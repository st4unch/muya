#if MUYA_TEST_HOOKS
// Test-hook commands of the Queue page (Queue / Branches / Kanban). Like all debug commands they exist only
// while MUYA_DEBUG_SOCKET is set. Reads are asynchronous: start `queue-reload`, poll `queue-state`.

import AppKit

extension DebugServer {
    func runQueue(_ cmd: String, _ arg: String) -> String? {
        let c = controller
        let q = c.queuePage
        let w = arg.split(separator: " ").map(String.init)
        switch cmd {
        case "queue-page":
            guard let t = QueueTab.allCases.first(where: { $0.name == arg }) else { return "error: queue-page <queue|branches|kanban>" }
            if c.currentPage !== q { c.showPage(q) }
            q.select(tab: t)
            return t.name
        case "queue-cwd": q.cwdProvider = { arg.isEmpty ? nil : arg }; return "ok"
        case "queue-paths": let ps = arg.split(separator: ":").map(String.init); q.pathsProvider = { ps }; return "ok"
        case "queue-add": q.addToQueue(arg); return "queued=\(q.queuedPaths.count)"
        case "queue-remove": q.removeFromQueue(arg); return "queued=\(q.queuedPaths.count)"
        case "queue-reload": q.reload(); return "ok"
        case "queue-state": return q.debugState()
        case "queue-autoconfirm": q.autoConfirm = arg == "on"; return "ok"
        case "queue-select": return q.select(branch: arg) ? "ok" : "error: not listed"
        case "queue-push": q.pushTapped(); return "ok"
        case "queue-merge": q.mergeTapped(); return "ok"
        case "queue-delete": q.deleteTapped(); return "ok"
        case "queue-sheet": return q.pendingSheetText ?? "none"
        case "queue-sheet-confirm": q.dismissSheet(confirm: true); return "ok"
        case "queue-sheet-cancel": q.dismissSheet(confirm: false); return "ok"
        case "queue-log": return q.actionLog.lines.joined(separator: "\n")
        case "dag-select": q.dag.select(Int(arg) ?? 0); return "selected=\(q.dag.selected)"
        case "dag-key":
            let codes = ["down": 125, "up": 126, "pagedown": 121, "pageup": 116, "home": 115, "end": 119]
            guard let k = codes[arg], let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: c.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(k)) else { return "error: dag-key <down|up|pagedown|pageup|home|end>" }
            q.dag.keyDown(with: e)
            return "selected=\(q.dag.selected)"
        case "dag-bench":
            let drawn0 = q.dag.rowsDrawn
            let t = q.dag.benchmark().sorted()
            if q.dag.rowsDrawn == drawn0 { return "error: nothing was painted (page not visible?)" }
            guard !t.isEmpty else { return "error: no commits loaded" }
            let mean = t.reduce(0, +) / Double(t.count)
            return String(format: "frames=%d mean_ms=%.2f p95_ms=%.2f max_ms=%.2f rows_drawn=%d", t.count, mean, t[min(t.count - 1, Int(Double(t.count) * 0.95))], t.last!, q.dag.rowsDrawn)
        case "kanban-select":
            guard q.board.cards.contains(where: { $0.slug == arg }) else { return "error: not listed" }
            q.kanban.set(board: q.board, cwd: q.cwd, keepSelection: arg); return "ok"
        case "kanban-move":
            guard w.count == 2, let col = KanbanColumn(rawValue: w[1]) else { return "error: kanban-move <slug> <draft|active|review|done>" }
            q.moveCard(w[0], to: col); return "ok"
        case "kanban-key":
            let codes = ["left": 123, "right": 124, "down": 125, "up": 126]
            guard w.count >= 1, let k = codes[w[0]], let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: w.count > 1 ? [.option] : [], timestamp: 0, windowNumber: c.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(k)) else { return "error: kanban-key <left|right|up|down> [opt]" }
            q.kanban.keyDown(with: e)
            return "selected=\(q.kanban.selectedSlug ?? "-")"
        case "kanban-drag":
            // kanban-drag <slug> <column>: real mouse events through the view, like a user dragging.
            guard w.count == 2, let col = KanbanColumn(rawValue: w[1]), let from = q.kanban.cardFrame(w[0]) else { return "error: kanban-drag <slug> <column>" }
            let k = q.kanban
            let to = k.columnFrame(col)
            func ev(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: k.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let a = NSPoint(x: from.midX, y: from.midY), b = NSPoint(x: to.midX, y: to.midY)
            guard let d = ev(.leftMouseDown, a), let m = ev(.leftMouseDragged, b), let u = ev(.leftMouseUp, b) else { return "error: no event" }
            k.mouseDown(with: d); k.mouseDragged(with: m); k.mouseUp(with: u)
            return "ok"
        case "kanban-copy-dir": return (q.source as? LocalQueueSource)?.copyDir ?? "none"
        default: return nil
        }
    }
}
#endif
