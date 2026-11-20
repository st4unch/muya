// The editor's model (Foundation only, so the unit tests cover it): how a file is decoded and written back
// (BOM, line endings), what a file of a given size may do (the large-file policy), the dirty / disk-change /
// conflict state machine, a line diff against git HEAD, and "go to line". The views (EditorPane.swift) only
// show what this decides.

import Foundation

// MARK: Encoding and line endings

public enum LineEnding: Equatable {
    case lf, crlf, cr
    public var string: String { self == .lf ? "\n" : self == .crlf ? "\r\n" : "\r" }
    public var label: String { self == .lf ? "LF" : self == .crlf ? "CRLF" : "CR" }
}

public enum TextEncoding: Equatable {
    case utf8, utf16LE, utf16BE
    public var label: String { self == .utf8 ? "UTF-8" : self == .utf16LE ? "UTF-16 LE" : "UTF-16 BE" }
}

public struct DecodedText {
    /// The text with every line ending turned into "\n" (what the text view edits).
    public var text: String
    public var eol: LineEnding
    public var bom: Bool
    public var encoding: TextEncoding
    /// More than one kind of line ending was found; saving writes the dominant one everywhere (as Monaco does).
    public var mixedEndings: Bool
}

public enum TextCodec {
    /// nil = not text we can edit: a NUL byte, or bytes that are not valid UTF-8 (classic's read_file refuses those too).
    public static func decode(_ data: Data) -> DecodedText? {
        var bytes = data
        var bom = false
        var enc = TextEncoding.utf8
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { bom = true; bytes = data.dropFirst(3) }
        else if data.starts(with: [0xFF, 0xFE]) { bom = true; enc = .utf16LE }
        else if data.starts(with: [0xFE, 0xFF]) { bom = true; enc = .utf16BE }
        var s: String
        if enc == .utf8 {
            if bytes.contains(0) { return nil }
            guard let t = String(data: bytes, encoding: .utf8) else { return nil }
            s = t
        } else {
            guard let t = String(data: data.dropFirst(2), encoding: enc == .utf16LE ? .utf16LittleEndian : .utf16BigEndian) else { return nil }
            s = t
            if s.utf8.contains(0) { return nil }
        }
        let (text, eol, mixed) = normalize(s)
        return DecodedText(text: text, eol: eol, bom: bom, encoding: enc, mixedEndings: mixed)
    }

    /// Counts line endings and rewrites them all to "\n". Skips the rewrite when there is no CR (the common case).
    static func normalize(_ s: String) -> (String, LineEnding, Bool) {
        var lf = 0, crlf = 0, cr = 0
        var hasCR = false
        s.utf8.withContiguousStorageIfAvailable { b in
            var i = 0; let n = b.count
            while i < n {
                let c = b[i]
                if c == 0x0A { lf += 1 }
                else if c == 0x0D { hasCR = true; if i + 1 < n, b[i + 1] == 0x0A { crlf += 1; i += 1 } else { cr += 1 } }
                i += 1
            }
        } ?? {
            for c in s.utf8 { if c == 0x0A { lf += 1 } else if c == 0x0D { hasCR = true; cr += 1 } }
        }()
        let bareLF = lf   // the LF of a CRLF is skipped above, so these are bare LFs only
        let kinds = [bareLF, crlf, cr].filter { $0 > 0 }.count
        let eol: LineEnding = crlf > bareLF && crlf >= cr ? .crlf : (cr > bareLF && cr > crlf ? .cr : .lf)
        guard hasCR else { return (s, .lf, false) }
        var out = [UInt8](); out.reserveCapacity(s.utf8.count)
        var prevCR = false
        for c in s.utf8 {
            if c == 0x0D { out.append(0x0A); prevCR = true; continue }
            if c == 0x0A, prevCR { prevCR = false; continue }
            prevCR = false; out.append(c)
        }
        return (String(decoding: out, as: UTF8.self), eol, kinds > 1)
    }

