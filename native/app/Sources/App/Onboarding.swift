// AC21: the first-launch / "not approved" screen, and the controller (ServiceGate) that decides which service screen
// is up: onboarding (Login Items approval), the restart dialog (AC19, RestartDialog.swift) or none.
//
// Look: a dimmed scrim (black 50 %, like ModalScrim) over the whole window and a ThemedBox(.popover) card with the
// Settings row type (13 pt bold title, 12 pt helper), ThemedButton ghost/primary. Colours come from tokens only.
//
// Honesty: the screen never decides on its own that approval happened. It disappears when muyad really answers a
// request (the connection succeeded), which is the only proof that ptyd runs. SMAppService is asked only to word the
// hint ("the switch is off") and to open System Settings.

import AppKit
import ServiceManagement

/// A full-window scrim with a centered card. Swallows mouse and keys so nothing behind it can be used; Return and Esc
/// call `onReturn` / `onEscape`.
class ModalOverlay: NSView {
    let card = ThemedBox(.popover)
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    private weak var previousResponder: NSResponder?

    init(width: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.35; card.layer?.shadowRadius = 20; card.layer?.shadowOffset = CGSize(width: 0, height: -12)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: width),
            card.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),
            card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
        ])
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: if let onEscape { onEscape() } else { NSSound.beep() }
        case 36, 76: if let onReturn { onReturn() } else { NSSound.beep() }
        default: NSSound.beep()
        }
    }

    /// Fills `host` and takes the keyboard.
    func present(in host: NSView) {
        guard superview == nil else { return }
        previousResponder = host.window?.firstResponder
        host.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor), trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor), bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.window?.makeFirstResponder(self)
    }

    func dismiss() {
        let window = self.window, back = previousResponder
        removeFromSuperview()
        if let back, back !== self { window?.makeFirstResponder(back) }
    }

    /// Dialog header: icon + 16 pt semibold title.
    static func header(icon: ThemeIcon, color: Theme.Token, title: String) -> NSView {
        let i = ThemeIconView(icon: icon, color: Theme.dynamic(color), size: 20)
        let t = NSTextField(labelWithString: title)
        t.font = ThemeFont.sans(16, .semibold); t.textColor = Theme.dynamic(.text)
        t.maximumNumberOfLines = 2; t.lineBreakMode = .byWordWrapping
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let h = Kit.hstack([i, t], spacing: 10)
        h.setAccessibilityElement(false)
        return h
    }

    /// Lays `rows` out top to bottom inside the card with 24 pt padding.
    func fill(_ rows: [NSView]) {
        let stack = Kit.vstack(rows, spacing: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])
        for r in rows where r is NSTextField || r is NSStackView || r is ThemedBox { r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    static func paragraph(_ s: String, strong: Bool = false) -> NSTextField {
        let f = strong ? ThemedText.title(s) : ThemedText.helper(s)
        f.maximumNumberOfLines = 0; f.lineBreakMode = .byWordWrapping
        f.preferredMaxLayoutWidth = 432
        if !strong { f.font = ThemeFont.sans(13); f.textColor = Theme.dynamic(.textMuted) }
        return f
    }
}

/// The AC21 card.
final class OnboardingView: ModalOverlay {
    private let dot = ThemedPill(ServiceCopy.waiting, fg: Theme.dynamic(.warningText), bg: Theme.dynamic(.warningBg), border: Theme.dynamic(.warningBorder), dot: Theme.dynamic(.warning))
    let openButton = ThemedButton(ServiceCopy.onboardingButton, style: .primary)
    var onOpenSettings: (() -> Void)?

