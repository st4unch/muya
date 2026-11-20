// P5 — the small dialogs of today's Muya (src/redesign/BroadcastModal.tsx, InlineRename, Menus.tsx ConfirmDialog): Broadcast to
// all panels, Rename, Confirm. One panel type over the dimmed window (ModalScrim), the ModalFrame look of the other dialogs:
// title, body, footer with Cancel + the action; Escape cancels, ⌘Return / Return in a one-line field confirms.

import AppKit

final class DialogPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onDefault: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 { onDefault?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class Dialogs {
    static let shared = Dialogs()
    private(set) var current: DialogPanel?
    private var scrim: ModalScrim?
    private var field: NSTextView?
    private var primary: ThemedButton?
    private var textField: NSTextField?

    var isOpen: Bool { current != nil }

    private func present(title: String, width: CGFloat, height: CGFloat, over host: NSWindow, body: (ModalFrame) -> Void, cancel: ThemedButton, action: ThemedButton, hint: String = "") {
        let keepTF = textField, keepTV = field   // set by the caller just before; dismiss() clears the previous dialog's state
        dismiss()
        textField = keepTF; field = keepTV
        let hintLabel = Kit.label(hint, size: 11, color: Token.textTertiary)
        let frame = ModalFrame.make(title: title, footerLeft: hintLabel, footerRight: [cancel, action], width: width, height: height, onClose: { [weak self] in self?.dismiss() })
        body(frame)
        let panel = DialogPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        frame.root.wantsLayer = true; frame.root.layer?.cornerRadius = 12; frame.root.layer?.masksToBounds = true
        frame.root.layer?.borderWidth = 1; frame.root.layer?.borderColor = Theme.dynamic(.border).cgColor
        panel.contentView = frame.root
        panel.onCancel = { [weak self] in self?.dismiss() }
        let s = ModalScrim(over: host) { [weak self] in self?.dismiss() }
        s.attach(panel)
        let f = host.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.midY - height / 2 + 40))
        panel.makeKeyAndOrderFront(nil)
        current = panel; scrim = s; primary = action
        panel.onDefault = { [weak action] in action?.onClick?() }
        if let tf = textField { panel.makeFirstResponder(tf) } else if let tv = field { panel.makeFirstResponder(tv) }
    }

    func dismiss() {
        scrim?.remove(); current?.orderOut(nil)
        current = nil; scrim = nil; field = nil; textField = nil; primary = nil; commandRun = nil
    }

    // MARK: Broadcast to all panels

    func broadcast(over host: NSWindow, panels: Int, send: @escaping (String) -> Void) {
        let tv = NSTextView(frame: .zero)
        tv.isRichText = false; tv.drawsBackground = false; tv.font = ThemeFont.sans(13); tv.textColor = Theme.dynamic(.text)
        tv.insertionPointColor = Theme.dynamic(.text); tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.setAccessibilityLabel("Message to send to every panel")
        let box = InputFrame(); box.translatesAutoresizingMaskIntoConstraints = false
        tv.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(tv)
        NSLayoutConstraint.activate([tv.topAnchor.constraint(equalTo: box.topAnchor), tv.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                                     tv.leadingAnchor.constraint(equalTo: box.leadingAnchor), tv.trailingAnchor.constraint(equalTo: box.trailingAnchor), box.heightAnchor.constraint(equalToConstant: 120)])
        field = tv
        let cancel = ThemedButton("Cancel"), go = ThemedButton(DialogsLogic.broadcastTitle(panels: panels), style: .primary)
        cancel.onClick = { [weak self] in self?.dismiss() }
        go.onClick = { [weak self, weak tv] in
            guard let t = DialogsLogic.trimmed(tv?.string ?? "") else { return }
            self?.dismiss(); send(t)
        }
        present(title: "Broadcast to all panels", width: 480, height: 330, over: host, body: { f in
            f.add(f.group("Message", box, helper: ThemedText.helper("Sent to every panel of the grid, then Return is pressed in each.")))
        }, cancel: cancel, action: go, hint: "⌘↩ to send")
    }

    // MARK: Rename

    func rename(over host: NSWindow, title: String = "Rename agent", current name: String, done: @escaping (String) -> Void) {
        let tf = NSTextField(string: name)
        tf.font = ThemeFont.sans(13); tf.textColor = Theme.dynamic(.text); tf.isBordered = false; tf.drawsBackground = false; tf.focusRingType = .none
        tf.setAccessibilityLabel("Name"); tf.translatesAutoresizingMaskIntoConstraints = false
        let box = InputFrame(); box.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(tf)
        NSLayoutConstraint.activate([tf.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), tf.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
                                     tf.centerYAnchor.constraint(equalTo: box.centerYAnchor), box.heightAnchor.constraint(equalToConstant: 32)])
        textField = tf
        let cancel = ThemedButton("Cancel"), go = ThemedButton("Rename", style: .primary)
        cancel.onClick = { [weak self] in self?.dismiss() }
        go.onClick = { [weak self, weak tf] in
            guard let t = DialogsLogic.trimmed(tf?.stringValue ?? "") else { return }
            self?.dismiss(); done(t)
        }
        tf.target = go; tf.action = #selector(NSControl.performClick(_:))
        present(title: title, width: 420, height: 210, over: host, body: { f in f.add(f.group("Name", box)) }, cancel: cancel, action: go, hint: "↩ to rename")
        tf.selectText(nil)
    }

    // MARK: Confirm

    func confirm(over host: NSWindow, title: String, message: String, confirmTitle: String, danger: Bool = false, onConfirm: @escaping () -> Void) {
        let cancel = ThemedButton("Cancel"), go = ThemedButton(confirmTitle, style: danger ? .danger : .primary)
        cancel.onClick = { [weak self] in self?.dismiss() }
        go.onClick = { [weak self] in self?.dismiss(); onConfirm() }
        // The height follows the message (about 50 characters a line at 13 pt in 370 pt): a long message must not be cut off.
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, Int((Double($1.count) / 50).rounded(.up))) }
        present(title: title, width: 420, height: CGFloat(min(460, max(190, 120 + lines * 19))), over: host, body: { f in
            let m = Kit.label(message, size: 13, color: Token.textSecondary, lines: 0); m.preferredMaxLayoutWidth = 370
            f.add(m)
        }, cancel: cancel, action: go)
    }

    // MARK: Command (session header "Command", ⌘⇧K; docs/prd-command-broadcast.md)

    private var commandRun: UUID?
    private weak var commandSegment: IconSegmented?
    private final class CommandDraft { var target = CommandTarget.this; var picked = Set<UInt64>() }

    /// Text or a slash command to this session, its split group, a ticked list, or every session. `send` asks the daemon and calls back with
    /// one result per session; the dialog then turns into the result list.
    func command(over host: NSWindow, current: UInt64?, groupIds: [UInt64]?, candidates: [CommandCandidate], send: @escaping (String, [UInt64], @escaping @MainActor ([CommandResult]) -> Void) -> Void) {
        let draft = CommandDraft()
        var refresh: () -> Void = {}
        let receivers = candidates.filter(\.receives)
        draft.target = receivers.contains { $0.id == current } ? .this : .all
        let tv = NSTextView(frame: .zero)
        tv.isRichText = false; tv.drawsBackground = false; tv.font = ThemeFont.mono(13); tv.textColor = Theme.dynamic(.text)
        tv.insertionPointColor = Theme.dynamic(.text); tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false; tv.isAutomaticTextReplacementEnabled = false
        tv.setAccessibilityLabel("Command or message")
        let box = InputFrame(); box.translatesAutoresizingMaskIntoConstraints = false
        tv.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(tv)
        NSLayoutConstraint.activate([tv.topAnchor.constraint(equalTo: box.topAnchor), tv.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                                     tv.leadingAnchor.constraint(equalTo: box.leadingAnchor), tv.trailingAnchor.constraint(equalTo: box.trailingAnchor), box.heightAnchor.constraint(equalToConstant: 84)])
        field = tv
        let chips = CommandLogic.presets.map { p -> ThemedButton in
            let b = ThemedButton(p); b.onClick = { [weak tv] in tv?.string = p; tv?.window?.makeFirstResponder(tv); tv?.setSelectedRange(NSRange(location: (p as NSString).length, length: 0)); tv?.didChangeText() }
            return b
        }
        let chipRow = Kit.hstack(chips, spacing: 8)
        let commandBlock = Kit.vstack([box, chipRow], spacing: 10)
        box.widthAnchor.constraint(equalTo: commandBlock.widthAnchor).isActive = true

        let seg = IconSegmented(options: CommandTarget.allCases.map(\.title)); seg.translatesAutoresizingMaskIntoConstraints = false
        seg.selected = draft.target.rawValue; commandSegment = seg
        let summary = ThemedText.helper(""); summary.maximumNumberOfLines = 2; summary.preferredMaxLayoutWidth = 470
        // The pick list: one checkbox row per live agent session (hidden unless "Pick sessions" is chosen).
        var rows: [NSView] = []
        for c in receivers {
            let cb = ThemedCheckbox(on: false)
            cb.setAccessibilityLabel("Send to \(c.name)")
            let name = ThemedText.title(c.name); name.lineBreakMode = .byTruncatingTail
            let r = Kit.hstack([cb, name], spacing: 10)
            let id = c.id
            cb.onChange = { on in if on { draft.picked.insert(id) } else { draft.picked.remove(id) }; refresh() }
            rows.append(r)
        }
        let pickList: NSView = rows.isEmpty ? ThemedText.helper("No Claude session is open.") : ModalLayout.rowsBox(rows, inset: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        pickList.translatesAutoresizingMaskIntoConstraints = false
        let targetBlock = Kit.vstack([seg, summary, pickList], spacing: 10)
        seg.widthAnchor.constraint(equalTo: targetBlock.widthAnchor).isActive = true
        pickList.widthAnchor.constraint(equalTo: targetBlock.widthAnchor).isActive = true

        let cancel = ThemedButton("Cancel"), go = ThemedButton(CommandLogic.sendTitle(count: 0), style: .primary)
        func currentIds() -> [UInt64] { CommandLogic.resolve(draft.target, current: current, groupIds: groupIds, picked: draft.picked, all: candidates) }
        refresh = {
            let ids = currentIds(), names = ids.compactMap { id in candidates.first { $0.id == id }?.name }
            go.title = CommandLogic.sendTitle(count: ids.count)
            let ready = !ids.isEmpty && CommandLogic.trimmed(tv.string) != nil
            go.isEnabled = ready; go.alphaValue = ready ? 1 : 0.45
            pickList.isHidden = draft.target != .pick
            summary.stringValue = ids.isEmpty ? (draft.target == .pick ? "Tick the sessions below." : draft.target == .group && groupIds == nil ? "This session is not in a split group." : "No Claude session to send to.")
                : names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " and \(names.count - 6) more" : "")
        }
        seg.onChange = { i in draft.target = CommandTarget(rawValue: i) ?? .this; refresh() }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: tv, queue: .main) { _ in MainActor.assumeIsolated { refresh() } }
        cancel.onClick = { [weak self] in self?.dismiss() }
        go.onClick = { [weak self, weak tv] in
            guard let self, let text = CommandLogic.trimmed(tv?.string ?? "") else { return }
            let ids = currentIds()
            guard !ids.isEmpty else { return }
            let targets = candidates.filter { ids.contains($0.id) }
            let token = UUID()
            self.showCommandResults(over: host, text: text, rows: targets.map { CommandResult(id: $0.id, name: $0.name, state: .queued) }, pending: true, token: token)
            send(text, ids) { [weak self] results in
                guard let self, self.commandRun == token else { return }   // the operator closed the dialog meanwhile
                self.showCommandResults(over: host, text: text, rows: CommandResult.named(results, by: candidates), pending: false, token: token)
            }
        }
        present(title: "Command", width: 520, height: 560, over: host, body: { f in
            f.add(f.group("Command", commandBlock, helper: ThemedText.helper("Typed into each session's prompt, then Return. Slash commands work, e.g. /compact or /model sonnet.")))
            f.add(f.group("Send to", targetBlock))
        }, cancel: cancel, action: go, hint: "⌘↩ to send")
        refresh()
    }

    /// The per-session answer list (also shown, in "Sending…" form, while the daemon works).
    private func showCommandResults(over host: NSWindow, text: String, rows: [CommandResult], pending: Bool, token: UUID) {
        let close = ThemedButton("Close"), done = ThemedButton("Done", style: .primary)   // Close is only the unused cancel slot (hidden)
        close.isHidden = true; done.onClick = { [weak self] in self?.dismiss() }
        let views: [NSView] = rows.map { r in
            let name = ThemedText.title(r.name); name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let color: NSColor = pending ? Theme.dynamic(.textMuted) : Theme.dynamic(r.state == .failed ? .dangerText : r.state == .submitted || r.state == .sent ? .successText : .warningText)
            let state = Kit.label(pending ? "Sending…" : r.label, size: 13, bold: true, color: color)
            state.setContentHuggingPriority(.required, for: .horizontal); state.setContentCompressionResistancePriority(.required, for: .horizontal)
            let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let line = Kit.hstack([name, spacer, state], spacing: 12)
            var col: [NSView] = [line]
            if !pending, let why = r.reason { let h = ThemedText.helper(why); h.maximumNumberOfLines = 0; h.preferredMaxLayoutWidth = 470; col.append(h) }
            let v = Kit.vstack(col, spacing: 3)
            line.translatesAutoresizingMaskIntoConstraints = false
            line.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
            return v
        }
        let list = ModalLayout.rowsBox(views, inset: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        let height = min(620, max(300, CGFloat(270 + rows.count * 46 + rows.filter { $0.reason != nil }.count * 18)))
        present(title: pending ? "Sending…" : "Command sent", width: 520, height: height, over: host, body: { f in
            let cmd = Kit.label(text, size: 13, color: Token.textSecondary, lines: 2); cmd.font = ThemeFont.mono(13); cmd.lineBreakMode = .byTruncatingTail
            f.add(f.group("Command", cmd))
            f.add(f.group("Result", list))
        }, cancel: close, action: done, hint: pending ? "Waiting for the sessions…" : CommandResult.summary(rows))
        commandRun = token
    }

    /// Test hook: picks a target segment (0 this, 1 group, 2 pick, 3 all) like a click.
    func debugCommandTarget(_ i: Int) { guard let s = commandSegment else { return }; s.selected = i; s.onChange?(i) }

    /// Test hook: whether a Command run is in flight or showing its result list.
    var commandRunActive: Bool { commandRun != nil }

    /// Test hook: presses the primary button of the open dialog.
    func pressPrimary() { primary?.onClick?() }
    func setText(_ s: String) { if let tv = field { tv.string = s } else { textField?.stringValue = s } }
}
