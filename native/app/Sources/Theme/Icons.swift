// Icons of today's Muya UI, drawn natively from the same SVG path data (IconData.swift, generated from
// src/redesign/icons.tsx): 24x24 viewBox, stroke only, round caps and joins, colour = a theme token.
//
//   let img = ThemeIcons.image(.sessionsRail, size: 18, color: Theme.dynamic(.textMuted))
//   ThemeIconView(icon: .bell, color: ...)           // an NSView that redraws on theme change
//
// The SVG path parser covers M m L l H h V v C c S s Q q T t A a Z z (all the commands used by the icon set).
import AppKit

public enum SVGPath {
    /// Parses SVG path data into a CGPath in SVG coordinates (y down, units of the viewBox).
    public static func parse(_ d: String) -> CGPath {
        var s = Scanner(d)
        let p = CGMutablePath()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtl: CGPoint? = nil   // previous cubic control point (for S)
        var lastQ: CGPoint? = nil     // previous quad control point (for T)
        var cmd: Character = "M"
        while true {
            s.skipSeparators()
            if s.atEnd { break }
            if let c = s.peekCommand() { cmd = c; s.advance(); if c == "Z" || c == "z" {
                p.closeSubpath(); cur = start; lastCtl = nil; lastQ = nil; continue } }
            let rel = cmd.isLowercase
            let ox = rel ? cur.x : 0, oy = rel ? cur.y : 0
            switch cmd {
            case "M", "m":
                guard let x = s.number(), let y = s.number() else { return p }
                cur = CGPoint(x: x + ox, y: y + oy); start = cur; p.move(to: cur)
                cmd = rel ? "l" : "L"; lastCtl = nil; lastQ = nil
            case "L", "l":
                guard let x = s.number(), let y = s.number() else { return p }
                cur = CGPoint(x: x + ox, y: y + oy); p.addLine(to: cur); lastCtl = nil; lastQ = nil
            case "H", "h":
                guard let x = s.number() else { return p }
                cur = CGPoint(x: x + ox, y: cur.y); p.addLine(to: cur); lastCtl = nil; lastQ = nil
            case "V", "v":
                guard let y = s.number() else { return p }
                cur = CGPoint(x: cur.x, y: y + oy); p.addLine(to: cur); lastCtl = nil; lastQ = nil
            case "C", "c":
                guard let x1 = s.number(), let y1 = s.number(), let x2 = s.number(), let y2 = s.number(),
                      let x = s.number(), let y = s.number() else { return p }
                let c2 = CGPoint(x: x2 + ox, y: y2 + oy)
                p.addCurve(to: CGPoint(x: x + ox, y: y + oy), control1: CGPoint(x: x1 + ox, y: y1 + oy), control2: c2)
                cur = CGPoint(x: x + ox, y: y + oy); lastCtl = c2; lastQ = nil
            case "S", "s":
                guard let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { return p }
                let c1 = lastCtl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = CGPoint(x: x2 + ox, y: y2 + oy)
                p.addCurve(to: CGPoint(x: x + ox, y: y + oy), control1: c1, control2: c2)
                cur = CGPoint(x: x + ox, y: y + oy); lastCtl = c2; lastQ = nil
            case "Q", "q":
                guard let x1 = s.number(), let y1 = s.number(), let x = s.number(), let y = s.number() else { return p }
                let c = CGPoint(x: x1 + ox, y: y1 + oy)
                p.addQuadCurve(to: CGPoint(x: x + ox, y: y + oy), control: c)
                cur = CGPoint(x: x + ox, y: y + oy); lastQ = c; lastCtl = nil
            case "T", "t":
                guard let x = s.number(), let y = s.number() else { return p }
                let c = lastQ.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                p.addQuadCurve(to: CGPoint(x: x + ox, y: y + oy), control: c)
                cur = CGPoint(x: x + ox, y: y + oy); lastQ = c; lastCtl = nil
            case "A", "a":
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(),
                      let fa = s.flag(), let fs = s.flag(), let x = s.number(), let y = s.number() else { return p }
                let end = CGPoint(x: x + ox, y: y + oy)
                addArc(p, from: cur, to: end, rx: rx, ry: ry, rotation: rot, large: fa, sweep: fs)
                cur = end; lastCtl = nil; lastQ = nil
            default: return p
            }
        }
        return p
    }

