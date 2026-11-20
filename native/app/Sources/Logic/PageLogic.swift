// View models of the Sessions, Schedules and Settings views and the command palette: pure Foundation, no
// AppKit, so they are unit-tested (Tests/PageTests.swift). Labels and messages follow today's UI
// (src/components/SessionsPage.tsx, SchedulesPage.tsx, SettingsModal.tsx).

import Foundation

// MARK: - Sessions

public struct HistoryEntry: Equatable, Sendable {
    public var sessionId: String
    public var cwd: String
    public var name: String?
    public var path: String
    public var lastModified: Int64
    public var lastMessageAt: Int64?
    public var sizeBytes: Int64

    public init?(json d: [String: Any]) {
        guard let id = d["sessionId"] as? String, let path = d["path"] as? String else { return nil }
        sessionId = id; self.path = path
        cwd = (d["cwd"] as? String) ?? ""
        name = (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        lastModified = (d["lastModified"] as? NSNumber)?.int64Value ?? 0
        lastMessageAt = (d["lastMessageAt"] as? NSNumber)?.int64Value
        sizeBytes = (d["sizeBytes"] as? NSNumber)?.int64Value ?? 0
    }

    public var displayName: String { name ?? String(sessionId.prefix(8)) }
    public var lastActivity: Int64 { lastMessageAt ?? lastModified }
}

public struct ContentMatch: Equatable, Sendable {
    public var sessionId: String
    public var snippet: String
    public var matchCount: Int
    public init?(json d: [String: Any]) {
        guard let id = d["sessionId"] as? String else { return nil }
        sessionId = id
        snippet = (d["snippet"] as? String) ?? ""
        matchCount = (d["matchCount"] as? NSNumber)?.intValue ?? 0
    }
}

/// The search box: free text plus `session=` `include=` `path=` `id=` `branch=` filters (same keys as the Tauri page).
public struct SessionQuery: Equatable, Sendable {
    public var text = ""
    public var name = ""
    public var include = ""
    public var path = ""
    public var id = ""
    public var branch = ""

    public init() {}

    public static func parse(_ raw: String) -> SessionQuery {
        var q = SessionQuery()
        var free: [String] = []
        for token in raw.split(whereSeparator: \.isWhitespace) {
            let t = String(token)
            guard let eq = t.firstIndex(of: "="), eq != t.startIndex else { free.append(t); continue }
            let key = t[..<eq].lowercased()
            let value = String(t[t.index(after: eq)...])
            switch key {
            case "session", "name", "s": q.name = value
            case "include", "text", "in", "has": q.include = value
            case "path", "cwd", "dir", "folder": q.path = value
            case "branch": q.branch = value
            case "id": q.id = value
            default: free.append(t)
            }
        }
        q.text = free.joined(separator: " ")
        return q
    }

    /// What the daemon should grep the transcripts for (>= 2 characters), or nil.
    public var contentTerm: String? {
        let t = include.isEmpty ? text : include
        return t.count >= 2 ? t : nil
    }
}

public enum SessionsLogic {
    /// Entries passing the query. `matches` are the content hits for `query.contentTerm` (nil while the search runs).
    public static func filter(_ entries: [HistoryEntry], _ q: SessionQuery, matches: [String: ContentMatch]?) -> [HistoryEntry] {
        entries.filter { e in
            if !q.name.isEmpty, !e.displayName.localizedCaseInsensitiveContains(q.name) { return false }
            if !q.path.isEmpty, !e.cwd.localizedCaseInsensitiveContains(q.path) { return false }
            if !q.id.isEmpty, !e.sessionId.lowercased().hasPrefix(q.id.lowercased()) { return false }
            if !q.include.isEmpty, let matches, matches[e.sessionId] == nil { return false }
            if q.include.isEmpty, !q.text.isEmpty {
                let meta = e.displayName.localizedCaseInsensitiveContains(q.text) || e.cwd.localizedCaseInsensitiveContains(q.text) || e.sessionId.lowercased().hasPrefix(q.text.lowercased())
                if !meta, matches?[e.sessionId] == nil { return false }
            }
            return true
        }
    }