    /// The bytes to write: "\n" turned back into the file's own line ending, BOM and encoding kept.
    public static func encode(_ text: String, eol: LineEnding, bom: Bool, encoding: TextEncoding) -> Data {
        var body: String = text
        if eol != .lf, text.utf8.contains(0x0A) {
            var out = [UInt8](); out.reserveCapacity(text.utf8.count + text.utf8.count / 40)
            for c in text.utf8 {
                if c == 0x0A { out.append(contentsOf: Array(eol.string.utf8)) } else { out.append(c) }
            }
            body = String(decoding: out, as: UTF8.self)
        }
        switch encoding {
        case .utf8:
            var d = Data(); if bom { d.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            d.append(contentsOf: body.utf8); return d
        case .utf16LE:
            var d = Data(); if bom { d.append(contentsOf: [0xFF, 0xFE]) }
            d.append(body.data(using: .utf16LittleEndian) ?? Data()); return d
        case .utf16BE:
            var d = Data(); if bom { d.append(contentsOf: [0xFE, 0xFF]) }
            d.append(body.data(using: .utf16BigEndian) ?? Data()); return d
        }
    }
}

// MARK: Large-file policy

/// What the editor may do with a file. The SIZE thresholds are `LargeFile`'s (docs/large-file-measurements.md): up to
/// 50 MB every feature, to 128 MB plain but editable, above that a prompt, and a head-only view that is read-only.
public struct EditorFeatures: Equatable {
    public enum ReadOnlyReason: Equatable { case truncated, longLine, notWritable }
    public var highlight: Bool
    public var minimap: Bool
    public var diff: Bool
    public var readOnly: ReadOnlyReason?
    public var editable: Bool { readOnly == nil }

    public static func decide(size: Int, longestLine: Int, truncated: Bool, writable: Bool) -> EditorFeatures {
        let full = size < LargeFile.largeBytes
        var ro: ReadOnlyReason?
        if truncated { ro = .truncated }
        else if longestLine > LargeFile.longLineBytes { ro = .longLine }   // NSTextView lays a long line out at ~2 s / MB
        else if !writable { ro = .notWritable }
        // A long line is displayed cut, so highlighting a cut copy would be wrong; and a 1 MB line cannot be coloured cheaply.
        return EditorFeatures(highlight: full && ro != .longLine, minimap: full && ro != .longLine, diff: full && ro == nil, readOnly: ro)
    }
}

// MARK: Disk stamp, dirty state, conflicts

/// What the file looked like on disk when we last read or wrote it.
public struct DiskStamp: Equatable {
    public var size: Int
    public var mtimeNs: Int64
    public var inode: UInt64

    public static func of(_ path: String) -> DiskStamp? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let ns = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return DiskStamp(size: Int(st.st_size), mtimeNs: ns, inode: UInt64(st.st_ino))
    }
}

public enum DiskEvent: Equatable { case unchanged, modified, deleted }

public enum SaveError: Error, Equatable, CustomStringConvertible {
    case conflict      // the file changed on disk after we read it
    case readOnly
    case failed(String)
    public var description: String {
        switch self {
        case .conflict: return "The file changed on disk after it was opened."
        case .readOnly: return "This file is open read-only."
        case .failed(let m): return m
        }
    }
}

/// One open file's state. The text itself lives in the text view; this holds everything else.
public final class EditorDocument {
    public let path: String
    public private(set) var eol: LineEnding
    public private(set) var bom: Bool
    public private(set) var encoding: TextEncoding
    public private(set) var mixedEndings: Bool
    public private(set) var features: EditorFeatures
    public private(set) var stamp: DiskStamp?
    /// Edited since it was read or saved. Like Monaco's flag: any edit sets it, only save / reload clears it.
    public private(set) var isDirty = false
    /// The file changed on disk while the buffer had unsaved edits (or was deleted): the badge offers a reload.
    public private(set) var diskChanged = false
    public private(set) var diskDeleted = false
    public private(set) var size: Int

