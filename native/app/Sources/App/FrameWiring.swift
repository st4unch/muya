// Connects the WP1 frame (Frame.swift) to the controller: rail → pages, header buttons → palette / theme / panels, footer text
// from the store. Everything is pushed from existing events (updateChrome, showPage) except FrameStats' 5 s timer.

import AppKit

extension MainController {
    func wireFrame() {
        wireSplit()
        let f = frameView!
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollStatus() } }
        f.rail.onSelect = { [weak self] item in self?.railSelected(item) }
        f.rail.onSettings = { [weak self] in self?.openSettings() }
        f.header.onSearch = { [weak self] in self?.togglePalette() }
        f.header.onWorkspace = { [weak self] r in self?.workspaceMenu(r) }
        f.header.onDoubleClick = { [weak self] in self?.titleBarDoubleClick() }
        f.header.sidebarToggle.onClick = { [weak self] in self?.toggleSidebar() }
        f.header.inspectorToggle.onClick = { [weak self] in self?.toggleInspector() }
        f.header.themeButton.onClick = { [weak self] in self?.cycleTheme() }
        f.header.bellButton.onClick = { [weak self] in self?.showNotifications() }
        sessionsPage.termHistoryLoader = { [weak self] done in
            guard let self else { return }
            if self.store.mockMode { done([]); return }
            MainActor.assumeIsolated { self.resourcesService.termHistory { r in if case let .success(l) = r { done(l) } else { done([]) } } }
        }
        agentsPanel.home = store.home
        composer.onModeMenu = { [weak self] anchor in self?.modeMenu(anchor) }
        sessionBar.collapsed = store.prefs.bool("muya.sessionHeaderCollapsed")
        sessionBar.onToggleCollapse = { [weak self] on in self?.store.prefs.set("muya.sessionHeaderCollapsed", on) }
        f.header.onExitGrid = { [weak self] in self?.setGrid(false) }
        f.header.onLayout = { [weak self] c in GridState.layout = c; GridState.picked = nil; self?.refreshTiles() }
        f.header.onWaitingFirst = { [weak self] in GridState.waitingFirst.toggle(); GridState.picked = nil; self?.refreshTiles() }
        f.header.onBroadcast = { [weak self] in self?.broadcastDialog() }
        Tile.onExitResume = { [weak self] s in self?.store.relaunch(s) }
        Tile.onExitClose = { [weak self] s in self?.store.close(s) }
        Tile.onFullscreen = { [weak self] s in self?.store.select(s); self?.setGrid(false) }
        Tile.onSend = { [weak self] s, t in self?.store.select(s); self?.store.paste(t); self?.store.sendKey("enter", mods: 0) }
        Tile.onAlways = { [weak self] id in
            guard let self, let s = self.store.sessions.first(where: { $0.id == id }), s.exited == nil, let k = s.screen?.alwaysKey else { return }
            self.store.select(s)
            self.store.answerVerified(session: id, promptKey: s.screen?.promptKey ?? "", choice: .key(k, index: s.screen?.alwaysIndex ?? 0))
        }
        Tile.onChoose = { [weak self] session, anchor in   // the name's chevron: choose the session shown in this panel
            guard let self else { return }
            let m = NSMenu()
            for s in self.store.sessions {
                let it = BlockMenuItem(title: s.name) { [weak self] in
                    GridState.picked = GridPlan.assign(GridState.shownIds, targetIndex: GridState.shownIds.firstIndex(of: session.id), pick: s.id); self?.refreshTiles()
                }
                it.state = s.id == session.id ? .on : .off
                m.addItem(it)
            }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }
        EmptyPanelView.assignHandler = { [weak self] in self?.showPage(self?.queuePage); self?.queuePage.select(tab: .queue) }
        EmptyPanelView.swapHandler = { [weak self] anchor in
            guard let self else { return }
            let m = NSMenu()
            for s in self.store.sessions where !GridState.shownIds.contains(s.id) {
                m.addItem(BlockMenuItem(title: s.name) { [weak self] in
                    GridState.picked = GridPlan.assign(GridState.shownIds, targetIndex: nil, pick: s.id); self?.refreshTiles()
                })
            }
            if m.items.isEmpty { let none = NSMenuItem(title: "No other sessions", action: nil, keyEquivalent: ""); none.isEnabled = false; m.addItem(none) }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }
        agentsPanel.pinned = { [unowned self] in Set(pinnedNames()) }
        Tile.sessionMenuProvider = { [weak self] s in self?.sessionMenu(for: s) ?? NSMenu() }
        f.footer.onAppearance = { [weak self] rect in self?.appearancePopover(rect) }
        f.footer.onComposer = { [weak self] in guard let self else { return }; self.store.prefs.set("muya.composerOpen", !(((self.store.prefs.get("muya.composerOpen") as? Bool) ?? true))); self.refreshFrame(); self.refreshTiles() }
        f.footer.onFields = { [weak self] rect in self?.fieldsPopover(rect) }
        Toasts.center = ToastCenter(host: window.contentView)
        Toasts.center.topInset = { [unowned self] in MainActor.assumeIsolated { autoAllowSuggest.isShown } ? 204 : 66 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.checkStorageHeadsUp() }
        agentsPanel.sessions = { [unowned self] in store.scopedSessions }
        agentsPanel.selected = { [unowned self] in store.selected }
        agentsPanel.onSelect = { [weak self] s in self?.filesMode = false; self?.store.select(s); self?.showPage(nil); self?.window.makeFirstResponder(self?.terminal) }
        agentsPanel.onSynced = { [weak self] in self?.syncRail() }
        f.rail.onPickSession = { [weak self] id in self?.railPick(id) }
        f.rail.onFlip = { [weak self] p in self?.railFlip(p) }
        agentsPanel.onClose = { [weak self] s in self?.store.close(s) }
        agentsPanel.onNew = { [weak self] in self?.newSession() }
        agentsPanel.onRename = { [weak self] s in self?.renameDialog(s) }
        agentsPanel.menuFor = { [weak self] s in self?.sessionMenu(for: s) ?? NSMenu() }
        sessionBar.onMore = { [weak self] anchor in
            guard let self, let s = self.store.selected else { return }
            self.sessionMenu(for: s).popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }
        sessionBar.onBroadcast = { [weak self] in self?.broadcastDialog() }
        frameView.onDrop = { [weak self] urls in self?.dropped(urls) }
        sessionBar.onGrid = { [weak self] in self?.toggleGrid() }
        sessionBar.onStop = { [weak self] in self?.store.sendKey("escape", mods: 0) }
        sessionBar.onCommand = { [weak self] in self?.commandDialog() }
        composer.onSend = { [weak self] t in self?.store.paste(t); self?.store.sendKey("enter", mods: 0) }
        composer.onSlash = { [weak self] in self?.toggleSlash() }
        composer.onFiles = { [weak self] urls in self?.composer.text.insertText(urls.map { "@" + $0.path }.joined(separator: " ") + " ", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        composer.onEscape = { [weak self] in self?.window.makeFirstResponder(self?.terminal) }
        frameStats.onUpdate = { [weak f] cpu, ram, clock in f?.header.stats.text = "CPU \(cpu)%  RAM \(ram) MB  \(clock)" }
        frameStats.start()
        refreshFrame()
    }

    func railSelected(_ item: RailItem) {
        switch item {
        case .control: filesMode = false; showPage(nil)
        case .files:
            filesMode = true; showPage(nil)   // the tree keeps whatever open/closed state the FILES header was left in (one shared state, like FilesSection.tsx)
            if let host = viewer.superview {
                if filesHome.superview == nil { filesHome.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(filesHome, positioned: .below, relativeTo: viewer); Kit.pin(filesHome, in: host) }
            }
            refreshFrame()
        case .sessions: showPage(sessionsPage)
        case .queue: showPage(queuePage); queuePage.select(tab: .queue); refreshFrame()
        case .kanban: showPage(queuePage); queuePage.select(tab: .kanban); refreshFrame()   // the rail follows the tab, which is set after the page is shown
        case .resources: showPage(resourcesPage)   // not showResources(): that one toggles, a rail click on the active item must stay
        case .ssh: showPage(sshPage)
        case .schedules: showPage(schedulesPage)
        }
    }

    /// The panel has come or gone and the split has settled: save what is true now (open/closed; the widths were kept while it moved).
    func unlockPanelLayout() { panelLayoutLocked = false; onPanelLayoutSettled?() }

    func toggleSidebar() {
        sidebarCollapsed.toggle()
        refreshFrame()
    }

    func cycleTheme() {
        let order = ["System", "Light", "Dark"], cur = store.prefs.string("appearance")
        let next = order[((order.firstIndex(of: cur) ?? 0) + 1) % 3]
        store.prefs.set("appearance", next)
        SettingsController.applyAppearance(next)
        refreshFrame()
    }

    func showNotifications() {
        if let p = notificationsPopover, p.isShown { p.close(); return }
        let p = NotificationsPopover.make()
        notificationsPopover = p
        p.onClose = { [weak self] in self?.notificationsPopover = nil }
        p.show(in: window, anchor: frameView.header.bellButton, edge: .belowTrailing)
    }

    /// Pushes the current state into rail highlight, header and footer.
    func refreshFrame() {
        guard let f = frameView else { return }
        let page = currentPage
        filesHome.isHidden = !ScreenRoute(page: page == nil ? nil : "page", filesMode: filesMode).filesScreenVisible
        filesHome.count = viewer.isHidden ? 0 : 1
        f.rail.active = page == nil ? (filesMode ? .files : .control) : page === sessionsPage ? .sessions : page === schedulesPage ? .schedules : page === sshPage ? .ssh
            : page === queuePage ? (queuePage.tab == .kanban ? .kanban : .queue) : (String(describing: type(of: page!)).contains("Resources") ? .resources : nil)
        // Pages (Sessions, Queue, SSH …) take the whole width in today's Muya: the agents panel is only beside the terminals.
        if let side = rootSplit.arrangedSubviews.first {
            let hide = sidebarCollapsed || currentPage != nil || gridMode   // the grid takes the width, like today's GridScreen
            if side.isHidden != hide {
                panelLayoutLocked = true   // the split resizes itself while the panel goes or comes: not the operator's choice, do not save it (Prefs.saveLayout)
                side.isHidden = hide; rootSplit.adjustSubviews(); rootSplit.needsDisplay = true
                if !hide { rootSplit.setPosition(PanelPrefs.agentsWidth(store.legacy, window: rootSplit.bounds.width), ofDividerAt: 0) }
                if hide { DispatchQueue.main.async { [weak self] in self?.unlockPanelLayout() } }
                if !hide {   // back from the grid / a page: once the split has laid out again, the panels get their saved widths
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        defer { DispatchQueue.main.async { self.unlockPanelLayout() } }
                        guard !self.gridMode, !self.sidebarCollapsed else { return }
                        self.rootSplit.layoutSubtreeIfNeeded()
                        self.rootSplit.setPosition(PanelPrefs.agentsWidth(self.store.legacy, window: self.rootSplit.bounds.width), ofDividerAt: 0)
                        if let split = self.inspector.superview as? InspectorSplit, !self.inspector.isHidden,
                           let w = PrefCodec.number(self.store.legacy.get(PrefKeys.inspectorWidth), min: PrefKeys.inspectorWidthRange.min, max: PrefKeys.inspectorWidthRange.max) {
                            split.layoutSubtreeIfNeeded(); split.setPosition(max(split.bounds.width - CGFloat(w), 320), ofDividerAt: 0)
                        }
                    }
                }
            }
        }
        f.header.sidebarToggle.toolTip = sidebarCollapsed ? "Show sidebar" : "Hide sidebar"
        agentsPanel.reload()
        let single = !gridMode && store.selected != nil
        let composerOpen = (store.prefs.get("muya.composerOpen") as? Bool) ?? true
        f.footer.composerOpen = composerOpen; Tile.composerOpen = composerOpen
        sessionBar.setShown(single); composer.setShown(single && composerOpen)
        sessionBar.configure(store.selected, home: store.home)
        sessionBar.setSplitEnabled(canSplitSelected)
        f.header.gridPanels = gridMode ? GridState.shownIds.count : nil
        f.header.layoutTabs.selected = GridChoice.allCases.firstIndex(of: GridState.layout) ?? 2
        f.footer.hint = gridMode ? "Tab to switch panels · ⌘↵ maximize" : ""
        composer.configure(store.selected)
        statusStrip.configure(single ? store.selected : nil, updateReady: (store.mockMode && single) || UpdateCenter.available != nil, composerOpen: composerOpen)
        sidebar?.count = { [unowned self] in store.mockMode ? 3 : Set(store.sessions.map(\.cwd)).count }
        sidebar?.openFiles.onOpen = { [weak self] p in self?.files.onOpen?(URL(fileURLWithPath: p), FileKind.detect(URL(fileURLWithPath: p))) }
        sidebar?.openFiles.onClose = { [weak self] p in self?.closeFile(p) }
        viewer.onDirtyChange = { [weak self] in guard let self else { return }; self.sidebar?.openFiles.dirty = Set(self.viewer.dirtyPaths) }
        viewer.autoSaveEnabled = { [weak self] in self?.store.prefs.bool("autoSave") ?? false }
        f.header.workspace = WorkspaceScope.chipLabel(scope: store.selectedRoot, hasSessions: !store.sessions.isEmpty)
        let pref = store.prefs.string("appearance")
        f.header.themeButton.icon = pref == "Light" ? .themeSun : pref == "Dark" ? .themeMoon : .themeMonitor
        f.header.themeButton.toolTip = "Theme: \(pref.isEmpty ? "System" : pref)"
        f.header.themeButton.setAccessibilityLabel(f.header.themeButton.toolTip)
        let sessions = store.sessions
        let working = sessions.filter { $0.exited == nil && $0.screen?.working == true }.count
        let waiting = sessions.filter { $0.screen?.permission == true }.count
        var parts = ["\(sessions.count) session\(sessions.count == 1 ? "" : "s")"]
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        f.footer.left = parts.joined(separator: " · ")
        f.footer.ready = store.connected
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        f.footer.right = "UTF-8"; f.footer.version = "v\(v)"
        f.footer.fields = chosenFields().compactMap { id in StatusFieldCatalog.byId[id].flatMap { d in StatusFieldCatalog.value(id, statusData).map { (d.label, $0) } } }
        if store.mockMode {   // same numbers as src/mock (ui-diff compares style, not content)
            MainActor.assumeIsolated { autoAllowSuggest.sessionsChanged() }   // the "Turn on Auto-allow?" toast of the reference
            frameStats.stop(); f.header.stats.text = "CPU 2%  RAM 111 MB  23:21"
            f.header.workspace = "claude-control-plane  · 3"
            f.footer.left = "3 workspaces     7 agents · 2 working · 1 waiting     0 conflicts"
        }
    }

    // MARK: P5 dialogs, menus, drop

    func renameDialog(_ s: SessionModel) {
        Dialogs.shared.rename(over: window, current: s.name) { [weak self] name in self?.store.rename(s, to: name) }
    }

    /// Sends one message to every panel of the grid: select, paste, Return, then back to the original selection.
    func broadcastDialog() {
        let ids = GridLayout.visible(ids: store.scopedSessions.map(\.id), selected: store.selected?.id)
        let targets = ids.compactMap { id in store.sessions.first { $0.id == id } }.filter { $0.exited == nil }
        Dialogs.shared.broadcast(over: window, panels: targets.count) { [weak self] text in
            guard let self else { return }
            let keep = self.store.selected
            for s in targets { self.store.select(s); self.store.paste(text); self.store.sendKey("enter", mods: 0) }
            self.store.select(keep)
        }
    }

    /// The header's "Command" button and ⌘⇧K: text or a slash command to this session, its split group, some sessions or all of them.
    /// The daemon types it with the broker's tracked delivery (`sessions.send_command`); the dialog then lists what happened per session.
    @objc func commandDialog() {
        MainActor.assumeIsolated {
            guard !Dialogs.shared.isOpen else { return }
            let candidates = store.sessions.map { CommandCandidate(id: $0.id, name: $0.name, isAgent: $0.screen?.modeDetected == true || $0.kind == "claude", exited: $0.exited != nil) }
            let cur = store.selected
            let groupIds = splitModel.group(of: cur).map { $0.keys.compactMap(UInt64.init) }
            Dialogs.shared.command(over: window, current: cur?.id, groupIds: groupIds, candidates: candidates) { [weak self] text, ids, done in
                guard let self else { return }
                let asked = candidates.filter { ids.contains($0.id) }
                _ = self.store.call("sessions.send_command", ["ids": ids.map { NSNumber(value: $0) }, "text": text]) { r in
                    switch r {
                    case let .success(v): done(CommandResult.parse(v))
                    case let .failure(e): done(CommandResult.allFailed(asked, reason: "\(e)"))
                    }
                }
            }
        }
    }

    /// "Schedule…" on a session: the schedule editor, pre-filled to type into THAT session at the chosen time.
    func openSessionSchedule(_ s: SessionModel) {
        guard s.exited == nil else { return }
        schedulesPage.openEditor(nil, target: ScheduleTarget(id: s.id, name: s.name, cwd: s.cwd))
    }

    /// The session menu of today's Muya (agent card right-click, header "…"): Rename…, Duplicate, Reveal in Finder, Schedule…, Close agent.
    func sessionMenu(for s: SessionModel) -> NSMenu {
        let m = NSMenu()
        func item(_ title: String, red: Bool = false, _ run: @escaping () -> Void) {
            let i = BlockMenuItem(title: title, run: run)
            if red { i.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: Theme.dynamic(.dangerText)]) }
            m.addItem(i)
        }
        let pinnedNow = pinnedNames().contains(s.name)
        item(pinnedNow ? "Unpin" : "Pin") { [weak self] in self?.togglePin(s) }
        item("Rename…") { [weak self] in self?.renameDialog(s) }
        item("Duplicate") { [weak self] in self?.store.spawn(cwd: s.cwd, name: "\(s.name) (copy)") }
        item("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)]) }
        item("Schedule…") { [weak self] in self?.openSessionSchedule(s) }
        m.addItem(.separator())
        item("Close agent", red: true) { [weak self] in self?.store.close(s) }
        return m
    }

    /// Files dropped on the window open in the viewer (the first one), like today's drop handler.
    func dropped(_ urls: [URL]) {
        // Regular files only (stat does not open, so a dropped FIFO / device cannot block here); the viewer reads off the main thread.
        guard let u = urls.first(where: { FileProbe.isRegular($0.path) }) else { return }
        showPage(nil); openViewer(u, FileKind.detect(u))
    }
}

