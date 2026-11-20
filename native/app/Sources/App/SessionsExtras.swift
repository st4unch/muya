// Sessions page extras: the transcript drawer ("View") and the clean-up dialog (move old or large
// transcripts to the Trash — nothing is ever deleted outright).

import AppKit

// MARK: - Transcript drawer

/// A panel that slides in at the right edge of the Sessions page and shows the end of one transcript.
final class TranscriptPanel: NSView {
    private let titleLabel = Kit.label("", size: 13, bold: true)
    private let note = Kit.label("", size: 11, color: Token.textSecondary)
    private let text = NSTextView()
    private(set) var shownId: String?
    private var serial = 0
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        text.isEditable = false; text.isRichText = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = Token.text; text.backgroundColor = .clear
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.setAccessibilityLabel("Transcript text")
        let scroll = Kit.scroll(text, label: "Transcript")
        let close = Kit.button("Close", self, #selector(closeTapped), label: "Close the transcript")
        let head = Kit.hstack([titleLabel, NSView(), close], spacing: 8)
        let sep = Kit.divider()
        for v in [head, note, sep, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            note.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: head.leadingAnchor), note.trailingAnchor.constraint(lessThanOrEqualTo: head.trailingAnchor),
            sep.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Transcript")
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Token.pageBackground.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor; layer?.borderWidth = 1
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func cancelOperation(_ sender: Any?) { closeTapped() }
    /// Test hook / the Sessions list calls this after files moved: the dialog's own lists are read again by the owner.
    @objc func closeTapped() { serial += 1; isHidden = true; shownId = nil; onClose?() }

    var contentText: String { text.string }
    var noteText: String { note.stringValue }

    /// Reads the end of the transcript off the main thread and shows it.
    func show(_ e: HistoryEntry, projectsRoot: String) {
        serial += 1
        let mine = serial
        shownId = e.sessionId
        titleLabel.stringValue = e.displayName
        note.stringValue = "Loading…"
        text.string = ""
        isHidden = false
        guard let path = CleanupLogic.checkedTranscript(e.path, root: projectsRoot) else {
            note.stringValue = "This transcript is outside Claude's projects folder and is not shown."
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try TranscriptLogic.tail(path: path) }
            DispatchQueue.main.async { [weak self] in
                guard let self, mine == self.serial else { return }
                switch result {
                case let .success(turns):
                    self.note.stringValue = turns.isEmpty ? "No messages in this session yet." : "\(turns.count) most recent message\(turns.count == 1 ? "" : "s")"
                    self.text.string = TranscriptLogic.render(turns)
                    self.text.scrollToEndOfDocument(nil)
                case let .failure(err):
                    self.note.stringValue = "Could not read the transcript: \(err.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Clean-up dialog

final class CleanupSheet: NSObject {
    private let home: String
    private let projectsRoot: String
    private(set) var entries: [HistoryEntry]
    private let live: Set<String>
    private let onChanged: () -> Void
    let window: DialogPanel
    private let status = ThemedText.helper("")
    private let trashButton = ThemedButton("Move to Trash")
    private let actionButton = ThemedButton("Archive", style: .primary)   // Archive on the Clean up tab, Restore on the Archived one
    private let tabs = ThemedSegmented(options: ["Clean up", "Archived (0)"])
    private let intro = ThemedText.helper("")
    private var rulesBox: NSView?
    /// sessions.archived / sessions.archive / sessions.restore of muyad (today's list_archived_sessions, archive_sessions, restore_sessions).
    private let rpc: (String, [String: Any], @escaping (Result<Any, ClientError>) -> Void) -> Void
    private(set) var archived: [HistoryEntry] = []
    private(set) var tab = 0   // 0 Clean up, 1 Archived
    private var archiveRoot: String { home + "/Library/Application Support/com.staunch.muya/session-archive" }
    private let olderSelect = ThemedSelect(CleanupLogic.olderChoices.map { "\($0) days" }, selected: 2)
    private let largerSelect = ThemedSelect(CleanupLogic.largerChoices.map { "\($0) MB" }, selected: 1)
    private let olderSwitch = ThemedSwitch(isOn: true)
    private let largerSwitch = ThemedSwitch(isOn: true)
    private let listHost = NSStackView()
    private var listBox: ThemedBox?
    private(set) var rules = CleanupLogic.Rules()
    private(set) var candidates: [HistoryEntry] = []
    private(set) var unticked = Set<String>()
    private(set) var running = false
    private(set) var lastResult = ""
    var now: () -> Date = { Date() }
    private var scrim: ModalScrim?

    init(window parent: NSWindow, home: String, entries: [HistoryEntry], live: Set<String>, rpc: @escaping (String, [String: Any], @escaping (Result<Any, ClientError>) -> Void) -> Void, onChanged: @escaping () -> Void) {
        self.rpc = rpc; self.home = home; self.entries = entries; self.live = live; self.onChanged = onChanged
        projectsRoot = home + "/.claude/projects"
        window = DialogPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 525), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        build()
        recompute()
        loadArchived()
        parentWindow = parent
        window.isReleasedWhenClosed = false; window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = true
        window.onCancel = { [weak self] in self?.closeTapped() }
        let s = ModalScrim(over: parent) { [weak self] in self?.closeTapped() }
        s.attach(window)
        let f = parent.frame
        window.setFrameOrigin(NSPoint(x: f.midX - 300, y: f.midY - 262))
        window.makeKeyAndOrderFront(nil)
        scrim = s
    }

    private var parentWindow: NSWindow?

    private func build() {
        olderSwitch.onChange = { [weak self] _ in self?.rulesChanged() }
        largerSwitch.onChange = { [weak self] _ in self?.rulesChanged() }
        olderSelect.onChange = { [weak self] _ in self?.rulesChanged() }
        largerSelect.onChange = { [weak self] _ in self?.rulesChanged() }
        olderSelect.setAccessibilityLabel("Not used for value"); largerSelect.setAccessibilityLabel("Larger than value")
        olderSwitch.setAccessibilityLabel("Not used for"); largerSwitch.setAccessibilityLabel("Larger than")
        trashButton.onClick = { [weak self] in self?.trashTapped() }
        trashButton.setAccessibilityLabel("Move the ticked sessions to the Trash")
        actionButton.onClick = { [weak self] in self?.archiveTapped() }
        tabs.onChange = { [weak self] i in self?.selectTab(i) }
        let close = ThemedButton("Close")
        close.onClick = { [weak self] in self?.closeTapped() }

        let frame = ModalFrame.make(title: "Clean up Claude sessions", footerLeft: status, footerRight: [trashButton, actionButton], width: 600, height: 525, bodyTop: 20, onClose: { [weak self] in self?.closeTapped() })
        _ = close
        intro.maximumNumberOfLines = 0; intro.preferredMaxLayoutWidth = 560
        func rule(_ t: String, _ select: ThemedSelect, _ sw: ThemedSwitch) -> NSView {
            let l = ThemedText.title(t)
            let r = Kit.hstack([l, NSView(), select, sw], spacing: 10)
            return r
        }
        let rulesBox = ModalLayout.rowsBox([rule("Not used for", olderSelect, olderSwitch), rule("Larger than", largerSelect, largerSwitch)])
        self.rulesBox = rulesBox
        listHost.orientation = .vertical; listHost.alignment = .leading; listHost.spacing = 0
        listHost.translatesAutoresizingMaskIntoConstraints = false
        let box = ThemedBox(.rows)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(listHost)
        NSLayoutConstraint.activate([
            listHost.topAnchor.constraint(equalTo: box.topAnchor), listHost.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            listHost.leadingAnchor.constraint(equalTo: box.leadingAnchor), listHost.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        listBox = box
        frame.body.spacing = 20
        frame.add(tabs); frame.add(intro); frame.add(rulesBox); frame.add(box)
        applyTab()
        window.contentView = frame.root
        frame.root.wantsLayer = true; frame.root.layer?.cornerRadius = 12; frame.root.layer?.masksToBounds = true
        frame.root.layer?.borderWidth = 1; frame.root.layer?.borderColor = Theme.dynamic(.border).cgColor
        window.setAccessibilityLabel("Clean up Claude sessions")
    }

    // MARK: Rules and list

    @objc func rulesChanged() {
        rules = CleanupLogic.Rules(olderDays: olderSwitch.isOn ? CleanupLogic.olderChoices[max(0, olderSelect.selected)] : nil,
                                   largerMB: largerSwitch.isOn ? CleanupLogic.largerChoices[max(0, largerSelect.selected)] : nil)
        unticked = []
        recompute()
    }

    private func recompute() {
        candidates = tab == 0 ? CleanupLogic.candidates(entries, rules, live: live, now: now()) : archived
        rebuildRows()
        updateStatus()
    }

    var picked: [HistoryEntry] { candidates.filter { !unticked.contains($0.path) } }

    private func updateStatus() {
        let held = CleanupLogic.heldBack(entries, rules, live: live, now: now())
        if running { status.stringValue = "Moving to the Trash…" }
        else if !lastResult.isEmpty { status.stringValue = lastResult }
        else if tab == 1 && candidates.isEmpty { status.stringValue = "Nothing archived yet" }
        else if tab == 0 && rules.olderDays == nil && rules.largerMB == nil { status.stringValue = "Turn on a rule to pick sessions." }
        else if candidates.isEmpty { status.stringValue = held.isEmpty ? "No session matches these rules." : "\(held.count) match but \(held.count == 1 ? "is" : "are") open or used in the last 10 minutes, so \(held.count == 1 ? "it is" : "they are") left alone." }
        else { status.stringValue = "\(picked.count) selected · \(SessionsLogic.byteSize(picked.reduce(0) { $0 + $1.sizeBytes }))" }
        for b in [trashButton, actionButton] { b.isEnabled = !picked.isEmpty && !running; b.alphaValue = b.isEnabled ? 1 : 0.45 }
        actionButton.title = actionRunning ?? (tab == 0 ? "Archive" : "Restore")
    }

    /// Test hook: sets a rule the way the user would.
    func setRule(_ name: String, _ value: String) -> Bool {
        switch name {
        case "older": if value == "off" { olderSwitch.isOn = false } else if let i = olderSelect.titles.firstIndex(of: "\(value) days") { olderSwitch.isOn = true; olderSelect.selected = i } else { return false }
        case "larger": if value == "off" { largerSwitch.isOn = false } else if let i = largerSelect.titles.firstIndex(of: "\(value) MB") { largerSwitch.isOn = true; largerSelect.selected = i } else { return false }
        default: return false
        }
        rulesChanged()
        return true
    }

    func toggle(id: String) -> Bool {
        guard let e = candidates.first(where: { $0.sessionId.hasPrefix(id) }) else { return false }
        if unticked.contains(e.path) { unticked.remove(e.path) } else { unticked.insert(e.path) }
        rebuildRows(); updateStatus()
        return true
    }

    // MARK: Trash

    @objc func trashTapped() { trash(confirm: true) }

    func trash(confirm: Bool) {
        let chosen = picked
        guard !chosen.isEmpty, !running else { return }
        guard confirm else { perform(chosen); return }
        let alert = NSAlert()
        alert.messageText = "Move \(chosen.count) session\(chosen.count == 1 ? "" : "s") to the Trash?"
        alert.informativeText = "\(SessionsLogic.byteSize(chosen.reduce(0) { $0 + $1.sizeBytes })) of conversation history. You can put them back from the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { perform(chosen) }
    }

    private func perform(_ chosen: [HistoryEntry]) {
        running = true; lastResult = ""
        updateStatus()
        let root = tab == 0 ? projectsRoot : archiveRoot, live = live
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var done = 0
            var skipped: [(String, String)] = []
            for e in chosen {
                switch Self.moveToTrash(e, root: root, live: live) {
                case .success: done += 1
                case let .failure(why): skipped.append((e.sessionId, why.text))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
                self.lastResult = CleanupLogic.resultLine(done: done, skipped: skipped)
                self.unticked = []
                self.onChanged()
                self.loadArchived()
                self.updateStatus()
            }
        }
    }

    /// The Sessions list was read again (after files moved): the clean-up list follows.
    func setEntries(_ e: [HistoryEntry]) { entries = e; recompute() }

    // MARK: Archive / Restore (muyad: files only move, between ~/.claude/projects and Muya's session-archive)

    private var actionRunning: String?

    func selectTabForTest(_ i: Int) { selectTab(i) }
    private func selectTab(_ i: Int) {
        tab = i; unticked = []; lastResult = ""
        applyTab(); recompute()
    }

    private func applyTab() {
        intro.stringValue = tab == 0
            ? "Archive moves sessions out of Claude's folder into Muya's archive — you can restore them here. Running sessions and ones used in the last 10 minutes are never touched."
            : "Archived sessions are kept until you move them to the Trash. Restore puts them back where Claude finds them."
        rulesBox?.isHidden = tab != 0
        tabs.selected = tab
    }

    func loadArchived() {
        rpc("sessions.archived", [:]) { [weak self] r in
            guard let self else { return }
            if case let .success(v) = r { self.archived = jsonObjects(v).compactMap(HistoryEntry.init(json:)) } else { self.archived = [] }
            self.tabs.options = ["Clean up", "Archived (\(self.archived.count))"]
            if self.tab == 1 { self.recompute() }
        }
    }

    @objc func archiveTapped() { archiveOrRestore() }

    /// Archive (Clean up tab) or Restore (Archived tab) the ticked sessions.
    func archiveOrRestore() {
        let chosen = picked
        guard !chosen.isEmpty, !running else { return }
        let restoring = tab == 1
        running = true; lastResult = ""; actionRunning = restoring ? "Restoring…" : "Archiving…"
        updateStatus(); status.stringValue = actionRunning!
        let params: [String: Any] = restoring ? ["paths": chosen.map(\.path)] : ["paths": chosen.map(\.path), "liveIds": Array(live)]
        rpc(restoring ? "sessions.restore" : "sessions.archive", params) { [weak self] r in
            guard let self else { return }
            self.running = false; self.actionRunning = nil
            switch r {
            case let .success(v):
                if let o = CleanupLogic.parseOutcome(v) { self.lastResult = CleanupLogic.resultLine(verb: restoring ? "Restored" : "Archived", done: o.done, skipped: o.skipped) }
                else { self.lastResult = "Unexpected answer from the daemon." }
            case let .failure(e): self.lastResult = describe(e)
            }
            self.unticked = []
            self.onChanged()
            self.loadArchived()
            self.updateStatus()
        }
    }

    struct Skip: Error { let text: String }

    /// Moves an item to the Trash and returns where it went. The verify scripts (MUYA_DEBUG_SOCKET set) can point
    /// MUYA_TRASH_DIR at a folder of their throwaway HOME: FileManager's Trash is the real user's, whatever HOME says.
    static func trash(_ url: URL) throws -> URL? {
        let env = ProcessInfo.processInfo.environment
        if env["MUYA_DEBUG_SOCKET"] != nil, let dir = env["MUYA_TRASH_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let dest = URL(fileURLWithPath: dir).appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
    }

    /// One transcript and its `<id>/` folder go to the Trash together, or neither does.
    static func moveToTrash(_ e: HistoryEntry, root: String, live: Set<String>) -> Result<Void, Skip> {
        let fm = FileManager.default
        guard let canon = CleanupLogic.checkedTranscript(e.path, root: root) else { return .failure(Skip(text: "outside Claude's folder")) }
        let id = ((canon as NSString).lastPathComponent as NSString).deletingPathExtension
        if live.contains(id) { return .failure(Skip(text: "session is running")) }
        if let m = (try? fm.attributesOfItem(atPath: canon))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < 600 { return .failure(Skip(text: "used in the last 10 minutes")) }
        let folder = (canon as NSString).deletingPathExtension
        var folderInTrash: URL?
        if fm.fileExists(atPath: folder) {
            do { folderInTrash = try trash(URL(fileURLWithPath: folder)) } catch { return .failure(Skip(text: "could not move its folder")) }
        }
        do { _ = try trash(URL(fileURLWithPath: canon)) } catch {
            if let back = folderInTrash { try? fm.moveItem(at: back, to: URL(fileURLWithPath: folder)) }
            return .failure(Skip(text: "could not move the transcript"))
        }
        return .success(())
    }

    @objc func closeTapped() {
        scrim?.remove(); scrim = nil
        window.orderOut(nil)
        onClosed?()
    }
    var onClosed: (() -> Void)?

    // MARK: Rows

    /// One row per candidate: tick box, name + "folder · age", size on the right (SessionCleanupDialog.tsx).
    private func rebuildRows() {
        for v in listHost.arrangedSubviews { listHost.removeArrangedSubview(v); v.removeFromSuperview() }
        if candidates.isEmpty {
            let l = ThemedText.helper(emptyText)
            l.maximumNumberOfLines = 0; l.preferredMaxLayoutWidth = 530
            let pad = NSView(); pad.translatesAutoresizingMaskIntoConstraints = false
            l.translatesAutoresizingMaskIntoConstraints = false; pad.addSubview(l)
            NSLayoutConstraint.activate([l.topAnchor.constraint(equalTo: pad.topAnchor, constant: 14), l.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -14),
                                         l.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 14), l.trailingAnchor.constraint(equalTo: pad.trailingAnchor, constant: -14)])
            listHost.addArrangedSubview(pad); pad.widthAnchor.constraint(equalTo: listHost.widthAnchor).isActive = true
            return
        }
        for (i, e) in candidates.enumerated() {
            let box = ThemedCheckbox(on: !unticked.contains(e.path))
            box.setAccessibilityLabel("Select \(e.displayName)")
            let idx = i
            box.onChange = { [weak self] on in
                guard let self, idx < self.candidates.count else { return }
                let p = self.candidates[idx].path
                if on { self.unticked.remove(p) } else { self.unticked.insert(p) }
                self.updateStatus()
            }
            let title = ThemedText.title(e.displayName)
            title.lineBreakMode = .byTruncatingTail
            let ageDays = Int((now().timeIntervalSince1970 * 1000 - Double(e.lastModified)) / 86_400_000)
            let sub = ThemedText.helper("\(e.cwd.abbreviatingHome(home)) · \(ageDays == 0 ? "today" : ageDays == 1 ? "1 day ago" : "\(ageDays) days ago")")
            sub.lineBreakMode = .byTruncatingTail; sub.maximumNumberOfLines = 1
            let size = ThemedText.helper(SessionsLogic.byteSize(e.sizeBytes))
            size.font = ThemeFont.sans(12); size.textColor = Theme.dynamic(.textMuted)
            let texts = Kit.vstack([title, sub], spacing: 1); texts.alignment = .leading
            texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
            texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let r = Kit.hstack([box, texts, size], spacing: 12); r.distribution = .fill
            title.setContentHuggingPriority(.init(1), for: .horizontal); sub.setContentHuggingPriority(.init(1), for: .horizontal)
            r.translatesAutoresizingMaskIntoConstraints = false
            let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(r)
            var cs = [r.topAnchor.constraint(equalTo: row.topAnchor, constant: 14), r.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
                      r.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14), r.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14)]
            if i > 0 {
                let rule = ModalRule(); row.addSubview(rule)
                cs += [rule.topAnchor.constraint(equalTo: row.topAnchor), rule.leadingAnchor.constraint(equalTo: row.leadingAnchor), rule.trailingAnchor.constraint(equalTo: row.trailingAnchor)]
            }
            NSLayoutConstraint.activate(cs)
            row.setAccessibilityElement(true); row.setAccessibilityRole(.group)
            row.setAccessibilityLabel("\(e.displayName), \(sub.stringValue)")
            listHost.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: listHost.widthAnchor).isActive = true
        }
    }

    private var emptyText: String {
        if tab == 1 { return "Nothing archived yet." }
        let held = CleanupLogic.heldBack(entries, rules, live: live, now: now())
        if rules.olderDays == nil && rules.largerMB == nil { return "Turn on a rule above to pick sessions." }
        if !held.isEmpty { return "\(held.count) match but \(held.count == 1 ? "is" : "are") open or used in the last 10 minutes, so \(held.count == 1 ? "it is" : "they are") left alone." }
        return "No session matches these rules. Running sessions and ones used in the last 10 minutes are left out — loosen the rules to see more."
    }

    func debugState() -> String {
        var lines = ["tab=\(tab == 0 ? "cleanup" : "archived") archived=\(archived.count)", "rules=older:\(rules.olderDays.map(String.init) ?? "off") larger:\(rules.largerMB.map(String.init) ?? "off")", "status=\(status.stringValue)", "trashEnabled=\(trashButton.isEnabled)"]
        for e in candidates { lines.append("\(unticked.contains(e.path) ? "[ ]" : "[x]")\t\(e.sessionId)\t\(e.displayName)\t\(e.sizeBytes)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Auto-allow suggestion toast (P12)

/// The card in the top-right corner: "Turn on Auto-allow?" (src/redesign/AutoAllowSuggest.tsx). It sits away from the
/// permission bar's Allow button so a click meant for Allow cannot land on "Turn on"; neither button is orange.
final class AutoAllowToast: NSView {
    private let card = ThemedBox(.popover)
    private let bodyLabel = ThemedText.helper("")
    private let close = ToastCloseButton()
    private let notNow = ThemedButton("Not now")
    private let turnOn = ThemedButton("Turn on Auto-allow")
    var onEnable: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = ThemedText.title(AutoAllowSuggestLogic.title)
        bodyLabel.textColor = Theme.dynamic(.textTertiary)
        bodyLabel.preferredMaxLayoutWidth = 276
        bodyLabel.maximumNumberOfLines = 1; bodyLabel.lineBreakMode = .byClipping   // the reference shows the sentence on one line, cut at the card's edge
        close.onClick = { [weak self] in self?.onDismiss?() }
        notNow.onClick = { [weak self] in self?.onDismiss?() }
        turnOn.onClick = { [weak self] in self?.onEnable?() }
        turnOn.setAccessibilityLabel("Turn on Auto-allow")
        let head = Kit.hstack([Kit.vstack([title, bodyLabel], spacing: 4), close], spacing: 8, alignment: .top)
        let buttons = Kit.hstack([NSView(), notNow, turnOn], spacing: 8)
        let col = Kit.vstack([head, buttons], spacing: 10)
        col.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(col); addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            col.topAnchor.constraint(equalTo: card.topAnchor, constant: 12), col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            widthAnchor.constraint(equalToConstant: 370),   // width 340 + 2 × 14 padding (content-box)
            head.widthAnchor.constraint(equalTo: col.widthAnchor), buttons.widthAnchor.constraint(equalTo: col.widthAnchor),
        ])
        wantsLayer = true
        layer?.shadowOpacity = 0.35; layer?.shadowRadius = 16; layer?.shadowOffset = CGSize(width: 0, height: -6)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(AutoAllowSuggestLogic.title)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(agentName: String) { bodyLabel.stringValue = AutoAllowSuggestLogic.body(agentName: agentName) }
    var bodyText: String { bodyLabel.stringValue }
    func tapEnable() { turnOn.onClick?() }
    func tapDismiss() { notNow.onClick?() }
}

/// The X in the toast's corner (24 x 24, no border).
final class ToastCloseButton: NSControl {
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        setAccessibilityRole(.button); setAccessibilityLabel("Close")
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath()
        let c = NSPoint(x: bounds.midX, y: bounds.midY), d: CGFloat = 4.5
        p.move(to: NSPoint(x: c.x - d, y: c.y - d)); p.line(to: NSPoint(x: c.x + d, y: c.y + d))
        p.move(to: NSPoint(x: c.x + d, y: c.y - d)); p.line(to: NSPoint(x: c.x - d, y: c.y + d))
        p.lineWidth = 1.6; p.lineCapStyle = .round
        Theme.dynamic(.textTertiary).setStroke(); p.stroke()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Decides when the toast shows (from the sessions' screen state) and wires its buttons. The Tauri app watches its
/// permission-prompt list; here the same prompts arrive as `Control::Screen` (muyad's prompt parser, AC12), which is
/// also what Model.evaluateAutoAllow answers. While an app is attached the daemon stays silent, so this is the only
/// place the suggestion comes from.
@MainActor
final class AutoAllowSuggestController {
    private unowned let store: Store
    private weak var host: NSView?
    private(set) var logic = AutoAllowSuggestLogic()
    private(set) var toast: AutoAllowToast?
    private var timer: Timer?
    private var keyMonitor: Any?
    /// True while a dialog / menu / the palette is on top: Esc is for it, not for the toast.
    var escapeBlocked: () -> Bool = { false }
    /// How many times "Turn on Auto-allow" was pressed (test hook).
    private(set) var enabledCount = 0

    init(store: Store, host: NSView?) { self.store = store; self.host = host }

    var isShown: Bool { toast != nil }

    /// Call after any session's screen state changed.
    func sessionsChanged() {
        let prompts = store.sessions.filter { $0.exited == nil }.compactMap { s -> AutoAllowSuggestLogic.Prompt? in
            guard let sc = s.screen, sc.permission, sc.approveKey != nil else { return nil }
            return .init(session: s.id, key: sc.promptKey, mode: sc.mode)
        }
        guard let id = logic.observe(prompts, autoApprove: store.prefs.bool("autoApprove")) else { return }
        present(sessionId: id)
    }

    /// Show (or re-aim) the toast for a session; also the entry point of the debug hook.
    func present(sessionId: UInt64) {
        guard let host else { return }
        let name = store.sessions.first { $0.id == sessionId }?.name ?? "A session"
        if toast == nil {
            let t = AutoAllowToast(frame: .zero)
            t.onEnable = { [weak self] in self?.enable() }
            t.onDismiss = { [weak self] in self?.dismiss() }
            t.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(t, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([t.topAnchor.constraint(equalTo: host.topAnchor, constant: 57), t.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16)])
            toast = t
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, e.keyCode == 53, e.window === self.host?.window, !self.escapeBlocked() else { return e }
                self.dismiss(); return nil
            }
        }
        toast?.show(agentName: name)
        timer?.invalidate()
        if store.mockMode { return }   // the dev mock keeps the toast up while a capture run walks through the views (the web mock's screens have it)
        timer = Timer.scheduledTimer(withTimeInterval: AutoAllowSuggestLogic.lifetime, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
    }

    func enable() {
        enabledCount += 1
        store.prefs.set("autoApprove", true)
        store.evaluateAutoAllow()
        dismiss()
    }

    func dismiss() {
        timer?.invalidate(); timer = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        toast?.removeFromSuperview(); toast = nil
        logic.dismiss()
    }
}
