// Terminal path links: detection (classic's regex and trim), resolution, kind, menu.

import Foundation

func runTerminalPathLinksTests() {
    typealias L = TerminalPathLinks
    func tok(_ row: String, _ col: Int) -> String? { L.token(row: row, column: col)?.text }

    test("path links: absolute, ~/, ./, ../ and bare a/b tokens are found") {
        check(tok("see /usr/local/bin now", 6) == "/usr/local/bin", "absolute")
        check(tok("open ~/Documents/x.txt", 8) == "~/Documents/x.txt", "home")
        check(tok("run ./build.sh", 5) == "./build.sh", "dot slash")
        check(tok("cd ../up/dir", 5) == "../up/dir", "dot dot slash")
        check(tok("edit src/main.rs ok", 6) == "src/main.rs", "bare relative")
        let t = L.token(row: "edit src/main.rs ok", column: 6)
        check(t?.startCol == 5 && t?.endCol == 15, "token columns are inclusive cell columns: \(String(describing: t))")
    }
    test("path links: trailing . , : ; ) ] are trimmed, inner ones stay") {
        check(tok("wrote /tmp/a.txt.", 8) == "/tmp/a.txt", "period")
        check(tok("wrote /tmp/a.txt, then", 8) == "/tmp/a.txt", "comma")
        check(tok("in /tmp/dir:", 5) == "/tmp/dir", "colon")
        check(tok("x /tmp/a/b)", 4) == "/tmp/a/b", "paren")
        check(tok("[/tmp/a/b]", 3) == "/tmp/a/b", "bracket")
        check(tok("x /tmp/a/b.,;", 4) == "/tmp/a/b", "several")
        check(tok("x /tmp/v1.2/f", 4) == "/tmp/v1.2/f", "inner dot stays")
        let t = L.token(row: "wrote /tmp/a.txt.", column: 8)
        check(t?.endCol == 15, "the trimmed dot is not part of the range: \(String(describing: t?.endCol))")
        check(L.token(row: "wrote /tmp/a.txt.", column: 16) == nil, "the trimmed dot is not a link cell")
    }
    test("path links: quotes, spaces, brackets and pipes end a token") {
        check(tok("\"/tmp/a b/c\"", 2) == "/tmp/a", "a space ends it")
        check(tok("'/tmp/q/x'", 3) == "/tmp/q/x", "single quotes")
        check(tok("\"/tmp/q/x\"", 3) == "/tmp/q/x", "double quotes")
        check(tok("(/tmp/p/q)", 3) == "/tmp/p/q", "parens")
        check(tok("<file>/tmp/p/q|x", 8) == "/tmp/p/q", "angle and pipe")
    }
    test("path links: only cells inside the token hit") {
        let row = "ab /tmp/x/y cd"
        check(L.token(row: row, column: 3)?.text == "/tmp/x/y", "first cell")
        check(L.token(row: row, column: 10)?.text == "/tmp/x/y", "last cell")
        check(L.token(row: row, column: 2) == nil, "the space before")
        check(L.token(row: row, column: 11) == nil, "the space after")
        check(L.token(row: row, column: 0) == nil, "a plain word")
        check(L.token(row: row, column: 99) == nil, "beyond the row")
        check(L.token(row: row, column: -1) == nil, "negative")
    }
    test("path links: an empty row, a row without a slash, a lone slash") {
        check(L.token(row: "", column: 0) == nil, "empty")
        check(L.token(row: "just words here", column: 2) == nil, "no slash")
        check(L.token(row: "a / b", column: 2) == nil, "a lone slash is not a path")
        check(L.token(row: "go folder/ now", column: 4) == nil, "classic: a bare name with a trailing slash only is not matched")
        check(L.token(row: "http://x.io/y", column: 7) != nil, "URLs are not special-cased: classic matches their tail, the stat then fails")
    }
    test("path links: foo.ts:42 stays one token (classic has no line:col; the stat then fails)") {
        check(tok("at src/foo.ts:42", 5) == "src/foo.ts:42", "kept whole")
        check(tok("at /tmp/foo.ts:42:7", 5) == "/tmp/foo.ts:42:7", "line and column kept")
        check(L.kind(ofPath: L.resolve("src/foo.ts:42", cwd: "/tmp", home: "/tmp")) == .none, "and it resolves to nothing")
    }
    test("path links: two tokens in one row, each with its own range") {
        let row = "cp /a/b /c/d"
        check(L.token(row: row, column: 4)?.text == "/a/b", "first")
        check(L.token(row: row, column: 9)?.text == "/c/d", "second")
    }
    test("path links: wide characters count two cells; the token range is in cells") {
        // "日" occupies cells 3-4 (spacer ""), the path starts at column 0
        let cells = ["/", "t", "/", "日", "", "x", " ", "z"]
        let t = L.token(cells: cells, column: 4)
        check(t?.text == "/t/日x" && t?.startCol == 0 && t?.endCol == 5, "spacer cell belongs to the token: \(String(describing: t))")
        check(L.token(cells: cells, column: 7) == nil, "a cell after the gap")
    }
    test("path links: resolve ~ against home and a relative token against the cwd") {
        check(L.resolve("~/a/b", cwd: "/w", home: "/h") == "/h/a/b", "home")
        check(L.resolve("./x", cwd: "/w", home: "/h") == "/w/./x", "dot slash joins on cwd")
        check(L.resolve("../x", cwd: "/w/v/", home: "/h") == "/w/v/../x", "no double slash")
        check(L.resolve("a/b", cwd: "/w", home: "/h") == "/w/a/b", "bare")
        check(L.resolve("/abs/p", cwd: "/w", home: "/h") == "/abs/p", "absolute stays")
        check(L.resolve("a/b", cwd: "", home: "/h") == "a/b", "no cwd")
    }
    test("path links: kind is file, dir or none from a real stat") {
        let d = NSTemporaryDirectory() + "pl-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d + "/sub", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: d + "/f.txt", contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: d) }
        check(L.kind(ofPath: d + "/f.txt") == .file, "file")
        check(L.kind(ofPath: d + "/sub") == .dir, "dir")
        check(L.kind(ofPath: d + "/nope") == .none, "missing")
        check(L.kind(ofPath: L.resolve("sub", cwd: d, home: "/")) == .dir, "relative to cwd")
        check(L.kind(ofPath: L.resolve("./f.txt", cwd: d, home: "/")) == .file, "./ relative to cwd")
        check(L.kind(ofPath: L.resolve("~/f.txt", cwd: "/", home: d)) == .file, "~ against the given home")
    }
    test("path links: the menu items and header match classic, in order") {
        check(L.menuTitles(for: .file) == ["Open in Muya", "Reveal in Finder", "Copy Path"], "file")
        check(L.menuTitles(for: .dir) == ["Open Terminal Here", "Reveal in Finder", "Copy Path"], "dir")
        check(L.menuTitles(for: .none).isEmpty, "none has no menu")
        check(L.header(path: "/a/b/c.txt", kind: .file) == "📄 c.txt", "file header")
        check(L.header(path: "/a/b", kind: .dir) == "📁 b", "dir header")
    }
    test("path links: the cache keys on cwd and token and is bounded") {
        var c = L.Cache()
        c["/a", "x/y"] = ("/a/x/y", .file)
        check(c["/a", "x/y"]?.kind == .file, "hit")
        check(c["/b", "x/y"] == nil, "another cwd is a miss")
        for i in 0 ..< L.Cache.limit + 5 { c["/c", "t\(i)"] = ("/p", .none) }
        check(c["/a", "x/y"] == nil, "cleared at the bound")
    }
}
