// Custom glyphs (Sources/App/CustomGlyphs.swift) through the SAME bitmap path as the glyph atlas (Renderer.swift Atlas.rasterize):
// a CGContext with data == nil, premultipliedLast; the atlas uploads `ctx.data` as it is, so memory row 0 is the TOP row of the cell.
// The shapes are checked by which half of the cell has ink (checked in the real app too: screenshot with each glyph on its own).

import CoreGraphics

private func inkRows(_ cp: UInt32, w: Int = 20, h: Int = 40) -> [Int] {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    CustomGlyphs.draw(cp, in: ctx, w: w, h: h, scale: 2)
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return (0 ..< h).map { r in (0 ..< w).reduce(0) { $0 + (p[(r * w + $1) * 4 + 3] > 128 ? 1 : 0) } }   // inked pixels per memory row
}

func runGlyphTests() {
    test("custom glyphs: ▀ fills the top half, ▄ the bottom half, █ everything, ▌ the left half") {
        let up = inkRows(0x2580), low = inkRows(0x2584), full = inkRows(0x2588)
        check(up[..<20].allSatisfy { $0 == 20 } && up[20...].allSatisfy { $0 == 0 }, "▀ top half: \(up)")
        check(low[..<20].allSatisfy { $0 == 0 } && low[20...].allSatisfy { $0 == 20 }, "▄ bottom half: \(low)")
        check(full.allSatisfy { $0 == 20 }, "█ full")
        let left = inkRows(0x258C)
        check(left.allSatisfy { $0 == 10 }, "▌ left half: \(left)")
    }
    test("custom glyphs: corners and tees have their arms on the right side of the cell (up arm = top rows)") {
        func upper(_ cp: UInt32) -> Int { inkRows(cp)[..<17].reduce(0, +) }      // ink well above the middle line
        func lower(_ cp: UInt32) -> Int { inkRows(cp)[23...].reduce(0, +) }      // ink well below it
        check(upper(0x2514) > 20 && lower(0x2514) == 0, "└ (up + right): ink only above the middle: up \(upper(0x2514)) down \(lower(0x2514))")
        check(upper(0x2518) > 20 && lower(0x2518) == 0, "┘ (up + left)")
        check(lower(0x250C) > 20 && upper(0x250C) == 0, "┌ (down + right): ink only below the middle: up \(upper(0x250C)) down \(lower(0x250C))")
        check(lower(0x2510) > 20 && upper(0x2510) == 0, "┐ (down + left)")
        check(upper(0x2534) > 20 && lower(0x2534) == 0, "┴ (up, left, right)")
        check(lower(0x252C) > 20 && upper(0x252C) == 0, "┬ (down, left, right)")
        check(upper(0x2570) > 10 && lower(0x2570) == 0, "╰ (rounded, up + right)")
        check(lower(0x256D) > 10 && upper(0x256D) == 0, "╭ (rounded, down + right)")
        check(upper(0x2575) > 20 && lower(0x2575) == 0 && lower(0x2577) > 20 && upper(0x2577) == 0, "╵ up / ╷ down")
    }
}
