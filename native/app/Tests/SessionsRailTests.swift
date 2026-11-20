// Unit tests of the sessions rail (Sources/Logic/SessionsRailLogic.swift).

import Foundation

func runSessionsRailTests() {
    test("rail pages: closing the column starts on Sessions, opening goes back to Menu") {
        var p = RailPages()
        check(p.page == .menu && !p.showsSessions, "open column: Menu")
        check(!p.flip(to: .sessions) && p.page == .menu, "no flip while the column is open")
        p.setCollapsed(true)
        check(p.showsSessions, "collapsed default = Sessions")
        check(p.flip(to: .menu) && p.page == .menu && !p.showsSessions, "flip to Menu")
        p.setCollapsed(true)
        check(p.page == .menu, "setting the same state again changes nothing")
        p.setCollapsed(false); check(p.page == .menu && !p.collapsed, "reopen: Menu")
        p.setCollapsed(true); p.flip(to: .menu); p.setCollapsed(false); p.setCollapsed(true)
        check(p.showsSessions, "collapse again: Sessions again")
    }
    test("rail rows: split groups get a bigger gap, members stay close") {
        let r = RailGeometry.rows(groups: [nil, "g1", "g1", nil])
        check(r.rows.count == 4 && r.rows[0].y == 0, "four rows")
        check(r.rows[2].y - r.rows[1].y == RailGeometry.itemHeight + RailGeometry.itemGap, "members of one split: small gap")
        check(r.rows[1].y - r.rows[0].y == RailGeometry.itemHeight + RailGeometry.groupGap, "gap before the split")
        check(r.rows[3].y - r.rows[2].y == RailGeometry.itemHeight + RailGeometry.groupGap, "gap after the split")
        check(r.height == r.rows[3].y + RailGeometry.itemHeight, "height")
        check(RailGeometry.rows(groups: []).height == 0, "empty")
    }
    test("rail scroll: reveal and clamp") {
        check(RailGeometry.reveal(rowY: 0, offset: 100, viewport: 200) == 0, "row above -> scroll up")
        check(RailGeometry.reveal(rowY: 500, offset: 0, viewport: 200) == 500 + RailGeometry.itemHeight - 200, "row below -> scroll down")
        check(RailGeometry.reveal(rowY: 50, offset: 0, viewport: 200) == 0, "visible row -> unchanged")
        check(RailGeometry.clamp(offset: 900, content: 600, viewport: 200) == 400 && RailGeometry.clamp(offset: -5, content: 600, viewport: 200) == 0, "clamp")
        check(RailGeometry.clamp(offset: 30, content: 100, viewport: 200) == 0, "content shorter than the viewport")
    }
    test("monogram: 2-3 letters") {
        check(RailMonogram.make("muya-all") == "MA", "two words")
        check(RailMonogram.make("claude control plane") == "CCP", "three words")
        check(RailMonogram.make("a-b-c-d") == "ABC", "at most three")
        check(RailMonogram.make("serbest") == "SE", "one word -> two letters")
        check(RailMonogram.make("x") == "X" && RailMonogram.make("") == "", "tiny and empty")
    }
    test("session step: wraps, handles no selection") {
        let ids: [UInt64] = [4, 7, 9]
        check(SessionStep.neighbor(of: 7, in: ids, delta: 1) == 9 && SessionStep.neighbor(of: 7, in: ids, delta: -1) == 4, "neighbors")
        check(SessionStep.neighbor(of: 9, in: ids, delta: 1) == 4 && SessionStep.neighbor(of: 4, in: ids, delta: -1) == 9, "wraps")
        check(SessionStep.neighbor(of: nil, in: ids, delta: 1) == 4 && SessionStep.neighbor(of: nil, in: ids, delta: -1) == 9, "none selected")
        check(SessionStep.neighbor(of: 99, in: ids, delta: 1) == 4, "unknown id")
        check(SessionStep.neighbor(of: 4, in: [], delta: 1) == nil, "empty")
    }
    test("rail keys: only the exact ⌃⌥ + arrow chords") {
        func k(_ code: UInt16, cmd: Bool = false, shift: Bool = false, alt: Bool = true, ctrl: Bool = true) -> KeyChord { KeyChord(keyCode: code, chars: "", cmd: cmd, shift: shift, alt: alt, ctrl: ctrl) }
        check(RailKeys.action(k(VK.left)) == .flip(.sessions) && RailKeys.action(k(VK.right)) == .flip(.menu), "left / right flip")
        check(RailKeys.action(k(VK.up)) == .step(-1) && RailKeys.action(k(VK.down)) == .step(1), "up / down step")
        check(RailKeys.action(k(VK.left, alt: false)) == nil, "⌃← is macOS Spaces")
        check(RailKeys.action(k(VK.left, ctrl: false)) == nil, "⌥← is the terminal's word move")
        check(RailKeys.action(k(VK.up, cmd: true)) == nil && RailKeys.action(k(VK.up, shift: true)) == nil, "extra modifiers pass through")
        check(RailKeys.action(k(VK.b)) == nil, "other keys pass through")
        // the terminal's own handling of ⌥ arrows must not claim these chords, and the ⌘ shortcut map must not either
        check(TerminalKeys.action(k(VK.left)) == nil, "terminal ignores ⌃⌥←")
        check(AppShortcuts.action(k(VK.left)) == nil, "no ⌘ map clash")
        for d in 1...9 { check(RailKeys.action(KeyChord(keyCode: VK.digits[d], chars: "\(d)", cmd: true)) == nil, "⌘\(d) untouched") }
    }
}
