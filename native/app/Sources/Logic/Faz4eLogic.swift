// Faz 4e view models and decisions, pure Foundation (unit-tested in Tests/Faz4eTests.swift):
// the live agent-session list (`claude agents --json`), resolving the `claude` binary by capability,
// the Sessions clean-up (Trash only), the transcript drawer, auto-allow, resume-on-launch, one-shot
// scheduled prompts and the Spotlight roots.

import Foundation

// MARK: - Live agent sessions

public struct AgentRow: Equatable, Sendable {
    public var sessionId: String
    public var shortId: String
    public var name: String
    public var cwd: String
    public var kind: String
    public var pid: Int32?
    public var startedAt: Int64?
    public var status: String       // working | waiting-for-input | idle | stopped
    public var waitingFor: String?
    public var parentId: String?
    /// `claude agents` id of a background session (what `claude attach` / `claude stop` take); nil for an interactive one.
    public var attachId: String?

    /// Today's rule (muya-core agents::map_agent): a session is attachable when it is a background one or has an id.
    public var attachable: Bool { kind == "background" || attachId != nil }
    public var isOpencode: Bool { kind.lowercased().contains("opencode") }

    public init?(json d: [String: Any]) {
        guard let sid = d["sessionId"] as? String, !sid.isEmpty else { return nil }
        sessionId = sid
        shortId = (d["id"] as? String) ?? String(sid.split(separator: "-").first ?? Substring(sid))
        cwd = (d["cwd"] as? String) ?? ""
        let given = (d["name"] as? String) ?? ""
        name = given.isEmpty ? ((cwd as NSString).lastPathComponent.isEmpty ? String(shortId.prefix(8)) : (cwd as NSString).lastPathComponent) : given
        kind = (d["kind"] as? String) ?? ""
        pid = (d["pid"] as? NSNumber).map { Int32(truncating: $0) }
        startedAt = (d["startedAt"] as? NSNumber)?.int64Value
        // Same mapping as muya-core agents::map_status: `state` wins over `status`.
        let raw = ((d["state"] as? String) ?? (d["status"] as? String) ?? "").lowercased()
        switch raw {
        case "busy", "working": status = "working"
        case "blocked", "waiting": status = "waiting-for-input"
        case "stopped", "failed": status = "stopped"
        default: status = "idle"
        }
        waitingFor = (d["waitingFor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        parentId = (d["parentSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        attachId = (d["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    public var statusLabel: String {
        switch status {
        case "working": return "Working"
        case "waiting-for-input": return "Waiting" + (waitingFor.map { " · \($0)" } ?? "")
        case "stopped": return "Stopped"
        default: return "Idle"
        }
    }
}

public enum AgentsLogic {
    /// Session ids land in a shell command: only plain id characters (src/lib/agent.ts isSafeSessionId).
    public static func isSafeId(_ id: String) -> Bool { !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") } }
    /// `claude attach '<id>' --dangerously-skip-permissions` (src/components/SessionsPage.tsx openCommandFor); nil for an unsafe id.
    public static func attachCommand(_ id: String) -> String? { isSafeId(id) ? "claude attach '\(id)' --dangerously-skip-permissions" : nil }
    /// `opencode --session '<id>' --auto` (src/lib/agent.ts buildResumeCommand).
    public static func opencodeResumeCommand(_ id: String) -> String? { isSafeId(id) ? "opencode --session '\(id)' --auto" : nil }

    /// "12m" / "1h 4m" / "30s" since `startedAt` (ms); "—" without a start (muya-core agents::duration_since).
    public static func duration(startedAt: Int64?, now: Date) -> String {
        guard let s = startedAt else { return "—" }
        let secs = max(0, Int64(now.timeIntervalSince1970 * 1000) - s) / 1000
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : m > 0 ? "\(m)m" : "\(secs)s"
    }

    /// Current branch of a folder by reading `.git/HEAD` (walks up; follows a worktree's `.git` file); "—" if not a repository.
    public static func branch(of cwd: String) -> String {
        var dir = cwd
        for _ in 0 ..< 12 {
            let dotGit = dir + "/.git"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue, let t = try? String(contentsOfFile: dotGit, encoding: .utf8), t.hasPrefix("gitdir:") {
                    let g = t.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDir = g.hasPrefix("/") ? g : dir + "/" + g
                }
                guard let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return "—" }
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if h.hasPrefix("ref: refs/heads/") { return String(h.dropFirst(16)) }
                return h.count >= 7 ? String(h.prefix(7)) : "—"
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        return "—"
    }

    /// The rows of a `claude agents --json` answer, newest first; nil when the output is not a JSON array
    /// (an old CLI printing a usage error, for instance).
    public static func parse(_ data: Data) -> [AgentRow]? {
        guard let v = try? JSONSerialization.jsonObject(with: data), let list = v as? [Any] else { return nil }
        let rows = list.compactMap { ($0 as? [String: Any]).flatMap(AgentRow.init(json:)) }
        return rows.sorted { ($0.startedAt ?? 0, $1.sessionId) > ($1.startedAt ?? 0, $0.sessionId) }
    }

    /// Candidate paths for `claude`, most specific first. The environment (login shell, PATH) comes first,
    /// the well-known install folders are only a fallback.
    public static func candidates(home: String, loginShellAnswer: String?, path: String?) -> [String] {
        var out: [String] = []
        func add(_ p: String) { if !p.isEmpty, !out.contains(p) { out.append(p) } }
        if let loginShellAnswer, loginShellAnswer.hasPrefix("/") { add(loginShellAnswer) }
        for dir in (path ?? "").split(separator: ":") where dir.hasPrefix("/") { add(dir + "/claude") }
        for rel in [".local/bin/claude", ".local/share/claude/bin/claude", ".claude/local/claude"] { add(home + "/" + rel) }
        add("/opt/homebrew/bin/claude"); add("/usr/local/bin/claude")
        return out
    }

    /// Runs `<bin> agents --json` with a time limit; stdout when it exits 0, else nil. Never blocks the caller
    /// longer than `timeout` seconds (the child is killed).
    public static func runAgents(_ bin: String, extraArgs: [String] = [], timeout: TimeInterval = 15, environment: [String: String]? = nil) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["agents", "--json"] + extraArgs
        if let environment { p.environment = environment }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        nonisolated(unsafe) var data = Data()
        let reader = DispatchQueue(label: "agents.read")
        let readDone = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); _ = done.wait(timeout: .now() + 2); return nil }
        _ = readDone.wait(timeout: .now() + 2)
        return p.terminationStatus == 0 ? data : nil
    }

    /// The capability test used to pick a binary: it answers `agents --json` with a JSON array.
    public static func supportsAgentsJSON(_ bin: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: bin), let d = runAgents(bin, timeout: 20) else { return false }
        return parse(d) != nil
    }

    /// Asks the user's own login shell where `claude` is (the app inherits only a minimal PATH from Finder).
    public static func loginShellAnswer(shell: String?) -> String? {
        guard let shell, shell.hasPrefix("/") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        nonisolated(unsafe) var data = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "claude.which").async { data = out.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + 8) == .timedOut { p.terminate(); return nil }
        _ = readDone.wait(timeout: .now() + 2)
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        guard let line, line.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: line) else { return nil }
        return line
    }

    /// First candidate that passes `probe` (the capability test: `agents --json` answers with JSON), else nil.
    /// Existence and `--version` prove nothing: a stale `claude` earlier on PATH answers both and still
    /// rejects `--json`.
    public static func resolve(_ candidates: [String], probe: (String) -> Bool) -> String? {
        candidates.first(where: probe)
    }
}