    public struct Group: Equatable, Sendable {
        public var cwd: String
        public var entries: [HistoryEntry]
        public var title: String { cwd.isEmpty ? "Unknown folder" : (cwd as NSString).lastPathComponent }
    }

    /// Sessions per project folder: groups and the sessions inside both newest first.
    public static func group(_ entries: [HistoryEntry]) -> [Group] {
        var byCwd: [String: [HistoryEntry]] = [:]
        for e in entries { byCwd[e.cwd, default: []].append(e) }
        return byCwd.map { Group(cwd: $0.key, entries: $0.value.sorted { $0.lastActivity > $1.lastActivity }) }
            .sorted { ($0.entries.first?.lastActivity ?? 0, $1.cwd) > ($1.entries.first?.lastActivity ?? 0, $0.cwd) }
    }

    /// `claude --resume '<id>' --permission-mode auto`; nil when the id could break out of the quotes.
    public static func resumeCommand(_ id: String) -> String? {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return "claude --resume '\(id)' --permission-mode auto"
    }

    /// Default file name of an export: the session label with runs of odd characters turned into `-`.
    public static func exportFilename(label: String, id: String) -> String {
        let base = label.isEmpty ? String(id.prefix(8)) : label
        var out = ""
        var lastDash = false
        for ch in base.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) && ch.isASCII || ch == "_" || ch == "." || ch == "-" {
                out.unicodeScalars.append(ch); lastDash = false
            } else if !lastDash { out += "-"; lastDash = true }
        }
        return out + ".md"
    }

    public static func relativeTime(ms: Int64, now: Date) -> String {
        let secs = Int(now.timeIntervalSince1970 - Double(ms) / 1000)
        if secs < 45 { return "just now" }
        if secs < 3600 { return "\(max(1, secs / 60)) min ago" }
        if secs < 86400 { return "\(secs / 3600) h ago" }
        if secs < 86400 * 30 { return "\(secs / 86400) d ago" }
        return "\(secs / (86400 * 30)) mo ago"
    }

    public static func byteSize(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1 << 20 { return String(format: "%.0f KB", Double(n) / 1024) }
        if n < 1 << 30 { return String(format: n < 10 << 20 ? "%.1f MB" : "%.0f MB", Double(n) / Double(1 << 20)) }   // formatBytes of src/lib/sessionStorage.ts
        return String(format: "%.1f GB", Double(n) / Double(1 << 30))
    }
}

// MARK: - Schedules

/// The running session a schedule types its prompt into (instead of starting a headless `claude -p`).
public struct ScheduleTarget: Equatable, Sendable {
    public var id: UInt64, name: String, cwd: String
    public init(id: UInt64, name: String, cwd: String) { self.id = id; self.name = name; self.cwd = cwd }
    init?(json d: [String: Any]?) {
        guard let d, let id = (d["id"] as? NSNumber)?.uint64Value, let name = d["name"] as? String else { return nil }
        self.init(id: id, name: name, cwd: (d["cwd"] as? String) ?? "")
    }
    var json: [String: Any] { ["id": id, "name": name, "cwd": cwd] }
}

public struct ScheduleJob: Equatable, Sendable {
    public var id: String, name: String, prompt: String, folder: String
    public var target: ScheduleTarget?
    public var kind: String            // interval | daily | weekly
    public var minutes: Int
    public var times: [String]         // first = main time, rest = extra times
    public var days: [Int]             // 0 = Monday ... 6 = Sunday
    public var enabled: Bool
    public var timeoutMin: Int
    public var bypass: Bool
    public var chrome: Bool
    public var model: String       // claude --model; "" = Claude's default
    public var effort: String      // claude --effort; "" = Claude's default
    public var nextRun: Int64?
    public var running: Bool, queued: Bool
    public var runs: Int, ok: Int, failed: Int
    public var lastStatus: String?
    public var lastStarted: Int64?

