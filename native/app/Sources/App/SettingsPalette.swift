// The Settings window (rows laid out like SettingsModal: bold title, helper, control on the right; every
// change is stored at once — by muya-core through muyad for its own settings, in the app's prefs file for
// the rest) and the command palette (⌘K).

import AppKit

/// The Settings window: ⌘Return saves, Escape closes (today's modal).
final class SettingsWindow: NSWindow {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) { onSave?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    unowned let store: Store
    let window: SettingsWindow
    private var controls: [String: NSView] = [:]
    private let status = ThemedText.helper("Theme changes apply right away · switches apply on Save")
    private var saveButton: ModalButton!
    private var docView: NSView!
    private var stored: [String: String] = [:]
    private enum Footer: Equatable { case idle, saved, busy, error(String) }
    private var footer: Footer = .idle { didSet { refreshFooter() } }
    private var core: [String: Any] = [:]
    private var debug: [String: Any] = [:]
    private var loading = false
    /// Settings > Beta (BetaSection.swift): switch back to classic, beta self-update.
    private(set) lazy var beta = BetaSection(store: store, host: { [unowned self] in self.window })
    /// Settings > Paired Macs (PairedMacsSection.swift): scope and revoke of the bridge peers.
    private(set) lazy var peers = PairedMacsSection(store: store, host: { [unowned self] in self.window })
    /// Settings > Privacy (FullDiskAccessUI.swift): the optional Full Disk Access row.
    private(set) lazy var fda = MainActor.assumeIsolated { FDASection() }

    /// Modal width of today's SettingsModal (modalKit ModalShell).
    static let modalWidth: CGFloat = 480
    static let modalMaxHeight: CGFloat = 621

