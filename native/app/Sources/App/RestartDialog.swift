// AC19: "restart the background service now / later". The dialog, the Store side of the restart (talk to the old
// daemon, wait for launchd to bring the new one, open the sessions again from the resume plan) and the state both
// share (ServiceState).
//
// Later: the app reconnects with the daemon's own protocol version (Incompat.speak). Sessions keep running, untouched.
// Now:   `Upgrade` -> the daemon keeps a resume plan, ends the sessions and exits; launchd starts the new build; the
//        app reconnects, opens each session again in its folder (`claude --resume <id>` where it had a Claude
//        conversation) through the normal spawn path, then tells the daemon the plan is done (`upgrade.resume_done`).

import AppKit

/// Everything the AC19/AC21 screens need to know about the daemon link, kept apart from the Store's session state.
final class ServiceState: @unchecked Sendable {
    /// What the last failed connection meant (nil = connected or never failed).
    var problem: ServiceProblem?
    /// The skew detail of the last refusal, kept so the dialog can be opened again after "Later".
    var lastSkew: Incompat?
    /// A stale background service (another copy's muyad / ptyd) the user chose "Later" for; the menu entry reopens the dialog.
    var lastStale: StaleService?
    var staleDismissed = false
    /// Automatic takeover of a service that is not this copy's (ServiceTakeover); tests may switch it off to see the dialog first.
    var autoTakeover = true
    /// Only a real install (the user's own HOME, a .app bundle; or a test that says what "this copy" is) has services launchd restarts.
    /// For anything else (a dev build, a fake HOME, MUYA_SOCKET pointing at a hand-started muyad) the takeover, the stale-service check
    /// and the socket sweep do nothing: ending that daemon would leave nobody to start it again.
    var managedInstall = false
    /// A takeover was started in this run: a second mismatch goes straight to the dialog instead of looping.
    var takeoverTried = false
    /// The restart in progress is the automatic takeover (no dialog is up; a failure must open it).
    var takeoverRunning = false
    var takeoverStale: StaleService?
    var takeoverFailure: String?
    /// Starts this copy's own services in place of the stale ones (SMAppService unregister + register); nil result = fine, else why not.
    var reregister: () -> String? = { nil }
    /// Duplicate bundles with this app's identifier / a job that cannot spawn (BundleCopies). nil = not applicable (dev build, fake HOME).
    var bundleReport: () -> BundleReport? = { nil }
    /// Re-registers this copy with LaunchServices and drops the others from it; nil = fine, else what failed. The agents are registered again by the caller.
    var fixBundles: () -> String? = { nil }
    var bundleFixTried = false
    /// The user closed the duplicate-bundle dialog (Later / Escape): it does not come back in this launch (the "Muya" status line still says why).
    var bundlesDismissed = false
    /// "Use this copy's service" was pressed: the next successful connect ends the dialog; the deadline says when to give up.
    var fixingBundles = false
    var fixingDeadline = Date.distantPast
    /// Test hook: where the services should come from, instead of the ones inside the app bundle.
    var expectedMuyad: String?, expectedPtyd: String?
    /// This app's release, to compare with what muyad announces (nil = dev build, nothing to compare). Test hook may override.
    var expectedProduct: String? = ServiceIdentity.bundledProduct()
    /// The hello version the app uses instead of its own ("later"); nil = its own.
    var speak: ProtoVersion?
    /// Test hook (debug socket `skew on`): announce this major instead of the real one, as a newer app would.
    /// Cleared by a successful "Restart service", because the restarted daemons are then the new build.
    var simulatedAppMajor: UInt16?
    var restarting = false
    var restartPlan: [LiveSession] = []
    var restartDeadline = Date.distantPast
    var waitsForApproval: () -> Bool = { false }
    var onProblem: ((ServiceProblem?) -> Void)?
    var onCompat: ((Bool) -> Void)?
    var onProgress: ((RestartPhase) -> Void)?
    /// After a restart the services were still another copy's (launchd started the old program again).
    var staleAfterRestart: StaleService?
    var reregisterError: String?
    // Recovery of a service that is not running (ServiceRecovery): counters since the last attempt, what the banner and the pages say.
    var failures = 0, attempts = 0
    var statusText: String?
    var lastRetry = Date.distantPast
    /// launchd lists the muyad job? (nil = cannot tell / not a real install)
    var jobLoaded: () -> Bool? = { nil }
    /// plist names of the agents whose socket answers nothing (the only ones worth registering again)
    var deadAgents: () -> [String] = { [] }
    /// Removes sockets nobody listens on (left behind by a booted-out job).
    var sweepSockets: () -> Void = { }
    /// Registers just these agents again (unregister + register); nil = fine / not applicable, else what macOS said.
    var reregisterAgents: ([String]) -> String? = { _ in nil }
    var phase: RestartPhase = .idle
}

