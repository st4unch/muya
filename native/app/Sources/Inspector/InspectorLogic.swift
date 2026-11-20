// Inspector view models and parsers (Foundation only, unit-tested): git status, unified diffs,
// worktrees, and the Claude transcript events behind the Files and Activity tabs.
//
// INTERIM data access: the target design (PRD §7) is that muyad serves these through the protocol.
// Until it does, `InspectorSource` is the protocol-shaped seam and `LocalGitSource` (InspectorSource.swift)
// runs a local read-only `git`. Messages muyad would need are listed in the Faz 4-B summary.

import Foundation

// MARK: Git status

enum ChangeKind: Equatable { case staged, unstaged, untracked, conflicted }

struct GitChange: Equatable {
    var path: String
    var origPath: String?
    /// Index (staged) and worktree status letters of `git status --porcelain=v1`.
    var x: Character
    var y: Character

    var isConflicted: Bool {
        if x == "U" || y == "U" { return true }
        return (x == "A" && y == "A") || (x == "D" && y == "D")
    }
    var isUntracked: Bool { x == "?" && y == "?" }
    var kinds: [ChangeKind] {
        if isConflicted { return [.conflicted] }
        if isUntracked { return [.untracked] }
        var k: [ChangeKind] = []
        if x != " " { k.append(.staged) }
        if y != " " { k.append(.unstaged) }
        return k
    }
    /// One letter for the row badge: the worktree status when there is one, else the index status.
    var badge: String { isUntracked ? "U" : isConflicted ? "!" : String(y != " " ? y : x) }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { let d = (path as NSString).deletingLastPathComponent; return d }
}

struct GitStatus: Equatable {
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var detached = false
    var changes: [GitChange] = []

    var conflicts: [GitChange] { changes.filter(\.isConflicted) }

    /// `git status --porcelain=v1 -z -b` (NUL-separated; a rename carries its old path as the next field).
    static func parse(_ data: Data) -> GitStatus {
        var st = GitStatus()
        let fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < fields.count {
            let f = fields[i]; i += 1
            if f.hasPrefix("## ") { parseBranch(String(f.dropFirst(3)), into: &st); continue }
            let chars = Array(f)
            guard chars.count > 3, chars[2] == " " else { continue }
            var c = GitChange(path: String(chars[3...]), origPath: nil, x: chars[0], y: chars[1])
            if (chars[0] == "R" || chars[0] == "C" || chars[1] == "R" || chars[1] == "C"), i < fields.count { c.origPath = fields[i]; i += 1 }
            st.changes.append(c)
        }
        return st
    }

    private static func parseBranch(_ s: String, into st: inout GitStatus) {
        var s = s
        if s.hasPrefix("No commits yet on ") { st.branch = String(s.dropFirst(18)); return }
        if s.hasPrefix("HEAD (no branch)") { st.detached = true; st.branch = "HEAD"; return }
        if let r = s.range(of: " [", options: .backwards), s.hasSuffix("]") {
            let inner = s[r.upperBound...].dropLast()
            for part in inner.split(separator: ",") {
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("ahead ") { st.ahead = Int(p.dropFirst(6)) ?? 0 }
                if p.hasPrefix("behind ") { st.behind = Int(p.dropFirst(7)) ?? 0 }
            }
            s = String(s[..<r.lowerBound])
        }
        if let r = s.range(of: "...") {
            st.branch = String(s[..<r.lowerBound]); st.upstream = String(s[r.upperBound...])
        } else { st.branch = s }
    }
}

// MARK: Diff

struct DiffLine: Equatable {
    enum Kind: Equatable { case meta, hunk, context, add, del, note }
    var kind: Kind
    var text: String
    var oldNo: Int?
    var newNo: Int?
}

struct DiffResult: Equatable {
    var lines: [DiffLine] = []
    var added = 0
    var removed = 0
    var binary = false
    var truncated = false

    /// Added / removed counted from the lines themselves: what a header shows must match the body.
    var lineCounts: (added: Int, removed: Int) {
        (lines.reduce(0) { $0 + ($1.kind == .add ? 1 : 0) }, lines.reduce(0) { $0 + ($1.kind == .del ? 1 : 0) })
    }
}

