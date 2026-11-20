// Tests of the design-system layer (Sources/Theme): generated tokens, SVG icon paths, bundled fonts.

import AppKit

private func rgb(_ c: NSColor) -> (Int, Int, Int) {
    let s = c.usingColorSpace(.sRGB)!
    return (Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
}

func runThemeTests() {
    test("archive / restore result line and the daemon's answer") {
        check(CleanupLogic.resultLine(verb: "Archived", done: 2, skipped: []) == "Archived 2 sessions.", "plural")
        check(CleanupLogic.resultLine(verb: "Restored", done: 1, skipped: []) == "Restored 1 session.", "singular")
        check(CleanupLogic.resultLine(verb: "Archived", done: 0, skipped: [("a", "session is running")]) == "Nothing archived. 1 session left as they were (session is running).", "nothing")
        check(CleanupLogic.resultLine(verb: "Archived", done: 1, skipped: [("a", "x"), ("b", "x"), ("c", "y")]) == "Archived 1 session. 3 sessions left as they were (x, y).", "reasons once")
        let o = CleanupLogic.parseOutcome(["done": 2, "skipped": [["/p/a.jsonl", "session is running"]]] as [String: Any])
        check(o?.done == 2 && o?.skipped.first?.1 == "session is running", "parse")
        check(CleanupLogic.parseOutcome("nope") == nil && CleanupLogic.parseOutcome(["x": 1] as [String: Any]) == nil, "bad answers")
    }

    test("tokens: dark and light values come from src/styles/tokens.css") {
        check(rgb(Theme.color(.bgApp, .dark)) == (0x0F, 0x11, 0x15), "--bg-app dark")
        check(rgb(Theme.color(.bgApp, .light)) == (0xF4, 0xF5, 0xF7), "--bg-app light")
        check(rgb(Theme.color(.accent, .dark)) == (0x8F, 0xB3, 0xFF), "--accent dark")
        check(rgb(Theme.color(.primaryBg, .light)) == (0x1A, 0x1D, 0x23), "--primary-bg light")
        for t in Theme.Token.allCases { check(Theme.dark[t] != nil, "\(t) has a dark value") }
        check(ThemeMetric.railWidth == 64 && ThemeMetric.headerHeight == 48 && ThemeMetric.footerHeight == 28, "frame geometry")
    }
    test("terminal palette: 16 ANSI colours of both themes, xterm values") {
        check(TerminalTheme.dark.ansi.count == 16 && TerminalTheme.light.ansi.count == 16, "16 colours")
        check(TerminalTheme.dark.background.r == 0x0B && TerminalTheme.dark.background.g == 0x0D && TerminalTheme.dark.background.b == 0x11, "dark background #0B0D11")
        check(TerminalTheme.dark.ansi[1].r == 0xF0 && TerminalTheme.dark.ansi[1].g == 0x71, "dark red #F07167")
        check(TerminalTheme.light.background.r == 0xFF, "light background white")
    }
    test("svg paths: arcs, relative commands, compact flags") {
        let p = SVGPath.parse("M3 12a9 9 0 1 0 3-6.7L3 8")
        check(!p.isEmpty && p.boundingBox.width > 8, "arc path has extent")
        let box = SVGPath.parse("M3 6h.01M3 12h.01").boundingBox
        check(abs(box.minX - 3) < 0.001 && abs(box.maxX - 3.01) < 0.001, "dot paths")
        let compact = SVGPath.parse("M10 4a2 2 0 011 3z")  // flags without separators
        check(!compact.isEmpty, "compact arc flags")
        let circle = SVGPath.parse("M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0")
        let b = circle.boundingBox
        check(abs(b.width - 20) < 0.2 && abs(b.height - 20) < 0.2, "two half arcs make a 20-wide circle: \(b)")
    }
    test("icons: every web icon has shapes and a non-empty path inside the 24 viewBox") {
        check(ThemeIcon.allCases.count == 40, "37 web icons + stop + agentOpened + command (native only), got \(ThemeIcon.allCases.count)")
        for ic in ThemeIcon.allCases {
            let bb = ThemeIcons.path(ic).boundingBox
            check(!ic.def.shapes.isEmpty && bb.width > 0 && bb.minX >= -0.5 && bb.maxX <= 24.5 && bb.minY >= -0.5 && bb.maxY <= 24.5, "\(ic) bounds \(bb)")
        }
    }
    test("fonts: the bundled files register and resolve by PostScript name") {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts")
        let names = ThemeFonts.register(directory: dir)
        for n in ["IBMPlexSans-Regular", "IBMPlexSans-Medium", "IBMPlexSans-SemiBold", "IBMPlexSans-Bold", "JetBrainsMono-Regular", "JetBrainsMono-Bold"] {
            check(names.contains(n), "\(n) registered")
        }
        check(ThemeFont.sans(13, .semibold).fontName == "IBMPlexSans-SemiBold", "semibold maps to SemiBold")
        check(ThemeFont.mono(13).fontName == "JetBrainsMono-Regular", "mono is JetBrains Mono")
        var gbreve: UniChar = 0x011F   // ğ is in latin-ext, merged into the same file
        var glyph = CGGlyph(0)
        check(CTFontGetGlyphsForCharacters(ThemeFont.sans(13), &gbreve, &glyph, 1) && glyph != 0, "latin-ext glyphs merged in")
    }
    test("agents rows: attachable rule, attach / resume commands, duration, branch from .git/HEAD") {
        let bg = AgentRow(json: ["sessionId": "s1", "kind": "background"])!, withId = AgentRow(json: ["sessionId": "s2", "id": "abc12345", "kind": "interactive"])!
        let plain = AgentRow(json: ["sessionId": "s3", "kind": "interactive"])!, oc = AgentRow(json: ["sessionId": "s4", "kind": "opencode"])!
        check(bg.attachable && withId.attachable && !plain.attachable, "attachable = background or has an id")
        check(oc.isOpencode && !plain.isOpencode, "opencode kind")
        check(AgentsLogic.attachCommand("abc-12.x_y") == "claude attach 'abc-12.x_y' --dangerously-skip-permissions", "attach command")
        check(AgentsLogic.attachCommand("a'b") == nil && AgentsLogic.attachCommand("") == nil && AgentsLogic.attachCommand("a b") == nil, "unsafe ids refused")
        check(AgentsLogic.opencodeResumeCommand("x1") == "opencode --session 'x1' --auto", "opencode resume command")
        let now = Date(timeIntervalSince1970: 1_000_000)
        check(AgentsLogic.duration(startedAt: nil, now: now) == "—", "no start")
        check(AgentsLogic.duration(startedAt: 1_000_000_000 - 30_000, now: now) == "30s", "seconds")
        check(AgentsLogic.duration(startedAt: 1_000_000_000 - 12 * 60_000, now: now) == "12m", "minutes")
        check(AgentsLogic.duration(startedAt: 1_000_000_000 - 64 * 60_000, now: now) == "1h 4m", "hours")
        let dir = NSTemporaryDirectory() + "wp6-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir + "/repo/.git", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: dir + "/repo/sub/deep", withIntermediateDirectories: true)
        try? "ref: refs/heads/feature/x\n".write(toFile: dir + "/repo/.git/HEAD", atomically: true, encoding: .utf8)
        check(AgentsLogic.branch(of: dir + "/repo") == "feature/x" && AgentsLogic.branch(of: dir + "/repo/sub/deep") == "feature/x", "branch from HEAD, also from a sub-folder")
        try? "0123456789abcdef\n".write(toFile: dir + "/repo/.git/HEAD", atomically: true, encoding: .utf8)
        check(AgentsLogic.branch(of: dir + "/repo") == "0123456", "detached HEAD → short hash")
        check(AgentsLogic.branch(of: dir) == "—", "not a repository")
        try? FileManager.default.removeItem(atPath: dir)
    }
    test("dialogs: trimmed submit text, broadcast button title") {
        check(DialogsLogic.trimmed("  build  \n") == "build" && DialogsLogic.trimmed(" \n\t") == nil && DialogsLogic.trimmed("") == nil, "trim / empty")
        check(DialogsLogic.broadcastTitle(panels: 1) == "Send to 1 panel" && DialogsLogic.broadcastTitle(panels: 4) == "Send to 4 panels", "title")
    }
    test("storage heads-up: heavy only with old or big sessions, text, day key") {
        let now = Date(timeIntervalSince1970: 2_000_000_000), nowMs = Int64(now.timeIntervalSince1970 * 1000), day: Int64 = 86_400_000, mb: Int64 = 1_048_576
        func e(_ id: String, age: Int64, size: Int64) -> HistoryEntry { HistoryEntry(json: ["sessionId": id, "path": "/p/\(id).jsonl", "lastModified": NSNumber(value: nowMs - age), "sizeBytes": NSNumber(value: size)])! }
        let light = StorageHeadsUpLogic.summary([e("a", age: day, size: mb), e("b", age: 2 * day, size: 2 * mb)], now: now)
        check(!StorageHeadsUpLogic.heavy(light) && light.count == 2, "light history stays quiet")
        let heavy = StorageHeadsUpLogic.summary([e("a", age: 40 * day, size: mb), e("b", age: day, size: 150 * mb), e("c", age: day, size: 3 * mb)], now: now)
        check(StorageHeadsUpLogic.heavy(heavy) && heavy.old == 1 && heavy.big == 1, "old + big counted")
        let text = StorageHeadsUpLogic.text(count: heavy.count, bytes: heavy.bytes, old: heavy.old, big: heavy.big)
        check(text.hasPrefix("3 sessions") && text.contains("1 not used for 30+ days") && text.contains("1 over 100 MB"), "text: \(text)")
        check(StorageHeadsUpLogic.dayKey(Date(timeIntervalSince1970: 0)).count == 10, "day key yyyy-MM-dd")
    }
    test("status fields: catalogue groups and the filter") {
        check(StatusFieldCatalog.byLabel["Context used"] != nil && StatusFieldCatalog.groupOrder.count == 10, "catalogue")
        check(StatusFieldCatalog.filtered("").flatMap(\.1).count == StatusFieldCatalog.fields.count, "no filter keeps all")
        let f = StatusFieldCatalog.filtered("CONTEXT")
        check(f.count == 1 && f[0].0 == "Context" && f[0].1.contains { $0.label == "Context size" } && !f[0].1.contains { $0.label == "Model" }, "filter is case-insensitive and drops empty groups")
        check(StatusFieldCatalog.filtered("zzz").isEmpty, "no match")
    }
    test("grid plan: layouts, waiting first, picked cells, swap/append, cell rectangles") {
        check(GridChoice.allCases.map(\.capacity) == [1, 2, 4, 6] && GridChoice.threeByTwo.shape == (3, 2) && GridChoice.oneByTwo.label == "1×2", "capacities and labels")
        let ids: [UInt64] = [1, 2, 3, 4, 5, 6, 7]
        check(GridPlan.visible(ids: ids, waiting: [], waitingFirst: false, picked: nil, selected: nil, capacity: 4) == [1, 2, 3, 4], "first four")
        check(GridPlan.visible(ids: ids, waiting: [5], waitingFirst: true, picked: nil, selected: nil, capacity: 4) == [5, 1, 2, 3], "waiting first")
        check(GridPlan.visible(ids: ids, waiting: [], waitingFirst: false, picked: nil, selected: 7, capacity: 4) == [1, 2, 3, 7], "selected is always shown")
        check(GridPlan.visible(ids: ids, waiting: [], waitingFirst: false, picked: [6, 99, 2], selected: nil, capacity: 4) == [6, 2], "picked wins, unknown ids dropped")
        check(GridPlan.assign([1, 2, 3], targetIndex: 0, pick: 3) == [3, 2, 1], "a session already in the grid swaps places")
        check(GridPlan.assign([1, 2, 3], targetIndex: 1, pick: 9) == [1, 9, 3], "another session takes the cell")
        check(GridPlan.assign([1, 2], targetIndex: nil, pick: 5) == [1, 2, 5] && GridPlan.assign([1, 2], targetIndex: nil, pick: 2) == [1, 2], "empty cell appends once")
        let c = GridPlan.cells(cols: 2, rows: 2, width: 1000, height: 600)
        check(c.count == 4 && c[0].x == 16 && c[0].w == 478 && c[1].x == 506 && c[2].y == c[0].y + c[0].h + 12, "cell rectangles")
    }
    test("alwaysAllowText: project rule, session rule, plain (same cases as GridPanel.test.tsx)") {
        check(GridPlan.alwaysAllowText("Yes, and don't ask again for: curl *") == "Don't ask again (this project)", "bash rule saved to the project")
        check(GridPlan.alwaysAllowText("Yes, and dont ask again for: ls") == "Don't ask again (this project)", "apostrophe optional")
        check(GridPlan.alwaysAllowText("Yes, allow all edits during this session") == "Allow all this session", "edits end with the session")
        check(GridPlan.alwaysAllowText("Yes, always") == "Always allow", "plain")
    }
    test("a split view has no divider while a pane is hidden (no stray vertical line)") {
        let split = HidingDividerSplit(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        split.isVertical = true; split.dividerStyle = .thin
        let a = NSView(), b = NSView()
        split.addArrangedSubview(a); split.addArrangedSubview(b)
        check(split.dividerThickness == 1 && !split.hasHiddenPane, "visible panes: the normal 1 px divider")
        a.isHidden = true; split.adjustSubviews()
        check(split.dividerThickness == 0 && split.hasHiddenPane, "first pane hidden: no divider")
        a.isHidden = false; b.isHidden = true
        check(split.dividerThickness == 0, "second pane hidden: no divider")
        b.isHidden = false
        check(split.dividerThickness == 1, "both shown again: divider back")
    }
    test("char diff: the changed characters of a modified line, from an LCS") {
        let a = CharDiff.spans(old: "const answer = 41;", new: "const answer = 42;")
        check(a.old == [16 ..< 17] && a.new == [16 ..< 17], "one digit: \(a)")
        let b = CharDiff.spans(old: "let x = foo(a, b)", new: "let y = foo(a, c)")
        check(b.old == [4 ..< 5, 15 ..< 16] && b.new == [4 ..< 5, 15 ..< 16], "two separate changes: \(b)")
        let c = CharDiff.spans(old: "abc", new: "abXc")
        check(c.old.isEmpty && c.new == [2 ..< 3], "pure insertion highlights only the new side: \(c)")
        let w = CharDiff.spans(old: "Command::new(cmd)", new: "Command::new(command)")
        check(w.old.isEmpty && w.new == [14 ..< 19], "a word grown inside: fragments one or two characters apart merge into one span: \(w)")
        check(CharDiff.spans(old: "same", new: "same").old.isEmpty, "equal lines have no spans")
        check(CharDiff.spans(old: "", new: "new").new == [0 ..< 3], "an empty old line: everything is new")
        let long = String(repeating: "x", count: 500)
        let d = CharDiff.spans(old: long + "1", new: long + "2")
        check(d.old == [500 ..< 501] && d.new == [500 ..< 501], "long lines use prefix/suffix")
    }
    test("permission modes: chip labels, picker items, Shift+Tab stepping rule (App.tsx setModeTo)") {
        check(["default", "acceptEdits", "plan", "auto", "bypass", "bypass permissions"].map(PermissionModes.chipLabel) == ["manual", "accept edits", "plan", "auto", "bypass", "bypass"], "MODE_LABEL")
        check(PermissionModes.items.map(\.label) == ["Manual", "Accept edits", "Plan", "Auto"] && PermissionModes.items.map(\.mode) == ["default", "acceptEdits", "plan", "auto"], "MODE_ITEMS: bypass is not offered")
        check(PermissionModes.isBypass("bypass") && !PermissionModes.isBypass("plan"), "bypass is outside the cycle")
        check(PermissionModes.cycleKeys == "\u{1B}[Z" && PermissionModes.maxPresses == 4 && PermissionModes.settleSeconds == 0.7, "Shift+Tab, 4 presses, 0.7 s")
        check(PermissionModes.shouldPress(current: "default", target: "plan", pressed: 0) && !PermissionModes.shouldPress(current: "plan", target: "plan", pressed: 1) && !PermissionModes.shouldPress(current: "default", target: "plan", pressed: 4), "stop at the target or after 4 presses")
        check(PermissionModes.shouldContinue(before: "default", after: "acceptEdits") && !PermissionModes.shouldContinue(before: "plan", after: "plan"), "an unchanged screen stops the loop")
    }
}
