// P4: today's app keeps its UI state in webview localStorage (keys apex.* / muya.*). muya_core::migrate copies those
// keys into `ui-prefs.json` ({ "<localStorage key>": "<string the webview stored>" }); this file is the ONE place the native
// app reads and writes them, under the same keys and with the same value formats, so a migrated file restores the same state
// and anything the native app writes is readable by the old one.

import Foundation

/// `ui-prefs.json`. Reads once; writes are debounced and merged: only keys this process changed are applied on top of
/// whatever is on disk at flush time, so another writer's keys (QueuePrefs: apex.mergeQueue) are never lost.
public final class LegacyStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var values: [String: String]
    private var dirty: [String: String?] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "muya.legacyprefs", qos: .utility)
    private let delay: TimeInterval
    /// Number of times the file was written (the measurable cost: tests and verify-p4 assert it stays tiny).
    public private(set) var writeCount = 0

    public static func path(home: String) -> String { home + "/Library/Application Support/com.staunch.muya/native/ui-prefs.json" }

    public init(url: URL, debounce: TimeInterval = 1.0) {
        self.url = url
        delay = debounce
        values = Self.read(url) ?? [:]
    }

    /// nil: no file. A garbled file is moved aside (kept for the operator) and counts as empty, so later writes work.
    private static func read(_ url: URL) -> [String: String]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String] { return obj }
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
        return nil
    }

    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return values.isEmpty }

    public func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }

    /// nil removes the key (the webview does the same for "off" / empty values). No-op when nothing changes.
    public func set(_ key: String, _ value: String?) {
        lock.lock()
        if values[key] == value { lock.unlock(); return }
        values[key] = value
        dirty[key] = .some(value)
        lock.unlock()
        schedule()
    }

    private func schedule() {
        queue.async { [self] in
            if timer != nil { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + delay, leeway: .milliseconds(200))
            t.setEventHandler { [self] in timer?.cancel(); timer = nil; writeNow() }
            timer = t
            t.resume()
        }
    }

    /// Writes pending changes now (quit, tests).
    public func flush() { queue.sync { timer?.cancel(); timer = nil; writeNow() } }

    private func writeNow() {
        lock.lock()
        let pending = dirty
        dirty = [:]
        lock.unlock()
        guard !pending.isEmpty else { return }
        var disk = Self.read(url) ?? [:]
        for (k, v) in pending { disk[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: disk, options: [.sortedKeys]) else { return }
        do {
            try SecureFile.write(data, to: url)
            writeCount += 1
        } catch {
            lock.lock(); for (k, v) in pending where dirty[k] == nil { dirty[k] = .some(v) }; lock.unlock()
        }
    }
}

