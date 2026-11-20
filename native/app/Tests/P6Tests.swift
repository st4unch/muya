// P6: Review changes — the file list model (`[` / `]`), and a branch reviewed against its base, on a throw-away repo.

import Foundation

func runP6Tests() {
    runP6DiffTests()
    runP6ClientTests()
    test("review model: [ and ] move between files and stop at the ends") {
        let files = ["a", "b", "c"].map { ReviewFile(code: "M", path: $0 + ".txt", change: nil) }
        var m = ReviewModel(title: "Review changes", files: files)
        check(m.current?.path == "a.txt" && !m.canPrev && m.canNext, "starts on the first file")
        check(m.footer == "File 1 of 3 · [ and ] to move", "footer text: \(m.footer)")
        check(m.handle(key: "]") && m.index == 1, "] goes next")
        check(m.handle(key: "]") && m.index == 2 && !m.canNext, "] reaches the last file")
        check(m.handle(key: "]") && m.index == 2, "] at the end is swallowed, index stays")
        check(m.handle(key: "[") && m.index == 1, "[ goes back")
        m.select(0); check(m.handle(key: "[") && m.index == 0, "[ at the start stays")
        check(!m.handle(key: "x") && m.index == 0, "other keys are not ours")
        m.select(9); check(m.index == 0, "select out of range is ignored")
    }

    test("review model: start index is clamped; empty list") {
        let one = [ReviewFile(code: "A", path: "n", change: nil)]
        check(ReviewModel(title: "t", files: one, start: 5).index == 0, "start clamped high")
        check(ReviewModel(title: "t", files: one, start: -3).index == 0, "start clamped low")
        var e = ReviewModel(title: "t", files: [])
        check(e.current == nil && !e.canPrev && !e.canNext && e.footer == "No changes", "empty review")
        check(e.handle(key: "]") && e.index == 0, "keys on an empty list are harmless")
    }

    test("review model: built from git changes and from a branch") {
        let st = GitStatus.parse(Data((["## main", " M a.swift", "?? n.txt", "D  gone.txt", "UU c.c"].joined(separator: "\0") + "\0").utf8))
        let m = ReviewModel.workingTree(st.changes)
        check(m.files.map(\.code) == ["M", "U", "D", "!"], "codes \(m.files.map(\.code))")
        check(m.files[0].change?.path == "a.swift" && m.title == "Review changes", "keeps the change")
        check(ReviewFile(code: "U", path: "dir/", change: nil).isFolder, "folder entry")
        let b = ReviewModel.branch("feat", base: "main", files: ["x.txt"])
        check(b.title == "Review feat against main" && b.files[0].code == "M" && b.files[0].change == nil, "branch model, no status: modified")
        let s = ReviewModel.branch("feat", base: "main", files: ["a", "b", "c", "d", "e"], status: ["a": "A", "b": "D", "c": "M", "d": "R", "e": "T"])
        check(s.files.map(\.code) == ["A", "D", "M", "R", "M"], "status letters become badges, unknown letters show M: \(s.files.map(\.code))")
    }

    test("branch review against a real throw-away repository") {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "p6-test-\(UUID().uuidString)"
        let repo = base + "/repo"
        defer { try? fm.removeItem(atPath: base) }
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let src = LocalGitSource()
        func git(_ a: [String]) { _ = src.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + a, in: repo) }
        git(["init", "-q", "-b", "main"])
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-q", "-m", "first"])
        git(["checkout", "-q", "-b", "feat"])
        try "one\ntwo\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/n.txt", atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-q", "-m", "second"])
        git(["checkout", "-q", "main"])

        check(src.reviewBase(root: repo, branch: "feat") == "main", "base is main")
        check(src.reviewBase(root: repo, branch: "main") == nil, "a branch is never its own base")
        let files = src.branchFiles(root: repo, base: "main", branch: "feat")
        check(Set(files) == ["a.txt", "n.txt"], "changed files \(files)")
        let d = src.branchDiff(root: repo, base: "main", branch: "feat", path: "a.txt")
        check(d.added == 1 && d.removed == 0, "a.txt +1 −0, got +\(d.added) −\(d.removed)")
        check(src.branchDiff(root: repo, base: "main", branch: "feat", path: "../x").lines.isEmpty, ".. refused")
        check(src.branchDiff(root: repo, base: "main", branch: "feat", path: "-x").lines.isEmpty, "option-looking path refused")
        check(src.branchFiles(root: repo, base: "main", branch: "--all").isEmpty, "option-looking branch refused")
    }
}

