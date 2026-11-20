// "Scheduled Prompt": the legacy one-shot timed prompt. Type a prompt, tick the terminals, pick a time; at that
// time the text is typed into those terminals and submitted. Like today's app it is held in memory only (a
// quit forgets it). The app, not the daemon, owns this feature, so it is a sheet of its own next to the
// daemon-run Schedules.

import AppKit

/// Owns the one-shot prompts and the single timer that fires the next one (no polling).
final class PromptRunner {
    unowned let store: Store
    private(set) var model = ScheduledPrompts()
    private var timer: Timer?
    var now: () -> Date = { Date() }
    var onChange: (() -> Void)?
    /// How many prompts were submitted so far (test hook).
    private(set) var firedCount = 0

    init(store: Store) { self.store = store }

    @discardableResult
    func add(prompt: String, terminals: [UInt64], at: Date, replacing id: Int? = nil) throws -> Int {
        let r = try model.add(prompt: prompt, terminals: terminals, at: at, now: now(), replacing: id)
        reschedule(); onChange?()
        return r
    }

    func remove(_ id: Int) { model.remove(id); reschedule(); onChange?() }

    /// Arms the timer for the nearest pending prompt (also after the Mac woke up: timers pause during sleep).
    func reschedule() {
        timer?.invalidate(); timer = nil
        guard let next = model.pending.first else { return }
        let wait = max(0.05, next.at.timeIntervalSince(now()))
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in self?.fire() }
        timer?.tolerance = min(1, wait * 0.05)
    }

    func fire() {
        for p in model.due(now: now()) {
            for id in p.terminalIds { store.submitText(p.prompt, to: id); firedCount += 1 }
        }
        onChange?()
        reschedule()
    }
}