    public init?(json d: [String: Any]) {
        guard let id = d["id"] as? String, let name = d["name"] as? String, let sch = d["schedule"] as? [String: Any], let kind = sch["kind"] as? String else { return nil }
        self.id = id; self.name = name; self.kind = kind
        prompt = (d["prompt"] as? String) ?? ""
        folder = (d["folder"] as? String) ?? ""
        target = ScheduleTarget(json: d["target"] as? [String: Any])
        minutes = (sch["minutes"] as? NSNumber)?.intValue ?? 60
        let main = (sch["time"] as? String).map { [$0] } ?? []
        times = main + ((sch["extraTimes"] as? [String]) ?? [])
        days = ((sch["days"] as? [NSNumber]) ?? []).map(\.intValue)
        enabled = (d["enabled"] as? Bool) ?? true
        timeoutMin = (d["timeoutMin"] as? NSNumber)?.intValue ?? 30
        bypass = (d["bypass"] as? Bool) ?? true
        chrome = (d["chrome"] as? Bool) ?? true
        model = (d["model"] as? String) ?? ""
        effort = (d["effort"] as? String) ?? ""
        nextRun = (d["nextRun"] as? NSNumber)?.int64Value
        running = (d["running"] as? Bool) ?? false
        queued = (d["queued"] as? Bool) ?? false
        runs = (d["runs"] as? NSNumber)?.intValue ?? 0
        ok = (d["ok"] as? NSNumber)?.intValue ?? 0
        failed = (d["failed"] as? NSNumber)?.intValue ?? 0
        let last = d["last"] as? [String: Any]
        lastStatus = last?["status"] as? String
        lastStarted = (last?["started"] as? NSNumber)?.int64Value
    }

    public var stateLabel: String {
        if running { return "Running" }
        if queued { return "Waiting" }
        if runs == 0 { return "Never run" }
        switch lastStatus { case "success": return "Success"; case "timeout": return "Timed out"; default: return "Failed" }
    }

    static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    public var describe: String {
        let at = ScheduleFormat.dayTimes(times).joined(separator: ", ")   // dayTimes() of src/lib/schedules.ts: sorted, no duplicates
        switch kind {
        case "interval": return minutes % 60 == 0 ? (minutes == 60 ? "Every hour" : "Every \(minutes / 60) hours") : "Every \(minutes) min"
        case "daily": return "Every day at \(at)"
        default:
            let d = Set(days)
            if d == [0, 1, 2, 3, 4] { return "Weekdays at \(at)" }
            if d == [5, 6] { return "Weekends at \(at)" }
            if d.count == 7 { return "Every day at \(at)" }
            return days.sorted().compactMap { $0 < 7 ? Self.dayNames[$0] : nil }.joined(separator: ", ") + " at \(at)"
        }
    }

    public func nextRunText(now: Date, calendar: Calendar = .current) -> String {
        if !enabled { return "off" }
        guard let ms = nextRun else { return "—" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let hm = f.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "today \(hm)" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: t) { return "tomorrow \(hm)" }
        f.dateFormat = "d MMM HH:mm"   // fmtClock: `${getDate()} ${month short} ${HH:mm}`
        return f.string(from: date)
    }
}

/// The formatters of src/lib/schedules.ts that the Schedules page shares with the old app.
public enum ScheduleFormat {
    /// Every time of day a daily / weekly schedule runs, sorted, without duplicates.
    public static func dayTimes(_ times: [String]) -> [String] { Array(Set(times)).sorted() }

    /// "just now", "5 min ago", "in 2 h", "in 3 d" (relTime): rounds, switches unit at 45 s / 1 h / 1 d.
    public static func relTime(ms: Int64, now: Date) -> String {
        let d = Double(ms) - now.timeIntervalSince1970 * 1000
        let a = abs(d)
        if a < 45_000 { return d > 0 ? "in a moment" : "just now" }
        func r(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }
        let (n, u) = a < 3_600_000 ? (r(a / 60_000), "min") : a < 86_400_000 ? (r(a / 3_600_000), "h") : (r(a / 86_400_000), "d")
        return d > 0 ? "in \(n) \(u)" : "\(n) \(u) ago"
    }
}

