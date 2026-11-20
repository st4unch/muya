// The app's local copy of one session's terminal: a libghostty-vt terminal fed with the bytes
// muyad sends (first a VT snapshot of the authoritative state, then live output). It is passive:
// it never answers terminal queries; muyad's own terminal does that.

import CGhostty
import Foundation

final class Replica: @unchecked Sendable {
    let terminal: GhosttyTerminal
    let renderState: GhosttyRenderState
    /// Guards the terminal: the reader thread writes, the render pass reads.
    let lock = NSLock()
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var bytesIn = 0
    /// libghostty's selection gesture (click counting, word / line / drag); created on first use.
    var gesture: GhosttySelectionGesture?
    /// Bumped whenever the selection changes; the renderer rebuilds highlighted rows when it moves.
    private(set) var selectionVersion = 0
    private var hadSelection = false
    /// New output returns the view to the bottom (PRD §8: scrollback is read while the program is quiet).
    var snapToBottomOnOutput = true
    /// Latency probe: when output containing `bytes` arrives, `hit` runs once (on the reader thread).
    private var probe: (bytes: Data, hit: () -> Void)?

    init?(cols: Int, rows: Int, theme: TerminalTheme) {
        self.cols = cols
        self.rows = rows
        var term: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &term, GhosttyTerminalOptions(cols: UInt16(cols), rows: UInt16(rows), max_scrollback: 2_000_000)) == GHOSTTY_SUCCESS,
              let term else { return nil }
        terminal = term
        var rs: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &rs) == GHOSTTY_SUCCESS, let rs else { return nil }
        renderState = rs
        // Grapheme clustering (DEC 2027), as in the Ghostty app: one cell for emoji + skin tone, flags.
        ghostty_terminal_mode_set(term, GhosttyMode(2027), true)
        apply(theme: theme)
    }

    deinit {
        if let gesture { ghostty_selection_gesture_free(gesture, terminal) }
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            lock.lock()
            ghostty_terminal_vt_write(terminal, base, raw.count)
            bytesIn += raw.count
            if let pr = probe, data.range(of: pr.bytes) != nil { probe = nil; pr.hit() }
            if snapToBottomOnOutput, scrolledBackLocked { scrollLocked(GHOSTTY_SCROLL_VIEWPORT_BOTTOM, delta: 0) }
            if hadSelection, !selectionActiveLocked { hadSelection = false; selectionVersion += 1 } // the program overwrote it
            lock.unlock()
        }
    }

    func armProbe(_ bytes: Data, hit: @escaping () -> Void) { lock.lock(); probe = (bytes, hit); lock.unlock() }
    func disarmProbe() { lock.lock(); probe = nil; lock.unlock() }

    func resize(cols: Int, rows: Int, cellW: Int, cellH: Int) {
        lock.lock()
        ghostty_terminal_resize(terminal, UInt16(cols), UInt16(rows), UInt32(cellW), UInt32(cellH))
        self.cols = cols
        self.rows = rows
        lock.unlock()
    }

    /// Default colours and ANSI palette for the current appearance (OSC overrides still win).
    func apply(theme: TerminalTheme) {
        lock.lock(); defer { lock.unlock() }
        var fg = theme.foreground.ghostty, bg = theme.background.ghostty, cur = theme.cursor.ghostty
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cur)
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 0, g: 0, b: 0), count: 256)
        let got = palette.withUnsafeMutableBytes { ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, $0.baseAddress) }
        guard got == GHOSTTY_SUCCESS else { return }
        for (i, c) in theme.ansi.enumerated() { palette[i] = c.ghostty }
        _ = palette.withUnsafeMutableBytes { ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, $0.baseAddress) }
    }

    /// Default foreground/background as the render state reports them (debug socket).
    func debugColors() -> String {
        lock.lock()
        ghostty_render_state_begin_update(renderState, terminal)
        lock.unlock()
        ghostty_render_state_end_update(renderState)
        var c = GhosttyRenderStateColors()
        c.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_colors_get(renderState, &c)
        return "fg=\(c.foreground.r),\(c.foreground.g),\(c.foreground.b) bg=\(c.background.r),\(c.background.g),\(c.background.b)"
    }

    var mouseTracking: Bool {
        lock.lock(); defer { lock.unlock() }
        var on = false
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &on)
        return on
    }

    func scroll(lines: Int) {
        lock.lock(); defer { lock.unlock() }
        scrollLocked(GHOSTTY_SCROLL_VIEWPORT_DELTA, delta: lines)
    }

    func scrollToBottom() {
        lock.lock(); defer { lock.unlock() }
        scrollLocked(GHOSTTY_SCROLL_VIEWPORT_BOTTOM, delta: 0)
    }

    private func scrollLocked(_ tag: GhosttyTerminalScrollViewportTag, delta: Int) {
        var b = GhosttyTerminalScrollViewport()
        b.tag = tag
        b.value.delta = delta
        ghostty_terminal_scroll_viewport(terminal, b)
    }

    /// Rows above the visible screen, and how far up the view is scrolled (0 = at the bottom).
    var scrollState: (history: Int, offsetFromBottom: Int) {
        lock.lock(); defer { lock.unlock() }
        var sb = GhosttyTerminalScrollbar()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS else { return (0, 0) }
        let history = Int(sb.total) - Int(sb.len)
        return (max(history, 0), max(history - Int(sb.offset), 0))
    }

    fileprivate var scrolledBackLocked: Bool {
        var sb = GhosttyTerminalScrollbar()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS else { return false }
        return sb.offset + sb.len < sb.total
    }

    fileprivate func bumpSelection() { selectionVersion += 1 }
    fileprivate func noteSelection(_ active: Bool) { hadSelection = active }
    fileprivate var selectionActiveLocked: Bool {
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.size
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS
    }

    /// The visible rows as text, right-trimmed (debug socket: lets a test read the screen).
    func visibleText() -> String {
        lock.lock()
        ghostty_render_state_begin_update(renderState, terminal)
        lock.unlock()
        ghostty_render_state_end_update(renderState)
        var iter: GhosttyRenderStateRowIterator?
        var cells: GhosttyRenderStateRowCells?
        ghostty_render_state_row_iterator_new(nil, &iter)
        ghostty_render_state_row_cells_new(nil, &cells)
        defer { ghostty_render_state_row_iterator_free(iter); ghostty_render_state_row_cells_free(cells) }
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iter)
        var lines: [String] = []
        var cps = [UInt32](repeating: 0, count: 32)
        while ghostty_render_state_row_iterator_next(iter) {
            ghostty_render_state_row_get(iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
            var line = String.UnicodeScalarView()
            while ghostty_render_state_row_cells_next(cells) {
                var len: UInt32 = 0
                // The second cell of a wide character holds no text of its own: reading it as a space would
                // turn "日本語" into "日 本 語" (selection text, the accessibility value, the debug socket).
                var raw: GhosttyCell = 0, wide = GHOSTTY_CELL_WIDE_NARROW
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { continue }
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len)
                if len == 0 { line.append(" "); continue }
                if cps.count < Int(len) { cps = [UInt32](repeating: 0, count: Int(len)) }
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &cps)
                for i in 0 ..< Int(len) { if let u = UnicodeScalar(cps[i]) { line.append(u) } }
            }
            var s = String(line)
            while s.hasSuffix(" ") { s.removeLast() }
            lines.append(s)
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: Selection (libghostty owns the selection and keeps it attached to the text while it scrolls)

