#if MUYA_TEST_HOOKS
// Test-hook commands of the Faz 4a views (Sessions, Schedules, Settings, command palette) and an
// accessibility audit. Like all debug commands they exist only while MUYA_DEBUG_SOCKET is set. Calls into
// muyad are asynchronous: a script starts one and polls the matching `*-view` / `*-state` command.

import AppKit

extension NSView { var refusesFirstResponderSafe: Bool { (self as? NSControl)?.refusesFirstResponder ?? false } }

extension DebugServer {
    func runFaz4(_ cmd: String, _ arg: String) -> String? {
        let c = controller
        let w = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let sp = c.sessionsPage, sc = c.schedulesPage
        switch cmd {
        case "page":
            switch arg {
            case "sessions": c.showPage(sp)
            case "schedules": c.showPage(sc)
            case "none", "control": c.showPage(nil)
            default: break
            }
            return c.currentPage.map { $0.titleLabel.stringValue } ?? "none"
        case "newagent-open": c.newSession(); return c.newAgentSheet == nil ? "error" : "ok"
        case "newagent-close": c.newAgentSheet?.cancelTapped(); return "ok"
        case "newagent-set":
            guard w.count == 2, let n = c.newAgentSheet else { return "error: newagent-set <field> <value> with the dialog open" }
            return n.debugSet(w[0], w[1]) ? "ok" : "error: unknown field"
        case "newagent-launch": c.newAgentSheet?.launchTapped(); return "ok"
        case "newagent-state": return c.newAgentSheet?.debugState() ?? "none"
        case "notifications-open": if c.notificationsPopover == nil { c.showNotifications() }; return c.notificationsPopover == nil ? "error" : "ok"
        case "popover-close": c.notificationsPopover?.close(); return "ok"
        case "snap": return MainActor.assumeIsolated { DebugSnap.snapshot(c.window, to: arg) }
        case "view-windowid": return "\(c.window.windowNumber)"

        // Sessions
        case "sessions-view": return sp.debugState()
        case "sessions-selected": return sp.selectedEntry?.sessionId ?? sp.selectedAgent?.sessionId ?? "none"
        case "sessions-reload": sp.reload(); return "ok"
        case "sessions-search": sp.setSearch(arg); return "ok"
        case "sessions-cancel": sp.cancelSearch(); return "ok searching=\(sp.searching)"
        case "sessions-select": return sp.select(id: arg) ? "ok" : "error: not listed"
        case "sessions-resume":
            guard sp.select(id: arg), let e = sp.selectedEntry else { return "error: not listed" }
            sp.resume(e); return "ok"
        case "sessions-export":
            // sessions-export <id> <dest>
            guard w.count == 2, let e = sp.entry(id: w[0]) else { return "error: sessions-export <id> <dest>" }
            sp.exportDestination = URL(fileURLWithPath: w[1])
            sp.exportDestination.map { sp.write(e, to: $0) }
            sp.exportDestination = nil
            return "ok"
        case "sessions-last-export": return sp.lastExport ?? ""

        // Schedules
        case "sched-view": return sc.debugState()
        case "sched-reload": sc.reload(); return "ok"
        case "sched-new": sc.newTapped(); return sc.editor == nil ? "error: no editor" : "ok"
        case "sched-session":   // the same call the session menu's "Schedule…" makes
            guard let id = UInt64(arg), let s = c.store.sessions.first(where: { $0.id == id }) else { return "error: no such session" }
            c.openSessionSchedule(s); return sc.editor == nil ? "error: no editor" : "ok"
        case "session-menu":    // titles of a session's right-click menu
            guard let id = UInt64(arg), let s = c.store.sessions.first(where: { $0.id == id }) else { return "error: no such session" }
            return c.sessionMenu(for: s).items.map { $0.isSeparatorItem ? "-" : $0.title }.joined(separator: "|")
        case "sched-edit":
            guard let j = sc.select(name: arg) else { return "error: no such schedule" }
            sc.openEditor(j); return "ok"
        case "sched-set":
            // sched-set <field> <value>   (name prompt folder kind minutes times days timeout on bypass chrome)
            guard w.count == 2, let ed = sc.editor else { return "error: sched-set <field> <value> with an editor open" }
            return ed.debugSet(w[0], w[1]) ? "ok" : "error: unknown field"
        case "sched-save": sc.editor?.submit(); return "ok"
        case "sched-editor": return sc.editor?.debugState() ?? "none"
        case "sched-cancel": sc.editor?.cancelTapped(); return "ok"
        case "sched-run":
            guard let j = sc.select(name: arg) else { return "error: no such schedule" }
            sc.runNow(j); return "ok"
        case "sched-toggle":
            // sched-toggle <name> on|off   (the name may contain spaces)
            guard let on = arg.split(separator: " ").last, let j = sc.select(name: String(arg.dropLast(on.count)).trimmingCharacters(in: .whitespaces)) else { return "error: no such schedule" }
            sc.setEnabled(j, on == "on"); return "ok"
        case "sched-delete":
            guard let j = sc.select(name: arg) else { return "error: no such schedule" }
            sc.delete(j, confirm: false); return "ok"
        case "sched-history":
            guard let j = sc.select(name: arg) else { return "error: no such schedule" }
            sc.showHistory(j); return "ok"
        case "sched-history-view": return sc.historyPanel?.debugState() ?? "none"
        case "sched-history-close": sc.historyPanel?.closeTapped(); return "ok"
        case "sched-sheet-windowid": return "\(c.window.windowNumber)"

        // Settings
        case "settings-open": c.settings.show(); return "\(c.settings.window.windowNumber)"
        case "menu-item":
            // menu-item <title>: the item's shortcut, then its action is performed (what choosing it does).
            func find(_ m: NSMenu?) -> NSMenuItem? {
                for i in m?.items ?? [] { if i.title == arg { return i }; if let f = find(i.submenu) { return f } }
                return nil
            }
            guard let i = find(NSApp.mainMenu), let a = i.action else { return "error: no such menu item" }
            let desc = "key=\(i.keyEquivalent) cmd=\(i.keyEquivalentModifierMask.contains(.command))"
            NSApp.sendAction(a, to: i.target, from: i)
            return desc
        case "settings-scroll-end": c.settings.scrollToEnd(); return "ok"
        case "settings-scroll-privacy": c.settings.scrollToPrivacy(); return "ok"
        case "settings-visible": return c.settings.window.isVisible ? "yes" : "no"
        case "settings-close": c.settings.window.close(); return "ok"
        case "settings-reload": c.settings.reload(); return "ok"
        case "settings-get": return c.settings.value(of: arg)
        case "settings-set":
            guard w.count == 2 else { return "error: settings-set <id> <value>" }
            return c.settings.set(w[0], w[1]) ? "ok" : "error: bad id or value"
        case "settings-rows": return SettingsSchema.rows.map { "\($0.id)=\(c.settings.value(of: $0.id))" }.joined(separator: "\n")
        case "appearance-name": return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"

        // Command palette
        case "palette-open": c.palette.open(); return "ok"
        case "palette-query": if !c.palette.isOpen { c.palette.open() }; c.palette.setQuery(arg); return c.palette.debugState()
        case "palette-state": return (c.palette.isOpen ? "open\n" : "closed\n") + c.palette.debugState()
        case "palette-run":
            if !arg.isEmpty, !c.palette.select(id: arg) { return "error: not in the results" }
            c.palette.runSelected(); return "ok"
        case "palette-close": c.palette.dismiss(); return "ok"
        case "palette-shortcut":
            // Sends ⌘K through the window like a key press (menu key equivalents included).
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)
            if let e { _ = NSApp.mainMenu?.performKeyEquivalent(with: e) }
            return c.palette.isOpen ? "open" : "closed"

        // Faz 4e: live agent sessions, clean-up, transcript drawer, scheduled prompt, auto-allow, resume, migration
        case "agents-reload": sp.reloadAgents(); return "ok"
        case "agents-info": return "runs=\(c.agents.runs) bin=\(c.agents.resolveBinary() == nil ? "none" : "found") error=\(c.agents.lastError ?? "")"
        case "cleanup-open":
            if c.currentPage !== sp { c.showPage(sp) }
            return sp.openCleanup() == nil ? "error: already open" : "ok"
        case "cleanup-view": return sp.cleanup?.debugState() ?? "none"
        case "cleanup-set":
            guard w.count == 2, let cl = sp.cleanup else { return "error: cleanup-set <older|larger> <n|off> with the dialog open" }
            return cl.setRule(w[0], w[1]) ? "ok" : "error: bad rule"
        case "cleanup-toggle": return sp.cleanup?.toggle(id: arg) == true ? "ok" : "error: not listed"
        case "cleanup-tab": guard let cl = sp.cleanup else { return "error: open the dialog first" }; cl.selectTabForTest(arg == "archived" ? 1 : 0); return "ok"
        case "cleanup-archive": sp.cleanup?.archiveOrRestore(); return "ok"
        case "cleanup-trash": sp.cleanup?.trash(confirm: false); return "ok"
        case "cleanup-close": sp.cleanup?.closeTapped(); return "ok"
        case "cleanup-windowid": return "\(c.window.windowNumber)"
        case "transcript-open":
            guard sp.select(id: arg), let e = sp.selectedEntry else { return "error: not listed" }
            sp.showTranscript(e); return "ok"
        case "transcript-view":
            let t = sp.transcriptPanel
            return "shown=\(t.isHidden ? "none" : (t.shownId ?? ""))\nnote=\(t.noteText)\n\(t.contentText)"
        case "transcript-close": sp.transcriptPanel.closeTapped(); return "ok"
        case "sprompt-open": return c.openScheduledPrompt() == nil ? "error" : "ok"
        case "sprompt-set":
            guard w.count == 2, let sh = c.promptSheet else { return "error: sprompt-set <prompt|terminals|in> <value> with the sheet open" }
            return sh.debugSet(w[0], w[1]) ? "ok" : "error: bad field"
        case "sprompt-submit": return c.promptSheet?.submit().map { "error=\($0)" } ?? "ok"
        case "sprompt-view": return c.promptSheet?.debugState() ?? "none"
        case "sprompt-select": c.promptSheet?.select(row: Int(arg) ?? -1); return "ok"
        case "sprompt-edit": c.promptSheet?.editTapped(); return "ok"
        case "sprompt-delete": c.promptSheet?.deleteTapped(); return "ok"
        case "sprompt-close": c.promptSheet?.closeTapped(); return "ok"
        case "sprompt-fire": c.promptRunner.fire(); return "fired=\(c.promptRunner.firedCount)"
        case "sprompt-state": return "fired=\(c.promptRunner.firedCount) pending=\(c.promptRunner.model.pending.count)"
        case "notify-state": return c.store.notifier.debugState()
        case "notify-delivered": return c.store.notifier.debugDelivered()
        case "notify-click": if let id = UInt64(arg) { c.store.notifier.focus(session: id); return "ok" } else { return "error: notify-click <session id>" }
        case "autoallow-state": return "allowed=\(c.store.autoAllowed)"
        case "resume-state": return "resumed=\(c.resumedAtLaunch.joined(separator: ",")) saved=\(c.resume.saved.map(\.sessionId).joined(separator: ","))"
        case "migration-state": return c.migrationOutcome.map { "\($0)" } ?? "pending"
        case "sched-events": return "events=\(c.store.eventsSeen) eventReloads=\(sc.eventReloads) pollReloads=\(sc.pollReloads)"
        case "spotlight-info": return "started=\(c.spotlight.started)"
        case "licences-text": return String(SettingsController.licencesText().prefix(200))
        case "licences-open": c.settings.show(); c.settings.showLicences(); return c.settings.licencesSheet == nil ? "error" : "ok"
        case "licences-close": c.settings.closeLicences(); return "ok"
        case "licences-windowid": return "\(c.settings.window.windowNumber)"

        case "focus":
            var r: NSResponder? = c.window.firstResponder
            if let tv = r as? NSTextView, tv.isFieldEditor, let d = tv.delegate as? NSView { r = d }
            guard let v = r as? NSView else { return r.map { "\(type(of: $0))" } ?? "none" }
            let label = v.accessibilityLabel() ?? (v as? NSButton)?.title ?? ""
            return "\(type(of: v)) label=\(label)"
        case "press":
            // press <tab|shift-tab|return|esc|down|up|space|cmd-k|cmd-comma>: a real key event through the window.
            let table: [String: (String, UInt16, NSEvent.ModifierFlags)] = [
                "tab": ("\t", 48, []), "shift-tab": ("\u{19}", 48, [.shift]), "return": ("\r", 36, []), "esc": ("\u{1b}", 53, []),
                "down": (String(UnicodeScalar(0xF701)!), 125, []), "up": (String(UnicodeScalar(0xF700)!), 126, []), "space": (" ", 49, []),
                "cmd-k": ("k", 40, [.command]), "cmd-comma": (",", 43, [.command]), "cmd-return": ("\r", 36, [.command]),
            ]
            guard let k = table[arg] else { return "error: unknown key" }
            if k.2.contains(.command) {
                // Command shortcuts are menu key equivalents: route like NSApplication does.
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: k.2, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber, context: nil, characters: k.0, charactersIgnoringModifiers: k.0, isARepeat: false, keyCode: k.1)
                guard let e else { return "error" }
                NSApp.sendEvent(e)
                return "ok"
            }
            post(chars: k.0, keyCode: k.1, flags: k.2)
            return "ok"
        case "inspector-tab":
            // inspector-tab <changes|files|activity|off>: shows the Inspector on that tab (or hides it).
            guard let split = c.inspector.superview as? InspectorSplit else { return "error: no inspector" }
            if arg == "off" { if !c.inspector.isHidden { split.toggle() }; return "ok" }
            if c.inspector.isHidden { c.toggleInspector() }
            c.inspector.select(tab: arg == "files" ? .files : arg == "activity" ? .activity : .changes)
            c.inspector.cwd = c.store.selected?.cwd
            return "ok"
        case "files-focus": return c.window.makeFirstResponder(c.files.outline) ? "ok" : "error"
        case "files-selected":
            let f = c.files
            guard f.outline.selectedRow >= 0, let n = f.outline.item(atRow: f.outline.selectedRow) as? FileNode else { return "none" }
            return "\(f.outline.level(forRow: f.outline.selectedRow))\t\(n.name)\(n.isDirectory ? "/" : "")\t\(n.isDirectory ? (f.outline.isItemExpanded(n) ? "expanded" : "collapsed") : "file")"
        case "fka": return NSApp.isFullKeyboardAccessEnabled ? "on" : "off"
        case "keycontrols":
            // keycontrols <main|settings|sheet|settings-sheet>: the enabled, visible controls of that window and whether each can take
            // keyboard focus (what Tab / Full Keyboard Access can reach), one `Type<TAB>label<TAB>focusable` line each.
            let target: NSWindow? = switch arg { case "main": c.window; case "settings": c.settings.window; case "sheet": c.window.attachedSheet ?? c.sessionsPage.cleanup?.window   // the Clean up dialog is a borderless panel over the page now, not an attached sheet
                case "settings-sheet": c.settings.window.attachedSheet; default: nil }
            guard let w = target, let root = w.contentView else { return "error: no such window" }
            var out: [String] = []
            func visit(_ v: NSView) {
                if v.isHidden || v is NSScroller || v is NSImageView { return } // images are decoration, not controls
                var control = false
                if let b = v as? NSButton { control = b.isEnabled } else if let sc = v as? NSControl, !(v is NSTextField) { control = sc.isEnabled }
                else if let t = v as? NSTextField { control = t.isEditable && t.isEnabled } else if v is NSTableView || v is NSOutlineView { control = true }
                else if let tv = v as? NSTextView { control = tv.isEditable && !tv.isFieldEditor }
                if control {
                    var label = v.accessibilityLabel() ?? ""
                    if label.isEmpty, let b = v as? NSButton { label = b.title }
                    if label.isEmpty, let sc = v as? NSSegmentedControl { label = (0 ..< sc.segmentCount).compactMap { sc.label(forSegment: $0) }.joined(separator: "/") }
                    let focusable = v.acceptsFirstResponder && !v.refusesFirstResponderSafe
                    out.append("\(type(of: v))\t\(label)\t\(focusable ? "yes" : "no")")
                }
                if v is NSTextField { return } // a search field's magnifier / clear buttons are parts of the field, not controls of their own
                for sv in v.subviews { visit(sv) }
            }
            visit(root)
            return out.joined(separator: "\n")
        case "pressin", "focusin":
            // pressin <main|settings|sheet|settings-sheet> <key> / focusin <target>: like press / focus, but at a window other than
            // the main one (a locked screen leaves the app inactive, so no window is "key" and an external key event reaches the main window).
            let words = arg.split(separator: " ").map(String.init)
            let target: NSWindow? = switch words.first ?? "" {
            case "main": c.window
            case "settings": c.settings.window.isVisible ? c.settings.window : nil
            case "sheet": c.window.attachedSheet ?? c.sessionsPage.cleanup?.window   // the Clean up dialog is a borderless panel over the page now, not an attached sheet
            case "settings-sheet": c.settings.window.attachedSheet
            default: nil
            }
            guard let w = target else { return "error: no such window (main|settings|sheet|settings-sheet)" }
            if cmd == "focusin" {
                var r: NSResponder? = w.firstResponder
                if let tv = r as? NSTextView, tv.isFieldEditor, let d = tv.delegate as? NSView { r = d }
                guard let v = r as? NSView else { return r.map { "\(type(of: $0))" } ?? "none" }
                var label = v.accessibilityLabel() ?? ""
                if label.isEmpty, let b = v as? NSButton { label = b.title }
                if label.isEmpty, let sc = v as? NSSegmentedControl { label = (0 ..< sc.segmentCount).compactMap { sc.label(forSegment: $0) }.joined(separator: "/") }
                return "\(type(of: v)) label=\(label)"
            }
            let keys: [String: (String, UInt16, NSEvent.ModifierFlags)] = [
                "tab": ("\t", 48, []), "shift-tab": ("\u{19}", 48, [.shift]), "return": ("\r", 36, []), "esc": ("\u{1b}", 53, []),
                "down": (String(UnicodeScalar(0xF701)!), 125, []), "up": (String(UnicodeScalar(0xF700)!), 126, []),
                "left": (String(UnicodeScalar(0xF702)!), 123, []), "right": (String(UnicodeScalar(0xF703)!), 124, []), "space": (" ", 49, []),
            ]
            guard words.count > 1, let k = keys[words[1]] else { return "error: pressin <target> <tab|shift-tab|return|esc|down|up|left|right|space>" }
            post(chars: k.0, keyCode: k.1, flags: k.2, in: w)
            return "ok"
        case "focus-key":
            // The first responder of the key window (a sheet, the Settings window, ...): what a real key press reaches.
            let w = NSApp.keyWindow ?? c.window
            var r: NSResponder? = w.firstResponder
            if let tv = r as? NSTextView, tv.isFieldEditor, let d = tv.delegate as? NSView { r = d }
            guard let v = r as? NSView else { return "win=\(w.title) " + (r.map { "\(type(of: $0))" } ?? "none") }
            var label = v.accessibilityLabel() ?? ""
            if label.isEmpty, let b = v as? NSButton { label = b.title }
            if label.isEmpty, let sc = v as? NSSegmentedControl { label = (0 ..< sc.segmentCount).compactMap { sc.label(forSegment: $0) }.joined(separator: "/") }
            return "win=\(w.title) \(type(of: v)) label=\(label)"
        case "geometry":
            // Window frame in screen points (AppKit, origin bottom-left), backing scale and the main screen height.
            let f = c.window.frame
            return "window=\(f.minX),\(f.minY),\(f.width),\(f.height) scale=\(c.window.backingScaleFactor) screen_h=\(NSScreen.screens.first?.frame.height ?? 0)"
        case "ax-terminal":
            // The terminal text area as the accessibility hierarchy exposes it (NSAccessibility tree walk from the
            // window, the same objects the AX server serialises). `ax-terminal text` prints the visible rows as JSON.
            func walk(_ e: Any, _ depth: Int) -> TerminalView? {
                guard depth < 14, let p = e as? NSAccessibilityProtocol else { return nil }
                if let v = e as? TerminalView, !v.isHidden, v.accessibilityRole() == .textArea, (v.accessibilityLabel() ?? "").hasPrefix("Terminal") { return v }
                for ch in p.accessibilityChildren() ?? [] { if let f = walk(ch, depth + 1) { return f } }
                return nil
            }
            guard let t = walk(c.window, 0) else { return "none" }
            if arg == "text" { return jsonString((t.accessibilityValue() as? String) ?? "") }
            return "role=AXTextArea label=\(t.accessibilityLabel() ?? "") chars=\(t.accessibilityNumberOfCharacters()) visible=\(NSStringFromRange(t.accessibilityVisibleCharacterRange()))"
        case "ax-tree": return axTree(dump: arg == "dump")
        case "ax-audit":
            // ax-audit [settings]: controls of the key window (or of the Settings window) without an accessibility label.
            let root = arg == "settings" ? c.settings.window.contentView : c.window.contentView
            var total = 0
            var bad: [String] = []
            audit(root, &total, &bad)
            if arg != "settings" { for sheet in c.window.sheets { audit(sheet.contentView, &total, &bad) } }
            else { for sheet in c.settings.window.sheets { audit(sheet.contentView, &total, &bad) } }
            return "controls=\(total) unlabelled=\(bad.count)" + (bad.isEmpty ? "" : "\n" + bad.joined(separator: "\n"))
        default: return nil
        }
    }

    /// Walks the views the way the Accessibility API sees them: every control that takes input or shows a
    /// list needs a label (or a title / value the system reads out).
    private func audit(_ v: NSView?, _ total: inout Int, _ bad: inout [String]) {
        guard let v, !v.isHidden, !(v is NSScroller) else { return }
        let isControl = v is NSControl && !(v is NSTextField && (v as! NSTextField).isEditable == false)
            || v is NSTableView || v is NSOutlineView || v is NSTextView && (v as! NSTextView).isEditable && !(v as! NSTextView).isFieldEditor
        if isControl, v.isAccessibilityElement() || v is NSTableView || v is NSOutlineView || v is NSTextView {
            total += 1
            var label = v.accessibilityLabel() ?? ""
            if label.isEmpty, let b = v as? NSButton { label = b.title }
            if label.isEmpty, let c = v as? NSSegmentedControl { label = (0 ..< c.segmentCount).compactMap { c.label(forSegment: $0) }.joined() }
            if label.isEmpty { bad.append("\(type(of: v)) in \(v.superview.map { "\(type(of: $0))" } ?? "-") frame=\(Int(v.frame.minX)),\(Int(v.frame.minY))") }
        }
        for s in v.subviews { audit(s, &total, &bad) }
    }
}
#endif
