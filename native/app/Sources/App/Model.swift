// App state: the connection to muyad, one SessionModel per daemon session, names persisted per
// install. Everything the UI shows comes from muyad (list, snapshot + output, screen state); the
// only thing stored locally is the display name of a session.

import AppKit
import Darwin
import Foundation

/// What the sidebar shows for a session, derived from `Control::Screen`.
struct ScreenSummary: Equatable {
    var activity: String?
    var busy = false
    var mode = "default"
    var modeDetected = false
    var permission = false
    /// The key that answers "Allow" and an id of what is being asked (tool + target), from the daemon's screen state.
    var approveKey: String?
    /// The "yes, and don't ask again" answer of the prompt (permission kind approveAlways) and its label, when the prompt has one.
    var alwaysKey: String?, alwaysLabel: String?
    var promptKey = ""

    init?(json: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        if let a = obj["activity"] as? [String: Any] { activity = a["verb"] as? String }
        busy = (obj["busy"] as? Bool) ?? false
        mode = (obj["mode"] as? String) ?? "default"
        modeDetected = (obj["modeDetected"] as? Bool) ?? false
        permission = obj["permission"] != nil
        if let p = obj["permission"] as? [String: Any] {
            promptKey = "\((p["tool"] as? String) ?? "")|\((p["target"] as? String) ?? "")|\((p["question"] as? String) ?? "")"
            approveKey = (p["options"] as? [[String: Any]])?.first { ($0["kind"] as? String) == "approve" }?["key"] as? String
            let always = (p["options"] as? [[String: Any]])?.first { ($0["kind"] as? String) == "approveAlways" }
            alwaysKey = always?["key"] as? String; alwaysLabel = always?["label"] as? String
        }
    }
}

final class SessionModel {
    let id: UInt64
    let pid: Int32
    var name: String
    var cwd: String
    var exited: Int32?
    var screen: ScreenSummary?
    /// Optional display overrides (the dev mock mode fills them; the daemon path leaves them nil): the card's status line,
    /// the elapsed time ("4m 15s") and the agent kind ("claude" / "opencode").
    /// Set when an agent opened this terminal through open_session: the opener's name (nil = the operator opened it).
    var openedBy: String?
    var statusLine: String?, elapsed: String?, kind: String?, progress: String?   // progress: the strip above the message box
    let replica: Replica

    init(id: UInt64, pid: Int32, name: String, cwd: String, replica: Replica) {
        self.id = id; self.pid = pid; self.name = name; self.cwd = cwd; self.replica = replica
    }

    /// State label + colour token for the sidebar row.
    var state: (text: String, color: NSColor) {
        if let code = exited { return ("Exited (\(code))", Token.stateExited) }
        guard let s = screen else { return ("Shell", Token.stateIdle) }
        if s.permission { return ("Needs permission", Token.statePermission) }
        if s.busy || s.activity != nil { return ("Working" + (s.activity.map { " · \($0)" } ?? ""), Token.stateBusy) }
        if s.modeDetected { return ("Claude · \(s.mode)", Token.stateClaude) }
        return ("Shell", Token.stateIdle)
    }

    /// The shell's live working directory (the daemon does not report it).
    static func currentDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard n == MemoryLayout<proc_vnodepathinfo>.size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}

extension SessionModel {
    /// The kind icon and its colour: Claude / opencode / terminal, and a robot for a terminal an agent opened (open_session).
    var kindIconChoice: (icon: ThemeIcon, color: NSColor) {
        if openedBy != nil { return (.agentOpened, Theme.dynamic(.agentClaude)) }
        let isClaude = screen?.modeDetected == true || kind == "claude"
        return (kind == "opencode" ? .opencodeKind : isClaude ? .claudeKind : .terminalKind, Theme.dynamic(kind == "opencode" ? .agentOpencode : isClaude ? .agentClaude : .accent))
    }
    var openedByTooltip: String? { SessionOrigin.tooltip(openedBy: openedBy) }
}

