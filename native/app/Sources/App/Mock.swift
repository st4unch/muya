// Dev-only mock mode: MUYA_MOCK=1 (honoured only together with MUYA_DEBUG_SOCKET) seeds the store with the same data as the web
// UI's mock backend (src/mock/fixtures.ts: 7 agents — documents-44 waiting, muya-all and opencode-review working, four idle —
// the folder ~/Documents/claude-control-plane, the terminal of muya-all) and talks to no daemon. Screenshots of this mode
// compared with native/ui-reference/screens measure style, not content. Nothing here runs in a normal launch.

import AppKit

enum MockData {
    static func install(store: Store) {
        let home = store.home
        let ccp = home + "/Documents/claude-control-plane"
        for d in [ccp, home + "/Documents/iptv", home + "/Documents/numbat"] { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        // The web mock's Files tree: each workspace holds a folder of its own name with notes.ts in it.
        for root in [ccp, home + "/Documents/iptv", home + "/Documents/numbat"] {
            let inner = root + "/" + (root as NSString).lastPathComponent
            try? FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: inner + "/notes.ts", contents: Data("// mock\n".utf8))
        }
        for repo in [ccp, home + "/Documents/iptv", home + "/Documents/numbat", home + "/control-plane"] {
            try? FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
            try? "ref: refs/heads/main\n".write(toFile: repo + "/.git/HEAD", atomically: true, encoding: .utf8)
        }
        try? FileManager.default.createDirectory(atPath: ccp + "/.git", withIntermediateDirectories: true)   // so the branch shows "main" like the web mock
        try? "ref: refs/heads/main\n".write(toFile: ccp + "/.git/HEAD", atomically: true, encoding: .utf8)

        func make(_ id: UInt64, _ name: String, _ cwd: String, screen: String?, status: String?, elapsed: String?, kind: String?, text: String, progress: String? = nil) -> SessionModel {
            let r = Replica(cols: 105, rows: 38, theme: store.theme)!
            r.write(Data(text.utf8))
            let s = SessionModel(id: id, pid: Int32(51_000 + id), name: name, cwd: cwd, replica: r)
            s.screen = screen.flatMap { ScreenSummary(json: $0) }
            s.statusLine = status; s.elapsed = elapsed; s.kind = kind; s.progress = progress
            return s
        }
        let rule = "\u{1b}[2m" + String(repeating: "─", count: 62) + "\u{1b}[0m"
        let muyaText = "\u{1b}[2J\u{1b}[H❯ refactor the agent list\r\n● Reading src/App.tsx\r\n\r\n\u{1b}[38;5;216m✻\u{1b}[0m Unfurling… (4m 15s · ↓ 16.9k tokens · thought for 3s)\r\n\r\n\(rule)\r\n❯\r\n\(rule)\r\n  ▸▸ bypass permissions on (shift+tab to cycle) · ← for agents"
        let docsText = "\u{1b}[2J\u{1b}[H● Write(docs/[file path])\r\n\r\n  Do you want to write docs/[file path]?\r\n  ❯ 1. Yes\r\n    2. Yes, and don't ask again for this session\r\n    3. No\r\n\r\n  Esc to cancel · Tab to amend"
        let working = "{\"busy\":true,\"activity\":{\"verb\":\"Unfurling…\"},\"mode\":\"bypass permissions\",\"modeDetected\":true}"
        let waiting = "{\"modeDetected\":true,\"mode\":\"default\",\"permission\":{\"tool\":\"fs_write_file\",\"target\":\"docs/[file path]\",\"question\":\"write\",\"options\":[{\"kind\":\"approve\",\"key\":\"1\"},{\"kind\":\"approveAlways\",\"key\":\"2\",\"label\":\"Yes, and don't ask again for this session\"}]}}"
        let list = [
            make(1, "documents-44", ccp, screen: waiting, status: "Needs permission: fs_write_file", elapsed: "1m", kind: "claude", text: docsText),
            make(2, "muya-all", ccp, screen: working, status: "Unfurling… · 16.9k tokens", elapsed: "4m 15s", kind: "claude", text: muyaText, progress: "4m 15s · ↓ 16.9k tokens · thought for 3s"),
            make(3, "opencode-review", ccp, screen: "{\"busy\":true,\"mode\":\"default\"}", status: "Working…", elapsed: nil, kind: "opencode", text: "\u{1b}[2J\u{1b}[Hopencode\r\nreviewing the diff…"),
            // the web mock lists only these three agents in the sidebar (Agents 3); the other four exist for the Sessions page only
        ]
        GridState.picked = [1, 2, 3]   // the web mock's grid: documents-44, muya-all, opencode-review + one empty panel
        store.installMock(list, selected: 1)
    }

