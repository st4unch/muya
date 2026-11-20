#if MUYA_TEST_HOOKS
// Test-hook commands of the Resources page and the slash popover (P7); they exist only while
// MUYA_DEBUG_SOCKET is set. Like the keyboard, `slash-key` goes through the popover's own handlers.

import AppKit

extension DebugServer {
    func runP7(_ cmd: String, _ arg: String) -> String? {
        MainActor.assumeIsolated { runP7Main(cmd, arg) }
    }

    @MainActor
    private func runP7Main(_ cmd: String, _ arg: String) -> String? {
        let c = controller
        let p = c.resourcesPage
        switch cmd {
        case "resources-open":
            // resources-open [skills|agents|hooks|mcps|marketplace]
            c.showPage(p)
            if let t = ResourceTab.allCases.first(where: { $0.title.lowercased() == arg.lowercased() }) { p.select(tab: t) }
            return "ok"
        case "resources-query": p.setQuery(arg); return "ok"
        case "resources-market": p.select(tab: .marketplace); return "ok"
        case "resources-kind":
            // resources-kind skills|mcps (marketplace section)
            p.select(tab: .marketplace); p.setKind(arg == "mcps" ? 1 : 0); return "ok"
        case "resources-select":
            // resources-select <index> of the visible rows, in order
            guard let i = Int(arg), let k = p.visibleKeys[safe: i] else { return "error: no such row" }
            p.select(key: k); return "ok"
        case "resources-create":
            // resources-create <Skill|Agent|Hook|MCP>|<request>: the sheet's Create button
            let parts = arg.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return "error: kind|request" }
            p.createWith(kind: parts[0], request: parts[1]); return "ok"
        case "resources-install-plugin": p.installPlugin(); return "ok"
        case "resources-state":
            let f = ResourcesLogic.filtered(p.resources, tab: p.tab, query: p.query)
            return "tab=\(p.tab.title) loading=\(p.loading) error=\(p.error ?? "-") skills=\(f.skills.count) agents=\(f.agents.count) hooks=\(f.hooks.count) mcps=\(f.mcps.count) market=\(p.marketSkills.count)/\(p.marketMcps.count) marketLoading=\(p.marketLoading) marketError=\(p.marketError ?? "-") selected=\(p.selectedKey ?? "-") file=\(p.fileText?.prefix(40).replacingOccurrences(of: "\n", with: "⏎") ?? "-") plugin=\(p.pluginInstalling ? "installing" : p.pluginResult.map { ($0.ok ? "ok:" : "fail:") + $0.message } ?? "-")"
        case "slash-open": if !c.slashPopover.isOpen { c.toggleSlash() }; return "ok"
        case "slash-type": c.slashPopover.type(arg); return "ok"
        case "slash-key":
            // slash-key down|up|enter|esc
            let s = c.slashPopover
            switch arg { case "down": s.move(1); case "up": s.move(-1); case "enter": s.pickSelected(); case "esc": s.close(); default: return "error: unknown key" }
            return "ok"
        case "slash-state":
            let s = c.slashPopover
            return "open=\(s.isOpen) shown=\(s.shown.count) index=\(s.index) selected=\(s.selectedName ?? "-") groups=\(Set(s.shown.map(\.source.rawValue)).sorted().joined(separator: ","))"
        default: return nil
        }
    }
}

private extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
#endif