public struct ScheduleStats: Equatable, Sendable {
    public var schedules: String, runs: String, successRate: String, lastFailure: String

    public init(_ jobs: [ScheduleJob]) {
        let on = jobs.filter(\.enabled).count
        schedules = "\(jobs.count) (\(on) on · \(jobs.count - on) off)"
        let total = jobs.reduce(0) { $0 + $1.runs }, ok = jobs.reduce(0) { $0 + $1.ok }
        runs = "\(total)"
        successRate = total == 0 ? "—" : "\(Int((Double(ok) / Double(total) * 100).rounded()))%"
        let failed = jobs.filter { $0.lastStatus != nil && $0.lastStatus != "success" && $0.runs > 0 }.max { ($0.lastStarted ?? 0) < ($1.lastStarted ?? 0) }
        lastFailure = failed?.name ?? "None"
    }
}

public struct ScheduleRun: Equatable, Sendable {
    public var started: Int64, ended: Int64
    public var status: String, trigger: String
    public var costUsd: Double?
    public var output: String

    public init?(json d: [String: Any]) {
        guard let s = (d["started"] as? NSNumber)?.int64Value, let st = d["status"] as? String else { return nil }
        started = s
        ended = (d["ended"] as? NSNumber)?.int64Value ?? s
        status = st
        trigger = (d["trigger"] as? String) ?? "schedule"
        costUsd = (d["costUsd"] as? NSNumber)?.doubleValue
        output = (d["output"] as? String) ?? ""
    }

    public var triggerLabel: String { trigger == "manual" ? "Run now" : "Scheduled" }
    public var statusLabel: String { status == "success" ? "Success" : status == "timeout" ? "Timed out" : "Failed" }
    public var duration: String {
        let s = max(0, (ended - started) / 1000)
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }
}

/// The text of the banner above the cards, per runner state (nil = no banner).
public func runnerBanner(_ runner: String) -> String? {
    switch runner {
    case "other": return "Another Muya window is running these schedules, so timers are paused here. Run now still works."
    case "none": return "No process is running the schedule timers right now."
    default: return nil
    }
}

public func runnerLabel(_ runner: String) -> String {
    switch runner {
    case "service": return "Run by the Muya service"
    case "here": return "Run by this window"
    case "other": return "Run by another Muya window"
    default: return "Not running"
    }
}

/// The create / edit form. `toParams` is what `schedules.save` takes.
public struct ScheduleDraft: Equatable, Sendable {
    public var id: String?
    public var name = ""
    public var prompt = ""
    public var folder = ""
    /// Set: the schedule types into this session (the editor opened from a session's right-click menu).
    public var target: ScheduleTarget?
    public var kind = "daily"
    public var minutes = 60
    public var times = ["09:00"]
    public var days: Set<Int> = [0, 1, 2, 3, 4]
    public var enabled = true
    public var bypass = true
    public var chrome = true
    public var timeoutMin = 30
    public var model = ""
    public var effort = ""
    /// The effort levels `claude --effort` takes; "" (first) = Claude's default.
    public static let efforts = ["", "low", "medium", "high", "xhigh", "max"]

    public static let maxTimes = 6

    public init() {}

    public init(_ j: ScheduleJob) {
        id = j.id; name = j.name; prompt = j.prompt; folder = j.folder; target = j.target; kind = j.kind; minutes = j.minutes
        times = j.times.isEmpty ? ["09:00"] : j.times
        days = Set(j.days)
        enabled = j.enabled; bypass = j.bypass; chrome = j.chrome; timeoutMin = j.timeoutMin
        model = j.model; effort = j.effort
    }