// MARK: - Clean-up (Trash only)

public enum CleanupLogic {
    public static let inUseMs: Int64 = 10 * 60 * 1000
    public static let olderChoices = [7, 14, 30, 60, 90]
    public static let largerChoices = [50, 100, 250, 500]

    public struct Rules: Equatable, Sendable {
        public var olderDays: Int?
        public var largerMB: Int?
        public init(olderDays: Int? = 30, largerMB: Int? = 100) { self.olderDays = olderDays; self.largerMB = largerMB }
    }

    static func matches(_ e: HistoryEntry, _ r: Rules, now: Date) -> Bool {
        let ageDays = Int((now.timeIntervalSince1970 * 1000 - Double(e.lastModified)) / 86_400_000)
        if let d = r.olderDays, ageDays >= d { return true }
        if let m = r.largerMB, e.sizeBytes > Int64(m) * 1_048_576 { return true }
        return false
    }

    static func inUse(_ e: HistoryEntry, live: Set<String>, now: Date) -> Bool {
        live.contains(e.sessionId) || Int64(now.timeIntervalSince1970 * 1000) - e.lastModified < inUseMs
    }

    /// Sessions matching ANY enabled rule, never a live or just-used one, biggest first.
    public static func candidates(_ all: [HistoryEntry], _ r: Rules, live: Set<String>, now: Date) -> [HistoryEntry] {
        guard r.olderDays != nil || r.largerMB != nil else { return [] }
        return all.filter { !inUse($0, live: live, now: now) && matches($0, r, now: now) }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Matching sessions left alone because they are open or were just used.
    public static func heldBack(_ all: [HistoryEntry], _ r: Rules, live: Set<String>, now: Date) -> [HistoryEntry] {
        guard r.olderDays != nil || r.largerMB != nil else { return [] }
        return all.filter { inUse($0, live: live, now: now) && matches($0, r, now: now) }
    }

    /// The canonical path of a transcript that may be moved to the Trash: `<root>/<project>/<id>.jsonl`, a real
    /// file (no symlink), inside `root` (= ~/.claude/projects). Anything else is refused.
    public static func checkedTranscript(_ path: String, root: String) -> String? {
        let fm = FileManager.default
        guard path.hasSuffix(".jsonl"), let canonRoot = realpathString(root), let canon = realpathString(path) else { return nil }
        guard canon.hasPrefix(canonRoot + "/") else { return nil }
        let rel = canon.dropFirst(canonRoot.count + 1).split(separator: "/")
        guard rel.count == 2 else { return nil }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: canon, isDirectory: &isDir), !isDir.boolValue else { return nil }
        guard (try? fm.destinationOfSymbolicLink(atPath: path)) == nil else { return nil }
        return canon
    }