    public init(path: String, decoded: DecodedText, features: EditorFeatures, size: Int) {
        self.path = path; eol = decoded.eol; bom = decoded.bom; encoding = decoded.encoding
        mixedEndings = decoded.mixedEndings; self.features = features; self.size = size
        stamp = DiskStamp.of(path)
    }

    public func markEdited() { if features.editable { isDirty = true } }

    /// The disk was checked (FSEvents, app activation, before save): says what happened. The caller decides:
    /// `.modified` + clean → reload; `.modified` + dirty → the badge (this call sets it); `.deleted` → the badge.
    @discardableResult
    public func checkDisk() -> DiskEvent {
        guard let now = DiskStamp.of(path) else {
            if stamp != nil || !diskDeleted { diskDeleted = true; if isDirty { diskChanged = true } }
            return .deleted
        }
        diskDeleted = false
        if now == stamp { return .unchanged }
        if isDirty { diskChanged = true }
        return .modified
    }

    /// The buffer was replaced by what is on disk now.
    public func didReload(decoded: DecodedText, features: EditorFeatures, size: Int) {
        eol = decoded.eol; bom = decoded.bom; encoding = decoded.encoding; mixedEndings = decoded.mixedEndings
        self.features = features; self.size = size
        stamp = DiskStamp.of(path); isDirty = false; diskChanged = false; diskDeleted = false
    }

    /// Writes `text` back. `force` skips the conflict check (the user chose "Overwrite"). Atomic: a temp file in the same
    /// folder is renamed over the target, so a crash never leaves half a file; mode bits are kept and a symlink is followed.
    public func save(text: String, force: Bool = false) throws {
        guard features.editable else { throw SaveError.readOnly }
        if !force, let was = stamp, let now = DiskStamp.of(path), now != was { diskChanged = true; throw SaveError.conflict }
        let data = TextCodec.encode(text, eol: eol, bom: bom, encoding: encoding)
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let dir = target.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(target.lastPathComponent).muya-save-\(UInt32.random(in: 0 ... .max))")
        do {
            var mode: mode_t = 0o644
            var st = stat(); if stat(target.path, &st) == 0 { mode = st.st_mode & 0o7777 }
            try data.write(to: tmp)
            chmod(tmp.path, mode)
            if rename(tmp.path, target.path) != 0 { throw SaveError.failed(String(cString: strerror(errno))) }
        } catch let e as SaveError { try? FileManager.default.removeItem(at: tmp); throw e }
        catch { try? FileManager.default.removeItem(at: tmp); throw SaveError.failed(error.localizedDescription) }
        stamp = DiskStamp.of(path); size = data.count
        isDirty = false; diskChanged = false; diskDeleted = false
    }
}

/// Opens a file for the editor: the same safety probe the viewer used (never a FIFO or device), the size policy, decoding.
public enum EditorOpen {
    public enum Result {
        case document(EditorDocument, text: String, displayNote: String?)
        case prompt(size: Int)
        case binary
        case unreadable
    }

    /// Off the main thread.
    public static func open(path: String, openAnyway: Bool) -> Result {
        let url = URL(fileURLWithPath: path)
        guard let p = FileProbe.probe(url) else { return .unreadable }
        if p.binary { return .binary }
        if p.size > LargeFile.promptBytes, !openAnyway { return .prompt(size: p.size) }
        let limit = p.size > LargeFile.promptBytes ? LargeFile.headBytes : LargeFile.promptBytes
        guard var data = FileProbe.readHead(url, limit: limit) else { return .unreadable }
        let truncated = data.count > limit
        if truncated { data = data.prefix(limit) }
        guard let decoded = TextCodec.decode(data) else {
            // A multi-byte character cut by the head limit is fine; anything else is not text.
            if truncated { for cut in 1 ... 3 where data.count > cut { if let d = TextCodec.decode(data.dropLast(cut)) { return finish(path, d, p.size, true) } } }
            return .binary
        }
        return finish(path, decoded, p.size, truncated)
    }

