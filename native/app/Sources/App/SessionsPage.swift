// Sessions view: the Claude sessions found in ~/.claude/projects, grouped per project folder (muyad:
// `sessions.history`), content search that runs in the daemon and can be cancelled (`sessions.search`),
// resume in a new terminal, export to Markdown (`sessions.export`).

import AppKit

private final class SessionNode: NSObject {
    let group: SessionsLogic.Group?
    let entry: HistoryEntry?
    /// The "Running now" header (its children are `agent` nodes).
    let liveHeader: Int?
    let agent: AgentRow?
    /// The amber clean-up strip: a row of the list, between the live and the past sessions (like today's page).
    let isBanner: Bool
    /// Stable child nodes: NSOutlineView tracks items by identity.
    let children: [SessionNode]
    init(group: SessionsLogic.Group) { self.group = group; entry = nil; liveHeader = nil; agent = nil; isBanner = false; children = group.entries.map(SessionNode.init(entry:)) }
    init(entry: HistoryEntry) { self.entry = entry; group = nil; liveHeader = nil; agent = nil; isBanner = false; children = [] }
    init(live rows: [AgentRow]) { group = nil; entry = nil; liveHeader = rows.count; agent = nil; isBanner = false; children = rows.map(SessionNode.init(agent:)) }
    init(agent: AgentRow) { self.agent = agent; group = nil; entry = nil; liveHeader = nil; isBanner = false; children = [] }
    init(banner: Bool) { isBanner = true; group = nil; entry = nil; liveHeader = nil; agent = nil; children = [] }
    var isHeader: Bool { group != nil || liveHeader != nil }
}

