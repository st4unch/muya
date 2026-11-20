// Tests for Sources/Logic/FileLogic.swift: tree model, watcher debounce, path actions, file kinds, Markdown.

import Foundation

private func tempDir() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muya-filetests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func touch(_ url: URL, _ text: String = "") { try? Data(text.utf8).write(to: url) }

func runFileTests() {
    test("tree: folders first, Finder-style order, hidden files toggle") {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        for n in ["b.txt", "a.txt", "file10.txt", "file2.txt", ".hidden"] { touch(d.appendingPathComponent(n)) }
        for n in ["zdir", "Adir"] { try FileManager.default.createDirectory(at: d.appendingPathComponent(n), withIntermediateDirectories: true) }
        let shown = FileTreeModel.list(d, showHidden: false).map(\.name)
        check(shown == ["Adir", "zdir", "a.txt", "b.txt", "file2.txt", "file10.txt"], "order \(shown)")
        let all = FileTreeModel.list(d, showHidden: true).map(\.name)
        check(all.contains(".hidden") && all.count == 7, "hidden shown: \(all)")
        check(FileTreeModel.list(d, showHidden: false).first?.isDirectory == true, "directory flag")
    }

    test("tree: lazy loading and refresh keeps loaded sub-trees") {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d.appendingPathComponent("sub"), withIntermediateDirectories: true)
        touch(d.appendingPathComponent("sub/inner.txt")); touch(d.appendingPathComponent("a.txt"))
        let root = FileNode(url: d, isDirectory: true)
        check(!root.isLoaded, "not loaded before first expand")
        root.setChildren(FileTreeModel.list(d, showHidden: false))
        let sub = root.children!.first { $0.name == "sub" }!
        check(!sub.isLoaded, "children of a collapsed directory stay unloaded")
        sub.setChildren(FileTreeModel.list(sub.url, showHidden: false))
        touch(d.appendingPathComponent("new.txt")); try FileManager.default.removeItem(at: d.appendingPathComponent("a.txt"))
        let r = FileTreeModel.refresh(root, showHidden: false)
        check(r.added == ["new.txt"] && r.removed == ["a.txt"], "diff \(r)")
        check(root.children!.first { $0.name == "sub" } === sub && sub.isLoaded, "same node object, still loaded")
        check(FileTreeModel.find(sub.path, in: root) === sub, "find loaded dir")
        check(FileTreeModel.find(d.path + "/nope", in: root) == nil, "find unknown dir")
        check(FileTreeModel.owner(of: sub.path + "/inner.txt", in: root) === sub, "owner of a file")
        check(FileTreeModel.find(d.path + "-x", in: root) == nil, "prefix-sibling is not inside")
    }

    test("watcher debounce: one flush per burst, bounded latency, paths merged") {
        var c = EventCoalescer(interval: 0.15)
        check(c.due(now: 0) == nil && c.flush(now: 0) == nil, "nothing pending")
        c.add(["/a"], now: 10.0)
        check(c.flush(now: 10.05) == nil, "not due yet")
        c.add(["/b", "/a"], now: 10.10)
        check(abs((c.due(now: 10.10) ?? -1) - 0.05) < 1e-9, "due counts from the FIRST event")
        let out = c.flush(now: 10.16)
        check(out == ["/a", "/b"], "merged \(String(describing: out))")
        check(c.pending.isEmpty && c.due(now: 11) == nil, "reset after flush")
        // A steady stream cannot starve the flush (leading-edge deadline).
        var s = EventCoalescer(interval: 0.15)
        var flushedAt: Double?
        for i in 0 ..< 100 {
            let t = Double(i) * 0.01
            s.add(["/x\(i)"], now: t)
            if flushedAt == nil, s.flush(now: t) != nil { flushedAt = t }
        }
        check((flushedAt ?? 9) <= 0.16, "flushed during the stream at \(flushedAt ?? -1)")
    }

    test("path actions: rename rules") {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let a = d.appendingPathComponent("a.txt"); touch(a, "A"); touch(d.appendingPathComponent("b.txt"))
        func err(_ n: String) -> PathActionError? { do { _ = try PathActions.renameTarget(of: a, to: n); return nil } catch { return error as? PathActionError } }
        check(err("") == .emptyName && err("   ") == .emptyName, "empty")
        check(err("x/y") == .invalidName && err("x:y") == .invalidName && err("..") == .invalidName, "invalid")
        check(err("b.txt") == .exists("b.txt"), "exists")
        check(err("a.txt") == nil, "same name is a no-op, not an error")
        let c = try PathActions.rename(a, to: "c.txt")
        check(c.lastPathComponent == "c.txt" && FileManager.default.fileExists(atPath: c.path) && !FileManager.default.fileExists(atPath: a.path), "renamed on disk")
        do { _ = try PathActions.rename(a, to: "d.txt"); check(false, "missing source should throw") } catch { check(error as? PathActionError == .missing, "missing") }
    }

    test("path actions: trash moves to the Trash, never deletes") {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("victim-\(UUID().uuidString).txt"); touch(f, "keep me")
        let landed = try PathActions.trash(f)
        check(!FileManager.default.fileExists(atPath: f.path), "gone from the folder")
        check(landed.map { FileManager.default.fileExists(atPath: $0.path) } == true, "still exists in the Trash")
        if let landed { try? FileManager.default.removeItem(at: landed) } // clean up our own test file
        do { _ = try PathActions.trash(f); check(false, "second trash should throw") } catch { check(error as? PathActionError == .missing, "missing") }
    }

    test("path actions: terminal directory, copy path, inside-root guard") {
        check(PathActions.terminalDirectory(for: URL(fileURLWithPath: "/p/q/file.rs"), isDirectory: false) == "/p/q", "file -> parent")
        check(PathActions.terminalDirectory(for: URL(fileURLWithPath: "/p/q"), isDirectory: true) == "/p/q", "dir -> itself")
        check(PathActions.isInside("/p/q/r", root: "/p/q") && PathActions.isInside("/p/q", root: "/p/q/"), "inside")
        check(!PathActions.isInside("/p/qq", root: "/p/q") && !PathActions.isInside("/p/q/../x", root: "/p/q"), "outside incl. .. and prefix siblings")
    }

    test("file kinds: by extension, then by content") {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        func kind(_ n: String, _ bytes: [UInt8]) -> FileKind { let u = d.appendingPathComponent(n); try? Data(bytes).write(to: u); return FileKind.detect(u) }
        check(kind("a.PNG", [1]) == .image && kind("a.jpeg", [1]) == .image, "images")
        check(kind("a.pdf", [1]) == .pdf, "pdf")
        check(kind("README.md", [1]) == .markdown, "markdown")
        check(kind("Makefile", Array("all:\n\techo ş\n".utf8)) == .text, "extensionless text")
        check(kind("blob.bin", [0, 1, 2, 0xff, 0xfe]) == .other, "binary with NULs")
        check(kind("latin.dat", [0xff, 0xfe, 0xfd]) == .other, "invalid UTF-8")
        check(kind("empty.xyz", []) == .text, "empty file is text")
        check(FileKind.looksLikeText(Data("日本語".utf8.dropLast(1))), "character cut at the sample end still counts as text")
    }

    test("markdown: block structure") {
        let md = """
        # Title
        Intro line one
        continues here.

        ## Sub *section*
        - first
          - nested
        * second
        1. one
        2. two

        ```swift
        let x = 1

        print(x)
        ```
        > quoted
        > more
        ---
        tail
        """
        let b = MarkdownParser.parse(md)
        check(b.first == .heading(level: 1, text: "Title"), "h1")
        check(b.contains(.paragraph("Intro line one continues here.")), "paragraph joins lines")
        check(b.contains(.heading(level: 2, text: "Sub *section*")), "h2 keeps inline markup for the renderer")
        check(b.contains(.bullet(depth: 0, text: "first")) && b.contains(.bullet(depth: 1, text: "nested")) && b.contains(.bullet(depth: 0, text: "second")), "bullets and depth")
        check(b.contains(.numbered(depth: 0, number: 1, text: "one")) && b.contains(.numbered(depth: 0, number: 2, text: "two")), "numbered")
        check(b.contains(.code(language: "swift", text: "let x = 1\n\nprint(x)")), "code block keeps blank lines")
        check(b.contains(.quote("quoted more")), "quote")
        check(b.contains(.rule), "rule")
        check(b.last == .paragraph("tail"), "tail")
        check(MarkdownParser.parse("#nospace") == [.paragraph("#nospace")], "# without a space is text")
        check(MarkdownParser.parse("```\nopen") == [.code(language: "", text: "open")], "unterminated fence")
        check(MarkdownParser.parse("") == [], "empty")
    }

    test("large files: thresholds are the Tauri app's (50 MB / 128 MB / 1 MB markdown), set by measurement") {
        let MB = 1_048_576
        check(LargeFile.decide(size: 0, binary: false, markdown: false) == .normal, "empty")
        for mb in [1, 3, 5, 10, 20, 49] { check(LargeFile.decide(size: mb * MB, binary: false, markdown: false) == .normal, "\(mb) MB opens normally") }
        check(LargeFile.decide(size: 50 * MB - 1, binary: false, markdown: false) == .normal, "just under 50 MB")
        check(LargeFile.decide(size: 50 * MB, binary: false, markdown: false) == .large, "50 MB")
        check(LargeFile.decide(size: 128 * MB, binary: false, markdown: false) == .large, "128 MB")
        check(LargeFile.decide(size: 128 * MB + 1, binary: false, markdown: false) == .prompt, "over 128 MB asks")
        check(LargeFile.decide(size: 500 * MB, binary: true, markdown: false) == .binary, "binary wins")
        check(LargeFile.decide(size: MB, binary: false, markdown: true) == .normal, "markdown at its limit renders")
        check(LargeFile.decide(size: MB + 1, binary: false, markdown: true) == .large, "markdown above it does not")
        check(LargeFile.decide(size: MB + 1, binary: false, markdown: false) == .normal, "plain text of that size is fine")
        check(LargeFile.headBytes == 16 * MB, "the head shown after Open Anyway")
    }

    test("large files: the longest line decides the long-line cut") {
        check(LargeFile.longestLine("") == 0, "empty")
        check(LargeFile.longestLine("abc") == 3, "no newline")
        check(LargeFile.longestLine("a\nbcd\ne\n") == 3, "middle line")
        check(LargeFile.longestLine("ş\n") == 2, "bytes, not characters")
        let ordinary = String(repeating: String(repeating: "x", count: 100) + "\n", count: 5000)
        check(LargeFile.longestLine(ordinary) < LargeFile.longLineBytes, "ordinary 500 KB file is not cut")
        check(LargeFile.longestLine(String(repeating: "x", count: LargeFile.longLineBytes + 1)) > LargeFile.longLineBytes, "one huge line is")
    }

    test("large files: long lines are broken on character boundaries, short ones untouched") {
        check(LargeFile.breakLongLines("a\nbb\n", limit: 5) == "a\nbb\n", "short lines")
        check(LargeFile.breakLongLines("abcdefghij", limit: 4) == "abcd\nefgh\nij", "plain ASCII")
        let tr = String(repeating: "ş", count: 10) // 2 bytes each
        let broken = LargeFile.breakLongLines(tr, limit: 5)
        check(broken.replacingOccurrences(of: "\n", with: "") == tr, "no character lost or split: \(broken.debugDescription)")
        check(LargeFile.lineCount("a\nb\nc") == 3, "line count")
    }
}