extension String {
    /// `/Users/x/dev` -> `~/dev` for the given home.
    func abbreviatingHome(_ home: String) -> String {
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }
}

protocol StoreDelegate: AnyObject {
    func storeDidChangeSessions(_ store: Store)
    func store(_ store: Store, didUpdate session: SessionModel)
    func store(_ store: Store, selectionChanged session: SessionModel?)
    func store(_ store: Store, connectionChanged connected: Bool, message: String)
    func store(_ store: Store, outputFor session: SessionModel)
}

final class Store: @unchecked Sendable {
    weak var delegate: StoreDelegate?
    private(set) var sessions: [SessionModel] = []
    private(set) var selected: SessionModel?
    private(set) var connected = false
    /// AC19/AC21: what the last failed connection meant, the "later" hello version, the restart in progress (RestartDialog.swift).
    let service = ServiceState()
    let socketPath: String
    let home: String
    var theme: TerminalTheme = .dark
    /// Grid of the visible terminal view; new sessions start at this size.
    var grid = (cols: 100, rows: 30)
    var cell = (w: 8, h: 16)

    var connection: MuyadConnection? // AC19/AC21 (ServiceGate) reads it
    /// The app's own preferences (theme, flags); the ones muya-core owns go through `call`.
    let prefs: UIPrefs
    /// P4: today's localStorage keys (ui-prefs.json); `bridge` keeps the settings above in step with them.
    let legacy: LegacyStore
    let bridge: PrefsBridge
    private let namesURL: URL
    private let orderURL: URL
    /// The agent list's order the operator made by dragging ("id:pid" per session); new sessions go to the end.
    private var order: [String] = []
    private var names: [String: String] = [:]
    private var openers: [String: String] = [:]
    private var openersURL: URL!
    var reconnectTimer: Timer?
    private let build = "muya-native-dev"
    /// Launch timing for the AC9 check (debug socket `launch`): when the sidebar first listed the daemon's
    /// sessions, and when each session's attach snapshot (its restored screen) was first written.
    private(set) var sessionsShownAt: Date?
    private(set) var snapshotAt: [UInt64: Date] = [:] // guarded by outputLock
    func snapshotTimes() -> [UInt64: Date] { outputLock.lock(); defer { outputLock.unlock() }; return snapshotAt }

    /// Dev-only mock mode (MUYA_MOCK=1 with MUYA_DEBUG_SOCKET): `Mock.swift` seeds sessions without a daemon so screenshots
    /// can be compared with the web UI's mock data (ui-diff measures style, not content).
    private(set) var mockMode = false
    func installMock(_ list: [SessionModel], selected idx: Int) {
        mockMode = true; sessions = list; selected = list.indices.contains(idx) ? list[idx] : nil; connected = true
        delegate?.storeDidChangeSessions(self)
    }

    init(socketPath: String, home: String) {
        self.socketPath = socketPath
        self.home = realpath(home, nil).map { let p = String(cString: $0); free($0); return p } ?? home // shells report physical paths
        let dir = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/MuyaNative")
        SecureFile.ensureDirectory(dir)
        namesURL = dir.appendingPathComponent("names.json")
        orderURL = dir.appendingPathComponent("order.json")
        prefs = UIPrefs(url: dir.appendingPathComponent("prefs.json"))
        legacy = LegacyStore(url: URL(fileURLWithPath: LegacyStore.path(home: self.home)))
        bridge = PrefsBridge(prefs: prefs, legacy: legacy)
        if let data = try? Data(contentsOf: namesURL), let d = try? JSONSerialization.jsonObject(with: data) as? [String: String] { names = d }
        openersURL = dir.appendingPathComponent("openers.json")
        if let data = try? Data(contentsOf: openersURL), let d = try? JSONSerialization.jsonObject(with: data) as? [String: String] { openers = d }
        if let data = try? Data(contentsOf: orderURL), let d = try? JSONSerialization.jsonObject(with: data) as? [String] { order = d }
    }

    // MARK: Connection

