// Pure UI logic with no AppKit / libghostty dependency, so the unit tests can cover it:
// pixel -> cell math, grid-view tiling, IME preedit layout, wheel accumulation, mouse routing and
// latency percentiles.

import Foundation

// MARK: Cell math

struct CellMetrics: Equatable {
    /// Cell size and outer padding, all in points.
    var cellW: Double, cellH: Double, padding: Double

    /// The cell under a point (view coordinates, y down), clamped into the grid.
    func cell(atX x: Double, y: Double, cols: Int, rows: Int) -> (col: Int, row: Int) {
        let c = Int(((x - padding) / cellW).rounded(.down)), r = Int(((y - padding) / cellH).rounded(.down))
        return (min(max(c, 0), max(cols - 1, 0)), min(max(r, 0), max(rows - 1, 0)))
    }

    func origin(col: Int, row: Int) -> (x: Double, y: Double) { (padding + Double(col) * cellW, padding + Double(row) * cellH) }
}

// MARK: Grid view tiling

enum GridLayout {
    /// Columns x rows used for `count` sessions (max 6): 1 -> 1x1, 2 -> 2x1, 3-4 -> 2x2, 5-6 -> 3x2.
    static func shape(count: Int) -> (cols: Int, rows: Int) {
        switch min(max(count, 0), 6) {
        case 0, 1: return (1, 1)
        case 2: return (2, 1)
        case 3, 4: return (2, 2)
        default: return (3, 2)
        }
    }

    /// Tile rectangles (origin top-left, y down) filling `width` x `height` with `gap` between tiles.
    static func tiles(count: Int, width: Double, height: Double, gap: Double) -> [(x: Double, y: Double, w: Double, h: Double)] {
        let n = min(count, 6)
        guard n > 0 else { return [] }
        let s = shape(count: n)
        let tw = (width - gap * Double(s.cols - 1)) / Double(s.cols), th = (height - gap * Double(s.rows - 1)) / Double(s.rows)
        return (0 ..< n).map { i in (Double(i % s.cols) * (tw + gap), Double(i / s.cols) * (th + gap), tw, th) }
    }

    /// Which sessions the grid shows: the selected one is always included, the rest in list order.
    static func visible(ids: [UInt64], selected: UInt64?, limit: Int = 6) -> [UInt64] {
        var out = Array(ids.prefix(limit))
        if let s = selected, ids.contains(s), !out.contains(s) { out[limit - 1] = s }
        return out
    }
}

// MARK: Mouse routing

enum MouseRoute: Equatable {
    case report, select

    /// While the program in the PTY tracks the mouse, clicks go to it; Shift keeps selection local.
    static func decide(programTracksMouse: Bool, shift: Bool) -> MouseRoute { programTracksMouse && !shift ? .report : .select }
}

/// Turns wheel / trackpad deltas into whole lines, keeping the fraction for the next event.
struct ScrollAccumulator {
    private(set) var remainder = 0.0

    /// `delta` in lines (precise devices: pixels / cell height). Positive = content moves down (scroll up).
    mutating func lines(delta: Double) -> Int {
        remainder += delta
        let whole = Int(remainder.rounded(.towardZero))
        remainder -= Double(whole)
        return whole
    }

    mutating func reset() { remainder = 0 }
}

// MARK: Preedit (IME marked text) layout

struct PreeditCell: Equatable {
    var col: Int, row: Int
    var text: String
    var wide: Bool
}

enum Preedit {
    /// Terminal cell width of one Unicode scalar: 0 for combining marks, 2 for East Asian wide / emoji.
    static func width(of u: Unicode.Scalar) -> Int {
        switch u.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        let v = u.value
        if v < 0x1100 { return 1 }
        let wide: [ClosedRange<UInt32>] = [
            0x1100 ... 0x115F, 0x2E80 ... 0x303E, 0x3041 ... 0x33FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xA000 ... 0xA4CF,
            0xAC00 ... 0xD7A3, 0xF900 ... 0xFAFF, 0xFE30 ... 0xFE6F, 0xFF00 ... 0xFF60, 0xFFE0 ... 0xFFE6,
            0x1F300 ... 0x1F64F, 0x1F900 ... 0x1F9FF, 0x20000 ... 0x3FFFD,
        ]
        return wide.contains { $0.contains(v) } ? 2 : 1
    }

    /// Cells the preedit occupies when its first character sits at (`col`,`row`) in a `cols` x `rows`
    /// grid. A wide character that does not fit at the right edge moves to the next row; text past
    /// the last row is dropped. Combining marks join the previous cell.
    static func layout(_ text: String, col: Int, row: Int, cols: Int, rows: Int) -> [PreeditCell] {
        guard cols > 0, rows > 0 else { return [] }
        var out: [PreeditCell] = []
        var c = col, r = row
        for ch in text {
            let w = ch.unicodeScalars.map(width(of:)).max() ?? 1
            if w == 0 { if !out.isEmpty { out[out.count - 1].text.append(ch) }; continue }
            if c + w > cols { c = 0; r += 1 }
            if r >= rows { break }
            out.append(PreeditCell(col: c, row: r, text: String(ch), wide: w == 2))
            c += w
        }
        return out
    }

    /// Where the cursor sits after the preedit (caret for the candidate window): the first free cell.
    static func caret(after cells: [PreeditCell], start: (col: Int, row: Int), cols: Int) -> (col: Int, row: Int) {
        guard let last = cells.last else { return start }
        let c = last.col + (last.wide ? 2 : 1)
        return c >= cols ? (0, last.row + 1) : (c, last.row)
    }
}

// MARK: Statistics

enum Stats {
    /// Nearest-rank percentile (p in 0...1) of unsorted samples.
    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count) * p).rounded(.up)) - 1))]
    }
}
