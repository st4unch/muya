// Client unit tests: a tiny runner (no XCTest dependency). Run with `native/app/build.sh test`.
// Optional live check: MUYA_TEST_SOCKET=<muyad socket> also exercises the real daemon.

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var ran = 0

func check(_ cond: @autoclosure () throws -> Bool, _ what: String, line: Int = #line) {
    do { if try !cond() { failures += 1; print("  FAIL (line \(line)): \(what)") } } catch { failures += 1; print("  FAIL (line \(line)): \(what) threw \(error)") }
}

func test(_ name: String, _ body: () throws -> Void) {
    ran += 1
    let before = failures
    do { try body() } catch { failures += 1; print("  FAIL \(name): threw \(error)") }
    print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}

struct SplitMix: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

let samples: [Frame] = [
    .control(.hello(role: "app", build: "test")),
    .control(.welcome(major: 1, minor: 0, serverBuild: "0.1")),
    .control(.error(code: "no_such_session", message: "no such session ş")),
    .control(.spawn(argv: [], cwd: "/tmp", env: [["A", "b"]], cols: 80, rows: 24)),
    .control(.spawned(id: 3, pid: 4242)),
    .control(.list),
    .control(.sessions([SessionInfo(id: 3, pid: 42, cols: 80, rows: 24, endSeq: 9, exited: Int32(0)), SessionInfo(id: UInt64.max, pid: 1, cols: 1, rows: 1, endSeq: UInt64.max, exited: nil)])),
    .control(.attach(id: 1)),
    .control(.detach(id: 1)),
    .control(.attached(id: 1, startSeq: 0, endSeq: 9, modes: "2004=1")),
    .control(.resize(id: 1, cols: 120, rows: 40)),
    .control(.close(id: 1)),
    .control(.key(id: 1, key: "enter", mods: 6, text: nil)),
    .control(.key(id: 1, key: "a", mods: 0, text: "a")),
    .control(.paste(id: 1, text: "echo \"hi\"\n\u{1b}[31m日本語")),
    .control(.mouse(id: 1, col: 3, row: 4, button: "wheel_up", action: "press", mods: 0)),
    .control(.ok),
    .control(.exited(id: 2, status: -1)),
    .control(.screen(id: 2, state: "{\"mode\":\"default\",\"modeDetected\":false}")),
    .control(.event(name: "ssh-broker-open", payload: "{}")),
    .control(.rpc(req: 5, method: "sessions.history", params: "{\"q\":\"ş\"}")),
    .control(.rpcReply(req: 5, ok: true, result: "[1,2]")),
    .control(.rpcReply(req: UInt64.max, ok: false, result: "nope")),
    .control(.rpcCancel(req: 5)),
    .output(session: 7, seq: UInt64.max - 5, data: Data("\u{1b}[31mş\0".utf8)),
    .input(session: 1, data: Data()),
]

test("every frame kind round-trips") {
    for f in samples {
        var d = FrameDecoder()
        d.push(f.encoded())
        check(try d.next() == f, "roundtrip \(f)")
        check(try d.next() == nil, "no second frame for \(f)")
        check(d.buffered == 0, "decoder drained")
    }
}

test("decoder handles byte-by-byte delivery and back-to-back frames") {
    let bytes = samples.reduce(Data()) { $0 + $1.encoded() }
    var d = FrameDecoder()
    var got: [Frame] = []
    for b in bytes {
        d.push(Data([b]))
        while let f = try d.next() { got.append(f) }
    }
    check(got == samples, "all \(samples.count) frames, in order")
}

test("random partial reads reassemble the same frames (1000 splits)") {
    var rng = SplitMix(s: 42)
    let bytes = samples.reduce(Data()) { $0 + $1.encoded() }
    for _ in 0 ..< 1000 {
        var d = FrameDecoder()
        var got: [Frame] = []
        var i = 0
        while i < bytes.count {
            let n = min(Int.random(in: 1 ... 40, using: &rng), bytes.count - i)
            d.push(bytes[i ..< i + n])
            i += n
            while let f = try d.next() { got.append(f) }
        }
        if got != samples { check(false, "split case produced \(got.count) frames"); return }
    }
}

