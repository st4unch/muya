// MuyaNotifier: posts ONE notification through UNUserNotificationCenter, so it carries Muya's own icon, then exits.
// muyad launches it when no Muya window is running (crates/muyad/src/prompt_watch.rs); the app posts its own
// notifications while it runs. Lives in Muya.app/Contents/Helpers, LSUIElement (no Dock icon, no menu).
//
//   MuyaNotifier --title <text> --body <text> [--session <id>]
//
// Exit status: 0 posted · 2 notifications are denied for Muya (the daemon must NOT fall back to something else) ·
// 3 permission not granted yet and not asked now (MUYA_NOTIFIER_NO_PROMPT=1) · 1 anything else went wrong.
// Without arguments the helper was started by the system because the operator clicked a notification: it opens Muya.
// Environment: MUYA_NOTIFIER_LOG=<file> appends one result line (tests); MUYA_NOTIFIER_NO_PROMPT=1 never opens the
// system's permission dialog (tests). Permission is asked the first time something needs a notification, never earlier.

import AppKit
import UserNotifications

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments

func flagValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func log(_ line: String) {
    guard let path = env["MUYA_NOTIFIER_LOG"], let data = (line + "\n").data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: URL(fileURLWithPath: path)) }
}

final class Helper: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if let s = flagValue("--click-session") { // test hook: do what a click on the banner does
            openMuya(session: s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
            return
        }
        guard let title = flagValue("--title"), let body = flagValue("--body") else {
            // Started by a click: the response is delivered right after launch; give it a moment, then leave.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            return
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: self.post(center, title, body)
            case .notDetermined:
                if env["MUYA_NOTIFIER_NO_PROMPT"] == "1" { self.finish("not-asked", title, body, 3); return }
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { self.post(center, title, body) } else { self.finish("denied", title, body, 2) }
                }
            default: self.finish("denied", title, body, 2)
            }
        }
    }

    private func post(_ center: UNUserNotificationCenter, _ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if let s = flagValue("--session") { c.userInfo = ["session": s]; c.threadIdentifier = "muya-session-\(s)" }
        center.add(UNNotificationRequest(identifier: "perm-\(flagValue("--session") ?? "x")", content: c, trigger: nil)) { err in
            self.finish(err == nil ? "delivered" : "error", title, body, err == nil ? 0 : 1)
        }
    }

    private func finish(_ outcome: String, _ title: String, _ body: String, _ code: Int32) {
        log("outcome=\(outcome) session=\(flagValue("--session") ?? "") title=\(title) body=\(body)")
        exit(code)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let session = response.notification.request.content.userInfo["session"] as? String
        openMuya(session: session)
        done()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }

    /// Opens Muya (starting it if needed) and, with a session id, hands it `muya://session/<id>` so the app selects that session.
    /// The app is the one that contains this helper (Contents/Helpers/MuyaNotifier.app); MUYA_NOTIFIER_TARGET_APP overrides it (tests).
    func openMuya(session: String?) {
        let muya = env["MUYA_NOTIFIER_TARGET_APP"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        log("outcome=clicked session=\(session ?? "") target=\(muya.lastPathComponent)")
        guard muya.pathExtension == "app" else { return }
        let config = NSWorkspace.OpenConfiguration()
        if let session, let url = URL(string: "muya://session/\(session)") {
            NSWorkspace.shared.open([url], withApplicationAt: muya, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: muya, configuration: config)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let helper = Helper()
app.delegate = helper
app.run()
