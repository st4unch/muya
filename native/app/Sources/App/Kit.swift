// Shared building blocks of the page views, the editors and the Settings window. The row layout follows
// today's modalKit/SettingsModal: a bold 13 pt title, a helper line under it, the control on the right.
// Colours only through tokens (Theme.swift); every control gets an accessibility label.

import AppKit

extension NSControl {
    /// Labels the control and its cell: the Accessibility API exposes a control's cell as the element, and the cell
    /// does not inherit the control's label (a field, pop-up or segmented control would be read without its name).
    func setSpokenLabel(_ text: String) { setAccessibilityLabel(text); cell?.setAccessibilityLabel(text) }
}

/// A multi-line field in a dialog: Tab and Shift-Tab leave it for the next / previous control (an NSTextView inserts
/// a tab character instead, which traps the keyboard inside the field).
final class DialogTextView: NSTextView {
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
}

enum Kit {
    static func label(_ s: String, size: CGFloat = 13, bold: Bool = false, color: NSColor = Token.text, lines: Int = 1) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = ThemeFont.sans(size, bold ? .semibold : .regular)   // IBM Plex Sans like today's Muya
        l.textColor = color
        l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        l.maximumNumberOfLines = lines
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    static func helper(_ s: String) -> NSTextField {
        let l = label(s, size: 11, color: Token.textSecondary, lines: 0)
        l.preferredMaxLayoutWidth = 320
        return l
    }

    static func button(_ title: String, _ target: AnyObject?, _ action: Selector, label: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.setAccessibilityLabel(label ?? title)
        return b
    }

    static func field(_ placeholder: String = "", label: String, width: CGFloat? = nil) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.setSpokenLabel(label)
        f.lineBreakMode = .byTruncatingTail
        f.usesSingleLineMode = true
        if let width { f.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return f
    }

    static func checkbox(_ title: String, on: Bool, _ target: AnyObject?, _ action: Selector?) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: target, action: action)
        b.state = on ? .on : .off
        b.setAccessibilityLabel(title)
        return b
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal; s.spacing = spacing; s.alignment = alignment
        return s
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.spacing = spacing; s.alignment = alignment
        return s
    }

    /// Title + helper on the left, `control` on the right (SettingsModal's row).
    static func row(title: String, helper: String?, control: NSView) -> NSView {
        let texts = vstack([label(title, bold: true)] + (helper.map { [Kit.helper($0)] } ?? []), spacing: 2)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let r = hstack([texts, control], spacing: 16, alignment: .top)
        r.distribution = .fill
        return r
    }

    static func divider() -> NSView {
        let b = NSBox(); b.boxType = .separator
        return b
    }

    static func sectionTitle(_ s: String) -> NSTextField { label(s.uppercased(), size: 11, bold: true, color: Token.textSecondary) }

    /// A scroll view around a table / outline, labelled for accessibility.
    static func scroll(_ doc: NSView, label: String) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = doc
        s.hasVerticalScroller = true
        s.drawsBackground = false
        s.borderType = .noBorder
        doc.setAccessibilityLabel(label)
        return s
    }

    static func pin(_ v: NSView, in parent: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        v.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
        ])
    }
}

extension Token {
    static let danger = dynamic("danger", dark: 0xE0626B, light: 0xC62828)
    static let success = dynamic("success", dark: 0x7FC27A, light: 0x2E7D32)
    static let pageBackground = Theme.dynamic(.bgApp)
    static let card = dynamic("card", dark: 0x23272D, light: 0xF1F2F4)
}

/// A full-size page over the terminal area: a title bar (title, optional status, Close) and content.
class PageView: NSView {
    let titleLabel = Kit.label("", size: 15, bold: true)
    let accessory = NSStackView()
    let content = NSView()
    var onClose: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.stringValue = title
        titleLabel.setAccessibilityRole(.staticText)
        let close = Kit.button("Close", self, #selector(closeTapped), label: "Close \(title)")
        close.keyEquivalent = ""
        accessory.orientation = .horizontal; accessory.spacing = 8
        let bar = Kit.hstack([titleLabel, NSView(), accessory, close], spacing: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        let sep = Kit.divider()
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar); addSubview(sep); addSubview(content)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sep.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: sep.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Token.pageBackground.cgColor }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    @objc func closeTapped() { onClose?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    /// Called when the page is shown: load fresh data, move focus.
    func didShow() {}
    func didHide() {}
}

/// An outline / table that reports Return as "activate" so a list is fully usable from the keyboard.
final class KeyTable: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0, let onReturn { onReturn(); return }
        super.keyDown(with: event)
    }
}

final class KeyOutline: NSOutlineView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0, let onReturn { onReturn(); return }
        super.keyDown(with: event)
    }
}

func jsonObjects(_ any: Any?) -> [[String: Any]] { (any as? [[String: Any]]) ?? [] }

func describe(_ error: ClientError) -> String {
    if case let .server(_, m) = error { return m }
    return "\(error)"
}

/// A rounded panel whose fill follows the appearance (CALayer colours do not, unless re-resolved).
final class CardView: NSStackView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Token.card.cgColor
            layer?.cornerRadius = 8
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
