// Box drawing (U+2500-257F), block elements (U+2580-259F) and powerline separators (U+E0B0-E0BF) drawn as geometry that
// fills the whole cell, like xterm.js "customGlyphs" in today's Muya: no gaps between rows, no seams between columns,
// no tofu where the font has no glyph. Draws white on transparent into the atlas bitmap (the shader tints it).

import CoreGraphics

enum CustomGlyphs {
    static func handles(_ cp: UInt32) -> Bool {
        (0x2500...0x259F).contains(cp) || (0xE0B0...0xE0BF).contains(cp)
    }

    /// Draws `cp` into `ctx` (a w x h bitmap, CG origin bottom-left). `scale` = device pixels per point (line thickness).
    static func draw(_ cp: UInt32, in ctx: CGContext, w: Int, h: Int, scale: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // top-left origin from here on
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let light = max(1, scale.rounded())
        switch cp {
        case 0x2500...0x257F: box(cp, ctx, w, h, light)
        case 0x2580...0x259F: block(cp, ctx, w, h)
        default: powerline(cp, ctx, w, h, light)
        }
        ctx.restoreGState()
    }

    // MARK: box drawing

    /// l, r, u, d arm styles: 0 none, 1 light, 2 heavy, 3 double (in that order of the string).
    private static let arms: [UInt32: String] = {
        let t: [(UInt32, String)] = [
            (0x2500, "1100"), (0x2501, "2200"), (0x2502, "0011"), (0x2503, "0022"),
            (0x250C, "0101"), (0x250D, "0201"), (0x250E, "0102"), (0x250F, "0202"),
            (0x2510, "1001"), (0x2511, "2001"), (0x2512, "1002"), (0x2513, "2002"),
            (0x2514, "0110"), (0x2515, "0210"), (0x2516, "0120"), (0x2517, "0220"),
            (0x2518, "1010"), (0x2519, "2010"), (0x251A, "1020"), (0x251B, "2020"),
            (0x251C, "0111"), (0x251D, "0211"), (0x251E, "0121"), (0x251F, "0112"), (0x2520, "0122"), (0x2521, "0221"), (0x2522, "0212"), (0x2523, "0222"),
            (0x2524, "1011"), (0x2525, "2011"), (0x2526, "1021"), (0x2527, "1012"), (0x2528, "1022"), (0x2529, "2021"), (0x252A, "2012"), (0x252B, "2022"),
            (0x252C, "1101"), (0x252D, "2101"), (0x252E, "1201"), (0x252F, "2201"), (0x2530, "1102"), (0x2531, "2102"), (0x2532, "1202"), (0x2533, "2202"),
            (0x2534, "1110"), (0x2535, "2110"), (0x2536, "1210"), (0x2537, "2210"), (0x2538, "1120"), (0x2539, "2120"), (0x253A, "1220"), (0x253B, "2220"),
            (0x253C, "1111"), (0x253D, "2111"), (0x253E, "1211"), (0x253F, "2211"), (0x2540, "1121"), (0x2541, "1112"), (0x2542, "1122"),
            (0x2543, "2121"), (0x2544, "1221"), (0x2545, "2112"), (0x2546, "1212"), (0x2547, "2221"), (0x2548, "2212"), (0x2549, "2122"), (0x254A, "1222"), (0x254B, "2222"),
            (0x2550, "3300"), (0x2551, "0033"), (0x2552, "0301"), (0x2553, "0103"), (0x2554, "0303"), (0x2555, "3001"), (0x2556, "1003"), (0x2557, "3003"),
            (0x2558, "0310"), (0x2559, "0130"), (0x255A, "0330"), (0x255B, "3010"), (0x255C, "1030"), (0x255D, "3030"),
            (0x255E, "0311"), (0x255F, "0133"), (0x2560, "0333"), (0x2561, "3011"), (0x2562, "1033"), (0x2563, "3033"),
            (0x2564, "3301"), (0x2565, "1103"), (0x2566, "3303"), (0x2567, "3310"), (0x2568, "1130"), (0x2569, "3330"),
            (0x256A, "3311"), (0x256B, "1133"), (0x256C, "3333"),
            (0x2574, "1000"), (0x2575, "0010"), (0x2576, "0100"), (0x2577, "0001"), (0x2578, "2000"), (0x2579, "0020"), (0x257A, "0200"), (0x257B, "0002"),
            (0x257C, "1200"), (0x257D, "0012"), (0x257E, "2100"), (0x257F, "0021"),
        ]
        return Dictionary(uniqueKeysWithValues: t.map { ($0.0, $0.1) })
    }()