    func connect() {
        reconnectTimer?.invalidate()
        // A second connect() (a reconnect that overlapped the first one) must not leave the old link alive: muyad would keep
        // it as a second app and every event (open_session!) would reach this process twice, opening two tabs.
        if let old = connection { old.onFrame = nil; old.onClose = nil; old.close(); connection = nil }
        do {
            let conn = try MuyadConnection(path: socketPath, build: build, announce: helloAnnounce)
            conn.onFrame = { [weak self] f in self?.handle(f) }
            conn.onClose = { [weak self] in DispatchQueue.main.async { self?.connectionLost() } }
            conn.start()
            connection = conn
            guard case let .sessions(list) = try conn.request(.list) else { throw ClientError.handshake("bad list reply") }
            sessions = []
            attached = []
            publishSnapshot()
            for info in list.sorted(by: { $0.id < $1.id }) { try adopt(info) }
            applySavedOrder()
            connected = true
            delegate?.store(self, connectionChanged: true, message: "")
            delegate?.storeDidChangeSessions(self)
            if sessionsShownAt == nil { sessionsShownAt = Date() }
            select(sessions.first(where: { $0.exited == nil }) ?? sessions.first)
            serviceConnected()
        } catch {
            connected = false
            connection?.close()
            connection = nil
            delegate?.store(self, connectionChanged: false, message: service.statusText ?? "\(error)")
            serviceFailed(error)
        }
    }

    /// AC19 "restart now": the daemon ended every session and exited; forget them here, the resume plan reopens them.
    func dropAllSessions() {
        connected = false
        connection?.close()
        connection = nil
        sessions = []
        attached = []
        publishSnapshot()
        delegate?.storeDidChangeSessions(self)
        select(nil)
    }

    /// After the Mac woke from sleep: ask muyad for its session list again. Sessions the daemon still has stay;
    /// ones it has that we lack are adopted; exit states are refreshed. A dead socket goes through the normal reconnect.
    func resyncAfterWake() {
        guard connected, let conn = connection else { if !connected { connect() }; return }
        do {
            guard case let .sessions(list) = try conn.request(.list, timeout: 3) else { throw ClientError.handshake("bad list reply") }
            var changed = false
            for info in list.sorted(by: { $0.id < $1.id }) {
                if let s = sessions.first(where: { $0.id == info.id }) {
                    if s.exited != info.exited { s.exited = info.exited; delegate?.store(self, didUpdate: s) }
                } else { try adopt(info); changed = true }
            }
            if changed { delegate?.storeDidChangeSessions(self) }
        } catch {
            connection?.close()
            connection = nil
            connectionLost2()
        }
    }

    private func connectionLost2() {
        connected = false
        delegate?.store(self, connectionChanged: false, message: "muyad went away")
        scheduleReconnect()
    }

    private func connectionLost() {
        guard connected else { return }
        connected = false
        connection = nil
        delegate?.store(self, connectionChanged: false, message: "muyad went away")
        scheduleReconnect()
    }

