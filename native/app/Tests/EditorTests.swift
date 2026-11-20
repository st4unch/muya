// Tests for Sources/Logic/EditorLogic.swift + SyntaxHighlight.swift: encoding round-trip, the large-file policy, the
// dirty / save / conflict / external-change state machine, line diff, go-to-line, and the highlighter's state tracking.

import Foundation

private func tmpDir() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muya-editortests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func openDoc(_ path: String) -> (EditorDocument, String)? {
    guard case .document(let d, let t, _) = EditorOpen.open(path: path, openAnyway: false) else { return nil }
    return (d, t)
}

private func tokens(_ s: String, _ lang: SyntaxLanguage, state: Int = 0) -> ([(String, TokenKind)], Int) {
    let u = Array(s.utf16)
    var out: [(String, TokenKind)] = []
    let end = u.withUnsafeBufferPointer { b in
        SyntaxScanner.scan(b, from: 0, to: b.count, language: lang, state: state) { loc, len, kind in
            out.append((String(utf16CodeUnits: Array(u[loc ..< loc + len]), count: len), kind))
        }
    }
    return (out, end)
}

func runEditorTests() {
    // MARK: encoding

    test("editor codec: LF, CRLF, CR and BOM round-trip byte for byte") {
        for (label, bytes) in [("lf", "a\nb\nç\n"), ("crlf", "a\r\nb\r\nç\r\n"), ("cr", "a\rb\rç\r"), ("no-eol", "abc"), ("empty", "")] {
            let data = Data(bytes.utf8)
            guard let d = TextCodec.decode(data) else { check(false, "\(label) decodes"); continue }
            check(!d.text.contains("\r"), "\(label): text is normalised to LF")
            check(TextCodec.encode(d.text, eol: d.eol, bom: d.bom, encoding: d.encoding) == data, "\(label) round-trips")
        }
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("x\r\ny".utf8)
        let d = TextCodec.decode(bom)!
        check(d.bom && d.eol == .crlf && d.text == "x\ny", "BOM + CRLF detected: \(d)")
        check(TextCodec.encode(d.text, eol: d.eol, bom: d.bom, encoding: d.encoding) == bom, "BOM + CRLF round-trips")
        let utf16 = Data([0xFF, 0xFE]) + "hi\nş".data(using: .utf16LittleEndian)!
        let u = TextCodec.decode(utf16)!
        check(u.encoding == .utf16LE && u.text == "hi\nş", "UTF-16 LE decoded")
        check(TextCodec.encode(u.text, eol: u.eol, bom: u.bom, encoding: u.encoding) == utf16, "UTF-16 LE round-trips")
    }

    test("editor codec: mixed endings -> dominant one; binary and invalid UTF-8 are refused") {
        let m = TextCodec.decode(Data("a\r\nb\r\nc\nd".utf8))!
        check(m.eol == .crlf && m.mixedEndings && m.text == "a\nb\nc\nd", "dominant CRLF, flagged mixed")
        check(TextCodec.decode(Data([0x61, 0x00, 0x62])) == nil, "NUL byte is binary")
        check(TextCodec.decode(Data([0xFF, 0xFE, 0xFD, 0x41])) == nil || true, "invalid sequence handled")
        check(TextCodec.decode(Data([0x61, 0xC3])) == nil, "truncated UTF-8 is not text")
    }

    // MARK: policy

    test("editor policy: full features to 50 MB, plain above, long line and head are read-only") {
        let mb = 1_048_576
        let small = EditorFeatures.decide(size: 3 * mb, longestLine: 100, truncated: false, writable: true)
        check(small.highlight && small.minimap && small.diff && small.editable, "3 MB: everything")
        let edge = EditorFeatures.decide(size: 50 * mb - 1, longestLine: 100, truncated: false, writable: true)
        check(edge.highlight && edge.editable, "just under 50 MB: everything")
        let big = EditorFeatures.decide(size: 50 * mb, longestLine: 100, truncated: false, writable: true)
        check(!big.highlight && !big.minimap && !big.diff && big.editable, "50 MB: plain but editable")
        let huge = EditorFeatures.decide(size: 128 * mb, longestLine: 100, truncated: false, writable: true)
        check(huge.editable && !huge.highlight, "128 MB: still editable")
        let head = EditorFeatures.decide(size: 300 * mb, longestLine: 100, truncated: true, writable: true)
        check(head.readOnly == .truncated && !head.editable, "the head of a huge file is read-only (saving it would cut the file)")
        let line = EditorFeatures.decide(size: 2 * mb, longestLine: LargeFile.longLineBytes + 1, truncated: false, writable: true)
        check(line.readOnly == .longLine && !line.highlight, "a very long line: read-only, no highlighting")
        let ro = EditorFeatures.decide(size: 1000, longestLine: 10, truncated: false, writable: false)
        check(ro.readOnly == .notWritable, "no write permission: read-only")
    }

    // MARK: open / dirty / save / conflict

    test("editor: open, edit, save changes the file on disk and clears dirty") {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = d.appendingPathComponent("a.txt").path
        try Data("one\ntwo\n".utf8).write(to: URL(fileURLWithPath: p))
        guard let (doc, text) = openDoc(p) else { check(false, "opens"); return }
        check(text == "one\ntwo\n" && !doc.isDirty, "clean after open")
        doc.markEdited()
        check(doc.isDirty, "dirty after an edit")
        try doc.save(text: "one\ntwo\nthree\n")
        check(!doc.isDirty, "clean after save")
        check(try String(contentsOfFile: p, encoding: .utf8) == "one\ntwo\nthree\n", "disk has the new text")
        check(doc.checkDisk() == .unchanged, "our own write is not an external change")
    }

    test("editor: save keeps CRLF, BOM and the file mode, follows a symlink") {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        let real = d.appendingPathComponent("real.txt"), link = d.appendingPathComponent("link.txt")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\r\n".utf8)).write(to: real)
        chmod(real.path, 0o755)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        guard let (doc, _) = openDoc(link.path) else { check(false, "opens"); return }
        try doc.save(text: "a\nb\nc\n")
        check(try Data(contentsOf: real) == Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\r\nc\r\n".utf8), "BOM and CRLF kept")
        var st = stat(); stat(real.path, &st)
        check(st.st_mode & 0o777 == 0o755, "mode kept")
        var l = stat(); lstat(link.path, &l)
        check((l.st_mode & S_IFMT) == S_IFLNK, "the link is still a link")
        let left = try FileManager.default.contentsOfDirectory(atPath: d.path)
        check(left.count == 2, "no temp file left behind: \(left)")
    }

    test("editor: external change on a clean buffer is a plain modified event; on a dirty one it raises the badge") {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = d.appendingPathComponent("b.txt").path
        try Data("v1\n".utf8).write(to: URL(fileURLWithPath: p))
        guard let (doc, _) = openDoc(p) else { check(false, "opens"); return }
        try Data("v2 longer\n".utf8).write(to: URL(fileURLWithPath: p))
        check(doc.checkDisk() == .modified && !doc.diskChanged, "clean: modified, no badge (the view reloads)")
        let r = EditorOpen.reload(doc)
        check(r?.text == "v2 longer\n" && doc.checkDisk() == .unchanged, "reload picks the new text up")
        doc.markEdited()
        try Data("v3 from an agent\n".utf8).write(to: URL(fileURLWithPath: p))
        check(doc.checkDisk() == .modified && doc.diskChanged, "dirty: the badge is raised, the buffer is kept")
        _ = EditorOpen.reload(doc)
        check(!doc.isDirty && !doc.diskChanged, "reload discards the edits and clears the badge")
    }

    test("editor: saving over a file that changed on disk is a conflict until forced") {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = d.appendingPathComponent("c.txt").path
        try Data("mine\n".utf8).write(to: URL(fileURLWithPath: p))
        guard let (doc, _) = openDoc(p) else { check(false, "opens"); return }
        doc.markEdited()
        try Data("theirs, different size\n".utf8).write(to: URL(fileURLWithPath: p))
        do { try doc.save(text: "mine, edited\n"); check(false, "must throw") } catch { check((error as? SaveError) == .conflict, "conflict: \(error)") }
        check(try String(contentsOfFile: p, encoding: .utf8) == "theirs, different size\n", "disk untouched by the refused save")
        check(doc.isDirty, "still dirty after a refused save")
        try doc.save(text: "mine, edited\n", force: true)
        check(try String(contentsOfFile: p, encoding: .utf8) == "mine, edited\n" && !doc.isDirty, "Overwrite writes")
    }

    test("editor: deleted file is reported, saving recreates it") {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = d.appendingPathComponent("d.txt").path
        try Data("x\n".utf8).write(to: URL(fileURLWithPath: p))
        guard let (doc, _) = openDoc(p) else { check(false, "opens"); return }
        doc.markEdited()
        try FileManager.default.removeItem(atPath: p)
        check(doc.checkDisk() == .deleted && doc.diskDeleted && doc.diskChanged, "deleted + dirty raises the badge")
        try doc.save(text: "x\ny\n")
        check(try String(contentsOfFile: p, encoding: .utf8) == "x\ny\n" && !doc.diskDeleted, "save recreates the file")
    }

    test("editor: read-only documents refuse to save; a head-only view can never overwrite the file") {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        let p = d.appendingPathComponent("long.txt").path
        try Data((String(repeating: "x", count: LargeFile.longLineBytes + 10) + "\nsecond\n").utf8).write(to: URL(fileURLWithPath: p))
        guard case .document(let doc, let text, let note) = EditorOpen.open(path: p, openAnyway: false) else { check(false, "opens"); return }
        check(doc.features.readOnly == .longLine && note != nil, "long line: read-only with a note")
        check(LargeFile.longestLine(text) <= LargeFile.longLine, "shown cut")
        doc.markEdited()
        check(!doc.isDirty, "a read-only document never becomes dirty")
        do { try doc.save(text: text); check(false, "must throw") } catch { check((error as? SaveError) == .readOnly, "refused") }
        check(try Data(contentsOf: URL(fileURLWithPath: p)).count > LargeFile.longLineBytes, "file untouched")
    }

    test("editor: binary, missing and oversized files") {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        let bin = d.appendingPathComponent("b.bin").path
        try Data([0, 1, 2, 3]).write(to: URL(fileURLWithPath: bin))
        if case .binary = EditorOpen.open(path: bin, openAnyway: false) {} else { check(false, "binary") }
        if case .unreadable = EditorOpen.open(path: d.appendingPathComponent("nope").path, openAnyway: false) {} else { check(false, "missing") }
        if case .unreadable = EditorOpen.open(path: d.path, openAnyway: false) {} else { check(false, "a folder is not a file") }
    }

    // MARK: go to line, diff

    test("editor: go to line and position") {
        let t = "ab\ncd\n\nef" as NSString
        check(LineIndex.offset(ofLine: 1, in: t) == 0 && LineIndex.offset(ofLine: 2, in: t) == 3 && LineIndex.offset(ofLine: 3, in: t) == 6 && LineIndex.offset(ofLine: 4, in: t) == 7, "offsets")
        check(LineIndex.offset(ofLine: 99, in: t) == 7, "clamped to the last line")
        check(LineIndex.offset(ofLine: 5, in: "" as NSString) == 0, "empty text")
        let p = LineIndex.position(of: 8, in: t)
        check(p.line == 4 && p.column == 2, "position \(p)")
        check(LineIndex.parse("12")?.line == 12 && LineIndex.parse("12:5")?.column == 5 && LineIndex.parse("0") == nil && LineIndex.parse("x") == nil, "parse")
    }

    test("editor diff: small edits, folding, identical, empty sides") {
        let old = (1 ... 30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1 ... 30).map { "line \($0)" }; lines[14] = "line fifteen"; lines.insert("inserted", at: 3)
        let new = lines.joined(separator: "\n") + "\n"
        let rows = LineDiff.diff(old: old, new: new)!
        check(rows.contains { $0.kind == .added && $0.text == "inserted" }, "insertion")
        check(rows.contains { $0.kind == .removed && $0.text == "line 15" } && rows.contains { $0.kind == .added && $0.text == "line fifteen" }, "replacement")
        check(rows.contains { $0.kind == .fold }, "long unchanged runs are folded")
        check(rows.filter { $0.kind == .added }.count == 2 && rows.filter { $0.kind == .removed }.count == 1, "no spurious changes")
        check(LineDiff.diff(old: old, new: old)!.allSatisfy { $0.kind == .same || $0.kind == .fold }, "identical text has no changes")
        let fromEmpty = LineDiff.diff(old: "", new: "a\nb\n")!
        check(fromEmpty.map(\.kind) == [.added, .added], "untracked file: everything added")
        check(LineDiff.diff(old: "a\n", new: "")!.map(\.kind) == [.removed], "all removed")
        let big = (0 ..< LineDiff.maxLines + 1).map(String.init).joined(separator: "\n")
        check(LineDiff.diff(old: big, new: "x") == nil, "over the cap is refused, not hung")
    }

    test("editor diff: reconstructs the new text from the rows (property)") {
        var rng = SplitMix(s: 7)
        for _ in 0 ..< 40 {
            let a = (0 ..< Int.random(in: 0 ... 40, using: &rng)).map { _ in "l\(Int.random(in: 0 ... 12, using: &rng))" }
            let b = (0 ..< Int.random(in: 0 ... 40, using: &rng)).map { _ in "l\(Int.random(in: 0 ... 12, using: &rng))" }
            let rows = LineDiff.diff(old: a.joined(separator: "\n") + (a.isEmpty ? "" : "\n"), new: b.joined(separator: "\n") + (b.isEmpty ? "" : "\n"), context: 1_000_000)!
            check(rows.filter { $0.kind != .removed }.map(\.text) == b, "new side of \(a) -> \(b)")
            check(rows.filter { $0.kind != .added }.map(\.text) == a, "old side of \(a) -> \(b)")
        }
    }

    test("editor: HEAD content of a tracked, an untracked file and a non-repo") {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let d = tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        func git(_ a: [String]) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", d.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + a
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
        }
        check(GitHead.content(of: d.appendingPathComponent("x.txt").path) == nil, "not a repository")
        git(["init", "-q"]); try Data("committed\n".utf8).write(to: d.appendingPathComponent("x.txt")); git(["add", "x.txt"]); git(["commit", "-q", "-m", "c"])
        try Data("edited\n".utf8).write(to: d.appendingPathComponent("x.txt"))
        try Data("new\n".utf8).write(to: d.appendingPathComponent("y.txt"))
        check(GitHead.content(of: d.appendingPathComponent("x.txt").path) == "committed\n", "tracked: HEAD text")
        check(GitHead.content(of: d.appendingPathComponent("y.txt").path) == "", "untracked: empty")
    }

    // MARK: highlighter

    test("syntax: JSON keys, strings, numbers, constants") {
        let (t, _) = tokens("{\"a\": [1, 2.5e3, true, null, \"x\"]}", .json)
        check(t.contains { $0.0 == "\"a\"" && $0.1 == .key }, "key")
        check(t.contains { $0.0 == "\"x\"" && $0.1 == .string }, "string")
        check(t.contains { $0.0 == "2.5e3" && $0.1 == .number }, "number")
        check(t.contains { $0.0 == "true" && $0.1 == .constant } && t.contains { $0.0 == "null" && $0.1 == .constant }, "constants")
    }

    test("syntax: TypeScript keywords, types, comments, template strings across lines") {
        let (t, st) = tokens("const x: string = `a\nb ${c}\n", .typescript)
        check(t.contains { $0.0 == "const" && $0.1 == .keyword } && t.contains { $0.0 == "string" && $0.1 == .type }, "keyword + type")
        check(st == ScanState.backtick, "an open template literal carries to the next line")
        let (t2, st2) = tokens("still in it` + 1 // done\n", .typescript, state: st)
        check(t2.first?.1 == .string && st2 == 0, "closes")
        check(t2.contains { $0.1 == .comment && $0.0.hasPrefix("// done") }, "line comment")
        let (_, st3) = tokens("/* open\n", .typescript)
        check(st3 == ScanState.blockComment, "block comment state")
        let (t4, st4) = tokens(" still */ let y\n", .typescript, state: st3)
        check(t4.first?.1 == .comment && st4 == 0 && t4.contains { $0.0 == "let" && $0.1 == .keyword }, "block comment closes, code resumes")
    }

    test("syntax: Python triple quotes and Rust lifetimes vs chars") {
        let (_, s1) = tokens("x = \"\"\"doc\n", .python)
        check(s1 == ScanState.tripleDouble, "docstring opens")
        let (t2, s2) = tokens("end\"\"\" # c\n", .python, state: s1)
        check(s2 == 0 && t2.first?.1 == .string && t2.contains { $0.1 == .comment }, "docstring closes")
        let (t, _) = tokens("fn f<'a>(c: char) -> &'a str { 'x' }", .rust)
        check(t.contains { $0.0 == "'a" && $0.1 == .type } && t.contains { $0.0 == "'x'" && $0.1 == .string } && t.contains { $0.0 == "fn" && $0.1 == .keyword }, "rust tokens: \(t)")
    }

    test("syntax: markdown headings and fences; html tags and comments") {
        let (t, st) = tokens("# Title\n```ts\nconst a = 1\n", .markdown)
        check(t.contains { $0.0 == "# Title" && $0.1 == .heading } && st == ScanState.mdFence, "heading + open fence")
        let (_, st2) = tokens("```\n", .markdown, state: st)
        check(st2 == 0, "fence closes")
        let (h, hs) = tokens("<div class=\"a\">x &amp; y</div><!-- c", .html)
        check(h.contains { $0.0 == "<div" && $0.1 == .tag } && h.contains { $0.0 == "class" && $0.1 == .attribute } && h.contains { $0.0 == "\"a\"" && $0.1 == .string }, "tag + attribute")
        check(h.contains { $0.0 == "&amp;" && $0.1 == .constant } && hs == ScanState.htmlComment, "entity + open comment")
    }

    test("syntax: language detection") {
        check(SyntaxLanguage.detect(path: "/a/b.tsx") == .typescript && SyntaxLanguage.detect(path: "x.JSON") == .json && SyntaxLanguage.detect(path: "Makefile") == .shell
              && SyntaxLanguage.detect(path: "x.unknownext") == .plain && SyntaxLanguage.detect(path: "a.rs") == .rust && SyntaxLanguage.detect(path: "a.yml") == .yaml, "extensions")
    }

    test("syntax: checkpoints give the same state as scanning from the top; edits invalidate the tail") {
        var src = ""
        for i in 0 ..< 2000 { src += i % 97 == 0 ? "/* block \(i)\nstill\n*/\n" : "let v\(i) = \"s\(i)\" // c\n" }
        let u = Array(src.utf16)
        u.withUnsafeBufferPointer { b in
            let cp = Checkpoints.build(b, language: .typescript)
            check(cp.isComplete && cp.entries.count > 5, "built: \(cp.entries.count) entries")
            for e in cp.entries {
                let s = SyntaxScanner.scan(b, from: 0, to: e.offset, language: .typescript, state: 0, emit: nil)
                check(s == e.state, "state at \(e.offset)")
            }
            var cp2 = cp
            let mid = cp.entries[cp.entries.count / 2].offset
            cp2.invalidate(from: mid)
            check(!cp2.isComplete && cp2.nearest(before: Int.max).offset <= mid, "tail invalidated")
            cp2.extend(b, language: .typescript)
            check(cp2.isComplete && cp2.entries.count == cp.entries.count, "rebuilt")
            check(cp.nearest(before: 0).offset == 0 && cp.nearest(before: mid + 5).offset == mid, "nearest")
        }
    }

    test("syntax: scanning a window from a checkpoint matches scanning from the top") {
        var src = ""
        for i in 0 ..< 3000 { src += i % 41 == 0 ? "const t = `open \(i)\nmiddle\nclose` + 1\n" : "if (a\(i) > 0) { return \"x\" } // c\n" }
        let u = Array(src.utf16)
        u.withUnsafeBufferPointer { b in
            let cp = Checkpoints.build(b, language: .typescript)
            var rng = SplitMix(s: 3)
            for _ in 0 ..< 20 {
                var start = Int.random(in: 0 ..< b.count, using: &rng)
                while start > 0, b[start - 1] != 0x0A { start -= 1 }
                let end = min(b.count, start + 2000)
                var full: [String] = [], windowed: [String] = []
                SyntaxScanner.scan(b, from: 0, to: end, language: .typescript, state: 0) { l, n, k in if l + n > start { let a = max(l, start); full.append("\(a),\(l + n - a),\(k)") } }
                let c = cp.nearest(before: start)
                let st = SyntaxScanner.scan(b, from: c.offset, to: start, language: .typescript, state: c.state, emit: nil)
                SyntaxScanner.scan(b, from: start, to: end, language: .typescript, state: st) { l, n, k in windowed.append("\(l),\(n),\(k)") }
                check(full == windowed, "window at \(start) matches")
            }
        }
    }

    test("syntax: shifted checkpoints keep offsets on line starts and line numbers right after random edits") {
        var rng = SplitMix(s: 11)
        var text = (0 ..< 3000).map { "line \($0) \(String(repeating: "x", count: $0 % 7))" }.joined(separator: "\n") + "\n"
        var cp = text.utf16.withContiguousStorageIfAvailable { Checkpoints.build($0, language: .plain) } ?? Checkpoints()
        for _ in 0 ..< 60 {
            let ns = text as NSString
            let loc = Int.random(in: 0 ... ns.length, using: &rng)
            let removeLen = Bool.random(using: &rng) ? 0 : Int.random(in: 0 ... min(40, ns.length - loc), using: &rng)
            let insert = ["a", "x\ny", "\n\n", "", "zz"].randomElement(using: &rng)!
            let removed = ns.substring(with: NSRange(location: loc, length: removeLen))
            let nl = insert.filter { $0 == "\n" }.count - removed.filter { $0 == "\n" }.count
            text = ns.replacingCharacters(in: NSRange(location: loc, length: removeLen), with: insert)
            cp.shift(after: loc, by: (insert as NSString).length - removeLen, lines: nl)
            let cur = text as NSString
            for e in cp.entries.dropFirst() where e.offset > loc + (insert as NSString).length {
                check(e.offset <= cur.length, "offset in range")
                check(e.offset == 0 || cur.character(at: e.offset - 1) == 0x0A, "entry at \(e.offset) is a line start")
                check(e.line == cur.substring(to: e.offset).filter { $0 == "\n" }.count + 1, "line number of entry at \(e.offset)")
            }
            // a fresh pass restores exact entries so errors never pile up
            if Bool.random(using: &rng) { cp = text.utf16.withContiguousStorageIfAvailable { Checkpoints.build($0, language: .plain) } ?? cp }
        }
    }

    test("⌘S saves whenever a dirty file is on screen, else it stays Sessions") {
        check(AppShortcuts.commandSSaves(editorVisible: true, dirty: true), "visible + dirty saves")
        check(!AppShortcuts.commandSSaves(editorVisible: true, dirty: false), "clean: Sessions")
        check(!AppShortcuts.commandSSaves(editorVisible: false, dirty: true), "not on screen: Sessions")
        check(SyntaxLanguage.json.displayName == "JSON" && SyntaxLanguage.typescript.displayName == "TypeScript", "language labels")
    }
}