final class ScheduledPromptSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let store: Store
    private let runner: PromptRunner
    private weak var parent: NSWindow?
    let window: NSWindow
    private let promptView = DialogTextView()
    private let timePicker = NSDatePicker()
    private let datePicker = NSDatePicker()
    private let errorLabel = Kit.label("", size: 12, color: Token.statePermission, lines: 2)
    private let submitButton = Kit.button("Schedule", nil, #selector(submitTapped), label: "Schedule the prompt")
    private let cancelEditButton = Kit.button("Cancel edit", nil, #selector(cancelEditTapped), label: "Cancel editing")
    private let editButton = Kit.button("Edit", nil, #selector(editTapped), label: "Edit the selected prompt")
    private let deleteButton = Kit.button("Delete", nil, #selector(deleteTapped), label: "Delete the selected prompt")
    private let terminalsStack = NSStackView()
    private let table = KeyTable()
    private let recent = Kit.label("", size: 11, color: Token.textSecondary, lines: 3)
    private var terminalBoxes: [(id: UInt64, box: NSButton)] = []
    private(set) var editingId: Int?
    private var rows: [ScheduledPrompt] = []
    var onClosed: (() -> Void)?

    init(window parent: NSWindow, store: Store, runner: PromptRunner) {
        self.store = store; self.runner = runner; self.parent = parent
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
        resetForm()
        reloadList()
        runner.onChange = { [weak self] in self?.reloadList() }
        parent.beginSheet(window)
    }

    private func build() {
        let title = Kit.label("Scheduled prompt", size: 15, bold: true)
        let intro = Kit.helper("Sends a prompt to the ticked terminals at the chosen time, once. Kept in memory only: quitting Muya forgets it.")
        intro.maximumNumberOfLines = 2

        promptView.isRichText = false; promptView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        promptView.textColor = Token.text; promptView.backgroundColor = .clear
        promptView.textContainerInset = NSSize(width: 6, height: 6)
        promptView.isVerticallyResizable = true; promptView.autoresizingMask = [.width]
        promptView.setAccessibilityLabel("Prompt to send")
        let promptScroll = Kit.scroll(promptView, label: "Prompt to send")
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true

        terminalsStack.orientation = .vertical; terminalsStack.alignment = .leading; terminalsStack.spacing = 4
        for s in store.sessions where s.exited == nil {
            let b = Kit.checkbox(s.name, on: s.id == store.selected?.id, nil, nil)
            terminalBoxes.append((s.id, b))
            terminalsStack.addArrangedSubview(b)
        }
        if terminalBoxes.isEmpty { terminalsStack.addArrangedSubview(Kit.label("No open terminal.", size: 12, color: Token.textSecondary)) }

        timePicker.datePickerStyle = .textFieldAndStepper; timePicker.datePickerElements = .hourMinuteSecond
        datePicker.datePickerStyle = .textFieldAndStepper; datePicker.datePickerElements = .yearMonthDay
        timePicker.setAccessibilityLabel("Time"); datePicker.setAccessibilityLabel("Date")
        for p in [timePicker, datePicker] { p.target = self; p.action = #selector(timeChanged) }

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("p")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col); table.headerView = nil; table.rowHeight = 38
        table.dataSource = self; table.delegate = self; table.style = .inset
        table.setAccessibilityLabel("Scheduled prompts")
        let tableScroll = Kit.scroll(table, label: "Scheduled prompts")
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        for b in [submitButton, cancelEditButton, editButton, deleteButton] { b.target = self }
        submitButton.keyEquivalent = "\r"
        let close = Kit.button("Close", self, #selector(closeTapped))
        close.keyEquivalent = "\u{1b}"

        let form = Kit.vstack([
            Kit.label("Prompt", size: 11, bold: true, color: Token.textSecondary), promptScroll,
            Kit.label("Terminals", size: 11, bold: true, color: Token.textSecondary), terminalsStack,
            Kit.label("Time", size: 11, bold: true, color: Token.textSecondary), Kit.hstack([timePicker, datePicker], spacing: 10),
            errorLabel,
            Kit.hstack([submitButton, cancelEditButton], spacing: 8),
            Kit.divider(),
            Kit.label("Waiting", size: 11, bold: true, color: Token.textSecondary), tableScroll,
            Kit.hstack([editButton, deleteButton], spacing: 8), recent,
        ], spacing: 8)
        let root = NSView()
        for v in [title, intro, form, close] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        for v in form.arrangedSubviews { v.translatesAutoresizingMaskIntoConstraints = false; if v is NSScrollView || v is NSBox || v === errorLabel || v === promptScroll { v.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true } }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            intro.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6), intro.leadingAnchor.constraint(equalTo: title.leadingAnchor), intro.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            form.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12),
            form.leadingAnchor.constraint(equalTo: title.leadingAnchor), form.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            close.trailingAnchor.constraint(equalTo: intro.trailingAnchor), close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            close.topAnchor.constraint(greaterThanOrEqualTo: form.bottomAnchor, constant: 10),
        ])
        window.contentView = root
        window.setAccessibilityLabel("Scheduled prompt")
        let fit = form.fittingSize
        window.setContentSize(NSSize(width: 520, height: fit.height + 130))
    }

    // MARK: Form

    var chosenTime: Date {
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute, .second], from: timePicker.dateValue)
        var d = cal.dateComponents([.year, .month, .day], from: datePicker.dateValue)
        d.hour = t.hour; d.minute = t.minute; d.second = t.second
        return cal.date(from: d) ?? datePicker.dateValue
    }

    func resetForm() {
        editingId = nil
        promptView.string = ""
        let at = runner.now().addingTimeInterval(300)
        timePicker.dateValue = at; datePicker.dateValue = at
        submitButton.title = "Schedule"; cancelEditButton.isHidden = true
        errorLabel.stringValue = ""
    }

    @objc private func timeChanged() { errorLabel.stringValue = "" }

    @objc func submitTapped() { _ = submit() }

    /// Returns the error shown, nil when the prompt was scheduled.
    @discardableResult
    func submit() -> String? {
        let ids = terminalBoxes.filter { $0.box.state == .on }.map(\.id)
        do {
            try runner.add(prompt: promptView.string, terminals: ids, at: chosenTime, replacing: editingId)
            resetForm()
            return nil
        } catch let f as ScheduledPrompts.Failure {
            errorLabel.stringValue = ScheduledPrompts.message(for: f)
            return errorLabel.stringValue
        } catch { return "\(error)" }
    }

    @objc private func cancelEditTapped() { resetForm() }

    @objc func editTapped() {
        guard table.selectedRow >= 0, table.selectedRow < rows.count, !rows[table.selectedRow].fired else { return }
        let p = rows[table.selectedRow]
        editingId = p.id
        promptView.string = p.prompt
        for (id, box) in terminalBoxes { box.state = p.terminalIds.contains(id) ? .on : .off }
        timePicker.dateValue = p.at; datePicker.dateValue = p.at
        submitButton.title = "Save changes"; cancelEditButton.isHidden = false
        errorLabel.stringValue = ""
    }

    @objc func deleteTapped() {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        let p = rows[table.selectedRow]
        if editingId == p.id { resetForm() }
        runner.remove(p.id)
    }

    @objc func closeTapped() {
        runner.onChange = nil
        parent?.endSheet(window); window.orderOut(nil)
        onClosed?()
    }

    // MARK: List

    private func reloadList() {
        rows = runner.model.pending
        table.reloadData()
        let fmt = DateFormatter(); fmt.dateStyle = .none; fmt.timeStyle = .medium
        recent.stringValue = runner.model.recent.isEmpty ? "" : "Sent: " + runner.model.recent.map { "\(fmt.string(from: $0.at)) “\($0.prompt.prefix(30))”" }.joined(separator: " · ")
        editButton.isEnabled = !rows.isEmpty; deleteButton.isEnabled = !rows.isEmpty
        if !rows.isEmpty, table.selectedRow < 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = rows[row]
        let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .medium
        let names = p.terminalIds.compactMap { id in store.sessions.first { $0.id == id }?.name }.joined(separator: ", ")
        let title = Kit.label(String(p.prompt.replacingOccurrences(of: "\n", with: " ").prefix(60)), bold: true)
        let sub = Kit.label("\(fmt.string(from: p.at)) · \(names.isEmpty ? "terminal closed" : names)", size: 11, color: Token.textSecondary)
        let cell = NSTableCellView()
        Kit.pin(Kit.vstack([title, sub], spacing: 1), in: cell, insets: NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6))
        cell.setAccessibilityLabel("\(title.stringValue), \(sub.stringValue)")
        return cell
    }

    // MARK: Test hooks

    func debugSet(_ field: String, _ value: String) -> Bool {
        switch field {
        case "prompt": promptView.string = value
        case "terminals": // comma-separated session names
            let want = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            for (id, box) in terminalBoxes { box.state = want.contains(store.sessions.first { $0.id == id }?.name ?? "") ? .on : .off }
        case "in": // seconds from now (may be negative)
            guard let s = Double(value) else { return false }
            let at = runner.now().addingTimeInterval(s)
            timePicker.dateValue = at; datePicker.dateValue = at
        default: return false
        }
        return true
    }

    func debugState() -> String {
        var lines = ["editing=\(editingId.map(String.init) ?? "none")", "error=\(errorLabel.stringValue)", "submit=\(submitButton.title)", "terminals=\(terminalBoxes.map { tb in "\(store.sessions.first { $0.id == tb.id }?.name ?? "?")=\(tb.box.state == .on ? "on" : "off")" }.joined(separator: ","))"]
        for p in runner.model.items { lines.append("item\t\(p.id)\t\(p.fired ? "fired" : "pending")\t\(p.prompt)\t\(p.terminalIds.map(String.init).joined(separator: ","))") }
        return lines.joined(separator: "\n")
    }

    func select(row: Int) { if row >= 0, row < rows.count { table.selectRowIndexes([row], byExtendingSelection: false) } }
}
