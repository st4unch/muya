// Terminal find (⌘F) and the two text helpers of today's terminal menu (src/lib/termMenu.ts: escapeForShell, isWebUrl).
// Pure: the Replica hands over the buffer as lines (row 0 = oldest scrollback row), this finds the matches and walks them.

import Foundation

public struct FindMatch: Equatable, Sendable {
    public var row: Int      // absolute row, 0 = top of the scrollback
    public var col: Int      // first cell
    public var cells: Int    // width in cells (a wide character is two)
    public init(row: Int, col: Int, cells: Int) { self.row = row; self.col = col; self.cells = cells }
}

public enum TerminalFind {
    /// Cells a character takes: 0 for combining marks, 2 for East Asian wide and emoji, else 1.
    public static func cellWidth(_ ch: Character) -> Int {
        guard let u = ch.unicodeScalars.first else { return 1 }
        if ch.unicodeScalars.count == 1, u.properties.generalCategory == .nonspacingMark || u.properties.generalCategory == .enclosingMark { return 0 }
        let v = u.value
        if u.properties.isEmojiPresentation { return 2 }
        switch v {
        case 0x1100 ... 0x115F, 0x2E80 ... 0x303E, 0x3041 ... 0x33FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xA000 ... 0xA4CF, 0xAC00 ... 0xD7A3,
             0xF900 ... 0xFAFF, 0xFE30 ... 0xFE6F, 0xFF00 ... 0xFF60, 0xFFE0 ... 0xFFE6, 0x1F300 ... 0x1F64F, 0x1F900 ... 0x1F9FF, 0x20000 ... 0x3FFFD: return 2
        default: return 1
        }
    }

    /// Every case-insensitive occurrence of `query` (xterm's SearchAddon default: plain text, no regex), oldest first.
    /// Occurrences do not overlap. An empty query finds nothing.
    public static func matches(lines: [String], query: String) -> [FindMatch] {
        guard !query.isEmpty else { return [] }
        var out: [FindMatch] = []
        let q = Array(query.lowercased())
        for (row, line) in lines.enumerated() {
            let chars = Array(line)
            let lower = chars.map { Character(String($0).lowercased()) }
            guard lower.count >= q.count else { continue }
            var i = 0
            while i + q.count <= lower.count {
                if Array(lower[i ..< i + q.count]) == q {
                    let col = chars[..<i].reduce(0) { $0 + cellWidth($1) }
                    let cells = chars[i ..< i + q.count].reduce(0) { $0 + cellWidth($1) }
                    out.append(FindMatch(row: row, col: col, cells: max(cells, 1)))
                    i += q.count
                } else { i += 1 }
            }
        }
        return out
    }

    /// The match to show next. `current` is the index of the one shown now (nil: none yet); `anchor` is the first row of the
    /// viewport, where a fresh search starts looking (xterm's findNext starts at the selection or the top of the view).
    /// Wraps round at the ends.
    public static func step(count: Int, current: Int?, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let c = current else { return forward ? 0 : count - 1 }
        return forward ? (c + 1) % count : (c - 1 + count) % count
    }

    /// The first match at or after `row` (a search as you type keeps the match near where you are), else the first.
    public static func firstAtOrAfter(_ ms: [FindMatch], row: Int) -> Int? {
        ms.isEmpty ? nil : (ms.firstIndex { $0.row >= row } ?? 0)
    }

    // MARK: Menu helpers (src/lib/termMenu.ts)

    /// Backslashes spaces and shell characters so a pasted path is one word; one trailing newline is dropped so it is not run.
    public static func escapeForShell(_ text: String) -> String {
        var t = text
        if t.hasSuffix("\r\n") || t.hasSuffix("\n") { t.removeLast() }   // "\r\n" is one Character in Swift
        let special = Set(" !\"#$&'()*,;<=>?[\\]^`{|}~\t\n\r\u{0B}\u{0C}")
        var out = ""
        for ch in t {
            // Other control characters (ESC, DEL, ...) would be typed into the shell as keystrokes: dropped.
            if ch.unicodeScalars.count == 1, let u = ch.unicodeScalars.first, (u.value < 0x20 && !special.contains(ch)) || u.value == 0x7F { continue }
            if ch.unicodeScalars.count == 1, special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// The selection is exactly one http(s) URL (surrounding whitespace allowed).
    public static func isWebURL(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil, let u = URL(string: t) else { return false }
        return !(u.host ?? "").isEmpty
    }
}