extension Store {
    var problem: ServiceProblem? { service.problem }
    var restarting: Bool { service.restarting }

    /// The version the next hello announces (nil = this build's own).
    var helloAnnounce: (major: UInt16, minor: UInt16)? {
        if let s = service.speak { return (s.major, s.minor) }
        return service.simulatedAppMajor.map { ($0, protoMinor) }
    }

    private func setProblem(_ p: ServiceProblem?) {
        guard p != service.problem else { return }
        service.problem = p
        if case let .versionSkew(info)? = p { service.lastSkew = info }
        if case let .staleService(st)? = p { service.lastStale = st }
        service.onProblem?(p)
    }

    private func progress(_ ph: RestartPhase) { service.phase = ph; service.onProgress?(ph) }

    /// A connect succeeded (the daemon answered `list`): that is the only proof the service runs.
    /// muyad serves without ptyd (AC21), so "connected" alone proves nothing: `upgrade.status` makes it try the link and
    /// says whether it worked. Not linked -> the onboarding screen, polled every 2 s over this same connection (the poll
    /// is also what lets muyad adopt ptyd the moment the user approves it).
    func serviceConnected() {
        service.failures = 0; service.attempts = 0; service.statusText = nil; service.reregisterError = nil
        call("upgrade.status") { [weak self] result in
            guard let self else { return }
            if case let .success(v) = result, let d = v as? [String: Any], (d["ptyd_linked"] as? Bool) == false {
                self.setProblem(.needsApproval)
                self.reconnectTimer?.invalidate()
                self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: ReconnectPolicy.delay(onboarding: true, restarting: false), repeats: false) { [weak self] _ in
                    self?.serviceConnected()
                }
                self.reconnectTimer?.tolerance = 0.5
                return
            }
            self.serviceReady(status: result)
        }
    }

    /// Are the running muyad and muya-ptyd the ones inside this app? (Same protocol does not mean same copy: see ServiceIdentity.)
    /// The daemon pid is the other end of our socket; ptyd is the parent of a live session's shell.
    func staleServices(sessions: [LiveSession]) -> StaleService? {
        let live = sessions.filter { $0.exited == nil }
        let muyadWant = service.expectedMuyad ?? ServiceIdentity.bundled("muyad"), ptydWant = service.expectedPtyd ?? ServiceIdentity.bundled("muya-ptyd")
        var found: StaleService?
        func consider(_ v: ServiceIdentity.Verdict, _ program: String) {
            guard v != .unknown, v != .current else { return }
            if found == nil || ServiceIdentity.worst(found!.verdict, v) != found!.verdict {
                found = StaleService(verdict: v, program: program, sessions: live, appPath: (service.expectedMuyad ?? ServiceIdentity.bundled("muyad")).map(ServiceTakeover.bundlePath(ofProgram:)),
                                     appVersion: service.expectedProduct, daemonVersion: connection.flatMap { ServiceTakeover.productOf(serverBuild: $0.serverBuild) }, takeoverFailure: service.takeoverFailure)
            }
        }
        if let conn = connection {
            var v = conn.peerPID.map { ServiceIdentity.verdict(pid: $0, expected: muyadWant) } ?? .unknown
            // The path cannot decide (unreadable, or it looks right): the release the daemon announces still can.
            if v == .unknown || v == .current {
                let b = ServiceIdentity.buildVerdict(serverBuild: conn.serverBuild, product: service.expectedProduct)
                if b != .unknown && b != .current { v = b }
            }
            consider(v, "muyad")
        }
        if let shell = live.first?.pid, let ptyd = ServiceIdentity.parentPID(of: shell) { consider(ServiceIdentity.verdict(pid: ptyd, expected: ptydWant), "muya-ptyd") }
        return found
    }

    /// The automatic takeover did not work: the dialog with the one-click "Use this copy's service" (and the reason).
    private func showTakeoverDialog(_ st: StaleService) {
        var s = st; s.takeoverFailure = service.takeoverFailure
        service.phase = .idle
        setProblem(nil)
        setProblem(.staleService(s))
        service.onCompat?(true)
    }

    private func serviceReady(status: Result<Any, ClientError>) {
        var sessions: [LiveSession] = []
        if case let .success(v) = status, let d = v as? [String: Any], let arr = d["sessions"] as? [Any] { sessions = arr.compactMap { try? Control.live($0) } }
        if service.fixingBundles {   // "Use this copy's service" worked: the service answers
            service.fixingBundles = false; service.bundleFixTried = false
            NSLog("muya: bundle fix done, the background service answers")
            progress(.finished(resumed: 0))
            setProblem(nil)
            service.onCompat?(false)
            return
        }
        if service.restarting {
            // The restart finished: the services that answer now must be this copy's. If they are not, say so instead of looping.
            service.staleAfterRestart = staleServices(sessions: sessions)
            if service.takeoverRunning {
                service.takeoverRunning = false
                if let st = service.staleAfterRestart { service.takeoverFailure = service.reregisterError ?? "the other copy's service started again"; service.takeoverStale = st; service.staleAfterRestart = nil }
            }
            setProblem(nil)
            service.onCompat?(service.speak != nil)
            finishRestart()
            return
        }
        if service.managedInstall, !service.staleDismissed, let st = staleServices(sessions: sessions) {
            if ServiceTakeover.decide(verdict: st.verdict, takeoverTried: service.takeoverTried, autoEnabled: service.autoTakeover) == .takeover {
                service.takeoverTried = true; service.takeoverRunning = true
                restartService()
                if !service.restarting {   // the restart could not even start (old service too old, or it refused): ask
                    service.takeoverRunning = false
                    var failed = st; failed.takeoverFailure = service.phase.text; service.takeoverFailure = service.phase.text
                    showTakeoverDialog(failed)
                }
                return
            }
            var shown = st
            if service.takeoverTried { shown.takeoverFailure = service.takeoverFailure ?? "the other copy's service is still the one running" }
            setProblem(.staleService(shown))
            service.onCompat?(true)
            return
        }
        setProblem(nil)
        service.onCompat?(service.speak != nil || service.lastStale != nil && service.staleDismissed)
    }

    /// A connect failed. Skew waits for the user's choice; everything else retries (slowly while onboarding).
    func serviceFailed(_ error: Error) {
        if service.restarting {
            if Date() < service.restartDeadline { scheduleReconnect(); return } // launchd is still bringing the daemons back
            service.restarting = false
            progress(.failed("The service did not come back within a minute. Quit Muya and open it again, or check System Settings > General > Login Items."))
        }
        if service.fixingBundles {
            if Date() < service.fixingDeadline { scheduleReconnect(); return }
            service.fixingBundles = false
            progress(.failed("The background service still did not start. Open System Settings › General › Login Items & Extensions and switch Muya off and on, then press Try again."))
        }
        let p = ServiceProblem.classify(error, loginItemWaitsForApproval: service.waitsForApproval())
        // The duplicate-bundle dialog is up: a plain "unreachable" must not replace it (it would flicker on every retry).
        if case .brokenBundles? = service.problem, case .unreachable = p { scheduleReconnect(); return }
        setProblem(p)
        if case .versionSkew = p { return }
        recoverIfNeeded(error: error, problem: p)
        scheduleReconnect()
    }

    /// The socket is dead although nothing says "not approved": launchd may have lost the job (booted out, app moved or replaced).
    /// After a short grace, clear dead sockets and register this copy's agents again; after two tries say precisely what is wrong.
    private func recoverIfNeeded(error: Error, problem: ServiceProblem) {
        var isSocket = false
        if let e = error as? ClientError, case .socket = e { isSocket = true }
        if case .unreachable = problem {} else { return }
        // Only a real install may repair the background service. A dev build, a fake HOME or a hand-started daemon has
        // no launchd job of its own: re-registering agents or bundles from here would touch the INSTALLED Muya's
        // registrations, and the "switch Muya on under Allow in the Background" text would send the user to change the
        // installed app's setting because of a copy that never had a service. Such a build just says it is not connected.
        guard service.managedInstall else {
            let text = ServiceCopy.noServiceHere
            service.statusText = text
            delegate?.store(self, connectionChanged: false, message: text)
            return
        }
        service.failures += 1
        let action = ServiceRecovery.plan(isSocketError: isSocket, approvalPending: false, jobLoaded: service.jobLoaded(), failures: service.failures,
                                          attempts: service.attempts, detail: service.reregisterError)
        // A second bundle with our identifier / a job that cannot spawn: fix at the first failure (startup), never leave "Starting…".
        if (service.failures == 1 && service.attempts == 0) || { if case .restart = action { return true }; if case .giveUp = action { return true }; return false }(),
           !service.fixingBundles, let report = service.bundleReport() {
            switch BundleCopies.decide(report: report, servicesDown: true, fixTried: service.bundleFixTried) {
            case .ok: break
            case .reregister:
                service.bundleFixTried = true
                NSLog("muya: found \(report.copies.count) bundle(s) with this app's identifier (\(report.copies.map(\.path).joined(separator: ", "))), job spawnFailed=\(report.spawnFailed): re-registering this copy")
                if let why = service.fixBundles() { service.reregisterError = why; NSLog("muya: bundle fix failed: \(why)") }
                let dead = service.deadAgents()
                if let why = service.reregisterAgents(dead.isEmpty ? [] : dead) { service.reregisterError = why }
                service.statusText = ServiceCopy.starting
                delegate?.store(self, connectionChanged: false, message: ServiceCopy.starting)
                return
            case .dialog:
                var r = report; r.failure = service.reregisterError ?? "the service did not start from this copy"
                service.statusText = ServiceCopy.bundlesStatus
                if BundleCopies.offer(dismissed: service.bundlesDismissed) == .dialog {
                    NSLog("muya: bundle fix did not hold, asking (\(r.failure ?? ""))")
                    setProblem(.brokenBundles(r))
                }
                delegate?.store(self, connectionChanged: false, message: ServiceCopy.bundlesStatus)
                return
            }
        }
        switch action {
        case .wait: break
        case .restart:
            service.attempts += 1; service.failures = 0
            service.statusText = ServiceCopy.starting
            service.sweepSockets()
            let dead = service.deadAgents()
            service.reregisterError = dead.isEmpty ? nil : service.reregisterAgents(dead)
            if service.waitsForApproval() { setProblem(.needsApproval) }
        case let .giveUp(text):
            service.statusText = text
            setProblem(.unreachable(text))
        }
        delegate?.store(self, connectionChanged: false, message: service.statusText ?? "\(error)")
    }

    /// The dialog's "Use this copy's service" for duplicate bundles: LaunchServices + all agents registered again from this copy
    /// (also when macOS says they are already enabled), then connect. Nothing runs (the services are down), so no session is cut.
    func fixBundlesNow() {
        progress(.restarting)
        service.bundleFixTried = true
        var why = service.fixBundles()
        if why == nil { why = service.reregister() }
        if let why { NSLog("muya: bundle fix failed: \(why)"); progress(.failed("Could not register this copy (\(why)). Quit Muya, move the other copy to the Trash, then sign out of macOS and in again.")); return }
        service.sweepSockets()
        service.fixingBundles = true
        service.fixingDeadline = Date().addingTimeInterval(30)
        service.failures = 0; service.attempts = 0
        connect()
    }

    /// The user (or a page that found no service) asks again: start the recovery from the top and connect now.
    /// `keepStatus`: a page asking is a quiet retry; what the user was told (e.g. the Login Items fix) stays until the new attempt says otherwise.
    func retryService(minInterval: TimeInterval = 0, keepStatus: Bool = false) {
        guard !connected, !service.restarting, !mockMode else { return }
        guard Date().timeIntervalSince(service.lastRetry) >= minInterval else { return }
        service.lastRetry = Date()
        service.failures = 0; service.attempts = 0
        if !keepStatus || service.statusText == nil { service.statusText = ServiceCopy.starting }
        delegate?.store(self, connectionChanged: false, message: service.statusText ?? ServiceCopy.starting)
        connect()
    }

    /// "Later" on the dialog: keep the running daemon, talk to it in the version it knows.
    func chooseLater() {
        if case .staleService? = service.problem {   // keep everything running; the menu entry brings the dialog back
            service.staleDismissed = true
            setProblem(nil)
            service.onCompat?(true)
            return
        }
        guard case let .versionSkew(info)? = service.problem ?? service.lastSkew.map(ServiceProblem.versionSkew) else { return }
        service.speak = Self.compatVersion(info)
        setProblem(nil)
        connect()
    }

    /// The hello that keeps a daemon of another major usable; a daemon too old to say gets major 1 / minor 0.
    static func compatVersion(_ info: Incompat) -> ProtoVersion {
        info.speak.major == 0 ? ProtoVersion(major: 1, minor: 0, build: "") : info.speak
    }

    /// "Restart service": needs a link to the old daemon that is allowed to send `Upgrade` (minor 3).
    func restartService() {
        if !connected {
            if case let .versionSkew(info)? = service.problem { service.speak = Self.compatVersion(info) }
            else if let info = service.lastSkew { service.speak = Self.compatVersion(info) }
            connect()
        }
        guard connected, let conn = connection else { progress(.failed("The background service is not reachable. Try again in a moment.")); return }
        guard conn.serverMinor >= minorUpgrade else {
            progress(.failed("The running background service is too old to be restarted from here. Quit Muya, then sign out and in again, or restart the Mac."))
            return
        }
        progress(.restarting)
        let reply: Control
        do { reply = try conn.request(.upgrade, timeout: 15) } catch {
            progress(.failed("The service did not accept the restart (\(error)). Nothing was changed."))
            return
        }
        guard case let .upgrading(plan, _) = reply else { progress(.failed("The service answered something unexpected. Nothing was changed.")); return }
        service.restartPlan = plan
        service.restarting = true
        service.restartDeadline = Date().addingTimeInterval(ReconnectPolicy.restartTimeout)
        service.speak = nil
        service.simulatedAppMajor = nil // the restarted daemons are the new build
        // launchd starts whatever its job points at: after the daemon left, point the job at THIS copy (no-op without a real bundle / HOME).
        if let why = service.reregister() { service.reregisterError = why }
        service.onCompat?(false)
        dropAllSessions() // the daemon ended them; the plan has what to open again
        scheduleReconnect()
    }

    /// The new daemons answer: open every session of the plan again, then tell the daemon it is done.
    private func finishRestart() {
        call("upgrade.resume_plan") { [weak self] result in
            guard let self else { return }
            var plan = self.service.restartPlan // the answer to `Upgrade`; the daemon's file wins when it has one
            if case let .success(v) = result, let p = ResumeStep.parsePlan(v) { plan = p }
            let steps = ResumeStep.steps(plan, home: self.home) { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
            self.progress(.resuming(done: 0, total: steps.count))
            for (i, step) in steps.enumerated() {
                if let cmd = step.command { self.openShell(cwd: step.cwd, name: step.name, typing: cmd) } else { self.spawn(cwd: step.cwd, name: step.name) }
                self.progress(.resuming(done: i + 1, total: steps.count))
            }
            self.call("upgrade.resume_done") { _ in }
            self.service.restarting = false
            self.service.restartPlan = []
            if let st = self.service.takeoverStale {   // the automatic takeover did not take: sessions are back, now ask
                self.service.takeoverStale = nil
                self.showTakeoverDialog(st)
                return
            }
            if let st = self.service.staleAfterRestart, case let .otherCopy(running) = st.verdict {
                self.progress(.failed("The service came back from the same other copy of Muya (\(KeptSession.abbreviate(running, home: self.home))). Your sessions were opened again, but the old program still runs. Quit Muya, move that old copy out of the way, then sign out of macOS and in again (or run: launchctl bootout gui/$(id -u)/com.staunch.muya.muyad)." + (self.service.reregisterError.map { " Registering this copy said: \($0)." } ?? "")))
                return
            }
            self.service.staleDismissed = false; self.service.lastStale = nil; self.service.staleAfterRestart = nil; self.service.takeoverFailure = nil
            self.progress(.finished(resumed: steps.count))
        }
    }
}

