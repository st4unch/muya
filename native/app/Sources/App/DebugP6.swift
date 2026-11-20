#if MUYA_TEST_HOOKS
// Test-hook commands of the Review changes dialog (P6). Like all debug commands they exist only while
// MUYA_DEBUG_SOCKET is set. `review-key` posts a REAL key event to the sheet window, like the keyboard does.

import AppKit

extension DebugServer {
    func runP6(_ cmd: String, _ arg: String) -> String? {
        let c = controller
        switch cmd {
        case "review-open":
            // review-open <working|branch>: Review changes over the main window (branch: read through muyad).
            if c.inspector.isHidden { c.toggleInspector() }
            if arg == "branch" { c.inspector.reviewBranch(on: c.window) { err in if let err { print("review-open branch: \(err)") } }; return "ok" }
            c.inspector.presentReview(on: c.window); return "ok"
        case "review-key":
            // review-key <[|]>: a keyDown through the sheet window (what the keyboard does).
            guard arg == "[" || arg == "]", let win = c.inspector.reviewWindow else { return "error: no review sheet or unknown key" }
            let code: UInt16 = arg == "[" ? 33 : 30
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, characters: arg, charactersIgnoringModifiers: arg, isARepeat: false, keyCode: code) else { return "error" }
            win.sendEvent(e); return "ok"
        case "review-state":
            guard let p = c.inspector.reviewPanel, c.inspector.reviewWindow != nil else { return "none" }
            return "codes=\(p.model.files.map(\.code).joined()) index=\(p.currentIndex) footer=\(p.footerString) file=\(p.model.current?.path ?? "") diff=\(p.diffString.split(separator: "\n").count) lines"
        case "review-header": return c.inspector.reviewPanel?.headerString ?? "none"
        case "review-close": c.inspector.reviewPanel?.onClose?(); return "ok"
        default: return nil
        }
    }
}
#endif