    private static func finish(_ path: String, _ decoded: DecodedText, _ size: Int, _ truncated: Bool) -> Result {
        var d = decoded
        let longest = LargeFile.longestLine(d.text)
        let writable = access(path, W_OK) == 0
        let f = EditorFeatures.decide(size: size, longestLine: longest, truncated: truncated, writable: writable)
        var note: String?
        if f.readOnly == .longLine {
            d.text = LargeFile.breakLongLines(d.text)
            note = "a line of \(ByteCountFormatter.string(fromByteCount: Int64(longest), countStyle: .file)) is shown cut every \(LargeFile.longLine) characters, so this file is read-only"
        }
        let doc = EditorDocument(path: path, decoded: d, features: f, size: size)
        return .document(doc, text: d.text, displayNote: note)
    }

    /// Re-reads for a reload. nil = could not be read as text any more.
    public static func reload(_ doc: EditorDocument) -> (text: String, note: String?)? {
        guard case .document(let fresh, let text, let note) = open(path: doc.path, openAnyway: doc.features.readOnly == .truncated) else { return nil }
        doc.didReload(decoded: DecodedText(text: text, eol: fresh.eol, bom: fresh.bom, encoding: fresh.encoding, mixedEndings: fresh.mixedEndings), features: fresh.features, size: fresh.size)
        return (text, note)
    }
}

// MARK: Go to line

public enum LineIndex {
    /// UTF-16 offset of the start of 1-based `line` (clamped to the first / last line). "12:5" style columns are the caller's.
    public static func offset(ofLine line: Int, in text: NSString) -> Int {
        var l = 1, i = 0
        let n = text.length
        if line <= 1 { return 0 }
        while i < n {
            let r = text.range(of: "\n", options: .literal, range: NSRange(location: i, length: n - i))
            if r.location == NSNotFound { break }
            l += 1; i = r.location + 1
            if l == line { return i }
        }
        return n == 0 ? 0 : (text.character(at: n - 1) == 0x0A ? n : (text.lineRange(for: NSRange(location: n - 1, length: 0)).location))
    }

    /// 1-based line and column of a UTF-16 offset.
    public static func position(of offset: Int, in text: NSString) -> (line: Int, column: Int) {
        let o = min(max(offset, 0), text.length)
        var line = 1, i = 0
        while i < o {
            let r = text.range(of: "\n", options: .literal, range: NSRange(location: i, length: o - i))
            if r.location == NSNotFound { break }
            line += 1; i = r.location + 1
        }
        return (line, o - i + 1)
    }

    public static func parse(_ input: String) -> (line: Int, column: Int?)? {
        let parts = input.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard let l = parts.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), l >= 1 else { return nil }
        if parts.count > 1 { guard let c = Int(parts[1].trimmingCharacters(in: .whitespaces)), c >= 1 else { return nil }; return (l, c) }
        return (l, nil)
    }
}

// MARK: Diff against HEAD

public enum DiffRowKind: Equatable { case same, added, removed, fold }

public struct DiffRow: Equatable {
    public var kind: DiffRowKind
    public var text: String          // for .fold: "N unchanged lines"
    public var oldLine: Int?
    public var newLine: Int?
}

public enum LineDiff {
    /// Over this many lines on either side the diff is refused (the view says so): Myers is O(N·D) and the view draws every row.
    public static let maxLines = 150_000

    /// Whole-file diff, then unchanged runs longer than `2 * context` lines are folded to a single row.
    public static func diff(old: String, new: String, context: Int = 3) -> [DiffRow]? {
        let a = split(old), b = split(new)
        if a.count > maxLines || b.count > maxLines { return nil }
        guard let script = myers(a, b) else { return nil }
        var rows: [DiffRow] = []
        var i = 0, j = 0
        for op in script {
            switch op {
            case .keep: rows.append(DiffRow(kind: .same, text: a[i], oldLine: i + 1, newLine: j + 1)); i += 1; j += 1
            case .del: rows.append(DiffRow(kind: .removed, text: a[i], oldLine: i + 1, newLine: nil)); i += 1
            case .ins: rows.append(DiffRow(kind: .added, text: b[j], oldLine: nil, newLine: j + 1)); j += 1
            }
        }
        return fold(rows, context: context)
    }

