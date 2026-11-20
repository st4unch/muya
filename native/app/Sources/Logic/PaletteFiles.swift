// The palette's "Files" group, exactly like today's paletteFileMap (src/App.tsx): the files open in the viewer, then the
// selected agent's changed files (git status of its folder). Nothing is scanned from disk, so nothing outside what the user
// already opened or changed is ever touched (no ~/Library, no folder walk).
import Foundation

enum PaletteFiles {
    /// `open`: absolute paths of the open files. `changes`: repo-relative paths with a "deleted" flag. Today's rule: a map keyed by
    /// the label (open files by their ~-abbreviated path, changes by their repo-relative path), a later entry replaces an earlier
    /// one with the same label, directories (trailing "/") are skipped; deleted files cannot be opened and are skipped too.
    static func items(open: [String], changes: [(path: String, deleted: Bool)], root: String?, home: String) -> [PaletteItem] {
        var order: [String] = [], byLabel: [String: String] = [:]
        func put(_ label: String, _ abs: String) { if byLabel[label] == nil { order.append(label) }; byLabel[label] = abs }
        for p in open { put(abbreviate(p, home: home), p) }
        if let root, !root.isEmpty {
            for c in changes where !c.path.hasSuffix("/") && !c.deleted { put(c.path, root + "/" + c.path) }
        }
        return order.map { PaletteItem(id: "file:" + byLabel[$0]!, group: "Files", title: $0) }
    }

    private static func abbreviate(_ p: String, home: String) -> String {
        if p == home { return "~" }
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }
}