enum DiffParser {
    /// Parses `git diff` output. Output larger than `maxLines` is cut (a huge generated file must not freeze the UI).
    static func parse(_ text: String, maxLines: Int = 5000) -> DiffResult {
        var r = DiffResult()
        var oldNo = 0, newNo = 0
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if r.lines.count >= maxLines { r.truncated = true; break }
            let line = String(raw)
            if line.hasPrefix("@@") {
                inHunk = true
                // @@ -a,b +c,d @@ section
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    oldNo = Int(parts[1].dropFirst().split(separator: ",")[0]) ?? 0
                    newNo = Int(parts[2].dropFirst().split(separator: ",")[0]) ?? 0
                }
                r.lines.append(DiffLine(kind: .hunk, text: line)); continue
            }
            if !inHunk {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { r.binary = true }
                if line.hasPrefix("diff --git") && !r.lines.isEmpty { inHunk = false }
                if !line.isEmpty { r.lines.append(DiffLine(kind: .meta, text: line)) }
                continue
            }
            if line.hasPrefix("diff --git") { inHunk = false; r.lines.append(DiffLine(kind: .meta, text: line)); continue }
            if line.hasPrefix("+") { r.lines.append(DiffLine(kind: .add, text: String(line.dropFirst()), oldNo: nil, newNo: newNo)); newNo += 1; r.added += 1 }
            else if line.hasPrefix("-") { r.lines.append(DiffLine(kind: .del, text: String(line.dropFirst()), oldNo: oldNo, newNo: nil)); oldNo += 1; r.removed += 1 }
            else if line.hasPrefix("\\") { r.lines.append(DiffLine(kind: .note, text: line)) }
            else if line.hasPrefix(" ") { r.lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldNo: oldNo, newNo: newNo)); oldNo += 1; newNo += 1 }
            else if line.isEmpty { continue }
            else { r.lines.append(DiffLine(kind: .meta, text: line)) }
        }
        return r
    }

    /// A diff of two texts (a branch file's merge-base side and its tip side), whole file with 3 lines of context.
    /// Line-based LCS; beyond `maxLines` per side the diff is cut (flagged `truncated`) rather than slow.
    static func fromPair(old: String, new: String, context: Int = 3, maxLines: Int = 5000) -> DiffResult {
        var r = DiffResult()
        if old.utf8.contains(0) || new.utf8.contains(0) { r.binary = true; return r }
        func split(_ t: String) -> [String] {
            var a = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if a.last == "" { a.removeLast() }
            return a
        }
        var a = split(old), b = split(new)
        if a.count > maxLines || b.count > maxLines { r.truncated = true; a = Array(a.prefix(maxLines)); b = Array(b.prefix(maxLines)) }
        // Trim the common head and tail so the table is only as big as the change.
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let ma = Array(a[head..<(a.count - tail)]), mb = Array(b[head..<(b.count - tail)])
        var ops: [(Character, String)] = a[0..<head].map { (" ", $0) }
        if ma.count * mb.count > 4_000_000 {
            ops += ma.map { ("-", $0) } + mb.map { ("+", $0) }; r.truncated = true
        } else {
            var t = [[Int32]](repeating: [Int32](repeating: 0, count: mb.count + 1), count: ma.count + 1)
            for i in stride(from: ma.count - 1, through: 0, by: -1) { for j in stride(from: mb.count - 1, through: 0, by: -1) {
                t[i][j] = ma[i] == mb[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            } }
            var i = 0, j = 0
            while i < ma.count || j < mb.count {
                if i < ma.count, j < mb.count, ma[i] == mb[j] { ops.append((" ", ma[i])); i += 1; j += 1 }
                else if j < mb.count, i == ma.count || t[i][j + 1] >= t[i + 1][j] { ops.append(("+", mb[j])); j += 1 }
                else { ops.append(("-", ma[i])); i += 1 }
            }
        }
        ops += a[(a.count - tail)...].map { (" ", $0) }
        // Numbers, then keep only changed lines and their context.
        var oldNo = 1, newNo = 1
        var numbered: [DiffLine] = []
        for (c, t) in ops {
            switch c {
            case "+": numbered.append(DiffLine(kind: .add, text: t, oldNo: nil, newNo: newNo)); newNo += 1
            case "-": numbered.append(DiffLine(kind: .del, text: t, oldNo: oldNo, newNo: nil)); oldNo += 1
            default: numbered.append(DiffLine(kind: .context, text: t, oldNo: oldNo, newNo: newNo)); oldNo += 1; newNo += 1
            }
        }
        var keep = [Bool](repeating: false, count: numbered.count)
        for (i, l) in numbered.enumerated() where l.kind != .context {
            for k in max(0, i - context)...min(numbered.count - 1, i + context) { keep[k] = true }
        }
        var gap = false
        for (i, l) in numbered.enumerated() {
            if !keep[i] { gap = true; continue }
            if gap, !r.lines.isEmpty { r.lines.append(DiffLine(kind: .hunk, text: "@@ … @@")) }
            gap = false
            r.lines.append(l)
        }
        (r.added, r.removed) = r.lineCounts
        return r
    }

    /// A new file has no diff against the index: show it as all-added.
    static func asAdded(_ content: String, maxLines: Int = 5000) -> DiffResult {
        var r = DiffResult()
        if content.utf8.contains(0) { r.binary = true; return r }
        var n = 1
        for l in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if r.lines.count >= maxLines { r.truncated = true; break }
            r.lines.append(DiffLine(kind: .add, text: String(l), oldNo: nil, newNo: n)); n += 1
        }
        if let last = r.lines.last, last.text.isEmpty, !r.truncated { r.lines.removeLast() }
        r.added = r.lines.count
        return r
    }
}

