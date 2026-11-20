// App-side services of Faz 4e: the live Claude agent sessions (`claude agents --json`, binary picked by
// capability), the resume-on-launch snapshot, the open-at-login switch and the Spotlight file search.

import AppKit
import ServiceManagement

/// Runs `claude agents --json` off the main thread. The binary is resolved once, by what it can do (see
/// AgentsLogic.resolve) — never by path alone — and again if a later run fails (the CLI was updated).
final class AgentService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "muya.agents", qos: .utility)
    private let home: String
    private var bin: String?
    private(set) var lastError: String?
    /// Number of `claude agents --json` runs so far (diagnostics, CPU accounting).
    private(set) var runs = 0

    init(home: String) { self.home = home }

    func resolveBinary() -> String? {
        if let bin { return bin }
        let env = ProcessInfo.processInfo.environment
        let cands = AgentsLogic.candidates(home: home, loginShellAnswer: AgentsLogic.loginShellAnswer(shell: env["SHELL"]), path: env["PATH"])
        bin = AgentsLogic.resolve(cands, probe: AgentsLogic.supportsAgentsJSON)
        return bin
    }

    func refresh(completion: @escaping @MainActor (Result<[AgentRow], AgentError>) -> Void) {
        nonisolated(unsafe) let finish = completion
        queue.async { [self] in
            let result = fetch()
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(result) } }
        }
    }

    /// Synchronous variant for quit time (short time limit), called on the main thread: it only uses a binary that is
    /// already known. Looking for one (login shell up to 8 s, a 20 s probe per candidate) must never hold up quitting.
    func fetchNow(timeout: TimeInterval = 4) -> [AgentRow]? {
        queue.sync { if bin != nil, case let .success(rows) = fetch(timeout: timeout, mayResolve: false) { return rows } else { return nil } }
    }

    private func fetch(timeout: TimeInterval = 15, mayResolve: Bool = true) -> Result<[AgentRow], AgentError> {
        for attempt in 0 ..< 2 {
            guard let b = mayResolve ? resolveBinary() : bin else {
                lastError = "Claude CLI not found, or too old to list sessions (`claude agents --json`)."
                return .failure(.noClaude(lastError!))
            }
            runs += 1
            if let data = AgentsLogic.runAgents(b, timeout: timeout), let rows = AgentsLogic.parse(data) { lastError = nil; return .success(rows) }
            if !mayResolve { break }
            bin = nil // re-resolve once: the CLI may have been replaced or updated
            if attempt == 1 { break }
        }
        lastError = "`claude agents --json` did not answer."
        return .failure(.failed(lastError!))
    }
}

enum AgentError: Error { case noClaude(String), failed(String)
    var text: String { switch self { case let .noClaude(m), let .failed(m): return m } }
}

/// Remembers the interactive Claude sessions that are open, so "Resume Claude sessions on launch" can reopen
/// them when the daemon came back without terminals (after a restart of the Mac, for instance).
final class ResumeService: @unchecked Sendable {
    private let agents: AgentService
    private let prefs: UIPrefs
    private var timer: Timer?

    init(agents: AgentService, prefs: UIPrefs) { self.agents = agents; self.prefs = prefs }

    var saved: [ResumeEntry] { ((prefs.get("lastClaudeSessions") as? [[String: Any]]) ?? []).compactMap(ResumeEntry.init(json:)) }

    /// Called whenever the agent list was read anyway (the Sessions page), and every 5 minutes while the setting is on.
    func remember(_ rows: [AgentRow]) {
        guard prefs.bool("resumeOnLaunch") else { return }
        let snap = ResumeLogic.snapshot(from: rows)
        if snap.isEmpty && !saved.isEmpty { return } // an empty answer must not erase what the last run had open
        prefs.set("lastClaudeSessions", snap.map(\.json))
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self, self.prefs.bool("resumeOnLaunch") else { return }
            self.agents.refresh { r in if case let .success(rows) = r { self.remember(rows) } }
        }
        timer?.tolerance = 60
    }

    func rememberAtQuit() {
        guard prefs.bool("resumeOnLaunch"), let rows = agents.fetchNow() else { return }
        remember(rows)
    }
}

/// "Open at login" (SMAppService). Never runs in a sandbox with a fake HOME, so tests and dev runs cannot
/// register anything with the real user's login items.
enum LoginItem {
    static func isRealHome(_ home: String) -> Bool {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return false }
        return String(cString: dir) == home
    }

    /// Applies the stored preference; returns a message when it could not be applied.
    @discardableResult
    static func apply(_ on: Bool, home: String) -> String? {
        guard isRealHome(home) else { return nil }
        do {
            if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            return nil
        } catch { return "Could not change the login item: \(error.localizedDescription)" }
    }
}

/// "Files on this Mac" in the command palette: an NSMetadataQuery limited to the folders the user chose.
final class SpotlightSearch: NSObject {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    var onResults: (([PaletteItem]) -> Void)?
    private let home: String
    /// How many queries were started (diagnostics).
    private(set) var started = 0

    init(home: String) { self.home = home }

    /// Starts (or replaces) a search; `roots` come from the user's setting. Nothing is searched without roots.
    func search(_ text: String, roots: [String]) {
        stop()
        let scopes = SpotlightLogic.scopes(roots: roots) { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
        guard let term = SpotlightLogic.sanitized(text), !scopes.isEmpty else { onResults?([]); return }
        let q = NSMetadataQuery()
        q.searchScopes = scopes
        q.predicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", term)
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemContentModificationDate", ascending: false)]
        q.notificationBatchingInterval = 0.2
        let nc = NotificationCenter.default
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(nc.addObserver(forName: name, object: q, queue: .main) { [weak self] n in
                nonisolated(unsafe) let note = n
                MainActor.assumeIsolated { if let q = note.object as? NSMetadataQuery { self?.deliver(q) } }
            })
        }
        query = q
        started += 1
        q.start()
    }

    private func deliver(_ q: NSMetadataQuery) {
        q.disableUpdates()
        var items: [PaletteItem] = []
        for i in 0 ..< min(q.resultCount, 20) {
            guard let r = q.result(at: i) as? NSMetadataItem, let path = r.value(forAttribute: kMDItemPath as String) as? String else { continue }
            items.append(PaletteItem(id: "file:\(path)", group: "Files on this Mac", title: (path as NSString).lastPathComponent, subtitle: SpotlightLogic.subtitle(path: path, home: home)))
        }
        q.enableUpdates()
        onResults?(items)
    }

    /// Stops the running query. Called when the palette closes or the text changes: a stopped query costs nothing.
    func stop() {
        query?.stop()
        query = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }
}
