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
    private let connectButton = ModalButton.action("Connect", nil, #selector(connectTapped), label: "Connect to the selected server in a new terminal")
    private let addButton = ModalButton.action("Add server…", nil, #selector(addTapped), label: "Add a server")
    private let editButton = ModalButton.action("Edit…", nil, #selector(editTapped), label: "Edit the selected server")
    private let deleteButton = ModalButton.action("Delete…", nil, #selector(deleteTapped), label: "Delete the selected server")
    private(set) var rows: [SSHServer] = []

    override var columns: [(String, String, CGFloat)] { [("name", "Name", 170), ("dest", "Server", 230), ("login", "Login", 150), ("group", "Group", 100), ("agent", "Agents", 120)] }
    override var rowCount: Int { rows.count }

    override func text(row: Int, column: String) -> String {
        let s = rows[row]
        switch column {
        case "name": return s.title
        case "dest": return s.destination + (s.connectionType == .psmp ? " via \(hub.model.profileTitle(id: s.psmpProfileId))" : "")
        case "login": return s.credentialKind.title
        case "group": return s.group.isEmpty ? "—" : s.group
        default: return s.agentAdded ? "Added by agent" : (s.agentAccess ? "Allowed" : "Off")
        }
    }

    init(hub: SSHHubPage) {
        super.init(hub: hub, label: "Servers list")
        search.placeholderString = "Filter servers"
        search.setSpokenLabel("Filter servers")
        search.delegate = self
        for b in [connectButton, addButton, editButton, deleteButton] { b.target = self }
        for v in [FieldBox(search, width: 260), connectButton, addButton, editButton, deleteButton] as [NSView] { toolbar.addArrangedSubview(v) }
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func reload() {
        rows = hub.model.visibleServers
        let list = present(hub.model.servers, empty: hub.model.filter.isEmpty ? "No servers yet" : "No server matches the filter", retry: { [weak hub] in hub?.reloadAll() })
        if !list { rows = [] }
        table.reloadData()
        updateButtons()
    }

    func updateButtons() {
        let ready = hub.model.servers.isReady
        let sel = selectedRow != nil
        addButton.isEnabled = ready
        connectButton.isEnabled = sel
        editButton.isEnabled = sel && ready
        deleteButton.isEnabled = sel && ready
    }

    override func selectionChanged() { updateButtons() }
    override func activate() { connectTapped() }
    var selected: SSHServer? { selectedRow.map { rows[$0] } }

    func controlTextDidChange(_ obj: Notification) { hub.model.filter = search.stringValue; reload() }

    @objc func connectTapped() {
        guard let s = selected else { return }
        switch SSHConnect.plan(s) {
        case let .shell(cmd, name):
            message.stringValue = "Opening \(s.destination)…"; message.textColor = Token.textSecondary
            hub.connect(name, cmd)
        case let .notWired(why):
            message.stringValue = why; message.textColor = Token.statePermission
        }
    }

    @objc func addTapped() { hub.editServer(nil) }
    @objc func editTapped() { if let s = selected { hub.editServer(s) } }

    @objc func deleteTapped() {
        guard let s = selected else { return }
        confirm("Delete “\(s.title)”?", detail: "Only the saved entry is removed. Any secret in the Password Store stays.", button: "Delete", destructive: true) { [weak self] in
            self?.hub.service.delete(server: s.id) { r in
                if case let .failure(e) = r { self?.message.stringValue = e.message; self?.message.textColor = Token.danger } else { self?.hub.reloadAll() }
            }
        }
    }
}

// MARK: PSMP profiles

@MainActor
final class PSMPPane: ListPane {
    private let addButton = ModalButton.action("Add profile…", nil, #selector(addTapped), label: "Add a PSMP profile")
    private let editButton = ModalButton.action("Edit…", nil, #selector(editTapped), label: "Edit the selected PSMP profile")
    private let deleteButton = ModalButton.action("Delete…", nil, #selector(deleteTapped), label: "Delete the selected PSMP profile")
    private(set) var rows: [PSMPProfile] = []

    override var columns: [(String, String, CGFloat)] { [("name", "Name", 170), ("addr", "PSMP address", 230), ("user", "Vault user", 150), ("scp", "scp options", 120)] }
    override var rowCount: Int { rows.count }

    override func text(row: Int, column: String) -> String {
        let p = rows[row]
        switch column {
        case "name": return p.title
        case "addr": return p.psmpAddress
        case "user": return p.vaultUser
        default: return p.scpOptions.isEmpty ? "—" : p.scpOptions
        }
    }

    init(hub: SSHHubPage) {
        super.init(hub: hub, label: "PSMP profiles list")
        for b in [addButton, editButton, deleteButton] { b.target = self; toolbar.addArrangedSubview(b) }
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func reload() {
        rows = hub.model.profileList
        if !present(hub.model.profiles, empty: "No PSMP profiles yet", retry: { [weak hub] in hub?.reloadAll() }) { rows = [] }
        table.reloadData()
        updateButtons()
    }

    func updateButtons() {
        let ready = hub.model.profiles.isReady
        addButton.isEnabled = ready
        editButton.isEnabled = ready && selectedRow != nil
        deleteButton.isEnabled = ready && selectedRow != nil
    }

    override func selectionChanged() { updateButtons() }
    override func activate() { editTapped() }
    var selected: PSMPProfile? { selectedRow.map { rows[$0] } }
    @objc func addTapped() { hub.editProfile(nil) }
    @objc func editTapped() { if let p = selected { hub.editProfile(p) } }

    @objc func deleteTapped() {
        guard let p = selected else { return }
        let used = hub.model.servers.isReady ? hub.model.visibleServers.filter { $0.psmpProfileId == p.id }.count : 0
        confirm("Delete “\(p.title)”?", detail: used > 0 ? "\(used) server\(used == 1 ? "" : "s") use this profile and will stop connecting until you pick another." : "Servers do not use it.", button: "Delete", destructive: true) { [weak self] in
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
    private let status = Kit.label("", size: 12, bold: true)
    private let addButton = ModalButton.action("Add secret…", nil, #selector(addTapped), label: "Add a secret to the Password Store")
    private let updateButton = ModalButton.action("Update value…", nil, #selector(updateTapped), label: "Replace the value of the selected secret")
    private(set) var rows: [SecretMeta] = []

    override var columns: [(String, String, CGFloat)] { [("name", "Name", 220), ("kind", "Kind", 90), ("desc", "Description", 320)] }
    override var rowCount: Int { rows.count }

    override func text(row: Int, column: String) -> String {
        let s = rows[row]
        switch column {
        case "name": return s.label
        case "kind": return s.kind
        default: return s.description.isEmpty ? "—" : s.description
        }
    }

    init(hub: SSHHubPage) {
        super.init(hub: hub, label: "Secret names (values are never shown)")
        search.placeholderString = "Filter secrets"
        search.setSpokenLabel("Filter secrets")
        search.delegate = self
        status.setAccessibilityLabel("Password Store status")
        for b in [addButton, updateButton] { b.target = self }
        for v in [status, FieldBox(search, width: 260), addButton, updateButton] as [NSView] { toolbar.addArrangedSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func reload() {
        rows = hub.vault.visible
        if !present(hub.vault.secrets, empty: hub.vault.filter.isEmpty ? "No secrets yet" : "No secret matches the filter", retry: { [weak hub] in hub?.reloadAll() }) { rows = [] }
        table.reloadData()
        status.stringValue = hub.vault.statusText
        if case .locked = hub.vault.secrets { status.textColor = Token.statePermission } else if hub.vault.secrets.isReady { status.textColor = Token.success } else { status.textColor = Token.textSecondary }
        addButton.isEnabled = hub.vault.secrets.isReady
        updateButton.isEnabled = hub.vault.secrets.isReady && selectedRow != nil
    }

    override func selectionChanged() { updateButton.isEnabled = hub.vault.secrets.isReady && selectedRow != nil }
    override func activate() { updateTapped() }
    var selected: SecretMeta? { selectedRow.map { rows[$0] } }
    func controlTextDidChange(_ obj: Notification) { hub.vault.filter = search.stringValue; reload() }
    @objc func addTapped() { hub.editSecret(nil) }
    @objc func updateTapped() { if let s = selected { hub.editSecret(s) } }
    func showMessage(_ t: String, error: Bool) { message.stringValue = t; message.textColor = error ? Token.statePermission : Token.textSecondary }
}

// MARK: The page

@MainActor
final class SSHHubPage: PageView {
    let service: SSHService
    var model = ServersModel()
    var cyberark = CyberArkModel()
    var vault = VaultModel()
    let connect: (_ name: String, _ command: String) -> Void
    private var tabs: UnderlineTabs!
    private var panes: [SSHSection: ListPane] = [:]
    private(set) var section = SSHSection.servers
    private(set) var form: FormSheet?
    /// The sheet that is open now (debug socket and tests).
    var openForm: FormSheet? { form }
    private(set) var generation = 0

    var serversPane: ServersPane { panes[.servers] as! ServersPane }
    var psmpPane: PSMPPane { panes[.psmp] as! PSMPPane }
    var cyberarkPane: CyberArkPane { panes[.cyberark] as! CyberArkPane }
    var vaultPane: VaultPane { panes[.vault] as! VaultPane }

    init(rpc: SSHRpc, connect: @escaping (_ name: String, _ command: String) -> Void) {
        service = SSHService(rpc: rpc)
        self.connect = connect
        super.init(title: "SSH & Passwords")
        useOwnHeading()
        tabs = UnderlineTabs(SSHSection.allCases.map(\.title))
        tabs.setSpokenLabel("Section")
        tabs.onChange = { [weak self] i in if let s = SSHSection(rawValue: i) { self?.select(s); self?.focusList() } }
        panes = [.servers: ServersPane(hub: self), .psmp: PSMPPane(hub: self), .cyberark: CyberArkPane(hub: self), .vault: VaultPane(hub: self)]
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

    func select(_ s: SSHSection) {
        section = s
        tabs.selected = s.rawValue
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
        let f = FormSheet(title: create ? "Create Password Store" : "Unlock Password Store", fields: fields, primary: create ? "Create" : "Unlock")
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

    func editSecret(_ existing: SecretMeta?) {
        let updating = existing != nil
        var fields = [FormField(id: "label", title: "Name", helper: updating ? "The secret to replace." : "How servers and agents refer to it.", value: existing?.label ?? "", placeholder: "lab-admin")]
        if !updating {
            fields.append(FormField(id: "kind", title: "Kind", kind: .popup(SSHValidation.secretKinds.map { ($0, $0) }), value: "password"))
            fields.append(FormField(id: "desc", title: "Description", helper: "Optional. Shown in the list.", value: ""))
        }
        fields.append(FormField(id: "value", title: updating ? "New value" : "Value", helper: "Stored encrypted. Never shown again.", kind: .secure))
        let f = FormSheet(title: updating ? "Update secret" : "Add secret", fields: fields, primary: updating ? "Update…" : "Add…")
        if updating { (f.controls["label"] as? NSTextField)?.isEditable = false }
        let existingList = vault.visible
        f.validate = { v in
            let buf = SecretBuffer(v["value"] ?? "")
            defer { buf.wipe() }
            return SSHValidation.secret(label: v["label"] ?? "", kind: v["kind"] ?? existing?.kind ?? "password", value: buf, existing: existingList, updating: updating)
        }
        f.onSubmit = { [weak self, weak f] v in
            guard let self, let f else { return }
            let label = (v["label"] ?? "").trimmingCharacters(in: .whitespaces)
            let kind = v["kind"] ?? existing?.kind ?? "password"
            let buf = SecretBuffer(v["value"] ?? "")
            f.clearSecure() // the field is empty from here on; only the buffer holds the value
            let c = VaultModel.confirmText(label: label, kind: kind, updating: updating)
            let a = NSAlert()
            a.messageText = c.title; a.informativeText = c.detail
            a.addButton(withTitle: c.button); a.addButton(withTitle: "Cancel")
            a.beginSheetModal(for: f.window) { resp in
                guard resp == .alertFirstButtonReturn else { buf.wipe(); return }
                self.service.store(label: label, description: v["desc"] ?? "", kind: kind, value: buf, updating: updating) { r in
                    switch r {
                    case .success: f.close(); self.form = nil; self.vaultPane.showMessage(updating ? "Updated “\(label)”." : "Stored “\(label)”.", error: false); self.reloadAll()
                    case let .failure(e): f.showErrors([], general: "\(e.message) — type the value again to retry.")
                    }
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
