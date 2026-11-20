// Where the Inspector gets its data. INTERIM: a local, read-only `git` and a read of the newest Claude
// transcript of the folder. `InspectorSource` is the seam: when muyad serves `fs.git_status`, `fs.diff`,
// `fs.worktrees` and `history.events` (see the Faz 4-B summary), only the implementation changes.
// Foundation only; every call blocks, so callers run it off the main thread.

import Foundation

struct InspectorSnapshot: Equatable {
    var root: String?              // nil: not a git repository
    var status = GitStatus()
    var card = ConflictCard(operation: nil, files: [], otherWorktrees: [], isLinkedWorktree: false)
    var error: String?
}

protocol InspectorSource {
    func snapshot(cwd: String) -> InspectorSnapshot
    func diff(root: String, change: GitChange) -> DiffResult
    func events(cwd: String, root: String?, home: String) -> [ActivityEvent]
}

final class LocalGitSource: InspectorSource {
    static let maxOutput = 8 << 20
    static let maxFileBytes = 1 << 20
    static let transcriptTail = 3 << 20
    let gitPath: String

    init(gitPath: String = "/usr/bin/git") { self.gitPath = gitPath }

    /// Runs git with no optional locks (never contend with the user's own git) and a C locale.
    func run(_ args: [String], in dir: String, timeout: TimeInterval = 10) -> (data: Data, ok: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = GitArgs.readOnly(args)
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"; env["LC_ALL"] = "C"; env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_PAGER"] = "cat"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (Data(), false) }
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
        return (data, p.terminationStatus == 0)
    }

    private func text(_ args: [String], in dir: String) -> String? {
        let r = run(args, in: dir)
        return r.ok ? String(decoding: r.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func snapshot(cwd: String) -> InspectorSnapshot {
        var snap = InspectorSnapshot()
        guard FileManager.default.fileExists(atPath: cwd), let root = text(["rev-parse", "--show-toplevel"], in: cwd), !root.isEmpty else { return snap }
        snap.root = root
        let st = run(["status", "--porcelain=v1", "-z", "-b", "--untracked-files=normal"], in: root)
        if !st.ok { snap.error = "git status failed"; return snap }
        snap.status = GitStatus.parse(st.data)
        let wt = run(["worktree", "list", "--porcelain"], in: root)
        let worktrees = wt.ok ? Worktree.parse(String(decoding: wt.data, as: UTF8.self)) : []
        snap.card = ConflictCard.make(status: snap.status, operation: operation(root), worktrees: worktrees, cwd: cwd)
        return snap
    }

    func operation(_ root: String) -> String? {
        guard let gd = text(["rev-parse", "--absolute-git-dir"], in: root) else { return nil }
        let fm = FileManager.default
        for (file, name) in [("MERGE_HEAD", "merge"), ("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert")]
        where fm.fileExists(atPath: gd + "/" + file) { return name }
        return nil
    }

    func diff(root: String, change: GitChange) -> DiffResult {
        if change.path.hasSuffix("/") {
            var r = DiffResult(); r.lines = [DiffLine(kind: .note, text: "Untracked folder: expand it in the file tree to see its files.")]; return r
        }
        if change.isUntracked || change.isConflicted {
            guard let h = FileHandle(forReadingAtPath: root + "/" + change.path) else { return DiffResult() }
            defer { try? h.close() }
            let data = h.readData(ofLength: Self.maxFileBytes)
            if data.contains(0) { var r = DiffResult(); r.binary = true; return r }
            let content = String(decoding: data, as: UTF8.self)
            return change.isConflicted ? DiffParser.conflictView(content) : DiffParser.asAdded(content)
        }
        let hasHead = run(["rev-parse", "--verify", "-q", "HEAD"], in: root).ok
        var args = ["diff", "--no-color", "--no-ext-diff", "--no-renames"]
        args += hasHead ? ["HEAD"] : ["--cached"]
        args += ["--", change.path]
        let r = run(args, in: root)
        return DiffParser.parse(String(decoding: r.data, as: UTF8.self))
    }

    // MARK: Transcript

    /// The newest transcript of this folder (`<home>/.claude/projects/<slug>/*.jsonl`), parsed from its tail.
    func events(cwd: String, root: String?, home: String) -> [ActivityEvent] {
        let fm = FileManager.default
        for dir in [cwd, root].compactMap({ $0 }) {
            let folder = home + "/.claude/projects/" + TranscriptParser.projectSlug(dir)
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            let newest = names.filter { $0.hasSuffix(".jsonl") }.compactMap { n -> (String, Date)? in
                guard let d = (try? fm.attributesOfItem(atPath: folder + "/" + n))?[.modificationDate] as? Date else { return nil }
                return (n, d)
            }.max { $0.1 < $1.1 }
            guard let file = newest, let h = FileHandle(forReadingAtPath: folder + "/" + file.0) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            let start = size > UInt64(Self.transcriptTail) ? size - UInt64(Self.transcriptTail) : 0
            try? h.seek(toOffset: start)
            var s = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            if start > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) } // drop the cut first line
            return TranscriptParser.parse(s)
        }
        return []
    }
}

