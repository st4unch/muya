// Window chrome: session list on the left, terminal on the right. Built from AppKit's own
// controls and semantic colours so it looks native in both appearances.

import AppKit

final class StateDot: NSView {
    var color: NSColor = Token.stateIdle { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

final class SessionRow: NSTableCellView {
    let dot = StateDot()
    let name = NSTextField(labelWithString: "")
    let cwd = NSTextField(labelWithString: "")
    let state = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = Token.text
        cwd.font = .systemFont(ofSize: 11)
        cwd.textColor = Token.textSecondary
        cwd.lineBreakMode = .byTruncatingHead
        state.font = .systemFont(ofSize: 11)
        for v in [name, cwd, state] { v.maximumNumberOfLines = 1; v.cell?.truncatesLastVisibleLine = true }
        let text = NSStackView(views: [name, cwd, state])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [dot, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            dot.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ s: SessionModel, home: String) {
        name.stringValue = s.name
        cwd.stringValue = s.cwd.abbreviatingHome(home)
        let st = s.state
        state.stringValue = st.text
        state.textColor = st.color
        dot.color = st.color
    }
}

/// One terminal in the main area: the Metal view plus (in the grid) a slim header with the session's
/// name and state, and an outline that marks the focused tile.
final class Tile: NSView {
    let terminal: TerminalView
    let header = NSView()
    let dot = StateDot()
    let title = NSTextField(labelWithString: "")
    let stateLabel = NSTextField(labelWithString: "")
    let kindIcon = ThemeIconView(icon: .claudeKind, color: Theme.dynamic(.agentClaude), size: 14)   // AgentKindIcon
    static let headerHeight: CGFloat = 49
    /// The footer's message-box toggle also hides/shows the "Message <name>…" row of grid panels (web GridPanel composerOpen).
    nonisolated(unsafe) static var composerOpen = true
    let actions = TileActionBar()   // WP4: inline permission bar of a waiting panel
    let input = TileInputBar()      // WP4: "Message <name>…" row of the other panels
    let expand = FrameIconButton(.maximize, label: "Full screen")
    nonisolated(unsafe) static var onFullscreen: ((SessionModel) -> Void)?
    nonisolated(unsafe) static var onChoose: ((SessionModel, NSView) -> Void)?   // the name's chevron: choose the session for this panel
    let chooser = PanelChevron()
    private var bypassPill: ThemedPill?
    let exitPanel = ExitPanel()
    nonisolated(unsafe) static var onExitResume: ((SessionModel) -> Void)?
    nonisolated(unsafe) static var onExitClose: ((SessionModel) -> Void)?
    nonisolated(unsafe) static var onSend: ((SessionModel, String) -> Void)?
    nonisolated(unsafe) static var onAlways: ((UInt64) -> Void)?
    var showsHeader = false { didSet { needsLayout = true; header.isHidden = !showsHeader } }
    var focused = false { didSet { updateBorder() } }

    init(store: Store) {
        terminal = TerminalView(store: store)
        super.init(frame: .zero)
        wantsLayer = true
        title.font = ThemeFont.sans(14, .semibold)
        title.textColor = Theme.dynamic(.text)
        stateLabel.font = ThemeFont.sans(12)
        for l in [title, stateLabel] { l.lineBreakMode = .byTruncatingTail; l.maximumNumberOfLines = 1; header.addSubview(l) }
        header.addSubview(dot); header.addSubview(kindIcon)
        header.wantsLayer = true
        header.isHidden = true
        addSubview(terminal)
        addSubview(exitPanel)
        addSubview(header)
        addSubview(actions); addSubview(input)
        header.addSubview(expand); header.addSubview(chooser)
        chooser.onClick = { [weak self] in if let s = self?.terminal.session, let c = self?.chooser { Tile.onChoose?(s, c) } }
        expand.onClick = { [weak self] in if let s = self?.terminal.session { Tile.onFullscreen?(s) } }
        input.onSend = { [weak self] t in if let s = self?.terminal.session { Tile.onSend?(s, t) } }
        actions.onAlways = { id in Tile.onAlways?(id) }
        exitPanel.onResume = { [weak self] in if let s = self?.terminal.session { Tile.onExitResume?(s) } }
        exitPanel.onClose = { [weak self] in if let s = self?.terminal.session { Tile.onExitClose?(s) } }
        actions.isHidden = true; input.isHidden = true
        actions.onAnswer = { id, approve in store.answerPrompt(session: id, approve: approve) }   // one safe path (exited sessions are skipped there)
        updateBorder()
        NotificationCenter.default.addObserver(forName: TerminalSchemeState.didChange, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updateBorder() } }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let h = showsHeader ? Tile.headerHeight : 0
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Tile.headerHeight)
        let ah = (actions.isHidden && input.isHidden) ? 0 : TileActionBar.height
        // Today's terminal padding (Terminal.tsx --term-pad: Control 20/28, grid 14/16) minus the renderer's own 6 px; the tile paints the terminal background.
        let padX: CGFloat = showsHeader ? 10 : 22, padY: CGFloat = showsHeader ? 8 : 14
        terminal.frame = NSRect(x: padX, y: h + padY, width: max(bounds.width - 2 * padX, 0), height: max(bounds.height - h - ah - 2 * padY, 0))
        exitPanel.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(bounds.height - h - ah, 0))
        actions.frame = NSRect(x: 0, y: bounds.height - ah, width: bounds.width, height: TileActionBar.height)
        input.frame = actions.frame
        expand.plain = true
        expand.frame = NSRect(x: bounds.width - 42, y: (Tile.headerHeight - 28) / 2, width: 28, height: 28)
        dot.frame = NSRect(x: 14, y: (Tile.headerHeight - 8) / 2, width: 8, height: 8)
        let w = bounds.width - 84
        title.sizeToFit()
        let tw = min(title.frame.width, w * 0.6)
        kindIcon.frame = NSRect(x: 32, y: (Tile.headerHeight - 14) / 2, width: 14, height: 14)
        let tx: CGFloat = kindIcon.isHidden ? 32 : 56
        title.frame = NSRect(x: tx, y: (Tile.headerHeight - title.frame.height) / 2, width: tw, height: title.frame.height)
        chooser.frame = NSRect(x: tx + tw + 2, y: (Tile.headerHeight - 22) / 2, width: 22, height: 22)
        chooser.isHidden = !showsHeader
        stateLabel.sizeToFit()
        let sw = min(stateLabel.frame.width, max(w - tw - 100, 0))
        stateLabel.frame = NSRect(x: tx + tw + 30, y: title.frame.minY, width: sw, height: stateLabel.frame.height)
        if let p = bypassPill { let pw = p.intrinsicContentSize.width; p.frame = NSRect(x: stateLabel.frame.maxX + 8, y: (Tile.headerHeight - 20) / 2, width: pw, height: 20) }
    }

    func configure(_ s: SessionModel?) {
        guard let s else { return }
        title.stringValue = s.name
        let st = s.state
        var text = st.text
        if s.exited == nil, let sc = s.screen {   // GridPanel.tsx statusText: withDetail("Needs permission", since) / "Working" / "Idle"
            if sc.permission { text = "Needs permission" + (s.elapsed.map { " · \($0)" } ?? "") } else if sc.busy || sc.activity != nil { text = "Working" }
        }
        stateLabel.stringValue = text
        stateLabel.textColor = st.color
        dot.color = st.color
        kindIcon.isHidden = false
        (kindIcon.icon, kindIcon.color) = s.kindIconChoice; kindIcon.toolTip = s.openedByTooltip
        bypassPill?.removeFromSuperview(); bypassPill = nil
        if s.exited == nil, PermissionModes.isBypass(s.screen?.mode ?? "") {   // today's "bypass" pill after the status
            let p = ThemedPill("bypass", fg: Theme.dynamic(.dangerText), bg: Theme.dynamic(.dangerPillBg)); header.addSubview(p); bypassPill = p
        }
        actions.configure(s)
        exitPanel.show(s)
        input.session = s
        input.isHidden = !showsHeader || !actions.isHidden || !Tile.composerOpen
        updateBorder()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let waiting = !actions.isHidden
            layer.cornerRadius = showsHeader ? 10 : 0; layer.masksToBounds = showsHeader
            layer.borderWidth = showsHeader ? (waiting ? 2 : 1) : 0   // today's GridPanel: focused = 1px --border-selected; waiting = 1px --warning + 1px ring
            layer.borderColor = Theme.dynamic(waiting ? .warning : focused ? .borderSelected : .border).cgColor
            header.layer?.backgroundColor = Theme.dynamic(.bgPanel).cgColor
            layer.backgroundColor = TerminalSchemeState.padFill.cgColor   // the padding around the grid is terminal background (a fixed scheme paints its own)
        }
    }

    override func layoutSubtreeIfNeeded() { super.layoutSubtreeIfNeeded() }

    /// Right-click on the panel header (grid): the session menu (Pin, Rename…, Duplicate, Reveal in Finder, …).
    nonisolated(unsafe) static var sessionMenuProvider: ((SessionModel) -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard showsHeader, let s = terminal.session, convert(event.locationInWindow, from: nil).y <= Tile.headerHeight else { return super.menu(for: event) }
        return Tile.sessionMenuProvider?(s)
    }
}