// MARK: Worktrees and the conflict card

struct Worktree: Equatable {
    var path: String
    var branch: String?
    var head: String?
    var detached = false
    var locked = false
    var prunable = false

    /// `git worktree list --porcelain`: blocks separated by blank lines.
    static func parse(_ text: String) -> [Worktree] {
        var out: [Worktree] = []
        var cur: Worktree?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { if let c = cur { out.append(c) }; cur = nil; continue }
            let s = String(line)
            if s.hasPrefix("worktree ") { cur = Worktree(path: String(s.dropFirst(9))); continue }
            guard cur != nil else { continue }
            if s.hasPrefix("HEAD ") { cur?.head = String(s.dropFirst(5).prefix(8)) }
            else if s.hasPrefix("branch ") { cur?.branch = String(s.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            else if s == "detached" { cur?.detached = true }
            else if s.hasPrefix("locked") { cur?.locked = true }
            else if s.hasPrefix("prunable") { cur?.prunable = true }
        }
        if let c = cur { out.append(c) }
        return out
    }
}

/// What the worktree conflict card shows.
struct ConflictCard: Equatable {
    var operation: String?          // "merge", "rebase", "cherry-pick", "revert"
    var files: [String]
    var otherWorktrees: [Worktree]  // other checkouts of the same repo (a branch checked out twice is the classic trap)
    var isLinkedWorktree: Bool

    var isEmpty: Bool { files.isEmpty && operation == nil }
    var title: String {
        let n = files.count
        if let op = operation { return n == 0 ? "A \(op) is in progress" : "\(n) conflicted file\(n == 1 ? "" : "s") during \(op)" }
        return "\(n) conflicted file\(n == 1 ? "" : "s")"
    }

