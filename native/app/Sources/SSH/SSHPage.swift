// "SSH & Passwords" page: Servers, PSMP profiles, CyberArk browser and the Password Store, one segmented page
// over the terminal area. Every call goes through SSHService; while the daemon lacks a call the pane shows a
// clear "not available yet" state instead of failing. Secret fields are NSSecureTextField, values go into a
// SecretBuffer and are wiped after use; the Password Store never shows a value.

import AppKit

// MARK: State overlay

/// Centered message over a list: locked, not available yet, failed, or empty.
final class StateView: NSStackView {
    private let title = ThemedText.title("")
    private let detail = ThemedText.helper("")
    let button = ModalButton("", height: 32)
    var onButton: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .centerX; spacing = 8
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 380
        for v in [title, detail, button] { addArrangedSubview(v) }
        button.onClick = { [weak self] in self?.tapped() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title t: String, detail d: String, button b: String?, onButton cb: (() -> Void)? = nil) {
        title.stringValue = t; detail.stringValue = d
        button.isHidden = b == nil
        button.title = b ?? ""
        button.setAccessibilityLabel(b ?? "")
        button.invalidateIntrinsicContentSize()
        onButton = cb
        setAccessibilityLabel("\(t). \(d)")
        isHidden = false
    }

    func hide() { isHidden = true }
    var text: String { isHidden ? "" : "\(title.stringValue) — \(detail.stringValue)" }
    @objc private func tapped() { onButton?() }
}

// MARK: A list pane

@MainActor
class ListPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = KeyTable()
    let toolbar = NSStackView()
    let stateView = StateView()
    let message = Kit.label("", size: 11, color: Token.textSecondary, lines: 2)
    private let scroll: NSScrollView
    private let listBox: ThemedBox
    unowned let hub: SSHHubPage

    /// (id, title, width)
    var columns: [(String, String, CGFloat)] { [] }
    var rowCount: Int { 0 }
    func text(row: Int, column: String) -> String { "" }
    func selectionChanged() {}
    func activate() {}
    func reload() {}

    init(hub: SSHHubPage, label: String) {
        self.hub = hub
        scroll = Kit.scroll(table, label: label)
        listBox = ThemedBox(.card)
        super.init(frame: .zero)
        toolbar.orientation = .horizontal; toolbar.spacing = 8
        message.setAccessibilityLabel("Status")
        scroll.hasHorizontalScroller = false
        table.dataSource = self; table.delegate = self
        table.rowHeight = 40; table.style = .plain
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.target = self; table.doubleAction = #selector(doubleClicked)
        table.onReturn = { [weak self] in self?.activate() }
        table.headerView = nil
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        listBox.translatesAutoresizingMaskIntoConstraints = false
        Kit.pin(scroll, in: listBox, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        for v in [toolbar, listBox, stateView, message] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            listBox.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            listBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), listBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            listBox.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -8),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            message.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stateView.centerXAnchor.constraint(equalTo: listBox.centerXAnchor), stateView.centerYAnchor.constraint(equalTo: listBox.centerYAnchor),
            stateView.widthAnchor.constraint(lessThanOrEqualTo: listBox.widthAnchor, constant: -32),
        ])
        for (id, title, w) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = w; c.minWidth = 50
            table.addTableColumn(c)
        }
        table.tableColumns.last?.resizingMask = .autoresizingMask
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedRow: Int? { table.selectedRow >= 0 ? table.selectedRow : nil }
    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }
    @objc private func doubleClicked() { if table.clickedRow >= 0 { activate() } }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let first = id == columns.first?.0
        let t = NSTextField(labelWithString: text(row: row, column: id))
        t.font = first ? ThemeFont.sans(13, .semibold) : ThemeFont.mono(12)
        t.textColor = Theme.dynamic(first ? .text : .textTertiary); t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        t.setAccessibilityLabel("\(tableColumn?.title ?? id): \(t.stringValue)")
        return t
    }

    /// Shows the right overlay for a pane state; returns true when the list itself is shown.
    @discardableResult
    func present<T>(_ state: PaneState<T>, empty: String, unlock: Bool = true, retry: (() -> Void)? = nil) -> Bool {
        table.reloadData()
        switch state {
        case .loading:
            stateView.show(title: "Loading…", detail: "", button: nil)
            return false
        case let .ready(items):
            if let a = items as? [Any], a.isEmpty { stateView.show(title: empty, detail: "", button: nil); return true }
            stateView.hide(); return true
        case .locked:
            stateView.show(title: "The Password Store is locked", detail: "Unlock it to use stored passwords, keys and tokens. Secret values are never shown here.", button: unlock ? "Unlock…" : nil) { [weak self] in self?.hub.unlockStore() }
            return false
        case let .notWired(m):
            stateView.show(title: "Not available yet", detail: "\(m) Nothing is lost: this page lights up as soon as the daemon offers the call.", button: nil)
            return false
        case let .failed(m):
            stateView.show(title: "Something went wrong", detail: m, button: "Retry") { retry?() }
            return false
        }
    }

    func confirm(_ title: String, detail: String, button: String, destructive: Bool = false, then go: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = title; a.informativeText = detail
        a.addButton(withTitle: button); a.addButton(withTitle: "Cancel")
        if destructive { a.buttons[0].hasDestructiveAction = true }
        guard let w = window else { return }
        a.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { go() } }
    }

    func debugState() -> String { "rows=\(rowCount) state=\(stateView.text) message=\(message.stringValue)" }
}

// MARK: Servers