    /// What an Archive / Restore run did, in one line (resultLine of SessionCleanupDialog.tsx).
    public static func resultLine(verb: String, done: Int, skipped: [(String, String)]) -> String {
        func n(_ k: Int) -> String { "\(k) session\(k == 1 ? "" : "s")" }
        let head = done > 0 ? "\(verb) \(n(done))." : "Nothing \(verb.lowercased())."
        guard !skipped.isEmpty else { return head }
        var seen: [String] = []
        for (_, why) in skipped where !seen.contains(why) { seen.append(why) }
        return "\(head) \(n(skipped.count)) left as they were (\(seen.joined(separator: ", ")))."
    }

    /// Reads the `{done, skipped: [[path, why]]}` answer of sessions.archive / sessions.restore.
    public static func parseOutcome(_ v: Any) -> (done: Int, skipped: [(String, String)])? {
        guard let d = v as? [String: Any], let done = (d["done"] as? NSNumber)?.intValue else { return nil }
        let skipped = ((d["skipped"] as? [Any]) ?? []).compactMap { row -> (String, String)? in
            guard let a = row as? [Any], a.count == 2, let p = a[0] as? String, let w = a[1] as? String else { return nil }
            return (p, w)
        }
        return (done, skipped)
    }

    public static func resultLine(done: Int, skipped: [(String, String)]) -> String {
        func n(_ k: Int) -> String { "\(k) session\(k == 1 ? "" : "s")" }
        let head = done > 0 ? "Moved to the Trash: \(n(done))." : "Nothing moved to the Trash."
        guard !skipped.isEmpty else { return head }
        var seen: [String] = []
        for (_, why) in skipped where !seen.contains(why) { seen.append(why) }
        return "\(head) \(n(skipped.count)) left as they were (\(seen.joined(separator: ", ")))."
    }

    public static func realpathString(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}

// MARK: - Transcript drawer

public struct TranscriptTurn: Equatable, Sendable {
    public var role: String
    public var text: String
    public var timestamp: String?
}

public enum TranscriptLogic {
    static let maxTextChars = 4000

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for b in blocks {
            switch b["type"] as? String {
            case "text": if let t = b["text"] as? String { parts.append(t) }
            case "tool_use": parts.append("🔧 [\((b["name"] as? String) ?? "tool")]")
            default: break // tool_result payloads are huge command output
            }
        }
        return parts.joined(separator: "\n")
    }

