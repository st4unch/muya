// Pure file-side logic (Foundation only, so the unit tests cover it): the lazy tree model, the
// FSEvents debounce, path actions (rename / trash / copy path), file-kind detection and the
// Markdown block parser the native viewer renders from.

import Foundation

// MARK: Tree model

/// One row of the file tree. A class: NSOutlineView needs stable identities.
final class FileNode {
    let url: URL
    let name: String
    let isDirectory: Bool
    var ignored = false
    /// nil = not loaded yet (lazy); loaded on first expand.
    private(set) var children: [FileNode]?

    init(url: URL, isDirectory: Bool, ignored: Bool = false) {
        self.url = url
        name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.ignored = ignored
    }

    var path: String { url.path }
    var isLoaded: Bool { children != nil }

    func setChildren(_ c: [FileNode]) { children = c }
    func unload() { children = nil }
}

enum FileTreeModel {
    /// Lists one directory: folders first, then files, each group sorted like Finder (case-insensitive, numeric-aware).
    /// Hidden = dot-files; they are dropped unless `showHidden`.
    static func list(_ dir: URL, showHidden: Bool, ignored: Set<String> = []) -> [FileNode] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var nodes: [FileNode] = []
        for n in names {
            if !showHidden && n.hasPrefix(".") { continue }
            let url = dir.appendingPathComponent(n)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            nodes.append(FileNode(url: url, isDirectory: isDir.boolValue, ignored: ignored.contains(n)))
        }
        return sorted(nodes)
    }

    static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Reloads `node`'s children after a change on disk, keeping the existing node objects (and their
    /// loaded sub-trees) for entries that are still there. Returns what changed.
    @discardableResult
    static func refresh(_ node: FileNode, showHidden: Bool, ignored: Set<String> = []) -> (added: [String], removed: [String]) {
        guard node.isDirectory, let old = node.children else { return ([], []) }
        let fresh = list(node.url, showHidden: showHidden, ignored: ignored)
        let oldByName = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [FileNode] = []
        var added: [String] = []
        for f in fresh {
            if let existing = oldByName[f.name], existing.isDirectory == f.isDirectory {
                existing.ignored = f.ignored
                merged.append(existing)
            } else {
                merged.append(f); added.append(f.name)
            }
        }
        let freshNames = Set(fresh.map(\.name))
        let removed = old.map(\.name).filter { !freshNames.contains($0) }
        node.setChildren(merged)
        return (added, removed)
    }

    /// The deepest loaded directory node that contains `path`, for routing a changed path to the node to refresh.
    static func owner(of path: String, in root: FileNode) -> FileNode? {
        let dir = (path as NSString).deletingLastPathComponent
        return find(dir, in: root)
    }

    static func find(_ dir: String, in node: FileNode) -> FileNode? {
        if node.path == dir { return node }
        guard node.isDirectory, dir.hasPrefix(node.path == "/" ? "/" : node.path + "/"), let kids = node.children else { return nil }
        for k in kids where k.isDirectory { if let r = find(dir, in: k) { return r } }
        return nil
    }
}

// MARK: FSEvents debounce

/// Collects changed paths and says when to flush: `interval` after the first event of a burst, so a
/// `git checkout` that touches 500 files makes one reload, and the latency to the UI stays bounded
/// (first event + interval), unlike a trailing-edge debounce that a steady stream can starve.
struct EventCoalescer {
    let interval: TimeInterval
    private(set) var pending = Set<String>()
    private(set) var firstAt: TimeInterval?

    init(interval: TimeInterval) { self.interval = interval }

    mutating func add(_ paths: [String], now: TimeInterval) {
        if pending.isEmpty { firstAt = now }
        pending.formUnion(paths)
    }

    /// Seconds until the pending batch is due (nil = nothing pending).
    func due(now: TimeInterval) -> TimeInterval? { firstAt.map { max(0, $0 + interval - now) } }