/// The dialog.
final class RestartDialog: ModalOverlay {
    let later = ThemedButton(ServiceCopy.laterButton, style: .ghost)
    let restart = ThemedButton(ServiceCopy.restartButton, style: .primary)
    private let progressLabel = ThemedText.helper("")
    private(set) var phase: RestartPhase = .idle
    /// "Restart service" was pressed: from then on the dialog is closed only by its own Done / Close.
    private(set) var committed = false
    /// What the dialog says (the debug socket and the verify scripts read these).
    private(set) var bodyText = ""
    private var restartLabel = ServiceCopy.restartButton
    private(set) var keptRows: [KeptSession] = []
    var onLater: (() -> Void)?
    var onRestart: (() -> Void)?
    var onDone: (() -> Void)?

    init(info: Incompat, home: String, bodyOverride: String? = nil, title: String = ServiceCopy.restartTitle) {
        super.init(width: 520)
        setAccessibilityLabel(title)
        let kept = KeptSession.rows(info.sessions, home: home)
        keptRows = kept
        bodyText = bodyOverride ?? ServiceCopy.restartBody(daemon: info.daemon, app: info.client, kept: kept.count)
        let body = Self.paragraph(bodyText)
        var rows: [NSView] = [Self.header(icon: .bypassWarning, color: .warning, title: title), body]
        if !kept.isEmpty { rows.append(Self.sessionList(kept)) }
        progressLabel.maximumNumberOfLines = 0; progressLabel.preferredMaxLayoutWidth = 472
        progressLabel.isHidden = true
        rows.append(progressLabel)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rows.append(Kit.hstack([spacer, later, restart], spacing: 10))
        fill(rows)
        later.onClick = { [weak self] in self?.laterTapped() }
        restart.onClick = { [weak self] in self?.restartTapped() }
        later.setAccessibilityLabel(ServiceCopy.laterButton); restart.setAccessibilityLabel(ServiceCopy.restartButton)
        onEscape = { [weak self] in self?.laterTapped() }
        onReturn = { [weak self] in self?.restartTapped() }
    }
    /// A stale background service (another copy's program is running).
    convenience init(stale: StaleService, home: String) {
        self.init(info: Incompat(daemon: ProtoVersion(major: 0, minor: 0, build: ""), client: ProtoVersion(major: protoMajor, minor: protoMinor, build: ""), required: ProtoVersion(major: 0, minor: 0, build: ""), speak: ProtoVersion(major: 0, minor: 0, build: ""), sessions: stale.sessions), home: home, bodyOverride: ServiceCopy.staleBody(stale, kept: stale.sessions.filter { $0.exited == nil }.count, home: home))
        restartLabel = ServiceCopy.staleRestartButton
        restart.title = restartLabel; restart.setAccessibilityLabel(restartLabel)
    }
    /// Duplicate bundles with this app's identifier: every copy listed, one button that fixes it.
    convenience init(bundles: BundleReport, home: String) {
        self.init(info: Incompat(daemon: ProtoVersion(major: 0, minor: 0, build: ""), client: ProtoVersion(major: protoMajor, minor: protoMinor, build: ""), required: ProtoVersion(major: 0, minor: 0, build: ""), speak: ProtoVersion(major: 0, minor: 0, build: ""), sessions: []), home: home, bodyOverride: BundleCopies.dialogBody(bundles, home: home), title: ServiceCopy.bundlesTitle)
        restartLabel = ServiceCopy.staleRestartButton
        restart.title = restartLabel; restart.setAccessibilityLabel(restartLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// At most 6 rows; the rest as "and N more".
    private static func sessionList(_ kept: [KeptSession]) -> NSView {
        let box = ThemedBox(.rows)
        var views: [NSView] = []
        for k in kept.prefix(6) {
            let t = ThemedText.title(k.title)
            let d = ThemedText.helper(k.detail); d.maximumNumberOfLines = 1; d.lineBreakMode = .byTruncatingMiddle
            views.append(Kit.vstack([t, d], spacing: 2))
        }
        if kept.count > 6 { views.append(ThemedText.helper("and \(kept.count - 6) more")) }
        let stack = Kit.vstack(views, spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
        ])
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        box.setAccessibilityLabel("Sessions that will be opened again")
        return box
    }

    private func laterTapped() {
        guard !phase.busy else { return }
        if case .finished = phase { onDone?() } else if case .failed = phase { onDone?() } else { onLater?() }
    }

    private func restartTapped() {
        guard !phase.busy else { return }
        if case .finished = phase { onDone?(); return }
        committed = true
        onRestart?()
    }

    func setPhase(_ p: RestartPhase) {
        phase = p
        progressLabel.stringValue = p.text
        progressLabel.isHidden = p == .idle
        if case .failed = p { progressLabel.textColor = Theme.dynamic(.dangerText) } else { progressLabel.textColor = Theme.dynamic(.textFaint) }
        switch p {
        case .finished: restart.title = "Done"; later.isHidden = true
        case .failed: restart.title = "Try again"; later.title = "Close"; later.isHidden = false
        default: restart.title = restartLabel; later.title = ServiceCopy.laterButton; later.isHidden = p.busy
        }
        restart.alphaValue = p.busy ? 0.5 : 1
        restart.setAccessibilityLabel(restart.title)
        needsLayout = true
    }
}