test("a long stream with 1 MB chunks keeps the decoder buffer bounded") {
    var d = FrameDecoder()
    let chunk = Frame.output(session: 1, seq: 0, data: Data(repeating: 0x61, count: 1 << 20)).encoded()
    var peak = 0
    for _ in 0 ..< 64 {
        d.push(chunk)
        while let _ = try d.next() {}
        peak = max(peak, d.buffered)
    }
    check(d.buffered == 0, "drained")
    check(peak <= chunk.count, "peak \(peak)")
}

test("oversized length is rejected before the body is buffered") {
    var d = FrameDecoder()
    d.push(be32(UInt32(maxFrame + 1)))
    do { _ = try d.next(); check(false, "expected tooLarge") } catch { check(error as? WireError == .tooLarge(maxFrame + 1), "\(error)") }
}

test("malformed bodies are typed errors, never crashes") {
    func decode(_ body: [UInt8]) -> WireError? {
        var d = FrameDecoder()
        d.push(be32(UInt32(body.count)) + Data(body))
        do { _ = try d.next(); return nil } catch { return error as? WireError }
    }
    check(decode([]) == .empty, "empty body")
    check(decode([9, 1, 2]) == .unknownKind(9), "unknown kind")
    check(decode([2, 0, 0, 0]) == .truncated, "short output header")
    check(decode([3, 0]) == .truncated, "short input header")
    if case .json = decode([1, 0x7b]) {} else { check(false, "bad json") }
    if case .json = decode(Array("\u{1}{\"type\":\"nope\"}".utf8)) {} else { check(false, "unknown control type") }
}

test("fuzz: arbitrary bytes in arbitrary splits never crash (3 s)") {
    var rng = SplitMix(s: 0x2545F4914F6CDD1D)
    let seeds = samples.prefix(10).map { $0.encoded() }
    let end = Date().addingTimeInterval(3)
    var cases = 0
    while Date() < end {
        var input: Data
        if Int.random(in: 0 ..< 3, using: &rng) == 0 {
            input = Data((0 ..< Int.random(in: 0 ..< 64, using: &rng)).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })
        } else {
            input = seeds.randomElement(using: &rng)!
            for _ in 0 ..< Int.random(in: 0 ..< 4, using: &rng) { input[Int.random(in: 0 ..< input.count, using: &rng)] = UInt8.random(in: 0 ... 255, using: &rng) }
        }
        if Int.random(in: 0 ..< 5, using: &rng) == 0 { input = input.prefix(Int.random(in: 0 ... input.count, using: &rng)) }
        var d = FrameDecoder()
        var i = 0
        loop: while i < input.count {
            let n = min(Int.random(in: 1 ... 8, using: &rng), input.count - i)
            d.push(input[input.startIndex + i ..< input.startIndex + i + n])
            i += n
            while true {
                do { if try d.next() == nil { break } } catch { break loop }
            }
        }
        cases += 1
    }
    check(cases > 1000, "only \(cases) cases")
}

