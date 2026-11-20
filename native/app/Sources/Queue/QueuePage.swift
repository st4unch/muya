// The Queue page: one page with three tabs — Queue (push / merge), Branches (commit graph) and Kanban
// (PRD progress board). Destructive buttons show a confirmation sheet and, in this build, only LOG the command.

import AppKit

enum QueueTab: Int, CaseIterable {
    case queue, branches, kanban
    var title: String { ["Queue", "Branches", "Kanban"][rawValue] }
    var name: String { ["queue", "branches", "kanban"][rawValue] }
}

final class QueuePage: PageView, NSTableViewDataSource, NSTableViewDelegate {
    var source: QueueSource = LocalQueueSource()
    /// The folder the views describe (the selected terminal's folder).
    var cwdProvider: () -> String? = { nil }
    let actionLog = InterimActionLog()
    /// Tests and verify scripts skip the confirmation sheet.
    var autoConfirm = false

    private(set) var tab: QueueTab = .queue
    private(set) var snapshot = QueueSnapshot()
    private(set) var commits: [CommitNode] = []
    private(set) var board = KanbanBoard(cards: [])
    private(set) var lastMessage = ""
    private(set) var cwd = ""
    private var generation = 0
    private(set) var loading = false

    private let header = QueueHeader()
    private let segmented = ThemedSegmented(options: QueueTab.allCases.map(\.title))
    private let table = KeyTable()
    private let list = QueueListView()
    private let listScroll = NSScrollView()
    private let pushButton = ThemedButton("Push…", style: .primary)
    private let mergeButton = ThemedButton("Merge…")
    private let deleteButton = ThemedButton("Delete branch…", style: .danger)
    private let queueNote = MonoLabel("", size: 10, color: .textMuted)
    let dag = DagView()
    private let dagScroll = NSScrollView()
    private let branchCard = BranchCard()
    private let dagDetail = MonoLabel("", size: 10, color: .textMuted)
    private let branchesDoc = BranchesDoc()
    private let branchesScroll = NSScrollView()
    let kanban = KanbanView()
    private let kanbanScroll = NSScrollView()
    private let kanbanNote = MonoLabel("", size: 10, color: .textMuted)
    /// Folders the page tracks (today: the workspaces); the app wires this to its terminals' folders.
    var pathsProvider: () -> [String] = { [] }
    private(set) var tracked: [TrackedProject] = []
    private(set) var queuedPaths: [String] = []
    /// Where the queue is kept (the user's HOME; tests and dev stacks point it at a throwaway one).
    var prefsHome = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    private var mergeClean: [String: Bool] = [:]
    private enum BRow { case group(Int), entry(QueueEntry) }
    private var rows: [BRow] = []
    private static let groups: [(label: String, glyph: [String], tone: Theme.Token)] = [("PRODUCTION BRANCHES (PRD)", QT.shieldCheck, .success), ("ACTIVE WORKSPACE WIP", QT.zap, .warning), ("OPEN PENDING (PR/STALE)", QT.pullRequest, .accent)]
    private var panes: [QueueTab: NSView] = [:]

