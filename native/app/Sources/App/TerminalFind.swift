// ⌘F in a terminal (today's Terminal.tsx search overlay): a small bar in the top-right corner with a field and previous /
// next / close; the current match is selected (so it shows highlighted) and scrolled into view. Enter = next, Shift+Enter =
// previous, Escape = close. Matches are plain case-insensitive text over the whole buffer, scrollback included.

import AppKit

final class TerminalFindBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    var onQuery: ((String) -> Void)?
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.font = ThemeFont.mono(12); field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.textColor = Theme.dynamic(.text)
        field.placeholderAttributedString = NSAttributedString(string: "Search…", attributes: [.font: ThemeFont.mono(12), .foregroundColor: NSColor.systemGray])
        field.delegate = self; field.setAccessibilityLabel("Search in the terminal")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 176).isActive = true
        status.font = ThemeFont.mono(10); status.textColor = Theme.dynamic(.textMuted); status.alignment = .right
        status.setContentHuggingPriority(.required, for: .horizontal)
        let prev = FindIconButton(.paths(["m18 15-6-6-6 6"]), label: "Previous match", tip: "Previous match (Shift+Enter)")
        let next = FindIconButton(.chevronDown, label: "Next match", tip: "Next match (Enter)")
        let close = FindIconButton(.close, label: "Close search", tip: "Close (Escape)")
        prev.onClick = { [weak self] in self?.onStep?(false) }
        next.onClick = { [weak self] in self?.onStep?(true) }
        close.onClick = { [weak self] in self?.onClose?() }
        let row = Kit.hstack([field, status, prev, next, close], spacing: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                                     row.topAnchor.constraint(equalTo: topAnchor, constant: 4), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)])
        wantsLayer = true; layer?.shadowOpacity = 0.3; layer?.shadowRadius = 8; layer?.shadowOffset = CGSize(width: 0, height: -3)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Terminal search")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        Theme.dynamic(.bgControl).setFill(); p.fill()
        Theme.dynamic(.borderStrong).setStroke(); p.lineWidth = 1; p.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}   // clicks on the bar never reach the terminal underneath

    func setStatus(_ s: String) { status.stringValue = s }

    func controlTextDidChange(_ obj: Notification) { onQuery?(field.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            onStep?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)); return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }
}

extension TerminalView {
    /// ⌘F / "Find…": opens the bar (or re-focuses it) and searches for what is already typed.
    func showFind() {
        let bar = findBar ?? { let b = TerminalFindBar(frame: .zero); wireFind(b); findBar = b; return b }()
        if bar.superview == nil { addSubview(bar) }
        bar.isHidden = false
        layoutFind()
        window?.makeFirstResponder(bar.field)
        if !bar.field.stringValue.isEmpty { runFind(bar.field.stringValue, step: nil) }
    }

    func hideFind() {
        guard let bar = findBar, !bar.isHidden else { return }
        bar.isHidden = true
        findMatches = []; findCurrent = nil
        session?.replica.clearSelection(); requestDraw()
        window?.makeFirstResponder(self)
    }

    var findIsOpen: Bool { findBar.map { !$0.isHidden } ?? false }

    func layoutFind() {
        guard let bar = findBar, !bar.isHidden else { return }
        let size = bar.fittingSize
        bar.frame = NSRect(x: max(bounds.maxX - size.width - 12, 0), y: 8, width: size.width, height: size.height)
    }

    private func wireFind(_ b: TerminalFindBar) {
        b.onQuery = { [weak self] q in self?.runFind(q, step: nil) }
        b.onStep = { [weak self] fwd in
            guard let self, let bar = self.findBar else { return }
            self.runFind(bar.field.stringValue, step: fwd)
        }
        b.onClose = { [weak self] in self?.hideFind() }
    }

    /// `step` nil: a new query (start at the first match from the top of the view); true / false: next / previous.
    func runFind(_ query: String, step: Bool?) {
        guard let replica = session?.replica else { return }
        if step == nil || findMatches.isEmpty {
            findMatches = TerminalFind.matches(lines: replica.bufferLines(), query: query)
            findCurrent = step == nil ? TerminalFind.firstAtOrAfter(findMatches, row: replica.viewportTop) : TerminalFind.step(count: findMatches.count, current: nil, forward: step ?? true)
        } else {
            findMatches = TerminalFind.matches(lines: replica.bufferLines(), query: query)   // the buffer may have grown since
            findCurrent = TerminalFind.step(count: findMatches.count, current: min(findCurrent ?? -1, findMatches.count - 1) < 0 ? nil : min(findCurrent!, findMatches.count - 1), forward: step ?? true)
        }
        if let i = findCurrent, findMatches.indices.contains(i) {
            replica.show(findMatches[i])
            findBar?.setStatus("\(i + 1)/\(findMatches.count)")
        } else {
            replica.clearSelection()
            findBar?.setStatus(query.isEmpty ? "" : "0/0")
        }
        requestDraw()
    }

    /// Debug socket / tests: "matches=N current=I selected=<text>".
    func findState() -> String {
        "open=\(findIsOpen) query=\(findBar?.field.stringValue ?? "") matches=\(findMatches.count) current=\(findCurrent.map(String.init) ?? "-") selected=\(session?.replica.selectedText() ?? "")"
    }
}