extension Replica {
    /// What a mouse press / drag / release looks like to the selection gesture.
    struct Pointer {
        var col: Int, row: Int
        /// Position in surface pixels (for repeat-click distance and drag direction).
        var x: Double, y: Double
        var timeNs: UInt64
        var rectangle = false
    }

    struct GestureGeometry { var cols: Int, cellWpx: Int, paddingPx: Int, heightPx: Int }

    private func gridRef(col: Int, row: Int) -> GhosttyGridRef? {
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        var p = GhosttyPoint()
        p.tag = GHOSTTY_POINT_TAG_VIEWPORT
        p.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: max(col, 0)), y: UInt32(max(row, 0)))
        return ghostty_terminal_grid_ref(terminal, p, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private func withGesture<T>(_ body: (GhosttySelectionGesture) -> T) -> T? {
        if gesture == nil {
            var g: GhosttySelectionGesture?
            guard ghostty_selection_gesture_new(nil, &g) == GHOSTTY_SUCCESS else { return nil }
            gesture = g
        }
        return gesture.map(body)
    }

    private func install(_ result: GhosttyResult, _ sel: inout GhosttySelection) {
        if result == GHOSTTY_SUCCESS {
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &sel)
            noteSelection(true)
            bumpSelection()
        }
    }

    /// Left button down. Returns the click count (1 = cell, 2 = word, 3 = line).
    @discardableResult
    func selectionPress(_ p: Pointer, repeatIntervalNs: UInt64, repeatDistance: Double) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard var ref = gridRef(col: p.col, row: p.row) else { return 0 }
        var event: GhosttySelectionGestureEvent?
        guard ghostty_selection_gesture_event_new(nil, &event, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) == GHOSTTY_SUCCESS, let event else { return 0 }
        defer { ghostty_selection_gesture_event_free(event) }
        var pos = GhosttySurfacePosition(x: p.x, y: p.y)
        var time = p.timeNs, interval = repeatIntervalNs, distance = repeatDistance
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &pos)
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time)
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)
        let result: (GhosttyResult, Int, GhosttySelection)? = withGesture { g in
            var sel = GhosttySelection()
            sel.size = MemoryLayout<GhosttySelection>.size
            let r = ghostty_selection_gesture_event(g, terminal, event, &sel)
            var count: UInt8 = 0
            ghostty_selection_gesture_get(g, terminal, GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT, &count)
            return (r, Int(count), sel)
        }
        guard let (r, count, selection) = result else { return 0 }
        var sel = selection
        if r == GHOSTTY_SUCCESS { install(r, &sel) } else { clearSelectionLocked() } // a plain click clears the old selection
        return count
    }

    func selectionDrag(_ p: Pointer, geometry g: GestureGeometry) {
        lock.lock(); defer { lock.unlock() }
        guard var ref = gridRef(col: p.col, row: p.row) else { return }
        var event: GhosttySelectionGestureEvent?
        guard ghostty_selection_gesture_event_new(nil, &event, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG) == GHOSTTY_SUCCESS, let event else { return }
        defer { ghostty_selection_gesture_event_free(event) }
        var pos = GhosttySurfacePosition(x: p.x, y: p.y)
        var rect = p.rectangle
        var geo = GhosttySelectionGestureGeometry(columns: UInt32(g.cols), cell_width: UInt32(g.cellWpx), padding_left: UInt32(g.paddingPx), screen_height: UInt32(g.heightPx))
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &pos)
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect)
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geo)
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.size
        guard let r = withGesture({ ghostty_selection_gesture_event($0, terminal, event, &sel) }) else { return }
        install(r, &sel)
    }

    func selectionRelease(col: Int, row: Int) {
        lock.lock(); defer { lock.unlock() }
        var event: GhosttySelectionGestureEvent?
        guard ghostty_selection_gesture_event_new(nil, &event, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) == GHOSTTY_SUCCESS, let event else { return }
        defer { ghostty_selection_gesture_event_free(event) }
        if var ref = gridRef(col: col, row: row) { ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref) }
        _ = withGesture { ghostty_selection_gesture_event($0, terminal, event, nil) }
    }

    /// The selected text as the clipboard should get it: soft wraps joined, trailing blanks trimmed.
    func selectedText() -> String? {
        lock.lock(); defer { lock.unlock() }
        var opts = GhosttyTerminalSelectionFormatOptions()
        opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.unwrap = true
        opts.trim = true
        opts.selection = nil
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_terminal_selection_format_alloc(terminal, nil, opts, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return nil }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    var hasSelection: Bool { lock.lock(); defer { lock.unlock() }; return selectionActiveLocked }

    func clearSelection() { lock.lock(); clearSelectionLocked(); lock.unlock() }

    private func clearSelectionLocked() {
        guard selectionActiveLocked else { return }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        noteSelection(false)
        bumpSelection()
    }

    /// Selects everything on screen and in scrollback (⌘A).
    func selectAll() {
        lock.lock(); defer { lock.unlock() }
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.size
        install(ghostty_terminal_select_all(terminal, &sel), &sel)
    }
}