test("parses the JSON the Rust daemon produces") {
    func parse(_ s: String) throws -> Control { try Control.parse(Data(s.utf8)) }
    check(try parse(#"{"type":"welcome","major":1,"minor":0,"server_build":"0.1.0"}"#) == .welcome(major: 1, minor: 0, serverBuild: "0.1.0"), "welcome")
    check(try parse(#"{"type":"sessions","sessions":[{"id":1,"pid":99,"cols":80,"rows":24,"end_seq":5,"exited":null},{"id":2,"pid":100,"cols":80,"rows":24,"end_seq":0,"exited":0}]}"#)
        == .sessions([SessionInfo(id: 1, pid: 99, cols: 80, rows: 24, endSeq: 5, exited: nil), SessionInfo(id: 2, pid: 100, cols: 80, rows: 24, endSeq: 0, exited: 0)]), "sessions")
    check(try parse(#"{"type":"error","code":"no_such_session","message":"no such session"}"#) == .error(code: "no_such_session", message: "no such session"), "error")
    check(try parse(#"{"type":"screen","id":4,"state":"{\"mode\":\"default\"}"}"#) == .screen(id: 4, state: #"{"mode":"default"}"#), "screen")
    check(try parse(#"{"type":"key","id":1,"key":"a","mods":0,"text":null}"#) == .key(id: 1, key: "a", mods: 0, text: nil), "key with null text")
    check(try parse(#"{"type":"sessions","sessions":[{"id":18446744073709551615,"pid":1,"cols":1,"rows":1,"end_seq":18446744073709551615,"exited":null}]}"#)
        == .sessions([SessionInfo(id: .max, pid: 1, cols: 1, rows: 1, endSeq: .max, exited: nil)]), "u64 max")
}

test("hello keeps the v1 wire shape (sorted keys, role snake_case)") {
    let body = Frame.control(.hello(role: "app", build: "b")).encoded().dropFirst(5)
    check(String(decoding: body, as: UTF8.self) == #"{"build":"b","major":1,"minor":3,"role":"app","type":"hello"}"#, "got \(String(decoding: body, as: UTF8.self))")
}

test("snapshot repair re-applies the cursor position that tab stops moved") {
    let snap = Data("\u{1b}c~ % hi\r\n~ % \u{1b}[0m\u{1b}[3;5H\u{1b}[3g\u{1b}[9G\u{1b}H\u{1b}[17G\u{1b}H".utf8)
    let fixed = repairSnapshotCursor(snap)
    check(fixed == snap + Data("\u{1b}[3;5H".utf8), "appends the last CUP, got \(String(decoding: fixed, as: UTF8.self).debugDescription)")
    let plain = Data("no tab block here \u{1b}[2;2H".utf8)
    check(repairSnapshotCursor(plain) == plain, "untouched without a tab-stop block")
    check(repairSnapshotCursor(Data()) == Data(), "empty input")
    let noCup = Data("\u{1b}[3g\u{1b}[9G\u{1b}H".utf8)
    check(repairSnapshotCursor(noCup) == noCup, "no earlier CUP: untouched")
    var rng = SplitMix(s: 7)
    for _ in 0 ..< 2000 { _ = repairSnapshotCursor(Data((0 ..< Int.random(in: 0 ..< 80, using: &rng)).map { _ in [0x1b, 0x5b, 0x33, 0x67, 0x48, 0x3b, 0x31, 0x41].randomElement(using: &rng)! })) }
}

// MARK: Faz 2b: selection, preedit, scrollback, grid

test("pixel to cell math clamps into the grid and respects padding") {
    let m = CellMetrics(cellW: 8, cellH: 16, padding: 6)
    check(m.cell(atX: 6, y: 6, cols: 80, rows: 24) == (0, 0), "top-left cell")
    check(m.cell(atX: 5, y: 5, cols: 80, rows: 24) == (0, 0), "padding clamps to cell 0")
    check(m.cell(atX: 6 + 8 * 10 + 7.9, y: 6 + 16 * 3 + 15.9, cols: 80, rows: 24) == (10, 3), "inside cell (10,3)")
    check(m.cell(atX: 6 + 8 * 10, y: 6 + 16 * 3, cols: 80, rows: 24) == (10, 3), "cell boundary belongs to the next cell")
    check(m.cell(atX: 9999, y: 9999, cols: 80, rows: 24) == (79, 23), "clamped bottom-right")
    check(m.origin(col: 2, row: 1) == (22, 22), "origin")
}

test("grid view tiling: shape, sizes, and the selected session is always shown") {
    check(GridLayout.shape(count: 1) == (1, 1) && GridLayout.shape(count: 2) == (2, 1) && GridLayout.shape(count: 4) == (2, 2) && GridLayout.shape(count: 6) == (3, 2), "shapes")
    let t = GridLayout.tiles(count: 6, width: 1204, height: 604, gap: 4)
    check(t.count == 6, "six tiles")
    check(abs(t[0].w - 398.67) < 0.01 && t[0].h == 300, "tile size \(t[0])")
    check(t[3].x == 0 && t[3].y == 304, "second row starts below the gap, got \(t[3])")
    check(abs(t[5].x + t[5].w - 1204) < 1e-9 && abs(t[5].y + t[5].h - 604) < 1e-9, "last tile ends at the edge")
    check(GridLayout.tiles(count: 9, width: 100, height: 100, gap: 0).count == 6, "capped at six")
    check(GridLayout.tiles(count: 0, width: 100, height: 100, gap: 0).isEmpty, "none")
    check(GridLayout.visible(ids: [1, 2, 3], selected: 2) == [1, 2, 3], "all fit")
    check(GridLayout.visible(ids: Array(1 ... 25), selected: 3) == [1, 2, 3, 4, 5, 6], "first six")
    check(GridLayout.visible(ids: Array(1 ... 25), selected: 20) == [1, 2, 3, 4, 5, 20], "selected replaces the last tile")
}

test("mouse routing: reporting while the program tracks the mouse, Shift overrides") {
    check(MouseRoute.decide(programTracksMouse: true, shift: false) == .report, "tracking -> report")
    check(MouseRoute.decide(programTracksMouse: true, shift: true) == .select, "shift -> select")
    check(MouseRoute.decide(programTracksMouse: false, shift: false) == .select, "no tracking -> select")
    check(MouseRoute.decide(programTracksMouse: false, shift: true) == .select, "no tracking + shift -> select")
}

test("scroll accumulator keeps the fraction between events") {
    var a = ScrollAccumulator()
    check(a.lines(delta: 0.4) == 0 && a.lines(delta: 0.4) == 0, "fractions collect")
    check(a.lines(delta: 0.4) == 1, "third event crosses 1.0")
    check(abs(a.remainder - 0.2) < 1e-9, "remainder \(a.remainder)")
    check(a.lines(delta: -3.5) == -3, "negative truncates toward zero")
    check(abs(a.remainder - (-0.3)) < 1e-9, "negative remainder \(a.remainder)")
    a.reset()
    check(a.lines(delta: 2.9) == 2, "after reset")
}

test("preedit layout: Turkish letters, wide Japanese, combining marks, wrapping") {
    func cols(_ c: [PreeditCell]) -> [Int] { c.map(\.col) }
    let tr = Preedit.layout("ğşçıöüİ", col: 3, row: 2, cols: 80, rows: 24)
    check(tr.count == 7 && cols(tr) == [3, 4, 5, 6, 7, 8, 9] && tr.allSatisfy { $0.row == 2 && !$0.wide }, "Turkish letters are one cell each: \(cols(tr))")
    check(tr.map(\.text).joined() == "ğşçıöüİ", "text kept")
    let ja = Preedit.layout("にほん", col: 0, row: 0, cols: 80, rows: 24)
    check(cols(ja) == [0, 2, 4] && ja.allSatisfy(\.wide), "wide characters take two cells: \(cols(ja))")
    let comb = Preedit.layout("e\u{0301}x", col: 0, row: 0, cols: 80, rows: 24)
    check(comb.count == 2 && comb[0].text == "e\u{0301}" && comb[1].col == 1, "a combining mark joins the previous cell")
    let wrap = Preedit.layout("abに", col: 78, row: 0, cols: 80, rows: 3)
    check(wrap.count == 3 && wrap[2].col == 0 && wrap[2].row == 1, "a wide character that does not fit moves to the next row: \(wrap)")
    check(Preedit.layout("abcdef", col: 78, row: 2, cols: 80, rows: 3).count == 2, "text past the last row is dropped")
    check(Preedit.layout("x", col: 0, row: 0, cols: 0, rows: 0).isEmpty, "empty grid")
    check(Preedit.caret(after: ja, start: (0, 0), cols: 80) == (6, 0), "caret after the composition")
    check(Preedit.caret(after: [], start: (4, 1), cols: 80) == (4, 1), "no preedit: caret stays")
    check(Preedit.width(of: "日") == 2 && Preedit.width(of: "ş") == 1 && Preedit.width(of: "😀") == 2 && Preedit.width(of: "\u{0301}") == 0, "widths")
}

test("percentile uses nearest rank") {
    check(Stats.percentile([], 0.5) == 0, "empty")
    check(Stats.percentile(Array(1 ... 100).map(Double.init), 0.95) == 95, "p95 of 1...100")
    check(Stats.percentile([5, 1, 3], 0.5) == 3, "median of three")
    check(Stats.percentile([7], 0.99) == 7, "single")
}

func replicaWith(_ text: String, cols: Int = 40, rows: Int = 6) -> Replica {
    let r = Replica(cols: cols, rows: rows, theme: .dark)!
    r.write(Data(text.utf8))
    return r
}

func ptr(_ col: Int, _ row: Int, t: UInt64 = 1_000_000_000, rect: Bool = false, fx: Double = 0.25) -> Replica.Pointer {
    // 16 px wide cells, 12 px padding, scale-2 style numbers
    Replica.Pointer(col: col, row: row, x: Double(12) + (Double(col) + fx) * 16, y: Double(12 + row * 32 + 16), timeNs: t, rectangle: rect)
}
let geo = Replica.GestureGeometry(cols: 40, cellWpx: 16, paddingPx: 12, heightPx: 400)

test("drag selects exactly the cells between press and release, and copy text is clean") {
    let r = replicaWith("hello world\r\nsecond line   \r\nthird")
    check(!r.hasSelection, "nothing selected at first")
    r.selectionPress(ptr(0, 0), repeatIntervalNs: 500_000_000, repeatDistance: 8)
    r.selectionDrag(ptr(4, 0, fx: 0.75), geometry: geo)
    r.selectionRelease(col: 4, row: 0)
    check(r.selectedText() == "hello", "got \(String(describing: r.selectedText()))")
    // Backwards drag over two rows.
    r.clearSelection()
    check(!r.hasSelection && r.selectedText() == nil, "clear")
    r.selectionPress(ptr(5, 1, fx: 0.75), repeatIntervalNs: 500_000_000, repeatDistance: 8)
    r.selectionDrag(ptr(6, 0, fx: 0.25), geometry: geo)
    check(r.selectedText() == "world\nsecond", "reverse multi-row drag, got \(String(describing: r.selectedText()))")
    // Trailing blanks of the selected rows are trimmed.
    r.clearSelection()
    r.selectionPress(ptr(0, 1), repeatIntervalNs: 500_000_000, repeatDistance: 8)
    r.selectionDrag(ptr(39, 1, fx: 0.75), geometry: geo)
    check(r.selectedText() == "second line", "trailing blanks trimmed, got \(String(describing: r.selectedText()))")
}

test("a drag ending in the left half of a cell leaves that cell out (Ghostty's half-cell rule)") {
    let r = replicaWith("abcdef")
    r.selectionPress(ptr(0, 0), repeatIntervalNs: 500_000_000, repeatDistance: 8)
    r.selectionDrag(ptr(3, 0, fx: 0.25), geometry: geo)
    check(r.selectedText() == "abc", "left half: got \(String(describing: r.selectedText()))")
    r.selectionDrag(ptr(3, 0, fx: 0.75), geometry: geo)
    check(r.selectedText() == "abcd", "right half: got \(String(describing: r.selectedText()))")
}

test("wide characters are selected as a whole and copy back as text") {
    let r = replicaWith("日本語 ok")
    r.selectionPress(ptr(0, 0), repeatIntervalNs: 500_000_000, repeatDistance: 8)
    r.selectionDrag(ptr(3, 0, fx: 0.75), geometry: geo) // 日 = cols 0-1, 本 = 2-3
    let t = r.selectedText()
    check(t == "日本", "got \(String(describing: t))")
    r.clearSelection()
    r.selectionPress(ptr(1, 0), repeatIntervalNs: 500_000_000, repeatDistance: 8) // second half of 日
    r.selectionDrag(ptr(1, 0, t: 1_000_000_000, fx: 0.75), geometry: geo)
    check(r.selectedText().map { $0.isEmpty || $0 == "日" } ?? true, "pointing at the second half of a wide char never splits it")
}

test("double click selects a word, triple click the line") {
    let r = replicaWith("foo bar-baz qux\r\nnext")
    let c1 = r.selectionPress(ptr(5, 0, t: 1_000_000_000), repeatIntervalNs: 500_000_000, repeatDistance: 8)
    r.selectionRelease(col: 5, row: 0)
    let c2 = r.selectionPress(ptr(5, 0, t: 1_150_000_000), repeatIntervalNs: 500_000_000, repeatDistance: 8)
    check(c1 == 1 && c2 == 2, "click counts \(c1) \(c2)")
    let word = r.selectedText()
    check(word == "bar-baz" || word == "bar", "word under the pointer, got \(String(describing: word))")
    r.selectionRelease(col: 5, row: 0)
    let c3 = r.selectionPress(ptr(5, 0, t: 1_300_000_000), repeatIntervalNs: 500_000_000, repeatDistance: 8)
    check(c3 == 3, "third click counts \(c3)")
    check(r.selectedText() == "foo bar-baz qux", "line, got \(String(describing: r.selectedText()))")
    r.selectionRelease(col: 5, row: 0)
    // A click later than the repeat interval starts over at 1 and clears.
    let c4 = r.selectionPress(ptr(5, 0, t: 3_000_000_000), repeatIntervalNs: 500_000_000, repeatDistance: 8)
    check(c4 == 1 && !r.hasSelection, "slow click: count \(c4), selection \(r.hasSelection)")
}

test("rectangle drag and select all") {
    let r = replicaWith("abcdef\r\nghijkl\r\nmnopqr")
    r.selectionPress(ptr(1, 0), repeatIntervalNs: 500_000_000, repeatDistance: 8)
    r.selectionDrag(ptr(3, 2, rect: true, fx: 0.75), geometry: geo)
    check(r.selectedText() == "bcd\nhij\nnop", "block, got \(String(describing: r.selectedText()))")
    r.selectAll()
    check(r.selectedText()?.hasPrefix("abcdef\nghijkl\nmnopqr") == true, "select all, got \(String(describing: r.selectedText()))")
}

test("selection survives output that scrolls the screen, and a rewrite of the text clears it") {
    let r = replicaWith("keep me\r\n", cols: 20, rows: 4)
    r.selectionPress(ptr(0, 0), repeatIntervalNs: 500_000_000, repeatDistance: 8)
    r.selectionDrag(ptr(6, 0, fx: 0.75), geometry: geo)
    check(r.selectedText() == "keep me", "selected")
    r.snapToBottomOnOutput = false
    r.write(Data("1\r\n2\r\n3\r\n4\r\n5\r\n".utf8)) // scrolls "keep me" into history
    check(r.selectedText() == "keep me", "still attached to the same text, got \(String(describing: r.selectedText()))")
    let v = r.selectionVersion
    r.clearSelection()
    check(r.selectionVersion > v, "clearing bumps the version so the renderer redraws")
}

test("visible text: wide characters are not split by their spacer cell (accessibility value, selection, debug socket)") {
    let r = Replica(cols: 30, rows: 3, theme: .dark)!
    r.write(Data("日本語 ok\r\nş ğ ı İ\r\n".utf8))
    check(r.visibleText() == "日本語 ok\nş ğ ı İ", "CJK text reads as written: \(r.visibleText().debugDescription)")
}

test("scrollback: wheel scrolls the replica, new output snaps back to the bottom") {
    let r = Replica(cols: 20, rows: 5, theme: .dark)!
    for i in 0 ..< 60 { r.write(Data("line \(i)\r\n".utf8)) }
    let s0 = r.scrollState
    check(s0.history >= 50 && s0.offsetFromBottom == 0, "history \(s0.history), at bottom")
    r.scroll(lines: -10)
    check(r.scrollState.offsetFromBottom == 10, "scrolled up 10, got \(r.scrollState.offsetFromBottom)")
    check(r.visibleText().contains("line 4") || !r.visibleText().contains("line 59"), "older lines are shown")
    r.scroll(lines: 4)
    check(r.scrollState.offsetFromBottom == 6, "scrolled back down 4")
    r.scroll(lines: -1000)
    check(r.scrollState.offsetFromBottom == r.scrollState.history, "clamped at the top of history")
    r.write(Data("fresh output\r\n".utf8))
    check(r.scrollState.offsetFromBottom == 0, "new output returns to the bottom, got \(r.scrollState.offsetFromBottom)")
    check(r.visibleText().contains("fresh output"), "and the fresh line is visible")
    r.scroll(lines: -8)
    r.scrollToBottom()
    check(r.scrollState.offsetFromBottom == 0, "scrollToBottom (a keystroke)")
}

test("scrollback can be read while output continues when snapping is off") {
    let r = Replica(cols: 20, rows: 5, theme: .dark)!
    r.snapToBottomOnOutput = false
    for i in 0 ..< 40 { r.write(Data("row \(i)\r\n".utf8)) }
    r.scroll(lines: -10)
    let before = r.visibleText()
    r.write(Data("more\r\n".utf8))
    check(r.scrollState.offsetFromBottom >= 10, "still scrolled back, got \(r.scrollState.offsetFromBottom)")
    check(r.visibleText() == before || r.scrollState.offsetFromBottom > 10, "the view is pinned to the same text")
}

if let socket = ProcessInfo.processInfo.environment["MUYA_TEST_SOCKET"] {
    test("live: handshake, spawn, attach, echo through the real daemon") {
        let conn = try MuyadConnection(path: socket, build: "client-test")
        check(!conn.serverBuild.isEmpty, "server build reported")
        nonisolated(unsafe) var received = Data()
        let lock = NSLock()
        conn.onFrame = { f in if case let .output(_, _, d) = f { lock.lock(); received.append(d); lock.unlock() } }
        conn.start()
        guard case let .spawned(id, _) = try conn.request(.spawn(argv: ["/bin/sh", "-c", "echo hello-from-client; sleep 5"], cwd: "/tmp", env: [], cols: 80, rows: 24)) else { check(false, "spawned"); return }
        _ = try conn.request(.attach(id: id))
        Thread.sleep(forTimeInterval: 1)
        lock.lock(); let text = String(decoding: received, as: UTF8.self); lock.unlock()
        check(text.contains("hello-from-client"), "output contains echo, got \(text.debugDescription)")
        guard case let .sessions(list) = try conn.request(.list) else { check(false, "list"); return }
        check(list.contains { $0.id == id }, "session listed")
        _ = try conn.request(.close(id: id))
        conn.close()
    }
}

runFileTests()
runEditorTests()
runEditorExtraTests()
runPageTests()
runFaz4eTests()
runInspectorTests()
runSplitTests()
runCommandTests()
runServiceIdentityTests()
runServiceRecoveryTests()
runStartedTerminalTests()
runSidebarTests()
runAgentsWidthTests()
runUiFixesTests()
runPasteTests()
runGlyphTests()
runP6Tests()
runP7Tests()
runP10Tests()
runP11Tests()
runQueueTests()
runSSHTests()
runP12Tests()
runP4Tests()
runAC1921Tests()
runBetaTests()
runFDATests()
runThemeTests()
runSafetyTests()
runNewAgentTests()
runV5Tests()
runUpdateStatusTests()
runNotifyTests()
runPaletteFilesTests()
runScrollCrashTests()
runP3Tests()
runTerminalTests()
runExitDiagTests()

print("\(ran) tests, \(failures) failures")
exit(failures == 0 ? 0 : 1)