    /// One transcript line as a displayable turn, or nil (meta lines, tool dumps, other record types).
    public static func parse(line: Substring) -> TranscriptTurn? {
        guard let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        let kind = (d["type"] as? String) ?? ""
        guard kind == "user" || kind == "assistant", (d["isMeta"] as? Bool) != true, let msg = d["message"] as? [String: Any] else { return nil }
        var text = text(of: msg["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.count > maxTextChars { text = String(text.prefix(maxTextChars)) + "\n… [truncated]" }
        return TranscriptTurn(role: (msg["role"] as? String) ?? kind, text: text, timestamp: d["timestamp"] as? String)
    }

    /// The newest `cap` turns of a transcript, read from the END of the file: a window of the last
    /// `firstWindow` bytes, growing x4 until it holds `cap` turns or the whole file.
    public static func tail(path: String, cap: Int = 500, firstWindow: Int = 4 << 20) throws -> [TranscriptTurn] {
        let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? h.close() }
        let len = Int(try h.seekToEnd())
        var window = max(firstWindow, 1)
        while true {
            let start = max(0, len - window)
            try h.seek(toOffset: UInt64(start))
            let data = try h.read(upToCount: len - start) ?? Data()
            var body = data
            if start > 0 { // mid-file the first line is cut: start after its newline
                if let nl = data.firstIndex(of: 0x0A) { body = data.suffix(from: data.index(after: nl)) } else { body = Data() }
            }
            let text = String(decoding: body, as: UTF8.self)
            var turns = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap(parse(line:))
            if turns.count >= cap || start == 0 {
                if turns.count > cap { turns.removeFirst(turns.count - cap) }
                return turns
            }
            window = window.multipliedReportingOverflow(by: 4).overflow ? len : window * 4
        }
    }

    public static func render(_ turns: [TranscriptTurn]) -> String {
        turns.map { t in
            let who = t.role == "user" ? "You" : "Claude"
            let when = t.timestamp.map { " · \($0.prefix(19).replacingOccurrences(of: "T", with: " "))" } ?? ""
            return "\(who)\(when)\n\(t.text)"
        }.joined(separator: "\n\n")
    }
}

// MARK: - Auto-allow and resume on launch

/// "Auto-allow permission prompts": a prompt nobody answers within `delay` seconds is approved. A prompt is
/// identified by a string key (session + what it asks for); a key that goes away and comes back counts as new.
public struct AutoAllowTracker: Sendable {
    public static let delay: TimeInterval = 2
    private var since: [String: Date] = [:]
    private var answered: Set<String> = []
    public init() {}

    /// Feed the prompts on screen right now. Returns the keys to approve at `now` (each exactly once).
    public mutating func tick(prompting: Set<String>, enabled: Bool, now: Date) -> [String] {
        for id in since.keys where !prompting.contains(id) { since[id] = nil; answered.remove(id) }
        guard enabled else { since = [:]; answered = []; return [] }
        var fire: [String] = []
        for id in prompting.sorted() {
            if since[id] == nil { since[id] = now }
            if !answered.contains(id), now.timeIntervalSince(since[id]!) >= Self.delay { answered.insert(id); fire.append(id) }
        }
        return fire
    }

    /// The prompt behind `id` was redrawn (the screen changed while the same prompt id stayed up, e.g. a second
    /// prompt for the same tool + target right after an answered one). It counts as a new prompt: fresh 2 s wait.
    public mutating func renew(_ id: String, now: Date) {
        if answered.remove(id) != nil { since[id] = now }
    }

    /// Seconds until the next prompt is due (nil when nothing waits), so the caller can sleep instead of poll.
    public func nextDue(now: Date) -> TimeInterval? {
        since.filter { !answered.contains($0.key) }.map { max(0, Self.delay - now.timeIntervalSince($0.value)) }.min()
    }
}

public struct ResumeEntry: Equatable, Sendable {
    public var sessionId: String
    public var cwd: String
    public var name: String
    public init(sessionId: String, cwd: String, name: String) { self.sessionId = sessionId; self.cwd = cwd; self.name = name }
    public init?(json d: [String: Any]) {
        guard let s = d["sessionId"] as? String, let c = d["cwd"] as? String else { return nil }
        self.init(sessionId: s, cwd: c, name: (d["name"] as? String) ?? "")
    }
    public var json: [String: Any] { ["sessionId": sessionId, "cwd": cwd, "name": name] }
}

public enum ResumeLogic {
    public static let maxResumed = 8

    /// What to reopen at launch: the Claude sessions that were open when the app last ran, when the setting is on
    /// and the daemon came back with no terminals (a daemon that kept its terminals needs no resuming).
    public static func plan(saved: [ResumeEntry], enabled: Bool, liveTerminals: Int, existingFolders: (String) -> Bool) -> [ResumeEntry] {
        guard enabled, liveTerminals == 0 else { return [] }
        var seen = Set<String>()
        return saved.filter { SessionsLogic.resumeCommand($0.sessionId) != nil && existingFolders($0.cwd) && seen.insert($0.sessionId).inserted }.prefix(maxResumed).map { $0 }
    }