/// A menu item that runs a closure.
final class BlockMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

// MARK: Pin, footer popovers, toasts

enum Toasts { nonisolated(unsafe) static var center: ToastCenter! }

extension MainController {
    func pinnedNames() -> [String] { (store.prefs.get("pinnedAgents") as? [String]) ?? [] }
    func togglePin(_ s: SessionModel) {
        var p = pinnedNames()
        if let i = p.firstIndex(of: s.name) { p.remove(at: i) } else { p.append(s.name) }
        store.prefs.set("pinnedAgents", p); refreshFrame()
    }

    /// The pinned footer fields as ids (today's muya.footer.statusFields); labels from the first native build are mapped.
    func chosenFields() -> [String] { StatusFieldCatalog.normalize((store.prefs.get("statusFields") as? [String]) ?? []) }

    /// Status JSON of the selected session: what Claude's status tap wrote (`statusline.session` of muyad); the dev mock seeds one.
    func mockStatusData() -> [String: Any] {
        ["model": ["display_name": "Opus", "id": "claude-opus-5-5"], "effort": ["level": "high"], "version": "2.1.260",
         "context_window": ["used_percentage": 42, "remaining_percentage": 58, "context_window_size": 200_000, "total_input_tokens": 16_900, "total_output_tokens": 1_200,
                            "current_usage": ["input_tokens": 8_500, "output_tokens": 1_200, "cache_creation_input_tokens": 5_000, "cache_read_input_tokens": 3_400]],
         "exceeds_200k_tokens": false]
    }

