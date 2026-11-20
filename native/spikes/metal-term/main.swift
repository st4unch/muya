// Faz 0 S1 (PRD docs/prd-native-rewrite.md, ADR-001 §7): Swift + libghostty-vt + Metal prototype.
// 25 live PTYs fed by a load generator (visible 1 MB/s, others 64 KB/s), 6 visible panes, one
// MTKView drawing every visible pane in a single pass from libghostty-vt's render state.
//
//   MetalTerm --bench [--seconds 20] [--sessions 25] [--visible 6] [--switches 20] [--offscreen]
//
// --offscreen renders into a texture on a 120 Hz timer instead of a drawable, so CPU/GPU frame cost
// can be measured with the display asleep; presented fps and switch latency need the window.
// Prototype simplification: every session has its replica in this process and is fed straight from
// its PTY (the real design feeds attached sessions only, from muyad) — so this is the heavier case.

import AppKit
import CGhostty
import CoreText
import Darwin
import Metal
import MetalKit
import QuartzCore

// MARK: - Options

let args = CommandLine.arguments
func opt(_ name: String, _ fallback: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) else { return fallback }
    return v
}
let benchMode = args.contains("--bench")
let offscreen = args.contains("--offscreen")
let sessionCount = opt("--sessions", 25)
let visibleCount = opt("--visible", 6)
let benchSeconds = opt("--seconds", 20)
let switchCount = opt("--switches", 20)
let rateVisible = opt("--rate-visible", 1_000_000)
let rateOther = opt("--rate-other", 65_536)
let paneColsOpt = opt("--cols", 80), paneRowsOpt = opt("--rows", 26)
/// `--cmd "<shell command>"`: session 0 runs this (login zsh) instead of the load generator.
let customCommand: String? = args.firstIndex(of: "--cmd").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
let snapshotPath: String? = args.firstIndex(of: "--snapshot").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
let snapshotAfter = opt("--after", 3)
/// `--resize-cols N --resize-at S`: shrink session 0 to N columns after S seconds (reflow + SIGWINCH).
let resizeCols = opt("--resize-cols", 0), resizeAt = opt("--resize-at", 2)

// MARK: - Session: PTY + load generator + libghostty-vt terminal

/// Load generator: Claude-like colored lines at `rate` bytes/s (written in 10 ms slices).
let generator = """
import sys, time, os
rate = int(sys.argv[1]); out = sys.stdout.buffer
lines = []
for i in range(400):
    lines.append(("\\x1b[38;5;%dm*\\x1b[0m Read \\x1b[1msrc/components/File%d.tsx\\x1b[0m lorem ipsum dolor sit amet \\x1b[38;2;%d;%d;200mşğüİı 日本語\\x1b[0m %d\\r\\n" % (16 + i % 200, i, i % 255, (i * 7) % 255, i)).encode())
blob = b"".join(lines); n = len(blob); pos = 0
slice_bytes = max(1, rate // 100); t = time.monotonic()
while True:
    chunk = blob[pos:pos + slice_bytes]
    if len(chunk) < slice_bytes: chunk += blob[:slice_bytes - len(chunk)]
    pos = (pos + slice_bytes) % n
    out.write(chunk); out.flush()
    t += 0.01
    d = t - time.monotonic()
    if d > 0: time.sleep(d)
    else: t = time.monotonic()
"""

final class Session: @unchecked Sendable {
    let id: Int
    let master: Int32
    let pid: pid_t
    let terminal: GhosttyTerminal
    let renderState: GhosttyRenderState
    let lock = NSLock()
    private var source: DispatchSourceRead?
    private(set) var bytesIn = 0
    private(set) var cols: Int, rows: Int

