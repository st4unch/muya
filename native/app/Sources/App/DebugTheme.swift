#if MUYA_TEST_HOOKS
// Test hooks for the design system (WP0): `gallery` opens a window that shows the bundled fonts, every colour token, the
// icon set and the shared kit parts, so they can be screenshot in both appearances. Exists only while MUYA_DEBUG_SOCKET is set.
//   gallery          open it (returns the window number for screencapture -l), `gallery-close` closes it
//   fonts            the PostScript names ThemeFont resolved ("sans=IBMPlexSans-Regular mono=JetBrainsMono-Regular")
import AppKit

private final class GalleryView: NSView {
    override var isFlipped: Bool { true }
    var buttons: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        func add(_ v: NSView, _ x: CGFloat, _ y: CGFloat, w: CGFloat? = nil, h: CGFloat? = nil) {
            let s = v.intrinsicContentSize
            v.frame = NSRect(x: x, y: y, width: w ?? (s.width > 0 ? s.width : 100), height: h ?? (s.height > 0 ? s.height : 24)); addSubview(v)
        }
        // kit parts (right column)
        var y: CGFloat = 372
        let lab = ThemedText.label("Appearance"); add(lab, 24, y, w: 200, h: 16); y += 22
        let seg = ThemedSegmented(options: ["System", "Light", "Dark"], selected: 2); add(seg, 24, y, w: 300, h: 36); y += 48
        add(ThemedText.title("Keep running when the window is closed"), 24, y, w: 300, h: 18)
        let sw1 = ThemedSwitch(isOn: true), sw2 = ThemedSwitch(isOn: false)
        add(sw1, 340, y); add(sw2, 380, y); y += 20
        add(ThemedText.helper("Sessions and schedules keep running; closing the window only hides it."), 24, y, w: 300, h: 34); y += 46
        add(ThemedButton("Cancel"), 24, y); add(ThemedButton("Launch agent", style: .primary), 100, y)
        add(ThemedButton("Delete", style: .danger, icon: .check), 230, y); add(ThemedButton("Add server", icon: .plus), 330, y); y += 46
        add(ThemedPill("Working · 4m 15s", fg: Theme.dynamic(.successText), bg: Theme.dynamic(.successBg), dot: Theme.dynamic(.success)), 24, y)
        add(ThemedPill("Bypass permissions on", fg: Theme.dynamic(.dangerText), bg: Theme.dynamic(.dangerPillBg)), 170, y)
        add(ThemedPill("Needs permission", fg: Theme.dynamic(.warningText), bg: Theme.dynamic(.warningBg), border: Theme.dynamic(.warningBorder)), 340, y)
        let box = ThemedBox(.rows); add(box, 24, y + 34, w: 200, h: 44)
        let card = ThemedBox(.card); add(card, 240, y + 34, w: 200, h: 44)
        let pop = ThemedBox(.popover); add(pop, 456, y + 34, w: 200, h: 44)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.dynamic(.bgApp).setFill(); bounds.fill()
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ f: NSFont, _ c: NSColor) { (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: f, .foregroundColor: c]) }
        text("IBM Plex Sans — 400 / 500 / 600 / 700", 24, 12, ThemeFont.sans(11, .semibold), Theme.dynamic(.textMuted))
        var y: CGFloat = 30
        for (w, n) in [(NSFont.Weight.regular, "Regular"), (.medium, "Medium"), (.semibold, "SemiBold"), (.bold, "Bold")] {
            text("\(n): Agents 3 · Working · Çağrı ğüşıöç 0123456789", 24, y, ThemeFont.sans(13, w), Theme.dynamic(.text)); y += 20
        }
        text("JetBrains Mono — 400 / 700", 24, y + 8, ThemeFont.sans(11, .semibold), Theme.dynamic(.textMuted)); y += 28
        text("let answer = 42; // ~/Documents/claude-control-plane", 24, y, ThemeFont.mono(13), Theme.dynamic(.text)); y += 20
        text("let answer = 42; // bold", 24, y, ThemeFont.mono(13, .bold), Theme.dynamic(.text)); y += 30
        // icons
        text("Icons (24 viewBox, stroke per web)", 24, y, ThemeFont.sans(11, .semibold), Theme.dynamic(.textMuted)); y += 20
        var x: CGFloat = 24
        for ic in ThemeIcon.allCases {
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState(); ctx.translateBy(x: x, y: y)
                ThemeIcons.draw(ic, in: ctx, size: 22, color: Theme.dynamic(.textSecondary)); ctx.restoreGState()
            }
            x += 32; if x > 760 { x = 24; y += 30 }
        }
        // token swatches (right of the kit parts)
        var sx: CGFloat = 480, sy: CGFloat = 372
        for t in Theme.Token.allCases.prefix(64) {
            if sy > 560 { sy = 372; sx += 60 }
            Theme.dynamic(t).setFill(); NSBezierPath(roundedRect: NSRect(x: sx, y: sy, width: 22, height: 14), xRadius: 3, yRadius: 3).fill()
            Theme.dynamic(.border).setStroke(); NSBezierPath(roundedRect: NSRect(x: sx + 0.5, y: sy + 0.5, width: 21, height: 13), xRadius: 3, yRadius: 3).stroke()
            sy += 18
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

extension DebugServer {
    func runTheme(_ cmd: String, _ arg: String) -> String? {
        switch cmd {
        case "gallery":
            let win = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 780, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = "Muya design system"; win.isReleasedWhenClosed = false
            win.contentView = GalleryView(frame: NSRect(x: 0, y: 0, width: 780, height: 680))
            win.makeKeyAndOrderFront(nil)
            DebugServer.gallery = win
            return "\(win.windowNumber)"
        case "composer":   // composer <text>: puts the text into the message box and presses Return in it ("composer" alone = placeholder + chips)
            let c = controller
            if arg.isEmpty { return "shown=\(!c.composer.isHidden) placeholder=\(c.composer.text.placeholder) bar=\(!c.sessionBar.isHidden)" }
            c.window.makeFirstResponder(c.composer.text)
            c.composer.text.string = arg; c.composer.text.send(); return "ok"
        case "rail":   // rail <Control|Files|Sessions|Queue|Kanban|Resources|SSH|Schedules>: what a click on the rail item does
            guard let item = RailItem(rawValue: arg) else { return "error: rail <item>" }
            controller.railSelected(item); return "ok \(controller.frameView.rail.active?.rawValue ?? "-")"
        case "dialog":   // dialog broadcast | rename <name> | confirm | text <t> | press | close | state
            return MainActor.assumeIsolated {
                let c = controller, d = Dialogs.shared
                let w = arg.split(separator: " ", maxSplits: 1).map(String.init), sub = w.first ?? "", rest = w.count > 1 ? w[1] : ""
                switch sub {
                case "broadcast": c.broadcastDialog(); return "ok"
                case "command": c.commandDialog(); return "ok"
                case "command-target": d.debugCommandTarget(Int(rest) ?? 0); return "ok"
                case "rename": if let s = c.store.selected { c.renameDialog(s) }; return "ok"
                case "confirm": d.confirm(over: c.window, title: "Delete file?", message: "This moves the file to the Trash.", confirmTitle: "Delete", danger: true) { print("confirmed") }; return "ok"
                case "text": d.setText(rest); return "ok"
                case "press": d.pressPrimary(); return "ok"
                case "close": d.dismiss(); return "ok"
                default: return "open=\(d.isOpen)"
                }
            }
        case "session-menu": return controller.store.selected.map { controller.sessionMenu(for: $0).items.map(\.title).joined(separator: "|") } ?? "none"
        case "drop": controller.frameView.showDropOverlay(arg == "show"); if arg != "show" && arg != "hide" { controller.frameView.onDrop?([URL(fileURLWithPath: arg)]) }; return "ok"
        case "dump-views":   // dump-views [thin]: every visible view of the main window with its window-relative frame ("thin": only splits and 1-2 px wide/tall views)
            guard let root = controller.window.contentView else { return "none" }
            var out: [String] = []
            func walk(_ v: NSView, _ depth: Int) {
                let f = v.convert(v.bounds, to: nil)
                let thin = f.width <= 2.5 || f.height <= 2.5
                let isSplit = v is NSSplitView
                if !v.isHidden, arg != "thin" || thin || isSplit {
                    out.append("\(String(repeating: " ", count: depth))\(type(of: v)) x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))" + (isSplit ? " divider=\((v as! NSSplitView).dividerThickness) hidden-subviews=\((v as! NSSplitView).arrangedSubviews.filter(\.isHidden).count)" : ""))
                }
                for c in v.subviews where !v.isHidden { walk(c, depth + 1) }
            }
            walk(root, 0)
            return out.joined(separator: "\n")
        case "terminal-scheme": controller.setTerminalScheme(arg); return "scheme=\(TerminalSchemeState.id) pref=\(controller.store.prefs.string("terminalScheme")) bg=\(String(TerminalTheme.current(for: controller.window.effectiveAppearance).background.hexValue, radix: 16))"
        case "appearance-popover": controller.appearancePopover(NSRect(x: controller.frameView.footer.bounds.maxX - 120, y: 0, width: 24, height: 24)); return "ok"
        case "term-find":   // term-find <query>: opens the bar, searches, returns the state; "term-find next|prev|close" steps
            let t = controller.terminal
            switch arg {
            case "next": t.runFind(t.findBar?.field.stringValue ?? "", step: true)
            case "prev": t.runFind(t.findBar?.field.stringValue ?? "", step: false)
            case "close": t.hideFind()
            default: t.showFind(); t.findBar?.field.stringValue = arg; t.runFind(arg, step: nil)
            }
            return t.findState()
        case "term-menu": return controller.terminal.contextMenu().items.map { $0.isSeparatorItem ? "-" : ($0.isEnabled ? "" : "(off)") + $0.title }.joined(separator: "|")
        case "term-paste-path":   // term-paste-path <clipboard text>: puts it on the clipboard and pastes it as a path
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(arg.replacingOccurrences(of: "\\n", with: "\n"), forType: .string)
            controller.terminal.pasteAsPath(); return "ok"
        case "term-clear-scrollback":
            let before = controller.terminal.session?.replica.scrollState.history ?? -1
            controller.terminal.clearScrollback()
            return "history before=\(before) after=\(controller.terminal.session?.replica.scrollState.history ?? -1)"
        case "status-fields":   // status-fields <id,id,…>: pins the fields, reads the selected session's status JSON now, returns the footer pairs
            controller.store.prefs.set("statusFields", arg.split(separator: ",").map(String.init))
            controller.pollStatus()
            return "ok"
        case "footer-composer": controller.frameView.footer.onComposer?(); return "composerOpen=\(controller.frameView.footer.composerOpen)"   // the footer's chat icon, without a click
        case "footer-height": return "\(Int(controller.frameView.footer.frame.height))"
        case "status-footer": return controller.frameView.footer.fields.map { "\($0.0)=\($0.1)" }.joined(separator: "|")
        case "toast-panels": let ps = NSApp.windows.filter { $0.identifier?.rawValue == "toast-lift" }; return "panels=\(ps.count) visible=\(ps.filter(\.isVisible).count) appActive=\(NSApp.isActive)"
        case "app-activate": NSApp.activate(ignoringOtherApps: true); return "appActive=\(NSApp.isActive)"
        case "toast-lift": ModalScrim.liftsToasts = arg != "off"; return "toastLift=\(ModalScrim.liftsToasts)"
        case "session-collapse": controller.sessionBar.collapseToggle.onClick?(); return "collapsed=\(controller.sessionBar.collapsed)"
        case "mode-menu": return PermissionModes.items.map(\.label).joined(separator: "|") + " current=" + (controller.store.selected?.screen?.mode ?? "-")
        case "window-rect":   // main window on screen as "x y w h" with a top-left origin (for screencapture -R, which also catches popovers and child windows)
            let f = controller.window.frame, h = NSScreen.screens.first?.frame.height ?? 0
            return "\(Int(f.minX)) \(Int(h - f.maxY)) \(Int(f.width)) \(Int(f.height))"
        case "ssh-section":   // ssh-section servers|psmp|cyberark|vault
            let m: [String: SSHSection] = ["servers": .servers, "psmp": .psmp, "cyberark": .cyberark, "vault": .vault]
            guard let sec = m[arg] else { return "error: ssh-section servers|psmp|cyberark|vault" }
            return MainActor.assumeIsolated { controller.sshPage.select(sec); return "ok" }
        case "ssh-reload":   // what the page's Retry button does
            return MainActor.assumeIsolated { controller.sshPage.reloadAll(); return "ok" }
        case "ssh-unlock":   // ssh-unlock: what "Unlock…" does (Touch ID if set up, else the sheet)
            return MainActor.assumeIsolated { controller.sshPage.unlockStore(); return "ok" }
        case "ssh-state":   // ssh-state: the section, the pane's message and the open form (secure fields shown as •)
            return MainActor.assumeIsolated { let h = controller.sshPage; return h.debugState() + (h.openForm.map { "\n--form--\n" + $0.debugState() } ?? "") }
        case "ssh-form":   // ssh-form set <id> <value> | submit | cancel
            let p = arg.split(separator: " ", maxSplits: 2).map(String.init)
            return MainActor.assumeIsolated {
                guard let f = controller.sshPage.openForm else { return "error: no form open" }
                switch p.first ?? "" {
                case "set" where p.count == 3: f.set(p[1], p[2]); return "ok"
                case "submit": f.submitTapped(); return "ok"
                case "cancel": f.cancelTapped(); return "ok"
                default: return "error: ssh-form set <id> <value> | submit | cancel"
                }
            }
        case "resources-tab":   // resources-tab skills|agents|hooks|mcps|marketplace
            guard let t = ResourceTab.allCases.first(where: { $0.title.lowercased() == arg }) else { return "error: resources-tab skills|agents|hooks|mcps|marketplace" }
            return MainActor.assumeIsolated { controller.resourcesPage.select(tab: t); return "ok" }
        case "gallery-close": DebugServer.gallery?.close(); DebugServer.gallery = nil; return "ok"
        case "fonts":
            return "sans=\(ThemeFont.sans(13).fontName) bold=\(ThemeFont.sans(13, .bold).fontName) mono=\(ThemeFont.mono(13).fontName)"
        default: return nil
        }
    }
    nonisolated(unsafe) static var gallery: NSWindow?
}
#endif