    /// Polls the selected session's status JSON while fields are pinned (or the picker is open); the footer repaints when it changed.
    func pollStatus() {
        guard !chosenFields().isEmpty || fieldPicker != nil else { statusData = nil; statusSid = nil; return }
        if store.mockMode { if statusData == nil { statusData = mockStatusData(); refreshFrame() }; return }
        guard let s = store.selected else { if statusData != nil { statusData = nil; refreshFrame() }; return }
        if statusSid != s.id { statusSid = s.id; statusData = nil }
        let sid = s.id
        store.call("statusline.session", ["sid": sid]) { [weak self] r in
            guard let self, self.statusSid == sid else { return }
            var d: [String: Any]?
            if case let .success(v) = r { d = v as? [String: Any] }
            if (d as NSDictionary?) != (self.statusData as NSDictionary?) { self.statusData = d; self.refreshFrame() }
        }
    }

    func appearancePopover(_ rect: NSRect) {
        let sh = delegate.shortcuts!
        appearancePop = AppearancePopover.show(in: window, from: frameView.footer, rect: rect, size: sh.fontSize, spacing: Double(terminal.renderer.shared.lineSpacing), scheme: TerminalSchemeState.id,
                               onSize: { n in sh.applyFont(n) },
                               onSpacing: { [weak self] l in
                                   guard let self else { return }
                                   self.store.prefs.set("terminalLineSpacing", l)
                                   self.terminal.renderer.setLineSpacing(CGFloat(l))
                                   for t in self.tileView.tiles { t.terminal.needsLayout = true; t.terminal.requestDraw() }
                               },
                               onScheme: { [weak self] id in self?.setTerminalScheme(id) })
    }