    static func make(status: GitStatus, operation: String?, worktrees: [Worktree], cwd: String) -> ConflictCard {
        let me = worktrees.first { cwd == $0.path || cwd.hasPrefix($0.path + "/") }
        let others = worktrees.filter { $0.path != me?.path }
        return ConflictCard(operation: operation, files: status.conflicts.map(\.path), otherWorktrees: others,
                            isLinkedWorktree: me != nil && me?.path != worktrees.first?.path)
    }
}

// MARK: Transcript events (Files and Activity tabs)

struct ActivityEvent: Equatable {
    enum Kind: String { case prompt, edit, write, read, command, search, agent, other }
    var time: Date?
    var kind: Kind
    var title: String      // "Edit", "Bash", "You"
    var detail: String     // file path, command, prompt start
    var path: String?
}

struct TouchedFile: Equatable {
    var path: String
    var lastTouched: Date?
    var edits: Int
    var viaTranscript: Bool
}

enum TranscriptParser {
    /// The folder Claude Code keeps a project's transcripts in: the working directory with `/` and `.` replaced by `-`.
    static func projectSlug(_ cwd: String) -> String { String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 }) }

    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    static func kind(of tool: String) -> ActivityEvent.Kind {
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit": return .edit
        case "Write": return .write
        case "Read": return .read
        case "Bash", "BashOutput", "KillShell": return .command
        case "Grep", "Glob", "WebSearch", "WebFetch": return .search
        case "Task", "Agent": return .agent
        default: return .other
        }
    }

    /// Parses JSONL transcript text into events, oldest first. Lines that are not JSON (a cut first line when
    /// only the tail of a big file was read) are skipped.
    static func parse(_ jsonl: String) -> [ActivityEvent] {
        var out: [ActivityEvent] = []
        for line in jsonl.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let time = parseDate(o["timestamp"] as? String)
            guard let msg = o["message"] as? [String: Any] else { continue }
            let type = o["type"] as? String
            if type == "user", (o["isMeta"] as? Bool) != true {
                if let s = msg["content"] as? String, !s.hasPrefix("<") {
                    out.append(ActivityEvent(time: time, kind: .prompt, title: "You", detail: oneLine(s), path: nil))
                } else if let parts = msg["content"] as? [[String: Any]] {
                    for p in parts where p["type"] as? String == "text" {
                        if let s = p["text"] as? String, !s.hasPrefix("<") { out.append(ActivityEvent(time: time, kind: .prompt, title: "You", detail: oneLine(s), path: nil)) }
                    }
                }
            } else if type == "assistant", let parts = msg["content"] as? [[String: Any]] {
                for p in parts where p["type"] as? String == "tool_use" {
                    let name = p["name"] as? String ?? "tool"
                    let input = p["input"] as? [String: Any] ?? [:]
                    let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
                    let detail: String
                    if let path { detail = path }
                    else if let c = input["command"] as? String { detail = oneLine(c) }
                    else if let q = (input["pattern"] as? String) ?? (input["query"] as? String) ?? (input["description"] as? String) ?? (input["url"] as? String) { detail = oneLine(q) }
                    else { detail = "" }
                    out.append(ActivityEvent(time: time, kind: kind(of: name), title: name, detail: detail, path: path))
                }
            }
        }
        return out
    }

    static func oneLine(_ s: String, max: Int = 160) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max)) + "…" : t
    }

    /// Files the session wrote or edited, most recently touched first.
    static func touchedFiles(_ events: [ActivityEvent]) -> [TouchedFile] {
        var byPath: [String: TouchedFile] = [:]
        var order: [String] = []
        for e in events where (e.kind == .edit || e.kind == .write) && e.path != nil {
            let p = e.path!
            if var f = byPath[p] { f.edits += 1; if let t = e.time { f.lastTouched = max(f.lastTouched ?? t, t) }; byPath[p] = f }
            else { byPath[p] = TouchedFile(path: p, lastTouched: e.time, edits: 1, viaTranscript: true); order.append(p) }
        }
        let files = order.compactMap { byPath[$0] }
        return files.sorted { ($0.lastTouched ?? .distantPast) > ($1.lastTouched ?? .distantPast) }
    }
}

enum InspectorFormat {
    /// Path shown relative to the session folder (or `~`-abbreviated outside it).
    static func displayPath(_ path: String, cwd: String, home: String) -> String {
        if !cwd.isEmpty, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        if !home.isEmpty, path == home { return "~" }
        if !home.isEmpty, path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func ago(_ t: Date?, now: Date = Date()) -> String {
        guard let t else { return "" }
        let s = Int(now.timeIntervalSince(t))
        if s < 10 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        return "\(s / 86_400) d ago"
    }

    static func statusWord(_ c: GitChange) -> String {
        if c.isUntracked { return "Untracked" }
        if c.isConflicted { return "Conflict" }
        switch c.y != " " ? c.y : c.x {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type changed"
        default: return "Changed"
        }
    }
}

// MARK: Review changes (P6)

/// One entry of the Review changes list: a status code (M, A, D, ?, !) and a repo-relative path.
struct ReviewFile: Equatable {
    var code: String
    var path: String
    /// The git change behind a working-tree entry (nil for a branch file).
    var change: GitChange?
    var isFolder: Bool { path.hasSuffix("/") }
}

/// The files of a review and the one being looked at. `[` goes to the previous file, `]` to the next.
struct ReviewModel: Equatable {
    var title: String
    var files: [ReviewFile]
    private(set) var index = 0

    init(title: String, files: [ReviewFile], start: Int = 0) {
        self.title = title; self.files = files
        index = min(max(0, start), max(0, files.count - 1))
    }

    var current: ReviewFile? { files.indices.contains(index) ? files[index] : nil }
    var canPrev: Bool { index > 0 }
    var canNext: Bool { index < files.count - 1 }
    @discardableResult mutating func prev() -> Bool { guard canPrev else { return false }; index -= 1; return true }
    @discardableResult mutating func next() -> Bool { guard canNext else { return false }; index += 1; return true }
    mutating func select(_ i: Int) { if files.indices.contains(i) { index = i } }

