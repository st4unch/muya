// A small modal form (sheet) built from Kit rows — bold 13 pt title, helper line, control on the right — for
// the server, PSMP profile and secret editors. Errors show under the field they belong to. Secure fields
// are NSSecureTextField and are cleared by `clearSecure()` right after the value has been taken.

import AppKit

struct FormField {
    enum Kind {
        case text
        case secure
        case popup([(value: String, title: String)])
        case combo([String])
        case check
    }

    var id: String
    var title: String
    var helper: String?
    var kind: Kind = .text
    var value = ""
    var placeholder = ""
}

@MainActor
final class FormSheet: NSObject, NSComboBoxDelegate {
    let window: EditorPanel
    private(set) var controls: [String: NSControl] = [:]
    private var rows: [String: NSView] = [:]
    private var errors: [String: NSTextField] = [:]
    private let summary = Kit.label("", size: 11, color: Token.danger, lines: 0)
    private weak var parent: NSWindow?
    private var order: [String] = []

    var validate: ([String: String]) -> [FieldError] = { _ in [] }
    /// Called with valid values; the form stays open until it calls `close()` (so a daemon error can be shown).
    var onSubmit: (([String: String]) -> Void)?
    var onChange: ((String, FormSheet) -> Void)?

    init(title: String, subtitle: String? = nil, fields: [FormField], primary primaryTitle: String) {
        window = EditorPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        primaryButton = ModalButton(primaryTitle, style: .primary, height: 32)
        super.init()
        window.title = title
        window.setAccessibilityLabel(title)
        window.onSubmit = { [weak self] in self?.submitTapped() }
        window.onCancel = { [weak self] in self?.cancelTapped() }
        primaryButton.onClick = { [weak self] in self?.submitTapped() }
        let cancel = ModalButton("Cancel", height: 32, label: "Cancel \(title)"); cancel.onClick = { [weak self] in self?.cancelTapped() }
        var views: [NSView] = []
        if let subtitle { views.append(ThemedText.helper(subtitle)) }
        for f in fields {
            order.append(f.id)
            let control = makeControl(f)
            controls[f.id] = control
            control.setSpokenLabel(f.title)
            let err = NSTextField(wrappingLabelWithString: "")
            err.font = ThemeFont.sans(12); err.textColor = Theme.dynamic(.dangerText)
            err.isHidden = true
            err.setAccessibilityLabel("\(f.title) error")
            errors[f.id] = err
            var parts: [NSView] = []
            if case .check = f.kind {
                let t = ThemedText.title(f.title)
                parts.append(Kit.hstack([control, t], spacing: 8))
            } else {
                parts.append(ThemedText.label(f.title))
                switch f.kind {
                case .popup, .combo, .text, .secure: parts.append(FieldBox(control))
                default: parts.append(control)
                }
            }
            if let h = f.helper, !h.isEmpty { let hl = ThemedText.helper(h); hl.maximumNumberOfLines = 0; parts.append(hl) }
            parts.append(err)
            let row = Kit.vstack(parts, spacing: 6)
            for v in parts { v.translatesAutoresizingMaskIntoConstraints = false; if !(v is NSStackView) { v.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true } }
            rows[f.id] = row
            views.append(row)
        }
        summary.isHidden = true
        summary.font = ThemeFont.sans(12); summary.textColor = Theme.dynamic(.dangerText)
        views.append(summary)
        let hint = ThemedText.helper(" ")
        let frame = ModalFrame.make(title: title, footerLeft: hint, footerRight: [cancel, primaryButton], width: 540, height: 200)
        for v in views { frame.add(v) }
        // The sheet is as tall as its form (up to what the screen allows).
        frame.root.layoutSubtreeIfNeeded()
        window.contentView = frame.root
        heightConstraint = frame.root.constraints.first { $0.firstAttribute == .height }
        bodyStack = frame.body
        window.initialFirstResponder = order.compactMap { controls[$0] }.first
        fit()
    }

    private let primaryButton: ModalButton
    private var heightConstraint: NSLayoutConstraint?
    private var bodyStack: NSStackView?

    /// Resizes the sheet to its form: header 56 + body + footer 61, at most 640.
    private func fit() {
        guard let body = bodyStack, let hc = heightConstraint else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        hc.constant = min(640, 56 + body.fittingSize.height + 32 + 61)
        window.setContentSize(NSSize(width: 540, height: hc.constant))
    }