    init?(id: Int, cols: Int, rows: Int, rate: Int, command: String? = nil) {
        self.id = id
        self.cols = cols
        self.rows = rows
        var term: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &term, GhosttyTerminalOptions(cols: UInt16(cols), rows: UInt16(rows), max_scrollback: 5_500_000)) == GHOSTTY_SUCCESS,
              let term else { return nil }
        terminal = term
        var rs: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &rs) == GHOSTTY_SUCCESS, let rs else { return nil }
        renderState = rs
        // Grapheme clustering (DEC 2027), on by default in the Ghostty app: keeps 👍🏽 and 🇹🇷 in one cell.
        ghostty_terminal_mode_set(term, GhosttyMode(2027), true)

        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0, let name = ptsname(m) else { return nil }
        let slave = open(String(cString: name), O_RDWR | O_NOCTTY)
        guard slave >= 0 else { return nil }
        var t = termios()
        tcgetattr(slave, &t)
        t.c_iflag |= tcflag_t(IUTF8)
        tcsetattr(slave, TCSANOW, &t)
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, TIOCSWINSZ, &ws)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for fd in 0...2 { posix_spawn_file_actions_adddup2(&actions, slave, Int32(fd)) }
        var p: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { [strdup("/bin/zsh"), strdup("-lc"), strdup($0), nil] }
            ?? [strdup("/usr/bin/python3"), strdup("-c"), strdup(generator), strdup(String(rate)), nil]
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let rc = posix_spawn(&p, command == nil ? "/usr/bin/python3" : "/bin/zsh", &actions, &attr, argv, envp)
        envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        argv.forEach { free($0) }
        close(slave)
        guard rc == 0 else { close(m); return nil }
        master = m
        pid = p

        // Replies to terminal queries (DA, DSR, ...) go back to the PTY.
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
            guard let userdata, let data else { return }
            let s = Unmanaged<Session>.fromOpaque(userdata).takeUnretainedValue()
            _ = write(s.master, data, len)
        }
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))

        let src = DispatchSource.makeReadSource(fileDescriptor: m, queue: DispatchQueue(label: "pty.\(id)", qos: .userInitiated))
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        src.setEventHandler { [unowned self] in
            let n = read(m, buf, 65536)
            guard n > 0 else { return }
            lock.lock()
            ghostty_terminal_vt_write(terminal, buf, n)
            bytesIn += n
            lock.unlock()
        }
        src.resume()
        source = src
    }

    /// Reflows the terminal and tells the program (SIGWINCH via TIOCSWINSZ on the PTY).
    func resize(cols: Int, rows: Int, cellW: Int, cellH: Int) {
        lock.lock()
        ghostty_terminal_resize(terminal, UInt16(cols), UInt16(rows), UInt32(cellW), UInt32(cellH))
        self.cols = cols
        self.rows = rows
        lock.unlock()
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: UInt16(cols * cellW), ws_ypixel: UInt16(rows * cellH))
        _ = ioctl(master, TIOCSWINSZ, &ws)
    }

    func stop() {
        source?.cancel()
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        close(master)
    }
}

// MARK: - Glyph atlas (CoreText -> one RGBA texture)

struct AtlasEntry { var uv: SIMD4<Float>; var color: Bool }

final class Atlas {
    let texture: MTLTexture
    let size = 4096
    let font: CTFont
    let boldFont: CTFont
    let italicFont: CTFont
    let cellW: Int, cellH: Int, descent: CGFloat
    private var cache: [UInt64: AtlasEntry] = [:]
    private var stringCache: [String: AtlasEntry] = [:]
    private var x = 0, y = 0, rowH = 0
    private(set) var misses = 0

