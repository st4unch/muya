#if MUYA_TEST_HOOKS
// Test-hook commands of the workspace scope (docs/prd-workspace-scope-native.md); only while MUYA_DEBUG_SOCKET is set.
//   ws-rows              the Workspace menu as it would show: titles joined by "|", "✓ " = ticked, "-" = separator, with the ⌥⌘ hints
//   ws-select <n|all>    choose the Nth row (1-based) or All workspaces, through the same call as ⌥⌘n / ⌥⌘0
//   ws-choose <path>     choose a folder by path (what clicking its row does)
//   ws-list              the agents list: ids of the sessions it shows, comma separated
//   ws-palette           the Terminals group of the command palette: ids, comma separated
//   ws-state             scope=<path|all> selected=<id> persisted=<value|none> chip=<label>

import AppKit

extension DebugServer {
    func runWorkspaceScope(_ cmd: String, _ arg: String) -> String? {
        guard cmd.hasPrefix("ws-") else { return nil }
        let c = controller
        switch cmd {
        case "ws-rows":
            var parts = c.workspaceMenuModel().map { ($0.on ? "✓ " : "") + $0.title + ($0.hint.isEmpty ? "" : "    " + $0.hint) }
            parts.insert("WORKSPACES", at: 0)
            parts += ["-", "Add workspace…"]
            return parts.joined(separator: "|")
        case "ws-select":
            let a = arg.trimmingCharacters(in: .whitespaces)
            if a == "all" { return c.chooseWorkspace(digit: nil) ? "ok" : "error: no workspace" }
            guard let n = Int(a), n >= 1, n <= 9 else { return "error: ws-select <1-9|all>" }
            return c.chooseWorkspace(digit: n) ? "ok" : "error: no such row"
        case "ws-choose":
            c.chooseWorkspace(arg.isEmpty ? nil : arg); return "ok"
        case "ws-list":
            c.agentsPanel.reloadNow()
            return c.agentsPanel.onScreenSessions.map { String($0.id) }.joined(separator: ",")
        case "ws-palette":
            return c.paletteItems().filter { $0.id.hasPrefix("term:") }.map { String($0.id.dropFirst(5)) }.joined(separator: ",")
        case "ws-state":
            let s = c.store
            return "scope=\(s.selectedRoot ?? "all") selected=\(s.selected.map { String($0.id) } ?? "-") persisted=\(s.legacy.get(PrefKeys.selectedRoot) ?? "none") chip=\(c.frameView.header.workspace)"
        default: return nil
        }
    }
}
#endif