    /// Dashed lines: (horizontal, heavy, dashes per cell).
    private static let dashes: [UInt32: (Bool, Bool, Int)] = [
        0x2504: (true, false, 3), 0x2505: (true, true, 3), 0x2506: (false, false, 3), 0x2507: (false, true, 3),
        0x2508: (true, false, 4), 0x2509: (true, true, 4), 0x250A: (false, false, 4), 0x250B: (false, true, 4),
        0x254C: (true, false, 2), 0x254D: (true, true, 2), 0x254E: (false, false, 2), 0x254F: (false, true, 2),
    ]

    private static func rect(_ ctx: CGContext, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
        if x1 > x0 && y1 > y0 { ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) }
    }

    private static func box(_ cp: UInt32, _ ctx: CGContext, _ w: Int, _ h: Int, _ light: CGFloat) {
        ctx.setShouldAntialias(false)
        let W = CGFloat(w), H = CGFloat(h), heavy = light * 3
        if let (horizontal, isHeavy, n) = dashes[cp] {
            let t = isHeavy ? heavy : light, len = horizontal ? W : H, period = len / CGFloat(n)
            for i in 0..<n {
                let a = (CGFloat(i) * period + period * 0.12).rounded(), b = (CGFloat(i) * period + period * 0.88).rounded()
                if horizontal { let y = ((H - t) / 2).rounded(.down); rect(ctx, a, y, b, y + t) }
                else { let x = ((W - t) / 2).rounded(.down); rect(ctx, x, a, x + t, b) }
            }
            return
        }
        switch cp {
        case 0x256D...0x2570: arc(cp, ctx, W, H, light); return
        case 0x2571...0x2573:
            ctx.setShouldAntialias(true); ctx.setLineWidth(light); ctx.setLineCap(.butt)
            if cp != 0x2572 { ctx.move(to: CGPoint(x: 0, y: H)); ctx.addLine(to: CGPoint(x: W, y: 0)) }
            if cp != 0x2571 { ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: W, y: H)) }
            ctx.strokePath(); return
        default: break
        }
        guard let s = arms[cp] else { return }
        let st = s.compactMap { Int(String($0)) }   // l r u d
        // Horizontal axis: arms l (negative) and r (positive) against the vertical arms u, d; then the same transposed.
        axis(ctx, along: W, across: H, neg: st[0], pos: st[1], perpNeg: st[2], perpPos: st[3], light: light, heavy: heavy) { a0, a1, b0, b1 in rect(ctx, a0, b0, a1, b1) }
        axis(ctx, along: H, across: W, neg: st[2], pos: st[3], perpNeg: st[0], perpPos: st[1], light: light, heavy: heavy) { a0, a1, b0, b1 in rect(ctx, b0, a0, b1, a1) }
    }

    /// Strokes (across-axis intervals) of one arm: one centred stroke (light/heavy) or two (double).
    private static func strokes(_ style: Int, across: CGFloat, light: CGFloat, heavy: CGFloat) -> [(CGFloat, CGFloat)] {
        switch style {
        case 0: return []
        case 3:
            let lo = ((across - 3 * light) / 2).rounded(.down)
            return [(lo, lo + light), (lo + 2 * light, lo + 3 * light)]
        default:
            let t = style == 2 ? heavy : light, y = ((across - t) / 2).rounded(.down)
            return [(y, y + t)]
        }
    }

    private static func axis(_ ctx: CGContext, along: CGFloat, across: CGFloat, neg: Int, pos: Int, perpNeg: Int, perpPos: Int,
                             light: CGFloat, heavy: CGFloat, emit: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void) {
        // The junction band of the perpendicular arms, measured on THIS axis' "along" coordinate (the perpendicular strokes are
        // positioned along it), so it comes from strokes() of the perpendicular style with `along` as the across size.
        let pn = strokes(perpNeg, across: along, light: light, heavy: heavy), pp = strokes(perpPos, across: along, light: light, heavy: heavy)
        let perps = pn + pp
        let hasPerp = !perps.isEmpty
        let pb0 = perps.map(\.0).min() ?? 0, pb1 = perps.map(\.1).max() ?? 0
        let mid = (along / 2).rounded(.down)
        let perpDouble = perpNeg == 3 || perpPos == 3
        for (isNeg, style) in [(true, neg), (false, pos)] where style != 0 {
            let opposite = isNeg ? pos != 0 : neg != 0
            for s in strokes(style, across: across, light: light, heavy: heavy) {
                let c = (s.0 + s.1) / 2, centre = across / 2
                let single = style != 3
                let sideNeg = single || c < centre, sidePos = single || c > centre
                let perpOnSide = (sideNeg && perpNeg != 0) || (sidePos && perpPos != 0)
                var edge: CGFloat   // where the stroke ends toward the junction
                if !hasPerp { edge = opposite ? (isNeg ? along : 0) : (isNeg ? mid + ceil(light / 2) : mid - ceil(light / 2)) }
                else if opposite {
                    if style == 3 && perpDouble && perpOnSide { edge = isNeg ? pb0 : pb1 }       // the inner gap of a double crossing
                    else { edge = isNeg ? pb1 : pb0 }                                           // passes through
                } else if style == 3 && perpDouble && perpOnSide {
                    // joins the nearest perpendicular stroke
                    edge = isNeg ? (perps.map(\.0).min()! + light) : (perps.map(\.1).max()! - light)
                } else { edge = isNeg ? pb1 : pb0 }
                if opposite && !(style == 3 && perpDouble && perpOnSide) {
                    // through-going: draw the whole way to the far end here, the opposite arm draws its own half
                    if isNeg { emit(0, max(edge, mid), s.0, s.1) } else { emit(min(edge, mid), along, s.0, s.1) }
                } else if isNeg { emit(0, edge, s.0, s.1) } else { emit(edge, along, s.0, s.1) }
            }
        }
    }

    private static func arc(_ cp: UInt32, _ ctx: CGContext, _ W: CGFloat, _ H: CGFloat, _ light: CGFloat) {
        ctx.setShouldAntialias(true); ctx.setLineWidth(light); ctx.setLineCap(.butt)
        let cx = ((W - light) / 2).rounded(.down) + light / 2, cy = ((H - light) / 2).rounded(.down) + light / 2
        let r = min(W, H) / 2
        let right = cp == 0x256D || cp == 0x2570, down = cp == 0x256D || cp == 0x256E
        let ex = right ? W : 0, ey = down ? H : 0
        let sx = right ? cx + r : cx - r, sy = down ? cy + r : cy - r
        ctx.move(to: CGPoint(x: ex, y: cy)); ctx.addLine(to: CGPoint(x: sx, y: cy))
        ctx.addQuadCurve(to: CGPoint(x: cx, y: sy), control: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: ey))
        ctx.strokePath()
    }

    // MARK: blocks

    private static func block(_ cp: UInt32, _ ctx: CGContext, _ w: Int, _ h: Int) {
        ctx.setShouldAntialias(false)
        let W = CGFloat(w), H = CGFloat(h)
        func fr(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) { rect(ctx, (x0 * W).rounded(), (y0 * H).rounded(), (x1 * W).rounded(), (y1 * H).rounded()) }
        switch cp {
        case 0x2580: fr(0, 0, 1, 0.5)
        case 0x2581...0x2588: let n = CGFloat(cp - 0x2580) / 8; fr(0, 1 - n, 1, 1)
        case 0x2589...0x258F: let n = CGFloat(0x2590 - cp) / 8; fr(0, 0, n, 1)
        case 0x2590: fr(0.5, 0, 1, 1)
        case 0x2591, 0x2592, 0x2593:
            let a: CGFloat = cp == 0x2591 ? 0.25 : cp == 0x2592 ? 0.5 : 0.75
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: a)); fr(0, 0, 1, 1)
        case 0x2594: fr(0, 0, 1, 0.125)
        case 0x2595: fr(0.875, 0, 1, 1)
        default:
            // quadrants 2596-259F: bits ul ur ll lr
            let q: [UInt32: [Int]] = [0x2596: [2], 0x2597: [3], 0x2598: [0], 0x2599: [0, 2, 3], 0x259A: [0, 3], 0x259B: [0, 1, 2], 0x259C: [0, 1, 3], 0x259D: [1], 0x259E: [1, 2], 0x259F: [1, 2, 3]]
            for i in q[cp] ?? [] { fr(i % 2 == 0 ? 0 : 0.5, i < 2 ? 0 : 0.5, i % 2 == 0 ? 0.5 : 1, i < 2 ? 0.5 : 1) }
        }
    }

    // MARK: powerline

    private static func powerline(_ cp: UInt32, _ ctx: CGContext, _ w: Int, _ h: Int, _ light: CGFloat) {
        ctx.setShouldAntialias(true); ctx.setLineWidth(light)
        let W = CGFloat(w), H = CGFloat(h)
        func tri(_ p: [(CGFloat, CGFloat)]) { ctx.move(to: CGPoint(x: p[0].0, y: p[0].1)); p.dropFirst().forEach { ctx.addLine(to: CGPoint(x: $0.0, y: $0.1)) }; ctx.closePath(); ctx.fillPath() }
        func line(_ p: [(CGFloat, CGFloat)]) { ctx.move(to: CGPoint(x: p[0].0, y: p[0].1)); p.dropFirst().forEach { ctx.addLine(to: CGPoint(x: $0.0, y: $0.1)) }; ctx.strokePath() }
        switch cp {
        case 0xE0B0: tri([(0, 0), (W, H / 2), (0, H)])
        case 0xE0B1: line([(0, 0), (W, H / 2), (0, H)])
        case 0xE0B2: tri([(W, 0), (0, H / 2), (W, H)])
        case 0xE0B3: line([(W, 0), (0, H / 2), (W, H)])
        case 0xE0B4, 0xE0B5, 0xE0B6, 0xE0B7:
            let right = cp == 0xE0B4 || cp == 0xE0B5, cx: CGFloat = right ? 0 : W
            ctx.move(to: CGPoint(x: cx, y: 0))
            ctx.addCurve(to: CGPoint(x: right ? W : 0, y: H / 2), control1: CGPoint(x: right ? W * 0.6 : W * 0.4, y: 0), control2: CGPoint(x: right ? W : 0, y: H * 0.2))
            ctx.addCurve(to: CGPoint(x: cx, y: H), control1: CGPoint(x: right ? W : 0, y: H * 0.8), control2: CGPoint(x: right ? W * 0.6 : W * 0.4, y: H))
            if cp == 0xE0B4 || cp == 0xE0B6 { ctx.closePath(); ctx.fillPath() } else { ctx.strokePath() }
        case 0xE0B8: tri([(0, 0), (0, H), (W, H)])
        case 0xE0B9: line([(0, 0), (W, H)])
        case 0xE0BA: tri([(W, 0), (W, H), (0, H)])
        case 0xE0BB: line([(W, 0), (0, H)])
        case 0xE0BC: tri([(0, 0), (W, 0), (0, H)])
        case 0xE0BD: line([(W, 0), (0, H)])
        case 0xE0BE: tri([(0, 0), (W, 0), (W, H)])
        case 0xE0BF: line([(0, 0), (W, H)])
        default: break
        }
    }
}