    private func makeControl(_ f: FormField) -> NSControl {
        switch f.kind {
        case .text, .secure:
            let t: NSTextField = { if case .secure = f.kind { return NSSecureTextField() } else { return NSTextField() } }()
            t.stringValue = f.value
            t.placeholderString = f.placeholder
            t.usesSingleLineMode = true
            t.delegate = self
            t.identifier = NSUserInterfaceItemIdentifier(f.id)
            return t
        case let .popup(items):
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            for i in items { p.addItem(withTitle: i.title); p.lastItem?.representedObject = i.value }
            if let idx = items.firstIndex(where: { $0.value == f.value }) { p.selectItem(at: idx) }
            p.target = self; p.action = #selector(controlChanged(_:))
            p.identifier = NSUserInterfaceItemIdentifier(f.id)
            return p
        case let .combo(options):
            let c = NSComboBox()
            c.addItems(withObjectValues: options)
            c.stringValue = f.value
            c.placeholderString = f.placeholder
            c.completes = true
            c.delegate = self
            c.identifier = NSUserInterfaceItemIdentifier(f.id)
            return c
        case .check:
            let b = Kit.checkbox("", on: f.value == "1", self, #selector(controlChanged(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(f.id)
            return b
        }
    }

    // MARK: Values

    func value(_ id: String) -> String {
        switch controls[id] {
        case let p as NSPopUpButton: return p.selectedItem?.representedObject as? String ?? ""
        case let b as NSButton: return b.state == .on ? "1" : "0"
        case let t as NSTextField: return t.stringValue
        default: return ""
        }
    }

    var values: [String: String] { Dictionary(uniqueKeysWithValues: order.map { ($0, value($0)) }) }

    func set(_ id: String, _ v: String) {
        switch controls[id] {
        case let p as NSPopUpButton: if let i = p.itemArray.firstIndex(where: { ($0.representedObject as? String) == v }) { p.selectItem(at: i) }
        case let b as NSButton: b.state = v == "1" ? .on : .off
        case let t as NSTextField: t.stringValue = v
        default: break
        }
    }

    func setHidden(_ id: String, _ hidden: Bool) { rows[id]?.isHidden = hidden }

    func setOptions(_ id: String, _ options: [String]) {
        guard let c = controls[id] as? NSComboBox else { return }
        c.removeAllItems(); c.addItems(withObjectValues: options)
    }

    /// Empties every secure field (call right after taking the value).
    func clearSecure() { for c in controls.values { if c is NSSecureTextField { (c as? NSTextField)?.stringValue = "" } } }

    // MARK: Presenting

    func present(on parent: NSWindow) {
        self.parent = parent
        fit()
        parent.beginSheet(window)
        window.makeFirstResponder(window.initialFirstResponder)
    }

    func close() {
        clearSecure()
        if let parent, window.sheetParent === parent { parent.endSheet(window) } else { window.orderOut(nil) }
    }

    func showErrors(_ errs: [FieldError], general: String? = nil) {
        for (id, label) in errors {
            let mine = errs.filter { $0.field == id }
            label.stringValue = mine.map(\.message).joined(separator: "\n")
            label.isHidden = mine.isEmpty
        }
        summary.stringValue = general ?? errs.filter { errors[$0.field] == nil }.map(\.message).joined(separator: "\n")
        summary.isHidden = summary.stringValue.isEmpty
        fit()
        if let first = errs.first(where: { controls[$0.field] != nil }) { window.makeFirstResponder(controls[first.field]) }
    }

    // MARK: Actions

    @objc func submitTapped() {
        let errs = validate(values)
        showErrors(errs)
        guard errs.isEmpty else { return }
        onSubmit?(values)
    }

    @objc func cancelTapped() { close() }

    @objc private func controlChanged(_ sender: NSControl) { if let id = sender.identifier?.rawValue { onChange?(id, self) } }

    func controlTextDidChange(_ obj: Notification) {
        guard let t = obj.object as? NSControl, let id = t.identifier?.rawValue else { return }
        if let label = errors[id], !label.isHidden { label.isHidden = true }
        onChange?(id, self)
    }

    func debugState() -> String {
        order.map { "\($0)=\(controls[$0] is NSSecureTextField ? "•" : value($0))\(rows[$0]?.isHidden == true ? " (hidden)" : "")" }.joined(separator: "\n")
            + "\nerrors: " + errors.compactMap { $0.value.isHidden ? nil : "\($0.key): \($0.value.stringValue)" }.sorted().joined(separator: " | ")
            + (summary.isHidden ? "" : "\nsummary: " + summary.stringValue)
    }
}
