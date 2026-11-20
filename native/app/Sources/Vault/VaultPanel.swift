// The "Vault Source" panel (old VaultConfigPanel): point Muya at an Obsidian vault. A sheet over the main window,
// built from the shared Theme parts. Rows: Current / Auto-detected / Custom path (+ Browse…). Nothing is scanned
// outside the daemon's ordinary-folder scan; any other vault is a path the user types or picks here.

import AppKit

/// Dialog surface: --bg-panel.
private final class PanelRoot: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Theme.dynamic(.bgPanel).setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A bordered, clickable path (an auto-detected vault).
private final class PathRow: NSControl {
    let path: String
    var onClick: (() -> Void)?
    private var hover = false
    init(_ path: String) {
        self.path = path
        super.init(frame: .zero)
        setAccessibilityRole(.button); setAccessibilityLabel("Use vault \(path)")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }
    override func draw(_ dirtyRect: NSRect) {
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        if hover { Theme.dynamic(.bgControl).setFill(); r.fill() }
        Theme.dynamic(.borderControl).setStroke(); r.lineWidth = 1; r.stroke()
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingMiddle
        let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.mono(12), .foregroundColor: Theme.dynamic(.text), .paragraphStyle: para]
        let s = path as NSString
        let h = s.size(withAttributes: a).height
        s.draw(in: NSRect(x: 10, y: (bounds.height - h) / 2, width: bounds.width - 20, height: h), withAttributes: a)
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { if isEnabled { onClick?() } }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A sheet window that closes on Esc.
private final class EscWindow: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class VaultConfigPanel: NSObject, NSTextFieldDelegate {
    let window: NSWindow
    private let escWindow: EscWindow
    private let service: VaultService
    private weak var parent: NSWindow?
    private let current = NSTextField(wrappingLabelWithString: "")
    private let currentIcon = ThemeIconView(icon: .check, color: Theme.dynamic(.successText), size: 14)
    private let banner = ThemedBox(.card)
    private let candidatesStack = NSStackView()
    private let candidatesLabel = ThemedText.label("Auto-detected")
    private let field = NSTextField()
    private let setButton = ThemedButton("Set", style: .primary)
    private let browseButton = ThemedButton("Browse…")
    private let busyLabel = ThemedText.helper("Applying…")
    private let errorLabel = ThemedText.helper("")
    private(set) var source: VaultSource?
    private(set) var candidates: [String] = []
    private(set) var busy = false { didSet { setButton.isEnabled = !busy && VaultLogic.canSet(field.stringValue); browseButton.isEnabled = !busy; busyLabel.isHidden = !busy; candidatesStack.arrangedSubviews.forEach { ($0 as? NSControl)?.isEnabled = !busy } } }
    var onChanged: (() -> Void)?
    var onClosed: (() -> Void)?

    init(rpc: SSHRpc, parent: NSWindow) {
        service = VaultService(rpc: rpc)
        self.parent = parent
        escWindow = EscWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window = escWindow
        super.init()
        escWindow.onCancel = { [weak self] in self?.close() }
        window.isReleasedWhenClosed = false
        window.setAccessibilityLabel("Vault Source")
        build()
    }

