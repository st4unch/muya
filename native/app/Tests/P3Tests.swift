// P3: the shortcut map (key -> terminal bytes / app action), the Esc rules, the ⌘Q double press, files handed
// over by Finder, and the closed-tab stack. Each expectation mirrors a rule in today's Muya (see ShortcutLogic.swift).

import Foundation

private func chord(_ c: String, _ code: UInt16 = 0, cmd: Bool = false, shift: Bool = false, alt: Bool = false, ctrl: Bool = false) -> KeyChord {
    KeyChord(keyCode: code, chars: c, cmd: cmd, shift: shift, alt: alt, ctrl: ctrl)
}

func runP3Tests() {
    test("Shift+Enter writes \\n; Enter alone, and Shift+Enter with another modifier, are left to the key path") {
        check(TerminalKeys.action(chord("\r", VK.enter, shift: true)) == .write("\n"), "shift+enter")
        check(TerminalKeys.action(chord("\r", VK.keypadEnter, shift: true)) == .write("\n"), "shift+keypad enter")
        check(TerminalKeys.action(chord("\r", VK.enter)) == nil, "plain enter")
        check(TerminalKeys.action(chord("\r", VK.enter, shift: true, alt: true)) == nil, "shift+alt+enter")
        check(TerminalKeys.action(chord("\r", VK.enter, cmd: true, shift: true)) == nil, "shift+cmd+enter is not a newline")
    }

    test("⌘ + R/L/A/E/D/U send the control bytes; ⌘K is the palette, never Ctrl+K") {
        check(TerminalKeys.action(chord("k", cmd: true)) == nil && AppShortcuts.action(chord("k", cmd: true)) == .togglePalette, "cmd+k")
        for (c, byte) in [("r", "\u{12}"), ("l", "\u{0C}"), ("a", "\u{01}"), ("e", "\u{05}"), ("d", "\u{04}"), ("u", "\u{15}")] {
            check(TerminalKeys.action(chord(c, cmd: true)) == .write(byte), "cmd+\(c)")
        }
        check(TerminalKeys.action(chord("r", cmd: true, shift: true)) == nil, "cmd+shift+r is not Ctrl+R")
        check(TerminalKeys.action(chord("r", cmd: true, alt: true)) == nil, "cmd+opt+r is not Ctrl+R")
        check(TerminalKeys.action(chord("r", cmd: true, ctrl: true)) == nil, "cmd+ctrl+r is not Ctrl+R")
        check(TerminalKeys.action(chord("w", cmd: true)) == nil, "cmd+w is the menu's")
        check(TerminalKeys.action(chord("r")) == nil, "plain r is text")
        check(TerminalKeys.action(chord("R", cmd: true)) == .write("\u{12}"), "upper-case letter from caps lock")
    }

    test("⌘C copies or interrupts; ⌘⇧C launches claude") {
        check(TerminalKeys.action(chord("c", cmd: true)) == .copyOrInterrupt, "cmd+c")
        check(TerminalKeys.action(chord("c", cmd: true, shift: true)) == .launchClaude, "cmd+shift+c")
        check(TerminalKeys.action(chord("c", cmd: true, shift: true, alt: true)) == nil, "cmd+shift+opt+c")
    }

    test("Option+arrows: ESC b / ESC f for left/right, plain arrows for up/down; with other modifiers untouched") {
        check(TerminalKeys.action(chord("", VK.left, alt: true)) == .write("\u{1B}b"), "opt+left")
        check(TerminalKeys.action(chord("", VK.right, alt: true)) == .write("\u{1B}f"), "opt+right")
        check(TerminalKeys.action(chord("", VK.up, alt: true)) == .write("\u{1B}[A"), "opt+up")
        check(TerminalKeys.action(chord("", VK.down, alt: true)) == .write("\u{1B}[B"), "opt+down")
        check(TerminalKeys.action(chord("", VK.left)) == nil, "plain left goes the normal way")
        check(TerminalKeys.action(chord("", VK.left, shift: true, alt: true)) == nil, "shift+opt+left")
        check(TerminalKeys.action(chord("", VK.left, cmd: true, alt: true)) == nil, "cmd+opt+left")
    }

    test("⌘F is search; ⌘= ⌘+ ⌘- ⌘0 step the font; ⌘+ with shift counts as bigger") {
        check(TerminalKeys.action(chord("f", cmd: true)) == .search, "cmd+f")
        check(TerminalKeys.action(chord("f", cmd: true, shift: true)) == nil, "cmd+shift+f")
        check(TerminalKeys.action(chord("=", cmd: true)) == .font(1), "cmd+=")
        check(TerminalKeys.action(chord("+", cmd: true, shift: true)) == .font(1), "cmd++")
        check(TerminalKeys.action(chord("-", cmd: true)) == .font(-1), "cmd+-")
        check(TerminalKeys.action(chord("0", cmd: true)) == .font(0), "cmd+0")
        check(TerminalKeys.action(chord("=", cmd: true, alt: true)) == nil, "cmd+opt+=")
    }

    test("font stepping clamps to 9...28 and resets to 13") {
        check(TerminalKeys.steppedFont(13, 1) == 14 && TerminalKeys.steppedFont(13, -1) == 12, "step")
        check(TerminalKeys.steppedFont(28, 1) == 28 && TerminalKeys.steppedFont(9, -1) == 9, "clamp")
        check(TerminalKeys.steppedFont(20, 0) == 13 && TerminalKeys.steppedFont(9, 0) == 13, "reset")
    }

    test("⌘1-9 pick the Nth agent; ⌘0 is not an agent shortcut") {
        for n in 1 ... 9 { check(AppShortcuts.action(chord(String(n), VK.digits[n], cmd: true)) == .selectAgent(n), "cmd+\(n)") }
        check(AppShortcuts.action(chord("0", VK.digits[0], cmd: true)) == nil, "cmd+0")
        check(AppShortcuts.action(chord("1", VK.digits[1], cmd: true, shift: true)) == nil, "cmd+shift+1")
        check(AppShortcuts.action(chord("1", VK.digits[1])) == nil, "plain 1 is text")
    }

    test("⌥⌘1-9 pick the Nth workspace, ⌥⌘0 all, by key code (⌥1 types '¡' on some layouts)") {
        for n in 1 ... 9 { check(AppShortcuts.action(chord("¡", VK.digits[n], cmd: true, alt: true)) == .selectWorkspace(n), "opt+cmd+\(n)") }
        check(AppShortcuts.action(chord("º", VK.digits[0], cmd: true, alt: true)) == .selectWorkspace(nil), "opt+cmd+0")
        check(AppShortcuts.action(chord("1", VK.digits[1], cmd: true, alt: true, ctrl: true)) == nil, "with ctrl it is not a workspace key")
        check(AppShortcuts.action(chord("1", VK.digits[1], cmd: true, shift: true, alt: true)) == nil, "with shift it is not a workspace key")
    }

    test("⌘B agents panel, ⌥⌘B inspector (by key code: ⌥B types '∫'); ⌘T new terminal; ⌘⇧D split; ⌘Enter maximize") {
        check(AppShortcuts.action(chord("b", VK.b, cmd: true)) == .toggleAgentsPanel, "cmd+b")
        check(AppShortcuts.action(chord("∫", VK.b, cmd: true, alt: true)) == .toggleInspector, "opt+cmd+b")
        check(AppShortcuts.action(chord("b", VK.b, cmd: true, shift: true)) == nil, "cmd+shift+b")
        check(AppShortcuts.action(chord("t", cmd: true)) == .newTerminal, "cmd+t")
        check(AppShortcuts.action(chord("t", cmd: true, shift: true)) == .reopenClosedTab, "cmd+shift+t reopens a closed tab, it is not a new terminal")
        check(AppShortcuts.action(chord("d", cmd: true, shift: true)) == .splitTerminalArea, "cmd+shift+d")
        check(AppShortcuts.action(chord("d", cmd: true)) == nil, "cmd+d stays Ctrl+D (terminal)")
        check(AppShortcuts.action(chord("\r", VK.enter, cmd: true)) == .maximizeGridPanel, "cmd+enter")
        check(AppShortcuts.action(chord("\r", VK.enter)) == nil, "plain enter")
    }

    test("Esc leaves the grid only with no modifier, no overlay, and focus outside a terminal or field") {
        let esc = chord("\u{1B}", VK.escape)
        check(AppShortcuts.escapeLeavesGrid(esc, overlayOpen: false, focusIsTerminalOrField: false), "plain")
        check(!AppShortcuts.escapeLeavesGrid(esc, overlayOpen: true, focusIsTerminalOrField: false), "overlay open")
        check(!AppShortcuts.escapeLeavesGrid(esc, overlayOpen: false, focusIsTerminalOrField: true), "terminal or field has focus (the agent uses Esc to interrupt)")
        check(!AppShortcuts.escapeLeavesGrid(chord("\u{1B}", VK.escape, shift: true), overlayOpen: false, focusIsTerminalOrField: false), "shift+esc")
        check(!AppShortcuts.escapeLeavesGrid(chord("a", 0), overlayOpen: false, focusIsTerminalOrField: false), "not Esc")
    }

    test("⌘Q: the first press shows the hint, a second within 700 ms quits, a late one starts over") {
        var g = QuitGuard()
        check(g.press(nowMs: 10_000) == .showHint, "first")
        check(g.press(nowMs: 10_699) == .quit, "second inside the window")
        check(g.press(nowMs: 20_000) == .showHint, "after a quit-press the guard is reset")
        check(g.press(nowMs: 20_700) == .showHint, "exactly 700 ms is outside the window")
        check(g.press(nowMs: 21_000) == .quit, "and that press armed the next")
    }

    test("files from Finder wait until the app is ready, then open at once; startup files drain only once") {
        var f = StartupFiles()
        check(f.offer(["/a.txt"]).isEmpty && f.offer(["/b.txt", "/c.txt"]).isEmpty, "kept while starting")
        check(f.drain() == ["/a.txt", "/b.txt", "/c.txt"], "drained in order")
        check(f.drain().isEmpty, "only once")
        check(f.offer(["/d.txt"]) == ["/d.txt"], "later files open immediately")
    }

    test("closed tabs come back newest first; a file reopened twice appears once; the stack is capped") {
        var c = ClosedTabs()
        check(c.isEmpty && c.pop() == nil, "empty")
        c.push(.terminal(cwd: "/p", name: "p"))
        c.push(.file(path: "/f"))
        c.push(.terminal(cwd: "/q", name: "q"))
        c.push(.file(path: "/f"))
        check(c.pop() == .file(path: "/f"), "newest first")
        check(c.pop() == .terminal(cwd: "/q", name: "q"), "then the terminal")
        check(c.pop() == .terminal(cwd: "/p", name: "p") && c.pop() == nil, "the duplicate file did not stay behind")
        for i in 0 ..< 30 { c.push(.file(path: "/f\(i)")) }
        var n = 0
        while c.pop() != nil { n += 1 }
        check(n == ClosedTabs.limit, "capped at \(ClosedTabs.limit), got \(n)")
    }

    test("the IME candidate window sits on the cursor cell at every font size") {
        // Cell sizes the atlas gives at 13 pt (8 x 21 px after the 1.6 line height) and scaled for 9 ... 28 pt.
        for pt in [9.0, 13.0, 20.0, 28.0] {
            let w = (pt * 0.6).rounded(.up), h = (pt * 1.6).rounded(.up)
            let r = IMEAnchor.cellRect(col: 29, row: 11, cellW: w, cellH: h, padding: 4)
            check(r.x == 4 + 29 * w && r.y == 4 + 11 * h && r.w == w && r.h == h, "\(pt) pt: cell (29,11) at \(r)")
            let origin = IMEAnchor.cellRect(col: 0, row: 0, cellW: w, cellH: h, padding: 4)
            check(origin.x == 4 && origin.y == 4, "\(pt) pt: the first cell starts at the padding")
        }
    }
}
