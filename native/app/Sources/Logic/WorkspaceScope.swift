// Which workspace a session belongs to, so the lists can show one workspace at a time (src/lib/workspaceScope.ts, docs/prd-workspace-scope-native.md).
// Membership is derived from where the session was opened, never stored. Pure: no AppKit.

import Foundation

public enum WorkspaceScope {
    /// `path` is `root` or sits under it.
    public static func within(_ path: String, _ root: String) -> Bool {
        let r = trimmed(root)
        return path == r || path.hasPrefix(r + "/")
    }

    /// Muya puts a repo's worktrees next to it: `<parent>/<repo>-worktrees/<branch>`.
    public static func worktreeDir(_ root: String) -> String? {
        let r = trimmed(root)
        guard let i = r.lastIndex(of: "/"), i != r.startIndex else { return nil }
        return String(r[..<i]) + "/" + String(r[r.index(after: i)...]) + "-worktrees"
    }

    /// Is a session opened in `cwd` part of workspace `root`?
    public static func belongsTo(cwd: String, root: String) -> Bool {
        if cwd.isEmpty { return false }
        if within(cwd, root) { return true }
        return worktreeDir(root).map { within(cwd, $0) } ?? false
    }

    /// Listed while `scope` is chosen (nil = all workspaces)? An SSH session has no local folder, so it shows everywhere.
    public static func inScope(cwd: String, ssh: Bool = false, scope: String?) -> Bool {
        guard let scope else { return true }
        return ssh || belongsTo(cwd: cwd, root: scope)
    }

    /// The most specific (longest) root a session belongs to.
    public static func workspaceOf(cwd: String, roots: [String]) -> String? {
        var best: String?
        for r in roots where belongsTo(cwd: cwd, root: r) { if best == nil || r.count > best!.count { best = r } }
        return best
    }

    /// The header chip text after "Workspace": the chosen folder's name, "All workspaces", or "No workspace" with no sessions.
    public static func chipLabel(scope: String?, hasSessions: Bool) -> String {
        guard let scope else { return hasSessions ? "All workspaces" : "No workspace" }
        let n = (trimmed(scope) as NSString).lastPathComponent
        return n.isEmpty ? scope : n
    }

    /// The row a chosen shortcut digit picks: 1-9 = the Nth row as listed, nil digit (⌥⌘0) = all. `.none` = no such row.
    public enum Pick: Equatable, Sendable { case all, root(String), none }
    public static func pick(digit: Int?, rows: [String]) -> Pick {
        guard let n = digit else { return rows.isEmpty ? .none : .all }
        return n >= 1 && n <= rows.count && n <= 9 ? .root(rows[n - 1]) : .none
    }

    private static func trimmed(_ root: String) -> String {
        var r = root
        while r.count > 1, r.hasSuffix("/") { r.removeLast() }
        return r == "/" ? "" : r   // root "/" : every absolute path is under it (path.hasPrefix("" + "/"))
    }
}