extension DiffParser {
    /// A conflicted file: its content, with the conflict markers called out.
    static func conflictView(_ content: String, maxLines: Int = 5000) -> DiffResult {
        var r = DiffResult()
        var n = 1
        for l in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if r.lines.count >= maxLines { r.truncated = true; break }
            let s = String(l)
            let marker = s.hasPrefix("<<<<<<<") || s.hasPrefix("=======") || s.hasPrefix(">>>>>>>") || s.hasPrefix("|||||||")
            r.lines.append(DiffLine(kind: marker ? .hunk : .context, text: s, oldNo: nil, newNo: n)); n += 1
        }
        if let last = r.lines.last, last.text.isEmpty, !r.truncated { r.lines.removeLast() }
        return r
    }
}

// MARK: Review changes: a branch against its base (interim local git, like the rest of this file)

extension LocalGitSource {
    /// `main` (else `master`) unless that is the branch itself; nil when neither exists.
    func reviewBase(root: String, branch: String) -> String? {
        ["main", "master"].first { $0 != branch && run(["rev-parse", "--verify", "-q", "refs/heads/" + $0], in: root).ok }
    }

    /// The files a branch changed since it left `base`.
    func branchFiles(root: String, base: String, branch: String) -> [String] {
        guard !branch.hasPrefix("-"), !base.hasPrefix("-") else { return [] }
        let r = run(["diff", "--name-only", "-z", "--no-renames", "refs/heads/\(base)...refs/heads/\(branch)"], in: root)
        guard r.ok else { return [] }
        return String(decoding: r.data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    /// One file of a branch's change set, as a diff.
    func branchDiff(root: String, base: String, branch: String, path: String) -> DiffResult {
        guard !path.hasPrefix("-"), !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return DiffResult() }
        let r = run(["diff", "--no-color", "--no-ext-diff", "--no-renames", "refs/heads/\(base)...refs/heads/\(branch)", "--", path], in: root)
        return DiffParser.parse(String(decoding: r.data, as: UTF8.self))
    }
}

// MARK: muyad client for the P6 calls

/// An error text from muyad (or from the transport).
struct RpcText: Error, Equatable, ExpressibleByStringLiteral {
    var text: String
    init(_ t: String) { text = t }
    init(stringLiteral v: String) { text = v }
}

/// One call into muyad, answered synchronously: (method, params) -> decoded JSON or an error text.
/// Blocking, so it must never run on the main thread (the app's adapter refuses to).
typealias BlockingRpc = (String, [String: Any]) -> Result<Any, RpcText>

struct BranchCommit: Equatable { var hash: String; var subject: String; var author: String; var relDate: String }

struct BranchInfo: Equatable {
    var name: String
    var base: String
    var ahead: Int
    var behind: Int
    var commits: [BranchCommit]
    var changedFiles: [String]
    /// path -> git status letter (A, M, D, R); empty from an older daemon.
    var changedStatus: [String: String] = [:]
}

struct FileVersion: Equatable { var id: String; var at: Int; var size: Int; var kind: String }

/// Typed client for `git.branch_detail`, `git.branch_file_pair`, `git.create_worktree`, `git.remove_worktree`
/// and `file_history.*`. Folder rules (workspace roots only) are enforced by the daemon; its errors pass through.
struct MuyadGit {
    let call: BlockingRpc