/// Lays the tiles out: one filling the area, or up to six in a grid.
final class TileContainer: NSView {
    private(set) var tiles: [Tile] = []
    private let store: Store
    private(set) var grid = false
    private(set) var shown = 1
    /// Grid cells (cols x rows) and the empty cells after the sessions (WP4: layouts 1 / 1×2 / 2×2 / 3×2 with "Empty panel" cards).
    private(set) var cols = 0, rows = 0
    private(set) var empties: [EmptyPanelView] = []
    /// Split Control: side-by-side panes with headers and dividers (SplitPanes.swift).
    private(set) var splitChrome: SplitChrome!

    init(store: Store, first: Tile) {
        self.store = store
        super.init(frame: .zero)
        splitChrome = SplitChrome(host: self)
        wantsLayer = true
        tiles = [first]
        addSubview(first)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func tile(_ i: Int) -> Tile {
        while tiles.count <= i { let t = Tile(store: store); tiles.append(t); addSubview(t) }
        return tiles[i]
    }

    /// Split Control: `count` panes of one split group, each tile under its own 26 px header.
    func arrangeSplit(count: Int) {
        grid = false
        shown = max(1, min(count, SplitLogic.maxSplit))
        cols = 0; for e in empties { e.isHidden = true }
        for i in 0 ..< shown { _ = tile(i) }
        for (i, t) in tiles.enumerated() { t.isHidden = i >= shown; t.showsHeader = false }
        needsLayout = true
    }

    func arrange(count: Int, grid: Bool) {
        splitChrome.deactivate()
        self.grid = grid
        shown = max(1, min(count, grid ? 6 : 1))
        if !grid { cols = 0; for e in empties { e.isHidden = true } }
        for i in 0 ..< shown { _ = tile(i) }
        for (i, t) in tiles.enumerated() {
            t.isHidden = i >= shown
            t.showsHeader = grid
        }
        needsLayout = true
    }

    /// Sets the grid shape and how many empty cells follow the sessions; creates / hides the empty panels.
    func setCells(cols: Int, rows: Int, empty: Int) {
        self.cols = cols; self.rows = rows
        while empties.count < empty { let e = EmptyPanelView(); empties.append(e); addSubview(e) }
        for (i, e) in empties.enumerated() { e.isHidden = !(grid && i < empty) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if splitChrome.active { splitChrome.layout(tiles: tiles, bounds: bounds); return }
        if grid, cols > 0 {
            let cells = GridPlan.cells(cols: cols, rows: rows, width: Double(bounds.width), height: Double(bounds.height))
            for (i, c) in cells.enumerated() {
                let r = NSRect(x: c.x, y: c.y, width: c.w, height: c.h)
                if i < shown, i < tiles.count { tiles[i].frame = r } else if i - shown >= 0, i - shown < empties.count { empties[i - shown].frame = r }
            }
            return
        }
        let frames = GridLayout.tiles(count: shown, width: Double(bounds.width), height: Double(bounds.height), gap: grid ? 4 : 0)
        for (i, f) in frames.enumerated() where i < tiles.count {
            tiles[i].frame = NSRect(x: f.x, y: f.y, width: f.w, height: f.h)
        }
    }
}

final class MainController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate, StoreDelegate, NSMenuDelegate {
    let store: Store
    let window: NSWindow
    let tileView: TileContainer
    var onPanelLayoutSettled: (() -> Void)?
    var panelLayoutLocked = false   // see refreshFrame / PanelPrefs.saveLayout
    let splitModel = SplitModel()   // Split Control (SplitControl.swift)
    var terminal: TerminalView { tileView.tiles[0].terminal }
    var onGridChanged: ((Bool) -> Void)?   // P4: apex.viewMode
    private(set) var gridMode = false { didSet { if gridMode != oldValue { onGridChanged?(gridMode) } } }
    let table = NSTableView()
    let banner = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    let files = FileTreePanel()
    let sideSplit = NSSplitView()
    let viewer = ViewerPane()
    let sessionsPage: SessionsPage
    let schedulesPage: SchedulesPage
    let queuePage = QueuePage()
    lazy var sshPage: SSHHubPage = SSHPageFactory.make(store: store)
    lazy var resourcesService: ResourcesService = MainActor.assumeIsolated { ResourcesService(rpc: StoreSSHRpc(store: store)) }
    lazy var resourcesPage: ResourcesPage = ResourcesPageFactory.make(controller: self)
    let slashPopover: SlashPopover = MainActor.assumeIsolated { SlashPopover(frame: .zero) }
    let settings: SettingsController
    /// The "Turn on Auto-allow?" toast (P12), over the main window's top-right corner.
    lazy var autoAllowSuggest: AutoAllowSuggestController = {
        MainActor.assumeIsolated {
            let c = AutoAllowSuggestController(store: store, host: window.contentView)
            c.escapeBlocked = { [unowned self] in palette.isOpen || window.attachedSheet != nil }
            return c
        }
    }()
    let palette = PalettePanel()
    /// AC21 onboarding screen and AC19 restart dialog (Onboarding.swift, RestartDialog.swift).
    lazy var serviceGate: ServiceGate = MainActor.assumeIsolated { ServiceGate(store: store, window: window) }
    let agents: AgentService
    let resume: ResumeService
    let promptRunner: PromptRunner
    let spotlight: SpotlightSearch
    private(set) var promptSheet: ScheduledPromptSheet?
    private var launchTasksDone = false
    /// What the first-launch resume did (for the verify scripts): names of the sessions reopened.
    private(set) var resumedAtLaunch: [String] = []
    private(set) var migrationOutcome: MigrationCall?
    let inspector = InspectorPane()
    // WP1 frame (header / rail / footer around the content split); see Frame.swift, FrameWiring.swift.
    var frameView: FrameView!
    var rootSplit: NSSplitView!
    let frameStats = FrameStats()
    let agentsPanel = AgentsPanel(), sessionBar = SessionBar(), composer = Composer(), statusStrip = StatusStrip()   // WP2
    var sidebar: SidebarView!
    var onInspectorChoice: ((Bool) -> Void)?   // the operator opened / closed the inspector (not an automatic hide): saved by PanelPrefs
    var statusData: [String: Any]?          // status JSON of the selected session (footer fields)
    var statusSid: UInt64?
    var statusTimer: Timer?
    var fieldPicker: FieldPickerController?   // P5: keeps the status field picker alive while its popover is open
    let filesHome = FilesHome()
    var filesMode = false { didSet { sidebar?.filesMode = filesMode } }   // the rail's Files item: open files + the tree on the left, the Files empty state in the middle
    var sidebarCollapsed = false   // the header's sidebar toggle; pages hide the panel regardless
    private(set) var currentPage: PageView?
    private var refreshTimer: Timer?
    /// AC24: while the window is fully hidden (occluded / minimized) nothing is drawn.
    private(set) var windowVisible = true
    private(set) var sleeping = false
    private(set) var wakeCount = 0
    private(set) var lastWakeResync: (sessionsBefore: Int, sessionsAfter: Int, seconds: Double)?

    init(store: Store) {
        self.store = store
        agents = AgentService(home: store.home)
        resume = ResumeService(agents: agents, prefs: store.prefs)
        promptRunner = PromptRunner(store: store)
        spotlight = SpotlightSearch(home: store.home)
        sessionsPage = SessionsPage(store: store, agents: agents)
        schedulesPage = SchedulesPage(store: store)
        settings = SettingsController(store: store)
        tileView = TileContainer(store: store, first: Tile(store: store))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        store.delegate = self
        statusStrip.onRestart = { [weak self] in self?.installUpdate() }
        NotificationCenter.default.addObserver(forName: UpdateCenter.changed, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshFrame() } }
        window.title = AppInfo.name
        window.isRestorable = false
        window.minSize = NSSize(width: 760, height: 420)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        rootSplit = buildContent() as? NSSplitView
        frameView = FrameView(content: rootSplit)
        window.contentView = frameView
        wireTile(tileView.tiles[0])
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        DispatchQueue.main.async { [rootSplit] in rootSplit?.setPosition(264, ofDividerAt: 0) /* agents.width default: 296, 264 at ≤1360 wide (usePanelLayout.ts); the app opens at 1120 */ }
        // Working directories are not reported by the daemon; look at the shells now and then.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.store.refreshDirectories() }
        refreshTimer?.tolerance = 1.5
        files.window = window
        files.home = store.home
        _ = serviceGate
        installInspector()
        wireFrame()
        files.silent = ProcessInfo.processInfo.environment["MUYA_DEBUG_SOCKET"] != nil
        files.onOpen = { [weak self] url, kind in self?.openViewer(url, kind) }
        files.onTerminalHere = { [weak self] dir in
            guard let self else { return }
            self.closeViewer()
            self.store.spawn(cwd: dir)
        }
        viewer.onClose = { [weak self] in self?.closeViewer() }
        SettingsController.applyAppearance(store.prefs.string("appearance"))
        queuePage.cwdProvider = { [weak self] in self?.store.selected?.cwd }
        queuePage.pathsProvider = { [weak self] in self?.store.sessions.map(\.cwd) ?? [] }
        for page in [sessionsPage, schedulesPage, queuePage, sshPage, resourcesPage] as [PageView] { page.onClose = { [weak self] in self?.showPage(nil) } }
        sessionsPage.onResume = { [weak self] _ in self?.showPage(nil) }
        sessionsPage.onAgents = { [weak self] rows in self?.resume.remember(rows) }
        schedulesPage.onScheduledPrompt = { [weak self] in self?.openScheduledPrompt() }
        // A live agent row maps to an open terminal only when exactly one open terminal sits in its folder.
        let terminalFor: (AgentRow) -> SessionModel? = { [weak self] row in
            let m = self?.store.sessions.filter { $0.exited == nil && $0.cwd == row.cwd } ?? []
            return m.count == 1 ? m[0] : nil
        }
        sessionsPage.canSchedule = { terminalFor($0) != nil }
        sessionsPage.onSchedule = { [weak self] row in if let s = terminalFor(row) { self?.openSessionSchedule(s) } }
        resume.start()
        palette.onQueryChanged = { [weak self] q in self?.paletteQueryChanged(q) }
        spotlight.onResults = { [weak self] items in self?.palette.extra = items }
        palette.provider = { [weak self] in self?.paletteItems() ?? [] }
        palette.onRun = { [weak self] item in self?.runPalette(item) }
        palette.onDismiss = { [weak self] in self?.restoreFocus() }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: Files, viewer

    /// The tree's roots (FileTree.tsx): one per workspace folder — the folders of the sessions, in the order of the agents list —
    /// each with the name of the agent working there.
    func refreshFileRoots() {
        var entries: [(path: String, chip: String?)] = []
        if store.mockMode {   // the web mock's three workspaces and the agent in each
            let d = store.home + "/Documents/"
            entries = [(d + "claude-control-plane", "muya-all"), (d + "iptv", "iptv-2a"), (d + "numbat", "numbat-c3")]
        }
        for s in store.sessions where s.exited == nil && !store.mockMode {
            guard !s.cwd.isEmpty else { continue }
            if let i = entries.firstIndex(where: { $0.path == s.cwd }) { if entries[i].chip == nil { entries[i].chip = s.name }; continue }
            entries.append((s.cwd, s.name))
        }
        files.setRoots(entries)
        files.activeRoot = store.mockMode ? entries.first?.path : store.selected?.cwd
        if store.mockMode { for e in entries { _ = files.expand(path: e.path + "/" + (e.path as NSString).lastPathComponent) } }   // the web mock's tree shows its sub-folder open
    }

    /// Files open in the viewer, oldest first (the palette's "Files" lists them); the viewer shows one at a time.
    var onOpenFilesChanged: (([String]) -> Void)?   // P4: muya.openFiles
    var openFilePaths: [String] = [] { didSet { onOpenFilesChanged?(openFilePaths); sidebar?.openFiles.paths = openFilePaths } }
    private(set) var viewerPath: String?

    func openViewer(_ url: URL, _ kind: FileKind) {
        openFilePaths.removeAll { $0 == url.path }; openFilePaths.append(url.path); viewerPath = url.path; sidebar?.openFiles.current = url.path
        viewer.show(url, kind: kind)
        viewer.isHidden = false
    }

    func closeViewer() {
        guard !viewer.isHidden else { return }
        if let p = viewerPath { openFilePaths.removeAll { $0 == p }; viewerPath = nil; sidebar?.openFiles.current = nil; viewer.discardSession(p) }
        viewer.isHidden = true
        window.makeFirstResponder(terminal)
    }

    /// Closes one open file the way every entry point should (⌘W, the list's ×, Reopen): a dirty document asks first.
    /// `done(true)` = it is closed; `done(false)` = the user cancelled (or the save failed) and everything stays.
    func closeFile(_ path: String, _ done: ((Bool) -> Void)? = nil) {
        viewer.confirmClose(path, window: window) { [weak self] ok in
            guard let self, ok else { done?(false); return }
            if path == self.viewerPath { self.closeViewer() } else { self.openFilePaths.removeAll { $0 == path } }
            done?(true)
        }
    }

    /// Quit: asks once for all unsaved documents. true = go ahead and quit.
    func confirmQuit() -> Bool {
        let dirty = viewer.dirtyPaths
        guard !dirty.isEmpty else { return true }
        #if MUYA_TEST_HOOKS
        if let a = EditorGuard.testAnswer { EditorGuard.testAnswer = nil; if a == "save" { return viewer.saveAll() }; return a == "discard" }
        #endif
        let a = NSAlert()
        let names = dirty.prefix(4).map { "“" + ($0 as NSString).lastPathComponent + "”" }.joined(separator: ", ") + (dirty.count > 4 ? " and \(dirty.count - 4) more" : "")
        a.messageText = dirty.count == 1 ? "Save changes to \(names) before quitting?" : "You have \(dirty.count) files with unsaved changes"
        a.informativeText = dirty.count == 1 ? "Your changes will be lost if you don’t save them." : "\(names). Your changes will be lost if you don’t save them."
        a.addButton(withTitle: "Save All"); a.addButton(withTitle: "Quit Without Saving"); a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: return viewer.saveAll()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: Scheduled prompt, spotlight, launch tasks

    @discardableResult
    func openScheduledPrompt() -> ScheduledPromptSheet? {
        guard promptSheet == nil else { return promptSheet }
        let sheet = ScheduledPromptSheet(window: window, store: store, runner: promptRunner)
        sheet.onClosed = { [weak self] in self?.promptSheet = nil }
        promptSheet = sheet
        return sheet
    }

    func paletteQueryChanged(_ text: String) {
        if text.isEmpty || !palette.isOpen { spotlight.stop(); palette.extra = []; return }
        spotlight.search(text, roots: SpotlightLogic.parseRoots(store.prefs.string("spotlightRoots"), home: store.home))
    }

    /// Once per launch, after the first connection to muyad: the first-launch migration and "resume on launch".
    private func runLaunchTasks() {
        guard !launchTasksDone else { return }
        launchTasksDone = true
        store.runMigration { [weak self] outcome in self?.migrationOutcome = outcome }
        settings.beta.acknowledgeLaunch()
        settings.beta.reload()   // an update the background check already found: the footer shows it right away
        let plan = ResumeLogic.plan(saved: resume.saved, enabled: store.prefs.bool("resumeOnLaunch"), liveTerminals: store.sessions.filter { $0.exited == nil }.count,
                                    existingFolders: { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue })
        for e in plan {
            guard let cmd = SessionsLogic.resumeCommand(e.sessionId) else { continue }
            store.openShell(cwd: e.cwd, name: "↻ \(e.name.isEmpty ? String(e.sessionId.prefix(8)) : e.name)", typing: cmd)
            resumedAtLaunch.append(e.name)
        }
    }

    // MARK: Pages, settings, palette

    @objc func showSessions() { showPage(currentPage === sessionsPage ? nil : sessionsPage) }
    @objc func showSchedules() { showPage(currentPage === schedulesPage ? nil : schedulesPage) }
    @objc func showResources() { showPage(currentPage === resourcesPage ? nil : resourcesPage) }
    @objc func showSSH() { showPage(currentPage === sshPage ? nil : sshPage) }
    @objc func showQueue() { openQueue(.queue) }
    func openQueue(_ tab: QueueTab) {
        if currentPage === queuePage, queuePage.tab == tab { showPage(nil); return }
        showPage(queuePage); queuePage.select(tab: tab)
    }
    @objc func openSettings() { settings.show() }
    /// App menu: "Return to Muya Classic (4.1.22)…" (the same flow as Settings > Updates).
    /// App menu "Check for Updates…" and the footer's Restart.
    @objc func checkForUpdates() { settings.beta.checkFromMenu() }
    func installUpdate() { settings.show(); settings.beta.installNow() }
    @objc func returnToClassic() { settings.show(); settings.beta.confirmSwitchBack() }
    @objc func saveFile() { if !viewer.isHidden, let p = viewerPath { viewer.sessions[p]?.save() } }
    @objc func goToLine() { if !viewer.isHidden, let p = viewerPath { viewer.sessions[p]?.goToLineSheet() } }
    @objc func showControl() { filesMode = false; showPage(nil) }
    @objc func togglePalette() { if palette.isOpen { palette.dismiss() } else { palette.open() } }

    /// Shows one page over the terminal area, or none (back to the terminals).
    func showPage(_ page: PageView?) {
        if palette.isOpen { palette.dismiss() }
        if page != nil { filesMode = false }   // a page and the Files screen are never up together (the rail's Files item is a mode of the terminal area, not a page)
        guard page !== currentPage else { refreshFrame(); return }   // same page (nil -> nil: Files -> Control): the frame still has to follow filesMode
        currentPage?.isHidden = true
        currentPage?.didHide()
        currentPage = page
        if let page {
            closeViewer()
            page.isHidden = false
            page.didShow()
        } else {
            restoreFocus()
        }
        refreshFrame()
        MainActor.assumeIsolated { delegate.panelPrefs?.syncInspector() }
    }

    func restoreFocus() {
        if let page = currentPage { window.makeFirstResponder(page) } else { window.makeFirstResponder(terminal) }
    }

    /// Everything ⌘K can reach: the open terminals, the most recent Claude sessions, the views and the commands.
    func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        for s in store.sessions { items.append(PaletteItem(id: "term:\(s.id)", group: "Terminals", title: s.name, subtitle: s.cwd.abbreviatingHome(store.home))) }
        // Today's order: Agents, Files (open files + the selected agent's changed files, as in src/App.tsx), Commands; history last.
        let snap = inspector.snapshot
        items += PaletteFiles.items(open: openFilePaths, changes: store.selected == nil ? [] : snap.status.changes.map { (path: $0.path, deleted: $0.x == "D" || $0.y == "D") },
                                    root: snap.root, home: store.home)
        if store.mockMode, !items.contains(where: { $0.group == "Files" }) {   // dev mock mode: the web mock's changed files (src/mock)
            items += ["src-tauri/src/pty.rs", "src-tauri/src/agents.rs", "tasks/todo.md", "src/App.tsx", "src/components/Terminal.tsx"].map { PaletteItem(id: "file:\(store.home)/\($0)", group: "Files", title: $0) }
        }
        items += [
            PaletteItem(id: "view:control", group: "Views", title: "Terminals"),
            PaletteItem(id: "view:sessions", group: "Views", title: "Sessions"),
            PaletteItem(id: "view:schedules", group: "Views", title: "Schedules"),
            PaletteItem(id: "view:resources", group: "Views", title: "Resources"),
            PaletteItem(id: "cmd:slash", group: "Commands", title: "Slash commands…"),
            PaletteItem(id: "view:queue", group: "Views", title: "Queue (push / merge)"),
            PaletteItem(id: "view:branches", group: "Views", title: "Branches (commit graph)"),
            PaletteItem(id: "view:kanban", group: "Views", title: "Kanban (PRD board)"),
            PaletteItem(id: "view:settings", group: "Views", title: "Settings"),
            PaletteItem(id: "cmd:new", group: "Commands", title: "New terminal"),
            PaletteItem(id: "cmd:newin", group: "Commands", title: "New session in folder…"),
            PaletteItem(id: "cmd:close", group: "Commands", title: "Close terminal"),
            PaletteItem(id: "cmd:grid", group: "Commands", title: "Toggle grid"),
            PaletteItem(id: "cmd:newschedule", group: "Commands", title: "New schedule"),
            PaletteItem(id: "cmd:sprompt", group: "Commands", title: "Scheduled prompt…"),
            PaletteItem(id: "cmd:cleanup", group: "Commands", title: "Clean up Claude sessions…"),
            PaletteItem(id: "cmd:vault", group: "Commands", title: "Notes vault source…"),
            PaletteItem(id: "cmd:theme", group: "Commands", title: "Cycle theme (system, light, dark)"),
        ]
        for e in sessionsPage.entries.sorted(by: { $0.lastActivity > $1.lastActivity }).prefix(200) {
            items.append(PaletteItem(id: "hist:\(e.sessionId)", group: "Sessions", title: e.displayName, subtitle: e.cwd.abbreviatingHome(store.home)))
        }
        return items
    }

    func runPalette(_ item: PaletteItem) {
        let kind = item.id.prefix(while: { $0 != ":" }), arg = String(item.id.drop(while: { $0 != ":" }).dropFirst())
        switch kind {
        case "term":
            filesMode = false; showPage(nil)
            if let s = store.sessions.first(where: { "\($0.id)" == arg }) { store.select(s) }
        case "file":
            let url = URL(fileURLWithPath: arg)
            showPage(nil)
            openViewer(url, FileKind.detect(url))
        case "hist":
            showPage(sessionsPage)
            sessionsPage.setSearch("id=\(arg)")
        case "view":
            switch arg {
            case "sessions": showPage(sessionsPage)
            case "schedules": showPage(schedulesPage)
            case "resources": showPage(resourcesPage)
            case "queue": openQueue(.queue)
            case "branches": openQueue(.branches)
            case "kanban": openQueue(.kanban)
            case "settings": openSettings()
            default: filesMode = false; showPage(nil)
            }
        default:
            switch arg {
            case "slash": toggleSlash()
            case "new": store.spawn(cwd: store.home); window.makeFirstResponder(terminal)
            case "newin": newSession()
            case "close": closeSession()
            case "grid": toggleGrid()
            case "newschedule": showPage(schedulesPage); schedulesPage.newTapped()
            case "sprompt": openScheduledPrompt()
            case "cleanup": showPage(sessionsPage); sessionsPage.openCleanup()
            case "vault": settings.show(); MainActor.assumeIsolated { settings.showVault() }
            case "theme":
                let order = ["System", "Light", "Dark"], cur = store.prefs.string("appearance")
                let next = order[((order.firstIndex(of: cur) ?? 0) + 1) % 3]
                store.prefs.set("appearance", next)
                SettingsController.applyAppearance(next)
            default: break
            }
        }
    }

    // MARK: Occlusion, sleep (AC24)

    @objc func occlusionChanged() {
        let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
        setWindowVisible(visible)
    }

    func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        TerminalView.drawingSuspended = !visible
        store.setActive(visible && !sleeping)
        if visible { frameStats.start() } else { frameStats.stop() }
        if visible { for t in tileView.tiles where !t.isHidden { t.terminal.requestDraw() } }
    }

    @objc func systemWillSleep() {
        sleeping = true
        TerminalView.drawingSuspended = true
        store.setActive(false)
    }

    /// After wake: the connection to muyad may have died while the Mac slept. Re-list the daemon's sessions,
    /// adopt anything missing, update exit states, reconnect if the socket is gone.
    @objc func systemDidWake() {
        sleeping = false
        promptRunner.reschedule() // timers pause during sleep: re-arm from the wall clock
        TerminalView.drawingSuspended = !windowVisible
        store.setActive(windowVisible)
        let t0 = CACurrentMediaTime()
        let before = store.sessions.count
        store.resyncAfterWake()
        lastWakeResync = (before, store.sessions.count, CACurrentMediaTime() - t0)
        wakeCount += 1
        for t in tileView.tiles where !t.isHidden { t.terminal.requestDraw() }
        refreshFileRoots() // no-op when unchanged; the FSEvents streams survive sleep
    }

    private func buildContent() -> NSView {
        let split = HidingDividerSplit()   // no divider left behind while the sidebar is hidden
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self

        // Sidebar: sessions on top, the file tree of the selected session below.
        files.setRoots([])   // the sidebar has its own FILES row: the panel's own "Files" header must never show, not even before the first session (it did on an empty first launch)
        let side = SidebarView(agents: agentsPanel, files: files.view)
        sidebar = side
        let sessionsBox = NSView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.setAccessibilityLabel("Terminal sessions")
        table.rowHeight = 58
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.menu = { let m = NSMenu(); m.delegate = self; return m }()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        let add = NSButton(title: "New Session", target: self, action: #selector(newSession))
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Session")
        add.imagePosition = .imageLeading
        add.bezelStyle = .rounded
        add.controlSize = .regular
        status.font = .systemFont(ofSize: 11)
        status.textColor = Token.textSecondary
        status.lineBreakMode = .byTruncatingTail
        let nav = NSStackView(views: [("Sessions", "clock.arrow.circlepath", #selector(showSessions)), ("Schedules", "calendar.badge.clock", #selector(showSchedules)), ("Queue", "arrow.triangle.merge", #selector(showQueue)), ("SSH & Passwords", "key.horizontal", #selector(showSSH)), ("Settings", "gearshape", #selector(openSettings))].map { t, sym, sel in
            let b = NSButton(title: t, target: self, action: sel)
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: t)
            b.imagePosition = .imageOnly
            b.bezelStyle = .texturedRounded
            b.toolTip = t
            b.setAccessibilityLabel(t)
            return b
        })
        nav.orientation = .horizontal
        nav.spacing = 6
        let bar = NSStackView(views: [add, nav, status])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 6
        for v in [scroll, bar] { v.translatesAutoresizingMaskIntoConstraints = false; sessionsBox.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: sessionsBox.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: sessionsBox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sessionsBox.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: sessionsBox.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: sessionsBox.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: sessionsBox.bottomAnchor, constant: -10),
        ])
        sidebar.expanded = false   // WP5: opens the tree from the "FILES" row

        // Terminal + banner
        let main = NSView()
        tileView.translatesAutoresizingMaskIntoConstraints = false
        banner.font = .systemFont(ofSize: 14)
        banner.textColor = Token.textSecondary
        banner.alignment = .center
        banner.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(tileView)
        main.addSubview(sessionBar); main.addSubview(composer); main.addSubview(statusStrip)
        NSLayoutConstraint.activate([
            sessionBar.topAnchor.constraint(equalTo: main.topAnchor), sessionBar.leadingAnchor.constraint(equalTo: main.leadingAnchor), sessionBar.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: main.bottomAnchor), composer.leadingAnchor.constraint(equalTo: main.leadingAnchor), composer.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            statusStrip.bottomAnchor.constraint(equalTo: composer.topAnchor), statusStrip.leadingAnchor.constraint(equalTo: main.leadingAnchor), statusStrip.trailingAnchor.constraint(equalTo: main.trailingAnchor),
        ])
        main.addSubview(banner)
        viewer.translatesAutoresizingMaskIntoConstraints = false
        viewer.isHidden = true
        main.addSubview(viewer)
        for v in [sessionsPage, schedulesPage, queuePage, sshPage, resourcesPage] as [PageView] {
            v.isHidden = true
            Kit.pin(v, in: main)
        }
        slashPopover.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(slashPopover)
        Kit.pin(slashPopover, in: main)
        wireSlash()
        palette.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(palette)
        NSLayoutConstraint.activate([
            palette.topAnchor.constraint(equalTo: main.topAnchor), palette.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            palette.leadingAnchor.constraint(equalTo: main.leadingAnchor), palette.trailingAnchor.constraint(equalTo: main.trailingAnchor),
        ])
        NSLayoutConstraint.activate([
            tileView.topAnchor.constraint(equalTo: sessionBar.bottomAnchor), tileView.bottomAnchor.constraint(equalTo: statusStrip.topAnchor),
            tileView.leadingAnchor.constraint(equalTo: main.leadingAnchor), tileView.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            banner.centerXAnchor.constraint(equalTo: main.centerXAnchor), banner.centerYAnchor.constraint(equalTo: main.centerYAnchor),
            viewer.topAnchor.constraint(equalTo: main.topAnchor), viewer.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            viewer.leadingAnchor.constraint(equalTo: main.leadingAnchor), viewer.trailingAnchor.constraint(equalTo: main.trailingAnchor),
        ])
        split.addArrangedSubview(side)
        split.addArrangedSubview(InspectorSplit(content: main, inspector: inspector))
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setPosition(250, ofDividerAt: 0)
        return split
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { splitView === sideSplit ? 160 : 200 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { splitView === sideSplit ? splitView.bounds.height - 140 : 380 }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { splitView === rootSplit && subview === rootSplit.arrangedSubviews.first }

    // MARK: Actions

    /// The "New agent" dialog (NewAgentSheet.swift): workspace, kind, permission mode … then Launch.
    @objc func newSession() {
        guard newAgentSheet == nil else { return }
        var known: [String] = [store.home.abbreviatingHome(store.home)]
        for s in store.sessions { let c = s.cwd.abbreviatingHome(store.home); if !known.contains(c) { known.append(c) } }
        let initial = (store.selected?.cwd ?? store.home).abbreviatingHome(store.home)
        let sheet = NewAgentSheet(store: store, workspaces: known, initial: initial)
        newAgentSheet = sheet
        sheet.onClose = { [weak self] in self?.newAgentSheet = nil; self?.window.makeFirstResponder(self?.terminal) }
        sheet.present(on: window)
    }
    private(set) var newAgentSheet: NewAgentSheet?
    var notificationsPopover: OverlayPopover?
    var appearancePop: OverlayPopover?

    @objc func closeSession() { if let s = store.selected { store.close(s) } }

    @objc func nextSession() { step(1) }
    @objc func previousSession() { step(-1) }
    private func step(_ d: Int) {
        guard !store.sessions.isEmpty else { return }
        let i = store.selected.flatMap { s in store.sessions.firstIndex { $0 === s } } ?? 0
        store.select(store.sessions[(i + d + store.sessions.count) % store.sessions.count])
    }

    @objc func renameSession() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < store.sessions.count else { return }
        let s = store.sessions[row]
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = s.name
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn, !field.stringValue.isEmpty { self?.store.rename(s, to: field.stringValue) }
        }
    }

    @objc func closeClickedSession() {
        let row = table.clickedRow
        guard row >= 0, row < store.sessions.count else { return }
        store.close(store.sessions[row])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0 else { return }
        menu.addItem(withTitle: "Rename…", action: #selector(renameSession), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close Session", action: #selector(closeClickedSession), keyEquivalent: "").target = self
    }

    private func wireTile(_ t: Tile) {
        t.terminal.onGrid = { [weak self] view, cols, rows in self?.gridChanged(view, cols, rows) }
        t.terminal.onFocusRequest = { [weak self] view in
            guard let self, let s = view.session, s !== self.store.selected else { return }
            self.store.select(s)
        }
    }

    @objc func toggleGrid() { setGrid(!gridMode) }

    func setGrid(_ on: Bool) {
        gridMode = on
        refreshTiles()
        MainActor.assumeIsolated { delegate.panelPrefs?.syncInspector() }
    }

    /// Single view: the selected session. Grid: up to six sessions, the selected one always among them.
    func refreshTiles() {
        let sessions: [SessionModel]
        var splitGroup: SplitGroup?
        var zoomed = false
        if gridMode {
            let choice = GridState.layout
            let waiting = Set(store.sessions.filter { $0.exited == nil && $0.screen?.permission == true }.map(\.id))
            let ids = GridPlan.visible(ids: store.sessions.map(\.id), waiting: waiting, waitingFirst: GridState.waitingFirst, picked: GridState.picked, selected: store.selected?.id, capacity: choice.capacity)
            sessions = ids.compactMap { id in store.sessions.first { $0.id == id } }
            GridState.shownIds = ids
        } else if let g = splitModel.group(of: store.selected), let sel = store.selected {
            // Split Control: the selected session's whole group, or just that pane while it is zoomed (the zoom ends with the selection).
            if splitModel.zoom != nil, splitModel.zoom != sel.id { splitModel.zoom = nil }
            zoomed = splitModel.zoom == sel.id
            splitGroup = g
            sessions = zoomed ? [sel] : g.keys.compactMap { k in store.sessions.first { SplitModel.key($0) == k } }
        } else {
            splitModel.zoom = nil
            sessions = store.selected.map { [$0] } ?? []
        }
        if splitGroup != nil, !zoomed, sessions.count < 2 { splitGroup = nil; splitModel.zoom = nil }   // members closed: a lone terminal shows alone
        if let g = splitGroup {
            tileView.arrangeSplit(count: sessions.count)
            tileView.splitChrome.configure(sessions: sessions, focused: store.selected, zoomed: zoomed, fractions: splitModel.fractions[g.id])
        } else {
            tileView.arrange(count: max(sessions.count, 1), grid: gridMode)
        }
        if gridMode { tileView.setCells(cols: GridState.layout.shape.cols, rows: GridState.layout.shape.rows, empty: max(0, GridState.layout.capacity - sessions.count)) }
        for (i, t) in tileView.tiles.enumerated() {
            let s = i < sessions.count ? sessions[i] : nil
            wireTile(t)
            t.terminal.show(s)
            t.configure(s)
            t.focused = s != nil && s === store.selected
        }
        tileView.layoutSubtreeIfNeeded()
        store.setVisible(sessions)
        focusSelectedTile()
        updateChrome()
    }

    private func focusSelectedTile() {
        if let t = tileView.tiles.first(where: { !$0.isHidden && $0.terminal.session === store.selected && $0.terminal.session != nil }) {
            window.makeFirstResponder(t.terminal)
        } else {
            window.makeFirstResponder(terminal)
        }
    }

    private func gridChanged(_ view: TerminalView, _ cols: Int, _ rows: Int) {
        if !gridMode { store.grid = (cols, rows) }
        if let s = view.session { store.ensureSize(s, cols: cols, rows: rows); view.requestDraw() }
        updateChrome()
    }

    private func updateChrome() {
        banner.stringValue = !store.connected ? banner.stringValue : (store.sessions.isEmpty ? "No sessions yet. Click + New agent, or press ⌘T for a terminal." : "")
        window.subtitle = store.selected.map { $0.name } ?? ""
        let size = gridMode ? "grid" : "\(terminal.lastGrid.cols)×\(terminal.lastGrid.rows)"
        status.stringValue = store.connected ? "\(store.sessions.count) session\(store.sessions.count == 1 ? "" : "s") · \(size)" : status.stringValue
        refreshFrame()
    }

    // MARK: StoreDelegate

    func storeDidChangeSessions(_ store: Store) {
        splitAdoptPending()
        table.reloadData()
        syncSelection()
        refreshTiles()
        refreshFileRoots(); inspector.cwd = store.selected?.cwd
    }

    func store(_ store: Store, didUpdate session: SessionModel) {
        guard let i = store.sessions.firstIndex(where: { $0 === session }) else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: 0))
        if session === store.selected { window.subtitle = session.name; refreshFileRoots(); inspector.cwd = session.cwd }
        for t in tileView.tiles where t.terminal.session === session { t.configure(session) }
        refreshFrame()
        MainActor.assumeIsolated { autoAllowSuggest.sessionsChanged() }
        inspector.refreshApprovals()   // the Inspector's NEEDS APPROVAL card follows the screen state at once
    }

    func store(_ store: Store, selectionChanged session: SessionModel?) {
        syncSelection()
        refreshTiles()
        refreshFileRoots(); inspector.cwd = session?.cwd
        closeViewer()
    }

    func store(_ store: Store, connectionChanged connected: Bool, message: String) {
        if connected {
            MainActor.assumeIsolated { sshPage.serviceCameBack() }
            runLaunchTasks()
            banner.stringValue = store.sessions.isEmpty ? "No sessions yet. Click + New agent, or press ⌘T for a terminal." : ""
        } else {
            banner.stringValue = ServiceApproval.registerError ?? store.service.statusText ?? "Not connected to the background service. Retrying…"
            status.stringValue = message
        }
    }

    func store(_ store: Store, outputFor session: SessionModel) {
        for t in tileView.tiles where t.terminal.session === session { t.terminal.requestDraw() }
    }

    private func syncSelection() {
        let i = store.selected.flatMap { s in store.sessions.firstIndex { $0 === s } }
        if let i { table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) } else { table.deselectAll(nil) }
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { store.sessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SessionRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? SessionRow) ?? { let c = SessionRow(frame: .zero); c.identifier = id; return c }()
        cell.configure(store.sessions[row], home: store.home)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < store.sessions.count, store.sessions[row] !== store.selected else { return }
        store.select(store.sessions[row])
    }
}