    /// Colour scheme of every terminal (muya.terminalPrefs.scheme): remembered, and all terminals + their padding repaint.
    func setTerminalScheme(_ id: String) {
        guard TerminalSchemeState.isValid(id) else { return }
        store.prefs.set("terminalScheme", id)
        TerminalSchemeState.set(id)
    }

    func fieldsPopover(_ rect: NSRect) {
        let picker = FieldPickerController(chosen: chosenFields(), data: statusData) { [weak self] list in
            self?.store.prefs.set("statusFields", list); self?.refreshFrame()
        }
        fieldPicker = picker
        picker.onClose = { [weak self] in self?.fieldPicker = nil }
        picker.show(from: frameView.footer, rect: rect)
    }

    /// Once a day, only when Claude's saved sessions are heavy (today's StorageHeadsUp).
    func checkStorageHeadsUp() {
        let today = StorageHeadsUpLogic.dayKey(Date())
        if store.mockMode { return }   // the reference shows only the Auto-allow toast
        guard store.prefs.string("storageHeadsUpDay") != today else { return }
        let show: ([HistoryEntry]) -> Void = { [weak self] entries in
            guard let self else { return }
            let sm = StorageHeadsUpLogic.summary(entries, now: Date())
            guard StorageHeadsUpLogic.heavy(sm) else { return }
            self.store.prefs.set("storageHeadsUpDay", today)
            Toasts.center.show(title: "Claude's saved sessions are getting big", message: StorageHeadsUpLogic.text(count: sm.count, bytes: sm.bytes, old: sm.old, big: sm.big),
                               actions: [("Not now", false, {}), ("Clean up…", true, { [weak self] in self?.showPage(self?.sessionsPage); self?.sessionsPage.openCleanup() })])
        }
        _ = store.call("sessions.history") { r in if case let .success(v) = r { show(jsonObjects(v).compactMap(HistoryEntry.init(json:))) } }
    }
}