    public func toParams() -> [String: Any] {
        var sch: [String: Any] = ["kind": kind]
        switch kind {
        case "interval": sch["minutes"] = minutes
        case "daily": sch["time"] = times.first ?? ""; sch["extraTimes"] = Array(times.dropFirst())
        default: sch["days"] = days.sorted(); sch["time"] = times.first ?? ""; sch["extraTimes"] = Array(times.dropFirst())
        }
        var job: [String: Any] = ["name": name, "prompt": prompt, "folder": folder, "schedule": sch, "enabled": enabled,
                                  "timeoutMin": timeoutMin, "bypass": bypass, "chrome": chrome,
                                  "model": model.trimmingCharacters(in: .whitespaces), "effort": effort]
        if let id { job["id"] = id }
        if let target { job["target"] = target.json }
        return ["job": job]
    }

    /// "Runs: ..." line under the schedule picker.
    public var summary: String {
        var j: [String: Any] = ["id": "x", "name": "x", "schedule": ["kind": kind, "minutes": minutes, "time": times.first ?? "", "extraTimes": Array(times.dropFirst()), "days": days.sorted()] as [String: Any]]
        j["enabled"] = true
        return "Runs: " + (ScheduleJob(json: j)?.describe.lowercasedFirst ?? "")
    }

    /// A new schedule for one running session: named after it, prompt empty, runs in its folder.
    public init(target t: ScheduleTarget) {
        name = t.name; folder = t.cwd; target = t
    }

    public mutating func addTime() {
        guard times.count < Self.maxTimes else { return }
        times.append(times.last ?? "09:00")
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - Command palette

public struct PaletteItem: Equatable, Sendable {
    public var id: String
    public var group: String
    public var title: String
    public var subtitle: String
    public init(id: String, group: String, title: String, subtitle: String = "") {
        self.id = id; self.group = group; self.title = title; self.subtitle = subtitle
    }
}

public enum Fuzzy {
    /// Subsequence score (higher is better); nil when `query` is not a subsequence of `text`.
    public static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace }), t = Array(text.lowercased())
        if q.isEmpty { return 0 }
        var score = 0, ti = 0, prev = -2
        for c in q {
            guard let hit = (ti ..< t.count).first(where: { t[$0] == c }) else { return nil }
            score += 10
            if hit == prev + 1 { score += 15 }                                  // consecutive
            if hit == 0 || !t[hit - 1].isLetter && !t[hit - 1].isNumber { score += 12 } // word start
            score -= min(hit - ti, 6)                                            // gaps cost a little
            prev = hit; ti = hit + 1
        }
        if t.starts(with: q) { score += 30 }
        return score - t.count / 8
    }

    /// Items matching `query`, best first (ties keep their order). An empty query keeps everything in order.
    public static func rank(_ items: [PaletteItem], _ query: String) -> [PaletteItem] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return items }
        let scored: [(Int, Int, PaletteItem)] = items.enumerated().compactMap { i, it in
            let s = [score(query, it.title), score(query, it.title + " " + it.subtitle).map { $0 - 20 }].compactMap { $0 }.max()
            return s.map { ($0, i, it) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2)
    }
}

// MARK: - Settings

public enum SettingKind: Sendable { case segmented([String]), toggle, popup([String]), text }

public struct SettingRow: Sendable {
    public var id: String          // key in the store
    public var section: String
    public var title: String
    public var helper: String
    public var kind: SettingKind
    /// "core": held by muya-core behind `prefs.*` / `debug_log.*`; "ui": the app's own prefs file.
    public var store: String
}

public enum SettingsSchema {
    public static let cleanupChoices = ["7 days", "14 days", "30 days", "60 days", "90 days", "180 days", "1 year"]
    public static let cleanupDays = [7, 14, 30, 60, 90, 180, 365]
    public static let appearanceChoices = ["System", "Light", "Dark"]

