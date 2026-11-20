// The permission-mode menu behind the composer's "Mode: … ▾" chip (src/App.tsx openModeMenu / setModeTo, src/redesign/Composer.tsx).

import AppKit

extension MainController {
    func modeMenu(_ anchor: NSView) {
        guard let s = store.selected, s.exited == nil else { return }
        let current = s.screen?.mode ?? "default"
        let m = NSMenu(title: "Permission mode")
        let head = NSMenuItem(title: "PERMISSION MODE", action: nil, keyEquivalent: ""); head.isEnabled = false; m.addItem(head)
        if PermissionModes.isBypass(current) {
            let a = NSMenuItem(title: "Bypass permissions is on", action: nil, keyEquivalent: "")
            a.attributedTitle = NSAttributedString(string: a.title, attributes: [.foregroundColor: Theme.dynamic(.dangerText)]); a.isEnabled = false
            let b = NSMenuItem(title: "Fixed at launch, outside the Shift+Tab cycle", action: nil, keyEquivalent: ""); b.isEnabled = false
            m.addItem(a); m.addItem(b)
        } else {
            for item in PermissionModes.items {
                let i = BlockMenuItem(title: item.label) { [weak self] in self?.switchMode(of: s, to: item.mode) }
                i.state = item.mode == current ? .on : .off
                m.addItem(i)
            }
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: anchor)
    }

    /// Shift+Tab until the screen shows `target` (at most 4 presses, stops when a press changes nothing).
    func switchMode(of s: SessionModel, to target: String, pressed: Int = 0) {
        let before = s.screen?.mode ?? "default"
        guard s.exited == nil, PermissionModes.shouldPress(current: before, target: target, pressed: pressed) else { return }
        store.select(s)
        store.sendText(PermissionModes.cycleKeys)
        DispatchQueue.main.asyncAfter(deadline: .now() + PermissionModes.settleSeconds) { [weak self] in
            let after = s.screen?.mode ?? "default"
            if PermissionModes.shouldContinue(before: before, after: after) { self?.switchMode(of: s, to: target, pressed: pressed + 1) }
        }
    }
}