    /// SVG endpoint arc -> cubic Béziers (W3C SVG implementation notes F.6).
    static func addArc(_ p: CGMutablePath, from a: CGPoint, to b: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
                       rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 || a == b { p.addLine(to: b); return }
        let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (a.x - b.x) / 2, dy = (a.y - b.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lam > 1 { let s = sqrt(lam); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den)); if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (a.x + b.x) / 2, cy = sp * cxp + cp * cyp + (a.y + b.y) / 2
        func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy, len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var r = acos(max(-1, min(1, dot / len))); if ux * vy - uy * vx < 0 { r = -r }; return r
        }
        let th1 = ang(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var dth = ang((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && dth > 0 { dth -= 2 * .pi } else if sweep && dth < 0 { dth += 2 * .pi }
        let n = Int(ceil(abs(dth) / (.pi / 2) - 1e-9)), step = dth / CGFloat(max(n, 1))
        let t = 4 / 3 * tan(step / 4)
        var th = th1
        for _ in 0..<max(n, 1) {
            let c1 = cos(th), s1 = sin(th), c2 = cos(th + step), s2 = sin(th + step)
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cp * rx * x - sp * ry * y + cx, y: sp * rx * x + cp * ry * y + cy)
            }
            p.addCurve(to: pt(c2, s2), control1: pt(c1 - t * s1, s1 + t * c1), control2: pt(c2 + t * s2, s2 - t * c2))
            th += step
        }
    }

    struct Scanner {
        let u: [Character]; var i = 0
        init(_ s: String) { u = Array(s) }
        var atEnd: Bool { i >= u.count }
        mutating func skipSeparators() { while i < u.count, u[i] == " " || u[i] == "," || u[i] == "\n" || u[i] == "\t" { i += 1 } }
        func peekCommand() -> Character? { i < u.count && "MmLlHhVvCcSsQqTtAaZz".contains(u[i]) ? u[i] : nil }
        mutating func advance() { i += 1 }
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < u.count, u[i] == "0" || u[i] == "1" else { return nil }
            defer { i += 1 }; return u[i] == "1"
        }
        mutating func number() -> CGFloat? {
            skipSeparators()
            let st = i
            if i < u.count, u[i] == "-" || u[i] == "+" { i += 1 }
            var digits = false, dot = false
            while i < u.count {
                if u[i].isNumber { digits = true; i += 1 }
                else if u[i] == ".", !dot { dot = true; i += 1 }
                else { break }
            }
            guard digits else { i = st; return nil }
            if i < u.count, u[i] == "e" || u[i] == "E" {   // exponent
                var j = i + 1
                if j < u.count, u[j] == "-" || u[j] == "+" { j += 1 }
                if j < u.count, u[j].isNumber { while j < u.count, u[j].isNumber { j += 1 }; i = j }
            }
            return Double(String(u[st..<i])).map { CGFloat($0) }
        }
    }
}

public enum ThemeIcons {
    /// All shapes of an icon as one CGPath in viewBox coordinates.
    public static func path(_ icon: ThemeIcon) -> CGPath {
        let all = CGMutablePath()
        for s in icon.def.shapes {
            switch s {
            case .path(let d): all.addPath(SVGPath.parse(d))
            case .circle(let cx, let cy, let r): all.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            case .rect(let x, let y, let w, let h, let rx):
                let r = min(rx, w / 2, h / 2)
                all.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
            }
        }
        return all
    }

    /// Draws the icon into the current CGContext, in a flipped (y-down) square of side `size` at the origin.
    public static func draw(_ icon: ThemeIcon, in ctx: CGContext, size: CGFloat, color: NSColor, stroke: CGFloat? = nil) {
        let d = icon.def, k = size / 24
        ctx.saveGState()
        ctx.scaleBy(x: k, y: k)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(stroke ?? d.stroke)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.addPath(path(icon)); ctx.strokePath()
        ctx.restoreGState()
    }

    /// An image that re-renders at draw time (so a dynamic colour follows the appearance).
    public static func image(_ icon: ThemeIcon, size: CGFloat? = nil, color: NSColor, stroke: CGFloat? = nil) -> NSImage {
        let side = size ?? icon.def.size
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(icon, in: ctx, size: side, color: color, stroke: stroke); return true
        }
    }
}

/// A view that shows one icon in a token colour (`color` is dynamic, so it repaints on theme change).
public final class ThemeIconView: NSView {
    public var icon: ThemeIcon { didSet { needsDisplay = true } }
    public var color: NSColor { didSet { needsDisplay = true } }
    public var iconSize: CGFloat { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public init(icon: ThemeIcon, color: NSColor, size: CGFloat? = nil) {
        self.icon = icon; self.color = color; self.iconSize = size ?? icon.def.size
        super.init(frame: NSRect(x: 0, y: 0, width: size ?? icon.def.size, height: size ?? icon.def.size))
    }
    required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: iconSize, height: iconSize) }
    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.translateBy(x: (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2)
        ThemeIcons.draw(icon, in: ctx, size: iconSize, color: color)
    }
}
