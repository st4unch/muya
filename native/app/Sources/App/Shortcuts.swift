// P3: the AppKit side of the shortcut map (ShortcutLogic.swift): one key monitor for the window-level keys of
// today's App.tsx (capture phase), the File-menu actions of lib.rs (New File, Open, Close Tab, Reopen Closed Tab),
// the ⌘Q double press with its hint, terminal font size, and files handed over by Finder.

import AppKit

final class ShortcutRouter: NSObject {
    unowned let controller: MainController
    private var monitor: Any?
    private(set) var closed = ClosedTabs()
    private var quitGuard = QuitGuard()
    private var startup = StartupFiles()
    private var hint: QuitHintView?
    private var hintTimer: Timer?
    private(set) var fontSize = TerminalKeys.fontDefault

    init(controller: MainController) {
        self.controller = controller
        super.init()
    }

    func install() {
        // handle() returns nil for a key it used: `self?.handle(e) ?? e` turned that nil back into the event, so every handled ⌘ key
        // ALSO reached the window / terminal (⌘R wrote ^R twice, ⌘B toggled twice).
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.handle(e)
        }
        controller.store.onUserClose = { [weak self] s in
            guard let self, !self.reopening else { return }
            self.closed.push(.terminal(cwd: s.cwd, name: s.name))
        }
        TerminalView.onFontStep = { [weak self] d in self?.stepFont(d) }
        applyFont(controller.store.prefs.int("terminalFontSize"))
        TerminalSchemeState.set(controller.store.prefs.string("terminalScheme"))
    }

    private var overlayOpen: Bool { controller.palette.isOpen || controller.window.attachedSheet != nil }

    /// Returns nil when the key was used.
    func handle(_ e: NSEvent) -> NSEvent? {
        guard e.window === controller.window else { return e }
        let k = TerminalView.chord(e)
        let fr = controller.window.firstResponder
        if k.keyCode == VK.escape, controller.gridMode {
            let owns = fr is TerminalView || fr is NSText || fr is NSTextField
            if AppShortcuts.escapeLeavesGrid(k, overlayOpen: overlayOpen, focusIsTerminalOrField: owns) { controller.setGrid(false); return nil }
            return e
        }
        if let a = RailKeys.action(k), !overlayOpen, performRail(a) { return nil }   // ⌃⌥ arrows: the sessions rail; nothing else with ⌃⌥ is taken
        guard k.cmd, !overlayOpen else { return e }
        if k.chars == "s", !k.shift, !k.alt, !k.ctrl {
            let c = controller
            let path = c.viewerPath
            if AppShortcuts.commandSSaves(editorVisible: !c.viewer.isHidden && c.currentPage == nil, dirty: path.map { c.viewer.isDirty($0) } ?? false) { c.saveFile(); return nil }
        }
        if let a = AppShortcuts.action(k), perform(a) { return nil }
        // ⌘ keys a terminal owns: take them before the menu does (⌘C copy / ⌘A select-all would win otherwise).
        if let tv = fr as? TerminalView, tv.performKeyAction(k) { return nil }
        return e
    }

    @discardableResult
    func perform(_ a: AppShortcut) -> Bool {
        let c = controller
        switch a {
        case .selectAgent(let n):
            c.agentsPanel.reloadNow()
            let listed = c.agentsPanel.onScreenSessions   // ⌘N = the Nth agent as listed on screen (open splits, pinned, then the status sections)
            guard n <= listed.count else { return false }
            if c.currentPage != nil { c.showPage(nil) }
            c.store.select(listed[n - 1])
            return true
        case .reopenClosedTab: reopenClosedTab(); return true
        case .togglePalette: c.togglePalette(); return true
        case .toggleAgentsPanel: c.toggleSidebar(); return true
        case .toggleInspector: c.toggleInspector(); return true
        case .newTerminal: newTerminal(); return true
        case .maximizeGridPanel:
            guard c.gridMode else { return false }
            c.setGrid(false); return true
        case .splitTerminalArea:
            guard c.canSplitSelected else { return false }
            c.addSplitPane(); return true
        case .selectWorkspace: return false // no workspace scope in the native app yet
        }
    }

    // MARK: Actions (menu items and keys)

    /// ⌘T: a blank terminal in the selected session's folder (else home), shown in Control.
    @objc func newTerminal() {
        let c = controller
        let cwd = c.store.selected?.cwd ?? c.store.home
        c.store.spawn(cwd: cwd, name: nil)
        if c.currentPage != nil { c.showPage(nil) }
    }

    /// ⌘N: the save dialog, then an empty file opened in the viewer.
    @objc func newFile() {
        let panel = NSSavePanel()
        panel.title = "New File"
        panel.directoryURL = URL(fileURLWithPath: controller.store.selected?.cwd ?? controller.store.home)
        panel.beginSheetModal(for: controller.window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.createFile(url)
        }
    }

    @discardableResult
    func createFile(_ url: URL) -> Bool {
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { return false }
        open(url)
        return true
    }

    /// ⌘O: the open dialog; every chosen file opens.
    @objc func openFiles() {
        let panel = NSOpenPanel()
        panel.title = "Open"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: controller.store.selected?.cwd ?? controller.store.home)
        panel.beginSheetModal(for: controller.window) { [weak self] r in
            guard r == .OK else { return }
            for u in panel.urls { self?.open(u) }
        }
    }

    func open(_ url: URL) {
        controller.showPage(nil)
        controller.openViewer(url, FileKind.detect(url))
    }

    /// ⌘W: the file in view, else the selected session. Never the window.
    @objc func closeTab() {
        let c = controller
        if !c.viewer.isHidden {
            guard let p = c.viewerPath else { c.closeViewer(); return }
            c.closeFile(p) { [weak self] closedIt in if closedIt { self?.closed.push(.file(path: p)) } }
        } else if let s = c.store.selected {
            c.store.close(s)
        }
    }

    private var reopening = false
    /// ⌘⇧T: the newest closed tab comes back (a terminal in its folder, a file in the viewer).
    @objc func reopenClosedTab() {
        guard let t = closed.pop() else { return }
        switch t {
        case .file(let p): open(URL(fileURLWithPath: p))
        case .terminal(let cwd, let name):
            reopening = true; defer { reopening = false }
            controller.store.spawn(cwd: cwd, name: name)
            if controller.currentPage != nil { controller.showPage(nil) }
        }
    }

    // MARK: ⌘Q double press

    @objc func quitPressed() {
        let now = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
        switch quitGuard.press(nowMs: now) {
        case .quit: NSApp.terminate(nil)
        case .showHint: showQuitHint()
        }
    }

    var quitHintVisible: Bool { hint?.superview != nil }

    private func showQuitHint() {
        guard let host = controller.window.contentView else { return }
        hint?.removeFromSuperview()
        let h = QuitHintView(text: "Press ⌘Q again to quit")
        h.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(h)
        NSLayoutConstraint.activate([h.centerXAnchor.constraint(equalTo: host.centerXAnchor), h.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -44)])
        hint = h
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: false) { [weak self] _ in self?.hint?.removeFromSuperview(); self?.hint = nil }
    }

    // MARK: Font size

    func stepFont(_ delta: Int) { applyFont(TerminalKeys.steppedFont(fontSize, delta)) }

    func applyFont(_ requested: Int) {
        let n = min(TerminalKeys.fontMax, max(TerminalKeys.fontMin, requested == 0 ? TerminalKeys.fontDefault : requested))
        fontSize = n
        controller.store.prefs.set("terminalFontSize", n)
        controller.terminal.renderer.setPointSize(CGFloat(n))
        for t in controller.tileView.tiles { t.terminal.needsLayout = true; t.terminal.requestDraw() }
    }

    // MARK: Files from Finder (get_startup_files / apex://open-file)

    /// Paths from Finder: opened at once when the window is up, else kept for `windowReady`.
    func receive(paths: [String]) {
        for p in startup.offer(paths) { open(URL(fileURLWithPath: p)) }
    }

    func windowReady() {
        for p in startup.drain() { open(URL(fileURLWithPath: p)) }
    }
}

/// "Press ⌘Q again to quit": bottom centre, panel fill, strong border, mono 12 semibold (src/App.tsx quitHint).
final class QuitHintView: NSView {
    private let label: NSTextField
    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        label.font = ThemeFont.mono(12, .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text)
        recolor()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // pointer-events: none, it never blocks input
    override func viewDidChangeEffectiveAppearance() { recolor() }
    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.dynamic(.bgPanel).cgColor
            layer?.borderColor = Theme.dynamic(.borderStrong).cgColor
            label.textColor = Theme.dynamic(.textStrong)
        }
    }
}

extension MainController {
    /// The View menu's ⌘B item (`toggleSidebar` is not an Objective-C method).
    @objc func toggleAgentsPanel() { toggleSidebar() }
}
