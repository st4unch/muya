// Unit tests of the Queue / Branches / Kanban logic (Sources/Queue/QueueLogic.swift) and of the interim local
// source, run against a throw-away repository in a temp directory (never a real repo, never a remote).

import Foundation

private func git(_ dir: String, _ args: [String], env: [String: String] = [:]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    var e = ProcessInfo.processInfo.environment
    for (k, v) in env { e[k] = v }
    p.environment = e
    let out = Pipe()
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    try? p.run()
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

private func node(_ sha: String, _ parents: [String]) -> CommitNode { CommitNode(sha: sha + "0000000", parents: parents.map { $0 + "0000000" }) }

func runQueueTests() {
    test("git runs in a hostile repository: a configured fsmonitor / hooks path is never executed") {
        let dir = NSTemporaryDirectory() + "muya-gitargs-\(getpid())"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = git(dir, ["init", "-q"])
        let marker = dir + "/PWNED"
        let script = dir + "/evil.sh"
        try? "#!/bin/sh\necho x > '\(marker)'\nprintf ''\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        _ = git(dir, ["config", "core.fsmonitor", script])
        // Without the app's prefix git runs the program on `status` (this proves the test can see the problem) ...
        _ = git(dir, ["status", "--porcelain"])
        check(FileManager.default.fileExists(atPath: marker), "plain git status runs core.fsmonitor (the hazard exists)")
        try? FileManager.default.removeItem(atPath: marker)
        // ... and not with it, through the real call path of the Inspector and the Queue.
        _ = LocalGitSource().run(["status", "--porcelain"], in: dir)
        _ = LocalQueueSource().run(["status", "--porcelain"], in: dir)
        check(!FileManager.default.fileExists(atPath: marker), "the app's git calls do not run core.fsmonitor")
    }

    test("ahead/behind: counts, tracking text, gone upstream, garbage") {
        check(AheadBehind.parseCount("3\t5\n") == AheadBehind(ahead: 5, behind: 3), "left-right count is behind then ahead")
        check(AheadBehind.parseCount("0 0") == AheadBehind(), "zeros")
        check(AheadBehind.parseCount("x\t1") == nil && AheadBehind.parseCount("1") == nil && AheadBehind.parseCount("") == nil && AheadBehind.parseCount("-1\t2") == nil, "garbage")
        check(AheadBehind.parseTrack("[ahead 2, behind 1]") == AheadBehind(ahead: 2, behind: 1), "both")
        check(AheadBehind.parseTrack("[behind 4]") == AheadBehind(ahead: 0, behind: 4), "behind only")
        check(AheadBehind.parseTrack("[ahead 7]").ahead == 7, "ahead only")
        check(AheadBehind.parseTrack("[gone]").gone, "gone")
        check(AheadBehind.parseTrack("") == AheadBehind(), "in sync")
    }

    test("queue rows: status, checks and which buttons are enabled") {
        var e = QueueEntry(branch: "feat", worktree: nil, upstream: "origin/feat", vsUpstream: AheadBehind(), vsBase: AheadBehind(ahead: 2, behind: 0), base: "main")
        check(e.status == .readyToMerge && e.canMerge && !e.canPush && !e.canDelete, "pushed and ahead of main: merge only")
        check(e.checksSummary == "3/3", "all checks pass: \(e.checksSummary)")
        e.vsUpstream.ahead = 1
        check(e.status == .pushNeeded && e.canPush, "unpushed commits")
        e.vsUpstream.ahead = 0; e.vsBase.behind = 3
        check(e.status == .needsRebase && e.checks.contains { $0.name.hasPrefix("up to date") && !$0.pass }, "behind main")
        e.vsBase.behind = 0; e.upstream = nil
        check(e.status == .noUpstream && e.canPush, "no upstream: push offered")
        if case let .push(_, _, up) = e.pushAction() { check(up, "first push sets the upstream") } else { check(false, "push action") }
        e.dirty = true
        check(e.status == .dirty && !e.canPush && !e.canMerge, "dirty tree blocks push and merge")
        e.dirty = false; e.vsBase = AheadBehind()
        check(e.status == .merged && e.canDelete && !e.canMerge && !e.canPush, "merged branch can be deleted, nothing to send")
        e.worktree = "/x/wt"
        check(!e.canDelete, "a branch with a worktree cannot be deleted")
        let base = QueueEntry(branch: "main", worktree: "/x", upstream: "origin/main", vsUpstream: AheadBehind(ahead: 2, behind: 0), base: "main", isBase: true)
        check(base.status == .pushNeeded && base.canPush && !base.canMerge && !base.canDelete, "base branch: push only")
    }

    test("queue order and the commands the buttons would run") {
        let mk = { (n: String, ab: Int, up: String?) in QueueEntry(branch: n, upstream: up, vsBase: AheadBehind(ahead: ab, behind: 0)) }
        let sorted = [mk("z-merged", 0, "o/z"), mk("b-ready", 1, "o/b"), mk("a-ready", 1, "o/a"), mk("c-noup", 1, nil)].sorted(by: QueueEntry.order).map(\.branch)
        check(sorted == ["a-ready", "b-ready", "c-noup", "z-merged"], "ready first (by name), no-upstream next, merged last: \(sorted)")
        check(QueueAction.push(branch: "f", remote: "origin", setUpstream: true).commandLine == "git push -u origin f", "push -u")
        check(QueueAction.push(branch: "f", remote: "origin", setUpstream: false).commandLine == "git push origin f", "push")
        check(QueueAction.merge(branch: "f", into: "main").commandLine.hasSuffix("git merge --no-ff f"), "merge")
        check(QueueAction.deleteBranch("f").commandLine == "git branch -d f", "delete uses the safe -d")
        let log = InterimActionLog()
        check(log.record(.deleteBranch("f")) == "would run: git branch -d f" && log.lines.count == 1, "interim handler only records")
    }

    test("for-each-ref parser") {
        let r = QueueParser.branches("main\torigin/main\t\t*\tinit\nfeat\t\t\t \twip: thing\ngone\torigin/gone\t[gone]\t \tx\n\n")
        check(r.count == 3 && r[0].head && r[0].upstream == "origin/main", "main is HEAD with upstream")
        check(r[1].upstream == nil && r[1].subject == "wip: thing", "no upstream")
        check(r[2].track.gone, "gone upstream")
    }

    test("DAG lanes: linear history stays in lane 0") {
        let rows = DagLayout.layout([node("c", ["b"]), node("b", ["a"]), node("a", [])])
        check(rows.map(\.lane) == [0, 0, 0], "lanes \(rows.map(\.lane))")
        check(rows[0].incoming.isEmpty && rows[0].outgoing == [0], "tip has nothing above")
        check(rows[1].incoming == [0] && rows[2].outgoing.isEmpty, "root has nothing below")
    }

    test("DAG lanes: branch and merge") {
        // m merges f into main; f and a branch from base b.
        let rows = DagLayout.layout([node("m", ["a", "f"]), node("f", ["b"]), node("a", ["b"]), node("b", [])])
        check(rows[0].lane == 0 && rows[0].outgoing == [0, 1], "merge commit opens lane 1: \(rows[0])")
        check(rows[1].lane == 1 && rows[1].through == [0], "f sits in lane 1 while lane 0 passes through")
        check(rows[1].outgoing == [1], "f continues in its own lane")
        check(rows[2].lane == 0 && rows[2].through == [1] && rows[2].outgoing == [1], "a's line joins the lane already waiting for b: \(rows[2])")
        check(rows[3].lane == 1 && rows[3].incoming == [1], "base b sits where both lines meet: \(rows[3])")
        check(rows[3].laneCount >= 2, "width tracked")
    }

    test("DAG lanes: a free lane is reused, octopus merge, unknown parent") {
        let rows = DagLayout.layout([node("m", ["a", "b", "c"]), node("a", []), node("b", []), node("c", [])])
        check(rows[0].outgoing == [0, 1, 2], "octopus opens three lanes: \(rows[0].outgoing)")
        check(rows.map(\.lane) == [0, 0, 1, 2], "lanes \(rows.map(\.lane))")
        let cut = DagLayout.layout([node("x", ["missing"]), node("y", [])])
        check(cut[1].lane == 1 && cut[0].outgoing == [0], "history cut by -n: parent never shows up, nothing crashes: \(cut.map(\.lane))")
        check(DagLayout.layout([]).isEmpty, "empty")
    }

    test("DAG lanes: property on a random 3,000-commit history") {
        var rng = SplitMix(s: 42)
        var commits: [CommitNode] = []
        // Build forward (parents earlier in an array), then reverse to children-first topo order.
        var shas: [String] = []
        for i in 0..<3000 {
            let sha = String(format: "%07x", i + 1) + "0000000"
            var ps: [String] = []
            if i > 0 {
                ps.append(shas[Int.random(in: max(0, i - 6)..<i, using: &rng)])
                if Int.random(in: 0..<7, using: &rng) == 0 { let p = shas[Int.random(in: max(0, i - 40)..<i, using: &rng)]; if p != ps[0] { ps.append(p) } }
            }
            shas.append(sha)
            commits.append(CommitNode(sha: sha, parents: ps))
        }
        commits.reverse()
        let rows = DagLayout.layout(commits)
        check(rows.count == commits.count, "one row per commit")
        var ok = true
        var rowOf: [String: Int] = [:]
        for (i, c) in commits.enumerated() { rowOf[c.sha] = i }
        for (i, r) in rows.enumerated() {
            if r.outgoing.count != commits[i].parents.count { ok = false }
            if Set(r.through).contains(r.lane) { ok = false }
            if r.laneCount < r.lane + 1 { ok = false }
            if Set(r.outgoing).count != r.outgoing.count && commits[i].parents.count == Set(commits[i].parents).count { ok = false }
            // Every parent's row sees the lane this edge was drawn in as incoming.
            for (n, p) in commits[i].parents.enumerated() {
                if let pr = rowOf[p], !rows[pr].incoming.contains(r.outgoing[n]) { ok = false }
            }
        }
        check(ok, "edges and lanes are consistent")
        check(rows.reduce(0) { max($0, $1.laneCount) } < 40, "lane count stays small: \(rows.reduce(0) { max($0, $1.laneCount) })")
    }

    test("git log record parser") {
        let rec = "aaaaaaa1\u{1F}bbbbbbb2 ccccccc3\u{1F}HEAD -> main, origin/main, tag: v1\u{1F}Ann\u{1F}1700000000\u{1F}fix: a | b\u{1E}\ndddddd04\u{1F}\u{1F}\u{1F}Bob\u{1F}0\u{1F}root\u{1E}\n"
        let c = DagLayout.parse(rec)
        check(c.count == 2, "two records")
        check(c[0].parents == ["bbbbbbb2", "ccccccc3"] && c[0].refs == ["main", "origin/main", "tag: v1"] && c[0].subject == "fix: a | b" && c[0].time == 1_700_000_000, "fields: \(c[0])")
        check(c[1].parents.isEmpty && c[1].refs.isEmpty && c[1].short == "dddddd0", "root commit")
        check(DagLayout.parse("junk").isEmpty, "garbage ignored")
    }

    test("kanban: classify, front matter, status rewrite") {
        check(KanbanColumn.classify("done") == .done && KanbanColumn.classify("Shipped v2") == .done, "done")
        check(KanbanColumn.classify("active") == .active && KanbanColumn.classify("in progress") == .active && KanbanColumn.classify("implementing") == .active, "active")
        check(KanbanColumn.classify("awaiting review") == .review && KanbanColumn.classify("pending") == .review, "review")
        check(KanbanColumn.classify("draft") == .draft && KanbanColumn.classify("blocked") == .draft && KanbanColumn.classify("") == .draft, "draft is the default")
        let doc = "---\nstatus: \"active\"\nprd: x\n---\n# Title\nbody status: keep\n"
        check(KanbanFile.status(of: doc) == "active", "status from front matter")
        check(KanbanFile.status(of: "# no front matter\nstatus: done") == "", "body lines are not front matter")
        check(KanbanFile.title(of: doc) == "Title", "title")
        let moved = KanbanFile.settingStatus("review", in: doc)
        check(KanbanFile.status(of: moved) == "review" && moved.contains("prd: x") && moved.contains("body status: keep"), "rewrite keeps everything else: \(moved.debugDescription)")
        check(KanbanFile.status(of: KanbanFile.settingStatus("done", in: "---\nprd: x\n---\nbody")) == "done", "adds status when missing")
        check(KanbanFile.status(of: KanbanFile.settingStatus("done", in: "just text")) == "done", "adds front matter when missing")
    }

    test("kanban board: moves and neighbours") {
        var b = KanbanBoard(cards: [KanbanCard(slug: "a", title: "A", status: "draft", file: ""), KanbanCard(slug: "b", title: "B", status: "active", file: ""), KanbanCard(slug: "c", title: "C", status: "draft", file: "")])
        check(b.cards(in: .draft).map(\.slug) == ["a", "c"], "two drafts")
        check(b.move(slug: "a", to: .review) && b.cards(in: .review).map(\.slug) == ["a"] && b.cards(in: .draft).map(\.slug) == ["c"], "moved")
        check(b.cards.first { $0.slug == "a" }?.status == "review", "status word follows the column")
        check(!b.move(slug: "a", to: .review) && !b.move(slug: "zzz", to: .done), "no-op moves rejected")
        check(b.move(slug: "b", to: .active) == false, "already there")
        check(KanbanBoard.neighbour(of: .draft, step: -1) == .draft && KanbanBoard.neighbour(of: .done, step: 1) == .done && KanbanBoard.neighbour(of: .active, step: 1) == .review, "clamped neighbours")
    }

    test("local source against a throw-away repo: queue, log, cards, interim write goes to a copy") {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "queue-test-\(getpid())"
        defer { try? fm.removeItem(atPath: tmp) }
        let repo = tmp + "/repo", origin = tmp + "/origin.git", copies = tmp + "/copies"
        try? fm.createDirectory(atPath: repo + "/docs", withIntermediateDirectories: true)
        _ = git(tmp, ["init", "--bare", "-q", origin])
        _ = git(repo, ["init", "-q"])
        func commit(_ file: String, _ msg: String) { try? msg.write(toFile: repo + "/" + file, atomically: true, encoding: .utf8); _ = git(repo, ["add", "-A"]); _ = git(repo, ["commit", "-q", "-m", msg]) }
        commit("a.txt", "one")
        _ = git(repo, ["remote", "add", "origin", origin]); _ = git(repo, ["push", "-q", "-u", "origin", "main"])
        _ = git(repo, ["checkout", "-q", "-b", "stale"]); commit("s.txt", "stale work"); _ = git(repo, ["checkout", "-q", "main"])
        commit("m.txt", "main moves on")
        try? "---\nstatus: active\n---\n".write(toFile: repo + "/docs/prd-alpha.progress.md", atomically: true, encoding: .utf8)
        try? "# Alpha feature\n".write(toFile: repo + "/docs/prd-alpha.md", atomically: true, encoding: .utf8)
        try? "---\nstatus: done\n---\n".write(toFile: repo + "/docs/prd-beta.progress.md", atomically: true, encoding: .utf8)
        _ = git(repo, ["add", "-A"]); _ = git(repo, ["commit", "-q", "-m", "docs"])
        _ = git(repo, ["push", "-q", "origin", "main"])
        _ = git(repo, ["branch", "merged"])
        _ = git(repo, ["checkout", "-q", "-b", "ready"]); commit("r.txt", "ready work"); _ = git(repo, ["push", "-q", "-u", "origin", "ready"])
        _ = git(repo, ["checkout", "-q", "main"])
        _ = git(repo, ["checkout", "-q", "-b", "unpushed"]); commit("u.txt", "unpushed work")
        _ = git(repo, ["checkout", "-q", "main"])

        let src = LocalQueueSource(copyDir: copies)
        let q = src.queue(cwd: repo)
        check(q.root != nil && q.base == "main", "git root and base found: \(q.base)")
        let by = Dictionary(uniqueKeysWithValues: q.entries.map { ($0.branch, $0) })
        check(by["ready"]?.status == .readyToMerge, "ready: \(String(describing: by["ready"]?.status)) \(String(describing: by["ready"]))")
        check(by["unpushed"]?.status == .noUpstream, "unpushed: \(String(describing: by["unpushed"]?.status))")
        check(by["merged"]?.status == .merged && by["merged"]?.canDelete == true, "merged: \(String(describing: by["merged"]?.status))")
        check(by["stale"]?.status == .needsRebase && by["stale"]?.vsBase == AheadBehind(ahead: 1, behind: 2), "stale branched before main moved: \(String(describing: by["stale"]))")
        check(by["ready"]?.vsBase == AheadBehind(ahead: 1, behind: 0), "ready is 1 ahead of main: \(String(describing: by["ready"]?.vsBase))")
        check(by["main"]?.isBase == true && by["main"]?.worktree != nil, "main is the base, checked out")
        check(q.entries.first?.branch != "merged", "merged sorts last, not first")

        let log = src.commits(cwd: repo, limit: 100)
        check(log.count >= 6 && log.contains { $0.refs.contains("main") } && log.contains { $0.refs.contains("origin/ready") }, "log has commits and branch refs: \(log.count)")
        check(DagLayout.layout(log).count == log.count, "layout covers the log")
        check(src.commits(cwd: tmp, limit: 10).isEmpty, "not a repo: nothing")

        // Tracked projects: the fields of today's pm_status.
        _ = git(repo, ["checkout", "-q", "ready"])
        try? "x".write(toFile: repo + "/dirty.txt", atomically: true, encoding: .utf8)
        let tp = src.tracked(paths: [repo, tmp])
        check(tp.count == 2 && tp[0].isGit && !tp[1].isGit, "tracked: a repo and a plain folder")
        check(tp[0].branch == "ready" && tp[0].base == "main" && tp[0].ahead == 1 && tp[0].behind == 0 && tp[0].changed == 1 && tp[0].dirty == 1, "tracked status of a branch: \(tp[0])")
        check(tp[0].lastActivity > 0 && tp[0].name == (repo as NSString).lastPathComponent, "tracked name and last commit time")
        check(src.mergeCheck(path: repo, branch: "ready", base: "main") == true, "trial merge of a clean branch")
        let h = tmp + "/prefs-home"
        check(QueuePrefs.load(home: h).isEmpty, "no prefs file: empty queue")
        let pf = QueuePrefs.file(home: h)
        try? FileManager.default.createDirectory(atPath: (pf as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? "{\"other.key\":\"keep\",\"apex.mergeQueue\":\"[\\\"/a\\\"]\"}".write(toFile: pf, atomically: true, encoding: .utf8)
        check(QueuePrefs.load(home: h) == ["/a"], "reads a migrated localStorage value")
        check(QueuePrefs.save(["/a", "/b"], home: h) && QueuePrefs.load(home: h) == ["/a", "/b"], "save then load")
        check((try? String(contentsOfFile: pf, encoding: .utf8))?.contains("\"other.key\":\"keep\"") == true, "other prefs keys are kept")
        try? "not json".write(toFile: pf, atomically: true, encoding: .utf8)
        check(!QueuePrefs.save(["/z"], home: h) && (try? String(contentsOfFile: pf, encoding: .utf8)) == "not json", "an unreadable file is not overwritten")
        check(TrackedProject(path: "/x", name: "x", lastActivity: 0).age() == "–" && TrackedProject(path: "/x", name: "x", lastActivity: 100).age(now: Date(timeIntervalSince1970: 100 + 3 * 86400 + 5)) == "3d ago", "age text")
        try? FileManager.default.removeItem(atPath: repo + "/dirty.txt")
        _ = git(repo, ["checkout", "-q", "main"])

        let cards = src.cards(cwd: repo)
        check(cards.map(\.slug) == ["alpha", "beta"] && cards[0].title == "Alpha feature" && cards[0].column == .active && cards[1].column == .done, "cards: \(cards)")
        let before = (try? String(contentsOfFile: repo + "/docs/prd-alpha.progress.md", encoding: .utf8)) ?? ""
        check(src.setStatus(slug: "alpha", column: .review, cwd: repo), "setStatus ok")
        check((try? String(contentsOfFile: repo + "/docs/prd-alpha.progress.md", encoding: .utf8)) == before, "the original file is untouched")
        check(src.cards(cwd: repo).first?.column == .review, "the copy is what the board shows next")
        check(git(repo, ["status", "--porcelain"]).isEmpty, "repo still clean after the move")
        check(!src.setStatus(slug: "nope", column: .done, cwd: repo), "unknown card")
    }
}