// MARK: Find and scrollback (⌘F, "Clear Scrollback" of the terminal menu)

extension Replica {
    /// The whole buffer, scrollback first, one string per row (trailing blanks trimmed; soft wraps NOT joined, so a line is a row).
    func bufferLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_select_all(terminal, &sel) == GHOSTTY_SUCCESS else { return [] }
        var opts = GhosttyTerminalSelectionFormatOptions()
        opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.unwrap = false
        opts.trim = true
        return withUnsafePointer(to: &sel) { p -> [String] in
            opts.selection = p
            var ptr: UnsafeMutablePointer<UInt8>?
            var len = 0
            guard ghostty_terminal_selection_format_alloc(terminal, nil, opts, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return [] }
            defer { ghostty_free(nil, ptr, len) }
            return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self).components(separatedBy: "\n")
        }
    }

    /// Selects the cells of `m` (so the renderer highlights them) and scrolls the view so they are on screen.
    func show(_ m: FindMatch) {
        lock.lock(); defer { lock.unlock() }
        func ref(_ col: Int, _ row: Int) -> GhosttyGridRef? {
            var r = GhosttyGridRef(); r.size = MemoryLayout<GhosttyGridRef>.size
            var p = GhosttyPoint(); p.tag = GHOSTTY_POINT_TAG_SCREEN
            p.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: max(col, 0)), y: UInt32(max(row, 0)))
            return ghostty_terminal_grid_ref(terminal, p, &r) == GHOSTTY_SUCCESS ? r : nil
        }
        guard let a = ref(m.col, m.row), let b = ref(m.col + m.cells - 1, m.row) else { return }
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.size
        sel.start = a; sel.end = b; sel.rectangle = false
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &sel)
        noteSelection(true); bumpSelection()
        var sb = GhosttyTerminalScrollbar()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS else { return }
        let top = Int(sb.offset), len = Int(sb.len)
        if m.row < top || m.row >= top + len { scrollLocked(GHOSTTY_SCROLL_VIEWPORT_DELTA, delta: m.row - (top + len / 2)) }
    }

    /// First row of the visible part of the buffer (absolute, 0 = oldest scrollback row).
    var viewportTop: Int {
        lock.lock(); defer { lock.unlock() }
        var sb = GhosttyTerminalScrollbar()
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS ? Int(sb.offset) : 0
    }

    /// Drops the scrollback of this copy (ED 3, "erase saved lines"); the screen and the running program are untouched.
    func clearScrollback() {
        clearSelection()
        write(Data("\u{1B}[3J".utf8))
    }
}