    // MARK: Sessions page data (same names as the web mock's agents + a few past transcripts)

    static func agents(home: String) -> [AgentRow] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func row(_ id: String, _ name: String, _ status: String, _ kind: String, _ ageMin: Int64, pid: Int, attachable: Bool = false, cwd: String? = nil) -> AgentRow {
            AgentRow(json: ["sessionId": id, "id": attachable ? id : "", "name": name, "cwd": cwd ?? home + "/Documents/claude-control-plane", "kind": kind, "status": status,
                            "startedAt": NSNumber(value: now - ageMin * 60_000), "pid": pid])!
        }
        return [row("muya-all", "muya-all", "working", "claude-sonnet-4.5", 4, pid: 51234, attachable: true), row("documents-44", "documents-44", "waiting", "claude-sonnet-4.5", 1, pid: 51235, attachable: true),
                row("opencode-review", "opencode-review", "working", "opencode", 5, pid: 51236), row("iptv-2a", "iptv-2a", "idle", "claude-sonnet-4.5", 90, pid: 0, cwd: home + "/Documents/iptv"),
                row("numbat-c3", "numbat-c3", "idle", "claude-sonnet-4.5", 120, pid: 0, cwd: home + "/Documents/numbat"), row("skills-envanter", "skills-envanter", "idle", "claude-sonnet-4.5", 300, pid: 0, cwd: home + "/control-plane"), row("serbest", "serbest", "idle", "claude-sonnet-4.5", 400, pid: 0, cwd: home)]
    }

    /// What the web mock's Sessions rows show next to the folder: duration text (some rows have none, one is the literal "[duration]") and whether the model is listed.
    static func sessionMeta(_ name: String) -> (duration: String, model: Bool)? {
        switch name {
        case "muya-all": return ("4m 15s", true)
        case "documents-44": return ("1m", true)
        case "opencode-review": return ("[duration]", false)
        case "iptv-2a", "numbat-c3", "skills-envanter", "serbest": return ("", false)
        default: return nil
        }
    }

    static func history(home: String) -> [HistoryEntry] {
        let now = Int64(Date().timeIntervalSince1970 * 1000), day: Int64 = 86_400_000, mb: Int64 = 1_048_576
        func e(_ id: String, _ name: String, _ ageMs: Int64, _ size: Int64, _ folder: String = "muya") -> HistoryEntry {
            HistoryEntry(json: ["sessionId": id, "name": name, "cwd": home + "/Documents/" + folder, "path": "/mock/\(id).jsonl",
                                "lastModified": NSNumber(value: now - ageMs), "sizeBytes": NSNumber(value: size)])!
        }
        return [e("9d1bed8-94ca-4e0b-9a5a-0a2fa1b4c1d1", "muya-all", 0, 239 * mb), e("c3d4e5f6-0001-4aaa-8bbb-000000000001", "lharries/whatsapp-mcp", 28 * day, 143 * mb, "whatsapp-mcp"), e("c3d4e5f6-0004-4aaa-8bbb-000000000004", "audit-m1-target3", 60 * day, 819 * 1024, "padas"), e("c3d4e5f6-0002-4aaa-8bbb-000000000002", "serbest", 3 * day, 29 * mb),
                e("c3d4e5f6-0003-4aaa-8bbb-000000000003", "iptv-f2", 5 * day, 3 * mb)]
    }

    // MARK: Schedules + Queue data (same rows as src/mock/schedulesMock.ts and fixtures.ts MOCK_PROJECT_STATUS)

    /// Answers `schedules.list` / `schedules.runs` in mock mode (there is no daemon): 3 jobs, 14 kept runs (12 + 2).
    /// The SSH page's data in mock mode: the same synthetic in-memory daemon the client tests use (documentation names, test values).
    nonisolated(unsafe) static var sshFake: FakeSSHRpc?

    static func call(_ method: String, _ params: [String: Any]) -> Any? {
        if ["vault.", "ssh.", "servers.", "psmp.", "cyberark."].contains(where: method.hasPrefix) {
            return MainActor.assumeIsolated { () -> Any? in
                let fake = sshFake ?? FakeSSHRpc(); sshFake = fake
                var out: Any?
                fake.call(method, params) { if case let .success(v) = $0 { out = v } }
                return out
            }
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000), h: Int64 = 3_600_000
        /// Local time tomorrow in ms (the web mock's clock shows "tomorrow 04:21" / "tomorrow 08:21").
        func tomorrow(_ hour: Int, _ minute: Int) -> Int64 {
            let cal = Calendar.current
            let d = cal.date(bySettingHour: hour, minute: minute, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date())!)!
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        func job(_ id: String, _ name: String, _ folder: String, _ sched: [String: Any], enabled: Bool, timeout: Int, bypass: Bool, chrome: Bool, model: String = "", effort: String = "", next: Int64?, runs: Int, ok: Int, last: [String: Any]?) -> [String: Any] {
            var d: [String: Any] = ["id": id, "name": name, "prompt": "Mock prompt.", "folder": folder, "schedule": sched, "enabled": enabled, "timeoutMin": timeout, "bypass": bypass, "chrome": chrome, "model": model, "effort": effort,
                                    "running": false, "queued": false, "runs": runs, "ok": ok, "failed": runs - ok]
            if let next { d["nextRun"] = NSNumber(value: next) }
            if let last { d["last"] = last }
            return d
        }
        switch method {
        case "bridge.list_peers":
            return [["spki_hash": "9062814d4252b0ce", "label": "Work MacBook", "last_addr": "10.0.0.2:9876", "paired_at": 1_700_000_000, "capability": "messaging", "paired_by": "agent"],
                    ["spki_hash": "c41e07aa93b15d20", "label": "Home Mac mini", "paired_at": 1_700_100_000, "capability": "research", "paired_by": "operator"]] as [[String: Any]]
        case "bridge.set_peer_capability", "bridge.revoke_peer": return NSNull()
        case "update_status", "beta_update_status": return ["installed": "5.0.0", "canSwitch": true, "kind": "release", "returnVersion": "4.1.22", "pending": ["version": "5.1.0"]] as [String: Any]
        case "return_classic_preflight": return ["live": 2, "agents": 1] as [String: Any]
        case "update_check": return ["installed": "5.0.0", "available": true, "version": "5.1.0"] as [String: Any]
        case "schedules.list":
            return ["runner": "here", "jobs": [
                job("s1", "Nightly dependency audit", "/home/someone/Projects/muya", ["kind": "daily", "time": "02:30"], enabled: true, timeout: 30, bypass: true, chrome: true, model: "opus", effort: "high", next: tomorrow(4, 21), runs: 12, ok: 11,
                    last: ["started": NSNumber(value: now - 86_040_000), "ended": NSNumber(value: now - 86_040_000 + 95_000), "status": "success"]),
                job("s2", "Standup summary", "/home/someone/Projects/api-gateway", ["kind": "weekly", "days": [0, 1, 2, 3, 4], "time": "09:00"], enabled: true, timeout: 15, bypass: false, chrome: false, next: tomorrow(8, 21), runs: 2, ok: 1,
                    last: ["started": NSNumber(value: now - 26 * h), "ended": NSNumber(value: now - 26 * h + 900_000), "status": "timeout"]),
                job("s3", "Inbox triage", "/home/someone/Projects/website", ["kind": "interval", "minutes": 120], enabled: false, timeout: 10, bypass: true, chrome: true, next: nil, runs: 0, ok: 0, last: nil),
            ] as [[String: Any]]] as [String: Any]
        case "schedules.runs":
            let id = params["id"] as? String ?? ""
            func run(_ i: Int64, _ status: String, _ out: String) -> [String: Any] {
                ["started": NSNumber(value: now - (i + 1) * 24 * h), "ended": NSNumber(value: now - (i + 1) * 24 * h + 95_000), "status": status, "trigger": i == 0 ? "manual" : "schedule", "costUsd": 0.08 + Double(i) * 0.01, "output": out]
            }
            if id == "s1" { return (0..<12).map { run(Int64($0), $0 == 3 ? "failed" : "success", $0 == 3 ? "Error: MCP server failed to start" : "No high or critical advisories.") } as [[String: Any]] }
            if id == "s2" { return [["started": NSNumber(value: now - 26 * h), "ended": NSNumber(value: now - 26 * h + 900_000), "status": "timeout", "trigger": "schedule", "output": "Stopped after 15 min."],
                                    ["started": NSNumber(value: now - 50 * h), "ended": NSNumber(value: now - 50 * h + 210_000), "status": "success", "trigger": "schedule", "output": "Wrote docs/standup.md."]] as [[String: Any]] }
            return [[String: Any]]()
        case "sessions.send_command":   // the Command dialog: one answer per terminal, every state once (no daemon in mock mode)
            let ids = (params["ids"] as? [NSNumber]) ?? []
            let table: [(String, String?)] = [("submitted", nil), ("queued", "the session is busy, it takes this after its current turn"), ("skipped", "waiting on a permission prompt: nothing was typed"), ("failed", "this terminal is gone")]
            return ["results": ids.enumerated().map { i, id in
                var r: [String: Any] = ["id": id, "name": "#\(id)", "state": table[i % 4].0]
                if let why = table[i % 4].1 { r["reason"] = why }
                return r
            }] as [String: Any]
        case "sessions.archived": return [Any]()   // nothing archived yet, like the web mock ("Archived (0)")
        case "sessions.archive", "sessions.restore": return ["done": (params["paths"] as? [Any])?.count ?? 0, "skipped": [Any]()] as [String: Any]
        default: return nil
        }
    }

    /// The Queue view's tracked projects in mock mode: the 3 workspaces of the web mock.
    static func tracked(home: String) -> [TrackedProject] {
        let t = Date().timeIntervalSince1970
        func p(_ name: String, dirty: Int) -> TrackedProject {
            TrackedProject(path: home + "/Documents/" + name, name: name, isGit: true, branch: "main", base: "main", ahead: 0, behind: 0, dirty: dirty, changed: 0, lastActivity: t - 20706 * 86400)   // the web mock shows "20706d ago"
        }
        return [p("claude-control-plane", dirty: 14), p("iptv", dirty: 0), p("numbat", dirty: 0)]
    }
}

/// Queue source for mock mode: the real (read-only) local source for everything, mock rows for the tracked projects.
struct MockQueueSource: QueueSource {
    let inner: QueueSource, home: String
    func tracked(paths: [String]) -> [TrackedProject] { MockData.tracked(home: home) }
    func mergeCheck(path: String, branch: String, base: String) -> Bool? { inner.mergeCheck(path: path, branch: branch, base: base) }
    func queue(cwd: String) -> QueueSnapshot { inner.queue(cwd: cwd) }
    func commits(cwd: String, limit: Int) -> [CommitNode] { inner.commits(cwd: cwd, limit: limit) }
    func cards(cwd: String) -> [KanbanCard] { inner.cards(cwd: cwd) }
    func setStatus(slug: String, column: KanbanColumn, cwd: String) -> Bool { inner.setStatus(slug: slug, column: column, cwd: cwd) }
}
