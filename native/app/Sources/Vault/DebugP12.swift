#if MUYA_TEST_HOOKS
// Test-hook commands of the Vault Source panel and the auto-allow toast (P12). Like all debug commands they exist
// only while MUYA_DEBUG_SOCKET is set. `suggest-esc` sends a REAL Esc key event through NSApp, like the keyboard.

import AppKit

extension DebugServer {
    func runP12(_ cmd: String, _ arg: String) -> String? {
        // Debug commands arrive on the main thread already (like runP6 / runFaz4).
        MainActor.assumeIsolated { runP12Main(cmd, arg) }
    }

    @MainActor
    private func runP12Main(_ cmd: String, _ arg: String) -> String? {
        let c = controller
        func vaultState() -> String {
            guard let p = c.settings.vaultPanel else { return "none" }
            return "current=\(p.currentString) banner=\(p.bannerShown) candidates=\(p.candidates.joined(separator: "|")) configured=\(p.source?.configuredPath ?? "-") error=\(p.errorString)"
        }
        switch cmd {
        case "vault-open":
            c.settings.show(); c.settings.showVault()
            return "\(c.settings.window.windowNumber)"
        case "vault-state": return vaultState()
        case "vault-type": c.settings.vaultPanel?.typeCustom(arg); return "ok"
        case "vault-set": c.settings.vaultPanel?.tapSet(); return "ok"
        case "vault-close": c.settings.vaultPanel?.close(); return "ok"
        case "suggest-show":
            guard let s = c.store.selected ?? c.store.sessions.first else { return "error: no session" }
            c.autoAllowSuggest.present(sessionId: s.id); return "ok"
        case "suggest-state":
            let a = c.autoAllowSuggest
            return "shown=\(a.isShown) enabled=\(a.enabledCount) body=\(a.toast?.bodyText ?? "")"
        case "suggest-click":
            if arg == "enable" { c.autoAllowSuggest.toast?.tapEnable() } else { c.autoAllowSuggest.toast?.tapDismiss() }
            return "ok"
        case "suggest-esc":
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { return "error" }
            NSApp.sendEvent(e); return "ok"
        default: return nil
        }
    }
}
#endif