    mutating func flush(now: TimeInterval) -> Set<String>? {
        guard let d = due(now: now), d <= 0 else { return nil }
        let out = pending
        pending = []; firstAt = nil
        return out
    }
}

// MARK: Path actions

enum PathActionError: Error, Equatable, CustomStringConvertible {
    case emptyName, invalidName, exists(String), missing, outside
    var description: String {
        switch self {
        case .emptyName: return "The name is empty."
        case .invalidName: return "A name cannot contain “/” or “:”."
        case .exists(let n): return "“\(n)” already exists here."
        case .missing: return "The item no longer exists."
        case .outside: return "The item is outside the opened folder."
        }
    }
}

enum PathActions {
    /// Validates a new file name for a rename. Returns the destination URL.
    static func renameTarget(of url: URL, to newName: String) throws -> URL {
        let n = newName.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { throw PathActionError.emptyName }
        if n.contains("/") || n.contains(":") || n == "." || n == ".." { throw PathActionError.invalidName }
        let dest = url.deletingLastPathComponent().appendingPathComponent(n)
        if n != url.lastPathComponent, FileManager.default.fileExists(atPath: dest.path) { throw PathActionError.exists(n) }
        return dest
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let dest = try renameTarget(of: url, to: newName)
        if dest == url { return url }
        guard FileManager.default.fileExists(atPath: url.path) else { throw PathActionError.missing }
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    /// Moves to the Trash (never a hard delete). Returns where it landed.
    @discardableResult
    static func trash(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { throw PathActionError.missing }
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
    }

    /// The directory a "new session here" starts in: the folder itself, or a file's parent.
    static func terminalDirectory(for url: URL, isDirectory: Bool) -> String {
        isDirectory ? url.path : url.deletingLastPathComponent().path
    }

    /// Whether `path` is inside `root` (or is `root`): the guard for every action the tree offers.
    static func isInside(_ path: String, root: String) -> Bool {
        let r = (root as NSString).standardizingPath, p = (path as NSString).standardizingPath
        return p == r || p.hasPrefix(r == "/" ? "/" : r + "/")
    }
}

// MARK: Large files

/// Large-file policy for the viewer. The SIZE thresholds are the SAME as the Tauri app's
/// (src/lib/largeFile.ts: LARGE_BYTES / PROMPT_BYTES / HEAD_BYTES / MD_RENDER_MAX) — change them together.
/// They come from measurements (native/app/measure-largefile.sh, docs/large-file-measurements.md):
/// NSTextView lays out lazily, so 100 MB of JSON/log/TS opens in < 0.7 s and scrolls in < 20 ms.
enum LargeFile {
    static let largeBytes = 50 * 1_048_576
    static let promptBytes = 128 * 1_048_576
    /// What "Open Anyway" reads of a file over `promptBytes` (read-only).
    static let headBytes = 16 * 1_048_576
    /// Rendered Markdown costs ~0.75 s per MB on the main thread here (1 MB = 0.8 s, 4 MB = 2.9 s).
    static let markdownRenderMax = 1 * 1_048_576
    /// A single line longer than this is broken for display (the viewer is read-only). NSTextView
    /// lays one line out in ~2 s per MB and worse beyond that (1 MB = 13 s, 5 MB = 70 s); up to
    /// 200 KB it costs < 0.4 s. Native-specific (Monaco's limit is 2 MB): it is engine-bound.
    static let longLineBytes = 200_000
    /// Where a broken line is cut.
    static let longLine = 2_000

    enum Mode: Equatable {
        case normal   // as before
        case large    // plain text (no Markdown rendering), long lines broken
        case prompt   // too big to load unasked
        case binary   // never shown as text
    }

    static func decide(size: Int, binary: Bool, markdown: Bool) -> Mode {
        if binary { return .binary }
        if size > promptBytes { return .prompt }
        if size >= largeBytes { return .large }
        if markdown && size > markdownRenderMax { return .large }
        return .normal
    }

