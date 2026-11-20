// Where the Queue, Branches and Kanban views get their data. INTERIM: a local, READ-ONLY `git` and a read of
// docs/prd-*.progress.md. `QueueSource` is the seam: when muyad serves the calls listed in the Queue summary
// (git.branches, git.log, git.worktrees, plan.list, plan.set_status, queue.run), only the implementation changes.
// Foundation only; every call blocks, so callers run it off the main thread.
//
// Nothing here writes to a repository: card moves go to a COPY directory, and the destructive actions only
// log the command they would run (`InterimActionLog`).

import Foundation

struct QueueSnapshot: Equatable {
    var root: String?
    var base = "main"
    var entries: [QueueEntry] = []
    var error: String?
}

/// One tracked project (a workspace folder): the same fields as today's `pm_status` (crates/muya-core/src/pm.rs).
struct TrackedProject: Equatable, Identifiable {
    var path: String
    var name: String
    var isGit = false
    var branch = ""
    var base = "main"
    var ahead = 0, behind = 0     // HEAD against the base branch
    var dirty = 0                 // uncommitted files
    var changed = 0               // files changed on this branch vs base
    var lastActivity: TimeInterval = 0   // last commit, seconds since 1970 (0 = unknown)
    var id: String { path }

    /// "3d ago" style, like today's relTime.
    func age(now: Date = Date()) -> String {
        guard lastActivity > 0 else { return "–" }
        let s = max(0, Int(now.timeIntervalSince1970 - lastActivity))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

protocol QueueSource {
    /// Status of each path (workspace folders), in order. Non-git folders come back with `isGit == false`.
    func tracked(paths: [String]) -> [TrackedProject]
    /// Trial merge of `branch` into `base` without touching the working tree: nil = could not tell.
    func mergeCheck(path: String, branch: String, base: String) -> Bool?
    func queue(cwd: String) -> QueueSnapshot
    func commits(cwd: String, limit: Int) -> [CommitNode]
    func cards(cwd: String) -> [KanbanCard]
    /// INTERIM: persists to a copy, never to the original file.
    func setStatus(slug: String, column: KanbanColumn, cwd: String) -> Bool
}

extension QueueSource {
    func tracked(paths: [String]) -> [TrackedProject] { [] }
    func mergeCheck(path: String, branch: String, base: String) -> Bool? { nil }
}

/// The queue membership, kept where the migrated localStorage lives: `ui-prefs.json` ({ "<localStorage key>": "<string>" },
/// crates/muya-core/src/migrate.rs), under today's key `apex.mergeQueue` (a JSON array of project paths as a string).
enum QueuePrefs {
    static let key = "apex.mergeQueue"

    static func file(home: String) -> String { home + "/Library/Application Support/com.staunch.muya/native/ui-prefs.json" }

    static func load(home: String) -> [String] {
        guard let d = FileManager.default.contents(atPath: file(home: home)),
              let all = try? JSONSerialization.jsonObject(with: d) as? [String: String],
              let v = all[key]?.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: v) as? [String] else { return [] }
        return list
    }

    /// Writes only this key; the other migrated keys stay as they are. Returns false when it could not be saved.
    @discardableResult
    static func save(_ paths: [String], home: String) -> Bool {
        let f = file(home: home)
        var all: [String: String] = [:]
        if let d = FileManager.default.contents(atPath: f) {
            guard let cur = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return false } // unreadable: do not clobber
            all = cur
        }
        guard let v = try? JSONSerialization.data(withJSONObject: paths) else { return false }
        all[key] = String(decoding: v, as: UTF8.self)
        guard let out = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return false }
        do {
            try FileManager.default.createDirectory(atPath: (f as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try out.write(to: URL(fileURLWithPath: f), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f)
            return true
        } catch { return false }
    }
}

/// The INTERIM handler of the destructive buttons: records what would have run, executes nothing.
final class InterimActionLog {
    private(set) var lines: [String] = []
    func record(_ action: QueueAction) -> String {
        let line = "would run: \(action.commandLine)"
        lines.append(line)
        return line
    }
}

final class LocalQueueSource: QueueSource {
    static let maxOutput = 16 << 20
    let gitPath: String
    /// Kanban moves land here (a throw-away copy of the progress file), never in the repository.
    let copyDir: String

    init(gitPath: String = "/usr/bin/git", copyDir: String = NSTemporaryDirectory() + "muya-queue-kanban-copy") {
        self.gitPath = gitPath
        self.copyDir = copyDir
    }