@MainActor
final class ServersPane: ListPane, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let countLabel = Kit.label("", size: 13, color: Theme.dynamic(.textSecondary))
    private let addButton = ModalButton("Add server", style: .primary, icon: .plus, height: 32, label: "Add a server")
    private let scroll = NSScrollView()
    private let doc = ServerCardsDocument()
    private(set) var rows: [SSHServer] = []
    private static let collapsedKey = "muya.ssh.servers.collapsed"
    private var collapsed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.collapsedKey) }
    }

    override var rowCount: Int { rows.count }
    override func text(row: Int, column: String) -> String { "" }

    init(hub: SSHHubPage) {
        super.init(hub: hub, label: "Servers list")
        search.placeholderString = "Search servers — label, host, username, group, tag…"
        search.setSpokenLabel("Search servers")
        search.delegate = self
        addButton.onClick = { [weak self] in self?.addTapped() }
        // Classic: row 1 = "N server(s)" on the left, "Add server" on the right; row 2 = the search field, full width.
        toolbar.orientation = .vertical; toolbar.alignment = .leading; toolbar.spacing = 12
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row1 = NSStackView(views: [countLabel, spacer, addButton])
        row1.orientation = .horizontal; row1.spacing = 8; row1.alignment = .centerY
        let box = FieldBox(search, height: 32)
        toolbar.addArrangedSubview(row1); toolbar.addArrangedSubview(box)
        for v in [row1, box] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true }
        // The cards replace the table; the shared overlay still shows loading / failed / empty.
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay; scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = doc
        doc.autoresizingMask = [.width]
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityLabel("Servers")
        guard let listBox = table.enclosingScrollView?.superview else { return }
        listBox.isHidden = true
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listBox.topAnchor), scroll.bottomAnchor.constraint(equalTo: listBox.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: listBox.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: listBox.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        doc.setFrameSize(NSSize(width: scroll.contentSize.width, height: doc.frame.height))
    }

    override func reload() {
        rows = hub.model.visibleServers
        let ready = hub.model.servers.isReady
        let list = present(hub.model.servers, empty: hub.model.filter.isEmpty ? "No servers yet" : "No server matches “\(hub.model.filter)”.", retry: { [weak hub] in hub?.reloadAll() })
        if !list { rows = [] }
        let all = hub.model.allServers.count
        countLabel.stringValue = ready ? "\(all) server(s)" : ""
        addButton.isEnabled = ready
        scroll.isHidden = !(ready && !rows.isEmpty)
        rebuild()
    }

    /// Redraws the cards from the rows, keeping the scroll position.
    private func rebuild() {
        let keep = scroll.contentView.bounds.origin
        let down = collapsed
        let groups = ServerGroup.make(rows).map { g -> GroupCardView in
            let cards: [FitCard] = down.contains(g.name) ? [] : g.items.map { s in
                ServerCardView(ServerCardModel(server: s, line: ServerCardLine.text(s, credName: { [weak self] in self?.hub.vault.label(forId: $0) })),
                               onConnect: { [weak self] in self?.connect(s) },
                               onEdit: { [weak self] in self?.hub.editServer(s) },
                               onDelete: { [weak self] in self?.delete(s) })
            }
            let v = GroupCardView(name: g.name, count: g.items.count, noun: "servers", collapsed: down.contains(g.name), cards: cards)
            v.onToggle = { [weak self] in
                guard let self else { return }
                var c = self.collapsed
                if c.contains(g.name) { c.remove(g.name) } else { c.insert(g.name) }
                self.collapsed = c
                self.rebuild()
            }
            return v
        }
        // classic keeps the PSMP profiles card at the bottom of this tab; there is no PSMP tab.
        let card = PSMPProfilesCard(profiles: hub.model.profileList,
                                    onAdd: { [weak self] in self?.hub.editProfile(nil) },
                                    onEdit: { [weak self] p in self?.hub.editProfile(p) },
                                    onDelete: { [weak self] p in self?.deleteProfile(p) })
        doc.set(groups, psmp: hub.model.servers.isReady ? card : nil)
        doc.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: keep)
    }

    var selected: SSHServer? { rows.first }

    func controlTextDidChange(_ obj: Notification) { hub.model.filter = search.stringValue; reload() }

    /// The drawn layout in one line, for the screenshot checks: which groups, how many cards, the PSMP card.
    func cardsSummary() -> String {
        let gs = doc.groups.map { "\($0.groupName)(\($0.itemCount))\($0.collapsed ? "-collapsed" : "")" }.joined(separator: ",")
        return "groups=[\(gs)] cards=\(rows.count) psmp=\(doc.psmp == nil ? 0 : hub.model.profileList.count)"
    }

    #if MUYA_TEST_HOOKS
    /// Debug socket `ssh-connect <title>`: presses that card's Connect button (what a click does).
    func debugConnect(_ title: String) -> String {
        connectServer(titled: title) ? "ok" : "error: no server titled '\(title)'"
    }

    /// Debug socket `ssh-group-toggle <name>`: collapses or expands that group.
    func debugToggleGroup(_ name: String) -> String {
        guard let g = doc.groups.first(where: { $0.groupName == name }) else { return "error: no group '\(name)'" }
        g.onToggle?()
        return "ok"
    }
    #endif

    /// Presses the Connect button of the card with this title; false when there is no such card.
    @discardableResult
    func connectServer(titled title: String) -> Bool {
        guard let s = rows.first(where: { $0.title == title }) else { return false }
        connect(s)
        return true
    }

    private func connect(_ s: SSHServer) {
        if let why = SSHConnect.precheck(s, profiles: hub.model.profileList) { message.stringValue = why; message.textColor = Token.statePermission; return }
        message.stringValue = "Opening \(s.destination)…"; message.textColor = Token.textSecondary
        let size = hub.terminalSize()
        hub.service.connect(server: s.id, cols: size.cols, rows: size.rows) { [weak self] r in
            switch r {
            case let .success(id): self?.message.stringValue = ""; self?.hub.focusSession(id)
            case let .failure(e): self?.message.stringValue = e.message; self?.message.textColor = Token.danger
            }
        }
    }

    @objc func addTapped() { hub.editServer(nil) }

    private func delete(_ s: SSHServer) {
        confirm("Delete “\(s.title)”?", detail: "Only the saved entry is removed. Any secret in the Password Store stays.", button: "Delete", destructive: true) { [weak self] in
            self?.hub.service.delete(server: s.id) { r in
                if case let .failure(e) = r { self?.message.stringValue = e.message; self?.message.textColor = Token.danger } else { self?.hub.reloadAll() }
            }
        }
    }

    private func deleteProfile(_ p: PSMPProfile) {
        confirm("Delete “\(p.title)”?", detail: "Servers that use this profile keep pointing at it until you edit them.", button: "Delete", destructive: true) { [weak self] in
            self?.hub.service.delete(profile: p.id) { r in
                if case let .failure(e) = r { self?.message.stringValue = e.message; self?.message.textColor = Token.danger } else { self?.hub.reloadAll() }
            }
        }
    }
}

