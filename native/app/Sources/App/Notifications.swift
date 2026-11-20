// Permission-prompt notifications from the running app (PRD AC12, native path). Posted through
// UNUserNotificationCenter, so they carry Muya's bundle identity and icon, and a click selects the session that asked.
// While the app is attached muyad stays silent (prompt_watch.rs), so this is the only notice for a prompt.
//
// Permission to post is asked at the first prompt that needs a notice, never at launch. "Do Not Disturb" / Focus is the
// system's: banners use the default interruption level, so a Focus mode holds them back like any other app's.
// Test hooks: under a debug socket the app never opens the system's permission dialog (MUYA_NOTIFY_PROMPT=1 allows it).

import AppKit
import UserNotifications

final class PromptNotifier: NSObject, UNUserNotificationCenterDelegate {
    private weak var store: Store?
    private var tracker = PromptNoticeTracker()
    private let env = ProcessInfo.processInfo.environment

    /// What was handed to the notification center, oldest first (diagnostics and the debug socket).
    private(set) var posted: [(session: UInt64, title: String, body: String, outcome: String)] = []
    private(set) var authorization = "unknown"

    init(store: Store) {
        self.store = store
        super.init()
    }

    private var center: UNUserNotificationCenter? {
        // A bare executable (swift tests, scripts) has no bundle: UNUserNotificationCenter would trap.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        let c = UNUserNotificationCenter.current()
        if c.delegate == nil { c.delegate = self }
        return c
    }

    private var mayAskForPermission: Bool { env["MUYA_DEBUG_SOCKET"] == nil || env["MUYA_NOTIFY_PROMPT"] == "1" }
    private var disabled: Bool { env["MUYA_MOCK"] == "1" }

    /// Called whenever a session's screen state changed (Store.evaluateAutoAllow): a prompt nobody has been told about yet
    /// gets one notification, unless the operator is looking at that session right now.
    func check() {
        guard !disabled, let store else { return }
        var prompting: [UInt64: String] = [:]
        for s in store.sessions where s.exited == nil {
            if let sc = s.screen, sc.permission { prompting[s.id] = sc.promptKey }
        }
        for id in tracker.fresh(prompting: prompting) {
            guard let s = store.sessions.first(where: { $0.id == id }), let key = prompting[id] else { continue }
            let windowVisible = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
            guard PromptNotice.shouldPost(appActive: NSApp.isActive, windowVisible: windowVisible, isSelected: store.selected === s) else { continue }
            let p = InspectorApproval.parse(promptKey: key)
            post(session: id, title: PromptNotice.title, body: PromptNotice.body(tool: p.tool, target: p.target))
        }
    }

    private func post(session: UInt64, title: String, body: String) {
        let index = posted.count
        posted.append((session, title, body, "pending"))
        guard let center else { posted[index].outcome = "no-bundle"; return }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorization = Self.name(settings.authorizationStatus)
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: self.add(index, session, title, body, center)
                case .notDetermined:
                    guard self.mayAskForPermission else { self.posted[index].outcome = "not-asked"; return }
                    // The first prompt that needs a notice is the moment to ask.
                    center.requestAuthorization(options: [.alert]) { granted, _ in
                        DispatchQueue.main.async {
                            self.authorization = granted ? "authorized" : "denied"
                            if granted { self.add(index, session, title, body, center) } else { self.posted[index].outcome = "denied" }
                        }
                    }
                default: self.posted[index].outcome = "denied"
                }
            }
        }
    }

    private func add(_ index: Int, _ session: UInt64, _ title: String, _ body: String, _ center: UNUserNotificationCenter) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = ["session": NSNumber(value: session)]
        c.threadIdentifier = "muya-session-\(session)"
        center.add(UNNotificationRequest(identifier: "perm-\(session)", content: c, trigger: nil)) { [weak self] err in
            DispatchQueue.main.async { self?.posted[index].outcome = err == nil ? "delivered" : "error" }
        }
    }

    private static func name(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    /// A click on a notification (or the debug socket's `notify-click`): bring the window forward and select that session.
    func focus(session id: UInt64) {
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) { w.makeKeyAndOrderFront(nil) }
        if let s = store?.sessions.first(where: { $0.id == id }) { store?.select(s) }
    }

    /// A link from the helper can arrive while the app is still starting and has not listed its sessions yet: retry for 5 s.
    func focusWhenListed(session id: UInt64, tries: Int = 20) {
        if store?.sessions.contains(where: { $0.id == id }) == true { focus(session: id); return }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.focusWhenListed(session: id, tries: tries - 1) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["session"] as? NSNumber)?.uint64Value
        DispatchQueue.main.async { if let id { self.focus(session: id) }; done() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }

    // MARK: Test hooks (debug socket)

    /// "auth=… posted=N" and one line per notice: session, outcome, title, body.
    func debugState() -> String {
        var lines = ["auth=\(authorization) posted=\(posted.count) asks=\(mayAskForPermission)"]
        for p in posted { lines.append("\(p.session)\t\(p.outcome)\t\(p.title)\t\(p.body)") }
        return lines.joined(separator: "\n")
    }

    /// What the system lists as delivered for this app (needs notification permission; empty otherwise). Blocks the
    /// calling (main) thread for at most 3 s: the answer arrives on a private queue.
    func debugDelivered() -> String {
        guard let center else { return "no-bundle" }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var rows: [String] = []
        center.getDeliveredNotifications { list in
            rows = list.map { "\($0.request.identifier)\t\($0.request.content.title)\t\($0.request.content.body)" }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 3) == .timedOut { return "timeout" }
        return "delivered=\(rows.count)" + rows.map { "\n" + $0 }.joined()
    }
}