func runP6DiffTests() {
    test("pair diff: counts equal the +/- lines, numbering is right, context is trimmed") {
        let old = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...30).map { "line \($0)" }
        lines[9] = "line ten"; lines.insert("inserted", at: 25)
        let d = DiffParser.fromPair(old: old, new: lines.joined(separator: "\n") + "\n")
        let c = d.lineCounts
        check(c.added == 2 && c.removed == 1, "+2 −1, got +\(c.added) −\(c.removed)")
        check(d.added == c.added && d.removed == c.removed, "stored counts match the lines")
        check(d.lines.contains { $0.kind == .del && $0.text == "line 10" && $0.oldNo == 10 }, "deleted line numbered by the old side")
        check(d.lines.contains { $0.kind == .add && $0.text == "line ten" && $0.newNo == 10 }, "added line numbered by the new side")
        check(d.lines.contains { $0.kind == .hunk }, "far-apart changes are separated by a hunk marker")
        check(!d.lines.contains { $0.text == "line 1" }, "unchanged lines far from a change are dropped")
    }

    test("pair diff: added, deleted, identical and binary files") {
        let add = DiffParser.fromPair(old: "", new: "a\nb\n")
        check(add.lineCounts.added == 2 && add.lineCounts.removed == 0, "added file")
        let del = DiffParser.fromPair(old: "a\nb\n", new: "")
        check(del.lineCounts.added == 0 && del.lineCounts.removed == 2, "deleted file")
        check(DiffParser.fromPair(old: "x\n", new: "x\n").lines.isEmpty, "identical: no lines")
        check(DiffParser.fromPair(old: "a\0b", new: "c").binary, "binary")
    }

    test("a parsed git diff: header counts come from the lines the body shows") {
        let txt = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,4 @@\n one\n-two\n+TWO\n+three-and-a-half\n three\n"
        let d = DiffParser.parse(txt)
        check(d.lineCounts.added == 2 && d.lineCounts.removed == 1 && d.added == 2 && d.removed == 1, "+2 −1")
    }
}

func runP6ClientTests() {
    test("muyad client: every P6 call sends the daemon's method and params and parses its answer") {
        nonisolated(unsafe) var seen: [(String, [String: Any])] = []
        let git = MuyadGit { m, p in
            seen.append((m, p))
            switch m {
            case "git.branch_detail": return .success(["name": "feat", "base": "main", "ahead": 2, "behind": 1, "commits": [["hash": "abc", "subject": "s", "author": "a", "relDate": "now"]], "changedFiles": ["a.txt", "n.txt"], "changedStatus": [["path": "a.txt", "status": "M"], ["path": "n.txt", "status": "A"]]] as [String: Any])
            case "git.branch_file_pair": return .success(["one\n", "one\ntwo\n"] as [Any])
            case "git.create_worktree": return .success("/w/feat")
            case "git.remove_worktree": return .success("removed worktree /w/feat")
            case "file_history.snapshot": return .success(["id": "v1", "at": 5, "size": 3, "kind": "saved"] as [String: Any])
            case "file_history.list": return .success([["id": "v1", "at": 5, "size": 3, "kind": "saved"]] as [Any])
            case "file_history.read": return .success("v1\n")
            default: return .failure("unknown method")
            }
        }
        let d = try git.branchDetail(cwd: "/r", branch: "feat").get()
        check(d.base == "main" && d.ahead == 2 && d.behind == 1 && d.commits.first?.subject == "s" && d.changedFiles == ["a.txt", "n.txt"] && d.changedStatus == ["a.txt": "M", "n.txt": "A"], "branch detail \(d)")
        let pair = try git.branchFilePair(cwd: "/r", base: "main", branch: "feat", path: "a.txt").get()
        check(pair.old == "one\n" && pair.new == "one\ntwo\n", "pair")
        check(try git.createWorktree(cwd: "/r", branch: "feat").get() == "/w/feat", "create")
        check(try git.removeWorktree("/w/feat").get().hasPrefix("removed"), "remove")
        check(try git.historySnapshot(path: "/r/a", content: "x", kind: "saved").get()?.id == "v1", "snapshot")
        check(try git.historyList(path: "/r/a").get().count == 1, "list")
        check(try git.historyRead(path: "/r/a", id: "v1").get() == "v1\n", "read")
        check(seen.map(\.0) == ["git.branch_detail", "git.branch_file_pair", "git.create_worktree", "git.remove_worktree", "file_history.snapshot", "file_history.list", "file_history.read"], "methods \(seen.map(\.0))")
        check(seen[1].1["base"] as? String == "main" && seen[3].1["worktree"] as? String == "/w/feat" && seen[0].1["cwd"] as? String == "/r", "params")
    }

    test("muyad client: errors and odd answers become failures, a null snapshot means nothing new") {
        let refuse = MuyadGit { _, _ in .failure("that folder is not one of Muya's workspaces") }
        if case let .failure(e) = refuse.branchDetail(cwd: "/x", branch: "b") { check(e.text.contains("not one of Muya's workspaces"), "daemon text passes through") } else { check(false, "should fail") }
        let odd = MuyadGit { _, _ in .success(42) }
        check({ if case .failure = odd.branchDetail(cwd: "/x", branch: "b") { return true }; return false }(), "non-object detail")
        check({ if case .failure = odd.branchFilePair(cwd: "/x", base: "m", branch: "b", path: "p") { return true }; return false }(), "non-pair")
        let none = MuyadGit { _, _ in .success(NSNull()) }
        check(try none.historySnapshot(path: "/x", content: "c", kind: "saved").get() == nil, "null = unchanged")
    }
}