    init(store: Store) {
        self.store = store
        window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: Self.modalWidth, height: Self.modalMaxHeight),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.onSave = { [weak self] in self?.saveTapped() }
        window.onCancel = { [weak self] in self?.closeTapped() }
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setAccessibilityLabel("Settings")
        build()
    }

    /// Today's Settings text for the rows it words differently, and the order of its Startup rows.
    private static let helperText: [String: String] = [
        "openAtLogin": "Muya starts by itself when you log in to this Mac.",
        "keepRunningInBackground": "The red close button hides the window; sessions and schedules keep running. Click Muya in the Dock to bring it back, ⌘Q to quit.",
        "resumeOnLaunch": "Claude tabs from last time pick up their conversations without a click. If there are none, a new Claude session opens.",
        "claudeStatusInFooter": "Model, context, cost and limits of the session you're looking at. Muya adds its status line to ~/.claude/settings.json and keeps yours running. Off puts your own back.",
        "claudeCleanupDays": "Claude deletes sessions not used for this long when it starts. Old sessions make Muya and Claude slower. Sessions you archive in Sessions are kept.",
        "autoSave": "Files you edit in Muya are saved a second after you stop typing. Either way, Muya keeps their earlier versions; see Activity or File ▸ Version History (⇧⌘H).",
        "debugLog": "Each CyberArk logon/list/retrieve and SSH connect step is appended with a timestamp. Metadata only — never passwords, tokens or account secrets.",
        "autoApprove": "If you don't answer a Claude permission prompt within 2 seconds, Muya clicks Allow for you. Applies to every session, including ones you can't see.",
    ]
    private static let startupOrder = ["openAtLogin", "keepRunningInBackground", "resumeOnLaunch", "autoApprove"]
    private static var orderedRows: [SettingRow] {
        var rows = SettingsSchema.rows.map { r -> SettingRow in var r = r; if let h = helperText[r.id] { r.helper = h }; return r }
        let slots = rows.indices.filter { startupOrder.contains(rows[$0].id) }
        let sorted = startupOrder.compactMap { id in rows.first { $0.id == id } }
        for (i, slot) in slots.enumerated() { rows[slot] = sorted[i] }
        return rows
    }

    private func build() {
        // Body: sections (group label, then a rows box or a full-width control), like SettingsModal.
        var blocks: [NSView] = []
        var sectionRows: [NSView] = []
        var section = ""
        var sectionStarts = Set<Int>()
        func flush() {
            guard !sectionRows.isEmpty else { return }
            blocks.append(ModalLayout.rowsBox(sectionRows)); sectionRows = []
        }
        for row in Self.orderedRows {
            if row.section != section {
                flush(); section = row.section
                sectionStarts.insert(blocks.count)
                blocks.append(ThemedText.label(section))
            }
            let (ctl, layout) = makeControl(row)
            if row.id == "debugLogPath" {
                (ctl as? NSTextField)?.font = ThemeFont.mono(12)
                let col = Kit.vstack([ThemedText.label("Log file"), layout], spacing: 6)
                layout.translatesAutoresizingMaskIntoConstraints = false
                if let fb = layout as? FieldBox { fb.fixedWidth = nil; for c in fb.constraints where c.firstAttribute == .width { c.isActive = false } }
                layout.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
                sectionRows.append(col)
            } else if case .segmented = row.kind {
                layout.translatesAutoresizingMaskIntoConstraints = false
                blocks.append(layout)
                blocks.append(ThemedText.helper(row.helper))
            } else {
                sectionRows.append(ModalLayout.settingRow(title: row.title, helper: row.helper, control: layout))
            }
            _ = ctl
        }
        flush()
        // Native-only: the notes vault panel (P12). Today's modal has no such row.
        let vault = ThemedButton("Notes vault…"); vault.onClick = { [weak self] in MainActor.assumeIsolated { self?.showVault() } }
        vault.setAccessibilityLabel("Choose the Obsidian notes vault")
        sectionStarts.insert(blocks.count)
        blocks.append(ThemedText.label("Notes"))
        blocks.append(ModalLayout.rowsBox([ModalLayout.settingRow(title: "Notes vault", helper: "The Obsidian vault that notes are read from.", control: vault)]))
        sectionStarts.insert(blocks.count)
        let fdaBlocks = MainActor.assumeIsolated { fda.blocks() }
        privacyAnchor = fdaBlocks.first
        blocks.append(contentsOf: fdaBlocks)
        sectionStarts.insert(blocks.count)
        blocks.append(contentsOf: peers.blocks())
        sectionStarts.insert(blocks.count)
        blocks.append(contentsOf: beta.blocks())
        // Today's last line: open-source notice + button.
        let oss = ThemedText.helper("Muya is built on open-source software.")
        oss.textColor = Theme.dynamic(.textMuted)
        let licences = ModalButton("Open-source licenses", height: 28, label: "Show the third-party licences")
        licences.onClick = { [weak self] in self?.showLicences() }
        let ossSpacer = NSView(); ossSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sectionStarts.insert(blocks.count)
        blocks.append(Kit.hstack([oss, ossSpacer, licences], spacing: 8))
        let stack = Kit.vstack(blocks, spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (i, v) in blocks.enumerated() {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if i > 0, sectionStarts.contains(i) { stack.setCustomSpacing(22, after: blocks[i - 1]) }
        }
        let doc = ModalDocView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
        ])
        docView = doc
        let scroll = Kit.scroll(doc, label: "Settings")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        let clip = scroll.contentView
        doc.widthAnchor.constraint(equalTo: clip.widthAnchor).isActive = true

        // Header (56px, title 16 / 600, rule under it) and footer (rule above, helper left, buttons right).
        let titleLabel = NSTextField(labelWithString: "Settings")
        titleLabel.font = ThemeFont.sans(15, .semibold); titleLabel.textColor = Theme.dynamic(.text)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityRole(.staticText)
        let headRule = ModalRule(), footRule = ModalRule()
        let done = ModalButton("Close", height: 32); done.hpad = 7; done.onClick = { [weak self] in self?.closeTapped() }
        let save = ModalButton("Save", style: .primary, height: 32); save.onClick = { [weak self] in self?.saveTapped() }
        save.hpad = 14; saveButton = save; save.isEnabled = false
        let footerButtons = Kit.hstack([done, save], spacing: 8)
        let closeX = ModalButton("", icon: .close, iconOnly: true, label: "Close")
        closeX.onClick = { [weak self] in self?.closeTapped() }
        status.maximumNumberOfLines = 1; status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = Kit.hstack([status, footerButtons], spacing: 8)
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.distribution = .fill
        let root = ModalFill(.bgPanel)
        for v in [titleLabel, headRule, scroll, footRule, footer, closeX] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 19),
            closeX.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), closeX.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            headRule.topAnchor.constraint(equalTo: root.topAnchor, constant: 56),
            headRule.leadingAnchor.constraint(equalTo: root.leadingAnchor), headRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headRule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footRule.topAnchor),
            footRule.leadingAnchor.constraint(equalTo: root.leadingAnchor), footRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footRule.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window.contentView = root
        window.setContentSize(NSSize(width: Self.modalWidth, height: Self.modalMaxHeight))
    }

    /// Today's rule: the modal is as tall as its content, at most 85 % of the viewport (maxHeight: 85vh).
    private func fitHeight(in host: NSWindow?) {
        let viewport = host?.contentView?.bounds.height ?? host?.frame.height ?? 732
        docView.layoutSubtreeIfNeeded()
        let content = 56 + docView.fittingSize.height + 61
        window.setContentSize(NSSize(width: Self.modalWidth, height: min(content, (viewport * 0.85).rounded())))
    }

    /// The control (read and written by the value hooks) and the view that lays it out in its row.
    private func makeControl(_ row: SettingRow) -> (NSView, NSView) {
        let c: NSView, layout: NSView
        switch row.kind {
        case .toggle:
            let s = ThemedSwitch(); s.target = self; s.action = #selector(changed(_:)); c = s; layout = s
        case let .segmented(labels):
            let s = IconSegmented(options: labels, icons: row.id == "appearance" ? [.themeMonitor, .themeSun, .themeMoon] : [])
            s.target = self; s.action = #selector(changed(_:)); c = s; layout = s
        case let .popup(labels):
            let p = NSPopUpButton(frame: .zero, pullsDown: false); p.addItems(withTitles: labels); p.target = self; p.action = #selector(changed(_:)); c = p
            layout = FieldBox(p, width: 130)
        case .text:
            let f = Kit.field(row.id == "spotlightRoots" ? "~/work, ~/Documents" : "~/.claude/muya-debug.log", label: row.title); f.delegate = self; c = f
            layout = FieldBox(f, width: 200)
        }
        c.identifier = NSUserInterfaceItemIdentifier(row.id)
        if let ctl = c as? NSControl { ctl.setSpokenLabel(row.title) } else { c.setAccessibilityLabel(row.title) }
        c.setAccessibilityHelp(row.helper)
        controls[row.id] = c
        return (c, layout)
    }

    // MARK: Values

    /// Reads the stored values into the controls (on open and after a relaunch).
    func reload() {
        beta.reload()
        peers.reload()
        MainActor.assumeIsolated { fda.reload() }
        loading = true
        for row in SettingsSchema.rows where row.store == "ui" { show(row, store.prefs.get(row.id)) }
        loading = false
        if store.mockMode { // dev mock mode: no daemon, show the web mock's defaults
            loading = true
            let d: [String: Any] = ["keepRunningInBackground": true, "claudeStatusInFooter": true, "claudeCleanupDays": 30]
            for row in SettingsSchema.rows where row.store == "core" && !row.id.hasPrefix("debugLog") { show(row, d[row.id]) }
            show(SettingsSchema.rows.first { $0.id == "debugLog" }!, false)
            show(SettingsSchema.rows.first { $0.id == "debugLogPath" }!, "")
            loading = false
            return
        }
        store.call("prefs.get") { [weak self] r in
            guard let self else { return }
            if case let .success(v) = r, let d = v as? [String: Any] {
                self.core = d
                self.loading = true
                for row in SettingsSchema.rows where row.store == "core" && row.id.hasPrefix("debugLog") == false { self.show(row, d[row.id]) }
                self.loading = false
            } else if case let .failure(e) = r { self.footer = .error("Could not read the settings: \(describe(e))") }
        }
        store.call("debug_log.get") { [weak self] r in
            guard let self, case let .success(v) = r, let d = v as? [String: Any] else { return }
            self.debug = d
            self.loading = true
            self.show(SettingsSchema.rows.first { $0.id == "debugLog" }!, d["enabled"])
            self.show(SettingsSchema.rows.first { $0.id == "debugLogPath" }!, d["path"])
            self.loading = false
        }
    }

    private func show(_ row: SettingRow, _ value: Any?) {
        guard let c = controls[row.id] else { return }
        switch (row.kind, c) {
        case (.toggle, let s as ThemedSwitch): s.isOn = (value as? Bool) ?? false
        case let (.segmented(labels), s as IconSegmented): s.selected = labels.firstIndex(of: (value as? String) ?? "") ?? 0
        case (.popup, let p as NSPopUpButton):
            if row.id == "claudeCleanupDays" { p.selectItem(withTitle: SettingsSchema.cleanupLabel(days: (value as? NSNumber)?.intValue)) }
        case (.text, let f as NSTextField): f.stringValue = (value as? String) ?? ""
        default: break
        }
        stored[row.id] = self.value(of: row.id)
        refreshFooter()
    }

    func value(of id: String) -> String {
        switch controls[id] {
        case let s as ThemedSwitch: return s.isOn ? "on" : "off"
        case let s as IconSegmented: return s.options.indices.contains(s.selected) ? s.options[s.selected] : ""
        case let p as NSPopUpButton: return p.titleOfSelectedItem ?? ""
        case let f as NSTextField: return f.stringValue
        default: return "?"
        }
    }

    /// Sets a control the way the user would and stores the change (test hook).
    func set(_ id: String, _ text: String) -> Bool {
        guard let c = controls[id] else { return false }
        switch c {
        case let s as ThemedSwitch: s.isOn = ["on", "true", "1"].contains(text)
        case let s as IconSegmented:
            guard let i = s.options.firstIndex(of: text) else { return false }
            s.selected = i
        case let p as NSPopUpButton: guard p.itemTitles.contains(text) else { return false }; p.selectItem(withTitle: text)
        case let f as NSTextField: f.stringValue = text
        default: return false
        }
        commit(id)
        return true
    }

    /// Theme applies at once; every other row waits for Save (today's modal).
    @objc private func changed(_ sender: NSView) {
        guard !loading, let id = sender.identifier?.rawValue else { return }
        if id == "appearance" { commit(id) } else { footer = .idle; refreshFooter() }
    }

    func controlTextDidChange(_ obj: Notification) { footer = .idle; refreshFooter() }

    private var dirtyIDs: [String] {
        SettingsSchema.rows.map(\.id).filter { $0 != "appearance" && controls[$0] != nil && value(of: $0) != stored[$0] }
    }

    private func refreshFooter() {
        guard saveButton != nil else { return }
        let dirty = !dirtyIDs.isEmpty
        saveButton.isEnabled = dirty && footer != .busy
        saveButton.title = footer == .busy ? "Saving…" : "Save"
        switch footer {
        case .saved where !dirty: status.stringValue = "✓ Saved"; status.textColor = Theme.dynamic(.successText)
        case let .error(m): status.stringValue = m; status.textColor = Theme.dynamic(.dangerText)
        default:
            status.stringValue = dirty ? "Unsaved changes · ⌘ Enter to save" : "Theme changes apply right away · switches apply on Save"
            status.textColor = Theme.dynamic(.textFaint)
        }
    }

    @objc func saveTapped() {
        let ids = dirtyIDs
        guard !ids.isEmpty else { return }
        footer = .busy
        for id in ids { commit(id) }
        if footer == .busy { footer = .saved }
    }

    private func commit(_ id: String) {
        guard !loading, let row = SettingsSchema.rows.first(where: { $0.id == id }) else { return }
        let v = value(of: id)
        func done(_ r: Result<Any, ClientError>) {
            if case let .failure(e) = r { footer = .error("Not saved: \(describe(e))"); reload() } else { stored[id] = v; footer = .saved }
        }
        switch id {
        case "appearance":
            store.prefs.set(id, v)
            Self.applyAppearance(v)
            stored[id] = v
        case "spotlightRoots":
            store.prefs.set(id, v)
            stored[id] = v
        case _ where row.store == "ui":
            store.prefs.set(id, v == "on")
            stored[id] = v
            if id == "autoApprove" { store.evaluateAutoAllow() }
            if id == "openAtLogin", let problem = LoginItem.apply(v == "on", home: store.home) { footer = .error(problem) }
        case "keepRunningInBackground", "claudeStatusInFooter":
            store.call("prefs.set", [id: v == "on"], completion: done)
        case "claudeCleanupDays":
            let days = SettingsSchema.cleanupChoices.firstIndex(of: v).map { SettingsSchema.cleanupDays[$0] } ?? 30
            store.call("prefs.set", [id: days], completion: done)
        case "debugLog", "debugLogPath":
            store.call("debug_log.set", ["enabled": value(of: "debugLog") == "on", "path": value(of: "debugLogPath")], completion: done)
        default: break
        }
    }

    static func applyAppearance(_ name: String) {
        NSApp.appearance = name == "Light" ? NSAppearance(named: .aqua) : name == "Dark" ? NSAppearance(named: .darkAqua) : nil
    }

    /// Scrolls the body to its end (the Beta group sits near the bottom); the screenshot scripts use it.
    private weak var privacyAnchor: NSView?

    /// Scrolls the Privacy group to the top of the window (screenshots and tests).
    func scrollToPrivacy() {
        docView.layoutSubtreeIfNeeded()
        guard let sv = docView.enclosingScrollView, let a = privacyAnchor else { return }
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, a.convert(a.bounds, to: docView).minY - 16)))
        sv.reflectScrolledClipView(sv.contentView)
    }

    func scrollToEnd() {
        docView.layoutSubtreeIfNeeded()
        guard let sv = docView.enclosingScrollView else { return }
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, docView.bounds.height - sv.contentView.bounds.height)))
        sv.reflectScrolledClipView(sv.contentView)
    }

    func show() {
        reload()
        if !window.isVisible {
            if let host = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeMain && !($0.title == "Settings") }) {
                scrim = ModalScrim(over: host) { [weak self] in self?.closeTapped() }
            }
            fitHeight(in: NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeMain }))
            // Centred over the main window like today's modal over the app; on the screen when there is none.
            if let host = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeMain }) {
                window.setFrameOrigin(NSPoint(x: host.frame.midX - window.frame.width / 2, y: host.frame.midY - window.frame.height / 2))
            } else { window.center() }
        }
        window.makeKeyAndOrderFront(nil)
        scrim?.attach(window)
    }

    private var scrim: ModalScrim?
    func windowWillClose(_ notification: Notification) { scrim?.remove(); scrim = nil }

    @objc func closeTapped() { window.close() }

    // MARK: Licences

    /// The text of native/THIRD_PARTY_NOTICES.md as copied into the app bundle by build.sh.
    static func licencesText() -> String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"), let t = try? String(contentsOf: url, encoding: .utf8) else {
            return "The licence notices were not found in the app bundle."
        }
        return t
    }

    private(set) var licencesSheet: NSWindow?
    /// The "Vault Source" sheet (P12); nil while closed.
    private(set) var vaultPanel: VaultConfigPanel?

    @MainActor @objc func showVault() {
        guard vaultPanel == nil else { return }
        let p = VaultConfigPanel(rpc: StoreSSHRpc(store: store), parent: window)
        p.onClosed = { [weak self] in self?.vaultPanel = nil }
        vaultPanel = p
        p.present()
    }

    @objc func showLicences() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        tv.isEditable = false; tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = Token.text; tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.string = Self.licencesText()
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.setAccessibilityLabel("Third-party licences")
        let scroll = Kit.scroll(tv, label: "Third-party licences")
        let close = Kit.button("Close", self, #selector(closeLicences))
        close.keyEquivalent = "\u{1b}"
        let title = Kit.label("Third-party licences", size: 13, bold: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 520))
        for v in [title, scroll, close] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        let w = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = root
        w.setAccessibilityLabel("Third-party licences")
        licencesSheet = w
        window.beginSheet(w)
    }

    @objc func closeLicences() {
        guard let w = licencesSheet else { return }
        window.endSheet(w); w.orderOut(nil); licencesSheet = nil
    }
}

