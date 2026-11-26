// Metal terminal renderer, adapted from native/spikes/metal-term: a CoreText glyph atlas and one
// instanced pass for cell backgrounds + one for glyphs, driven by libghostty-vt's render state.
// The view draws only when asked (needsDisplay), so an idle terminal costs no CPU or GPU.

import AppKit
import CGhostty
import CoreText
import Metal
import MetalKit
import QuartzCore

struct AtlasEntry { var uv: SIMD4<Float>; var color: Bool }

final class Atlas {
    let texture: MTLTexture
    let size = 2048
    let font: CTFont, boldFont: CTFont, italicFont: CTFont
    let cellW: Int, cellH: Int, descent: CGFloat, lineExtra: CGFloat
    private var cache: [UInt64: AtlasEntry] = [:]
    private var stringCache: [String: AtlasEntry] = [:]
    private var x = 0, y = 0, rowH = 0
    private(set) var misses = 0
    private let glyphScale: CGFloat
    /// Bumped when the atlas fills up and is cleared; cached cell instances are then stale.
    private(set) var generation = 0

    init(device: MTLDevice, pointSize: CGFloat, scale: CGFloat, lineSpacing: CGFloat = 1.6) {
        glyphScale = scale
        // JetBrains Mono (bundled, registered at launch by ThemeFonts) like today's Muya; Menlo when it is not registered.
        let jb = NSFont(name: "JetBrainsMono-Regular", size: 12) != nil
        font = CTFontCreateWithName((jb ? "JetBrainsMono-Regular" : "Menlo") as CFString, pointSize * scale, nil)
        boldFont = jb ? CTFontCreateWithName("JetBrainsMono-Bold" as CFString, pointSize * scale, nil)
                      : (CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font)
        italicFont = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic) ?? font
        var glyph = CGGlyph(0)
        var ch = UniChar(77) // "M"
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &adv, 1)
        cellW = Int(floor(adv.width))   // xterm: device char width = floor(css advance x devicePixelRatio) — 13 px JetBrains Mono: 15 device px = 7.5 pt at 2x (the web app), not ceil = 8
        let natural = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        // xterm's default line spacing in today's Muya (LINE_DEFAULT 1.6, src/lib/terminalPrefs.ts:25) over the font's own height.
        // xterm: row height = floor(round(font height) x lineHeight) in CSS px — 13 px JetBrains Mono: round(17.2) = 17, x 1.6 → 27 px rows
        // (measured in today's app: 27 px between text lines). Device pixels = that x scale.
        let rawPts = (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) / scale   // not ceil()ed: xterm rounds the measured height
        let cellPts = floor(rawPts.rounded() * lineSpacing)
        cellH = Int(max(natural, cellPts * scale))
        lineExtra = (CGFloat(cellH) - natural) / 2
        descent = CTFontGetDescent(font)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        d.usage = .shaderRead
        texture = device.makeTexture(descriptor: d)!
    }

    func entry(codepoint: UInt32, bold: Bool, italic: Bool, wide: Bool) -> AtlasEntry {
        let key = UInt64(codepoint) | (bold ? 1 << 32 : 0) | (wide ? 1 << 33 : 0) | (italic ? 1 << 34 : 0)
        if let e = cache[key] { return e }
        let e = rasterize(String(UnicodeScalar(codepoint).map(Character.init) ?? " "), bold: bold, italic: italic, wide: wide)
        cache[key] = e
        return e
    }

    func entry(grapheme: [UInt32], bold: Bool, italic: Bool, wide: Bool) -> AtlasEntry {
        var s = String.UnicodeScalarView()
        grapheme.forEach { if let u = UnicodeScalar($0) { s.append(u) } }
        let key = (bold ? "b" : "r") + (italic ? "i" : "u") + (wide ? "w" : "n") + String(s)
        if let e = stringCache[key] { return e }
        let e = rasterize(String(s), bold: bold, italic: italic, wide: wide)
        stringCache[key] = e
        return e
    }

    private func rasterize(_ text: String, bold: Bool, italic: Bool, wide: Bool) -> AtlasEntry {
        misses += 1
        let w = cellW * (wide ? 2 : 1), h = cellH
        if x + w > size { x = 0; y += rowH; rowH = 0 }
        if y + h > size {
            cache.removeAll(); stringCache.removeAll()
            x = 0; y = 0; rowH = 0
            generation += 1
        }
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setShouldSmoothFonts(false) // stem darkening makes light-on-dark and dark-on-light text look heavy
        ctx.setShouldAntialias(true)
        if text.unicodeScalars.count == 1, let u = text.unicodeScalars.first?.value, CustomGlyphs.handles(u) {
            CustomGlyphs.draw(u, in: ctx, w: w, h: h, scale: glyphScale)
            if let data = ctx.data { texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4) }
            let s = Float(size)
            let e = AtlasEntry(uv: SIMD4(Float(x) / s, Float(y) / s, Float(x + w) / s, Float(y + h) / s), color: false)
            x += w; rowH = max(rowH, h)
            return e
        }
        let attr = NSAttributedString(string: text, attributes: [
            .font: italic ? italicFont : bold ? boldFont : font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var color = false
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if let f = attrs[kCTFontAttributeName], CTFontGetSymbolicTraits(f as! CTFont).contains(.traitColorGlyphs) { color = true }
        }
        ctx.textPosition = CGPoint(x: 0, y: descent + lineExtra)
        CTLineDraw(line, ctx)
        if let data = ctx.data { texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4) }
        let s = Float(size)
        let e = AtlasEntry(uv: SIMD4(Float(x) / s, Float(y) / s, Float(x + w) / s, Float(y + h) / s), color: color)
        x += w
        rowH = max(rowH, h)
        return e
    }
}