    /// Breaks every line longer than `limit` bytes into pieces (never inside a UTF-8 character).
    static func breakLongLines(_ s: String, limit: Int = longLine) -> String {
        var out = [UInt8](); out.reserveCapacity(s.utf8.count + s.utf8.count / limit + 16)
        var run = 0
        for b in s.utf8 {
            if b == 0x0A { run = 0; out.append(b); continue }
            if run >= limit && (b & 0xC0) != 0x80 { out.append(0x0A); run = 0 }
            out.append(b); run += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Length in bytes of the longest line.
    static func longestLine(_ s: String) -> Int {
        var best = 0, run = 0
        for b in s.utf8 { if b == 0x0A { best = max(best, run); run = 0 } else { run += 1 } }
        return max(best, run)
    }

    static func lineCount(_ s: String) -> Int { s.utf8.reduce(into: 1) { if $1 == 0x0A { $0 += 1 } } }
}

// MARK: File kinds

enum FileKind: Equatable {
    case image, pdf, markdown, text, other

    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "icns", "ico"]

    /// Kind from the extension, then (for unknown extensions) from the first bytes: text if valid UTF-8 without NULs.
    static func detect(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if imageExt.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if ext == "md" || ext == "markdown" { return .markdown }
        guard let h = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 8192)) ?? Data()
        return looksLikeText(head) ? .text : .other
    }

    static func looksLikeText(_ d: Data) -> Bool {
        if d.isEmpty { return true }
        if d.contains(0) { return false }
        if String(data: d, encoding: .utf8) != nil { return true }
        // A multi-byte character may be cut at the end of the sample: allow up to 3 trailing bytes to be dropped.
        for cut in 1 ... 3 where d.count > cut { if String(data: d.dropLast(cut), encoding: .utf8) != nil { return true } }
        return false
    }
}

// MARK: Markdown blocks

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(depth: Int, text: String)
    case numbered(depth: Int, number: Int, text: String)
    case code(language: String, text: String)
    case quote(String)
    case rule
}

enum MarkdownParser {
    /// A small block parser (headings, lists, fenced code, quotes, rules, paragraphs). Inline styling is left
    /// to `AttributedString(markdown:)` when rendering; this only decides the block structure.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var para: [String] = []
        var code: (lang: String, lines: [String])?
        var quote: [String] = []

        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        func flushQuote() { if !quote.isEmpty { out.append(.quote(quote.joined(separator: " "))); quote = [] } }

        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if var c = code {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    out.append(.code(language: c.lang, text: c.lines.joined(separator: "\n"))); code = nil
                } else { c.lines.append(raw); code = c }
                continue
            }
            let line = raw
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flushPara(); flushQuote()
                code = (String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                continue
            }
            if t.isEmpty { flushPara(); flushQuote(); continue }
            if t.hasPrefix(">") {
                flushPara()
                quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            if let h = heading(t) { flushPara(); out.append(h); continue }
            if t.count >= 3, Set(t).isSubset(of: ["-", "*", "_"]), Set(t).count == 1 { flushPara(); out.append(.rule); continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let b = listItem(t, depth: indent / 2) { flushPara(); out.append(b); continue }
            para.append(t)
        }
        if let c = code { out.append(.code(language: c.lang, text: c.lines.joined(separator: "\n"))) } // unterminated fence
        flushPara(); flushQuote()
        return out
    }

    private static func heading(_ t: String) -> MarkdownBlock? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1 ... 6).contains(hashes), t.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: String(t.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ t: String, depth: Int) -> MarkdownBlock? {
        for m in ["- ", "* ", "+ "] where t.hasPrefix(m) { return .bullet(depth: depth, text: String(t.dropFirst(2))) }
        let digits = t.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9, t.dropFirst(digits.count).hasPrefix(". "), let n = Int(digits) {
            return .numbered(depth: depth, number: n, text: String(t.dropFirst(digits.count + 2)))
        }
        return nil
    }
}
