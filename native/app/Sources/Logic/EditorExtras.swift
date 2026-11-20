// Pure helpers for the editor's code folding, bracket matching and multi-cursor (Foundation only; unit-tested).

import Foundation

// MARK: Folding (Monaco's default: indentation based)

public enum Folding {
    /// Columns of leading whitespace of the line starting at `start` (tab = 4); nil for a blank line.
    static func indent(_ ns: NSString, lineStart start: Int, end: Int) -> Int? {
        var col = 0, i = start
        while i < end {
            let c = ns.character(at: i)
            if c == 0x20 { col += 1 } else if c == 0x09 { col += 4 } else if c == 0x0A || c == 0x0D { return nil } else { return col }
            i += 1
        }
        return nil
    }

    /// End of the line (before its "\n") that starts at `start`.
    static func lineEnd(_ ns: NSString, _ start: Int) -> Int {
        let r = ns.range(of: "\n", options: .literal, range: NSRange(location: start, length: ns.length - start))
        return r.location == NSNotFound ? ns.length : r.location
    }

    /// Cheap "does this line have a chevron": the next non-blank line (within 200 lines) is indented deeper. O(1) for the gutter.
    public static func isFoldable(headerLineStart start: Int, in ns: NSString) -> Bool {
        let n = ns.length
        guard start < n else { return false }
        let hEnd = lineEnd(ns, start)
        guard let base = indent(ns, lineStart: start, end: hEnd), hEnd < n else { return false }
        var pos = hEnd + 1, looked = 0
        while pos < n, looked < 200 {
            let e = lineEnd(ns, pos)
            if let ind = indent(ns, lineStart: pos, end: e) { return ind > base }
            pos = e + 1; looked += 1
        }
        return false
    }

    /// The hidden range when the line starting at `headerLineStart` is folded: from the end of that line to the end of the last
    /// line of its more-indented block (the line that closes the block, with the header's indent, stays visible). nil = not foldable.
    /// `limit` bounds the scan (UTF-16 units) so a click on a top-level `[` of a huge file cannot hang.
    public static func range(headerLineStart start: Int, in ns: NSString, limit: Int = 64 << 20) -> NSRange? {
        let n = ns.length
        guard start < n else { return nil }
        let hEnd = lineEnd(ns, start)
        guard let base = indent(ns, lineStart: start, end: hEnd), hEnd < n else { return nil }
        var pos = hEnd + 1, lastEnd = -1
        let stop = min(n, start + limit)
        while pos <= n, pos < stop {
            let e = lineEnd(ns, pos)
            if let ind = indent(ns, lineStart: pos, end: e) {
                if ind <= base { break }
                lastEnd = e
            }
            pos = e + 1
        }
        guard lastEnd > hEnd else { return nil }
        return NSRange(location: hEnd, length: lastEnd - hEnd)
    }
}

// MARK: Bracket matching

public enum BracketMatch {
    /// The bracket next to `caret` (before it, else after it) and its partner: the offsets of both. Plain counting (strings and
    /// comments are not skipped), bounded by `limit` characters each way.
    public static func pair(at caret: Int, in ns: NSString, limit: Int = 200_000) -> (Int, Int)? {
        func partner(_ c: unichar) -> (unichar, Bool)? {
            switch c {
            case 0x28: return (0x29, true)
            case 0x5B: return (0x5D, true)
            case 0x7B: return (0x7D, true)
            case 0x29: return (0x28, false)
            case 0x5D: return (0x5B, false)
            case 0x7D: return (0x7B, false)
            default: return nil
            }
        }
        for pos in [caret - 1, caret] where pos >= 0 && pos < ns.length {
            let c = ns.character(at: pos)
            guard let (other, forward) = partner(c) else { continue }
            var depth = 0, i = pos
            let stop = forward ? min(ns.length - 1, pos + limit) : max(0, pos - limit)
            while forward ? i <= stop : i >= stop {
                let d = ns.character(at: i)
                if d == c { depth += 1 } else if d == other { depth -= 1; if depth == 0 { return (pos, i) } }
                i += forward ? 1 : -1
            }
        }
        return nil
    }
}

// MARK: Multi-cursor helpers

public enum MultiCursor {
    /// ⌘D: the next occurrence of the selected text (or of the word at an empty caret) after the last range, wrapping once.
    /// An empty caret first selects its word (`selectWord`); then each call returns the range to add.
    public static func nextOccurrence(ranges: [NSRange], in ns: NSString) -> (add: NSRange?, selectWord: NSRange?) {
        guard let last = ranges.last else { return (nil, nil) }
        if last.length == 0 {
            let w = wordRange(at: last.location, in: ns)
            return (nil, w.length > 0 ? w : nil)
        }
        let needle = ns.substring(with: last)
        var from = NSMaxRange(last)
        for pass in 0 ..< 2 {
            let r = ns.range(of: needle, options: .literal, range: NSRange(location: from, length: ns.length - from))
            if r.location != NSNotFound, !ranges.contains(where: { NSIntersectionRange($0, r).length > 0 || $0 == r }) { return (r, nil) }
            if pass == 0 { from = 0 }
        }
        return (nil, nil)
    }

    public static func wordRange(at loc: Int, in ns: NSString) -> NSRange {
        func isWord(_ c: unichar) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F }
        var s = loc, e = loc
        while s > 0, isWord(ns.character(at: s - 1)) { s -= 1 }
        while e < ns.length, isWord(ns.character(at: e)) { e += 1 }
        return NSRange(location: s, length: e - s)
    }
}
