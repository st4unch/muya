// Settings > Updates (docs/prd-muya-v5-replace.md): Muya's own update and "Return to Muya Classic". Rows are
// built with the ModalParts helpers like every other Settings group. The work is muyad's (muya-switchover); this
// only asks, shows progress from `muya://switchover` and quits once the other app is up. Also the launch handshake
// (`switchover_ack_launch`) and the one-time Touch ID notice after a switch.

import AppKit

final class BetaSection: NSObject {
    unowned let store: Store
    private let host: () -> NSWindow
    private let status = ThemedText.helper("")
    private let switchBack = ThemedButton("Return…")
    private let check = ThemedButton(UpdateStatusText.checkTitle)
    private let update = ThemedButton(UpdateStatusText.installTitle(legacy: false), style: .primary)
    private var installed = ""
    /// "release" (Muya 5), "legacy" (the `.native` beta / bridge app: its update is a move to Muya 5) or "dev".
    private var kind = "release"
    /// The `.native` beta / bridge app (known from its own bundle id): its update is a move to Muya 5.
    private let legacy = Bundle.main.bundleIdentifier?.hasSuffix(".native") == true
    private var available: String?
    private var none = false
    private var upToDate = false
    private var busy = false { didSet { refresh() } }
    /// This process asked for the running switch/update. A freshly launched app is also connected to the (old) daemon
    /// and sees the same events, but it is the one that stays.
    private var initiatedHere = false
    private var progress: String? { didSet { refresh() } }

