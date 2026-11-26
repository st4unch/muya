// Terminal path links (classic's Terminal.tsx path-link provider, ported): which token of a terminal row is a
// filesystem path, where it resolves, and what its menu offers. Pure and testable; the view (TerminalView) does the hover.

import Foundation

enum TerminalPathLinks {
    /// A path-looking token of one terminal row. Columns are 0-based cell columns, `endCol` inclusive.
    struct Token: Equatable {
        var text: String
        var startCol: Int
        var endCol: Int
    }

    enum Kind: String { case file, dir, none }

    /// Classic's PATH_RE (Terminal.tsx), character for character; `\w` is spelled ASCII like JavaScript's.
    private static let pattern = try! NSRegularExpression(pattern: #"(?:~/|\.{0,2}/)[^\s"'<>|()]+|[A-Za-z0-9_.\-]+/[^\s"'<>|()]+"#)
    /// Classic's trailing-punctuation trim: /[.,:;)\]]+$/
    private static let trailing: Set<Character> = [".", ",", ":", ";", ")", "]"]

    /// The token under `column` of a row given as one string per cell (a wide character's second cell is "", a blank cell is " ").
    static func token(cells: [String], column: Int) -> Token? {
        guard column >= 0, column < cells.count else { return nil }
        var text = "", starts: [Int] = []   // starts[i] = UTF-16 offset of cell i in `text`
        for c in cells { starts.append(text.utf16.count); text += c }
        let ns = text as NSString
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range)
            while let last = s.last, trailing.contains(last) { s.removeLast() }
            guard !s.isEmpty else { continue }
            let from = m.range.location, to = from + (s as NSString).length   // [from, to)
            // First cell whose text starts inside the token, and the last one.
            guard let a = starts.firstIndex(where: { $0 >= from && $0 < to }), let b = starts.lastIndex(where: { $0 >= from && $0 < to }) else { continue }
            var end = b
            while end + 1 < cells.count, cells[end + 1].isEmpty { end += 1 }   // a wide character's spacer belongs to it
            if column >= a, column <= end { return Token(text: s, startCol: a, endCol: end) }
        }
        return nil
    }

    /// The same for a plain string where one Character is one cell.
    static func token(row: String, column: Int) -> Token? { token(cells: row.map { String($0) }, column: column) }

    /// Classic's resolve_path_kind: `~/` against `home`, a relative token joined onto `cwd` (the session's current directory).
    static func resolve(_ token: String, cwd: String, home: String) -> String {
        let raw = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = raw.hasPrefix("~/") ? home + "/" + raw.dropFirst(2) : raw
        if expanded.hasPrefix("/") || cwd.isEmpty { return expanded }
        return cwd + (cwd.hasSuffix("/") ? "" : "/") + expanded
    }

    /// stat: dir wins over file like classic; anything else (missing, broken symlink, denied) is none.
    static func kind(ofPath path: String) -> Kind {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return .none }
        return isDir.boolValue ? .dir : .file
    }

    /// The menu's items in order, after the header: classic's App.tsx path menu.
    static func menuTitles(for kind: Kind) -> [String] {
        switch kind {
        case .file: return ["Open in Muya", "Reveal in Finder", "Copy Path"]
        case .dir: return ["Open Terminal Here", "Reveal in Finder", "Copy Path"]
        case .none: return []
        }
    }

    /// The menu's header: 📁 / 📄 and the basename.
    static func header(path: String, kind: Kind) -> String {
        (kind == .dir ? "📁 " : "📄 ") + (path as NSString).lastPathComponent
    }

    /// A small cache of (cwd, token) -> resolved path and kind; bounded like classic's (2000).
    struct Cache {
        private var items: [String: (path: String, kind: Kind)] = [:]
        static let limit = 2000
        subscript(cwd: String, token: String) -> (path: String, kind: Kind)? {
            get { items[cwd + "\0" + token] }
            set {
                if items.count >= Self.limit { items.removeAll() }
                items[cwd + "\0" + token] = newValue
            }
        }
    }
}