    private func build() {
        let title = ThemedText.title("Vault Source"); title.font = ThemeFont.sans(15, .semibold)
        let intro = ThemedText.helper("The Obsidian vault Muya searches for notes. Pick a folder that contains an .obsidian folder.")

        let warnText = ThemedText.helper("Vault search server not installed — run this once, then pick the vault again:")
        warnText.textColor = Theme.dynamic(.warningText)
        let cmd = NSTextField(labelWithString: VaultLogic.setupCommand)
        cmd.font = ThemeFont.mono(12); cmd.textColor = Theme.dynamic(.warningText); cmd.isSelectable = true
        let warnNote = ThemedText.helper("From the Muya repo. Installs the semantic-search engine and its Python packages.")
        warnNote.textColor = Theme.dynamic(.warningText)
        banner.kind = .card
        let warn = Kit.vstack([warnText, cmd, warnNote], spacing: 4)
        warn.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(warn)
        NSLayoutConstraint.activate([
            warn.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10), warn.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -10),
            warn.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12), warn.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
        ])
        banner.isHidden = true

        current.font = ThemeFont.mono(12); current.lineBreakMode = .byTruncatingMiddle; current.maximumNumberOfLines = 2
        current.setAccessibilityLabel("Current vault")
        let currentRow = Kit.hstack([currentIcon, current], spacing: 6)

        candidatesStack.orientation = .vertical; candidatesStack.alignment = .leading; candidatesStack.spacing = 6

        field.placeholderString = "/path/to/vault"
        field.font = ThemeFont.mono(12)
        field.setSpokenLabel("Custom vault path")
        field.delegate = self
        field.usesSingleLineMode = true
        setButton.onClick = { [weak self] in self?.setTapped() }
        browseButton.onClick = { [weak self] in self?.browse() }
        browseButton.setAccessibilityLabel("Browse for a vault folder")
        setButton.isEnabled = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let customRow = Kit.hstack([field, setButton, browseButton], spacing: 8)

        busyLabel.isHidden = true
        errorLabel.textColor = Theme.dynamic(.dangerText); errorLabel.isHidden = true
        let close = ThemedButton("Close")
        close.onClick = { [weak self] in self?.close() }
        let footer = Kit.hstack([busyLabel, NSView(), close], spacing: 8)

        let col = Kit.vstack([title, intro, banner, ThemedText.label("Current"), currentRow, candidatesLabel, candidatesStack, ThemedText.label("Custom path"), customRow, errorLabel, footer], spacing: 8)
        col.setCustomSpacing(4, after: title)
        col.setCustomSpacing(14, after: intro); col.setCustomSpacing(14, after: banner); col.setCustomSpacing(14, after: currentRow)
        col.setCustomSpacing(14, after: candidatesStack); col.setCustomSpacing(14, after: customRow)
        col.translatesAutoresizingMaskIntoConstraints = false
        let root = PanelRoot(frame: NSRect(x: 0, y: 0, width: 460, height: 400))
        root.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            col.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22), col.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            col.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18),
            root.widthAnchor.constraint(equalToConstant: 460),
        ])
        for v in col.arrangedSubviews where v !== col.arrangedSubviews.first { v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        window.contentView = root
        candidatesLabel.isHidden = true; candidatesStack.isHidden = true
    }

    private func fitWindow() {
        window.contentView?.layoutSubtreeIfNeeded()
        if let col = window.contentView?.subviews.first as? NSStackView { window.setContentSize(NSSize(width: 460, height: col.fittingSize.height + 40)) }
    }

    func present() {
        refresh()
        guard let parent else { return }
        parent.beginSheet(window)
    }

    func close() {
        guard let parent else { return }
        parent.endSheet(window); window.orderOut(nil)
        onClosed?()
    }

    func refresh() {
        errorLabel.isHidden = true
        service.status { [weak self] r in
            guard let self else { return }
            switch r {
            case let .success(s): self.show(s)
            case let .failure(e): self.show(nil); self.showError(e.message)
            }
        }
        service.candidates { [weak self] list in self?.showCandidates(list) }
    }

    private func show(_ s: VaultSource?) {
        source = s
        banner.isHidden = s?.serverInstalled ?? true
        current.stringValue = VaultLogic.currentText(s)
        current.textColor = s?.resolvedPath != nil ? Theme.dynamic(.successText) : Theme.dynamic(.textFaint)
        currentIcon.isHidden = s?.resolvedPath == nil
        if let c = field.stringValue.isEmpty ? s?.configuredPath : nil { field.stringValue = c }
        setButton.isEnabled = !busy && VaultLogic.canSet(field.stringValue)
        fitWindow()
    }

    private func showCandidates(_ list: [String]) {
        candidates = list
        candidatesStack.arrangedSubviews.forEach { candidatesStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for path in list {
            let row = PathRow(path)
            row.onClick = { [weak self] in self?.apply(path) }
            row.translatesAutoresizingMaskIntoConstraints = false
            candidatesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: candidatesStack.widthAnchor).isActive = true
        }
        candidatesLabel.isHidden = list.isEmpty; candidatesStack.isHidden = list.isEmpty
        fitWindow()
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = VaultLogic.errorText(message); errorLabel.isHidden = false
        fitWindow()
    }

    func apply(_ path: String) {
        guard !busy else { return }
        busy = true; errorLabel.isHidden = true
        service.apply(path) { [weak self] r in
            guard let self else { return }
            self.busy = false
            switch r {
            case let .success(s): self.show(s); self.onChanged?()
            case let .failure(e): self.showError(e.message)
            }
        }
    }

    private func setTapped() { apply(field.stringValue) }

    private func browse() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.message = "Select your Obsidian vault folder"
        p.prompt = "Choose"
        if p.runModal() == .OK, let url = p.url { field.stringValue = url.path; apply(url.path) }
    }

    func controlTextDidChange(_ obj: Notification) { setButton.isEnabled = !busy && VaultLogic.canSet(field.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { if setButton.isEnabled { setTapped() }; return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }

    // Test / debug hooks.
    var currentString: String { current.stringValue }
    var bannerShown: Bool { !banner.isHidden }
    var errorString: String { errorLabel.isHidden ? "" : errorLabel.stringValue }
    func typeCustom(_ text: String) { field.stringValue = text; setButton.isEnabled = !busy && VaultLogic.canSet(text) }
    func tapSet() { setTapped() }
}