// MARK: Header: Workspace menu and title-bar double-click

extension MainController {
    #if MUYA_TEST_HOOKS
    nonisolated(unsafe) static var menuHook: ((NSMenu) -> Void)?
    nonisolated(unsafe) static var menuAutoCancel: TimeInterval = 0
    #endif
    /// The "Workspace <name> ⌄" menu (src/App.tsx "workspaces" menu): "All workspaces", then the folders the sessions work in.
    /// Choosing one sets the workspace scope (Store.selectedRoot); the tick follows the scope, not the selected session.
    var workspaceRows: [WorkspaceMenuLogic.Row] { WorkspaceMenuLogic.rows(cwds: store.sessions.map(\.cwd), keep: store.selectedRoot) }

    /// The menu as titles ("-" = separator, "✓ " = ticked), for the menu and the debug socket alike. `digit` is the ⌥⌘
    /// shortcut; the menu gives it to AppKit as a key equivalent so macOS draws it right-aligned, as every other menu does.
    func workspaceMenuModel() -> [(title: String, hint: String, digit: Int?, on: Bool, root: String?, action: Bool)] {
        let rows = workspaceRows
        var out: [(title: String, hint: String, digit: Int?, on: Bool, root: String?, action: Bool)] = []
        let agents: (Int) -> String = { "\($0) agent\($0 == 1 ? "" : "s")" }
        if !rows.isEmpty {
            out.append(("All workspaces   \(agents(store.sessions.count))", "⌥⌘0", 0, store.selectedRoot == nil, nil, true))
        }
        for (i, r) in rows.enumerated() {
            out.append(("\(r.title)   \(agents(r.count)) · \(r.path.abbreviatingHome(store.home))", i < 9 ? "⌥⌘\(i + 1)" : "", i < 9 ? i + 1 : nil, r.path == store.selectedRoot, r.path, true))
        }
        return out
    }