final class SessionsPage: PageView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    unowned let store: Store
    private let search = NSSearchField()
    private var searchBox: FieldBox!
    private let outline = KeyOutline()
    private let status = Kit.label("", size: 11, color: Token.textSecondary)
    private let resumeButton: NSButton
    private let exportButton: NSButton
    private let copyButton: NSButton
    private let viewButton: NSButton
    private let cleanupButton: NSButton
    private let agents: AgentService
    private let transcript = TranscriptPanel()
    private(set) var cleanup: CleanupSheet?
    private(set) var agentRows: [AgentRow] = []
    private(set) var agentError: String?
    private var agentTimer: Timer?
    /// Called with every fresh live-session list (the resume-on-launch snapshot listens).
    var onAgents: (([AgentRow]) -> Void)?
    private let empty = Kit.label("", color: Token.textSecondary)
    private let banner = CleanupBanner()
    private let tabs = SessionTabs(["Agent Sessions", "Terminal History"])
    let termView = TermHistoryView()
    var termHistoryLoader: ((@escaping ([TermHistoryEntries]) -> Void) -> Void)? { didSet { termView.load = termHistoryLoader } }
    private var bannerShown = false

    private(set) var entries: [HistoryEntry] = []
    private(set) var matches: [String: ContentMatch]?
    private var nodes: [SessionNode] = []
    private var debounce: Timer?
    private var searchReq: UInt64 = 0
    private var searchSerial = 0
    private(set) var searching = false
    private(set) var loadError: String?
    /// Set by the test hook: where an export goes instead of asking with a save panel.
    var exportDestination: URL?
    var onResume: ((HistoryEntry) -> Void)?
    /// "Schedule…" on a live agent row; nil result = the row maps to no single open terminal (the item is left out).
    var onSchedule: ((AgentRow) -> Void)?
    var canSchedule: ((AgentRow) -> Bool)?
    private(set) var lastExport: String?

    init(store: Store, agents: AgentService) {
        self.store = store
        self.agents = agents
        viewButton = Kit.button("View", nil, #selector(viewTapped), label: "Show the end of the selected conversation")
        cleanupButton = Kit.button("Clean up…", nil, #selector(cleanupTapped), label: "Move old or large sessions to the Trash")
        resumeButton = Kit.button("Resume", nil, #selector(resumeTapped), label: "Resume the selected session in a new terminal")
        exportButton = Kit.button("Export .md…", nil, #selector(exportTapped), label: "Export the selected conversation as Markdown")
        copyButton = Kit.button("Copy ID", nil, #selector(copyIDTapped), label: "Copy the selected session id")
        super.init(title: "Sessions")
        for b in [resumeButton, exportButton, copyButton, viewButton, cleanupButton] { b.target = self }
        useOwnHeading()   // WP6: heading "Agent Sessions" + Clean up… / Refresh like today's Muya

        search.placeholderString = "Search — or filter: session=muya include=v4.1 path=… id=…"
        search.setSpokenLabel("Search sessions")
        search.font = ThemeFont.mono(11); search.focusRingType = .none   // today's input: mono 11, no focus ring, not focused on arrival
        search.delegate = self
        search.sendsSearchStringImmediately = false
        searchBox = FieldBox(search, height: 28)
        let refresh = Kit.button("Refresh", self, #selector(refreshTapped), label: "Refresh the session list")
        let hint = Kit.label("Filters: session=name  include=text in the conversation  path=  id=  — combine them, e.g. session=muya include=v4.1", size: 11, color: Token.textSecondary)
        hint.font = ThemeFont.mono(11)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("s"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.indentationPerLevel = 0
        outline.dataSource = self
        outline.delegate = self
        outline.style = .plain; outline.backgroundColor = .clear
        outline.intercellSpacing = .zero
        outline.usesAutomaticRowHeights = false
        outline.doubleAction = #selector(resumeTapped)
        outline.target = self
        outline.onReturn = { [weak self] in self?.resumeTapped() }
        outline.menu = { let m = NSMenu(); m.delegate = self; return m }()
        let scroll = Kit.scroll(outline, label: "Sessions list")

        empty.alignment = .center
        let bottom = Kit.hstack([resumeButton, viewButton, exportButton, copyButton, NSView(), status], spacing: 8)
        for v in [searchBox!, hint, scroll, empty, bottom] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        accessory.addArrangedSubview(cleanupButton)
        accessory.addArrangedSubview(refresh)
        let heading = tabs
        tabs.onChange = { [weak self] i in self?.tabChanged(i) }
        let headClean = ThemedButton("Clean up…"), headRefresh = ThemedButton("Refresh")
        headClean.onClick = { [weak self] in self?.cleanupTapped() }
        headRefresh.onClick = { [weak self] in self?.refreshTapped() }
        for v in [heading, headClean, headRefresh] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 15), heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), heading.widthAnchor.constraint(equalToConstant: 300),
            headRefresh.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), headRefresh.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            headClean.trailingAnchor.constraint(equalTo: headRefresh.leadingAnchor, constant: -8), headClean.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
        ])
        transcript.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(transcript)
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: content.topAnchor), transcript.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            transcript.trailingAnchor.constraint(equalTo: content.trailingAnchor), transcript.widthAnchor.constraint(equalToConstant: 460),
        ])
        bottom.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchBox.topAnchor.constraint(equalTo: content.topAnchor, constant: 61),
            searchBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            searchBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            hint.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 5),
            hint.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: searchBox.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        bottom.isHidden = true   // WP6: the actions are on the cards now (the buttons stay for keyboard/menu actions)
        outline.selectionHighlightStyle = .none
        termView.translatesAutoresizingMaskIntoConstraints = false; termView.isHidden = true; content.addSubview(termView)
        NSLayoutConstraint.activate([
            termView.topAnchor.constraint(equalTo: content.topAnchor, constant: 56), termView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            termView.leadingAnchor.constraint(equalTo: content.leadingAnchor), termView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        listViews = [searchBox, hint, scroll, empty]
        updateButtons()
    }

    private var listViews: [NSView] = []
    func tabChanged(_ i: Int) {
        let history = i == 1
        for v in listViews { v.isHidden = history }
        termView.isHidden = !history
        if history { termView.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didShow() {
        reload()
        window?.makeFirstResponder(self)   // the search field is not focused on arrival (no focus ring), like today's page
        agentTimer?.invalidate()
        // The live list costs a `claude` process (~0.2 s CPU): once every 10 s, and only while this page is shown.
        agentTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.reloadAgents() }
        agentTimer?.tolerance = 3
    }

    override func didHide() {
        cancelSearch()
        agentTimer?.invalidate(); agentTimer = nil
        transcript.closeTapped()
    }

    // MARK: Data

    @objc func refreshTapped() { reload() }

    override func updateLayer() { layer?.backgroundColor = Theme.dynamic(.bgControl).cgColor }   // the page is bg-[var(--bg-control)]

    func reloadAgents() {
        if store.mockMode { agentRows = MockData.agents(home: store.home); agentError = nil; applyFilter(); return }   // dev mock mode
        agents.refresh { [weak self] r in
            guard let self else { return }
            switch r {
            case let .success(rows): self.agentRows = rows; self.agentError = nil; self.onAgents?(rows)
            case let .failure(e): self.agentRows = []; self.agentError = e.text
            }
            self.applyFilter()
        }
    }

    /// Ids of the sessions that are running: the clean-up never touches them.
    var liveIds: Set<String> { Set(agentRows.map(\.sessionId)) }

    func reload() {
        reloadAgents()
        if store.mockMode { entries = MockData.history(home: store.home); loadError = nil; applyFilter(); return }
        status.stringValue = "Loading…"
        store.call("sessions.history") { [weak self] r in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.entries = jsonObjects(v).compactMap(HistoryEntry.init(json:))
                self.cleanup?.setEntries(self.entries)
                self.loadError = nil
            case let .failure(e):
                self.loadError = describe(e)
            }
            self.applyFilter()
            self.startSearchIfNeeded()
        }
    }

    var query: SessionQuery { .parse(search.stringValue) }

    /// The entries the search request covers: every filter except the content term itself.
    private func searchScope() -> [HistoryEntry] {
        var q = query; q.text = ""; q.include = ""
        return SessionsLogic.filter(entries, q, matches: nil)
    }

    func applyFilter() {
        let shown = SessionsLogic.filter(entries, query, matches: matches)
        let q = query
        // Content filters cannot apply to a running session's live list: `include=` hides it.
        let liveShown = !q.include.isEmpty ? [] : agentRows.filter { a in
            (q.name.isEmpty || a.name.localizedCaseInsensitiveContains(q.name)) && (q.path.isEmpty || a.cwd.localizedCaseInsensitiveContains(q.path))
                && (q.id.isEmpty || a.sessionId.lowercased().hasPrefix(q.id.lowercased()))
                && (q.text.isEmpty || a.name.localizedCaseInsensitiveContains(q.text) || a.cwd.localizedCaseInsensitiveContains(q.text) || a.sessionId.lowercased().hasPrefix(q.text.lowercased()))
        }
        let flat = shown.sorted { $0.lastActivity > $1.lastActivity }
        updateBanner()
        nodes = (liveShown.isEmpty ? [] : [SessionNode(live: liveShown)]) + (bannerShown ? [SessionNode(banner: true)] : []) + (flat.isEmpty ? [] : [SessionNode(group: SessionsLogic.Group(cwd: "", entries: flat))])
        outline.reloadData()
        for n in nodes { outline.expandItem(n) }
        if let first = nodes.first(where: { $0.group != nil })?.group?.entries.first, outline.selectedRow < 0 {
            if let row = (0 ..< outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? SessionNode)?.entry == first }) {
                outline.selectRowIndexes([row], byExtendingSelection: false)
            }
        }
        if let loadError {
            empty.stringValue = "Could not read the sessions: \(loadError)"; empty.isHidden = false
            status.stringValue = ""
        } else {
            empty.stringValue = entries.isEmpty ? "No transcript history." : "No matching sessions."
            empty.isHidden = !shown.isEmpty || !liveShown.isEmpty
            status.stringValue = statusText(shown: shown.count) + (liveShown.isEmpty ? "" : " · \(liveShown.count) running") + (agentError.map { " · \($0)" } ?? "")
        }
        updateButtons()
    }

    /// The amber strip of today's Muya: how much history there is, and what clean-up would take.
    private func updateBanner() {
        let now = Date().timeIntervalSince1970 * 1000, day = 86_400_000.0
        let old = entries.filter { now - Double($0.lastModified) > 30 * day }.count
        let big = entries.filter { $0.sizeBytes > 100 * 1_048_576 }.count
        let total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let show = old > 0 || big > 0
        banner.set(text: "\(entries.count) sessions · \(SessionsLogic.byteSize(total))" + (old > 0 ? " · \(old) not used for 30+ days" : "") + (big > 0 ? " · \(big) over 100 MB" : "") + " — big histories slow Muya and Claude down")
        banner.onClean = { [weak self] in self?.cleanupTapped() }
        bannerShown = show
    }

    func statusText(shown: Int) -> String {
        if searching { return "Searching \(searchScope().count) sessions…" }
        let q = query
        if let term = q.contentTerm, matches != nil { return "\(shown) of \(entries.count) sessions · “\(term)”" }
        return shown == entries.count ? "\(entries.count) sessions" : "\(shown) of \(entries.count) sessions"
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) { searchTextChanged() }
    func searchFieldDidEndSearching(_ sender: NSSearchField) { searchTextChanged() }

    func searchTextChanged() {
        cancelSearch()
        matches = nil
        applyFilter()
        debounce?.invalidate()
        guard query.contentTerm != nil else { return }
        debounce = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in self?.startSearchIfNeeded() }
    }

    /// Sets the box and searches at once (test hook).
    func setSearch(_ text: String) {
        search.stringValue = text
        searchTextChanged()
        debounce?.invalidate()
        startSearchIfNeeded()
    }

    func startSearchIfNeeded() {
        guard let term = query.contentTerm, !entries.isEmpty else { return }
        cancelSearch()
        searchSerial += 1
        let serial = searchSerial
        searching = true
        applyFilter()
        let refs = searchScope().map { ["id": $0.sessionId, "cwd": $0.cwd, "path": $0.path] }
        searchReq = store.call("sessions.search", ["query": term, "sessions": refs]) { [weak self] r in
            guard let self, serial == self.searchSerial else { return }
            self.searching = false
            self.searchReq = 0
            if case let .success(v) = r, v is NSNull == false {
                self.matches = Dictionary(jsonObjects(v).compactMap(ContentMatch.init(json:)).map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
            } else if case let .failure(e) = r {
                self.status.stringValue = "Search failed: \(describe(e))"
            }
            self.applyFilter()
        }
    }

    func cancelSearch() {
        debounce?.invalidate()
        if searching { store.cancelCall(searchReq) }
        searching = false
        searchSerial += 1
    }

    // MARK: Selection and actions

    var selectedEntry: HistoryEntry? { (outline.item(atRow: outline.selectedRow) as? SessionNode)?.entry }
    var selectedAgent: AgentRow? { (outline.item(atRow: outline.selectedRow) as? SessionNode)?.agent }

    private func updateButtons() {
        let on = selectedEntry != nil
        for b in [resumeButton, exportButton, viewButton] { b.isEnabled = on }
        copyButton.isEnabled = on || selectedAgent != nil
    }

    @objc func viewTapped() { if let e = selectedEntry { showTranscript(e) } }
    func showTranscript(_ e: HistoryEntry) { transcript.show(e, projectsRoot: store.home + "/.claude/projects") }
    var transcriptPanel: TranscriptPanel { transcript }

    @objc func cleanupTapped() { openCleanup() }
    @discardableResult
    func openCleanup() -> CleanupSheet? {
        guard cleanup == nil, let w = window else { return nil }
        let sheet = CleanupSheet(window: w, home: store.home, entries: entries, live: liveIds, rpc: { [weak self] m, p, done in self?.store.call(m, p, completion: done) }) { [weak self] in self?.reload() }
        sheet.onClosed = { [weak self] in self?.cleanup = nil }
        cleanup = sheet
        return sheet
    }

    @objc func resumeTapped() { if let e = selectedEntry { resume(e) } }
    @objc func exportTapped() { if let e = selectedEntry { export(e) } }
    @objc func copyIDTapped() {
        guard let id = selectedEntry?.sessionId ?? selectedAgent?.sessionId else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        status.stringValue = "Copied \(id)"
    }

    func entry(id: String) -> HistoryEntry? { entries.first { $0.sessionId == id || $0.sessionId.hasPrefix(id) } }

    func resume(_ e: HistoryEntry) {
        guard let cmd = SessionsLogic.resumeCommand(e.sessionId) else { status.stringValue = "This session id cannot be resumed safely."; return }
        let cwd = FileManager.default.fileExists(atPath: e.cwd) ? e.cwd : store.home
        store.openShell(cwd: cwd, name: "↻ \(e.displayName)", typing: cmd)
        onResume?(e)
    }

    /// Asks where to save (or uses `exportDestination`), then the daemon writes the Markdown.
    func export(_ e: HistoryEntry) {
        if let dest = exportDestination { write(e, to: dest); return }
        let panel = NSSavePanel()
        panel.title = "Export conversation as Markdown"
        panel.nameFieldStringValue = SessionsLogic.exportFilename(label: e.name ?? "", id: e.sessionId)
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.beginSheetModal(for: window ?? NSApp.mainWindow ?? NSWindow()) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.write(e, to: url)
        }
    }

    func write(_ e: HistoryEntry, to url: URL) {
        store.call("sessions.export", ["sessionId": e.sessionId, "cwd": e.cwd, "path": e.path, "dest": url.path, "overwrite": true]) { [weak self] r in   // the save panel already asked about replacing
            switch r {
            case .success: self?.status.stringValue = "Exported to \(url.lastPathComponent)"; self?.lastExport = url.path
            case let .failure(err): self?.status.stringValue = "Export failed: \(describe(err))"; self?.lastExport = nil
            }
        }
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? SessionNode else { return nodes.count }
        return n.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? SessionNode else { return nodes[index] }
        return n.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SessionNode)?.isHeader == true }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SessionNode)?.isHeader == true }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? SessionNode).map { !$0.isHeader && !$0.isBanner } ?? false }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if (item as? SessionNode)?.agent != nil { return SessionCard.height + 6 }
        if (item as? SessionNode)?.isBanner == true { return 65 }
        guard let e = (item as? SessionNode)?.entry else { return 26 }
        return SessionCard.height + 6 + (matches?[e.sessionId]?.snippet.isEmpty == false ? SessionCard.snippetExtra : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }   // the two groups are always open

    private func cardHeight(_ node: SessionNode) -> CGFloat {
        guard let e = node.entry, matches?[e.sessionId]?.snippet.isEmpty == false else { return SessionCard.height }
        return SessionCard.height + SessionCard.snippetExtra
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! SessionNode
        let cell = NSTableCellView()
        if node.isBanner {
            banner.removeFromSuperview(); banner.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(banner)
            NSLayoutConstraint.activate([banner.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 20), banner.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -20),
                                         banner.topAnchor.constraint(equalTo: cell.topAnchor, constant: 23), banner.heightAnchor.constraint(equalToConstant: 36)])
            cell.setAccessibilityLabel("Clean-up suggestion")
            return cell
        }
        if let n = node.liveHeader {
            let h = SessionSectionHeader("LIVE SESSIONS (\(n))", color: .success); Kit.pin(h, in: cell, insets: NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
            cell.setAccessibilityLabel("Live sessions, \(n)")
            return cell
        }
        if let g = node.group {
            let h = SessionSectionHeader("PAST SESSIONS (\(g.entries.count))", color: .textMuted); Kit.pin(h, in: cell, insets: NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
            cell.setAccessibilityLabel("Past sessions, \(g.entries.count)")
            return cell
        }
        let card = SessionCard()
        let now = Date()
        var spoken = ""
        if let a = node.agent {
            card.title = a.name
            let waiting = a.status == "waiting-for-input"
            card.attention = waiting
            var pills: [SessionCard.Pill] = []
            if waiting { pills.append(.init(text: "NEEDS YOU", fg: .warningText, bg: .warningBg, border: .warningBorder, dot: .warning)) }
            if a.isOpencode { pills.append(.init(text: "OPENCODE", fg: .successText, bg: nil, raw: StatusPillColors.opencode)) }
            pills.append(.init(text: a.status.uppercased(), fg: .textMuted, bg: nil, raw: StatusPillColors.status(a.status)))
            card.pills = pills
            card.model = a.isOpencode ? "" : a.kind
            card.agentMeta = (a.cwd.abbreviatingHome(store.home), AgentsLogic.branch(of: a.cwd), AgentsLogic.duration(startedAt: a.startedAt, now: now))
            if store.mockMode, let m = MockData.sessionMeta(a.name) { card.agentMeta = (card.agentMeta!.folder, "main", m.duration); if !m.model { card.model = "" } }   // the web mock's rows
            // Today's buttons: .md always; opencode → Resume; attachable claude → Attach + Stop (red); otherwise Open.
            var acts: [(String, ThemedButton.Style, () -> Void)] = [(".md", .ghost, { [weak self] in
                if let e = self?.entry(id: a.sessionId) { self?.export(e) } else { self?.status.stringValue = "No transcript for this session yet." }
            })]
            let cwd = FileManager.default.fileExists(atPath: a.cwd) ? a.cwd : store.home
            if a.isOpencode {
                acts.append(("Resume", .ghost, { [weak self] in
                    guard let self, let cmd = AgentsLogic.opencodeResumeCommand(a.sessionId) else { return }
                    self.store.openShell(cwd: cwd, name: a.name, typing: cmd); self.onClose?()
                }))
            } else if a.attachable {
                acts.append(("Attach", .ghost, { [weak self] in
                    guard let self, let cmd = AgentsLogic.attachCommand(a.attachId ?? a.sessionId) else { return }
                    self.store.openShell(cwd: cwd, name: a.name, typing: cmd); self.onClose?()
                }))
                acts.append(("Stop", .danger, { [weak self] in
                    // `claude stop <id>` through the daemon (agents.stop), no confirmation — like today's Stop button.
                    guard let self else { return }
                    _ = self.store.call("agents.stop", ["id": a.attachId ?? a.sessionId]) { [weak self] _ in self?.reloadAgents() }
                }))
            } else {
                acts.append(("Open", .ghost, { [weak self] in self?.store.spawn(cwd: cwd, name: a.name); self?.onClose?() }))
            }
            card.actions = acts
            spoken = "\(a.name), \(a.status), \(card.agentMeta!.folder)"
        } else if let e = node.entry {
            card.title = e.displayName
            var meta = "\(e.cwd.abbreviatingHome(store.home)) · \(SessionsLogic.relativeTime(ms: e.lastActivity, now: now)) · \(SessionsLogic.byteSize(e.sizeBytes))"
            if meta.hasPrefix(" · ") { meta.removeFirst(3) }
            card.meta = meta
            card.sizeText = SessionsLogic.byteSize(e.sizeBytes)
            card.histMeta = (e.cwd.abbreviatingHome(store.home), SessionsLogic.relativeTime(ms: e.lastActivity, now: now), e.sessionId)
            if let m = matches?[e.sessionId], !m.snippet.isEmpty { card.snippet = "…\(m.snippet)…" }
            card.actions = [(".md", .ghost, { [weak self] in self?.export(e) }), ("View", .ghost, { [weak self] in self?.showTranscript(e) }), ("Resume", .ghost, { [weak self] in self?.resume(e) }), ("···", .ghost, { [weak self] in self?.rowMenu(e) })]
            spoken = "\(e.displayName), \(meta)"
        }
        card.selected = outline.row(forItem: node) == outline.selectedRow && outline.selectedRow >= 0
        card.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(card)
        NSLayoutConstraint.activate([card.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 20), card.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -20),
                                     card.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4), card.heightAnchor.constraint(equalToConstant: cardHeight(node))])
        cell.setAccessibilityLabel(spoken)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        outline.reloadData(forRowIndexes: IndexSet(0 ..< outline.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        if row >= 0, let n = outline.item(atRow: row) as? SessionNode, n.entry != nil { outline.selectRowIndexes([row], byExtendingSelection: false) }
        if let a = selectedAgent {
            let i = menu.addItem(withTitle: "Copy ID", action: #selector(copyIDTapped), keyEquivalent: ""); i.target = self
            if canSchedule?(a) == true { let sc = menu.addItem(withTitle: "Schedule…", action: #selector(scheduleAgentTapped), keyEquivalent: ""); sc.target = self }
            return
        }
        guard selectedEntry != nil else { return }
        for (t, a) in [("Resume", #selector(resumeTapped)), ("View", #selector(viewTapped)), ("Export .md…", #selector(exportTapped)), ("Copy ID", #selector(copyIDTapped))] {
            let i = menu.addItem(withTitle: t, action: a, keyEquivalent: ""); i.target = self
        }
        menu.addItem(.separator())
        let ar = menu.addItem(withTitle: "Archive", action: #selector(archiveRowTapped), keyEquivalent: ""); ar.target = self
        let tr = menu.addItem(withTitle: "Move to Trash…", action: #selector(trashRowTapped), keyEquivalent: ""); tr.target = self
    }

    @objc private func scheduleAgentTapped() { if let a = selectedAgent { onSchedule?(a) } }

    /// The "···" button of a past session (today's "Archive or move to the Trash" menu).
    private func rowMenu(_ e: HistoryEntry) {
        guard let w = window else { return }
        if let row = (0 ..< outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? SessionNode)?.entry?.path == e.path }) { outline.selectRowIndexes([row], byExtendingSelection: false) }
        let m = NSMenu()
        m.autoenablesItems = false
        let live = liveIds.contains(e.sessionId)
        let a = m.addItem(withTitle: "Archive", action: #selector(archiveRowTapped), keyEquivalent: ""); a.target = self; a.isEnabled = !live
        let t = m.addItem(withTitle: "Move to Trash…", action: #selector(trashRowTapped), keyEquivalent: ""); t.target = self; t.isEnabled = !live
        m.popUp(positioning: nil, at: outline.convert(w.mouseLocationOutsideOfEventStream, from: nil), in: outline)
    }

    /// "Archive" of a past session: the daemon moves the transcript and its folder into Muya's archive (restorable from Clean up → Archived).
    @objc func archiveRowTapped() {
        guard let e = selectedEntry else { return }
        status.stringValue = "Archiving…"
        store.call("sessions.archive", ["paths": [e.path], "liveIds": Array(liveIds)]) { [weak self] r in
            guard let self else { return }
            switch r {
            case let .success(v):
                if let o = CleanupLogic.parseOutcome(v) { self.status.stringValue = CleanupLogic.resultLine(verb: "Archived", done: o.done, skipped: o.skipped) }
                self.reload()
            case let .failure(err): self.status.stringValue = describe(err)
            }
        }
    }

    /// "Move to Trash…" of a past session: asks first (the web's Confirm dialog), then the transcript and its folder go to the Trash.
    @objc func trashRowTapped() {
        guard let e = selectedEntry, let w = window else { return }
        Dialogs.shared.confirm(over: w, title: "Move to Trash?", message: "“\(e.displayName)” and its folder go to the Trash. You can put them back from there.", confirmTitle: "Move to Trash", danger: true) { [weak self] in
            guard let self else { return }
            switch CleanupSheet.moveToTrash(e, root: self.store.home + "/.claude/projects", live: self.liveIds) {
            case .success: self.status.stringValue = "Moved to the Trash."; self.reload()
            case let .failure(f): self.status.stringValue = "Not moved: \(f.text)"
            }
        }
    }

    // MARK: Test hook

    func debugState() -> String {
        var lines = ["status=\(status.stringValue)", "searching=\(searching)", "matches=\(matches.map { String($0.count) } ?? "nil")"]
        for n in nodes {
            if n.isBanner { lines.append("banner"); continue }   // the clean-up strip row: neither live nor past
            if n.liveHeader != nil {
                lines.append("live\t\(n.children.count)")
                for c in n.children { guard let a = c.agent else { continue }; lines.append("  \(a.sessionId)\t\(a.name)\t\(a.status)\t\(a.cwd)\t\(a.waitingFor ?? "")") }
                continue
            }
            // The history is one flat list under a "PAST SESSIONS" header; every card carries its own folder (cwd, last field).
            guard let g = n.group else { continue }
            lines.append("past\t\(g.entries.count)")
            for e in g.entries { lines.append("  \(e.sessionId)\t\(e.displayName)\t\(matches?[e.sessionId]?.snippet ?? "")\t\(e.cwd)") }
        }
        return lines.joined(separator: "\n")
    }

    func select(id: String) -> Bool {
        for r in 0 ..< outline.numberOfRows {
            if let e = (outline.item(atRow: r) as? SessionNode)?.entry, e.sessionId.hasPrefix(id) {
                outline.selectRowIndexes([r], byExtendingSelection: false); return true
            }
        }
        return false
    }
}


/// Amber strip above the session list ("N sessions · 415 MB · … — big histories slow Muya and Claude down" + Clean up…).
final class CleanupBanner: FillView {
    private let label: NSTextField = { let l = Kit.label("", size: 11, color: Theme.dynamic(.warningText)); l.font = ThemeFont.mono(11); return l }()
    private let button = CardButton("Clean up…")
    var onClean: (() -> Void)? { didSet { button.onClick = { [weak self] in self?.onClean?() } } }
    init() {
        super.init(.warningBg)
        addSubview(label); addSubview(button)
        setAccessibilityRole(.group); setAccessibilityLabel("Clean-up suggestion")
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(text: String) { label.stringValue = text; needsLayout = true }
    override func layout() {
        super.layout()
        let bw = button.intrinsicContentSize.width
        button.frame = NSRect(x: bounds.width - 10 - bw, y: (bounds.height - CardButton.height) / 2, width: bw, height: CardButton.height)
        label.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: max(0, button.frame.minX - 24), height: 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Theme.dynamic(.warningBg).setFill(); p.fill(); Theme.dynamic(.warningBorder).setStroke(); p.stroke()
    }
}


/// The Tailwind colours of today's status pills (SessionsPage.tsx statusColor, and the opencode badge): foreground, fill, border.
enum StatusPillColors {
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a) }
    private static func pair(_ dark: NSColor, _ light: NSColor) -> NSColor { NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light } }
    static let opencode = (pair(hex(0x6EE7B7), hex(0x047857)), pair(hex(0x022C22, 0.4), hex(0xECFDF5)), pair(hex(0x047857), hex(0x6EE7B7)))
    static func status(_ s: String) -> (NSColor, NSColor, NSColor) {
        switch s {
        case "working": return (pair(hex(0x4ADE80), hex(0x047857)), pair(hex(0x14532D, 0.3), hex(0xECFDF5)), pair(hex(0x15803D), hex(0xA7F3D0)))
        case "waiting-for-input": return (pair(hex(0xFBBF24), hex(0xB45309)), pair(hex(0x78350F, 0.25), hex(0xFFFBEB)), pair(hex(0xD97706), hex(0xFDE68A)))
        case "stopped": return (pair(hex(0xF87171), hex(0xBE123C)), pair(hex(0x7F1D1D, 0.3), hex(0xFFF1F2)), pair(hex(0xB91C1C), hex(0xFECDD3)))
        default: return (hex(0x1D4ED8), hex(0xEFF6FF), hex(0xBFDBFE))
        }
    }
}