    func run(_ args: [String], in dir: String, timeout: TimeInterval = 15) -> (text: String, ok: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = GitArgs.readOnly(args)
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"; env["LC_ALL"] = "C"; env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_PAGER"] = "cat"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ("", false) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var data = Data()
        while true {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if data.count < Self.maxOutput { data.append(chunk) }
        }
        p.waitUntilExit()
        killer.cancel()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus == 0)
    }

    private func text(_ args: [String], in dir: String) -> String? {
        let r = run(args, in: dir)
        return r.ok ? r.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func root(of cwd: String) -> String? {
        guard FileManager.default.fileExists(atPath: cwd), let r = text(["rev-parse", "--show-toplevel"], in: cwd), !r.isEmpty else { return nil }
        return r
    }

    /// Same git calls as `status_for` in crates/muya-core/src/pm.rs.
    func tracked(paths: [String]) -> [TrackedProject] {
        paths.map { path in
            var p = TrackedProject(path: path, name: (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent)
            guard FileManager.default.fileExists(atPath: path), text(["rev-parse", "--is-inside-work-tree"], in: path) == "true" else { return p }
            p.isGit = true
            p.branch = text(["rev-parse", "--abbrev-ref", "HEAD"], in: path) ?? ""
            p.base = baseBranch(in: path)
            p.dirty = (run(["status", "--porcelain"], in: path).text).split(separator: "\n").count
            if p.branch != p.base {
                if let c = text(["rev-list", "--left-right", "--count", "\(p.base)...HEAD"], in: path) {
                    let n = c.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Int($0) }
                    if n.count == 2 { p.behind = n[0]; p.ahead = n[1] }
                }
                p.changed = (text(["diff", "--name-only", "\(p.base)...HEAD"], in: path) ?? "").split(separator: "\n").count
            }
            p.lastActivity = TimeInterval(text(["log", "-1", "--format=%ct"], in: path) ?? "") ?? 0
            return p
        }
    }

    /// The repo's integration branch: origin/HEAD, else main, else master.
    func baseBranch(in path: String) -> String {
        if let h = text(["symbolic-ref", "refs/remotes/origin/HEAD"], in: path), let b = h.split(separator: "/").last, !b.isEmpty { return String(b) }
        for c in ["main", "master"] where run(["rev-parse", "--verify", "--quiet", c], in: path).ok { return c }
        return "main"
    }

    func mergeCheck(path: String, branch: String, base: String) -> Bool? {
        if branch == base { return true }
        let r = run(["merge-tree", "--write-tree", base, branch], in: path)
        return r.ok ? true : (r.text.contains("CONFLICT") || r.text.contains("changed in both") ? false : nil)
    }

    func queue(cwd: String) -> QueueSnapshot {
        var snap = QueueSnapshot()
        guard let root = root(of: cwd) else { return snap }
        snap.root = root
        let refs = run(["for-each-ref", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)\t%(HEAD)\t%(subject)", "refs/heads"], in: root)
        guard refs.ok else { snap.error = "git for-each-ref failed"; return snap }
        let branches = QueueParser.branches(refs.text)
        let names = Set(branches.map(\.branch))
        let base = ["main", "master", "trunk", "develop"].first(where: names.contains) ?? branches.first(where: \.head)?.branch ?? "main"
        snap.base = base

        // Worktree path per branch.
        var worktreeOf: [String: String] = [:]
        let wt = run(["worktree", "list", "--porcelain"], in: root)
        if wt.ok {
            for w in Worktree.parse(wt.text) { if let br = w.branch { worktreeOf[br] = w.path } }
        }
        for b in branches {
            var e = QueueEntry(branch: b.branch, worktree: worktreeOf[b.branch], upstream: b.upstream, vsUpstream: b.track, subject: b.subject, base: base, isBase: b.branch == base)
            if !e.isBase {
                let r = run(["rev-list", "--left-right", "--count", "\(base)...\(b.branch)"], in: root)
                if r.ok, let ab = AheadBehind.parseCount(r.text) { e.vsBase = ab }
            }
            let dir = e.worktree ?? (b.head ? root : nil)
            if let dir { e.dirty = !(text(["status", "--porcelain=v1", "--untracked-files=no"], in: dir) ?? "").isEmpty }
            snap.entries.append(e)
        }
        snap.entries.sort(by: QueueEntry.order)
        return snap
    }

    func commits(cwd: String, limit: Int) -> [CommitNode] {
        guard let root = root(of: cwd) else { return [] }
        let r = run(["log", "--all", "--topo-order", "-n", "\(limit)", "--format=%H%x1f%P%x1f%D%x1f%an%x1f%at%x1f%s%x1e"], in: root, timeout: 30)
        return r.ok ? DagLayout.parse(r.text) : []
    }

    func cards(cwd: String) -> [KanbanCard] {
        let docs = (root(of: cwd) ?? cwd) + "/docs"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: docs) else { return [] }
        var out: [KanbanCard] = []
        for n in names.sorted() where n.hasPrefix("prd-") && n.hasSuffix(".progress.md") {
            let slug = String(n.dropFirst(4).dropLast(12))
            guard let prog = try? String(contentsOfFile: docs + "/" + n, encoding: .utf8) else { continue }
            // The copy written by an earlier move wins over the original (INTERIM persistence).
            let copy = copyPath(cwd: cwd, file: n)
            let shown = (try? String(contentsOfFile: copy, encoding: .utf8)) ?? prog
            let prd = try? String(contentsOfFile: docs + "/prd-\(slug).md", encoding: .utf8)
            let title = prd.flatMap(KanbanFile.title(of:)) ?? KanbanFile.title(of: prog) ?? slug.replacingOccurrences(of: "-", with: " ")
            out.append(KanbanCard(slug: slug, title: title, status: KanbanFile.status(of: shown), file: n))
        }
        return out
    }

    func copyPath(cwd: String, file: String) -> String {
        let key = String((root(of: cwd) ?? cwd).unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }, radix: 16)
        return copyDir + "/" + key + "/" + file
    }

    func setStatus(slug: String, column: KanbanColumn, cwd: String) -> Bool {
        let file = "prd-\(slug).progress.md"
        let docs = (root(of: cwd) ?? cwd) + "/docs"
        let copy = copyPath(cwd: cwd, file: file)
        guard let src = (try? String(contentsOfFile: copy, encoding: .utf8)) ?? (try? String(contentsOfFile: docs + "/" + file, encoding: .utf8)) else { return false }
        do {
            try FileManager.default.createDirectory(atPath: (copy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try KanbanFile.settingStatus(column.statusWord, in: src).write(toFile: copy, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }
}