    func scheduleReconnect() {
        reconnectTimer?.invalidate()
        let delay = ReconnectPolicy.delay(onboarding: problem == .needsApproval, restarting: restarting)
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.connect() }
        reconnectTimer?.tolerance = delay / 4
    }

    /// Creates the local replica for a daemon session and attaches: muyad answers with a VT
    /// snapshot of its terminal, then live output.
    private func adopt(_ info: SessionInfo) throws {
        guard let replica = Replica(cols: Int(info.cols), rows: Int(info.rows), theme: theme) else { throw ClientError.handshake("terminal allocation failed") }
        let cwd = SessionModel.currentDirectory(of: info.pid) ?? home
        let key = "\(info.id):\(info.pid)"
        let name = names[key] ?? (cwd == home ? "Shell" : (cwd as NSString).lastPathComponent)
        let model = SessionModel(id: info.id, pid: info.pid, name: name, cwd: cwd, replica: replica)
        model.exited = info.exited
        model.openedBy = openers[key]
        sessions.append(model)
        publishSnapshot() // output can arrive before the attach reply: the reader thread must find the model
        if let conn = connection, conn.serverMinor >= minorDetach {
            // Screen-only until a view needs the output (AC24: replicas only for visible sessions).
            _ = try conn.request(.detach(id: info.id))
        } else {
            _ = try connection?.request(.attach(id: info.id))
            attached.insert(info.id)
        }
        recomputeInterest()
    }

    // MARK: Output interest (AC24 / AC8)

    /// Sessions muyad currently streams output for (main thread).
    private(set) var attached = Set<UInt64>()
    /// Fast-switch cache: sessions that were visible most recently stay attached.
    static let recentKept = 3
    private var visibleIDs: [UInt64] = []
    private var recent: [UInt64] = []
    private var windowActive = true

    /// The views show these sessions now; everything else is detached after the small recent list.
    func setVisible(_ sessions: [SessionModel]) {
        let ids = sessions.map(\.id)
        guard ids != visibleIDs else { return }
        for id in visibleIDs where !ids.contains(id) { recent.removeAll { $0 == id }; recent.insert(id, at: 0) }
        recent.removeAll { ids.contains($0) }
        recent = Array(recent.prefix(Store.recentKept))
        visibleIDs = ids
        recomputeInterest()
    }

    /// False while the window is occluded, minimized or the Mac sleeps: nothing is streamed.
    func setActive(_ active: Bool) {
        guard active != windowActive else { return }
        windowActive = active
        recomputeInterest()
    }

    private func recomputeInterest() {
        guard let conn = connection, conn.serverMinor >= minorDetach else { return }
        let wanted: Set<UInt64> = windowActive ? Set(visibleIDs + recent) : []
        for s in sessions {
            if wanted.contains(s.id) {
                if attached.insert(s.id).inserted { conn.send(.attach(id: s.id)) }
            } else if attached.remove(s.id) != nil {
                conn.send(.detach(id: s.id))
            }
        }
    }

    // MARK: Frames (reader thread)

    private func handle(_ frame: Frame) {
        switch frame {
        case let .control(.attached(id, _, _, _)):
            awaitingSnapshot.insert(id)
        case let .output(id, _, data):
            guard let s = sessionForOutput(id) else { return }
            // The first output after Attached is the VT snapshot of muyad's terminal.
            let isSnapshot = awaitingSnapshot.remove(id) != nil
            s.replica.write(isSnapshot ? repairSnapshotCursor(data) : data)
            if isSnapshot { outputLock.lock(); if snapshotAt[id] == nil { snapshotAt[id] = Date() }; outputLock.unlock() }
            // One main-queue hop per burst, not per frame: a stream arrives in thousands of frames.
            outputLock.lock()
            let hop = !outputNotified.contains(id)
            outputNotified.insert(id)
            outputLock.unlock()
            if hop {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.outputLock.lock(); self.outputNotified.remove(id); self.outputLock.unlock()
                    self.delegate?.store(self, outputFor: s)
                }
            }
        case let .control(.screen(id, state)):
            DispatchQueue.main.async { [weak self] in
                guard let self, let s = self.sessions.first(where: { $0.id == id }), let sum = ScreenSummary(json: state), sum != s.screen else { return }
                s.screen = sum
                self.delegate?.store(self, didUpdate: s)
                self.evaluateAutoAllow()
            }
        case let .control(.exited(id, status)):
            DispatchQueue.main.async { [weak self] in
                guard let self, let s = self.sessions.first(where: { $0.id == id }) else { return }
                s.exited = status
                self.delegate?.store(self, didUpdate: s)
                self.evaluateAutoAllow()
            }
        case let .control(.event(name, payload)):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.eventsSeen += 1
                self.adoptStartedTerminal(name, payload)
                NotificationCenter.default.post(name: Store.eventNotification, object: self, userInfo: ["name": name, "payload": payload])
            }
        default: break
        }
    }

    /// Sessions whose next output frame is the attach snapshot; touched on the reader thread only.
    private var awaitingSnapshot = Set<UInt64>()
    private let outputLock = NSLock()
    private var outputNotified = Set<UInt64>()
    private let sessionsLock = NSLock()
    private func sessionForOutput(_ id: UInt64) -> SessionModel? { sessionsSnapshot.first { $0.id == id } }
    private var sessionsSnapshot: [SessionModel] { sessionsLock.lock(); defer { sessionsLock.unlock() }; return _snapshot }
    private var _snapshot: [SessionModel] = []
    private func publishSnapshot() { sessionsLock.lock(); _snapshot = sessions; sessionsLock.unlock() }

    // MARK: Actions

    func select(_ s: SessionModel?) {
        selected = s
        delegate?.store(self, selectionChanged: s)
    }

    /// Sessions keep the size muyad has until a view shows them; then they take that view's grid.
    func ensureSize(_ s: SessionModel, cols: Int, rows: Int) {
        guard s.exited == nil, s.replica.cols != cols || s.replica.rows != rows else { return }
        resize(s, cols: cols, rows: rows)
    }

    func resize(_ s: SessionModel, cols: Int, rows: Int) {
        s.replica.resize(cols: cols, rows: rows, cellW: cell.w, cellH: cell.h)
        connection?.send(.resize(id: s.id, cols: UInt16(cols), rows: UInt16(rows)))
    }

    func spawn(cwd: String, name: String? = nil) {
        guard let conn = connection else { return }
        do {
            let reply = try conn.request(.spawn(argv: [], cwd: cwd, env: [], cols: UInt16(grid.cols), rows: UInt16(grid.rows)), timeout: 10)
            guard case let .spawned(id, pid) = reply else { return }
            let display = name ?? (cwd == home ? "Shell" : (cwd as NSString).lastPathComponent)
            names["\(id):\(pid)"] = display
            saveNames()
            try adopt(SessionInfo(id: id, pid: pid, cols: UInt16(grid.cols), rows: UInt16(grid.rows), endSeq: 0, exited: nil))
            sessions.last?.name = display
            delegate?.storeDidChangeSessions(self)
            select(sessions.last)
        } catch {
            delegate?.store(self, connectionChanged: connected, message: "New session failed: \(error)")
        }
    }

    // MARK: Daemon events, auto-allow, migration

    /// Posted on the main thread for every `Control::Event` the daemon sends (userInfo: name, payload).
    static let eventNotification = Notification.Name("MuyaDaemonEvent")
    /// How many daemon events arrived so far (a page that polls as a fallback relaxes once events flow).
    private(set) var eventsSeen = 0

    /// Notifications for permission prompts (AC12): the app posts them itself while it is attached.
    lazy var notifier = PromptNotifier(store: self)

    private var autoAllow = AutoAllowTracker()
    private var autoAllowTimer: Timer?
    /// Prompts answered by auto-allow since launch (test hook and diagnostics).
    private(set) var autoAllowed = 0

    /// Looks at every session's permission prompt: one nobody answered for 2 s gets the "Allow" key (the same
    /// thing the Tauri app does). Sleeps until the next prompt is due instead of polling.
    func evaluateAutoAllow() {
        notifier.check()   // a new permission prompt gets one notification (Notifications.swift)
        let enabled = prefs.bool("autoApprove")
        var prompting: [String: (id: UInt64, key: String)] = [:]
        for s in sessions where s.exited == nil {
            if let sc = s.screen, sc.permission, let k = sc.approveKey { prompting["\(s.id)|\(sc.promptKey)"] = (s.id, k) }
        }
        let now = Date()
        for key in autoAllow.tick(prompting: Set(prompting.keys), enabled: enabled, now: now) {
            guard let p = prompting[key] else { continue }
            connection?.sendInput(session: p.id, Data(p.key.utf8))
            autoAllowed += 1
        }
        autoAllowTimer?.invalidate(); autoAllowTimer = nil
        if let due = autoAllow.nextDue(now: now) {
            autoAllowTimer = Timer.scheduledTimer(withTimeInterval: due + 0.02, repeats: false) { [weak self] _ in self?.evaluateAutoAllow() }
        }
    }

    /// Types `text` into a specific session (not only the selected one), then Enter after a short pause as a
    /// separate key press: sent as one chunk, the TUI would take the Enter for part of a paste.
    func submitText(_ text: String, to id: UInt64) {
        guard let s = sessions.first(where: { $0.id == id }), s.exited == nil else { return }
        connection?.sendInput(session: id, Data(text.utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.connection?.sendInput(session: id, Data("\r".utf8)) }
    }

    /// The Inspector's NEEDS APPROVAL card: Allow sends the key the daemon's prompt parser named, Deny sends Esc.
    func answerPrompt(session id: UInt64, approve: Bool) {
        guard let s = sessions.first(where: { $0.id == id }), s.exited == nil else { return }
        if approve {
            guard let k = s.screen?.approveKey else { return }
            connection?.sendInput(session: id, Data(k.utf8))
        } else {
            connection?.sendInput(session: id, Data([0x1b]))
        }
    }

    /// First-launch migration of the Tauri app's UI state (muya_core::migrate). The daemon call may not exist yet:
    /// an old daemon answers "unknown method" and nothing is stored, so it is tried again next launch.
    func runMigration(completion: @escaping @MainActor (MigrationCall) -> Void = { _ in }) {
        call("migrate.run") { [weak self] r in
            let outcome: MigrationCall
            switch r {
            case let .success(v): outcome = .done(String(describing: v))
            case let .failure(e): outcome = MigrationCall.interpret(ok: false, text: describe(e))
            }
            if case .done = outcome { self?.prefs.set("migrationDone", true) }
            completion(outcome)
        }
    }

    /// A call into muyad's core logic (protocol minor 2); `completion` runs on the main thread. Returns the
    /// request id for `cancelCall` (0 when not connected).
    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], completion: @escaping @MainActor (Result<Any, ClientError>) -> Void) -> UInt64 {
        nonisolated(unsafe) let finish = completion
        if mockMode, let v = MockData.call(method, params) {   // dev mock mode: no daemon, canned rows
            nonisolated(unsafe) let value = v
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(.success(value)) } }
            return 0
        }
        guard let conn = connection else {
            let text = ServiceCopy.notConnected(status: service.statusText)
            retryService(minInterval: 3, keepStatus: true)   // a page asking for something is a "try again": start from the top
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(.failure(.notConnected(text))) } }
            return 0
        }
        return conn.call(method, params) { r in
            nonisolated(unsafe) let result = r
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(result) } }
        }
    }

    func cancelCall(_ req: UInt64) { if req != 0 { connection?.cancelCall(req) } }

    /// `muya://terminal-opened` (the MCP `open_terminal`): muyad started a shell itself; adopt it under the name the agent gave it.
    /// The tab joins the list without taking the focus from what the operator is doing (unless nothing is selected).
    func adoptStartedTerminal(_ event: String, _ payload: String) {
        guard event == "muya://terminal-opened", let t = StartedTerminal(payload: payload), !sessions.contains(where: { $0.id == t.id }) else { return }
        names["\(t.id):\(t.pid)"] = t.name
        saveNames()
        do { try adopt(SessionInfo(id: t.id, pid: t.pid, cols: t.cols ?? UInt16(grid.cols), rows: t.rows ?? UInt16(grid.rows), endSeq: 0, exited: nil)) } catch { return }
        sessions.last?.name = t.name
        delegate?.storeDidChangeSessions(self)
        if selected == nil { select(sessions.last) }
    }

    /// Opens a shell in `cwd` and types `command` into it (resume a Claude session).
    func openShell(cwd: String, name: String, typing command: String) {
        spawn(cwd: cwd, name: name)
        guard let s = selected, let conn = connection else { return }
        conn.send(.paste(id: s.id, text: command))
        conn.send(.key(id: s.id, key: "enter", mods: 0, text: nil))
    }

    /// P3: told when the user closes a session (⌘⇧T brings it back).
    var onUserClose: ((SessionModel) -> Void)?

    func close(_ s: SessionModel) {
        onUserClose?(s)
        connection?.send(.close(id: s.id))
        sessions.removeAll { $0 === s }
        publishSnapshot()
        delegate?.storeDidChangeSessions(self)
        if selected === s { select(sessions.last) }
    }

    func rename(_ s: SessionModel, to name: String) {
        s.name = name
        names["\(s.id):\(s.pid)"] = name
        saveNames()
        delegate?.store(self, didUpdate: s)
    }

    func refreshDirectories() {
        for s in sessions where s.exited == nil {
            if let d = SessionModel.currentDirectory(of: s.pid), d != s.cwd { s.cwd = d; delegate?.store(self, didUpdate: s) }
        }
    }

    func applyTheme(_ t: TerminalTheme) {
        theme = t
        for s in sessions { s.replica.apply(theme: t) }
    }

    // MARK: Input (the one path every keystroke takes, real or scripted)

    func sendText(_ text: String) {
        guard let s = selected, s.exited == nil, !text.isEmpty else { return }
        s.replica.scrollToBottom()
        s.replica.clearSelection() // typing replaces the selection, as in Ghostty
        connection?.sendInput(session: s.id, Data(text.utf8))
    }

    func sendKey(_ key: String, mods: UInt16, text: String? = nil) {
        guard let s = selected, s.exited == nil else { return }
        s.replica.scrollToBottom()
        s.replica.clearSelection()
        connection?.send(.key(id: s.id, key: key, mods: mods, text: text))
    }

    /// Both preference files, written now (quit, focus lost, signals).
    func flushPrefs() { prefs.flush(); legacy.flush() }

    func paste(_ text: String, allowEmpty: Bool = false) {
        guard let s = selected, s.exited == nil, allowEmpty || !text.isEmpty else { return }
        s.replica.scrollToBottom()
        s.replica.clearSelection()
        connection?.send(.paste(id: s.id, text: text))
    }

    func sendMouse(session: SessionModel? = nil, col: Int, row: Int, button: String, action: String, mods: UInt16) {
        guard let s = session ?? selected, s.exited == nil else { return }
        connection?.send(.mouse(id: s.id, col: UInt16(max(0, col)), row: UInt16(max(0, row)), button: button, action: action, mods: mods))
    }

    private func sessionKey(_ s: SessionModel) -> String { "\(s.id):\(s.pid)" }

    private func applySavedOrder() {
        guard !order.isEmpty else { return }
        let keys = SplitLogic.applyOrder(sessions.map(sessionKey), saved: order)
        let byKey = Dictionary(sessions.map { (sessionKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        sessions = keys.compactMap { byKey[$0] }
        publishSnapshot()
    }

    /// Drag-to-reorder in the agent list (App.tsx reorderAgents): `s` takes the place of `target`; the order is kept across restarts.
    func moveSession(_ s: SessionModel, to target: SessionModel) {
        let next = SplitLogic.reorder(sessions.map(sessionKey), from: sessionKey(s), to: sessionKey(target))
        let byKey = Dictionary(sessions.map { (sessionKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        sessions = next.compactMap { byKey[$0] }
        order = next
        if let d = try? JSONSerialization.data(withJSONObject: order) { try? SecureFile.write(d, to: orderURL) }
        publishSnapshot()
        delegate?.storeDidChangeSessions(self)
    }

    /// An agent opened this session (open_session): remembered with the name like the tab name, so it survives a restart of the app.
    func markOpened(_ s: SessionModel, by opener: String) {
        s.openedBy = opener
        openers["\(s.id):\(s.pid)"] = opener
        if let d = try? JSONSerialization.data(withJSONObject: openers, options: [.sortedKeys]) { try? SecureFile.write(d, to: openersURL) }
        delegate?.store(self, didUpdate: s)
    }

    private func saveNames() {
        if let d = try? JSONSerialization.data(withJSONObject: names, options: [.sortedKeys]) { try? SecureFile.write(d, to: namesURL) }
    }
}