    init(device: MTLDevice, pointSize: CGFloat, scale: CGFloat) {
        font = CTFontCreateWithName("Menlo" as CFString, pointSize * scale, nil)
        boldFont = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font
        italicFont = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic) ?? font
        var glyph = CGGlyph(0)
        var ch = UniChar(77) // "M"
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &adv, 1)
        cellW = Int(ceil(adv.width))
        cellH = Int(ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)))
        descent = CTFontGetDescent(font)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        d.usage = .shaderRead
        texture = device.makeTexture(descriptor: d)!
    }

    /// One codepoint (the common case) is keyed without building a String.
    func entry(codepoint: UInt32, bold: Bool, italic: Bool = false, wide: Bool) -> AtlasEntry {
        let key = UInt64(codepoint) | (bold ? 1 << 32 : 0) | (wide ? 1 << 33 : 0) | (italic ? 1 << 34 : 0)
        if let e = cache[key] { return e }
        let e = rasterize(String(UnicodeScalar(codepoint).map(Character.init) ?? " "), bold: bold, italic: italic, wide: wide)
        cache[key] = e
        return e
    }

    func entry(grapheme: [UInt32], bold: Bool, italic: Bool = false, wide: Bool) -> AtlasEntry {
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
        if y + h > size { x = 0; y = 0; rowH = 0 } // full: wrap (prototype; real atlas grows/evicts)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let attr = NSAttributedString(string: text, attributes: [
            .font: italic ? italicFont : bold ? boldFont : font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var color = false
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if let f = attrs[kCTFontAttributeName] {
                if CTFontGetSymbolicTraits(f as! CTFont).contains(.traitColorGlyphs) { color = true }
            }
        }
        ctx.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, ctx)
        if let data = ctx.data {
            texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        }
        let s = Float(size)
        let e = AtlasEntry(uv: SIMD4(Float(x) / s, Float(y) / s, Float(x + w) / s, Float(y + h) / s), color: color)
        x += w
        rowH = max(rowH, h)
        return e
    }
}

// MARK: - Renderer

struct CellInstance {
    var grid: SIMD2<Float>
    var size: SIMD2<Float> // in cells: 1 or 2 wide; 0 = no glyph
    var uv: SIMD4<Float>
    var fg: SIMD4<UInt8>
    var bg: SIMD4<UInt8>
    var flags: UInt32 // 1 = color glyph, 2 = underline, 4 = strikethrough, 8 = bar cursor, 16 = underline cursor
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
    if (u.pass == 1 && c.size.x == 0) o.pos = float4(2, 2, 2, 1); // no glyph: outside the clip volume
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

/// Per-pane CPU copy of the cell instances; dirty rows are rebuilt from the render state.
final class PaneCache {
    var cells: [CellInstance]
    var sessionID = -1
    /// The cell the cursor was drawn on and its instance before the cursor changed it.
    var cursor: (index: Int, original: CellInstance)?
    init(count: Int) { cells = Array(repeating: CellInstance(grid: .zero, size: .zero, uv: .zero, fg: .zero, bg: .zero, flags: 0), count: count) }
}

@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let atlas: Atlas
    var sessions: [Session] = []
    var visible: [Int] = []
    var panes: [PaneCache] = []
    let cols: Int, rows: Int, paneCols: Int
    var rowIter: GhosttyRenderStateRowIterator?
    var rowCells: GhosttyRenderStateRowCells?
    let maxInflight = 3
    let inflight = DispatchSemaphore(value: 3)
    var buffers: [[MTLBuffer]] = []
    var frameIndex = 0
    var offscreenTarget: MTLTexture?

    // Metrics
    var frameStarts: [CFTimeInterval] = []
    var cpuMs: [Double] = []
    var gpuMs: [Double] = []
    var presented: [CFTimeInterval] = []
    var rowsRebuilt = 0
    var pendingSwitch: (requested: CFTimeInterval, frame: Int)?
    var switchLatencies: [Double] = []

    init(device: MTLDevice, cols: Int, rows: Int, paneCols: Int, scale: CGFloat) {
        self.device = device
        self.cols = cols
        self.rows = rows
        self.paneCols = paneCols
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
        super.init()
        ghostty_render_state_row_iterator_new(nil, &rowIter)
        ghostty_render_state_row_cells_new(nil, &rowCells)
    }