    init() {
        super.init(title: "Queue")
        // Today's Muya pages have their own header band, not a title bar with a Close button: hide the shared one
        // and let the content start at the top (Escape still closes the page).
        for v in subviews where v !== content { v.isHidden = true }
        for c in constraints where c.firstItem === content && c.firstAttribute == .top { c.isActive = false }
        content.topAnchor.constraint(equalTo: topAnchor).isActive = true
        header.translatesAutoresizingMaskIntoConstraints = false
        segmented.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header); header.addSubview(segmented)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor), header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 49),
            segmented.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16), segmented.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            segmented.heightAnchor.constraint(equalToConstant: 30), segmented.widthAnchor.constraint(equalToConstant: 216),
        ])
        segmented.onChange = { [weak self] i in self?.select(tab: QueueTab(rawValue: i) ?? .queue) }
        segmented.setAccessibilityLabel("Queue view")
        header.title = "Push / Merge Queue"
        buildQueue()
        buildBranches()
        buildKanban()
        for t in QueueTab.allCases { panes[t]?.isHidden = t != .queue }
        queuedPaths = QueuePrefs.load(home: prefsHome)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addPane(_ tab: QueueTab, _ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: header.bottomAnchor), v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor), v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        panes[tab] = v
    }

    // MARK: Build

    private func buildQueue() {
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        list.autoresizingMask = [.width]
        let pane = NSView()
        listScroll.translatesAutoresizingMaskIntoConstraints = false; pane.addSubview(listScroll)
        Kit.pin(listScroll, in: pane)
        addPane(.queue, pane)
    }

    private func buildBranches() {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch"))
        c.title = "Branch"; c.width = 400; c.minWidth = 100
        table.addTableColumn(c)
        table.headerView = nil
        table.style = .plain
        table.dataSource = self; table.delegate = self
        table.rowHeight = 68
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel("Branches: push and merge")
        table.onReturn = { [weak self] in self?.pushTapped() }
        for (b, label, act) in [(pushButton, "Push the selected branch", #selector(pushTapped)), (mergeButton, "Merge the selected branch into the base branch", #selector(mergeTapped)), (deleteButton, "Delete the selected merged branch", #selector(deleteTapped))] {
            b.setAccessibilityLabel(label); b.target = self; b.action = act; b.isEnabled = false; b.alphaValue = 0.4
        }
        let bar = Kit.hstack([pushButton, mergeButton, deleteButton, queueNote], spacing: 8)
        branchesDoc.install(card: branchCard, table: table, bar: bar, detail: dagDetail)
        dagScroll.documentView = dag
        dagScroll.hasVerticalScroller = true
        dagScroll.drawsBackground = false
        dag.autoresizingMask = [.width]
        dagScroll.contentView.postsBoundsChangedNotifications = true
        dag.onSelect = { [weak self] i in self?.dagSelected(i) }
        dagScroll.translatesAutoresizingMaskIntoConstraints = false
        branchCard.addSubview(dagScroll)
        NSLayoutConstraint.activate([
            dagScroll.topAnchor.constraint(equalTo: branchCard.topAnchor, constant: BranchCard.band), dagScroll.leadingAnchor.constraint(equalTo: branchCard.leadingAnchor, constant: 1), dagScroll.trailingAnchor.constraint(equalTo: branchCard.trailingAnchor, constant: -1),
            dagScroll.bottomAnchor.constraint(equalTo: branchCard.bottomAnchor, constant: -BranchCard.footer),
        ])
        branchesScroll.documentView = branchesDoc
        branchesScroll.hasVerticalScroller = true
        branchesScroll.drawsBackground = false
        branchesDoc.autoresizingMask = [.width]
        let pane = NSView()
        branchesScroll.translatesAutoresizingMaskIntoConstraints = false; pane.addSubview(branchesScroll)
        Kit.pin(branchesScroll, in: pane)
        addPane(.branches, pane)
    }

    private func buildKanban() {
        kanbanScroll.documentView = kanban
        kanbanScroll.hasVerticalScroller = true
        kanbanScroll.hasHorizontalScroller = true
        kanbanScroll.drawsBackground = false
        kanban.autoresizingMask = [.width]
        kanban.onMove = { [weak self] slug, col in self?.moveCard(slug, to: col) }
        let pane = NSView()
        kanbanScroll.translatesAutoresizingMaskIntoConstraints = false; pane.addSubview(kanbanScroll)
        kanbanNote.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(kanbanNote)
        kanbanNote.alignment = .right
        NSLayoutConstraint.activate([
            kanbanScroll.topAnchor.constraint(equalTo: pane.topAnchor), kanbanScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            kanbanScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor), kanbanScroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            kanbanNote.trailingAnchor.constraint(equalTo: segmented.leadingAnchor, constant: -14), kanbanNote.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            kanbanNote.leadingAnchor.constraint(greaterThanOrEqualTo: header.leadingAnchor, constant: 230),
        ])
        addPane(.kanban, pane)
    }

    // MARK: Tabs and loading

    func select(tab t: QueueTab) {
        tab = t
        segmented.selected = t.rawValue
        for (k, v) in panes { v.isHidden = k != t }
        kanbanNote.isHidden = t != .kanban
        branchesDoc.relayout()
        configureHeader()
        needsDisplay = true
        focusCurrent()
    }

    private func configureHeader() {
        switch tab {
        case .queue: header.icon = QT.pullRequest; header.title = "Push / Merge Queue"; header.pill = nil; header.border = false
        case .branches: header.icon = QT.gitBranch; header.title = "Branches"; header.pill = nil; header.border = true
        case .kanban: header.icon = QT.layers; header.title = "PRD Board"; header.pill = "\(board.cards.count) docs"; header.border = true
        }
    }

    // The page behind the cards: --bg-chrome for Queue and Branches, --bg-panel for the PRD board.
    override func updateLayer() { layer?.backgroundColor = Theme.dynamic(tab == .kanban ? .bgPanel : .bgChrome).cgColor }

    func focusCurrent() {
        switch tab {
        case .queue: window?.makeFirstResponder(listScroll)
        case .branches: window?.makeFirstResponder(dag)
        case .kanban: window?.makeFirstResponder(kanban)
        }
    }

    override func didShow() { reload(); focusCurrent() }
    override func becomeFirstResponder() -> Bool { focusCurrent(); return true }

    /// Reads all three views' data off the main thread and applies it if nothing newer was started.
    func reload(completion: (() -> Void)? = nil) {
        generation += 1
        let gen = generation
        let dir = cwdProvider() ?? NSHomeDirectory()
        cwd = dir
        loading = true
        let src = source
        var paths: [String] = []
        for p in pathsProvider() + queuedPaths where !paths.contains(p) { paths.append(p) }
        if paths.isEmpty, cwdProvider() != nil { paths = [dir] }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snap = src.queue(cwd: dir)
            let log = src.commits(cwd: dir, limit: 5000)
            let cards = src.cards(cwd: dir)
            let projects = src.tracked(paths: paths)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.loading = false
                self.tracked = projects
                self.apply(snapshot: snap, commits: log, cards: cards)
                completion?()
            }
        }
    }

    func apply(snapshot snap: QueueSnapshot, commits log: [CommitNode], cards: [KanbanCard]) {
        snapshot = snap
        commits = log
        board = KanbanBoard(cards: cards)
        let keep = selectedEntry?.branch
        buildRows()
        table.reloadData()
        configureHeader()
        if let keep { _ = select(branch: keep) } else if let i = rows.firstIndex(where: { if case .entry = $0 { return true } else { return false } }) { table.selectRowIndexes([i], byExtendingSelection: false) }
        queueNote.text = snap.root == nil ? "Not a git repository: \(cwd.abbreviatingHome(NSHomeDirectory()))" : "Base: \(snap.base)  ·  \(snap.entries.count) branches  ·  buttons only log the command (INTERIM)"
        updateButtons()
        branchesDoc.relayout()
        rebuildList()
        dag.set(commits: log, laneRows: DagLayout.layout(log))
        dagDetail.text = log.isEmpty ? "No commits." : "\(log.count) commits (newest first). ↑ ↓ ⇞ ⇟ ⌘↑ ⌘↓ to move."
        kanban.set(board: board, cwd: cwd)
        kanbanNote.text = board.cards.isEmpty ? "" : "\(board.cards.count) cards  ·  ⌥← ⌥→ or drag to move  ·  changes go to a temporary copy only (INTERIM)"
    }

    // MARK: Queue and tracked projects

    private func rebuildList() {
        func card(_ p: TrackedProject, queued: Bool) -> ProjectCard {
            let c = ProjectCard(p, queued: queued)
            c.mergeClean = mergeClean[p.path]
            c.add.onClick = { [weak self] in self?.addToQueue(p.path) }
            c.remove.onClick = { [weak self] in self?.removeFromQueue(p.path) }
            c.push.onClick = { [weak self] in self?.confirm(.push(branch: p.branch, remote: "origin", setUpstream: false)) }
            c.merge.onClick = { [weak self] in self?.confirm(.merge(branch: p.branch, into: p.base)) }
            return c
        }
        let git = tracked.filter(\.isGit)
        let queued = queuedPaths.compactMap { path in git.first { $0.path == path } }
        list.set(queued: queued.map { card($0, queued: true) }, tracked: git.map { p in let c = card(p, queued: false); c.add.isEnabled = !queuedPaths.contains(p.path); c.add.alphaValue = c.add.isEnabled ? 1 : 0.4; c.add.title = c.add.isEnabled ? "Add to queue" : "Queued"; return c })
    }

    func addToQueue(_ path: String) {
        guard !queuedPaths.contains(path), let p = tracked.first(where: { $0.path == path && $0.isGit }) else { return }
        queuedPaths.append(path)
        QueuePrefs.save(queuedPaths, home: prefsHome)
        rebuildList()
        let src = source
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = src.mergeCheck(path: p.path, branch: p.branch, base: p.base)
            DispatchQueue.main.async {
                guard let self else { return }
                if let ok { self.mergeClean[path] = ok }
                self.rebuildList()
            }
        }
    }

    func removeFromQueue(_ path: String) {
        queuedPaths.removeAll { $0 == path }
        mergeClean[path] = nil
        QueuePrefs.save(queuedPaths, home: prefsHome)
        rebuildList()
    }

    // MARK: Queue table

    /// PRD = the base branch, WIP = work that is not pushed or not clean, pending = ready, stale or merged.
    private static func group(of e: QueueEntry) -> Int {
        if e.isBase { return 0 }
        switch e.status {
        case .dirty, .pushNeeded, .noUpstream: return 1
        default: return 2
        }
    }

    private func buildRows() {
        rows = []
        for (g, _) in Self.groups.enumerated() {
            rows.append(.group(g))
            rows += snapshot.entries.filter { Self.group(of: $0) == g }.map { .entry($0) }
        }
    }

    var selectedEntry: QueueEntry? {
        let r = table.selectedRow
        if r >= 0, r < rows.count, case let .entry(e) = rows[r] { return e }
        return nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .group = rows[row] { return 30 }; return 68 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .entry = rows[row] { return true }; return false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { if case .entry = rows[row] { return QueueRowView() }; return NSTableRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let e: QueueEntry
        switch rows[row] {
        case let .group(g):
            let v = BranchSection(glyph: Self.groups[g].glyph, label: Self.groups[g].label, tone: Self.groups[g].tone)
            v.count = snapshot.entries.filter { Self.group(of: $0) == g }.count
            return v
        case let .entry(x): e = x
        }
        let cell = QueueRowCell()
        cell.name.text = e.isBase ? "\(e.branch)  (base)" : e.branch
        let tone = Self.tone(for: e.status)
        cell.pill.text = e.status.rawValue
        cell.pill.fg = Theme.dynamic(tone.fg); cell.pill.bg = Theme.dynamic(tone.bg); cell.pill.border = nil
        let wt = e.worktree.map { ($0 as NSString).lastPathComponent } ?? "–"
        cell.detail.text = "\(e.aheadBehindText)  ·  checks \(e.checksSummary)  ·  worktree \(wt)  ·  \(e.subject)"
        cell.setAccessibilityLabel("\(e.branch): \(e.status.rawValue). Checks " + e.checks.map { "\($0.name): \($0.pass ? "pass" : "fail")" }.joined(separator: ", "))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    static func tone(for s: QueueStatus) -> (fg: Theme.Token, bg: Theme.Token) {
        switch s {
        case .readyToMerge: return (.successText, .successBg)
        case .needsRebase, .dirty: return (.warningText, .warningBg)
        case .pushNeeded: return (.accent, .bgSelected)
        case .noUpstream, .merged, .upToDate: return (.textMuted, .bgControl)
        }
    }

    private func updateButtons() {
        let e = selectedEntry
        for (b, on) in [(pushButton, e?.canPush ?? false), (mergeButton, e?.canMerge ?? false), (deleteButton, e?.canDelete ?? false)] { b.isEnabled = on; b.alphaValue = on ? 1 : 0.4 }
    }

    func select(branch: String) -> Bool {
        guard let i = rows.firstIndex(where: { if case let .entry(e) = $0 { return e.branch == branch }; return false }) else { return false }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
        return true
    }

    // MARK: Destructive actions (INTERIM: log only)

    @objc func pushTapped() { if let e = selectedEntry, e.canPush { confirm(e.pushAction()) } }
    @objc func mergeTapped() { if let e = selectedEntry, e.canMerge { confirm(e.mergeAction()) } }
    @objc func deleteTapped() { if let e = selectedEntry, e.canDelete { confirm(e.deleteAction()) } }

    private var sheet: NSAlert?

    func confirm(_ action: QueueAction) {
        if autoConfirm || window == nil { run(action); return }
        let a = NSAlert()
        a.messageText = action.title
        a.informativeText = "This would run:\n\(action.commandLine)\n\nIn this build nothing is executed: the command is only logged."
        a.addButton(withTitle: action.verb)
        a.addButton(withTitle: "Cancel")
        a.buttons[0].setAccessibilityLabel("\(action.verb) (logs the command only)")
        a.buttons[1].keyEquivalent = "\u{1b}"
        sheet = a
        a.beginSheetModal(for: window!) { [weak self] r in
            self?.sheet = nil
            if r == .alertFirstButtonReturn { self?.run(action) }
        }
    }

    func run(_ action: QueueAction) {
        lastMessage = actionLog.record(action)
        queueNote.text = lastMessage
        NSAccessibility.post(element: queueNote, notification: .announcementRequested, userInfo: [.announcement: lastMessage])
    }

    var pendingSheetText: String? { sheet?.informativeText }
    func dismissSheet(confirm ok: Bool) {
        guard let a = sheet, let w = window else { return }
        w.endSheet(a.window, returnCode: ok ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    }

    // MARK: Branches

    private func dagSelected(_ i: Int) {
        guard i >= 0, i < commits.count else { dagDetail.text = ""; return }
        let c = commits[i]
        let date = c.time > 0 ? DateFormatter.localizedString(from: Date(timeIntervalSince1970: c.time), dateStyle: .medium, timeStyle: .short) : ""
        dagDetail.text = "\(c.short)  ·  \(c.author)  ·  \(date)  ·  \(c.subject)" + (c.refs.isEmpty ? "" : "  ·  " + c.refs.joined(separator: ", "))
    }

    // MARK: Kanban

    func moveCard(_ slug: String, to column: KanbanColumn) {
        guard board.move(slug: slug, to: column) else { return }
        kanban.set(board: board, cwd: cwd, keepSelection: slug)
        let src = source, dir = cwd
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = src.setStatus(slug: slug, column: column, cwd: dir)
            DispatchQueue.main.async {
                self?.lastMessage = ok ? "Moved \(slug) to \(column.title) (temporary copy only)" : "Could not save the move of \(slug)"
                self?.kanbanNote.text = self?.lastMessage ?? ""
            }
        }
    }

    // MARK: Test hooks

    func debugState() -> String {
        var s = "tab=\(tab.name) cwd=\(cwd.isEmpty ? "-" : "set") loading=\(loading) root=\(snapshot.root == nil ? "none" : "git") base=\(snapshot.base)\n"
        s += "queue: \(snapshot.entries.count) rows, selected=\(selectedEntry?.branch ?? "-")\n"
        for e in snapshot.entries { s += "  \(e.branch)\t\(e.status.rawValue)\t\(e.aheadBehindText)\t\(e.checksSummary)\tpush=\(e.canPush) merge=\(e.canMerge) delete=\(e.canDelete)\n" }
        s += "tracked: \(tracked.filter(\.isGit).count) git of \(tracked.count), queued=\(queuedPaths.count)\n"
        s += "branches: \(commits.count) commits, lanes<=\(dag.maxLanes), selected=\(dag.selected)\n"
        s += "kanban: " + KanbanColumn.allCases.map { "\($0.title)=\(board.cards(in: $0).count)" }.joined(separator: " ") + ", selected=\(kanban.selectedSlug ?? "-")\n"
        s += "log: \(actionLog.lines.count) \(actionLog.lines.last ?? "")"
        return s
    }
}
