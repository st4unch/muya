// Unit tests of the Faz 4e logic (Sources/Logic/Faz4eLogic.swift).

import Foundation

private func hist(_ id: String, mod: Int64, size: Int64, cwd: String = "/w/a", path: String? = nil) -> HistoryEntry {
    HistoryEntry(json: ["sessionId": id, "cwd": cwd, "path": path ?? "/p/\(id).jsonl", "lastModified": NSNumber(value: mod), "sizeBytes": NSNumber(value: size)])!
}

private func tmpDir() -> String {
    let d = NSTemporaryDirectory() + "faz4e-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func script(_ dir: String, _ name: String, _ body: String) -> String {
    let p = dir + "/" + name
    try? "#!/bin/sh\n\(body)\n".write(toFile: p, atomically: true, encoding: .utf8)
    chmod(p, 0o755)
    return p
}

func runFaz4eTests() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let nowMs = Int64(now.timeIntervalSince1970 * 1000)
    let day: Int64 = 86_400_000

    test("agents json: parse, status mapping, naming, newest first") {
        let json = """
        [{"sessionId":"aaa-1","cwd":"/w/alpha","kind":"interactive","status":"idle","startedAt":100,"pid":42},
         {"sessionId":"bbb-2","id":"bg1","name":"Fix tests","kind":"background","state":"blocked","status":"busy","waitingFor":"permission prompt","startedAt":900},
         {"sessionId":"ccc-3","cwd":"/w/gamma","status":"failed","startedAt":500,"parentSessionId":"aaa-1"},
         {"nope":1}]
        """
        let rows = AgentsLogic.parse(Data(json.utf8))!
        check(rows.map(\.sessionId) == ["bbb-2", "ccc-3", "aaa-1"], "newest first, junk dropped: \(rows.map(\.sessionId))")
        check(rows[0].status == "waiting-for-input" && rows[0].statusLabel == "Waiting · permission prompt", "state wins over status")
        check(rows[0].name == "Fix tests" && rows[0].shortId == "bg1", "given name and short id")
        check(rows[1].status == "stopped" && rows[1].name == "gamma" && rows[1].parentId == "aaa-1", "name from the folder")
        check(rows[2].status == "idle" && rows[2].pid == 42 && rows[2].shortId == "aaa", "short id from the session id")
        check(AgentsLogic.parse(Data("error: unknown option '--json'".utf8)) == nil, "not JSON")
        check(AgentsLogic.parse(Data("{}".utf8)) == nil, "not an array")
        check(AgentsLogic.parse(Data("[]".utf8))?.isEmpty == true, "empty list is valid")
    }

    test("claude is picked by capability: an old binary that rejects --json is skipped") {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let old = script(d, "old-claude", "if [ \"$2\" = \"--json\" ]; then echo \"error: unknown option\" >&2; exit 1; fi\necho 2.1.78")
        let new = script(d, "new-claude", "echo '[{\"sessionId\":\"s1\",\"cwd\":\"/x\",\"status\":\"idle\"}]'")
        check(!AgentsLogic.supportsAgentsJSON(old), "old rejects")
        check(AgentsLogic.supportsAgentsJSON(new), "new answers")
        check(AgentsLogic.resolve([old, "/nonexistent/claude", new], probe: AgentsLogic.supportsAgentsJSON) == new, "resolves the capable one")
        check(AgentsLogic.resolve([old], probe: AgentsLogic.supportsAgentsJSON) == nil, "nothing capable")
        let rows = AgentsLogic.runAgents(new).flatMap(AgentsLogic.parse)
        check(rows?.count == 1, "runAgents output parses")
    }

    test("claude candidates: environment first, fallbacks after, no duplicates, no relative paths") {
        let c = AgentsLogic.candidates(home: "/home/u", loginShellAnswer: "/opt/x/claude", path: "/usr/bin:/opt/x:relative:/usr/bin")
        check(c.first == "/opt/x/claude", "login shell answer first: \(c)")
        check(c.filter { $0 == "/opt/x/claude" }.count == 1, "deduplicated")
        check(!c.contains { !$0.hasPrefix("/") }, "no relative path")
        check(c.contains("/home/u/.local/bin/claude") && c.contains("/opt/homebrew/bin/claude"), "fallbacks")
        check(AgentsLogic.candidates(home: "/h", loginShellAnswer: "claude", path: nil).first == "/h/.local/bin/claude", "a bare name from the shell is ignored")
    }

    test("a hung claude is killed at the time limit") {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let hang = script(d, "hang", "sleep 30")
        let t0 = Date()
        check(AgentsLogic.runAgents(hang, timeout: 1) == nil, "no answer")
        check(Date().timeIntervalSince(t0) < 6, "returned after \(Date().timeIntervalSince(t0)) s")
    }

    test("clean-up rules: older or larger, never live or just used, biggest first, rules off = none") {
        let es = [hist("old", mod: nowMs - 40 * day, size: 10), hist("big", mod: nowMs - day, size: 300 << 20), hist("fresh", mod: nowMs - 60_000, size: 900 << 20),
                  hist("live", mod: nowMs - 90 * day, size: 5), hist("small", mod: nowMs - 2 * day, size: 5)]
        let r = CleanupLogic.Rules(olderDays: 30, largerMB: 100)
        check(CleanupLogic.candidates(es, r, live: ["live"], now: now).map(\.sessionId) == ["big", "old"], "picked")
        check(Set(CleanupLogic.heldBack(es, r, live: ["live"], now: now).map(\.sessionId)) == ["fresh", "live"], "held back")
        check(CleanupLogic.candidates(es, .init(olderDays: nil, largerMB: nil), live: [], now: now).isEmpty, "no rule, no pick")
        check(CleanupLogic.candidates(es, .init(olderDays: 30, largerMB: nil), live: [], now: now).map(\.sessionId) == ["old", "live"].filter { $0 == "old" || $0 == "live" }, "older only")
    }

    test("trash safety: only real transcripts two levels under the projects root") {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = tmpDir(); defer { try? FileManager.default.removeItem(atPath: outside) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/proj", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/proj/s1.jsonl", contents: Data("{}".utf8))
        fm.createFile(atPath: root + "/proj/notes.txt", contents: Data())
        fm.createFile(atPath: outside + "/x.jsonl", contents: Data())
        try fm.createDirectory(atPath: root + "/proj/deep", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/proj/deep/s2.jsonl", contents: Data())
        try fm.createSymbolicLink(atPath: root + "/proj/link.jsonl", withDestinationPath: outside + "/x.jsonl")
        check(CleanupLogic.checkedTranscript(root + "/proj/s1.jsonl", root: root) != nil, "a transcript passes")
        check(CleanupLogic.checkedTranscript(root + "/proj/notes.txt", root: root) == nil, "wrong extension")
        check(CleanupLogic.checkedTranscript(outside + "/x.jsonl", root: root) == nil, "outside the root")
        check(CleanupLogic.checkedTranscript(root + "/proj/deep/s2.jsonl", root: root) == nil, "too deep")
        check(CleanupLogic.checkedTranscript(root + "/proj/link.jsonl", root: root) == nil, "a symlink out of the root")
        check(CleanupLogic.checkedTranscript(root + "/../" + (root as NSString).lastPathComponent + "/proj/s1.jsonl", root: root) != nil, "dot-dot is resolved, still inside")
        check(CleanupLogic.checkedTranscript(root + "/proj/missing.jsonl", root: root) == nil, "missing file")
        check(CleanupLogic.resultLine(done: 2, skipped: [("a", "session is running"), ("b", "session is running")]) == "Moved to the Trash: 2 sessions. 2 sessions left as they were (session is running).", "result line")
        check(CleanupLogic.resultLine(done: 0, skipped: []) == "Nothing moved to the Trash.", "nothing")
    }

    test("transcript tail: user/assistant turns only, tool use as a marker, newest N, truncation") {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        var lines: [String] = ["{\"type\":\"summary\",\"summary\":\"x\"}", "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"role\":\"user\",\"content\":\"meta\"}}"]
        for i in 0 ..< 30 {
            lines.append("{\"type\":\"user\",\"timestamp\":\"2026-01-01T10:00:\(String(format: "%02d", i))Z\",\"message\":{\"role\":\"user\",\"content\":\"question \(i)\"}}")
            lines.append("{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"answer \(i)\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}")
            lines.append("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"HUGE\"}]}}")
        }
        lines.append("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(String(repeating: "x", count: 5000))\"}}")
        let p = d + "/t.jsonl"
        try lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8)
        let all = try TranscriptLogic.tail(path: p, cap: 1000)
        check(all.count == 61, "turns: \(all.count)")
        check(all[0].text == "question 0" && all[0].timestamp == "2026-01-01T10:00:00Z", "first turn")
        check(all[1].text == "answer 0\n🔧 [Bash]", "assistant text and tool marker: \(all[1].text)")
        check(!all.contains { $0.text.contains("HUGE") || $0.text == "meta" }, "tool results and meta skipped")
        check(all.last!.text.hasSuffix("… [truncated]") && all.last!.text.count < 4100, "long text truncated")
        let last5 = try TranscriptLogic.tail(path: p, cap: 5)
        check(last5.count == 5 && last5.last == all.last, "newest 5")
        let small = try TranscriptLogic.tail(path: p, cap: 3, firstWindow: 600) // window grows until it holds enough
        check(small.count == 3 && small.last == all.last, "tiny window grows: \(small.count)")
        check(TranscriptLogic.render([all[0]]).hasPrefix("You · 2026-01-01 10:00:00\nquestion 0"), "render: \(TranscriptLogic.render([all[0]]))")
        var threw = false
        do { _ = try TranscriptLogic.tail(path: d + "/missing.jsonl") } catch { threw = true }
        check(threw, "missing file throws")
    }

    test("auto-allow: after 2 s, once per prompt, again after the prompt went away; off = never") {
        var t = AutoAllowTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        check(t.tick(prompting: ["7"], enabled: true, now: t0).isEmpty, "not yet")
        check(t.tick(prompting: ["7"], enabled: true, now: t0.addingTimeInterval(1.9)).isEmpty, "1.9 s")
        check(t.nextDue(now: t0.addingTimeInterval(1.5)).map { abs($0 - 0.5) < 0.001 } == true, "due in 0.5 s")
        check(t.tick(prompting: ["7"], enabled: true, now: t0.addingTimeInterval(2)) == ["7"], "at 2 s")
        check(t.tick(prompting: ["7"], enabled: true, now: t0.addingTimeInterval(5)).isEmpty, "answered once")
        check(t.nextDue(now: t0.addingTimeInterval(5)) == nil, "nothing waits")
        check(t.tick(prompting: [], enabled: true, now: t0.addingTimeInterval(6)).isEmpty, "prompt gone")
        check(t.tick(prompting: ["7"], enabled: true, now: t0.addingTimeInterval(7)).isEmpty, "a new prompt waits again")
        check(t.tick(prompting: ["7", "9"], enabled: true, now: t0.addingTimeInterval(9.1)) == ["7"], "7 is due; 9 only just appeared")
        check(t.tick(prompting: ["9"], enabled: true, now: t0.addingTimeInterval(11.2)) == ["9"], "9 fires 2 s after it appeared")
        var off = AutoAllowTracker()
        _ = off.tick(prompting: ["1"], enabled: false, now: t0)
        check(off.tick(prompting: ["1"], enabled: false, now: t0.addingTimeInterval(60)).isEmpty, "off never fires")
        check(off.tick(prompting: ["1"], enabled: true, now: t0.addingTimeInterval(61)).isEmpty, "turning it on starts the 2 s wait")
    }

    test("auto-allow: many sessions at once, back-to-back prompts, manual answer") {
        let t0 = Date(timeIntervalSince1970: 1000)
        for n in [2, 5] {
            var t = AutoAllowTracker()
            let ids = Set((1 ... n).map { "\($0)|Bash|ls|" })
            _ = t.tick(prompting: ids, enabled: true, now: t0)
            check(t.tick(prompting: ids, enabled: true, now: t0.addingTimeInterval(2)) == ids.sorted(), "\(n) sessions all fire")
            check(t.tick(prompting: ids, enabled: true, now: t0.addingTimeInterval(9)).isEmpty, "\(n): never twice")
        }
        var t = AutoAllowTracker()
        _ = t.tick(prompting: ["1|Bash|ls|"], enabled: true, now: t0)
        check(t.tick(prompting: ["1|Bash|ls|"], enabled: true, now: t0.addingTimeInterval(2)) == ["1|Bash|ls|"], "first")
        t.renew("1|Bash|ls|", now: t0.addingTimeInterval(3))   // same id redrawn: back-to-back prompt
        check(t.tick(prompting: ["1|Bash|ls|"], enabled: true, now: t0.addingTimeInterval(4)).isEmpty, "waits 2 s again")
        check(t.tick(prompting: ["1|Bash|ls|"], enabled: true, now: t0.addingTimeInterval(5)) == ["1|Bash|ls|"], "second same-id prompt fires")
        check(t.tick(prompting: ["1|Bash|pwd|"], enabled: true, now: t0.addingTimeInterval(6)).isEmpty, "different id starts waiting")
        check(t.tick(prompting: ["1|Bash|pwd|"], enabled: true, now: t0.addingTimeInterval(8)) == ["1|Bash|pwd|"], "different id fires")
        var m = AutoAllowTracker()
        _ = m.tick(prompting: ["2|Edit|a|"], enabled: true, now: t0)
        check(m.tick(prompting: [], enabled: true, now: t0.addingTimeInterval(1)).isEmpty, "answered by hand")
        check(m.tick(prompting: [], enabled: true, now: t0.addingTimeInterval(3)).isEmpty, "never re-answered")
        m.renew("2|Edit|a|", now: t0)   // renew on an unanswered/unknown id is a no-op
        check(m.nextDue(now: t0) == nil, "no phantom timer")
    }

    test("resume on launch: only when on, with no live terminals, safe ids, existing folders, capped, deduplicated") {
        let saved = [ResumeEntry(sessionId: "a-1", cwd: "/ok", name: "A"), ResumeEntry(sessionId: "a-1", cwd: "/ok", name: "dup"), ResumeEntry(sessionId: "b'; rm -rf ~", cwd: "/ok", name: "evil"),
                     ResumeEntry(sessionId: "c-3", cwd: "/gone", name: "C")] + (0 ..< 12).map { ResumeEntry(sessionId: "n\($0)", cwd: "/ok", name: "n\($0)") }
        let exists: (String) -> Bool = { $0 == "/ok" }
        let plan = ResumeLogic.plan(saved: saved, enabled: true, liveTerminals: 0, existingFolders: exists)
        check(plan.count == 8 && plan[0].sessionId == "a-1" && plan[1].sessionId == "n0", "capped, deduped, filtered: \(plan.map(\.sessionId))")
        check(ResumeLogic.plan(saved: saved, enabled: false, liveTerminals: 0, existingFolders: exists).isEmpty, "off")
        check(ResumeLogic.plan(saved: saved, enabled: true, liveTerminals: 2, existingFolders: exists).isEmpty, "daemon kept its terminals")
        let rows = AgentsLogic.parse(Data("[{\"sessionId\":\"x-1\",\"cwd\":\"/w\",\"status\":\"busy\"},{\"sessionId\":\"y-2\",\"cwd\":\"/w\",\"kind\":\"background\",\"id\":\"b\"},{\"sessionId\":\"z-3\",\"cwd\":\"/w\",\"status\":\"stopped\"}]".utf8))!
        check(ResumeLogic.snapshot(from: rows).map(\.sessionId) == ["x-1"], "snapshot keeps live interactive sessions")
        check(ResumeEntry(json: ResumeEntry(sessionId: "q", cwd: "/c", name: "n").json) == ResumeEntry(sessionId: "q", cwd: "/c", name: "n"), "json round trip")
    }

    test("scheduled prompts: validation, edit, due once, recent five") {
        var s = ScheduledPrompts()
        let n = Date(timeIntervalSince1970: 5000)
        func fails(_ prompt: String, _ t: [UInt64], _ at: Date) -> ScheduledPrompts.Failure? {
            var c = s
            do { try c.add(prompt: prompt, terminals: t, at: at, now: n) } catch { return error as? ScheduledPrompts.Failure }
            return nil
        }
        check(fails("  ", [1], n.addingTimeInterval(60)) == .emptyPrompt, "empty prompt")
        check(fails("go", [], n.addingTimeInterval(60)) == .noTerminal, "no terminal")
        check(fails("go", [1], n) == .inThePast, "now is the past")
        check(fails("go", [1], n.addingTimeInterval(-5)) == .inThePast, "past")
        let a = try s.add(prompt: " run tests ", terminals: [1, 2], at: n.addingTimeInterval(60), now: n)
        let b = try s.add(prompt: "later", terminals: [1], at: n.addingTimeInterval(600), now: n)
        check(s.pending.map(\.id) == [a, b] && s.pending[0].prompt == "run tests", "pending sorted and trimmed")
        try s.add(prompt: "edited", terminals: [3], at: n.addingTimeInterval(30), now: n, replacing: b)
        check(s.pending.map(\.id) == [b, a] && s.items.count == 2 && s.pending[0].terminalIds == [3], "edit replaces in place")
        check(s.due(now: n.addingTimeInterval(10)).isEmpty, "not due")
        check(s.due(now: n.addingTimeInterval(45)).map(\.id) == [b], "b due")
        check(s.due(now: n.addingTimeInterval(45)).isEmpty, "fires once")
        check(s.pending.map(\.id) == [a] && s.recent.map(\.id) == [b], "pending / recent")
        s.remove(a)
        check(s.pending.isEmpty, "deleted")
        for i in 0 ..< 7 { try s.add(prompt: "p\(i)", terminals: [1], at: n.addingTimeInterval(Double(100 + i)), now: n) }
        _ = s.due(now: n.addingTimeInterval(1000))
        check(s.recent.count == 5 && s.recent.last?.prompt == "p6", "recent keeps five")
        check(ScheduledPrompts.message(for: .inThePast).contains("passed"), "message")
    }

    test("spotlight: scopes limited to chosen existing roots; query text is sanitised") {
        let exists: (String) -> Bool = { $0 == "/Users/x/work" || $0 == "/Users/x/docs" }
        check(SpotlightLogic.scopes(roots: ["/Users/x/work", "/Users/x/work/", "/Users/x/gone", "rel/path", "/", "/Users/x/docs"], exists: exists) == ["/Users/x/work", "/Users/x/docs"], "scopes")
        check(SpotlightLogic.scopes(roots: [], exists: exists).isEmpty, "no roots, no search")
        check(SpotlightLogic.parseRoots(" ~/work , /Volumes/D/docs,, ~ ", home: "/Users/x") == ["/Users/x/work", "/Volumes/D/docs", "/Users/x"], "setting text to folders")
        check(SpotlightLogic.parseRoots("", home: "/h").isEmpty, "empty setting")
        check(SpotlightLogic.sanitized("a") == nil && SpotlightLogic.sanitized("  ") == nil, "too short")
        check(SpotlightLogic.sanitized(" report* ") == "report", "wildcard removed")
        check(SpotlightLogic.sanitized("kMDItemFSName == \"*\"") == "kMDItemFSName", "no operators survive")
        check(SpotlightLogic.sanitized("**") == nil, "only wildcards")
        check(SpotlightLogic.sanitized(String(repeating: "a", count: 200))?.count == 80, "capped")
        check(SpotlightLogic.subtitle(path: "/Users/x/work/a/b.txt", home: "/Users/x") == "~/work/a", "subtitle")
        check(SpotlightLogic.subtitle(path: "/Users/x/b.txt", home: "/Users/x") == "~", "home itself")
    }

    test("migration call: an old daemon is not an error") {
        check(MigrationCall.interpret(ok: false, text: "unknown method `migrate.run`") == .unsupported, "unsupported")
        check(MigrationCall.interpret(ok: true, text: "\"Migrated\"") == .done("\"Migrated\""), "done")
        check(MigrationCall.interpret(ok: false, text: "sqlite3 failed") == .failed("sqlite3 failed"), "failed")
    }
}