    init() {
        super.init(width: 480)
        setAccessibilityLabel(ServiceCopy.onboardingTitle)
        openButton.onClick = { [weak self] in self?.onOpenSettings?() }
        openButton.setAccessibilityLabel(ServiceCopy.onboardingButton)
        let steps = ThemedBox(.rows)
        let stepsText = OnboardingView.paragraph(ServiceCopy.onboardingSteps)
        stepsText.translatesAutoresizingMaskIntoConstraints = false
        steps.addSubview(stepsText)
        NSLayoutConstraint.activate([
            stepsText.leadingAnchor.constraint(equalTo: steps.leadingAnchor, constant: 14), stepsText.trailingAnchor.constraint(equalTo: steps.trailingAnchor, constant: -14),
            stepsText.topAnchor.constraint(equalTo: steps.topAnchor, constant: 12), stepsText.bottomAnchor.constraint(equalTo: steps.bottomAnchor, constant: -12),
        ])
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = Kit.hstack([dot, spacer, openButton], spacing: 12)
        fill([
            Self.header(icon: .settingsRail, color: .accent, title: ServiceCopy.onboardingTitle),
            Self.paragraph(ServiceCopy.onboardingWhat),
            Self.paragraph(ServiceCopy.onboardingWhy),
            steps,
            footer,
        ])
        onReturn = { [weak self] in self?.onOpenSettings?() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "Waiting for approval…" while polling; `approved` for the moment between the answer and the screen going away.
    func setWaiting(_ waiting: Bool) {
        dot.text = waiting ? ServiceCopy.waiting : ServiceCopy.approved
        let ok = !waiting
        dot.fg = Theme.dynamic(ok ? .successText : .warningText); dot.bg = Theme.dynamic(ok ? .successBg : .warningBg)
        dot.border = Theme.dynamic(ok ? .successCardBorder : .warningBorder); dot.dot = Theme.dynamic(ok ? .success : .warning)
    }
}

/// What the system says about the two background services (only meaningful in a real, installed app bundle).
enum ServiceApproval {
    static let plists = ["com.staunch.muya.muyad.plist", "com.staunch.muya.ptyd.plist"]

    /// True when the bundle carries the services and the system lists one of them as waiting for approval. Never true
    /// for a dev build or a fake HOME: nothing is registered there, so the answer is a plain "no".
    static func waitsForApproval(home: String) -> Bool {
        guard LoginItem.isRealHome(home) else { return false }
        let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents")
        return plists.contains { name in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
                && SMAppService.agent(plistName: name).status == .requiresApproval
        }
    }

    /// What registering the bundled agents said last (nil = fine or not applicable). Shown instead of the generic banner.
    nonisolated(unsafe) static var registerError: String?
    /// A managed hand-over is waited for once; a second pass never waits again.
    nonisolated(unsafe) static var handoverWaited = false

    /// Registers every bundled agent the system does not know yet. Without this nothing ever starts muyad / ptyd on a
    /// plain double-click: `status` stays `notRegistered`, no LaunchAgent exists and the app retries forever. A fresh
    /// registration comes back as `requiresApproval` (the user flips the switch in Login Items - the onboarding card
    /// says so); an already approved agent stays untouched. No-op for a dev build or a fake HOME.
    @discardableResult
    static func ensureRegistered(home: String) -> String? {
        registerError = nil
        guard LoginItem.isRealHome(home) else { return nil }
        // Jobs of another bundle id (the `.native` beta app, now in the Trash) hold the same labels: registering over them
        // fails or is booted out by their hand-over. After a managed hand-over wait for them to go; otherwise leave it to the
        // stale-service dialog (which asks before it ends live sessions) instead of killing anything silently.
        let foreign = V5Startup.foreignServices()
        switch LegacyJobs.plan(foreign: foreign, switchLaunch: LaunchHandshake.isSwitchLaunch(Array(CommandLine.arguments.dropFirst())) && !handoverWaited) {
        case .leaveToRestartDialog: return nil
        case .waitThenRegister:
            handoverWaited = true
            DispatchQueue.global().async {
                _ = V5Startup.waitUntilGone(foreign, timeout: 30)
                DispatchQueue.main.async { ServiceApproval.ensureRegistered(home: home) }
            }
            return nil
        case .nothing: break
        }
        let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents")
        var problems: [String] = []
        for name in plists where FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            let svc = SMAppService.agent(plistName: name)
            guard svc.status == .notRegistered || svc.status == .notFound else { continue }
            do { try svc.register() } catch {
                // "Operation not permitted" while the item waits for approval is not a failure: re-read the status.
                if svc.status != .requiresApproval && svc.status != .enabled { problems.append("\(name): \(error.localizedDescription)") }
            }
        }
        registerError = problems.isEmpty ? nil : "Could not register the background service (" + problems.joined(separator: "; ") + ")"
        return registerError
    }

    /// Points launchd's jobs at THIS bundle: unregister then register every bundled agent (what a moved or replaced app needs; the old job keeps
    /// its old program path otherwise). Meant to run just after the service asked to be restarted, so no live session is cut. nil = done / not
    /// applicable (dev build, fake HOME); otherwise what macOS said.
    static func reregister(home: String, only: [String]? = nil) -> String? {
        guard LoginItem.isRealHome(home) else { return nil }
        // The user already agreed to restart (RestartDialog says live sessions end): jobs of another bundle id go first.
        for label in V5Startup.foreignServices() { V5Startup.bootout(label) }
        let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents")
        var problems: [String] = []
        for name in plists where (only?.contains(name) ?? true) && FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            let svc = SMAppService.agent(plistName: name)
            do { try svc.unregister() } catch { problems.append("\(name) unregister: \(error.localizedDescription)") }
            do { try svc.register() } catch { if svc.status != .requiresApproval && svc.status != .enabled { problems.append("\(name) register: \(error.localizedDescription)") } }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    static let bundleLabel = "com.staunch.muya.muyad"

    /// The copies of this app and the job state (nil = a dev build or a fake HOME: nothing registered there).
    static func bundleReport(home: String) -> BundleReport? {
        guard LoginItem.isRealHome(home), let id = Bundle.main.bundleIdentifier, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return BundleCopies.report(bundleID: id, selfPath: Bundle.main.bundleURL.path, label: bundleLabel)
    }

    /// LaunchServices: this copy in, the others out (files untouched). The caller registers the agents again afterwards.
    static func fixBundles(home: String) -> String? {
        guard let r = bundleReport(home: home) else { return nil }
        let others = r.copies.filter { !$0.isSelf }.map(\.path)
        NSLog("muya: lsregister: this copy \(Bundle.main.bundleURL.path), dropping \(others)")
        return BundleCopies.registerSelfOnly(selfPath: Bundle.main.bundleURL.path, others: others)
    }

    /// Does launchd list the muyad job right now (`launchctl print` exits 0)? nil = not a real install, or launchctl cannot be run.
    static func muyadJobLoaded(home: String) -> Bool? {
        guard LoginItem.isRealHome(home) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/com.staunch.muya.muyad"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        return p.terminationStatus == 0
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Decides which service screen is up. Lives as long as the main window; the Store tells it what it saw.
@MainActor
final class ServiceGate {
    private let store: Store
    private unowned let host: NSWindow
    private(set) var onboarding: OnboardingView?
    private(set) var restart: RestartDialog?
    /// The optional Full Disk Access step (FullDiskAccessUI.swift), offered once the background service runs.
    private(set) var fdaStep: FDAStepView?
    /// Called instead of opening System Settings (tests and the debug socket count the calls).
    var openSettings: () -> Void = { ServiceApproval.openSystemSettings() }
    private(set) var openSettingsCalls = 0
    private var menuItem: NSMenuItem?

    init(store: Store, window: NSWindow) {
        self.store = store; host = window
        let home = store.home
        store.service.waitsForApproval = { ServiceApproval.waitsForApproval(home: home) }
        store.service.reregister = { ServiceApproval.reregister(home: home) }
        // Recovery of a service that is not running although Login Items says it is on (see ServiceRecovery).
        let muyadSock = store.socketPath, ptydSock = (store.socketPath as NSString).deletingLastPathComponent + "/ptyd.sock"
        store.service.jobLoaded = { ServiceApproval.muyadJobLoaded(home: home) }
        store.service.managedInstall = ServiceTakeover.isManagedInstall(realHome: LoginItem.isRealHome(home), appBundle: Bundle.main.bundleURL.pathExtension == "app", testSaysSo: false)
        store.service.sweepSockets = { [weak store] in guard store?.service.managedInstall == true else { return }; StaleSocket.sweep(muyadSock); StaleSocket.sweep(ptydSock) }
        store.service.deadAgents = { ServiceRecovery.deadAgents(muyadSocket: muyadSock, ptydSocket: ptydSock) }
        store.service.reregisterAgents = { ServiceApproval.reregister(home: home, only: $0) }
        store.service.bundleReport = { ServiceApproval.bundleReport(home: home) }
        store.service.fixBundles = { ServiceApproval.fixBundles(home: home) }
        #if MUYA_TEST_HOOKS
        // Dev stacks have no bundle and no launchd: the tests say which programs count as "this copy's" and what "register this copy" does.
        let env = ProcessInfo.processInfo.environment
        store.service.expectedMuyad = env["MUYA_TEST_EXPECT_MUYAD"]; store.service.expectedPtyd = env["MUYA_TEST_EXPECT_PTYD"]
        if env["MUYA_TEST_EXPECT_MUYAD"] != nil { store.service.managedInstall = true }   // the test says what "this copy" is
        if env["MUYA_TEST_AUTOTAKEOVER"] == "0" { store.service.autoTakeover = false }
        // Two bundles with the same identifier, without LaunchServices: MUYA_TEST_BUNDLE_COPIES = "self:other:..." (paths), MUYA_TEST_BUNDLE_FLAG = a file whose
        // existence means "the job is in spawn failed"; the fix removes it (MUYA_TEST_BUNDLE_FIXFAIL = a file; while it exists the fix does nothing, as when macOS keeps the wrong copy).
        if let list = env["MUYA_TEST_BUNDLE_COPIES"], let flag = env["MUYA_TEST_BUNDLE_FLAG"] {
            let paths = list.split(separator: ":").map(String.init)
            store.service.bundleReport = {
                let failed = FileManager.default.fileExists(atPath: flag)
                return BundleReport(copies: paths.enumerated().map { BundleCopy(path: $1, version: BundleCopies.version(ofBundle: $1), isSelf: $0 == 0, resolved: failed ? $0 == 1 : $0 == 0) }, spawnFailed: failed)
            }
            store.service.fixBundles = { if !(env["MUYA_TEST_BUNDLE_FIXFAIL"].map { FileManager.default.fileExists(atPath: $0) } ?? false) { try? FileManager.default.removeItem(atPath: flag) }; return nil }
        }
        if let v = env["MUYA_TEST_EXPECT_PRODUCT"] { store.service.expectedProduct = v.isEmpty ? nil : v }
        // Dev stacks have no launchd: MUYA_TEST_JOBLOADED = "yes" / "no" says what `launchctl print` would, MUYA_TEST_REREGISTER starts the agents.
        if let j = env["MUYA_TEST_JOBLOADED"] { store.service.jobLoaded = { j == "yes" } }
        if let cmd = env["MUYA_TEST_REREGISTER"] {
            let run: ([String]) -> String? = { agents in
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
                var e = ProcessInfo.processInfo.environment; e["MUYA_TEST_AGENTS"] = agents.joined(separator: " "); p.environment = e
                do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 ? nil : "exit \(p.terminationStatus)" } catch { return "\(error)" }
            }
            store.service.reregister = { run([]) }
            store.service.reregisterAgents = { run($0) }
        }
        #endif
        store.service.onProblem = { [weak self] p in MainActor.assumeIsolated { self?.problemChanged(p) } }
        NotificationCenter.default.addObserver(forName: FDAModel.changedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fdaStep?.setStatus(FDAModel.shared.status) }
        }
        // First run: once the window is up and nothing else asks for attention, offer the optional step.
        DispatchQueue.main.async { [weak self] in self?.offerFullDiskAccessIfNeeded() }
        store.service.onCompat = { [weak self] on in MainActor.assumeIsolated { self?.compatChanged(on) } }
        store.service.onProgress = { [weak self] ph in MainActor.assumeIsolated { self?.restart?.setPhase(ph) } }
    }

    private func problemChanged(_ p: ServiceProblem?) {
        switch p {
        case .needsApproval?: showOnboarding(); hideRestart()
        case let .versionSkew(info)?: hideOnboarding(); showRestart(info)
        case let .brokenBundles(r)?: hideOnboarding(); if let d = restart, !d.committed { hideRestart() }; showRestart(bundles: r)
        case let .staleService(st)?: hideOnboarding(); if let d = restart, !d.committed { hideRestart() }; showRestart(stale: st)   // sessions may have changed since the dialog came up
        default: hideOnboarding(); if let d = restart, !d.committed { hideRestart() } // once "Restart service" was pressed the dialog stays until Done
        }
        if p == nil { offerFullDiskAccessIfNeeded() }
    }

    // MARK: Full Disk Access step (optional, once)

    /// Real installs only (a dev stack with a fake HOME never asks; MUYA_TEST_FDA lets the tests force it).
    private var realInstall: Bool {
        #if MUYA_TEST_HOOKS
        if ProcessInfo.processInfo.environment["MUYA_TEST_FDA"] != nil { return true }
        #endif
        return LoginItem.isRealHome(store.home)
    }

    func offerFullDiskAccessIfNeeded() {
        guard fdaStep == nil, store.problem == nil else { return }
        let model = FDAModel.shared
        let offer = FullDiskAccess.shouldOffer(status: model.refresh(), dismissed: store.prefs.bool(FullDiskAccess.dismissedKey),
                                               otherScreenUp: onboarding != nil || restart != nil, realInstall: realInstall)
        if offer { showFullDiskAccess() }
    }

    func showFullDiskAccess() {
        guard fdaStep == nil, let content = host.contentView else { return }
        let v = FDAStepView()
        v.onOpen = { FDAModel.shared.open() }
        v.onReveal = { FDAModel.shared.reveal() }
        v.onNotNow = { [weak self] in self?.dismissFullDiskAccess() }
        v.present(in: content)
        fdaStep = v
    }

    /// "Not now" / Done / Esc: remembered, so the step never comes back on its own. Settings keeps the row.
    func dismissFullDiskAccess() {
        store.prefs.set(FullDiskAccess.dismissedKey, true)
        guard let v = fdaStep else { return }
        v.dismiss(); fdaStep = nil
    }

    // MARK: Onboarding

    func showOnboarding() {
        guard onboarding == nil, let content = host.contentView else { return }
        let v = OnboardingView()
        v.onOpenSettings = { [weak self] in self?.openSettingsCalls += 1; self?.openSettings() }
        v.present(in: content)
        onboarding = v
    }

    func hideOnboarding() {
        guard let v = onboarding else { return }
        v.dismiss(); onboarding = nil
    }

    // MARK: Restart dialog

    func showRestart(_ info: Incompat) {
        guard restart == nil, let content = host.contentView else { return }
        let d = RestartDialog(info: info, home: store.home)
        d.onLater = { [weak self] in self?.chooseLater() }
        d.onRestart = { [weak self] in self?.store.restartService() }
        d.onDone = { [weak self] in self?.hideRestart() }
        d.present(in: content)
        restart = d
    }

    func showRestart(bundles: BundleReport) {
        guard restart == nil, let content = host.contentView else { return }
        let d = RestartDialog(bundles: bundles, home: store.home)
        d.onLater = { [weak self] in self?.store.service.bundlesDismissed = true; self?.hideRestart() }   // Later / Escape: a way out, and it stays closed this launch
        d.onRestart = { [weak self] in self?.store.fixBundlesNow() }
        d.onDone = { [weak self] in self?.hideRestart() }
        d.present(in: content)
        restart = d
    }

    func showRestart(stale: StaleService) {
        guard restart == nil, let content = host.contentView else { return }
        let d = RestartDialog(stale: stale, home: store.home)
        d.onLater = { [weak self] in self?.chooseLater() }
        d.onRestart = { [weak self] in self?.store.restartService() }
        d.onDone = { [weak self] in self?.hideRestart() }
        d.present(in: content)
        restart = d
    }

    /// The dialog again, from the menu item, when the user chose "Later" earlier.
    @objc func reopenRestart() {
        if let st = store.service.lastStale, store.service.staleDismissed { showRestart(stale: st); return }
        guard let info = store.service.lastSkew else { return }
        showRestart(info)
    }

    func hideRestart() {
        guard let d = restart else { return }
        d.dismiss(); restart = nil
    }

    private func chooseLater() {
        hideRestart()
        if case .staleService? = store.service.problem { store.chooseLater(); return }
        if store.service.lastStale != nil, store.service.problem == nil, store.service.staleDismissed { return }
        store.chooseLater()
    }

    // MARK: Menu entry (only while the app talks to an older service)

    private func compatChanged(_ on: Bool) {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        if on, menuItem == nil {
            let item = NSMenuItem(title: "Restart Background Service…", action: #selector(reopenRestart), keyEquivalent: "")
            item.target = self
            appMenu.insertItem(item, at: min(1, appMenu.items.count))
            menuItem = item
        } else if !on, let item = menuItem {
            appMenu.removeItem(item); menuItem = nil
        }
    }

    var hasMenuItem: Bool { menuItem != nil }
}