    func configure(visibleCount: Int) {
        panes = (0..<visibleCount).map { _ in PaneCache(count: cols * rows) }
        let bytes = MemoryLayout<CellInstance>.stride * cols * rows
        buffers = (0..<maxInflight).map { _ in (0..<visibleCount).map { _ in device.makeBuffer(length: bytes, options: .storageModeShared)! } }
    }

    var cellPx: SIMD2<Float> { SIMD2(Float(atlas.cellW), Float(atlas.cellH)) }

    func paneOrigin(_ i: Int) -> SIMD2<Float> {
        let pw = Float(cols) * cellPx.x + 8, ph = Float(rows) * cellPx.y + 8
        return SIMD2(Float(i % paneCols) * pw + 4, Float(i / paneCols) * ph + 4)
    }

    /// Pulls a pane's session into its render state and rebuilds dirty rows of its instance cache.
    func update(pane: PaneCache, session: Session) {
        let full = pane.sessionID != session.id
        pane.sessionID = session.id
        session.lock.lock()
        ghostty_render_state_begin_update(session.renderState, session.terminal)
        session.lock.unlock()
        ghostty_render_state_end_update(session.renderState)

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(session.renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        restoreCursor(pane: pane)
        if dirty == GHOSTTY_RENDER_STATE_DIRTY_FALSE && !full { drawCursor(pane: pane, session: session); return }
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_colors_get(session.renderState, &colors)
        let defFg = SIMD4<UInt8>(colors.foreground.r, colors.foreground.g, colors.foreground.b, 255)
        let defBg = SIMD4<UInt8>(colors.background.r, colors.background.g, colors.background.b, 255)
        let allRows = full || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL
        if allRows {
            let empty = CellInstance(grid: .zero, size: .zero, uv: .zero, fg: defFg, bg: defBg, flags: 0)
            for i in pane.cells.indices { pane.cells[i] = empty; pane.cells[i].grid = SIMD2(Float(i % cols), Float(i / cols)) }
        }

        ghostty_render_state_get(session.renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIter)
        var y = 0
        var cps = [UInt32](repeating: 0, count: 16)
        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        pane.cells.withUnsafeMutableBufferPointer { out in
            while y < rows, ghostty_render_state_row_iterator_next(rowIter) {
                var rowDirty = false
                ghostty_render_state_row_get(rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
                defer {
                    var clean = false
                    ghostty_render_state_row_set(rowIter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
                    y += 1
                }
                if !rowDirty && !allRows { continue }
                rowsRebuilt += 1
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
                        // Erased cells can still carry a background color (content tag).
                        var c = GhosttyColorRgb()
                        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &c) == GHOSTTY_SUCCESS { bg = SIMD4(c.r, c.g, c.b, 255) }
                    }
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
                            e = atlas.entry(grapheme: Array(cps[0..<Int(len)]), bold: bold, italic: italic, wide: isWide)
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
        drawCursor(pane: pane, session: session)
        var clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_set(session.renderState, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean)
    }

    /// Puts back the cell the cursor was drawn on; runs before any row is rebuilt.
    func restoreCursor(pane: PaneCache) {
        if let old = pane.cursor, old.index < pane.cells.count { pane.cells[old.index] = old.original }
        pane.cursor = nil
    }

    /// Block cursor inverts its cell; bar and underline cursors are drawn by the background pass.
    func drawCursor(pane: PaneCache, session: Session) {
        var visible = false, inView = false
        ghostty_render_state_get(session.renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)
        ghostty_render_state_get(session.renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &inView)
        guard visible, inView else { return }
        var cx: UInt16 = 0, cy: UInt16 = 0
        ghostty_render_state_get(session.renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx)
        ghostty_render_state_get(session.renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy)
        var style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        ghostty_render_state_get(session.renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style)
        let i = Int(cy) * cols + Int(cx)
        guard Int(cx) < cols, Int(cy) < rows else { return }
        pane.cursor = (i, pane.cells[i])
        switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: pane.cells[i].flags |= 8
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: pane.cells[i].flags |= 16
        default:
            var cell = pane.cells[i]
            swap(&cell.fg, &cell.bg)
            pane.cells[i] = cell
        }
    }

    func encodeFrame(target: MTLTexture, viewport: SIMD2<Float>, pass: MTLRenderPassDescriptor) -> MTLCommandBuffer {
        let slot = frameIndex % maxInflight
        for (i, pane) in panes.enumerated() where i < visible.count {
            update(pane: pane, session: sessions[visible[i]])
            pane.cells.withUnsafeBytes { src in
                buffers[slot][i].contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(atlas.texture, index: 0)
        for (i, _) in panes.enumerated() where i < visible.count {
            enc.setVertexBuffer(buffers[slot][i], offset: 0, index: 0)
            for p in 0..<2 {
                var u = Uniforms(origin: paneOrigin(i), cellSize: cellPx, viewport: viewport, pass: UInt32(p))
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cols * rows)
            }
        }
        enc.endEncoding()
        return cb
    }

    func recordGPU(_ cb: MTLCommandBuffer) {
        cb.addCompletedHandler { [weak self] buf in
            let ms = (buf.gpuEndTime - buf.gpuStartTime) * 1000
            DispatchQueue.main.async { self?.gpuMs.append(ms) }
        }
    }

    // MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let t0 = CACurrentMediaTime()
        inflight.wait()
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { inflight.signal(); return }
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        let size = view.drawableSize
        let cb = encodeFrame(target: drawable.texture, viewport: SIMD2(Float(size.width), Float(size.height)), pass: pass)
        let frame = frameIndex
        if let sw = pendingSwitch, sw.frame < 0 { pendingSwitch = (sw.requested, frame) }
        drawable.addPresentedHandler { [weak self] d in
            let when = d.presentedTime
            DispatchQueue.main.async {
                guard let self, when > 0 else { return }
                self.presented.append(when)
                if let sw = self.pendingSwitch, sw.frame >= 0, frame >= sw.frame {
                    self.switchLatencies.append((when - sw.requested) * 1000)
                    self.pendingSwitch = nil
                }
            }
        }
        cb.present(drawable)
        recordGPU(cb)
        let sem = inflight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
        frameIndex += 1
        frameStarts.append(t0)
        cpuMs.append((CACurrentMediaTime() - t0) * 1000)
    }

    /// Offscreen: same work, into a texture, driven by a 120 Hz timer.
    func drawOffscreen(size: CGSize) {
        let t0 = CACurrentMediaTime()
        if offscreenTarget == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = snapshotPath == nil ? .private : .shared
            offscreenTarget = device.makeTexture(descriptor: d)
        }
        inflight.wait()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = offscreenTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let cb = encodeFrame(target: offscreenTarget!, viewport: SIMD2(Float(size.width), Float(size.height)), pass: pass)
        if let sw = pendingSwitch, sw.frame < 0 {
            let req = sw.requested
            pendingSwitch = nil
            cb.addCompletedHandler { [weak self] _ in
                let done = CACurrentMediaTime()
                DispatchQueue.main.async { self?.switchLatencies.append((done - req) * 1000) }
            }
        }
        recordGPU(cb)
        let sem = inflight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
        frameIndex += 1
        frameStarts.append(t0)
        cpuMs.append((CACurrentMediaTime() - t0) * 1000)
    }

    func requestSwitch(to set: [Int]) {
        visible = set
        pendingSwitch = (CACurrentMediaTime(), -1)
    }
}

// MARK: - Metrics

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

func pct(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted()
    return s[min(s.count - 1, Int(Double(s.count) * p))]
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: Renderer!
    var view: MTKView?
    var timer: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let device = MTLCreateSystemDefaultDevice()!
        // Retina by default: with the display asleep NSScreen reports 1x, which would understate the cost.
        let scale = CGFloat(opt("--scale", Int(NSScreen.main?.backingScaleFactor ?? 2) >= 2 ? 2 : 2))
        let paneCols = 3
        let (cols, rows) = (paneColsOpt, paneRowsOpt)
        renderer = Renderer(device: device, cols: cols, rows: rows, paneCols: paneCols, scale: scale)
        renderer.configure(visibleCount: visibleCount)
        for i in 0..<sessionCount {
            guard let s = Session(id: i, cols: cols, rows: rows, rate: i == 0 ? rateVisible : rateOther, command: i == 0 ? customCommand : nil) else { fatalError("session \(i)") }
            renderer.sessions.append(s)
        }
        renderer.visible = Array(0..<min(visibleCount, sessionCount))
        let px = SIMD2(Float(cols) * renderer.cellPx.x + 8, Float(rows) * renderer.cellPx.y + 8)
        let gridRows = (visibleCount + paneCols - 1) / paneCols
        let sizePx = CGSize(width: CGFloat(px.x) * CGFloat(paneCols), height: CGFloat(px.y) * CGFloat(gridRows))

        if offscreen {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333))
            t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.renderer.drawOffscreen(size: sizePx) } }
            t.resume()
            timer = t
        } else {
            let sizePt = CGSize(width: sizePx.width / scale, height: sizePx.height / scale)
            window = NSWindow(contentRect: NSRect(origin: .zero, size: sizePt), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Metal Term (S1)"
            let v = MTKView(frame: NSRect(origin: .zero, size: sizePt), device: device)
            v.colorPixelFormat = .bgra8Unorm
            v.preferredFramesPerSecond = 120
            v.delegate = renderer
            window.contentView = v
            window.center()
            window.makeKeyAndOrderFront(nil)
            view = v
        }
        if benchMode { Task { await runBench() } }
        if let path = snapshotPath { Task { await snapshot(to: path) } }
        if resizeCols > 0 {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(resizeAt) * 1_000_000_000)
                let s = renderer.sessions[0]
                s.resize(cols: resizeCols, rows: s.rows, cellW: renderer.atlas.cellW, cellH: renderer.atlas.cellH)
            }
        }
    }

    func runBench() async {
        let r = renderer!
        try? await Task.sleep(nanoseconds: 2_000_000_000) // warm-up: atlas fills, generators settle
        r.frameStarts = []; r.cpuMs = []; r.gpuMs = []; r.presented = []; r.rowsRebuilt = 0
        let bytes0 = r.sessions.reduce(0) { $0 + $1.bytesIn }
        let cpu0 = cpuSeconds()
        let t0 = CACurrentMediaTime()
        var peakMB = footprintMB()
        for _ in 0..<benchSeconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            peakMB = max(peakMB, footprintMB())
        }
        let elapsed = CACurrentMediaTime() - t0
        let cpu = (cpuSeconds() - cpu0) / elapsed * 100
        let bytes = r.sessions.reduce(0) { $0 + $1.bytesIn } - bytes0
        let intervals = zip(r.frameStarts.dropFirst(), r.frameStarts).map { ($0 - $1) * 1000 }
        let presentedIntervals = zip(r.presented.dropFirst(), r.presented).map { ($0 - $1) * 1000 }
        let frames = r.frameStarts.count, presentedFrames = r.presented.count
        var lines: [String] = []
        lines.append("mode \(offscreen ? "offscreen" : "window"), \(sessionCount) sessions, \(visibleCount) visible, \(r.cols)x\(r.rows) cells, cell \(r.atlas.cellW)x\(r.atlas.cellH) px, \(benchSeconds) s")
        lines.append(String(format: "throughput: %.1f MB/s into all terminals (visible gen %d B/s, others %d B/s)", Double(bytes) / elapsed / 1e6, rateVisible, rateOther))
        lines.append(String(format: "encoded fps %.1f; frame interval p50 %.2f p95 %.2f p99 %.2f ms", Double(frames) / elapsed, pct(intervals, 0.5), pct(intervals, 0.95), pct(intervals, 0.99)))
        if !offscreen {
            lines.append(String(format: "presented fps %.1f; presented interval p50 %.2f p95 %.2f p99 %.2f ms", Double(presentedFrames) / elapsed, pct(presentedIntervals, 0.5), pct(presentedIntervals, 0.95), pct(presentedIntervals, 0.99)))
        }
        lines.append(String(format: "CPU per frame (update + encode) p50 %.2f p95 %.2f max %.2f ms; GPU per frame p50 %.3f p95 %.3f ms", pct(r.cpuMs, 0.5), pct(r.cpuMs, 0.95), r.cpuMs.max() ?? 0, pct(r.gpuMs, 0.5), pct(r.gpuMs, 0.95)))
        lines.append(String(format: "rows rebuilt %.0f/frame; process CPU %.0f%%; footprint peak %.0f MB; atlas glyphs %d", Double(r.rowsRebuilt) / Double(max(frames, 1)), cpu, peakMB, r.atlas.misses))

        // Switch test: replace every visible pane with sessions that were hidden.
        r.switchLatencies = []
        for k in 0..<switchCount {
            let start = ((k + 1) * visibleCount) % max(1, sessionCount - visibleCount + 1)
            r.requestSwitch(to: Array(start..<min(start + visibleCount, sessionCount)))
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        lines.append(String(format: "switch (all %d panes to other sessions) n=%d p50 %.1f p95 %.1f max %.1f ms (%@)", visibleCount, r.switchLatencies.count, pct(r.switchLatencies, 0.5), pct(r.switchLatencies, 0.95), r.switchLatencies.max() ?? 0, offscreen ? "to GPU completion" : "to presentation"))
        lines.append(String(format: "footprint end %.0f MB", footprintMB()))
        let out = lines.joined(separator: "\n")
        print(out)
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count { try? out.write(toFile: args[i + 1], atomically: true, encoding: .utf8) }
        timer?.cancel()
        r.sessions.forEach { $0.stop() }
        NSApp.terminate(nil)
    }

    /// Writes what the offscreen renderer drew to a PNG (lets the output be checked with the display off).
    func snapshot(to path: String) async {
        try? await Task.sleep(nanoseconds: UInt64(snapshotAfter) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let tex = renderer.offscreenTarget else { print("snapshot needs --offscreen"); NSApp.terminate(nil); return }
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // The CGContext must not outlive the buffer pointer, so build the image inside the closure.
        let image = bytes.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!.makeImage()!
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        var alphaZero = 0, firstLit = -1
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[i + 3] == 0 { alphaZero += 1 }
            if firstLit < 0 && (bytes[i] > 16 || bytes[i + 1] > 16 || bytes[i + 2] > 16) { firstLit = i }
        }
        print("alpha==0 pixels \(alphaZero) of \(w * h); first lit at px \(firstLit / 4) (x \((firstLit / 4) % w), y \((firstLit / 4) / w)) bytes \(firstLit >= 0 ? Array(bytes[firstLit..<firstLit + 4]) : [])")
        let lit = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 16 || bytes[$0 + 1] > 16 || bytes[$0 + 2] > 16 }.count
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_colors_get(renderer.sessions[0].renderState, &colors)
        print("snapshot \(w)x\(h) -> \(path); session 0 bytes \(renderer.sessions[0].bytesIn), lit pixels \(lit), frames \(renderer.frameIndex), default fg \(colors.foreground.r),\(colors.foreground.g),\(colors.foreground.b) bg \(colors.background.r),\(colors.background.g),\(colors.background.b)")
        timer?.cancel()
        renderer.sessions.forEach { $0.stop() }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { renderer?.sessions.forEach { kill($0.pid, SIGKILL) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(offscreen ? .accessory : .regular)
app.run()
