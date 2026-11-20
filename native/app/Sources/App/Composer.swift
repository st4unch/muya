// WP2 — the message box under the terminal (src/redesign/Composer.tsx): placeholder "Message <name>… ( / commands, @ files )"
// (shells: "Run a shell command in <name>…"), a Mode chip (Claude's permission mode), "@ Add file", "/ Commands", the hint line
// "↩ send · ⇧↩ newline · ↑ history" and a round send button. Enter pastes the text into the selected session and presses Return.

import AppKit

final class ComposerTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var onSend: ((String) -> Void)?
    var onEscape: (() -> Void)?
    var onHistory: (([String]) -> Void)?   // P4: persisted as apex.composerHistory.agent
    var history: [String] = [] { didSet { onHistory?(history) } }
    private var cursor: Int?
    private var draft = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
                                           withAttributes: [.font: ThemeFont.sans(14), .foregroundColor: Theme.dynamic(.textMuted)])
        }
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }

    func send() {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if history.last != t { history.append(t); if history.count > PrefCodec.maxHistory { history.removeFirst() } }
        cursor = nil; string = ""; needsDisplay = true
        onSend?(t)
    }
    private func show(_ s: String) { string = s; setSelectedRange(NSRange(location: (s as NSString).length, length: 0)); needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // return / enter
            if event.modifierFlags.contains(.shift) { insertNewline(nil) } else { send() }
        case 53: onEscape?()
        case 126 where selectedRange().location == 0 || !string.contains("\n"): // up: older message
            guard !history.isEmpty else { return }
            if cursor == nil { draft = string; cursor = history.count }
            cursor = max(0, cursor! - 1); show(history[cursor!])
        case 125 where cursor != nil:
            let n = cursor! + 1
            if n >= history.count { cursor = nil; show(draft) } else { cursor = n; show(history[n]) }
        default: super.keyDown(with: event)
        }
    }
}

final class Composer: FillView {
    let text = ComposerTextView()
    private let scroll = NSScrollView()
    private let slashButton = ComposerChip("/ Commands")
    private let fileButton = ComposerChip("@ Add file")
    private let sendButton = SendButton()
    private var modeChip: ComposerChip?
    var onModeMenu: ((NSView) -> Void)?   // the chip's permission-mode picker (ModeMenu.swift)
    private var heightC: NSLayoutConstraint!
    var onSend: ((String) -> Void)?
    var onSlash: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onEscape: (() -> Void)?
    static let height: CGFloat = 135

    init() {
        super.init(.bgApp)
        top = true
        translatesAutoresizingMaskIntoConstraints = false
        heightC = heightAnchor.constraint(equalToConstant: Self.height); heightC.isActive = true
        text.isRichText = false; text.drawsBackground = false; text.font = ThemeFont.sans(14)
        text.textColor = Theme.dynamic(.text); text.insertionPointColor = Theme.dynamic(.text)
        text.textContainerInset = NSSize(width: 4, height: 2); text.isAutomaticQuoteSubstitutionEnabled = false
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Message")
        scroll.documentView = text; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        [scroll, slashButton, fileButton, sendButton].forEach(addSubview)
        text.onSend = { [weak self] t in self?.onSend?(t) }
        text.onEscape = { [weak self] in self?.onEscape?() }
        sendButton.onClick = { [weak self] in self?.text.send() }
        slashButton.onClick = { [weak self] in self?.onSlash?() }
        fileButton.onClick = { [weak self] in self?.chooseFiles() }
        setAccessibilityRole(.group); setAccessibilityLabel("Composer")
    }
    required init?(coder: NSCoder) { fatalError() }

    func setShown(_ on: Bool) { heightC.constant = on ? Self.height : 0; isHidden = !on }

    private var sig = ""
    func configure(_ s: SessionModel?) {
        let n = "\(s?.id ?? 0)|\(s?.name ?? "")|\(s?.screen?.modeDetected ?? false)|\(s?.screen?.mode ?? "")|\(s?.exited != nil)"
        guard n != sig else { return }; sig = n
        let claude = s?.screen?.modeDetected == true
        text.placeholder = s.map { claude ? "Message \($0.name)… ( / commands, @ files )" : "Run a shell command in \($0.name)…" } ?? ""
        modeChip?.removeFromSuperview(); modeChip = nil
        if let s, claude, s.exited == nil {
            let mode = s.screen?.mode ?? "default"
            let p = ComposerChip("Mode: \(PermissionModes.chipLabel(mode)) ▾", danger: PermissionModes.isBypass(mode))   // today's MODE_LABEL; click opens the picker
            p.onClick = { [weak self, weak p] in if let p { self?.onModeMenu?(p) } }
            addSubview(p); modeChip = p
        }
        text.isEditable = s?.exited == nil
        needsLayout = true
    }

    private var box: NSRect { NSRect(x: 20, y: 14, width: bounds.width - 40, height: bounds.height - 14 - 16) }
    override func layout() {
        super.layout()
        let b = box
        scroll.frame = NSRect(x: b.minX + 12, y: b.minY + 10, width: b.width - 24, height: b.height - 62)
        text.frame.size.width = scroll.contentSize.width
        var x = b.minX + 12
        let y = b.maxY - 10 - 32   // the chip row is 32 px high (the send button); chips are 26 px, centred
        if let m = modeChip { let w = m.intrinsicContentSize.width; m.frame = NSRect(x: x, y: y + 1, width: w, height: 26); x += w + 8 }
        for btn in [fileButton, slashButton] { let w = btn.intrinsicContentSize.width; btn.frame = NSRect(x: x, y: y + 1, width: w, height: 26); x += w + 8 }
        sendButton.frame = NSRect(x: b.maxX - 12 - 32, y: y, width: 32, height: 32)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let b = box
        let p = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        Theme.dynamic(.bgInput).setFill(); p.fill(); Theme.dynamic(.borderStrong).setStroke(); p.stroke()
        let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textMuted)]
        let h = ("↩ send  ·  ⇧↩ newline  ·  ↑ history" as NSString)
        let w = h.size(withAttributes: a)
        h.draw(at: NSPoint(x: b.maxX - 12 - 32 - 12 - w.width, y: b.maxY - 10 - 16 - w.height / 2), withAttributes: a)
    }
    private func chooseFiles() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in if r == .OK { self?.onFiles?(p.urls) } }
    }
}

/// Round black send button with an up arrow.
final class SendButton: NSControl {
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
    override func draw(_ dirtyRect: NSRect) {
        Theme.dynamic(.primaryBg).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState(); ctx.translateBy(x: 8, y: 8)
        ThemeIcons.draw(.send, in: ctx, size: 16, color: Theme.dynamic(.primaryFg)); ctx.restoreGState()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}


/// Today's composer chip (.rd-chip): 26 px pill, 1 px --border-control, 12 px text; the danger variant is the bypass-mode chip.
final class ComposerChip: NSControl {
    let title: String, danger: Bool
    var onClick: (() -> Void)?
    init(_ title: String, danger: Bool = false) {
        self.title = title; self.danger = danger
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var attrs: [NSAttributedString.Key: Any] { [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(danger ? .dangerText : .textTertiary)] }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil((title as NSString).size(withAttributes: attrs).width) + 22, height: 26) }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        if danger { Theme.dynamic(.dangerBtnBg).setFill(); p.fill() }
        Theme.dynamic(danger ? .dangerBorder : .borderControl).setStroke(); p.lineWidth = 1; p.stroke()
        let sz = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 36 || event.keyCode == 49 { onClick?() } else { super.keyDown(with: event) } }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