    /// The interactive sessions of an agents answer worth remembering for the next launch.
    public static func snapshot(from rows: [AgentRow]) -> [ResumeEntry] {
        rows.filter { $0.kind != "background" && $0.status != "stopped" && !$0.cwd.isEmpty }
            .map { ResumeEntry(sessionId: $0.sessionId, cwd: $0.cwd, name: $0.name) }
    }
}

// MARK: - Scheduled Prompt (one-shot, in memory like today's app)

public struct ScheduledPrompt: Equatable, Sendable {
    public var id: Int
    public var prompt: String
    public var terminalIds: [UInt64]
    public var at: Date
    public var fired = false
}

public struct ScheduledPrompts: Sendable {
    public private(set) var items: [ScheduledPrompt] = []
    private var next = 1
    public init() {}

    public enum Failure: Error, Equatable { case emptyPrompt, noTerminal, inThePast }

    /// Validates like the Tauri modal (prompt and terminal needed, time must still be ahead).
    @discardableResult
    public mutating func add(prompt: String, terminals: [UInt64], at: Date, now: Date, replacing id: Int? = nil) throws -> Int {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { throw Failure.emptyPrompt }
        if terminals.isEmpty { throw Failure.noTerminal }
        if at <= now { throw Failure.inThePast }
        if let id, let i = items.firstIndex(where: { $0.id == id }) {
            items[i] = ScheduledPrompt(id: id, prompt: p, terminalIds: terminals, at: at)
            return id
        }
        let item = ScheduledPrompt(id: next, prompt: p, terminalIds: terminals, at: at)
        next += 1
        items.append(item)
        return item.id
    }

    public mutating func remove(_ id: Int) { items.removeAll { $0.id == id } }

    /// Marks the due prompts fired and returns them.
    public mutating func due(now: Date) -> [ScheduledPrompt] {
        var out: [ScheduledPrompt] = []
        for i in items.indices where !items[i].fired && items[i].at <= now { items[i].fired = true; out.append(items[i]) }
        return out
    }

    public var pending: [ScheduledPrompt] { items.filter { !$0.fired }.sorted { $0.at < $1.at } }
    public var recent: [ScheduledPrompt] { Array(items.filter(\.fired).suffix(5)) }

    public static func message(for f: Failure) -> String {
        switch f {
        case .emptyPrompt: return "Write the prompt to send first."
        case .noTerminal: return "Pick at least one terminal."
        case .inThePast: return "The chosen time has already passed. Pick a later time."
        }
    }
}

// MARK: - Spotlight ("files on this Mac")

public enum SpotlightLogic {
    /// Search scopes: the user's chosen roots that exist as folders, deduplicated, nothing outside them.
    public static func scopes(roots: [String], exists: (String) -> Bool) -> [String] {
        var out: [String] = []
        for r in roots {
            let p = (r as NSString).standardizingPath
            if p.hasPrefix("/"), p != "/", exists(p), !out.contains(p) { out.append(p) }
        }
        return out
    }

    /// The setting's text ("~/work, /Volumes/Data/docs") as absolute folder paths.
    public static func parseRoots(_ setting: String, home: String) -> [String] {
        setting.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { r in
            r == "~" ? home : r.hasPrefix("~/") ? home + "/" + r.dropFirst(2) : r
        }
    }

    /// Only text the user typed becomes part of the query, and only as a plain "name contains" match:
    /// no wildcard or operator characters get through.
    public static func sanitized(_ query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return nil }
        let cleaned = q.filter { !"*?\\\"'()[]{}<>=&|!".contains($0) }.trimmingCharacters(in: .whitespaces)
        return cleaned.count >= 2 ? String(cleaned.prefix(80)) : nil
    }

    public static func subtitle(path: String, home: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir == home ? "~" : dir.hasPrefix(home + "/") ? "~" + dir.dropFirst(home.count) : dir
    }
}

// MARK: - First-launch migration (daemon call, behind a feature check)

public enum MigrationCall: Equatable, Sendable {
    /// The daemon does not know `migrate.run` yet: nothing happens, nothing is remembered.
    case unsupported
    case done(String)
    case failed(String)

    public static func interpret(ok: Bool, text: String) -> MigrationCall {
        if ok { return .done(text) }
        return text.contains("unknown method") ? .unsupported : .failed(text)
    }
}
