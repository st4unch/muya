#if MUYA_TEST_HOOKS
// Test-hook commands of Split Control; only while MUYA_DEBUG_SOCKET is set.
//   split-state            groups, zoom, collapsed, selected, the panes shown (id:x,y,w,h) and the agent list's split rows
//   split-add              what ⌘⇧D does          split-group <from> <to>   drag a session onto another
//   split-close <id>       × on a pane            split-zoom <id>           a pane's focus / restore button
//   split-collapse <gid>   the group row chevron  split-divider <i> <dx>    drag column divider i by dx points
//   split-open [anchor=<id>] <json>   a `muya://open-agent-session` payload (agent open_session)
//   agent-close <json>     a `muya://close-agent-session` payload (agent close_session): ok when a tab left the store

import AppKit

extension DebugServer {
    func runSplit(_ cmd: String, _ arg: String) -> String? {
        let c = controller
        func session(_ s: Substring) -> SessionModel? { UInt64(s).flatMap { id in c.store.sessions.first { $0.id == id } } }
        let parts = arg.split(separator: " ", maxSplits: 1)
        switch cmd {
        case "split-state":
            let m = c.splitModel
            let groups = m.groups.map { "\($0.id)=\($0.keys.joined(separator: ","))" }.joined(separator: ";")
            let ch = c.tileView.splitChrome!
            c.tileView.layoutSubtreeIfNeeded()
            let panes = ch.active ? c.tileView.tiles.prefix(ch.sessions.count).enumerated().map { i, t in "\(ch.sessions[i].id):\(Int(t.frame.minX)),\(Int(t.frame.minY)),\(Int(t.frame.width)),\(Int(t.frame.height))" }.joined(separator: ";") : ""
            return "groups=[\(groups)] zoom=\(m.zoom.map(String.init) ?? "-") collapsed=\(m.collapsed.sorted().joined(separator: ",")) selected=\(c.store.selected.map { String($0.id) } ?? "-") active=\(ch.active) panes=[\(panes)] sessions=\(c.store.sessions.map { String($0.id) }.joined(separator: ",")) canSplit=\(c.canSplitSelected) splitEnabled=\(c.sessionBar.splitButton.isEnabled) fractions=\(ch.fractions.map { String(format: "%.2f", $0) }.joined(separator: ","))"
        case "grid-layout":   // grid-layout 1|1x2|2x2|3x2: the grid shape (measure-ac7.py keeps 6 tiles like the first AC7 run)
            guard let g = GridChoice(rawValue: arg) else { return "error: grid-layout 1|1x2|2x2|3x2" }
            GridState.layout = g; c.refreshTiles(); c.window.layoutIfNeeded(); return "ok tiles=\(c.tileView.shown)"
        case "open-url":   // open-url <url>: what LaunchServices does when a URL (muya://session/<id>) is handed to this app
            guard let u = URL(string: arg) else { return "error: bad url" }
            (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [u]); return "ok"
        case "agents-rebuilds": return "\(c.agentsPanel.rebuilds)"   // how often the agent cards were rebuilt (guard: a selection change adds 0)
        case "split-add": c.addSplitPane(); return "ok"
        case "split-group":
            guard parts.count == 2, let a = UInt64(parts[0]), let b = UInt64(parts[1]) else { return "error: split-group <from> <to>" }
            c.groupSessions(from: a, to: b); return "ok"
        case "split-close": guard let s = parts.first.flatMap(session) else { return "error: no session" }; c.closeSplitPane(s); return "ok"
        case "split-zoom": guard let s = parts.first.flatMap(session) else { return "error: no session" }; c.toggleSplitZoom(s); return "ok"
        case "split-ungroup": guard let id = parts.first.flatMap({ UInt64($0) }) else { return "error: split-ungroup <id>" }; c.agentsPanel.onUngroup?(id); return "ok"   // dropped on the list's empty space
        case "split-into":   // split-into <id> <group id>: dropped on a split's header row
            guard parts.count == 2, let a = UInt64(parts[0]) else { return "error: split-into <id> <gid>" }
            c.agentsPanel.onGroupInto?(a, String(parts[1])); return "ok"
        case "split-reorder":   // split-reorder <from> <to>: dropped on the top / bottom quarter of the row of <to>
            guard parts.count == 2, let a = UInt64(parts[0]), let b = UInt64(parts[1]) else { return "error: split-reorder <from> <to>" }
            c.agentsPanel.onReorder?(a, b); return "ok"
        case "drop-preview":   // drop-preview card <id> group|reorder|off · header <gid> on|off · empty on|off: the outlines a drag shows (AX / pixels cannot drag from here)
            let p = c.agentsPanel
            switch (parts.first.map(String.init) ?? "") {
            case "card":
                let a = (parts.count > 1 ? String(parts[1]) : "").split(separator: " ")
                guard a.count == 2, let id = UInt64(a[0]) else { return "error: drop-preview card <id> group|reorder|off" }
                for case let v as AgentCard in p.doc.subviews where v.session.id == id { v.debugDrop(a[1] == "group" ? .group : a[1] == "reorder" ? .reorder : nil) }
            case "header":
                let a = (parts.count > 1 ? String(parts[1]) : "").split(separator: " ")
                guard a.count == 2 else { return "error: drop-preview header <gid> on|off" }
                for case let v as SplitGroupRow in p.doc.subviews where v.groupID == String(a[0]) { v.debugDrop(a[1] == "on") }
            case "empty": p.doc.debugHover(parts.count > 1 && parts[1] == "on")
            default: return "error: drop-preview card|header|empty"
            }
            return "ok"
        case "agents-scroll": return c.agentsPanel.debugScroll(Double(arg).map { CGFloat($0) })
        case "agents-order":   // the sessions as listed on screen (what ⌘1–9 pick), ids
            c.agentsPanel.reloadNow(); return c.agentsPanel.onScreenSessions.map { String($0.id) }.joined(separator: ",")
        case "split-collapse": c.agentsPanel.onToggleGroup?(arg); return "ok"
        case "split-divider":
            guard parts.count == 2, let i = Int(parts[0]), let dx = Double(parts[1]) else { return "error: split-divider <i> <dx>" }
            c.tileView.splitChrome.simulateDrag(i, CGFloat(dx)); return "ok"
        case "split-open":
            // split-open [anchor=<session id>] <json>: with an anchor the caller's terminal is that session (the lookup through `claude agents` is skipped)
            var rest = Substring(arg), anchor: SessionModel?
            if arg.hasPrefix("anchor="), let sp = arg.firstIndex(of: " ") { anchor = session(arg[arg.index(arg.startIndex, offsetBy: 7) ..< sp]); rest = arg[arg.index(after: sp)...] }
            guard let req = OpenAgentSession(payload: String(rest)) else { return "error: bad payload" }
            c.openAgentSession(req, anchor: anchor); return "ok"
        case "agent-close":
            return c.closeAgentSession(payload: arg) ? "ok" : "error: no such tab"
        default: return nil
        }
    }
}
#endif