/// Value formats of today's keys (usePersistentState stores JSON; some keys are raw strings or "1").
public enum PrefCodec {
    public static func bool(_ raw: String?) -> Bool? {
        guard let raw, let d = raw.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) as? NSNumber,
              CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return v.boolValue
    }
    public static func encode(bool: Bool) -> String { bool ? "true" : "false" }

    /// A JSON number, rounded and clamped like usePanelLayout's asClampedNumber; anything else is nil (= use the default).
    public static func number(_ raw: String?, min lo: Double, max hi: Double) -> Double? {
        guard let raw, let d = raw.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) as? NSNumber,
              !(v === kCFBooleanTrue) , !(v === kCFBooleanFalse) else { return nil }
        let x = v.doubleValue
        guard x.isFinite else { return nil }
        return Swift.min(Swift.max(x.rounded(), lo), hi)
    }
    public static func encode(number: Double) -> String { String(Int(number.rounded())) }

    public static func stringList(_ raw: String?) -> [String]? {
        guard let raw, let d = raw.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d) as? [Any] else { return nil }
        return v.compactMap { $0 as? String }
    }
    public static func encode(list: [String]) -> String {
        (try? JSONSerialization.data(withJSONObject: list)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    /// "1" flags (autoApprove, autoSave, resumeOnLaunch): on = "1", off = key removed.
    public static func flag(_ raw: String?) -> Bool { raw == "1" }
    public static func encode(flag: Bool) -> String? { flag ? "1" : nil }

    /// apex.theme is the raw string system | light | dark; native settings say System | Light | Dark.
    public static func appearance(_ raw: String?) -> String? {
        switch raw { case "system": return "System"; case "light": return "Light"; case "dark": return "Dark"; default: return nil }
    }
    public static func encode(appearance: String) -> String { appearance.lowercased() }

    /// muya.terminalPrefs is JSON {fontSize, lineHeight, letterSpacing, scheme}; the font size is clamped 9-28.
    public static func fontSize(_ raw: String?) -> Int? {
        guard let raw, let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let n = o["fontSize"] as? NSNumber, n.doubleValue.isFinite else { return nil }
        return Int(Swift.min(Swift.max(n.doubleValue.rounded(), 9), 28))
    }
    /// The colour scheme id of muya.terminalPrefs (an unknown id reads as "muya", like validate() in terminalPrefs.ts).
    public static func scheme(_ raw: String?) -> String? {
        guard let raw, let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = o["scheme"] as? String else { return nil }
        return TerminalSchemes.all.contains { $0.id == s } ? s : "muya"
    }
    public static func encode(scheme: String, into raw: String?) -> String {
        var o: [String: Any] = [:]
        if let raw, let d = raw.data(using: .utf8), let cur = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { o = cur }
        o["scheme"] = TerminalSchemes.all.contains { $0.id == scheme } ? scheme : "muya"
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{\"scheme\":\"muya\"}"
    }
    /// Keeps lineHeight / letterSpacing / scheme as the old app wrote them.
    public static func encode(fontSize: Int, into raw: String?) -> String {
        var o: [String: Any] = [:]
        if let raw, let d = raw.data(using: .utf8), let cur = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { o = cur }
        o["fontSize"] = fontSize
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{\"fontSize\":\(fontSize)}"
    }

    /// muya.openFiles: [{key, kind: editor|mdview|imgview|pdfview, filePath, name}], newest last, at most 30.
    public static let maxOpenFiles = 30
    public static func openFiles(_ raw: String?) -> [String]? {
        guard let raw, let d = raw.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d) as? [Any] else { return nil }
        let kinds: Set<String> = ["editor", "mdview", "imgview", "pdfview"]
        let paths = v.compactMap { e -> String? in
            guard let o = e as? [String: Any], o["key"] is String, o["name"] is String, let k = o["kind"] as? String, kinds.contains(k), let p = o["filePath"] as? String else { return nil }
            return p
        }
        return Array(paths.suffix(maxOpenFiles))
    }
    public static func encode(openFiles paths: [String], kind: (String) -> String, previous: String?) -> String {
        // Entries the old app already wrote keep their key (so its tab identity survives a round trip).
        var keys: [String: String] = [:]
        if let previous, let d = previous.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            for e in v { if let p = e["filePath"] as? String, let k = e["key"] as? String { keys[p] = k } }
        }
        let list: [[String: Any]] = paths.suffix(maxOpenFiles).map { p in
            ["key": keys[p] ?? "file:" + p, "kind": kind(p), "filePath": p, "name": (p as NSString).lastPathComponent]
        }
        return (try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    /// apex.composerHistory.<kind>: JSON string[], newest last, at most 200.
    public static let maxHistory = 200
    public static func history(_ raw: String?) -> [String]? { stringList(raw).map { Array($0.suffix(maxHistory)) } }
}

/// Every key today's app uses (src/ at the time of P4) and what the native app does with it. `obsolete` keys are never
/// touched: they stay in the file exactly as migrated (a later step or the old app may still want them).
public enum PrefKeys {
    public static let theme = "apex.theme"                 // src/theme/theme.ts:20
    public static let autoApprove = "muya.autoApprove"     // src/lib/autoApprove.ts:7
    public static let autoSave = "muya.autoSave"           // src/lib/fileVersions.ts:84
    public static let resumeOnLaunch = "muya.resumeOnLaunch" // src/lib/startup.ts:3
    public static let terminalPrefs = "muya.terminalPrefs" // src/lib/terminalPrefs.ts:29
    public static let viewMode = "apex.viewMode"           // src/App.tsx:390 ("grid" | "tabs")
    public static let splitGroups = "muya.splitGroups"                 // src/App.tsx:2067 (native: keys are "<session id>:<pid>", SplitLogic.dropLegacyKeys)
    public static let splitCollapsed = "muya.splitGroupsCollapsed"      // src/App.tsx:2068
    public static let agentsOpen = "muya.panels.agentsOpen"       // src/redesign/usePanelLayout.ts:16
    public static let inspectorOpen = "muya.panels.inspectorOpen" // :17
    public static let agentsWidth = "muya.panels.agentsWidth"     // :18 (220-480)
    public static let inspectorWidth = "muya.panels.inspectorWidth" // :19 (260-520)
    public static let filesOpen = "muya.panels.filesOpen"         // :20
    public static let filesHeight = "muya.panels.filesHeight"     // usePanelLayout.ts:21 (120-2000, absent = fill)
    public static let selectedRoot = "apex.selectedRoot"   // src/App.tsx:588 (absent = All workspaces)
    public static let openFiles = "muya.openFiles"         // src/App.tsx:199
    public static let composerHistoryAgent = "apex.composerHistory.agent" // src/redesign/composerHistory.ts:10
    public static let mergeQueue = "apex.mergeQueue"       // src/components/QueuePage.tsx:52 (QueuePrefs, P-queue)

    public static let agentsWidthRange = (min: 220.0, max: 480.0)
    public static let inspectorWidthRange = (min: 260.0, max: 520.0)

    /// key -> why the native app does not read it. Webview-only: tab identity, React layout state, features native lacks.
    public static let obsolete: [String: String] = [
        "apex.openTabs": "tab list of the webview; native sessions live in muyad and survive quit, Claude ones reopen through resumeOnLaunch (lastClaudeSessions)",
        "muya.selectedAgent": "keyed by a webview tab key; native selects by muyad session id (first live session on connect)",
        "apex.gridKeys": "webview tab keys; the native grid shows the first six sessions plus the selected one",
        "muya.gridLayout": "native tiles pick the shape from the session count (1/2/4/6), there is no layout choice",
        "apex.workspaces": "user-added file-tree roots; the native Files rail follows the selected session's directory",
        "apex.worktrees": "worktree list of the webview Queue; native Queue derives it from the sessions' directories",
        "muya.notifications": "bell log; the native bell shows 'No notifications.' (no feed yet, tracked in parity.md)",
        "muya.notificationsUnread": "bell dot; same as notifications",
        "muya.composerOpen": "the native composer is part of the single-session view and has no hide control",
        "muya.sessionHeaderCollapsed": "the native session bar has no collapse control",
        "muya.lastActive": "v1 of lastActive; the old app deletes it on read",
        "muya.lastActive.v2": "feeds the webview 'Recent' filter; the native agents panel has no recent filter",
        "muya.servers.collapsed": "the native SSH page lists servers without foldable groups",
        "muya.vault.collapsed": "the native vault panel has no foldable groups",
        "muya.fileAccessGate.dismissed": "webview file-access gate; native reads files directly and macOS asks itself",
        "apex.composerHistory.shell": "the native composer has one history (stored as 'agent'); shell history stays as migrated",
        "muya.waitingSince": "sessionStorage in the webview (not even in localStorage)",
    ]
}

/// Keeps the native settings (UIPrefs, prefs.json: "appearance", "autoApprove" ...) and today's localStorage keys in
/// ui-prefs.json equal: at start the migrated value wins, afterwards every settings write is mirrored.
public final class PrefsBridge {
    public let legacy: LegacyStore
    private let prefs: UIPrefs
    private static let flags: [(native: String, key: String)] = [("autoApprove", PrefKeys.autoApprove), ("autoSave", PrefKeys.autoSave), ("resumeOnLaunch", PrefKeys.resumeOnLaunch)]

    /// Lists (JSON string[]; key removed when empty) and a raw day string, added by the UI work.
    private static let lists: [(native: String, key: String)] = [("pinnedAgents", "muya.pinnedAgents"), ("statusFields", "muya.footer.statusFields")]
    private static let dayKey = (native: "storageHeadsUpDay", key: "apex.sessionsHeadsUp")

    public init(prefs: UIPrefs, legacy: LegacyStore) {
        self.prefs = prefs
        self.legacy = legacy
        seed()
        prefs.onSet = { [weak self] k, v in self?.mirror(k, v) }
    }

    private func seed() {
        if let a = PrefCodec.appearance(legacy.get(PrefKeys.theme)) {
            if prefs.string("appearance") != a { prefs.set("appearance", a) }
        } else if let cur = prefs.get("appearance") as? String, cur != "System" { mirror("appearance", cur) }
        for f in Self.flags {
            if legacy.get(f.key) == "1" {
                if !prefs.bool(f.native) { prefs.set(f.native, true) }
            } else if prefs.bool(f.native) { mirror(f.native, true) }
        }
        for l in Self.lists {
            if let v = PrefCodec.stringList(legacy.get(l.key)) {
                if (prefs.get(l.native) as? [String]) != v { prefs.set(l.native, v) }
            } else if let cur = prefs.get(l.native) as? [String], !cur.isEmpty { mirror(l.native, cur) }
        }
        if let d = legacy.get(Self.dayKey.key) { if prefs.string(Self.dayKey.native) != d { prefs.set(Self.dayKey.native, d) } }
        else if !prefs.string(Self.dayKey.native).isEmpty { mirror(Self.dayKey.native, prefs.string(Self.dayKey.native)) }
        if let n = PrefCodec.fontSize(legacy.get(PrefKeys.terminalPrefs)) {
            if prefs.int("terminalFontSize") != n { prefs.set("terminalFontSize", n) }
        } else if prefs.int("terminalFontSize") != 13 { mirror("terminalFontSize", prefs.int("terminalFontSize")) }
        if let sc = PrefCodec.scheme(legacy.get(PrefKeys.terminalPrefs)) {
            if prefs.string("terminalScheme") != sc { prefs.set("terminalScheme", sc) }
        } else if !prefs.string("terminalScheme").isEmpty, prefs.string("terminalScheme") != "muya" { mirror("terminalScheme", prefs.string("terminalScheme")) }
    }

    func mirror(_ key: String, _ value: Any) {
        if key == "appearance", let s = value as? String { legacy.set(PrefKeys.theme, PrefCodec.encode(appearance: s)) }
        else if key == "terminalFontSize", let n = value as? Int ?? (value as? NSNumber)?.intValue {
            legacy.set(PrefKeys.terminalPrefs, PrefCodec.encode(fontSize: n, into: legacy.get(PrefKeys.terminalPrefs)))
        } else if key == "terminalScheme", let sc = value as? String {
            legacy.set(PrefKeys.terminalPrefs, PrefCodec.encode(scheme: sc, into: legacy.get(PrefKeys.terminalPrefs)))
        } else if let l = Self.lists.first(where: { $0.native == key }), let v = value as? [String] {
            legacy.set(l.key, v.isEmpty ? nil : PrefCodec.encode(list: v))
        } else if key == Self.dayKey.native, let d = value as? String {
            legacy.set(Self.dayKey.key, d.isEmpty ? nil : d)
        } else if let f = Self.flags.first(where: { $0.native == key }), let b = value as? Bool { legacy.set(f.key, PrefCodec.encode(flag: b)) }
    }
}

/// Files of the app's own state (preferences, names): the folder is 0700 and a file is 0600 from its first byte —
/// written to a temp file opened with that mode, then renamed over the target, so no reader ever sees a half file
/// or a world-readable one.
public enum SecureFile {
    public static func ensureDirectory(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    public static func write(_ data: Data, to url: URL) throws {
        ensureDirectory(url.deletingLastPathComponent())
        let tmp = url.path + ".tmp-\(getpid())"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var failed: Int32 = 0
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; failed = errno; return }
                off += n
            }
        }
        if failed == 0, fsync(fd) != 0 { failed = errno }
        Darwin.close(fd)
        if failed == 0, rename(tmp, url.path) != 0 { failed = errno }
        if failed != 0 { unlink(tmp); throw NSError(domain: NSPOSIXErrorDomain, code: Int(failed)) }
    }
}
