// Unit tests of the Sessions / Schedules / Settings view models and the command palette
// (Sources/Logic/PageLogic.swift) plus the rpc round trip against a live muyad (MUYA_TEST_SOCKET).

import Foundation

private func entry(_ id: String, cwd: String, name: String? = nil, at: Int64 = 0) -> HistoryEntry {
    var d: [String: Any] = ["sessionId": id, "cwd": cwd, "path": "/p/\(id).jsonl", "lastModified": NSNumber(value: at), "sizeBytes": 10]
    if let name { d["name"] = name }
    return HistoryEntry(json: d)!
}

func runPageTests() {
    test("session query parses filters and free text") {
        let q = SessionQuery.parse("deploy session=muya include=v4.1 path=work id=ab12 branch=main s2=x")
        check(q.text == "deploy s2=x", "free text \(q.text)")
        check(q.name == "muya" && q.include == "v4.1" && q.path == "work" && q.id == "ab12" && q.branch == "main", "filters")
        check(q.contentTerm == "v4.1", "include wins as the content term")
        check(SessionQuery.parse("a").contentTerm == nil, "one character is no search")
        check(SessionQuery.parse("zebra").contentTerm == "zebra", "free text is the term")
        check(SessionQuery.parse("name=").text == "" && SessionQuery.parse("name=").name == "", "a filter being typed filters nothing yet")
    }

    test("sessions filter by name, path, id prefix and content hits") {
        let es = [entry("aaa111", cwd: "/w/alpha", name: "Zebra work"), entry("bbb222", cwd: "/w/beta"), entry("ccc333", cwd: "/w/alpha", name: "other")]
        func ids(_ q: String, _ m: [String: ContentMatch]? = nil) -> [String] { SessionsLogic.filter(es, .parse(q), matches: m).map(\.sessionId) }
        check(ids("") == ["aaa111", "bbb222", "ccc333"], "no query keeps all")
        check(ids("session=zebra") == ["aaa111"], "name")
        check(ids("path=beta") == ["bbb222"], "path")
        check(ids("id=CCC") == ["ccc333"], "id prefix, case-insensitive")
        check(ids("alpha") == ["aaa111", "ccc333"], "free text hits the folder")
        let hit = ContentMatch(json: ["sessionId": "bbb222", "snippet": "..zebra..", "matchCount": 2])!
        check(ids("zebra", ["bbb222": hit]).sorted() == ["aaa111", "bbb222"], "free text: name hit or content hit")
        check(ids("include=zebra", ["bbb222": hit]) == ["bbb222"], "include requires the content hit")
        check(ids("include=zebra", nil).count == 3, "include does not hide anything while the search runs")
    }

    test("sessions group per project, newest first") {
        let es = [entry("a", cwd: "/w/old", at: 100), entry("b", cwd: "/w/new", at: 900), entry("c", cwd: "/w/old", at: 500), entry("d", cwd: "", at: 50)]
        let g = SessionsLogic.group(es)
        check(g.map(\.cwd) == ["/w/new", "/w/old", ""], "groups ordered by their newest session: \(g.map(\.cwd))")
        check(g[1].entries.map(\.sessionId) == ["c", "a"], "sessions newest first")
        check(g[0].title == "new" && g[2].title == "Unknown folder", "titles")
    }

    test("resume command only for safe ids; export file names") {
        check(SessionsLogic.resumeCommand("0a1b-2c_3") == "claude --resume '0a1b-2c_3' --permission-mode auto", "resume")
        check(SessionsLogic.resumeCommand("x'; touch /tmp/pwn; '") == nil, "quote injection refused")
        check(SessionsLogic.resumeCommand("") == nil, "empty id")
        check(SessionsLogic.exportFilename(label: "Zebra work / v2", id: "abcdef123456") == "Zebra-work-v2.md", SessionsLogic.exportFilename(label: "Zebra work / v2", id: "abcdef123456"))
        check(SessionsLogic.exportFilename(label: "", id: "abcdef123456") == "abcdef12.md", "falls back to the first 8 characters")
        let now = Date(timeIntervalSince1970: 10_000_000)
        check(SessionsLogic.relativeTime(ms: 9_999_990_000, now: now) == "just now", "now")
        check(SessionsLogic.relativeTime(ms: 9_996_400_000, now: now) == "1 h ago", "hour")
        check(SessionsLogic.byteSize(1536) == "2 KB" && SessionsLogic.byteSize(5 << 20) == "5.0 MB", "sizes")
    }

    func job(_ extra: [String: Any] = [:], schedule: [String: Any] = ["kind": "daily", "time": "09:30"]) -> ScheduleJob {
        var d: [String: Any] = ["id": "s1", "name": "Nightly", "prompt": "p", "folder": "/tmp", "schedule": schedule, "enabled": true,
                                "timeoutMin": 30, "bypass": true, "chrome": false, "runs": 0, "ok": 0, "failed": 0, "running": false, "queued": false]
        for (k, v) in extra { d[k] = v }
        return ScheduleJob(json: d)!
    }

    test("schedule descriptions match the Tauri page") {
        check(job(schedule: ["kind": "interval", "minutes": 60]).describe == "Every hour", "hour")
        check(job(schedule: ["kind": "interval", "minutes": 15]).describe == "Every 15 min", "15 min")
        check(job().describe == "Every day at 09:30", "daily")
        check(job(schedule: ["kind": "daily", "time": "09:00", "extraTimes": ["17:00"]]).describe == "Every day at 09:00, 17:00", "extra times")
        check(job(schedule: ["kind": "weekly", "days": [0, 1, 2, 3, 4], "time": "08:00"]).describe == "Weekdays at 08:00", "weekdays")
        check(job(schedule: ["kind": "weekly", "days": [5, 6], "time": "10:00"]).describe == "Weekends at 10:00", "weekends")
        check(job(schedule: ["kind": "weekly", "days": [2, 0], "time": "10:00"]).describe == "Mon, Wed at 10:00", "named days sorted")
        check(job(schedule: ["kind": "interval", "minutes": 120]).describe == "Every 2 hours" && job(schedule: ["kind": "interval", "minutes": 90]).describe == "Every 90 min" && job(schedule: ["kind": "interval", "minutes": 1440]).describe == "Every 24 hours", "interval hours like describeSchedule")
        check(job(schedule: ["kind": "daily", "time": "17:00", "extraTimes": ["09:00", "17:00"]]).describe == "Every day at 09:00, 17:00", "dayTimes sorted, no duplicates")
        let rn = Date(timeIntervalSince1970: 1_000_000_000)
        func rel(_ deltaMs: Int64) -> String { ScheduleFormat.relTime(ms: Int64(rn.timeIntervalSince1970 * 1000) + deltaMs, now: rn) }
        check(rel(-10_000) == "just now" && rel(10_000) == "in a moment" && rel(-300_000) == "5 min ago" && rel(-86_040_000) == "24 h ago" && rel(-93_600_000) == "1 d ago" && rel(7_200_000) == "in 2 h" && rel(3 * 86_400_000) == "in 3 d", "relTime like relTime() of schedules.ts")
    }

    test("schedule state labels, next run text and stats") {
        check(job().stateLabel == "Never run", "never")
        check(job(["runs": 2, "ok": 2, "last": ["status": "success", "started": 5]]).stateLabel == "Success", "success")
        check(job(["runs": 2, "last": ["status": "timeout", "started": 5]]).stateLabel == "Timed out", "timeout")
        check(job(["runs": 2, "last": ["status": "failed", "started": 5]]).stateLabel == "Failed", "failed")
        check(job(["running": true, "queued": true]).stateLabel == "Running" && job(["queued": true]).stateLabel == "Waiting", "running / waiting")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        func ms(_ plusHours: Double) -> NSNumber { NSNumber(value: Int64((now.timeIntervalSince1970 + plusHours * 3600) * 1000)) }
        check(job(["nextRun": ms(1)]).nextRunText(now: now, calendar: cal) == "today 23:13", job(["nextRun": ms(1)]).nextRunText(now: now, calendar: cal))
        check(job(["nextRun": ms(4)]).nextRunText(now: now, calendar: cal) == "tomorrow 02:13", "tomorrow")
        check(job(["nextRun": ms(72)]).nextRunText(now: now, calendar: cal) == "17 Nov 22:13", job(["nextRun": ms(72)]).nextRunText(now: now, calendar: cal))
        check(job(["enabled": false, "nextRun": ms(1)]).nextRunText(now: now, calendar: cal) == "off", "off")
        check(job().nextRunText(now: now, calendar: cal) == "—", "no next run")
        let st = ScheduleStats([job(["runs": 4, "ok": 3]), job(["id": "s2", "name": "Broken", "enabled": false, "runs": 1, "ok": 0, "last": ["status": "failed", "started": 9]])])
        check(st.schedules == "2 (1 on · 1 off)" && st.runs == "5" && st.successRate == "60%" && st.lastFailure == "Broken", "\(st)")
        let none = ScheduleStats([])
        check(none.successRate == "—" && none.lastFailure == "None", "empty stats")
    }

    test("schedule draft builds the save parameters and caps the times") {
        var d = ScheduleDraft()
        d.name = "N"; d.prompt = "p"; d.folder = "/tmp"
        var p = d.toParams()["job"] as! [String: Any]
        var sch = p["schedule"] as! [String: Any]
        check(sch["kind"] as? String == "daily" && sch["time"] as? String == "09:00" && (sch["extraTimes"] as? [String])?.isEmpty == true, "daily default 09:00")
        check(p["enabled"] as? Bool == true && p["bypass"] as? Bool == true && p["chrome"] as? Bool == true && p["timeoutMin"] as? Int == 30, "defaults on, 30 min")
        check(p["id"] == nil, "a new job has no id")
        d.kind = "weekly"; d.days = [4, 0]; d.times = ["08:00", "12:00"]
        sch = (d.toParams()["job"] as! [String: Any])["schedule"] as! [String: Any]
        check(sch["days"] as? [Int] == [0, 4] && sch["extraTimes"] as? [String] == ["12:00"], "weekly days sorted, extra times")
        d.kind = "interval"; d.minutes = 15
        sch = (d.toParams()["job"] as! [String: Any])["schedule"] as! [String: Any]
        check(sch["minutes"] as? Int == 15 && sch["time"] == nil, "interval")
        for _ in 0 ..< 10 { d.addTime() }
        check(d.times.count == ScheduleDraft.maxTimes, "at most 6 times")
        check(p["model"] as? String == "" && p["effort"] as? String == "", "model and effort default to Claude's own")
        let withME = ScheduleDraft(job(["model": "opus", "effort": "xhigh"]))
        let mp = (withME.toParams()["job"] as? [String: Any]) ?? [:]
        check(mp["model"] as? String == "opus" && mp["effort"] as? String == "xhigh", "model and effort round-trip through the draft")
        let edit = ScheduleDraft(job(["timeoutMin": 7]))
        p = edit.toParams()["job"] as! [String: Any]
        check(p["id"] as? String == "s1" && p["timeoutMin"] as? Int == 7 && edit.summary == "Runs: every day at 09:30", "edit keeps the id: \(edit.summary)")
        check(runnerBanner("other")?.hasPrefix("Another Muya window") == true && runnerBanner("service") == nil && runnerLabel("service") == "Run by the Muya service", "runner texts")
    }

    test("a session schedule carries its target through the draft and back") {
        var d = ScheduleDraft(target: ScheduleTarget(id: 7, name: "shell", cwd: "/work"))
        check(d.name == "shell" && d.folder == "/work" && d.target?.id == 7, "prefilled from the session")
        d.prompt = "echo SCHED"
        let p = d.toParams()["job"] as! [String: Any]
        let t = p["target"] as? [String: Any]
        check(t?["id"] as? UInt64 == 7 && t?["name"] as? String == "shell" && t?["cwd"] as? String == "/work", "target in the save params")
        check((ScheduleDraft().toParams()["job"] as! [String: Any])["target"] == nil, "a plain draft has no target")
        let back = ScheduleJob(json: ["id": "s9", "name": "shell", "schedule": ["kind": "daily", "time": "09:00"], "target": ["id": 7, "name": "shell", "cwd": "/work"]])!
        check(back.target == ScheduleTarget(id: 7, name: "shell", cwd: "/work") && ScheduleDraft(back).target == back.target, "listed job -> draft keeps it")
        check(ScheduleJob(json: ["id": "s9", "name": "n", "schedule": ["kind": "daily", "time": "09:00"]])!.target == nil, "old jobs have none")
    }

    test("schedule runs parse and label") {
        let r = ScheduleRun(json: ["started": 1000, "ended": 66000, "status": "success", "trigger": "manual", "costUsd": 0.5, "output": "hi"])!
        check(r.triggerLabel == "Run now" && r.statusLabel == "Success" && r.duration == "1 min 5 s" && r.costUsd == 0.5, "\(r.duration)")
        check(ScheduleRun(json: ["started": 1, "status": "failed", "trigger": "schedule"])!.triggerLabel == "Scheduled", "scheduled")
    }

    test("command palette ranks fuzzy matches") {
        let items = [PaletteItem(id: "v.sessions", group: "Views", title: "Sessions"), PaletteItem(id: "v.schedules", group: "Views", title: "Schedules"),
                     PaletteItem(id: "v.settings", group: "Views", title: "Settings"), PaletteItem(id: "s.1", group: "Sessions", title: "Zebra work", subtitle: "~/work/alpha"),
                     PaletteItem(id: "c.new", group: "Commands", title: "New terminal")]
        func ids(_ q: String) -> [String] { Fuzzy.rank(items, q).map(\.id) }
        check(ids("").count == 5, "empty query keeps everything")
        check(ids("sch") == ["v.schedules"], "prefix: \(ids("sch"))")
        check(ids("se").first == "v.sessions" || ids("se").first == "v.settings", "prefix beats the rest: \(ids("se"))")
        check(ids("nt") == ["c.new"], "subsequence across words: \(ids("nt"))")
        check(ids("alpha") == ["s.1"], "subtitle matches: \(ids("alpha"))")
        check(ids("xyz").isEmpty, "no match")
        check(Fuzzy.score("sx", "Sessions") == nil, "not a subsequence")
        check((Fuzzy.score("ses", "Sessions") ?? 0) > (Fuzzy.score("ses", "Close all sessions") ?? 0), "word start / prefix wins")
    }

    test("settings rows cover the Tauri Settings and persist") {
        let titles = SettingsSchema.rows.map(\.title)
        for t in ["Keep running when the window is closed", "Resume Claude sessions on launch", "Auto-allow permission prompts", "Claude status in Muya's footer",
                  "Delete old Claude sessions after", "Auto-save files", "Log CyberArk + SSH connection steps", "Log file"] { check(titles.contains(t), "row '\(t)'") }
        check(Set(SettingsSchema.rows.map(\.id)).count == SettingsSchema.rows.count, "unique ids")
        check(SettingsSchema.cleanupLabel(days: 60) == "60 days" && SettingsSchema.cleanupLabel(days: 365) == "1 year" && SettingsSchema.cleanupLabel(days: nil) == "30 days" && SettingsSchema.cleanupLabel(days: 45) == "45 days", "cleanup labels")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uiprefs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prefs.json")
        let a = UIPrefs(url: url)
        check(a.string("appearance") == "System" && a.int("terminalFontSize") == 13 && !a.bool("autoSave"), "defaults")
        a.set("appearance", "Dark"); a.set("autoSave", true); a.set("terminalFontSize", 16)
        check(a.string("appearance") == "Dark", "a change is visible before it is on disk")
        a.flush()
        check(a.writeCount == 1, "a burst of three changes is one write (\(a.writeCount))")
        let mode = { (path: String) in ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        check(mode(url.path) == 0o600 && mode(dir.path) == 0o700, "prefs file 0600 in a 0700 folder (\(String(mode(url.path), radix: 8)) / \(String(mode(dir.path), radix: 8)))")
        let b = UIPrefs(url: url)
        check(b.string("appearance") == "Dark" && b.bool("autoSave") && b.int("terminalFontSize") == 16, "read back after a relaunch")
        check((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() == ["prefs.json"], "no temp file left behind")
    }

    if let socket = ProcessInfo.processInfo.environment["MUYA_TEST_SOCKET"] {
        test("live: rpc round trip, errors and cancel against the real daemon") {
            let conn = try MuyadConnection(path: socket, build: "client-test")
            check(conn.serverMinor >= minorRpc, "server speaks minor \(conn.serverMinor)")
            conn.start()
            func call(_ m: String, _ p: [String: Any] = [:]) -> Result<Any, ClientError> {
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var out: Result<Any, ClientError> = .failure(.timeout)
                conn.call(m, p) { out = $0; sem.signal() }
                _ = sem.wait(timeout: .now() + 10)
                return out
            }
            if case let .success(v) = call("prefs.get") { check((v as? [String: Any])?["keepRunningInBackground"] != nil, "prefs.get shape") } else { check(false, "prefs.get") }
            if case let .failure(.server(_, m)) = call("nope") { check(m.contains("unknown method"), m) } else { check(false, "unknown method must fail") }
            if case let .success(v) = call("sessions.history") { check(v is [Any], "history is a list") } else { check(false, "history") }
            let req = conn.call("sessions.search", ["query": "zz", "sessions": []]) { _ in }
            conn.cancelCall(req)
            conn.close()
        }
    }
}
