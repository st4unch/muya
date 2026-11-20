// Unit tests of the Inspector parsers and view models (Sources/Inspector/InspectorLogic.swift) and the
// interim local git source, run against a throw-away repository in a temp directory.

import Foundation

private func nul(_ parts: [String]) -> Data { Data((parts.joined(separator: "\0") + "\0").utf8) }

func runInspectorTests() {
    test("git status parses branch, ahead/behind, changes and renames") {
        let st = GitStatus.parse(nul(["## main...origin/main [ahead 2, behind 1]", " M src/a.swift", "A  new.txt", "R  b.txt", "a.txt", "?? notes ş.md", "UU merge.c"]))
        check(st.branch == "main" && st.upstream == "origin/main" && st.ahead == 2 && st.behind == 1, "branch line \(st)")
        check(st.changes.count == 5, "five entries (rename consumes its old path): \(st.changes.count)")
        check(st.changes[0].path == "src/a.swift" && st.changes[0].kinds == [.unstaged] && st.changes[0].badge == "M", "unstaged modify")
        check(st.changes[1].kinds == [.staged] && st.changes[1].badge == "A", "staged add")
        check(st.changes[2].origPath == "a.txt" && st.changes[2].path == "b.txt", "rename keeps old path")
        check(st.changes[3].isUntracked && st.changes[3].path == "notes ş.md" && st.changes[3].badge == "U", "untracked with a space and a non-ASCII letter")
        check(st.changes[4].isConflicted && st.conflicts.count == 1 && st.changes[4].badge == "!", "conflict")
    }

    test("git status edge cases: no upstream, detached, no commits, empty, both staged and unstaged") {
        check(GitStatus.parse(nul(["## topic"])).branch == "topic", "no upstream")
        let d = GitStatus.parse(nul(["## HEAD (no branch)"]))
        check(d.detached && d.branch == "HEAD", "detached")
        check(GitStatus.parse(nul(["## No commits yet on main"])).branch == "main", "unborn branch")
        check(GitStatus.parse(Data()).changes.isEmpty, "empty output")
        check(GitStatus.parse(nul(["## main", "MM both.txt"])).changes[0].kinds == [.staged, .unstaged], "staged and unstaged")
        check(GitStatus.parse(nul(["## main", "x"])).changes.isEmpty, "garbage field ignored")
        check(["AA", "DD", "UD", "DU", "AU", "UA"].allSatisfy { GitChange(path: "p", origPath: nil, x: $0.first!, y: $0.last!).isConflicted }, "all unmerged pairs")
    }

    test("diff parser: hunks, line numbers, colouring kinds, counts") {
        let text = """
        diff --git a/f.txt b/f.txt
        index 111..222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,4 @@ func x
         keep
        -old
        +new
        +extra
         tail
        \\ No newline at end of file
        """
        let d = DiffParser.parse(text)
        check(d.added == 2 && d.removed == 1, "counts \(d.added)/\(d.removed)")
        let kinds = d.lines.map(\.kind)
        check(kinds == [.meta, .meta, .meta, .meta, .hunk, .context, .del, .add, .add, .context, .note], "kinds \(kinds)")
        check(d.lines[5].oldNo == 1 && d.lines[5].newNo == 1, "context numbers")
        check(d.lines[6].oldNo == 2 && d.lines[6].newNo == nil, "deleted line number")
        check(d.lines[7].newNo == 2 && d.lines[8].newNo == 3, "added line numbers")
        check(d.lines[9].oldNo == 3 && d.lines[9].newNo == 4, "context after changes")
    }

    test("diff parser: dashes inside a hunk are content, second file resets, binary, truncation") {
        let two = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n--- not a header\n+++ also content\ndiff --git a/b b/b\n--- a/b\n+++ b/b\n@@ -5 +5 @@\n-x\n+y\n"
        let d = DiffParser.parse(two)
        check(d.removed == 2 && d.added == 2, "counts \(d.removed)/\(d.added)")
        check(d.lines.filter { $0.kind == .hunk }.count == 2, "two hunks")
        check(d.lines.first { $0.kind == .del && $0.text == "x" }?.oldNo == 5, "second file numbering restarts")
        check(DiffParser.parse("Binary files a/x and b/x differ\n").binary, "binary")
        let big = "@@ -1,9999 +1,9999 @@\n" + String(repeating: " l\n", count: 9000)
        let t = DiffParser.parse(big, maxLines: 100)
        check(t.truncated && t.lines.count == 100, "truncated at the cap")
        check(DiffParser.parse("").lines.isEmpty, "empty")
    }

    test("new and conflicted files render as added / marker views") {
        let a = DiffParser.asAdded("one\ntwo\n")
        check(a.added == 2 && a.lines.map(\.text) == ["one", "two"] && a.lines[1].newNo == 2, "all added")
        check(DiffParser.asAdded("a\0b").binary, "NUL means binary")
        let c = DiffParser.conflictView("x\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic\n")
        check(c.lines.filter { $0.kind == .hunk }.count == 3, "three markers called out")
    }

    test("worktree list parsing and the conflict card") {
        let text = "worktree /r/main\nHEAD abcdef1234567890\nbranch refs/heads/main\n\nworktree /r/wt-feature\nHEAD 1234567890abcdef\nbranch refs/heads/feature\nlocked\n\nworktree /r/old\nHEAD 0000000000000000\ndetached\nprunable gitdir file points to non-existent location\n"
        let w = Worktree.parse(text)
        check(w.count == 3 && w[0].branch == "main" && w[0].head == "abcdef12", "main \(w)")
        check(w[1].locked && w[1].branch == "feature", "locked linked")
        check(w[2].detached && w[2].prunable && w[2].branch == nil, "detached prunable")
        var st = GitStatus(); st.changes = [GitChange(path: "m.c", origPath: nil, x: "U", y: "U")]
        let card = ConflictCard.make(status: st, operation: "merge", worktrees: w, cwd: "/r/wt-feature/sub")
        check(card.isLinkedWorktree && card.files == ["m.c"] && card.otherWorktrees.count == 2, "linked card")
        check(card.title == "1 conflicted file during merge", card.title)
        let clean = ConflictCard.make(status: GitStatus(), operation: nil, worktrees: w, cwd: "/r/main")
        check(clean.isEmpty && !clean.isLinkedWorktree, "main worktree, nothing to show")
        check(ConflictCard.make(status: GitStatus(), operation: "rebase", worktrees: [], cwd: "/x").title == "A rebase is in progress", "operation only")
    }

    test("transcript: events, touched files, slug") {
        check(TranscriptParser.projectSlug("/w/my.proj/a") == "-w-my-proj-a", "slug")
        let jsonl = """
        {"type":"user","timestamp":"2026-11-04T10:00:00.000Z","message":{"role":"user","content":"fix the bug\\nplease"}}
        {"type":"user","timestamp":"2026-11-04T10:00:01.000Z","isMeta":true,"message":{"role":"user","content":"meta"}}
        {"type":"user","timestamp":"2026-11-04T10:00:02.000Z","message":{"role":"user","content":"<command-name>/model</command-name>"}}
        {"type":"assistant","timestamp":"2026-11-04T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"ok"},{"type":"tool_use","name":"Read","input":{"file_path":"/w/a.swift"}},{"type":"tool_use","name":"Edit","input":{"file_path":"/w/a.swift"}}]}}
        {"type":"assistant","timestamp":"2026-11-04T10:01:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift build\\n&& echo ok"}},{"type":"tool_use","name":"Write","input":{"file_path":"/w/b.swift"}}]}}
        {"type":"assistant","timestamp":"2026-11-04T10:02:00.000Z","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/w/a.swift"}}]}}
        not json at all
        {"type":"summary"}
        """
        let ev = TranscriptParser.parse(jsonl)
        check(ev.map(\.kind) == [.prompt, .read, .edit, .command, .write, .edit], "kinds \(ev.map(\.kind))")
        check(ev[0].detail == "fix the bug please", "prompt flattened to one line")
        check(ev[3].detail == "swift build && echo ok", "command flattened")
        check(ev[0].time != nil && ev[3].time != nil, "both timestamp styles parse")
        let t = TranscriptParser.touchedFiles(ev)
        check(t.map(\.path) == ["/w/a.swift", "/w/b.swift"], "most recently touched first, reads excluded: \(t.map(\.path))")
        check(t[0].edits == 2 && t[1].edits == 1, "edit counts")
        check(TranscriptParser.oneLine(String(repeating: "x", count: 500)).count == 161, "long text cut")
    }

    test("display formatting") {
        check(InspectorFormat.displayPath("/w/p/src/a.swift", cwd: "/w/p", home: "/h") == "src/a.swift", "inside the folder")
        check(InspectorFormat.displayPath("/h/other/x", cwd: "/w/p", home: "/h") == "~/other/x", "under home")
        check(InspectorFormat.displayPath("/etc/hosts", cwd: "/w/p", home: "/h") == "/etc/hosts", "elsewhere")
        let now = Date(timeIntervalSince1970: 100_000)
        check(InspectorFormat.ago(now.addingTimeInterval(-5), now: now) == "just now" && InspectorFormat.ago(now.addingTimeInterval(-300), now: now) == "5 min ago", "ago")
        check(InspectorFormat.ago(nil) == "" && InspectorFormat.ago(now.addingTimeInterval(-90_000), now: now) == "1 d ago", "ago edge")
    }

    test("local source against a real throw-away repository") {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "inspector-test-\(UUID().uuidString)"
        let repo = base + "/repo"
        let home = base + "/home"
        defer { try? fm.removeItem(atPath: base) }
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let src = LocalGitSource()
        func git(_ a: [String]) { _ = src.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + a, in: repo) }
        git(["init", "-q", "-b", "main"])
        try "line1\nline2\nline3\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "keep\n".write(toFile: repo + "/gone.txt", atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-q", "-m", "init"])
        try "line1\nCHANGED\nline3\nline4\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try fm.removeItem(atPath: repo + "/gone.txt")
        try "brand new\n".write(toFile: repo + "/new ş.txt", atomically: true, encoding: .utf8)
        var snap = src.snapshot(cwd: repo)
        check(snap.root != nil && snap.status.branch == "main", "repo found, branch main: \(snap.status)")
        check(Set(snap.status.changes.map(\.path)) == ["a.txt", "gone.txt", "new ş.txt"], "changes \(snap.status.changes.map(\.path))")
        check(snap.card.isEmpty, "no conflicts on a clean index")
        guard let root = snap.root, let a = snap.status.changes.first(where: { $0.path == "a.txt" }) else { check(false, "a.txt listed"); return }
        let d = src.diff(root: root, change: a)
        check(d.added == 2 && d.removed == 1, "diff counts \(d.added)/\(d.removed)")
        check(d.lines.contains { $0.kind == .add && $0.text == "CHANGED" }, "added line present")
        let n = src.diff(root: root, change: snap.status.changes.first { $0.isUntracked }!)
        check(n.added == 1 && n.lines.first?.text == "brand new", "untracked file shown as added")
        let del = src.diff(root: root, change: snap.status.changes.first { $0.path == "gone.txt" }!)
        check(del.removed == 1, "deleted file diff")

        // A real merge conflict.
        git(["checkout", "-q", "-b", "topic"]); git(["checkout", "-q", "--", "a.txt"]); try "line1\nTOPIC\nline3\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        git(["commit", "-q", "-am", "topic"]); git(["checkout", "-q", "main"])
        git(["checkout", "-q", "--", "."]); try "line1\nMAIN\nline3\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        git(["commit", "-q", "-am", "main"])
        git(["merge", "topic"])
        snap = src.snapshot(cwd: repo)
        check(snap.card.operation == "merge" && snap.card.files == ["a.txt"], "conflict card \(snap.card)")
        let cv = src.diff(root: root, change: snap.status.conflicts[0])
        check(cv.lines.filter { $0.kind == .hunk }.count == 3, "markers shown")

        // Not a repository, missing folder.
        check(src.snapshot(cwd: base).root == nil, "plain folder is not a repo")
        check(src.snapshot(cwd: base + "/nope").root == nil, "missing folder")

        // Transcript lookup under a temp HOME.
        let slug = TranscriptParser.projectSlug(repo)
        try fm.createDirectory(atPath: home + "/.claude/projects/" + slug, withIntermediateDirectories: true)
        let line = "{\"type\":\"assistant\",\"timestamp\":\"2026-11-04T10:00:00.000Z\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"\(repo)/a.txt\"}}]}}\n"
        try ("garbage-cut-line\n" + line).write(toFile: home + "/.claude/projects/" + slug + "/s1.jsonl", atomically: true, encoding: .utf8)
        let ev = src.events(cwd: repo, root: root, home: home)
        check(ev.count == 1 && ev[0].kind == .edit, "transcript read from the temp home: \(ev)")
        check(src.events(cwd: base, root: nil, home: home).isEmpty, "folder without transcripts")
    }

    test("Activity AGENT FILES: edited vs read-only, counts, first-touched order") {
        func ev(_ k: ActivityEvent.Kind, _ p: String, _ t: Double) -> ActivityEvent { ActivityEvent(time: Date(timeIntervalSince1970: t), kind: k, title: "", detail: p, path: p) }
        let s = AgentFiles.split([ev(.read, "/r/a", 1), ev(.edit, "/r/b", 2), ev(.edit, "/r/b", 3), ev(.read, "/r/b", 4), ev(.read, "/r/c", 5), ev(.read, "/r/a", 6)])
        check(s.modified == [AgentFile(path: "/r/b", count: 2)], "modified: \(s.modified)")
        check(s.read.map(\.path) == ["/r/a", "/r/c"] && s.read[0].count == 2, "read in first-touched order, edited file not repeated: \(s.read)")
    }

    test("side-by-side diff pairs removed and added lines row by row") {
        var d = DiffResult()
        d.lines = [DiffLine(kind: .hunk, text: "@@ -1,3 +1,3 @@", oldNo: nil, newNo: nil),
                   DiffLine(kind: .del, text: "a", oldNo: 1, newNo: nil), DiffLine(kind: .del, text: "b", oldNo: 2, newNo: nil),
                   DiffLine(kind: .add, text: "A", oldNo: nil, newNo: 1),
                   DiffLine(kind: .context, text: "c", oldNo: 3, newNo: 2)]
        let r = SideBySide.rows(d)
        check(r.count == 4 && r[0].separator != nil, "hunk row spans both sides")
        check(r[1].left?.text == "a" && r[1].right?.text == "A" && r[2].left?.text == "b" && r[2].right == nil, "pairs then leaves the shorter side empty")
        check(r[3].left?.text == "c" && r[3].right?.text == "c", "context on both sides")
    }

    test("approval prompt key splits into tool, target and question") {
        let p = InspectorApproval.parse(promptKey: "Write|src/a.rs|Do you want to create a.rs?")
        check(p.tool == "Write" && p.target == "src/a.rs" && p.question == "Do you want to create a.rs?", "\(p)")
        check(InspectorApproval.parse(promptKey: "").tool == "", "empty key")
    }
}