    static func split(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private enum Op { case keep, del, ins }

    /// Myers' O(ND) shortest edit script. nil when D grows past a budget (two nearly unrelated huge files).
    private static func myers(_ a: [String], _ b: [String]) -> [Op]? {
        // Trim the common prefix and suffix first: the usual "one small edit in a big file" case costs O(N) only.
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let x = Array(a[pre ..< a.count - suf]), y = Array(b[pre ..< b.count - suf])
        let n = x.count, m = y.count
        var mid: [Op] = []
        if n == 0 { mid = Array(repeating: .ins, count: m) }
        else if m == 0 { mid = Array(repeating: .del, count: n) }
        else {
            let maxD = min(n + m, 4000)
            let off = maxD + 1
            var v = [Int](repeating: 0, count: 2 * maxD + 3)
            var trace: [[Int]] = []
            var found = -1
            outer: for d in 0 ... maxD {
                trace.append(v)
                var k = -d
                while k <= d {
                    var px: Int
                    if k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) { px = v[off + k + 1] } else { px = v[off + k - 1] + 1 }
                    var py = px - k
                    while px < n, py < m, x[px] == y[py] { px += 1; py += 1 }
                    v[off + k] = px
                    if px >= n, py >= m { found = d; break outer }
                    k += 2
                }
            }
            if found < 0 { return nil }
            var ops: [Op] = []
            var cx = n, cy = m
            var d = found
            while d > 0 {
                let vv = trace[d]
                let k = cx - cy
                let prevK: Int
                if k == -d || (k != d && vv[off + k - 1] < vv[off + k + 1]) { prevK = k + 1 } else { prevK = k - 1 }
                let prevX = vv[off + prevK], prevY = prevX - prevK
                while cx > prevX, cy > prevY { ops.append(.keep); cx -= 1; cy -= 1 }
                if cx == prevX { ops.append(.ins); cy -= 1 } else { ops.append(.del); cx -= 1 }
                d -= 1
            }
            while cx > 0, cy > 0 { ops.append(.keep); cx -= 1; cy -= 1 }
            mid = ops.reversed()
        }
        return Array(repeating: .keep, count: pre) + mid + Array(repeating: .keep, count: suf)
    }

    private static func fold(_ rows: [DiffRow], context: Int) -> [DiffRow] {
        var out: [DiffRow] = []
        var i = 0
        while i < rows.count {
            if rows[i].kind != .same { out.append(rows[i]); i += 1; continue }
            var j = i; while j < rows.count, rows[j].kind == .same { j += 1 }
            let run = j - i
            let head = i == 0 ? 0 : context, tail = j == rows.count ? 0 : context
            if run > head + tail + 1 {
                out.append(contentsOf: rows[i ..< i + head])
                out.append(DiffRow(kind: .fold, text: "\(run - head - tail) unchanged lines", oldLine: nil, newLine: nil))
                out.append(contentsOf: rows[(j - tail) ..< j])
            } else { out.append(contentsOf: rows[i ..< j]) }
            i = j
        }
        return out
    }
}

public enum GitHead {
    /// The file's text at HEAD, "" when the file is untracked / new (classic diffs those against empty), nil when git
    /// itself is unavailable or the folder is no repository.
    public static func content(of path: String, timeout: TimeInterval = 4) -> String? {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return nil }
        guard let inside = run(["-C", dir, "rev-parse", "--is-inside-work-tree"], timeout: timeout), String(decoding: inside.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return nil }
        guard let r = run(["-C", dir, "show", "HEAD:./" + url.lastPathComponent], timeout: timeout), r.status == 0 else { return "" }
        return String(decoding: r.out, as: UTF8.self)
    }

    private static func run(_ args: [String], timeout: TimeInterval) -> (out: Data, status: Int32)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.environment = ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C", "HOME": NSHomeDirectory()]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        var data = Data()
        let reader = DispatchQueue(label: "gitHead.read")
        let readDone = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        readDone.wait()
        return (data, p.terminationStatus)
    }
}