// MARK: CyberArk

@MainActor
final class CyberArkPane: ListPane, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let newServer = ModalButton.action("New server from account…", nil, #selector(newServerTapped), label: "Create a server from the selected CyberArk account")
    private(set) var rows: [CyberArkAccount] = []

    override var columns: [(String, String, CGFloat)] { [("name", "Account", 260), ("addr", "Address", 170), ("user", "User", 110), ("safe", "Safe", 110), ("platform", "Platform", 100)] }
    override var rowCount: Int { rows.count }

    override func text(row: Int, column: String) -> String {
        let a = rows[row]
        switch column {
        case "name": return a.name
        case "addr": return a.address
        case "user": return a.username
        case "safe": return a.safe
        default: return a.platformId
        }
    }

    init(hub: SSHHubPage) {
        super.init(hub: hub, label: "CyberArk accounts")
        search.placeholderString = "Search accounts by name, address or safe"
        search.setSpokenLabel("Search CyberArk accounts")
        search.delegate = self
        search.sendsSearchStringImmediately = false
        search.target = self; search.action = #selector(searchTapped)
        newServer.target = self
        toolbar.addArrangedSubview(FieldBox(search, width: 360)); toolbar.addArrangedSubview(newServer)
        newServer.isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func reload() {
        rows = []
        if case let .ready(a) = hub.cyberark.state { rows = a }
        let ready = present(hub.cyberark.state, empty: hub.cyberark.summary, unlock: true, retry: { [weak self] in self?.searchTapped() })
        if !ready { rows = [] }
        // Before the first search the list is empty and the hint tells what to do.
        if ready, rows.isEmpty { stateView.show(title: hub.cyberark.summary, detail: "", button: nil) }
        table.reloadData()
        message.stringValue = ready ? hub.cyberark.summary : ""
        message.textColor = Token.textSecondary
        newServer.isEnabled = selectedRow != nil
    }

    override func selectionChanged() { newServer.isEnabled = selectedRow != nil }
    override func activate() { newServerTapped() }
    var selected: CyberArkAccount? { selectedRow.map { rows[$0] } }

    func controlTextDidChange(_ obj: Notification) { hub.cyberark.query = search.stringValue }

    func setQuery(_ q: String) { search.stringValue = q; hub.cyberark.query = q }

    @objc func searchTapped() {
        hub.cyberark.query = search.stringValue
        hub.runSearch()
    }

    @objc func newServerTapped() {
        guard let a = selected else { return }
        var s = SSHServer()
        s.label = a.name; s.host = a.address; s.username = a.username
        s.connectionType = .psmp; s.credentialKind = .cyberark; s.credentialRef = a.id
        hub.editServer(s, isNew: true)
    }
}

// MARK: Password Store

@MainActor
final class VaultPane: ListPane, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let status = Kit.label("", size: 13, color: Theme.dynamic(.success))
    private let addButton = ModalButton("Add credential", style: .primary, icon: .plus, height: 32, label: "Add a credential to the Password Store")
    private let touchButton = ModalButton("Enable Touch ID", icon: .fingerprint, height: 32, label: "Turn Touch ID unlock on or off")
    private let lockButton = ModalButton("Lock", icon: .lockIcon, height: 32, label: "Lock the Password Store")
    private let importKeyButton = ModalButton("Import SSH key", icon: .upload, height: 32, label: "Import an SSH private key from a file")
    private let importCredButton = ModalButton("Import credential", icon: .upload, height: 32, label: "Import a credential value from a file")
    private let exportBackupButton = ModalButton("Export backup", height: 32, label: "Export the encrypted store as a backup file")
    private let moreButton = ModalButton("More", icon: .chevronDown, height: 32, label: "Import and export")
    private let statusIcon = GlyphView(.unlock, size: 16, token: .success)
    private let scroll = NSScrollView()
    private let doc = CredCardsDocument()
    private(set) var rows: [SecretMeta] = []
    /// Values the operator chose to show (by secret id). Hidden again after 30 s, on lock and on delete.
    private(set) var revealed: [String: String] = [:]
    private var copiedId: String?
    /// The open form: editing this card in place, a new credential, or an import (classic's CredForm / import cards).
    private enum Editing: Equatable { case edit(String), new, importKey, importCred }
    private var editing: Editing?
    private var editValue = ""
    private(set) var form: CredFormCard?
    private var hideTimer: Timer?
    private var touchOn = false
    private static let collapsedKey = "muya.vault.collapsed"
    private var collapsed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.collapsedKey) }
    }

    override var rowCount: Int { rows.count }
    override func text(row: Int, column: String) -> String { "" }

    init(hub: SSHHubPage) {
        super.init(hub: hub, label: "Stored secrets")
        search.placeholderString = "Search credentials — label, username, group, note…"
        search.setSpokenLabel("Search credentials")
        search.delegate = self
        status.setAccessibilityLabel("Password Store status")
        addButton.onClick = { [weak self] in self?.beginNew() }
        touchButton.onClick = { [weak self] in self?.touchTapped() }
        lockButton.onClick = { [weak self] in self?.lockTapped() }
        importKeyButton.onClick = { [weak self] in self?.beginImport(key: true) }
        importCredButton.onClick = { [weak self] in self?.beginImport(key: false) }
        exportBackupButton.onClick = { [weak self] in self?.exportBackup() }
        moreButton.onClick = { [weak self] in self?.showMore() }
        moreButton.isHidden = true
        // Row 1: status on the left, actions on the right (classic). Row 2: the search field, full width. Below 760 px the
        // two ghost buttons drop their words and keep their icon / tooltip so the row never overflows.
        toolbar.orientation = .vertical; toolbar.alignment = .leading; toolbar.spacing = 12
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let statusBox = NSStackView(views: [statusIcon, status]); statusBox.orientation = .horizontal; statusBox.spacing = 4; statusBox.alignment = .centerY
        let row1 = NSStackView(views: [statusBox, spacer, addButton, importKeyButton, importCredButton, exportBackupButton, moreButton, touchButton, lockButton])
        row1.orientation = .horizontal; row1.spacing = 8; row1.alignment = .centerY
        let box = FieldBox(search, height: 32)
        toolbar.addArrangedSubview(row1); toolbar.addArrangedSubview(box)
        for v in [row1, box] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true }
        // The cards replace the table: same place, same states (locked / loading / failed use the shared overlay).
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay; scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = doc
        doc.autoresizingMask = [.width]
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityLabel("Stored secrets")
        guard let listBox = table.enclosingScrollView?.superview else { return }
        listBox.isHidden = true
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listBox.topAnchor), scroll.bottomAnchor.constraint(equalTo: listBox.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: listBox.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: listBox.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        doc.setFrameSize(NSSize(width: scroll.contentSize.width, height: doc.frame.height))
        // Classic's six buttons fit from ~900 px; below that the import / export ones move into a "More" menu.
        let compact = bounds.width < 900
        for b in [importKeyButton, importCredButton, exportBackupButton] { b.isHidden = compact }
        moreButton.isHidden = !compact
        let narrow = bounds.width < 760
        touchButton.title = narrow ? "Touch ID" : (touchOn ? "Disable Touch ID" : "Enable Touch ID")
        lockButton.title = narrow ? "" : "Lock"; lockButton.toolTip = "Lock the Password Store"; touchButton.toolTip = touchOn ? "Stop offering Touch ID unlock" : "Unlock with Touch ID next time, without the master password"
    }

    override func reload() {
        rows = hub.vault.visible
        let ready = hub.vault.secrets.isReady
        if !present(hub.vault.secrets, empty: hub.vault.filter.isEmpty ? "No credentials yet" : "No credentials match “\(hub.vault.filter)”.", retry: { [weak hub] in hub?.reloadAll() }) { rows = [] }
        if !ready { hideValues() }
        revealed = revealed.filter { k, _ in rows.contains { $0.id == k } }
        scroll.isHidden = !(ready && (!rows.isEmpty || (editing != nil)))
        status.stringValue = hub.vault.statusText
        statusIcon.isHidden = !ready
        if case .locked = hub.vault.secrets { status.textColor = Theme.dynamic(.warning) } else if ready { status.textColor = Theme.dynamic(.success) } else { status.textColor = Theme.dynamic(.textSecondary) }
        for b in [addButton, lockButton, touchButton, importKeyButton, importCredButton, exportBackupButton, moreButton] { b.isEnabled = ready }
        hub.service.vaultStatus { [weak self] st in
            guard let self else { return }
            self.touchOn = st.biometricAvailable
            self.needsLayout = true
        }
        rebuild()
    }

    /// Redraws the cards from the rows, keeping the scroll position.
    private func rebuild() {
        let keep = scroll.contentView.bounds.origin
        let searching = !hub.vault.filter.trimmingCharacters(in: .whitespaces).isEmpty
        let col = collapsed
        let groups = CredGroup.make(rows).map { g -> CredGroupView in
            var isCollapsed = !searching && col.contains(g.name)
            if case let .edit(id) = editing, g.items.contains(where: { $0.id == id }) { isCollapsed = false }
            let cards: [FitCard] = g.items.map { m -> FitCard in
                if case let .edit(id) = editing, id == m.id, let f = makeForm() { return f }
                return CredCardView(CredCardModel(meta: m, revealed: revealed[m.id], copied: copiedId == m.id),
                             onEye: { [weak self] in self?.toggleReveal(m) }, onCopy: { [weak self] in self?.copy(m) },
                             onEdit: { [weak self] in self?.beginEdit(m) }, onExport: { [weak self] in self?.exportCard(m) }, onDelete: { [weak self] in self?.delete(m) })
            }
            let v = CredGroupView(group: g, collapsed: isCollapsed, cards: cards)
            v.onToggle = { [weak self] in
                guard let self else { return }
                var c = self.collapsed
                if c.contains(g.name) { c.remove(g.name) } else { c.insert(g.name) }
                self.collapsed = c; self.rebuild()
            }
            return v
        }
        doc.set(groups)
        switch editing {
        case .new, .importKey, .importCred: doc.setTop(makeForm())
        default: doc.setTop(nil)
        }
        doc.setFrameSize(NSSize(width: scroll.contentSize.width, height: doc.frame.height))
        doc.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(keep.y, doc.frame.height - scroll.contentSize.height))))
    }

    func beginNew() { editing = .new; editValue = ""; rebuild(); scrollToTop() }
    func beginImport(key: Bool) { editing = key ? .importKey : .importCred; rebuild(); scrollToTop() }
    func beginEdit(_ m: SecretMeta) {
        hub.service.reveal(id: m.id) { [weak self] r in
            guard let self else { return }
            switch r {
            case let .success(v): self.editing = .edit(m.id); self.editValue = v; self.rebuild()
            case let .failure(e): self.showMessage(e.message, error: true)
            }
        }
    }
    func endEditing() { editing = nil; editValue = ""; rebuild() }
    private func scrollToTop() { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView); form?.focusFirst() }

    /// The form for the open editing state (nil when none). Saving goes to the daemon; the value never stays in a field.
    private func makeForm() -> CredFormCard? {
        guard let editing else { return nil }
        let meta: SecretMeta? = { if case let .edit(id) = editing { return rows.first { $0.id == id } }; return nil }()
        var v = CredFormCard.Values()
        var o: CredFormCard.Options
        switch editing {
        case .edit: o = .init(title: "Edit credential", primary: "Save")
            if let m = meta { v = .init(label: m.label, username: m.username, kind: m.kind, group: m.group, description: m.description, value: editValue) }
        case .new: o = .init(title: "New credential", primary: "Save")
        case .importKey: o = .init(title: "Import SSH key", primary: "Choose file…", showKind: false, showValue: false, showExtras: false); v.kind = "key"
        case .importCred: o = .init(title: "Import credential", primary: "Choose file…", showValue: false)
        }
        let f = CredFormCard(v, options: o)
        f.onCancel = { [weak self] in self?.endEditing() }
        f.onSave = { [weak self, weak f] vals in
            guard let self, let f else { return nil }
            return self.save(form: f, vals: vals, editing: editing, meta: meta)
        }
        form = f
        return f
    }

    private func save(form f: CredFormCard, vals: CredFormCard.Values, editing: Editing, meta: SecretMeta?) -> String? {
        let label = vals.label.trimmingCharacters(in: .whitespaces)
        switch editing {
        case .importKey, .importCred:
            let key = editing == .importKey
            let o = NSOpenPanel()
            o.title = key ? "Select SSH private key file" : "Select file containing the secret value"
            o.canChooseFiles = true; o.canChooseDirectories = false; o.allowsMultipleSelection = false
            guard o.runModal() == .OK, let url = o.url else { return nil }
            hub.service.importFile(label: label.isEmpty ? (key ? "imported key" : "imported credential") : label, username: vals.username, secretKind: key ? nil : vals.kind,
                                   description: vals.description, group: vals.group.trimmingCharacters(in: .whitespaces), path: url.path) { [weak self, weak f] r in
                switch r {
                case .success: self?.endEditing(); self?.showMessage("Imported “\(label.isEmpty ? url.lastPathComponent : label)”.", error: false); self?.hub.reloadAll()
                case let .failure(e): f?.showError(e.message)
                }
            }
            return nil
        case .new, .edit:
            let buf = SecretBuffer(vals.value)
            let others = hub.vault.visible.filter { $0.id != meta?.id }
            let errs = SSHValidation.secret(label: vals.label, kind: vals.kind, value: buf, existing: others, updating: false)
            if let first = errs.first { buf.wipe(); return first.message }
            f.clearSecret()
            hub.service.save(id: meta?.id ?? "", label: label, username: vals.username, group: vals.group.trimmingCharacters(in: .whitespaces), description: vals.description, kind: vals.kind, value: buf) { [weak self, weak f] r in
                switch r {
                case .success: self?.hideValues(); self?.endEditing(); self?.showMessage(meta != nil ? "Saved “\(label)”." : "Stored “\(label)”.", error: false); self?.hub.reloadAll()
                case let .failure(e): f?.showError("\(e.message) — type the value again to retry.")
                }
            }
            return nil
        }
    }

    func controlTextDidChange(_ obj: Notification) { hub.vault.filter = search.stringValue; reload() }
    func showMessage(_ t: String, error: Bool) { message.stringValue = t; message.textColor = error ? Token.statePermission : Token.textSecondary }

    func hideValues() { revealed = [:]; hideTimer?.invalidate(); hideTimer = nil; if doc.superview != nil, !rows.isEmpty { rebuild() } }

    func toggleReveal(_ s: SecretMeta) {
        if revealed[s.id] != nil { revealed[s.id] = nil; rebuild(); return }
        hub.service.reveal(id: s.id) { [weak self] r in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.revealed[s.id] = v
                self.hideTimer?.invalidate()
                self.hideTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.hideValues() } }
                self.rebuild()
                self.showMessage("Showing “\(s.label)” for 30 seconds.", error: false)
            case let .failure(e): self.showMessage(e.message, error: true)
            }
        }
    }

    func copy(_ s: SecretMeta) {
        hub.service.reveal(id: s.id) { [weak self] r in
            guard let self else { return }
            switch r {
            case let .success(v):
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(v, forType: .string)
                let mine = pb.changeCount
                self.copiedId = s.id; self.rebuild()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copiedId = nil; self?.rebuild() }
                self.showMessage("Copied “\(s.label)”. The clipboard is cleared in 30 seconds.", error: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if NSPasteboard.general.changeCount == mine { NSPasteboard.general.clearContents() } }
            case let .failure(e): self.showMessage(e.message, error: true)
            }
        }
    }

    /// Classic deletes at once, without a confirmation.
    func delete(_ s: SecretMeta) {
        hub.service.remove(id: s.id) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success: self.revealed[s.id] = nil; self.showMessage("Deleted “\(s.label)”.", error: false); self.hub.reloadAll()
            case let .failure(e): self.showMessage(e.message, error: true)
            }
        }
    }

    private func showMore() {
        let menu = NSMenu()
        for (title, act) in [("Import SSH key…", #selector(menuImportKey)), ("Import credential…", #selector(menuImportCred)), ("Export backup…", #selector(menuExportBackup))] {
            let i = NSMenuItem(title: title, action: act, keyEquivalent: ""); i.target = self; menu.addItem(i)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 2), in: moreButton)
    }
    @objc private func menuImportKey() { beginImport(key: true) }
    @objc private func menuImportCred() { beginImport(key: false) }
    @objc private func menuExportBackup() { exportBackup() }

    /// Classic: "Export encrypted store backup" -> muya-ssh-vault.enc.bak; the file stays sealed under the master password.
    func exportBackup() {
        let p = NSSavePanel()
        p.title = "Export encrypted store backup"; p.nameFieldStringValue = "muya-ssh-vault.enc.bak"
        guard p.runModal() == .OK, let url = p.url else { return }
        hub.service.exportBackup(dest: url.path) { [weak self] r in
            switch r {
            case .success: self?.showMessage("Encrypted backup exported to: \(url.path)", error: false)
            case let .failure(e): self?.showMessage(e.message, error: true)
            }
        }
    }

    /// Classic's per-card Export: the value as plain text in the file picked (owner-only).
    func exportCard(_ s: SecretMeta) {
        let p = NSSavePanel()
        p.title = "Export \(s.kind)"; p.nameFieldStringValue = (s.label.isEmpty ? s.username : s.label) + (s.kind == "key" ? "" : ".txt")
        guard p.runModal() == .OK, let url = p.url else { return }
        hub.service.exportCred(id: s.id, dest: url.path) { [weak self] r in
            switch r {
            case .success: self?.showMessage("\(s.kind == "key" ? "SSH key" : "Password") exported to: \(url.path)", error: false)
            case let .failure(e): self?.showMessage(e.message, error: true)
            }
        }
    }

    func touchTapped() {
        let want = !touchOn
        hub.service.setTouchId(want) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success: self.showMessage(want ? "Touch ID will unlock the Password Store." : "Touch ID unlock is off.", error: false); self.reload()
            case let .failure(e): self.showMessage(e.message, error: true)
            }
        }
    }

    func lockTapped() {
        hub.service.lock { [weak self] r in
            guard let self else { return }
            if case let .failure(e) = r { self.showMessage(e.message, error: true); return }
            self.hideValues(); self.hub.reloadAll()
        }
    }

    #if MUYA_TEST_HOOKS
    /// Debug socket: `show|copy|edit|delete <label>`, `lock`, `collapse <group>`, `rows`, `layout`.
    func debugAct(_ arg: String) -> String {
        let p = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch p.first ?? "" {
        case "rows": return rows.map { r in "\(r.label)|\(r.username)|\(r.group)|\(r.kind)|\(revealed[r.id] ?? "••••••••")" }.joined(separator: "\n")
        case "layout":
            let lines = doc.groups.map { g -> String in
                let box = "\(Int(g.frame.minX)),\(Int(g.frame.minY)) \(Int(g.frame.width))x\(Int(g.frame.height))"
                let cards = g.cards.map { c in "\(Int(c.frame.minX)),\(Int(c.frame.minY)) \(Int(c.frame.width))x\(Int(c.frame.height))" }.joined(separator: ";")
                return "\(g.groupName) \(box) cards=" + cards
            }
            let bar = "toolbar=\(touchButton.title)|\(lockButton.title) width=\(Int(bounds.width))"
            return lines.joined(separator: "\n") + "\n" + bar
        case "lock": lockTapped(); return "ok"
        case "new": beginNew(); return "ok"
        case "import": beginImport(key: p.count == 2 && p[1] == "key"); return "ok"
        case "formset":   // formset <id> <value>
            let q = (p.count == 2 ? p[1] : "").split(separator: " ", maxSplits: 1).map(String.init)
            guard let f = form, q.count == 2 else { return "error: no form open / formset <label|user|kind|group|desc|secret> <value>" }
            f.setValue(q[0], q[1]); return "ok"
        case "formsave": form?.submitForTest(); return form == nil ? "error: no form open" : "ok"
        case "formcancel": form?.cancelForTest(); return "ok"
        case "formstate": return form.map { f in "open kind=\(f.kind) error=\(f.values.value.isEmpty ? "value-empty" : "value-set")" } ?? "none"
        case "collapse":
            guard p.count == 2 else { return "error: collapse <group>" }
            var c = collapsed
            if c.contains(p[1]) { c.remove(p[1]) } else { c.insert(p[1]) }
            collapsed = c; rebuild(); return "ok"
        case let act where ["show", "copy", "edit", "delete"].contains(act):
            guard p.count == 2, let s = rows.first(where: { $0.label == p[1] }) else { return "error: no such secret" }
            switch act { case "show": toggleReveal(s); case "copy": copy(s); case "edit": beginEdit(s); default: hub.service.remove(id: s.id) { [weak self] _ in self?.hub.reloadAll() } }   // no confirmation sheet from the debug socket
            return "ok"
        default: return "error: ssh-secret show|copy|edit|delete <label> | lock | collapse <group> | rows | layout"
        }
    }
    #endif
}