    /// The `[` / `]` keys. Returns true when the key was ours (even at the end of the list), so it is swallowed.
    @discardableResult mutating func handle(key: String) -> Bool {
        switch key {
        case "[": prev(); return true
        case "]": next(); return true
        default: return false
        }
    }

    var footer: String { files.isEmpty ? "No changes" : "File \(index + 1) of \(files.count) · [ and ] to move" }

    static func workingTree(_ changes: [GitChange]) -> ReviewModel {
        ReviewModel(title: "Review changes", files: changes.map { ReviewFile(code: $0.badge, path: $0.path, change: $0) })
    }

    /// `status` maps a path to its git status letter (A, M, D, R); a file without one shows as modified.
    static func branch(_ name: String, base: String, files: [String], status: [String: String] = [:]) -> ReviewModel {
        ReviewModel(title: "Review \(name) against \(base)", files: files.map { f in
            let c = status[f] ?? "M"
            return ReviewFile(code: ["A", "M", "D", "R"].contains(c) ? c : "M", path: f, change: nil)
        })
    }
}

// MARK: Activity tab: agent files (WP3)

/// One row of the Activity tab's AGENT FILES groups (src/redesign/ActivityPanel.tsx): the file and how many times it was touched.
struct AgentFile: Equatable {
    var path: String
    var count: Int
}

enum AgentFiles {
    /// MODIFIED = files the session edited or wrote, READ = files it only read, both in the order the session first touched them.
    static func split(_ events: [ActivityEvent]) -> (modified: [AgentFile], read: [AgentFile]) {
        var mod: [String: Int] = [:], rd: [String: Int] = [:]
        var order: [String] = []
        for e in events {
            guard let p = e.path else { continue }
            switch e.kind {
            case .edit, .write: mod[p, default: 0] += 1
            case .read: rd[p, default: 0] += 1
            default: continue
            }
            if !order.contains(p) { order.append(p) }
        }
        func rows(_ d: [String: Int]) -> [AgentFile] {
            order.filter { d[$0] != nil }.map { AgentFile(path: $0, count: d[$0]!) }
        }
        let m = rows(mod)
        return (m, rows(rd.filter { mod[$0.key] == nil }))
    }
}

// MARK: Review dialog: before | after columns (WP3)

/// One row of the side-by-side diff: the old line on the left, the new one on the right (either may be missing).
struct SideRow: Equatable {
    var left: DiffLine?
    var right: DiffLine?
    var separator: String?   // a hunk header spans both columns
}

enum SideBySide {
    /// Pairs a unified diff for two columns: context shows on both sides, a block of removed lines sits next to the
    /// added lines that replace it (row by row), the rest of the longer side is left empty.
    static func rows(_ d: DiffResult) -> [SideRow] {
        var out: [SideRow] = []
        var dels: [DiffLine] = [], adds: [DiffLine] = []
        func flush() {
            for i in 0..<max(dels.count, adds.count) { out.append(SideRow(left: i < dels.count ? dels[i] : nil, right: i < adds.count ? adds[i] : nil)) }
            dels = []; adds = []
        }
        for l in d.lines {
            switch l.kind {
            case .del: dels.append(l)
            case .add: adds.append(l)
            case .context: flush(); out.append(SideRow(left: l, right: l))
            case .hunk: flush(); out.append(SideRow(separator: l.text))
            case .meta: continue
            case .note: flush(); out.append(SideRow(separator: l.text))
            }
        }
        flush()
        return out
    }
}

// MARK: Needs-approval card (WP3)

/// A session waiting for a permission answer, as the Inspector's NEEDS APPROVAL card shows it.
struct InspectorApproval: Equatable {
    var id: UInt64
    var name: String
    var tool: String
    var target: String
    var question: String
    var actionable: Bool

    /// The sentence after the agent's name (web: "wants to write a file").
    var summary: String { question.isEmpty ? "is waiting for your permission" : question }

    /// `Control::Screen` prompt key "tool|target|question" (Model.swift ScreenSummary.promptKey).
    static func parse(promptKey: String) -> (tool: String, target: String, question: String) {
        let p = promptKey.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        return (p.count > 0 ? p[0] : "", p.count > 1 ? p[1] : "", p.count > 2 ? p[2] : "")
    }
}