    /// Chooses the scope (nil = all). The selection moves only when it falls out of the new scope (classic App.tsx:613).
    func chooseWorkspace(_ root: String?) {
        store.selectedRoot = root
        store.legacy.set(PrefKeys.selectedRoot, root)
        showPage(nil)
        if let sel = store.selected, !store.scopedSessions.contains(where: { $0 === sel }), let first = store.scopedSessions.first { store.select(first) }
        agentsPanel.reloadNow()
        refreshFrame()
    }

    /// ⌥⌘1-9 / ⌥⌘0 and the debug socket: the Nth row as listed, nil = all. False when there is no such row.
    @discardableResult
    func chooseWorkspace(digit: Int?) -> Bool {
        switch WorkspaceScope.pick(digit: digit, rows: workspaceRows.map(\.path)) {
        case .all: chooseWorkspace(nil)
        case .root(let r): chooseWorkspace(r)
        case .none: return false
        }
        return true
    }

    func workspaceMenu(_ chip: NSRect) {
        let m = NSMenu(title: "Workspaces")
        let head = NSMenuItem(title: "WORKSPACES", action: nil, keyEquivalent: ""); head.isEnabled = false; m.addItem(head)
        let model = workspaceMenuModel()
        if model.isEmpty { let e = NSMenuItem(title: "No workspace yet.", action: nil, keyEquivalent: ""); e.isEnabled = false; m.addItem(e) }
        for e in model {
            let i = BlockMenuItem(title: e.title) { [weak self] in self?.chooseWorkspace(e.root) }
            if let d = e.digit { i.keyEquivalent = String(d); i.keyEquivalentModifierMask = [.option, .command] }
            i.state = e.on ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
        m.addItem(BlockMenuItem(title: "Add workspace…") { [weak self] in self?.newSession() })
        #if MUYA_TEST_HOOKS
        if let hook = Self.menuHook { hook(m); return }
        if Self.menuAutoCancel > 0 { let t = Timer(timeInterval: Self.menuAutoCancel, repeats: false) { _ in m.cancelTracking() }; RunLoop.main.add(t, forMode: .common) }   // the verify scripts read the menu instead of opening it
        #endif
        m.popUp(positioning: nil, at: NSPoint(x: chip.minX, y: chip.maxY + 4), in: frameView.header)
    }

    /// Double-click on the top bar: what the system setting says (AppleActionOnDoubleClick), zoom by default. Never full screen.
    func titleBarDoubleClick() {
        switch TitleBarAction.from(defaultsValue: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
        case .zoom: window.zoom(nil)
        case .minimize: window.miniaturize(nil)
        case .none: break
        }
    }
}
