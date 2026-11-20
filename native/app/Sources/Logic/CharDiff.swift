// Character-level diff of one changed line pair (what Monaco's diff editor highlights inside a modified line): the ranges of
// characters that differ, from a longest-common-subsequence of the two lines. Long lines fall back to the common prefix / suffix.

import Foundation

enum CharDiff {
    /// Changed character ranges (in `Character` offsets) of the old and the new line.
    static func spans(old: String, new: String, lcsLimit: Int = 400) -> (old: [Range<Int>], new: [Range<Int>]) {
        let a = Array(old), b = Array(new)
        if a == b { return ([], []) }
        if a.count > lcsLimit || b.count > lcsLimit { return prefixSuffix(a, b) }
        // LCS table (lengths of the common suffixes), then walk it.
        let n = a.count, m = b.count
        var t = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
                }
            }
        }
        var ca = [Bool](repeating: true, count: n), cb = [Bool](repeating: true, count: m)   // true = changed
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { ca[i] = false; cb[j] = false; i += 1; j += 1 }
            else if t[i + 1][j] >= t[i][j + 1] { i += 1 } else { j += 1 }
        }
        return (merge(ranges(ca)), merge(ranges(cb)))
    }

    /// Changes separated by one or two unchanged characters read as one change (Monaco post-processes its character changes the same way).
    private static func merge(_ r: [Range<Int>], gap: Int = 2) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for x in r {
            if let last = out.last, x.lowerBound - last.upperBound <= gap { out[out.count - 1] = last.lowerBound ..< x.upperBound } else { out.append(x) }
        }
        return out
    }

    private static func prefixSuffix(_ a: [Character], _ b: [Character]) -> (old: [Range<Int>], new: [Range<Int>]) {
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        func r(_ x: [Character]) -> [Range<Int>] { p < x.count - s ? [p ..< x.count - s] : [] }
        return (r(a), r(b))
    }

    private static func ranges(_ changed: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = [], start: Int?
        for (i, c) in changed.enumerated() {
            if c, start == nil { start = i }
            if !c, let s = start { out.append(s ..< i); start = nil }
        }
        if let s = start { out.append(s ..< changed.count) }
        return out
    }
}
