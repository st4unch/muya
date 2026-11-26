// Pure logic behind four small window/sidebar behaviours (kept out of the AppKit views so tests can reach it):
// the Workspace menu rows, the Files section height, the workspace root row's collapsed state, the title-bar double-click.

import Foundation

/// The header's "Workspace <name> ⌄" menu (src/App.tsx workspaces menu): one row per working folder of the sessions.
public enum WorkspaceMenuLogic {
    public struct Row: Equatable, Sendable {
        public var path: String, title: String, count: Int
        public init(path: String, title: String, count: Int) { self.path = path; self.title = title; self.count = count }
    }
    /// Folders in order of first appearance; the title is the folder name. `count` = the sessions in that root's scope
    /// (the folder itself, its subfolders, its `-worktrees` folder, every SSH session), i.e. the rows the list shows after choosing it.
    /// `keep` (the chosen root) stays listed after its last session closes.
    public static func rows(cwds: [String], ssh: [Bool] = [], keep: String? = nil) -> [Row] {
        var order: [String] = []
        for c in cwds where !c.isEmpty && !order.contains(c) { order.append(c) }
        if let k = keep, !k.isEmpty, !order.contains(k) { order.append(k) }
        return order.map { root in
            let n = cwds.indices.filter { WorkspaceScope.inScope(cwd: cwds[$0], ssh: ssh.indices.contains($0) && ssh[$0], scope: root) }.count
            let base = (root as NSString).lastPathComponent
            return Row(path: root, title: base.isEmpty ? root : base, count: n)
        }
    }
}

/// The height of the FILES section (classic usePanelLayout: muya.panels.filesHeight, 120...2000, nil = fill).
public enum FilesHeightLogic {
    public static let minHeight: CGFloat = 120
    public static let maxStored: CGFloat = 2000
    /// The stored value, or nil (= fill) when missing or not a number.
    public static func parse(_ raw: String?) -> CGFloat? {
        guard let raw, let d = Double(raw.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
        return CGFloat(min(max(d, Double(minHeight)), Double(maxStored)))
    }
    /// The section height for a requested height in a column with `available` points (the agents list keeps `minHeight` too).
    public static func clamp(_ wanted: CGFloat, available: CGFloat) -> CGFloat {
        max(minHeight, min(wanted, available - minHeight))
    }
}

/// Which workspace root rows the operator collapsed (a reload of the tree must not open them again).
public struct CollapsedRoots: Equatable, Sendable {
    public private(set) var paths: Set<String> = []
    public init() {}
    public func isExpanded(_ path: String) -> Bool { !paths.contains(path) }
    public mutating func set(_ path: String, expanded: Bool) { if expanded { paths.remove(path) } else { paths.insert(path) } }
    public mutating func toggle(_ path: String) { set(path, expanded: !isExpanded(path)) }
    /// Roots that went away are forgotten.
    public mutating func prune(keeping live: [String]) { paths.formIntersection(live) }
}

/// What a double-click on the title bar does: the system setting AppleActionOnDoubleClick ("Maximize" = zoom, "Minimize", "None").
public enum TitleBarAction: Equatable, Sendable {
    case zoom, minimize, none
    public static func from(defaultsValue: String?) -> TitleBarAction {
        switch defaultsValue?.lowercased() {
        case "minimize": return .minimize
        case "none": return .none
        default: return .zoom   // "Maximize", unset, anything unknown: the macOS default
        }
    }
}

/// Sessions an agent opened through open_session (MCP) look different from terminals the operator opened.
public enum SessionOrigin {
    public static func tooltip(openedBy: String?) -> String? { openedBy.map { "Opened by \($0)" } }
}