    init(store: Store, host: @escaping () -> NSWindow) {
        self.store = store; self.host = host
        super.init()
        switchBack.setAccessibilityLabel(ReturnWording.rowTitle)
        switchBack.onClick = { [weak self] in MainActor.assumeIsolated { self?.confirmSwitchBack() } }
        check.setAccessibilityLabel("Check for an update")
        check.onClick = { [weak self] in MainActor.assumeIsolated { self?.checkNow() } }
        update.setAccessibilityLabel("Install the update now")
        update.onClick = { [weak self] in MainActor.assumeIsolated { self?.installNow() } }
        status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NotificationCenter.default.addObserver(self, selector: #selector(daemonEvent(_:)), name: Store.eventNotification, object: store)
        refresh()
    }

    /// The group label and its rows box, for SettingsController.build().
    func blocks() -> [NSView] {
        let switchRow = ModalLayout.settingRow(title: ReturnWording.rowTitle, helper: ReturnWording.rowHelper, control: switchBack)
        let buttons = Kit.hstack([check, update], spacing: 8)
        let updateRow = ModalLayout.settingRow(title: legacy ? ReturnWording.moveTitle : "Updates", helper: legacy ? ReturnWording.moveHelper : "Checks by itself; nothing installs without you.", control: buttons)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let versionRow = Kit.hstack([ThemedText.title(AppInfo.name), spacer, status], spacing: 16)
        status.alignment = .right
        return [ThemedText.label("Updates"), ModalLayout.rowsBox([switchRow, updateRow, versionRow])]
    }

    /// Reads the installed version and any update the background poll already found.
    func reload() {
        store.call("update_status", ["appPath": Bundle.main.bundlePath]) { [weak self] r in
            guard let self, case let .success(v) = r, let o = v as? [String: Any] else { return }
            self.installed = (o["installed"] as? String) ?? ""
            self.kind = (o["kind"] as? String) ?? "release"
            self.available = (o["pending"] as? [String: Any])?["version"] as? String
            UpdateCenter.set(self.available)
            self.refresh()
        }
    }

    private func refresh() {
        update.isHidden = available == nil
        update.title = UpdateStatusText.installTitle(legacy: legacy)
        update.isEnabled = !busy
        check.isEnabled = !busy
        switchBack.isEnabled = !busy
        status.stringValue = progress ?? UpdateStatusText.line(installed: installed, available: available, upToDate: upToDate, none: none)
    }

    private func checkNow() { check(then: nil) }

    /// App menu "Check for Updates…": the same check, answered with a toast (Settings need not be open).
    func checkFromMenu() {
        check { [weak self] err in
            guard let self else { return }
            let t = UpdateStatusText.toast(name: AppInfo.name, installed: self.installed, available: self.available, error: err)
            Toasts.center?.show(title: t.0, message: t.1, seconds: 8)
        }
    }

    private func check(then done: ((String?) -> Void)?) {
        busy = true; progress = "Checking for updates…"
        store.call("update_check", ["appPath": Bundle.main.bundlePath]) { [weak self] r in
            guard let self else { return }
            self.busy = false; self.progress = nil
            switch r {
            case let .success(v):
                let o = v as? [String: Any] ?? [:]
                self.installed = (o["installed"] as? String) ?? self.installed
                self.none = (o["none"] as? Bool) ?? false
                self.available = (o["available"] as? Bool) == true ? o["version"] as? String : nil
                self.upToDate = self.available == nil
                UpdateCenter.set(self.available)
                self.refresh(); done?(nil)
            case let .failure(e): self.progress = describe(e); done?(describe(e))
            }
        }
    }

    func installNow() {
        // The move to Muya 5 replaces the background service, so running sessions end: ask first, with the numbers.
        guard legacy else { startInstall(); return }
        busy = true; progress = "Checking running sessions…"
        store.call("return_classic_preflight") { [weak self] r in
            guard let self else { return }
            self.busy = false; self.progress = nil
            let o = (try? r.get()) as? [String: Any] ?? [:]
            let live = (o["live"] as? Int) ?? 0, agents = (o["agents"] as? Int) ?? 0
            Dialogs.shared.confirm(over: self.host(), title: ReturnWording.moveConfirmTitle, message: ReturnWording.moveConfirmMessage(live: live, agents: agents),
                                   confirmTitle: live > 0 ? "Move and close \(live)" : "Move to Muya 5", danger: live > 0) { [weak self] in
                MainActor.assumeIsolated { self?.startInstall() }
            }
        }
    }

    private func startInstall() {
        busy = true; progress = "Starting…"; initiatedHere = true
        store.call("update_install", ["appPath": Bundle.main.bundlePath]) { [weak self] r in
            if case let .failure(e) = r { self?.busy = false; self?.progress = describe(e) }
        }
    }

    /// Also the target of the app menu's "Return to Muya Classic…".
    func confirmSwitchBack() {
        busy = true; progress = "Checking running sessions…"
        store.call("return_classic_preflight") { [weak self] r in
            guard let self else { return }
            self.busy = false; self.progress = nil
            let o = (try? r.get()) as? [String: Any] ?? [:]
            let live = (o["live"] as? Int) ?? 0, agents = (o["agents"] as? Int) ?? 0
            Dialogs.shared.confirm(over: self.host(), title: ReturnWording.confirmTitle(), message: BetaWording.switchBackMessage(live: live, agents: agents),
                                   confirmTitle: live > 0 ? "Return and close \(live)" : "Return to Muya Classic", danger: live > 0) { [weak self] in
                MainActor.assumeIsolated { self?.startSwitchBack() }
            }
        }
    }

    private func startSwitchBack() {
        busy = true; progress = "Starting…"; initiatedHere = true
        store.call("return_classic_start", ["appPath": Bundle.main.bundlePath]) { [weak self] r in
            if case let .failure(e) = r { self?.busy = false; self?.progress = describe(e); self?.initiatedHere = false }
        }
    }

    @objc private func daemonEvent(_ n: Notification) {
        guard let name = n.userInfo?["name"] as? String, let payload = n.userInfo?["payload"] as? String else { return }
        switch name {
        case "muya://switchover":
            guard let e = SwitchoverEvent(payload: payload) else { return }
            progress = e.text
            if e.isError { busy = false; initiatedHere = false; return }
            busy = true
            // The other app is up (muyad waited for its handshake): this one steps aside.
            if e.stepsAside(initiatedHere: initiatedHere) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) } }
        case "muya://update-available":
            if let v = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any], let ver = v["version"] as? String {
                available = ver; UpdateCenter.set(ver); refresh()
                Toasts.center?.show(title: "\(AppInfo.name) \(ver) is available", message: "Open Settings > Updates to install it.", seconds: 10)
            }
        default: break
        }
    }

    /// Once per launch, after muyad is reachable: answers classic's 30 s handshake after a switch, and shows the
    /// one-time Touch ID notice when classic had it on and Native cannot read that Keychain item.
    func acknowledgeLaunch() {
        store.call("switchover_ack_launch", ["args": Array(CommandLine.arguments.dropFirst())]) { r in
            guard case let .success(v) = r, let o = v as? [String: Any], (o["touchIdNeeded"] as? Bool) == true else { return }
            Toasts.center?.show(title: BetaWording.touchIdTitle, message: BetaWording.touchIdMessage, seconds: 30)
        }
    }
}