struct CellInstance {
    var grid: SIMD2<Float>
    var size: SIMD2<Float> // in cells: 1 or 2 wide; 0 = no glyph
    var uv: SIMD4<Float>
    var fg: SIMD4<UInt8>
    var bg: SIMD4<UInt8>
    var flags: UInt32 // 1 = colour glyph, 2 = underline, 4 = strikethrough, 8 = bar cursor, 16 = underline cursor
    var pad: UInt32 = 0
}

struct Uniforms {
    var origin: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var viewport: SIMD2<Float>
    var pass: UInt32
    var pad: UInt32 = 0
}

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct Cell { float2 grid; float2 size; float4 uv; uchar4 fg; uchar4 bg; uint flags; uint pad; };
struct Uniforms { float2 origin; float2 cellSize; float2 viewport; uint pass; uint pad; };
struct VOut { float4 pos [[position]]; float2 uv; float2 local; float4 color; float4 fg; uint flags [[flat]]; };
vertex VOut vmain(uint vid [[vertex_id]], uint iid [[instance_id]],
                  const device Cell* cells [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
    Cell c = cells[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    VOut o;
    float2 extent = u.pass == 0 ? float2(1, 1) : c.size;
    float2 p = u.origin + (c.grid + corner * extent) * u.cellSize;
    float2 ndc = p / u.viewport * 2.0 - 1.0;
    o.pos = float4(ndc.x, -ndc.y, 0, 1);
    o.uv = mix(c.uv.xy, c.uv.zw, corner);
    o.color = float4(u.pass == 0 ? c.bg : c.fg) / 255.0;
    o.fg = float4(c.fg) / 255.0;
    o.local = corner;
    o.flags = c.flags;
    if (u.pass == 1 && c.size.x == 0) o.pos = float4(2, 2, 2, 1);
    return o;
}
fragment float4 fmain(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]], constant Uniforms& u [[buffer(1)]]) {
    if (u.pass == 0) {
        if ((in.flags & 2) && in.local.y > 0.90 && in.local.y < 0.96) return in.fg;
        if ((in.flags & 4) && abs(in.local.y - 0.55) < 0.035) return in.fg;
        if ((in.flags & 8) && in.local.x < 0.12) return in.fg;
        if ((in.flags & 16) && in.local.y > 0.88) return in.fg;
        return in.color;
    }
    constexpr sampler s(filter::nearest);
    float4 t = atlas.sample(s, in.uv);
    if (in.flags & 1) return t;
    return float4(in.color.rgb * t.a, t.a);
}
"""

/// Frame counters read through the debug socket / SIGUSR1 (CPU = update + encode per frame).
struct RenderMetrics {
    var frames = 0
    var cpuMs: [Double] = []
    var gpuMs: [Double] = []
    /// CPU (update + encode) plus GPU time of the same frame, and the gap between two frames of one view.
    var frameMs: [Double] = []
    var intervalMs: [Double] = []
    var tileFrames: [ObjectIdentifier: Int] = [:]
    var rowsRebuilt = 0
    var windowStart = CACurrentMediaTime()

    mutating func reset() { self = RenderMetrics() }
    static func pct(_ v: [Double], _ p: Double) -> Double { Stats.percentile(v, p) }
    var json: [String: Any] {
        let secs = max(CACurrentMediaTime() - windowStart, 0.001)
        return ["frames": frames, "fps": Double(frames) / secs, "seconds": secs,
                "cpu_ms_p50": Self.pct(cpuMs, 0.5), "cpu_ms_p95": Self.pct(cpuMs, 0.95), "cpu_ms_max": cpuMs.max() ?? 0,
                "gpu_ms_p50": Self.pct(gpuMs, 0.5), "gpu_ms_p95": Self.pct(gpuMs, 0.95), "gpu_ms_max": gpuMs.max() ?? 0,
                "frame_ms_p50": Self.pct(frameMs, 0.5), "frame_ms_p95": Self.pct(frameMs, 0.95), "frame_ms_max": frameMs.max() ?? 0,
                "interval_ms_p50": Self.pct(intervalMs, 0.5), "interval_ms_p95": Self.pct(intervalMs, 0.95),
                "tiles_drawing": tileFrames.count, "fps_per_tile": tileFrames.isEmpty ? 0 : Double(frames) / secs / Double(tileFrames.count),
                "rows_rebuilt_per_frame": Double(rowsRebuilt) / Double(max(frames, 1))]
    }
}

/// What every terminal view in the process shares: the GPU device and queue, the compiled pipeline,
/// the glyph atlas (one texture for all tiles of the grid view) and the frame counters.
final class RenderShared {
    nonisolated(unsafe) static var main: RenderShared!
    static func get(scale: CGFloat) -> RenderShared { if main == nil { main = RenderShared(scale: scale) }; return main }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    private(set) var atlas: Atlas
    private(set) var scale: CGFloat
    private(set) var pointSize: CGFloat = 13
    /// Terminal line spacing (xterm lineHeight; today's default 1.6): the cell height is font size x this.
    private(set) var lineSpacing: CGFloat = 1.6
    let metricsLock = NSLock()
    var metrics = RenderMetrics()

    init(scale: CGFloat) {
        device = MTLCreateSystemDefaultDevice()!
        self.scale = scale
        queue = device.makeCommandQueue()!
        atlas = Atlas(device: device, pointSize: 13, scale: scale)
        let lib = try! device.makeLibrary(source: shaderSource, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vmain")
        d.fragmentFunction = lib.makeFunction(name: "fmain")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .one
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try! device.makeRenderPipelineState(descriptor: d)
    }

    func setScale(_ s: CGFloat) {
        guard s != scale else { return }
        scale = s
        atlas = Atlas(device: device, pointSize: pointSize, scale: s, lineSpacing: lineSpacing)
    }

    /// Terminal font size (⌘= / ⌘- / ⌘0): a new atlas; every tile notices the new atlas object and redraws.
    func setPointSize(_ p: CGFloat) {
        guard p != pointSize else { return }
        pointSize = p
        atlas = Atlas(device: device, pointSize: p, scale: scale, lineSpacing: lineSpacing)
    }

    func setLineSpacing(_ l: CGFloat) {
        guard l != lineSpacing else { return }
        lineSpacing = l
        atlas = Atlas(device: device, pointSize: pointSize, scale: scale, lineSpacing: l)
    }
}

final class TerminalRenderer: NSObject, MTKViewDelegate {
    let shared: RenderShared
    var device: MTLDevice { shared.device }
    var atlas: Atlas { shared.atlas }
    var scale: CGFloat { shared.scale }
    var theme: TerminalTheme = .dark { didSet { cachedFor = nil } }
    /// The session being shown; set on the main thread.
    var replica: Replica? { didSet { cachedFor = nil } }
    /// IME marked text, drawn at the TUI cursor with an underline until it is committed.
    var preedit = ""
    /// The cell the TUI cursor is in, as of the last frame (the candidate window anchors there).
    private(set) var cols = 0, rows = 0
    var paddingPx: Float { Float(6 * scale) }

    private var cells: [CellInstance] = []
    private var cachedFor: ObjectIdentifier?
    private var cachedGeneration = -1
    private var cachedAtlas: ObjectIdentifier?
    private var cachedSelection = -1
    private var cachedLink = -1
    private var linkVersion = 0
    /// The path link under the pointer: its cells are drawn underlined (terminal path links). Not the selection.
    var link: (row: Int, from: Int, to: Int)? { didSet { linkVersion += 1 } }
    private var overlay: [(index: Int, original: CellInstance)] = []
    private(set) var cursorCell = (x: 0, y: 0)
    private var lastDraw = 0.0
    /// Called (main thread, after the GPU finished) for the next completed frame; used to time echo / switch.
    var onNextFrameCompleted: (() -> Void)?
    private var rowIter: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private let maxInflight = 3
    private let inflight = DispatchSemaphore(value: 3)
    private var buffers: [MTLBuffer] = []
    private var frameIndex = 0

    init(shared: RenderShared) {
        self.shared = shared
        super.init()
        ghostty_render_state_row_iterator_new(nil, &rowIter)
        ghostty_render_state_row_cells_new(nil, &rowCells)
    }

    var cellPx: SIMD2<Float> { SIMD2(Float(atlas.cellW), Float(atlas.cellH)) }
    var cellSizePoints: CGSize { CGSize(width: CGFloat(atlas.cellW) / scale, height: CGFloat(atlas.cellH) / scale) }

    /// The grid that fits a drawable of `size` pixels.
    func gridFor(drawable size: CGSize) -> (cols: Int, rows: Int) {
        let usableW = Float(size.width) - 2 * paddingPx, usableH = Float(size.height) - 2 * paddingPx
        return (max(2, Int(usableW / cellPx.x)), max(1, Int(usableH / cellPx.y)))
    }

    func setGrid(cols: Int, rows: Int) {
        guard cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        cells = Array(repeating: CellInstance(grid: .zero, size: .zero, uv: .zero, fg: .zero, bg: .zero, flags: 0), count: cols * rows)
        let bytes = MemoryLayout<CellInstance>.stride * cols * rows
        buffers = (0 ..< maxInflight).map { _ in device.makeBuffer(length: bytes, options: .storageModeShared)! }
        cachedFor = nil
        overlay = []
    }

    func setScale(_ s: CGFloat) {
        shared.setScale(s)
        cachedFor = nil
    }

    func setPointSize(_ p: CGFloat) {
        shared.setPointSize(p)
        cachedFor = nil
    }

    func setLineSpacing(_ l: CGFloat) {
        shared.setLineSpacing(l)
        cachedFor = nil
    }

    func metricsSnapshot() -> [String: Any] { shared.metricsLock.lock(); defer { shared.metricsLock.unlock() }; return shared.metrics.json }
    func resetMetrics() { shared.metricsLock.lock(); shared.metrics.reset(); shared.metricsLock.unlock() }

    // MARK: - Cell rebuild (from the spike: only dirty rows are rebuilt)

    private func update(replica: Replica) {
        let id = ObjectIdentifier(replica)
        let atlasID = ObjectIdentifier(atlas)
        var full = cachedFor != id || cachedGeneration != atlas.generation || cachedAtlas != atlasID || cachedSelection != replica.selectionVersion || cachedLink != linkVersion
        replica.lock.lock()
        ghostty_render_state_begin_update(replica.renderState, replica.terminal)
        replica.lock.unlock()
        ghostty_render_state_end_update(replica.renderState)

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(replica.renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        restoreOverlay()
        if dirty == GHOSTTY_RENDER_STATE_DIRTY_FALSE && !full { drawOverlay(replica); return }
        full = full || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_colors_get(replica.renderState, &colors)
        let defFg = SIMD4<UInt8>(colors.foreground.r, colors.foreground.g, colors.foreground.b, 255)
        let defBg = SIMD4<UInt8>(colors.background.r, colors.background.g, colors.background.b, 255)
        if full {
            let empty = CellInstance(grid: .zero, size: .zero, uv: .zero, fg: defFg, bg: defBg, flags: 0)
            for i in cells.indices { cells[i] = empty; cells[i].grid = SIMD2(Float(i % cols), Float(i / cols)) }
        }
        let generation = atlas.generation
        let cols = self.cols, rows = self.rows
        var rebuilt = 0

        ghostty_render_state_get(replica.renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIter)
        let selectionVersion = replica.selectionVersion
        let selBg = SIMD4<UInt8>(theme.selection.r, theme.selection.g, theme.selection.b, 255)
        var y = 0
        var cps = [UInt32](repeating: 0, count: 16)
        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        cells.withUnsafeMutableBufferPointer { out in
            while y < rows, ghostty_render_state_row_iterator_next(rowIter) {
                var rowDirty = false
                ghostty_render_state_row_get(rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
                defer {
                    var clean = false
                    ghostty_render_state_row_set(rowIter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
                    y += 1
                }
                if !rowDirty && !full { continue }
                rebuilt += 1
                var rowSel = GhosttyRenderStateRowSelection()
                rowSel.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
                let selected = ghostty_render_state_row_get(rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &rowSel) == GHOSTTY_SUCCESS
                ghostty_render_state_row_get(rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells)
                var x = 0
                while x < cols, ghostty_render_state_row_cells_next(rowCells) {
                    var len: UInt32 = 0
                    var raw: GhosttyCell = 0
                    var styled = false
                    var keys: [GhosttyRenderStateRowCellsData] = [GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                                                                  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                                                                  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING]
                    withUnsafeMutablePointer(to: &len) { l in withUnsafeMutablePointer(to: &raw) { r in withUnsafeMutablePointer(to: &styled) { st in
                        var vals: [UnsafeMutableRawPointer?] = [UnsafeMutableRawPointer(l), UnsafeMutableRawPointer(r), UnsafeMutableRawPointer(st)]
                        var written = 0
                        _ = ghostty_render_state_row_cells_get_multi(rowCells, 3, &keys, &vals, &written)
                    }}}
                    var fg = defFg, bg = defBg
                    var bold = false, italic = false
                    var lineFlags: UInt32 = 0
                    if styled {
                        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                        bold = style.bold
                        italic = style.italic
                        if style.underline != 0 { lineFlags |= 2 }
                        if style.strikethrough { lineFlags |= 4 }
                        var c = GhosttyColorRgb()
                        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &c) == GHOSTTY_SUCCESS { fg = SIMD4(c.r, c.g, c.b, 255) }
                        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &c) == GHOSTTY_SUCCESS { bg = SIMD4(c.r, c.g, c.b, 255) }
                        if style.inverse { swap(&fg, &bg) }
                        if style.faint {
                            fg = SIMD4<UInt8>(truncatingIfNeeded: (SIMD4<UInt16>(truncatingIfNeeded: fg) &+ SIMD4<UInt16>(truncatingIfNeeded: bg)) / 2)
                            fg.w = 255
                        }
                    } else if len == 0 {
                        var c = GhosttyColorRgb()
                        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &c) == GHOSTTY_SUCCESS { bg = SIMD4(c.r, c.g, c.b, 255) }
                    }
                    if selected, x >= Int(rowSel.start_x), x <= Int(rowSel.end_x) { bg = selBg }
                    if let l = link, l.row == y, x >= l.from, x <= l.to { lineFlags |= 2 }
                    var wide = GHOSTTY_CELL_WIDE_NARROW
                    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                    var inst = CellInstance(grid: SIMD2(Float(x), Float(y)), size: .zero, uv: .zero, fg: fg, bg: bg, flags: lineFlags)
                    if len > 0 && wide != GHOSTTY_CELL_WIDE_SPACER_TAIL {
                        let isWide = wide == GHOSTTY_CELL_WIDE_WIDE
                        let e: AtlasEntry
                        if len == 1 {
                            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &cps)
                            e = cps[0] == 32 ? AtlasEntry(uv: .zero, color: false) : atlas.entry(codepoint: cps[0], bold: bold, italic: italic, wide: isWide)
                        } else {
                            if cps.count < Int(len) { cps = [UInt32](repeating: 0, count: Int(len)) }
                            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &cps)
                            e = atlas.entry(grapheme: Array(cps[0 ..< Int(len)]), bold: bold, italic: italic, wide: isWide)
                        }
                        if e.uv != .zero {
                            inst.size = SIMD2(isWide ? 2 : 1, 1)
                            inst.uv = e.uv
                            inst.flags |= e.color ? 1 : 0
                        }
                    }
                    out[y * cols + x] = inst
                    x += 1
                }
            }
        }
        cachedFor = id
        cachedAtlas = atlasID
        cachedSelection = selectionVersion
        cachedLink = linkVersion
        // The atlas filled up and was cleared mid-update: instances built earlier point at wiped
        // glyphs. Build everything again against the fresh atlas.
        if atlas.generation != generation { cachedFor = nil; cachedGeneration = atlas.generation }
        else { cachedGeneration = generation }
        drawOverlay(replica)
        var clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_set(replica.renderState, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean)
        shared.metricsLock.lock(); shared.metrics.rowsRebuilt += rebuilt; shared.metricsLock.unlock()
    }

    private func restoreOverlay() {
        for o in overlay.reversed() where o.index < cells.count { cells[o.index] = o.original }
        overlay = []
    }

    /// Cursor and IME preedit are drawn into the cell array on top of the terminal's cells and put
    /// back at the start of the next update, so the terminal state itself is never touched.
    private func drawOverlay(_ replica: Replica) {
        drawCursor(replica)
        guard !preedit.isEmpty else { return }
        let fg = theme.foreground, bg = theme.background
        for pc in Preedit.layout(preedit, col: cursorCell.x, row: cursorCell.y, cols: cols, rows: rows) {
            let i = pc.row * cols + pc.col
            guard i < cells.count, i + (pc.wide ? 1 : 0) < cells.count else { continue }
            let e = atlas.entry(grapheme: pc.text.unicodeScalars.map(\.value), bold: false, italic: false, wide: pc.wide)
            var inst = cells[i]
            inst.fg = SIMD4(fg.r, fg.g, fg.b, 255)
            inst.bg = SIMD4(bg.r, bg.g, bg.b, 255)
            inst.uv = e.uv
            inst.size = e.uv == .zero ? .zero : SIMD2(pc.wide ? 2 : 1, 1)
            inst.flags = 2 | (e.color ? 1 : 0) // underline marks the text as uncommitted
            overlay.append((i, cells[i]))
            cells[i] = inst
            if pc.wide {
                overlay.append((i + 1, cells[i + 1]))
                cells[i + 1].size = .zero
                cells[i + 1].bg = inst.bg
                cells[i + 1].flags = 2
            }
        }
    }

    private func drawCursor(_ replica: Replica) {
        var visible = false, inView = false
        ghostty_render_state_get(replica.renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)
        ghostty_render_state_get(replica.renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &inView)
        guard inView else { return }
        var cx: UInt16 = 0, cy: UInt16 = 0
        ghostty_render_state_get(replica.renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx)
        ghostty_render_state_get(replica.renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy)
        // TUIs hide the hardware cursor but park it at their input caret: the IME anchor follows it either way.
        if Int(cx) < cols, Int(cy) < rows { cursorCell = (Int(cx), Int(cy)) }
        guard visible else { return }
        var style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        ghostty_render_state_get(replica.renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style)
        guard Int(cx) < cols, Int(cy) < rows else { return }
        cursorCell = (Int(cx), Int(cy))
        guard preedit.isEmpty else { return } // the composition replaces the cursor until it is committed
        let i = Int(cy) * cols + Int(cx)
        overlay.append((i, cells[i]))
        switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: cells[i].flags |= 8
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: cells[i].flags |= 16
        default:
            var cell = cells[i]
            swap(&cell.fg, &cell.bg)
            cells[i] = cell
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let t0 = CACurrentMediaTime()
        inflight.wait()
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { inflight.signal(); return }
        let bg = theme.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.r) / 255, green: Double(bg.g) / 255, blue: Double(bg.b) / 255, alpha: 1)
        let cb = shared.queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        if let replica, cols > 0 {
            update(replica: replica)
            if cachedFor == nil { DispatchQueue.main.async { view.needsDisplay = true } } // atlas was reset mid-frame
            let slot = frameIndex % maxInflight
            cells.withUnsafeBytes { buffers[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            enc.setRenderPipelineState(shared.pipeline)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setVertexBuffer(buffers[slot], offset: 0, index: 0)
            let size = view.drawableSize
            for p in 0 ..< 2 {
                var u = Uniforms(origin: SIMD2(paddingPx, paddingPx), cellSize: cellPx, viewport: SIMD2(Float(size.width), Float(size.height)), pass: UInt32(p))
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cols * rows)
            }
        }
        enc.endEncoding()
        cb.present(drawable)
        let sem = inflight
        let cpuMs = (CACurrentMediaTime() - t0) * 1000
        let shared = self.shared
        let hook = onNextFrameCompleted
        onNextFrameCompleted = nil
        cb.addCompletedHandler { buf in
            let gpu = (buf.gpuEndTime - buf.gpuStartTime) * 1000
            shared.metricsLock.lock()
            if shared.metrics.gpuMs.count < 40000 { shared.metrics.gpuMs.append(gpu); shared.metrics.frameMs.append(cpuMs + gpu) }
            shared.metricsLock.unlock()
            sem.signal()
            if let hook { DispatchQueue.main.async(execute: hook) }
        }
        cb.commit()
        frameIndex += 1
        shared.metricsLock.lock()
        shared.metrics.frames += 1
        shared.metrics.tileFrames[ObjectIdentifier(self), default: 0] += 1
        if lastDraw > 0, shared.metrics.intervalMs.count < 40000 { shared.metrics.intervalMs.append((t0 - lastDraw) * 1000) }
        if shared.metrics.cpuMs.count < 40000 { shared.metrics.cpuMs.append(cpuMs) }
        shared.metricsLock.unlock()
        lastDraw = t0
    }
}

