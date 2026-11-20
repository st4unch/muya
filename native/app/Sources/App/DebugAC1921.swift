#if MUYA_TEST_HOOKS
// Test hooks of the AC19 restart dialog and the AC21 onboarding screen. Like all debug commands they exist only while
// MUYA_DEBUG_SOCKET is set. The clicks go through the same closures the buttons call; nothing here fakes a result:
//   ac-state                       one line: problem, screens up, phase, compat mode, menu entry
//   ac-sessions                    one line per session: id, pid, folder, hash of the screen text
//   ac-skew on|off                 announce a newer protocol major (a newer app than the running daemon) and reconnect
//   ac-settings stub               count "Open Login Items" clicks instead of opening System Settings
//   ac-click open|later|restart   press a button of the onboarding screen / restart dialog
//   ac-key esc|return              the keys the dialog answers
//   ac-reopen                      the "Restart Background Service…" menu entry
//   ac-dialog                      the dialog's text, session rows and buttons
//   ac-retry / ac-status           what Retry does / the recovery counters, status line and banner
//   fda-state                      Full Disk Access: status, step shown, dismissed pref, button counters
//   fda-set granted|denied|unknown simulate what the probe finds, then re-read
//   fda-show                       show the first-run step regardless of status
//   fda-click open|reveal|notnow   press a button of the step (open/reveal are counted, not performed)
//   ac-window                      window number of the main window (for screencapture)

import AppKit
import CryptoKit

extension DebugServer {
    func runAC1921(_ cmd: String, _ arg: String) -> String? {
        guard cmd.hasPrefix("ac-") || cmd.hasPrefix("fda-") else { return nil }
        return MainActor.assumeIsolated { runAC1921Main(cmd, arg) }
    }

    @MainActor
    private func runAC1921Main(_ cmd: String, _ arg: String) -> String? {
        let c = controller, store = c.store, gate = c.serviceGate
        switch cmd {
        case "ac-state":
            let p: String
            switch store.problem { case nil: p = "none"; case .needsApproval?: p = "approval"; case .versionSkew?: p = "skew"; case let .staleService(st)?: p = "stale(\(st.program) \(st.verdict))"; case let .unreachable(m)?: p = "unreachable(\(m))" }
            let r = gate.restart
            return "connected=\(store.connected) problem=\(p) onboarding=\(gate.onboarding != nil ? "shown" : "hidden") restart=\(r != nil ? "shown" : "hidden") "
                + "phase=\(store.service.phase.text.isEmpty ? "idle" : store.service.phase.text) restarting=\(store.restarting) compat=\(store.service.speak != nil) "
                + "menu=\(gate.hasMenuItem) settingsCalls=\(gate.openSettingsCalls) sessions=\(store.sessions.count)"
        case "ac-sessions":
            return store.sessions.map { s in
                let digest = SHA256.hash(data: Data(s.replica.visibleText().utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                return "\(s.id)\t\(s.pid)\t\(s.cwd)\t\(digest)"
            }.joined(separator: "\n")
        case "ac-skew":
            store.service.simulatedAppMajor = arg == "on" ? 2 : nil
            store.connection?.close() // the daemon's connection drops; the reconnect announces the new major
            return "ok"
        case "ac-settings":
            gate.openSettings = {}
            return "ok"
        case "ac-click":
            switch arg {
            case "open": guard let o = gate.onboarding else { return "error: no onboarding screen" }; o.openButton.onClick?(); return "ok"
            case "later": guard let r = gate.restart else { return "error: no restart dialog" }; r.later.onClick?(); return "ok"
            case "restart", "done": guard let r = gate.restart else { return "error: no restart dialog" }; r.restart.onClick?(); return "ok"
            default: return "error: open|later|restart"
            }
        case "ac-key":
            guard let o = gate.restart ?? gate.onboarding else { return "error: nothing shown" }
            let code: UInt16 = arg == "esc" ? 53 : 36
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { return "error" }
            o.keyDown(with: e)
            return "ok"
        case "ac-reopen":
            gate.reopenRestart(); return "ok"
        case "ac-dialog":
            guard let r = gate.restart else { return "none" }
            return "body=\(r.bodyText) | rows=" + r.keptRows.map { "\($0.title) [\($0.detail)]" }.joined(separator: "; ") + " | buttons=\(r.later.isHidden ? "" : r.later.title)/\(r.restart.title) | progress=\(store.service.phase.text)"
        case "ac-retry": store.retryService(); return "ok"   // what a page's Retry button does
        case "ac-status": return "status=\(store.service.statusText ?? "-") attempts=\(store.service.attempts) failures=\(store.service.failures) banner=\(c.banner.stringValue)"
        case "fda-state":
            let m = FDAModel.shared
            return "status=\(m.status.label) step=\(gate.fdaStep != nil ? "shown" : "hidden") dismissed=\(store.prefs.bool(FullDiskAccess.dismissedKey)) open=\(m.openCalls) reveal=\(m.revealCalls)"
        case "fda-set":
            FDAModel.shared.simulate(arg); FDAModel.shared.openPane = {}; FDAModel.shared.revealHelpers = {}
            return "ok"
        case "fda-show": gate.showFullDiskAccess(); return "ok"
        case "fda-click":
            switch arg {
            case "open": guard let v = gate.fdaStep else { return "error: no step" }; v.openButton.onClick?(); return "ok"
            case "reveal": guard let v = gate.fdaStep else { return "error: no step" }; v.revealButton.onClick?(); return "ok"
            case "notnow": guard let v = gate.fdaStep else { return "error: no step" }; v.notNowButton.onClick?(); return "ok"
            default: return "error: open|reveal|notnow"
            }
        case "ac-window": return "\(c.window.windowNumber)"
        default: return nil
        }
    }
}
#endif