    private func obj(_ r: Result<Any, RpcText>) -> Result<[String: Any], RpcText> {
        switch r {
        case let .failure(e): return .failure(e)
        case let .success(v): if let d = v as? [String: Any] { return .success(d) }; return .failure("unexpected answer from muyad")
        }
    }

    func branchDetail(cwd: String, branch: String) -> Result<BranchInfo, RpcText> {
        obj(call("git.branch_detail", ["cwd": cwd, "branch": branch])).map { d in
            BranchInfo(name: d["name"] as? String ?? branch, base: d["base"] as? String ?? "", ahead: d["ahead"] as? Int ?? 0, behind: d["behind"] as? Int ?? 0,
                       commits: (d["commits"] as? [[String: Any]] ?? []).map { BranchCommit(hash: $0["hash"] as? String ?? "", subject: $0["subject"] as? String ?? "", author: $0["author"] as? String ?? "", relDate: $0["relDate"] as? String ?? "") },
                       changedFiles: (d["changedFiles"] as? [String]) ?? [],
                       changedStatus: Dictionary(((d["changedStatus"] as? [[String: Any]]) ?? []).compactMap { e in (e["path"] as? String).flatMap { p in (e["status"] as? String).map { (p, $0) } } }, uniquingKeysWith: { a, _ in a }))
        }
    }

    /// (content at the merge-base, content at the branch tip); "" where the file does not exist.
    func branchFilePair(cwd: String, base: String, branch: String, path: String) -> Result<(old: String, new: String), RpcText> {
        switch call("git.branch_file_pair", ["cwd": cwd, "base": base, "branch": branch, "path": path]) {
        case let .failure(e): return .failure(e)
        case let .success(v):
            guard let a = v as? [Any], a.count == 2, let o = a[0] as? String, let n = a[1] as? String else { return .failure("unexpected answer from muyad") }
            return .success((o, n))
        }
    }

    func createWorktree(cwd: String, branch: String) -> Result<String, RpcText> {
        switch call("git.create_worktree", ["cwd": cwd, "branch": branch]) {
        case let .failure(e): return .failure(e)
        case let .success(v): if let s = v as? String { return .success(s) }; return .failure("unexpected answer from muyad")
        }
    }

    func removeWorktree(_ path: String) -> Result<String, RpcText> {
        switch call("git.remove_worktree", ["worktree": path]) {
        case let .failure(e): return .failure(e)
        case let .success(v): if let s = v as? String { return .success(s) }; return .failure("unexpected answer from muyad")
        }
    }

    private func version(_ d: [String: Any]) -> FileVersion? {
        guard let id = d["id"] as? String else { return nil }
        return FileVersion(id: id, at: d["at"] as? Int ?? 0, size: d["size"] as? Int ?? 0, kind: d["kind"] as? String ?? "")
    }

    /// nil inside `.success` when the content equals the newest version (nothing new was stored).
    func historySnapshot(path: String, content: String, kind: String) -> Result<FileVersion?, RpcText> {
        switch call("file_history.snapshot", ["path": path, "content": content, "kind": kind]) {
        case let .failure(e): return .failure(e)
        case let .success(v): return .success((v as? [String: Any]).flatMap(version))
        }
    }

    func historyList(path: String) -> Result<[FileVersion], RpcText> {
        switch call("file_history.list", ["path": path]) {
        case let .failure(e): return .failure(e)
        case let .success(v): return .success(((v as? [[String: Any]]) ?? []).compactMap(version))
        }
    }

    func historyRead(path: String, id: String) -> Result<String, RpcText> {
        switch call("file_history.read", ["path": path, "id": id]) {
        case let .failure(e): return .failure(e)
        case let .success(v): if let s = v as? String { return .success(s) }; return .failure("unexpected answer from muyad")
        }
    }
}
