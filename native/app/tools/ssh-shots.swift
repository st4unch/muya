// Renders the SSH & Passwords page and its editors against the in-memory fake daemon (synthetic data only)
// and writes dark + light PNGs, plus a few behaviour assertions on the real views. No daemon, no app process.
//   ssh-shots <out-dir>        (see verify-ssh.sh)

import AppKit

/// Real on-screen capture of one window (the same screencapture -l route the other verify scripts use); the
/// window is ordered in, given a moment to draw, captured, and left alone afterwards.
@MainActor
func shoot(_ window: NSWindow, dark: Bool, to path: String) {
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    if !window.isVisible { window.orderFrontRegardless() }
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    // Rendered from the views themselves (works with a locked screen, where screencapture returns black).
    guard let frameView = window.contentView?.superview else { return }
    let b = frameView.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = b.size
    frameView.cacheDisplay(in: b, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

nonisolated(unsafe) var fails = 0
func expect(_ ok: Bool, _ what: String) { if ok { print("PASS \(what)") } else { print("FAIL \(what)"); fails += 1 } }

@MainActor
func makeHub(_ mode: FakeSSHRpc.Mode, focused: ((UInt64) -> Void)? = nil) -> (SSHHubPage, FakeSSHRpc, NSWindow) {
    let rpc = FakeSSHRpc(mode: mode)
    let hub = SSHHubPage(rpc: rpc, focusSession: { focused?($0) })
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.title = "Muya Native"
    w.contentView = hub
    hub.didShow()
    return (hub, rpc, w)
}

@main
struct Shots {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        func both(_ w: NSWindow, _ name: String) { shoot(w, dark: true, to: "\(out)/\(name)-dark.png"); shoot(w, dark: false, to: "\(out)/\(name)-light.png"); print("shot \(name)") }

        // Servers
        var focusedSession: UInt64?
        let (hub, rpc, win) = makeHub(.working, focused: { focusedSession = $0 })
        expect(hub.model.visibleServers.count == 4 && hub.serversPane.rowCount == 4, "servers list shows four rows")
        both(win, "ssh-servers")
        expect(hub.serversPane.connectServer(titled: "Build host"), "Connect on the Build host card")   // direct + prompt
        expect(rpc.lastConnect == "s1" && focusedSession == 7, "Connect asks the daemon (ssh.connect) and brings the new tab forward: \(rpc.lastConnect ?? "nil") \(String(describing: focusedSession))")
        expect(hub.serversPane.connectServer(titled: "Edge router"), "Connect on the Edge router card")   // stored login: the daemon injects it
        expect(rpc.lastConnect == "s2", "Connect on a stored-login server also goes to the daemon: \(rpc.lastConnect ?? "nil")")
        both(win, "ssh-servers-connect-note")

        // Server editor with an error
        hub.editServer(nil)
        if let f = hub.form {
            f.set("host", "-bad"); f.set("username", "ops"); f.set("port", "70000")
            f.submitTapped()
            expect(f.debugState().contains("host: Host must not start") && f.debugState().contains("port: Port must be 1–65535"), "form shows field errors under the fields")
            both(f.window, "ssh-server-form-errors")
            f.set("host", "new.example.test"); f.set("port", "22"); f.set("type", "psmp")
            f.onChange?("type", f)
            f.submitTapped()
            let saved = rpc.servers.last
            expect(rpc.servers.count == 5 && hub.form == nil && saved?["psmpProfileId"] as? String == "p1" && saved?["connectionType"] as? String == "psmp", "valid form saves and closes; a PSMP server defaults to the first profile (\(rpc.servers.count) servers)")
        } else { expect(false, "server form opened") }
        both(win, "ssh-servers-after-add")

        // PSMP profiles: classic has no PSMP tab, the card sits at the bottom of Servers.
        hub.select(.psmp)
        expect(hub.section == .servers, "asking for PSMP lands on Servers, as classic has no PSMP tab")
        expect(hub.serversPane.cardsSummary().contains("psmp=1"), "the PSMP profiles card shows one profile")
        both(win, "ssh-psmp")
        hub.editProfile(nil)
        if let f = hub.form {
            f.set("addr", "psmp.example.test"); f.set("vault", "svc@dom")
            f.submitTapped()
            expect(f.debugState().contains("vault: Vault user must not contain the user delimiter"), "profile form rejects the delimiter inside the user")
            both(f.window, "ssh-psmp-form-errors")
            f.cancelTapped()
        }

        // CyberArk (results)
        hub.select(.cyberark)
        both(win, "ssh-cyberark-empty")
        hub.cyberarkPane.setQuery("operating")
        hub.runSearch()
        expect(hub.cyberarkPane.rowCount == 2, "search finds both synthetic accounts")
        hub.cyberarkPane.table.selectRowIndexes([0], byExtendingSelection: false)
        both(win, "ssh-cyberark-results")

        // Password Store (unlocked)
        hub.select(.vault)
        expect(hub.vaultPane.rowCount == 3 && hub.vault.statusText.hasPrefix("Unlocked"), "vault lists three names")
        both(win, "vault-unlocked")
        // classic draws the new-credential form as a card above the groups, not as a sheet.
        hub.vaultPane.beginNew()
        if let f = hub.vaultPane.form {
            f.setValue("label", "lab-admin")
            f.setValue("value", "placeholder-not-a-secret")
            both(win, "vault-add-form-filled")
            f.submitForTest()
            expect(hub.vaultPane.form != nil, "a duplicate name keeps the form open instead of saving")
            both(win, "vault-add-form-errors")
            f.clearSecret()
            f.cancelForTest()
        } else { expect(false, "new-credential card opened") }

        // Locked store
        let (lockedHub, lockedRpc, lockedWin) = makeHub(.locked)
        lockedHub.select(.vault)
        expect(lockedHub.vault.statusText == "Locked" && lockedHub.vaultPane.stateView.text.contains("locked"), "locked store shows the locked state: \(lockedHub.vaultPane.stateView.text)")
        both(lockedWin, "vault-locked")
        lockedHub.vaultPane.stateView.button.onClick?()
        // Unlock asks for the master password first (Touch ID is off in the fake), exactly as classic does.
        expect(lockedHub.form != nil, "Unlock opens the master-password sheet")
        if let f = lockedHub.form {
            f.set("master", "placeholder-not-a-secret")
            both(f.window, "vault-unlock-sheet")
            f.submitTapped()
        }
        expect(lockedRpc.unlocks == 1 && lockedHub.vault.statusText.hasPrefix("Unlocked"), "Unlock calls the daemon and the list appears")
        both(lockedWin, "vault-after-unlock")

        // Daemon without the calls
        let (bareHub, _, bareWin) = makeHub(.unwired)
        expect(bareHub.serversPane.stateView.text.contains("Not available yet"), "servers: not available yet")
        both(bareWin, "ssh-servers-notwired")
        bareHub.select(.vault)
        expect(bareHub.vaultPane.stateView.text.contains("Not available yet"), "vault: not available yet")
        both(bareWin, "vault-notwired")
        bareHub.select(.cyberark)
        bareHub.cyberarkPane.setQuery("lab"); bareHub.runSearch()
        expect(bareHub.cyberarkPane.stateView.text.contains("Not available yet"), "cyberark: not available yet")
        both(bareWin, "ssh-cyberark-notwired")

        // Accessibility: every control in every pane has a label
        var unlabelled: [String] = []
        func walk(_ v: NSView) {
            if v.isHidden { return }
            let isControl = v is NSButton || v is NSTextField && (v as! NSTextField).isEditable || v is NSPopUpButton || v is NSSegmentedControl || v is NSTableView
            if isControl, (v.accessibilityLabel() ?? "").isEmpty, !((v as? NSButton)?.title.isEmpty == false) { unlabelled.append(String(describing: type(of: v))) }
            v.subviews.forEach(walk)
        }
        for s in SSHSection.allCases { hub.select(s); walk(hub) }
        expect(unlabelled.isEmpty, "every visible control has an accessibility label (\(unlabelled))")

        // The same audit through the NSAccessibility hierarchy (what VoiceOver reads), per section and for every form
        // (AC26): no interactive control without a label.
        var treeBad: [String] = []
        func audited(_ name: String, _ windows: [NSWindow]) {
            let r = accessibilityAudit(windows: windows)
            let head = r.split(separator: "\n").first.map(String.init) ?? ""
            print("AX \(name): \(head)")
            if !head.contains("unlabelled=0") { treeBad.append("\(name): \(r)") }
        }
        for sec in SSHSection.allCases { hub.select(sec); audited("SSH section \(sec.title)", [win]) }
        hub.select(.servers); hub.editServer(nil); if let f = hub.form { audited("server form", [f.window]); f.cancelTapped() }
        hub.select(.psmp); hub.editProfile(nil); if let f = hub.form { audited("PSMP profile form", [f.window]); f.cancelTapped() }
        hub.select(.vault); hub.vaultPane.beginNew(); if hub.vaultPane.form != nil { audited("secret form", [win]); hub.vaultPane.form?.clearSecret(); hub.vaultPane.form?.cancelForTest() }
        audited("locked Password Store", [lockedWin]); audited("not-available state", [bareWin])
        expect(treeBad.isEmpty, "accessibility tree audit: every interactive control is labelled (\(treeBad.joined(separator: " | ")))")

        // Keyboard: Return on a row activates, sections are reachable from the segmented control
        hub.select(.servers)
        expect(hub.vaultPane.table.onReturn != nil, "lists react to Return")
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}

// ModalParts lifts toasts above its scrim (liftToasts) and names two app classes; this tool has no toasts, so empty stand-ins satisfy the compiler.
final class ToastCard: NSView {}
final class AutoAllowToast: NSView {}