// MARK: - Command palette

final class PalettePanel: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let field = Kit.field("Search agents, files, commands — or files on this Mac…", label: "Command palette search")
    private let table = KeyTable()
    private let box = ThemedBox(.popover)
    private var boxHeight: NSLayoutConstraint!
    private var boxTop: NSLayoutConstraint!
    private(set) var all: [PaletteItem] = []
    private(set) var shown: [PaletteItem] = []
    var provider: (() -> [PaletteItem])?
    var onRun: ((PaletteItem) -> Void)?
    var onDismiss: (() -> Void)?
    /// Called (debounced) with the text being typed, for the asynchronous "files on this Mac" group.
    var onQueryChanged: ((String) -> Void)?
    private var queryDebounce: Timer?
    /// Results that arrive later (Spotlight); shown after the ranked items, never re-ranked.
    var extra: [PaletteItem] = [] {
        didSet { let keep = table.selectedRow; shown = rankedItems() + (field.stringValue.isEmpty ? [] : extra); table.reloadData(); resizeBox(); if keep >= 0, keep < shown.count { table.selectRowIndexes([keep], byExtendingSelection: false) } else if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) } }
    }

    /// Today's headings: Agents, Files, Commands (CommandPalette.tsx). The native groups map onto them.
    static func heading(_ group: String) -> String {
        switch group { case "Terminals": return "Agents"; case "Files on this Mac", "Files": return "Files"; case "Sessions": return "Sessions"; default: return group == "Views" ? "Commands" : group }
    }
    private func startsGroup(_ row: Int) -> Bool { row == 0 || Self.heading(shown[row].group) != Self.heading(shown[row - 1].group) }
    private static let itemHeight: CGFloat = 36, headingHeight: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        box.translatesAutoresizingMaskIntoConstraints = false
        field.font = ThemeFont.sans(14)
        field.isBordered = false; field.focusRingType = .none; field.drawsBackground = false; field.textColor = Theme.dynamic(.text)
        field.placeholderAttributedString = NSAttributedString(string: "Search agents, files, commands — or files on this Mac…", attributes: [.font: ThemeFont.sans(14), .foregroundColor: Theme.dynamic(.textMuted)])
        field.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("p")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col); table.headerView = nil; table.rowHeight = Self.itemHeight
        table.dataSource = self; table.delegate = self; table.style = .plain; table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.onReturn = { [weak self] in self?.runSelected() }
        table.doubleAction = #selector(runSelectedAction); table.target = self
        let scroll = Kit.scroll(table, label: "Command palette results")
        scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        let bar = PaletteFill(); bar.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(field)
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14), field.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
                                     field.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: -0.5)])
        for v in [bar, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        noResults.font = ThemeFont.sans(13); noResults.textColor = Theme.dynamic(.textMuted); noResults.isHidden = true   // CommandPalette.tsx: "No results"
        noResults.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(noResults)
        NSLayoutConstraint.activate([noResults.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20), noResults.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 20)])
        addSubview(box)
        boxHeight = box.heightAnchor.constraint(equalToConstant: 400)
        boxTop = box.topAnchor.constraint(equalTo: topAnchor, constant: 120)
        boxCenter = box.centerXAnchor.constraint(equalTo: centerXAnchor)
        NSLayoutConstraint.activate([
            boxCenter, boxTop, boxHeight,
            box.widthAnchor.constraint(equalToConstant: 560),
            bar.topAnchor.constraint(equalTo: box.topAnchor, constant: 1), bar.heightAnchor.constraint(equalToConstant: 44),
            bar.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1), bar.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command palette")
        isHidden = true
    }

    /// Input bar of the palette: --bg-input with a rule under it.
    private final class PaletteFill: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            Theme.dynamic(.bgInput).setFill(); bounds.fill()
            Theme.dynamic(.border).setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
        override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    }

    /// The card is centred in the window and 20 % from its top (today's palette is fixed to the window, not to the
    /// terminal area this panel sits in).
    override func layout() {
        super.layout()
        if let content = window?.contentView {
            let r = convert(bounds, to: content)             // this panel in the window's content coordinates
            let h = content.bounds.height
            let flippedTop = content.isFlipped ? r.minY : h - r.maxY
            boxTop.constant = (h * 0.2 - flippedTop).rounded()
            boxCenter.constant = (content.bounds.midX - r.midX).rounded()
            windowHeight = h
        } else { boxTop.constant = (bounds.height * 0.2).rounded(); windowHeight = bounds.height }
        resizeBox()
    }
    private var windowHeight: CGFloat = 732
    private var boxCenter: NSLayoutConstraint!

    /// Height of the card: the list's content, at most 55 % of the window (maxHeight: 55vh).
    private let noResults = NSTextField(labelWithString: "No results")
    private func resizeBox() {
        noResults.isHidden = !(shown.isEmpty && !field.stringValue.isEmpty)
        var h: CGFloat = 0
        for i in shown.indices { h += Self.itemHeight + (startsGroup(i) ? Self.headingHeight : 0) }
        let natural = 45 + 16 + max(h, 48)
        boxHeight?.constant = min(natural, max(120, (windowHeight * 0.55).rounded()))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { dismiss() } // a click outside the box closes it
    override func cancelOperation(_ sender: Any?) { dismiss() }

    var isOpen: Bool { !isHidden }

    /// Today's palette is fixed to the window, centred on it: on the first open this panel moves from the terminal area
    /// to the window's content view (above the frame), pinned to all four edges.
    private func moveToWindowRoot() {
        guard let content = window?.contentView, superview !== content else { return }
        removeFromSuperview()
        translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(self)
        NSLayoutConstraint.activate([topAnchor.constraint(equalTo: content.topAnchor), bottomAnchor.constraint(equalTo: content.bottomAnchor),
                                     leadingAnchor.constraint(equalTo: content.leadingAnchor), trailingAnchor.constraint(equalTo: content.trailingAnchor)])
    }

    func open() {
        moveToWindowRoot()
        all = provider?() ?? []
        extra = []
        field.stringValue = ""
        refilter()
        isHidden = false
        needsLayout = true; window?.contentView?.layoutSubtreeIfNeeded()   // the card's offsets come from where this panel sits: lay out once it is at the window root
        needsLayout = true; layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
    }

    func dismiss() {
        guard !isHidden else { return }
        queryDebounce?.invalidate()
        onQueryChanged?("")
        isHidden = true
        onDismiss?()
    }

    func setQuery(_ q: String) { field.stringValue = q; refilter(); queryDebounce?.invalidate(); onQueryChanged?(q) }

    /// Ranked by match, then laid out in today's group order (Agents, Files, Commands, then the rest); the rank decides inside a group.
    private func rankedItems() -> [PaletteItem] {
        let order = ["Agents": 0, "Files": 1, "Commands": 2]
        let ranked = Fuzzy.rank(all, field.stringValue)
        return ranked.enumerated().sorted { a, b in
            let ga = order[Self.heading(a.element.group)] ?? 3, gb = order[Self.heading(b.element.group)] ?? 3
            return ga != gb ? ga < gb : a.offset < b.offset
        }.map(\.element)
    }

    private func refilter() {
        if field.stringValue.isEmpty { extra = [] }
        shown = rankedItems() + (field.stringValue.isEmpty ? [] : extra)
        table.reloadData()
        resizeBox()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) {
        refilter()
        queryDebounce?.invalidate()
        let text = field.stringValue
        queryDebounce = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.onQueryChanged?(text) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        let r = min(max(table.selectedRow + d, 0), shown.count - 1)
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc private func runSelectedAction() { runSelected() }

    /// Selects the result with this id (test hook).
    func select(id: String) -> Bool {
        guard let i = shown.firstIndex(where: { $0.id == id }) else { return false }
        table.selectRowIndexes([i], byExtendingSelection: false)
        return true
    }

    func runSelected() {
        guard table.selectedRow >= 0, table.selectedRow < shown.count else { return }
        let item = shown[table.selectedRow]
        dismiss()
        onRun?(item)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { Self.itemHeight + (startsGroup(row) ? Self.headingHeight : 0) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRow(headingHeight: startsGroup(row) ? Self.headingHeight : 0) }

    /// Selected row = --bg-selected, rounded, below the group heading that may sit on top of the same row.
    private final class PaletteRow: NSTableRowView {
        let headingHeight: CGFloat
        init(headingHeight: CGFloat) { self.headingHeight = headingHeight; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func drawBackground(in dirtyRect: NSRect) {}
        override func drawSelection(in dirtyRect: NSRect) {
            let r = NSRect(x: 0, y: headingHeight, width: bounds.width, height: bounds.height - headingHeight)
            Theme.dynamic(.bgSelected).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
        override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let it = shown[row]
        let mono = it.group == "Files on this Mac" || it.group == "Files" || it.id.hasPrefix("file:")
        let title = NSTextField(labelWithString: it.title)
        title.font = mono ? ThemeFont.mono(13) : ThemeFont.sans(13); title.textColor = Theme.dynamic(.text); title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sub = NSTextField(labelWithString: it.subtitle)
        sub.font = ThemeFont.mono(11); sub.textColor = Theme.dynamic(.textMuted); sub.lineBreakMode = .byTruncatingMiddle
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = Kit.hstack([title, sub], spacing: 4)
        line.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(line)
        var cs = [line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), line.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
                  line.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: 0), line.heightAnchor.constraint(equalToConstant: Self.itemHeight)]
        if startsGroup(row) {
            let h = NSTextField(labelWithString: Self.heading(it.group))
            h.font = ThemeFont.sans(12, .semibold); h.textColor = Theme.dynamic(.textMuted)
            h.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(h)
            cs += [h.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), h.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8)]
        }
        NSLayoutConstraint.activate(cs)
        cell.setAccessibilityLabel("\(it.group): \(it.title) \(it.subtitle)")
        return cell
    }

    func debugState() -> String { shown.map { "\($0.id)\t\($0.group)\t\($0.title)\t\($0.subtitle)" }.joined(separator: "\n") }
}