    public static let rows: [SettingRow] = [
        SettingRow(id: "appearance", section: "Appearance", title: "Theme", helper: "System follows your macOS appearance.", kind: .segmented(appearanceChoices), store: "ui"),
        SettingRow(id: "keepRunningInBackground", section: "Startup", title: "Keep running when the window is closed", helper: "Sessions and schedules stay alive; closing the window only hides it.", kind: .toggle, store: "core"),
        SettingRow(id: "openAtLogin", section: "Startup", title: "Open at login", helper: "Starts Muya when you log in to your Mac.", kind: .toggle, store: "ui"),
        SettingRow(id: "resumeOnLaunch", section: "Startup", title: "Resume Claude sessions on launch", helper: "Reopen the Claude sessions that were open when Muya quit.", kind: .toggle, store: "ui"),
        SettingRow(id: "autoApprove", section: "Startup", title: "Auto-allow permission prompts", helper: "Answers a Claude permission prompt for you after 2 seconds.", kind: .toggle, store: "ui"),
        SettingRow(id: "claudeStatusInFooter", section: "Claude", title: "Claude status in Muya's footer", helper: "Shows model, context and cost through a statusLine in ~/.claude/settings.json.", kind: .toggle, store: "core"),
        SettingRow(id: "claudeCleanupDays", section: "Claude", title: "Delete old Claude sessions after", helper: "Claude removes session history older than this (cleanupPeriodDays).", kind: .popup(cleanupChoices), store: "core"),
        SettingRow(id: "autoSave", section: "Editor", title: "Auto-save files", helper: "Saves a changed file a moment after you stop typing.", kind: .toggle, store: "ui"),
        SettingRow(id: "spotlightRoots", section: "Command palette", title: "Search files in these folders", helper: "Comma-separated folders for the palette's “Files on this Mac” results. Empty: no file search.", kind: .text, store: "ui"),
        SettingRow(id: "debugLog", section: "Debug logging", title: "Log CyberArk + SSH connection steps", helper: "Writes the steps (never secrets) to the log file below.", kind: .toggle, store: "core"),
        SettingRow(id: "debugLogPath", section: "Debug logging", title: "Log file", helper: "Default: ~/.claude/muya-debug.log", kind: .text, store: "core"),
    ]

    public static func cleanupLabel(days: Int?) -> String {
        guard let days else { return "30 days" }
        return cleanupDays.firstIndex(of: days).map { cleanupChoices[$0] } ?? "\(days) days"
    }
}

/// The app's own preferences (theme, terminal font size, ...) in one JSON file, written atomically.
public final class UIPrefs: @unchecked Sendable {
    public static let defaults: [String: Any] = ["appearance": "System", "resumeOnLaunch": false, "openAtLogin": false, "spotlightRoots": "", "autoApprove": false, "autoSave": false, "terminalFontSize": 13]
    private let url: URL
    private let lock = NSLock()
    private var values: [String: Any]

    public init(url: URL) {
        self.url = url
        values = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    public func get(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key] ?? Self.defaults[key]
    }

    public func string(_ key: String) -> String { (get(key) as? String) ?? "" }
    public func bool(_ key: String) -> Bool { (get(key) as? Bool) ?? false }
    public func int(_ key: String) -> Int { (get(key) as? NSNumber)?.intValue ?? 0 }

    /// P4 hook: every write is mirrored to ui-prefs.json under today's localStorage key (Prefs.swift).
    public var onSet: ((String, Any) -> Void)?

    private let queue = DispatchQueue(label: "muya.uiprefs", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var dirty = false
    /// Number of times the file was written (tests assert a burst of changes costs one write).
    public private(set) var writeCount = 0

    /// The change is visible at once; the file follows a quarter second later on a private queue (a burst of changes is one
    /// write, and the main thread never waits for the disk). `flush()` writes now.
    public func set(_ key: String, _ value: Any) {
        onSet?(key, value)
        lock.lock()
        values[key] = value
        dirty = true
        lock.unlock()
        queue.async { [self] in
            if timer != nil { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.25, leeway: .milliseconds(100))
            t.setEventHandler { [self] in timer?.cancel(); timer = nil; writeNow() }
            timer = t
            t.resume()
        }
    }

    /// Writes pending changes now (quit, losing focus, tests).
    public func flush() { queue.sync { timer?.cancel(); timer = nil; writeNow() } }

    private func writeNow() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        dirty = false
        let snapshot = values
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted]) else { return }
        do { try SecureFile.write(data, to: url); writeCount += 1 } catch { lock.lock(); dirty = true; lock.unlock() }
    }
}