// MARK: The page

@MainActor
final class SSHHubPage: PageView {
    let service: SSHService
    var model = ServersModel()
    var cyberark = CyberArkModel()
    var vault = VaultModel()
    /// Brings the tab the daemon opened for `Connect` to the front.
    let focusSession: (_ id: UInt64) -> Void
    let terminalSize: () -> (cols: Int, rows: Int)
    private var tabs: UnderlineTabs!
    private var panes: [SSHSection: ListPane] = [:]
    private(set) var section = SSHSection.servers
    private(set) var form: FormSheet?
    /// The sheet that is open now (debug socket and tests).
    var openForm: FormSheet? { form }
    private(set) var generation = 0

    var serversPane: ServersPane { panes[.servers] as! ServersPane }
    var cyberarkPane: CyberArkPane { panes[.cyberark] as! CyberArkPane }
    var vaultPane: VaultPane { panes[.vault] as! VaultPane }

    init(rpc: SSHRpc, terminalSize: @escaping () -> (cols: Int, rows: Int) = { (120, 30) }, focusSession: @escaping (_ id: UInt64) -> Void = { _ in }) {
        service = SSHService(rpc: rpc)
        self.focusSession = focusSession
        self.terminalSize = terminalSize
        super.init(title: "SSH & Passwords")
        useOwnHeading()
        tabs = UnderlineTabs(SSHSection.tabs.map(\.title))
        tabs.setSpokenLabel("Section")
        tabs.onChange = { [weak self] i in guard SSHSection.tabs.indices.contains(i) else { return }; self?.select(SSHSection.tabs[i]); self?.focusList() }
        panes = [.servers: ServersPane(hub: self), .cyberark: CyberArkPane(hub: self), .vault: VaultPane(hub: self)]
        let icon = GlyphView(.theme(.sshRail), size: 20, token: .textMuted)
        let heading = NSTextField(labelWithString: "SSH Configuration")
        heading.font = ThemeFont.sans(18, .semibold); heading.textColor = Theme.dynamic(.text); heading.setAccessibilityRole(.staticText)
        let head = Kit.hstack([icon, heading], spacing: 10)
        for v in [head, tabs] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            head.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            tabs.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 14),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        for (_, p) in panes {
            p.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(p)
            NSLayoutConstraint.activate([
                p.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 0),
                p.leadingAnchor.constraint(equalTo: content.leadingAnchor), p.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                p.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        select(.servers)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didShow() { reloadAll(); focusList() }
    override func didHide() { form?.close(); form = nil }

    func focusList() { if let p = panes[section] { window?.makeFirstResponder(p.table) } }

    func select(_ wanted: SSHSection) {
        // PSMP profiles are a card inside Servers now, so asking for that section lands on Servers.
        let s = wanted == .psmp ? .servers : wanted
        section = s
        // PSMP has no tab of its own (its card lives in Servers), so it shows the Servers tab.
        tabs.selected = SSHSection.tabs.firstIndex(of: s) ?? 0
        for (k, p) in panes { p.isHidden = k != s }
        panes[s]?.reload()
    }

    // MARK: Loading

    /// Reloads servers, profiles and the Password Store; each pane redraws as its answer arrives. A stale
    /// answer (an older reload finishing later) is ignored.
    /// The background service answered again: a page that showed "Something went wrong" because it was down loads itself now.
    func serviceCameBack() {
        func failed<T>(_ s: PaneState<T>) -> Bool { if case .failed = s { return true }; return false }
        if failed(model.servers) || failed(model.profiles) || failed(vault.secrets) { reloadAll() }
    }

    func reloadAll() {
        generation += 1
        let gen = generation
        model.servers = .loading; model.profiles = .loading; vault.secrets = .loading
        redraw()
        service.servers { [weak self] st in guard let self, gen == self.generation else { return }; self.model.servers = st; self.redraw() }
        service.profiles { [weak self] st in guard let self, gen == self.generation else { return }; self.model.profiles = st; self.redraw() }
        service.secrets { [weak self] st in guard let self, gen == self.generation else { return }; self.vault.secrets = st; self.redraw() }
    }

    func redraw() { for (_, p) in panes { p.reload() }; panes[section].map { _ in () } }

    func runSearch() {
        guard cyberark.canSearch else { return }
        cyberark.state = .loading; cyberark.searched = true
        cyberarkPane.reload()
        let q = cyberark.query
        service.searchAccounts(q) { [weak self] st in
            guard let self, q == self.cyberark.query else { return }
            self.cyberark.state = st
            self.cyberarkPane.reload()
        }
    }

    /// The daemon locked the store (idle limit or Lock): close an open sheet and show the locked state.
    func vaultWasLocked() { form?.close(); form = nil; reloadAll() }

    /// Touch ID first when it is set up, else (or after it fails / is cancelled) the master-password sheet.
    func unlockStore() {
        vaultPane.showMessage("", error: false)
        service.vaultStatus { [weak self] st in
            guard let self else { return }
            if st.unlocked { return self.reloadAll() }
            if !st.initialized { return self.askMaster(create: true) }
            guard st.biometricAvailable else { return self.askMaster(create: false) }
            self.vaultPane.showMessage("Waiting for Touch ID…", error: false)
            self.service.unlock(biometric: true) { [weak self] r in
                guard let self else { return }
                switch r {
                case .success: self.vaultPane.showMessage("", error: false); self.reloadAll()
                case let .failure(e): self.vaultPane.showMessage(e.message, error: true); self.askMaster(create: false)
                }
            }
        }
    }

    /// The master-password sheet (or the "create a store" one when this Mac has none yet).
    private func askMaster(create: Bool) {
        var fields = [FormField(id: "master", title: "Master password", helper: create ? "Protects every secret in the store. There is no way to recover it." : "The password you chose when you created the Password Store — the same one classic Muya uses.", kind: .secure)]
        if create { fields.append(FormField(id: "again", title: "Repeat it", kind: .secure)) }
        else { fields.append(FormField(id: "touch", title: "Touch ID", helper: "Unlock with your fingerprint next time.", kind: .check, value: "0")) }
        // Classic's create card: the text about AES-256-GCM, Create + "Export master password", and the plaintext warning.
        let sheetTitle: String = create ? "Create password store" : "Unlock Password Store"
        let subtitle: String? = create ? "Your credentials are stored encrypted with AES-256-GCM. Keep your master password safe — the app never stores it, so you can also export an encrypted backup once unlocked.\n⚠️ “Export master password” saves it to a plaintext file you pick. Prefer keeping it in a password manager — the app never stores it." : nil
        var extra: (title: String, action: (FormSheet) -> Void)?
        if create { extra = (title: "Export master password", action: { [weak self] sheet in self?.exportMaster(from: sheet) }) }
        let primaryTitle: String = create ? "Create" : "Unlock"
        let f = FormSheet(title: sheetTitle, subtitle: subtitle, fields: fields, primary: primaryTitle, extraButton: extra)
        f.validate = { v in
            if (v["master"] ?? "").isEmpty { return [FieldError(field: "master", message: "Type the master password")] }
            if create, v["master"] != v["again"] { return [FieldError(field: "again", message: "The two passwords differ")] }
            return []
        }
        f.onSubmit = { [weak self, weak f] v in
            guard let self, let f else { return }
            let buf = SecretBuffer(v["master"] ?? "")
            f.clearSecure()
            let finish: @MainActor (Result<String?, RpcFailure>) -> Void = { r in
                switch r {
                case let .success(note):
                    f.close(); self.form = nil
                    self.vaultPane.showMessage(note.map { "Unlocked. Touch ID was not turned on: \($0)" } ?? "", error: note != nil)
                    self.reloadAll()
                case let .failure(e): f.showErrors([], general: "\(e.message) — type the password again to retry.")
                }
            }
            if create { self.service.createStore(master: buf) { finish($0.map { _ in nil }) } }
            else { self.service.unlock(master: buf, enableTouchId: v["touch"] == "1", finish) }
        }
        present(f)
    }

    /// Classic's "Export master password": needs the master typed first; writes it in plain text to the file picked.
    private func exportMaster(from sheet: FormSheet?) {
        guard let sheet else { return }
        let master = sheet.value("master")
        guard master.count >= 4 else { sheet.showErrors([], general: "type the master password above first, then export it"); return }
        let p = NSSavePanel()
        p.title = "Export master password (PLAINTEXT)"; p.nameFieldStringValue = "muya-master-password.txt"
        guard p.runModal() == .OK, let url = p.url else { return }
        service.exportMaster(dest: url.path, master: SecretBuffer(master)) { r in
            switch r {
            case .success: sheet.showErrors([], general: "⚠️ Master password written in plaintext to: \(url.path) — store it somewhere safe.")
            case let .failure(e): sheet.showErrors([], general: e.message)
            }
        }
    }

    // MARK: Editors

    private func present(_ f: FormSheet) {
        form?.close()
        form = f
        guard let w = window else { return }
        f.present(on: w)
    }

    func editServer(_ existing: SSHServer?, isNew: Bool? = nil) {
        let creating = isNew ?? (existing == nil)
        let s = existing ?? SSHServer()
        let profiles = model.profileList
        let secretNames = vault.visible.map(\.label)
        let accountIds: [String] = { if case let .ready(a) = cyberark.state { return a.map(\.id) } else { return [] } }()
        let profileItems: [(value: String, title: String)] = profiles.isEmpty ? [("", "No PSMP profiles — add one first")] : profiles.map { ($0.id, $0.title) }
        let fields = [
            FormField(id: "label", title: "Name", helper: "Shown in the list. Optional.", value: s.label, placeholder: "Build host"),
            FormField(id: "host", title: "Host", helper: "A name or an address.", value: s.host, placeholder: "server.example.com"),
            FormField(id: "port", title: "Port", value: String(s.port)),
            FormField(id: "username", title: "User", value: s.username, placeholder: "admin"),
            FormField(id: "type", title: "Connection", helper: "PSMP goes through the CyberArk proxy.", kind: .popup([("direct", "Direct SSH"), ("psmp", "Via PSMP")]), value: s.connectionType.rawValue),
            FormField(id: "psmp", title: "PSMP profile", kind: .popup(profileItems), value: s.psmpProfileId ?? ""),
            FormField(id: "login", title: "Login", helper: "Where the password comes from.", kind: .popup(CredentialKind.allCases.map { ($0.rawValue, $0.title) }), value: s.credentialKind.rawValue),
            FormField(id: "ref", title: "Secret or account", helper: "The name of the secret, or the CyberArk account id. Never the password itself.", kind: .combo(s.credentialKind == .cyberark ? accountIds : secretNames), value: s.credentialRef ?? ""),
            FormField(id: "group", title: "Group", helper: "Servers with the same group are listed together.", value: s.group, placeholder: "Production"),
            FormField(id: "options", title: "ssh options", helper: "Extra options such as -J jump@host. Optional.", value: s.sshOptions),
            FormField(id: "agent", title: "Let agents use it", helper: "Claude agents may list and open this server. They never see the password.", kind: .check, value: s.agentAccess ? "1" : "0"),
        ]
        let f = FormSheet(title: creating ? "Add server" : "Edit server", fields: fields, primary: creating ? "Add" : "Save")
        let sync: (FormSheet) -> Void = { f in
            f.setHidden("psmp", f.value("type") != "psmp")
            f.setHidden("ref", f.value("login") == "prompt")
            f.setOptions("ref", f.value("login") == "cyberark" ? accountIds : secretNames)
        }
        sync(f)
        f.onChange = { id, f in if id == "type" || id == "login" { sync(f) } }
        let build: ([String: String]) -> SSHServer = { v in
            var n = s
            n.label = v["label"]?.trimmingCharacters(in: .whitespaces) ?? ""
            n.host = v["host"]?.trimmingCharacters(in: .whitespaces) ?? ""
            n.port = Int(v["port"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            n.username = v["username"]?.trimmingCharacters(in: .whitespaces) ?? ""
            n.connectionType = SSHConnectionType(rawValue: v["type"] ?? "") ?? .direct
            n.psmpProfileId = n.connectionType == .psmp ? v["psmp"] : nil
            n.credentialKind = CredentialKind(rawValue: v["login"] ?? "") ?? .prompt
            n.credentialRef = n.credentialKind == .prompt ? nil : v["ref"]?.trimmingCharacters(in: .whitespaces)
            n.group = v["group"]?.trimmingCharacters(in: .whitespaces) ?? ""
            n.sshOptions = v["options"]?.trimmingCharacters(in: .whitespaces) ?? ""
            n.agentAccess = v["agent"] == "1"
            if creating { n.id = "" }
            return n
        }
        let others: [SSHServer] = { if case let .ready(all) = model.servers { return all } else { return [] } }()
        f.validate = { v in
            var errs = SSHValidation.server(build(v), others: others, profiles: profiles)
            if Int(v["port"]?.trimmingCharacters(in: .whitespaces) ?? "") == nil, !errs.contains(where: { $0.field == "port" }) { errs.append(FieldError(field: "port", message: "Port must be a number")) }
            return errs
        }
        f.onSubmit = { [weak self, weak f] v in
            self?.service.save(server: build(v)) { r in
                switch r {
                case .success: f?.close(); self?.form = nil; self?.reloadAll()
                case let .failure(e): f?.showErrors([], general: e.message)
                }
            }
        }
        present(f)
    }

    func editProfile(_ existing: PSMPProfile?) {
        let p = existing ?? PSMPProfile()
        let creating = existing == nil
        let fields = [
            FormField(id: "label", title: "Name", value: p.label, placeholder: "Lab PSMP"),
            FormField(id: "addr", title: "PSMP address", helper: "Host name of the proxy only.", value: p.psmpAddress, placeholder: "psmp.example.com"),
            FormField(id: "vault", title: "Vault user", helper: "Your CyberArk user name.", value: p.vaultUser),
            FormField(id: "udelim", title: "User delimiter", value: p.userDelim),
            FormField(id: "pdelim", title: "Parameter delimiter", value: p.paramDelim),
            FormField(id: "scp", title: "scp options", helper: "Extra -o options for file copies. Optional.", value: p.scpOptions),
        ]
        let f = FormSheet(title: creating ? "Add PSMP profile" : "Edit PSMP profile", fields: fields, primary: creating ? "Add" : "Save")
        let build: ([String: String]) -> PSMPProfile = { v in
            var n = p
            n.label = v["label"]?.trimmingCharacters(in: .whitespaces) ?? ""
            n.psmpAddress = v["addr"]?.trimmingCharacters(in: .whitespaces) ?? ""
            n.vaultUser = v["vault"]?.trimmingCharacters(in: .whitespaces) ?? ""
            n.userDelim = v["udelim"]?.isEmpty == false ? v["udelim"]! : "@"
            n.paramDelim = v["pdelim"]?.isEmpty == false ? v["pdelim"]! : "#"
            n.scpOptions = v["scp"]?.trimmingCharacters(in: .whitespaces) ?? ""
            return n
        }
        f.validate = { v in
            SSHValidation.profile(build(v)).map { FieldError(field: ["psmpAddress": "addr", "vaultUser": "vault"][$0.field] ?? $0.field, message: $0.message) }
        }
        f.onSubmit = { [weak self, weak f] v in
            self?.service.save(profile: build(v)) { r in
                switch r {
                case .success: f?.close(); self?.form = nil; self?.reloadAll()
                case let .failure(e): f?.showErrors([], general: e.message)
                }
            }
        }
        present(f)
    }

    // MARK: Diagnostics

    func debugState() -> String {
        let p = panes[section]
        return "section=\(section.title) \(p?.debugState() ?? "")"
    }
}
