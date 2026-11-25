// The Password Store as classic draws it: one card per group (collapsible), a grid of credential cards inside, each card
// with its row actions on the right (eye, copy, edit, delete). Spec: docs/prd-secrets-parity.cards-spec.md.
// Colours only through Theme tokens; sizes are classic's (card radius 10, padding 16, gap 12, action buttons 28 square).

import AppKit

extension GlyphIcon {
    static let eye = GlyphIcon.paths(["M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0", "M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0z"])
    static let eyeOff = GlyphIcon.paths(["M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49", "M14.084 14.158a3 3 0 0 1-4.242-4.242", "M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143", "m2 2 20 20"])
    static let copy = GlyphIcon.paths(["M10 8h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H10a2 2 0 0 1-2-2V10a2 2 0 0 1 2-2z", "M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"])
    static let download = GlyphIcon.paths(["M12 15V3", "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4", "m7 10 5 5 5-5"])
    static let upload = GlyphIcon.paths(["M12 3v12", "m17 8-5-5-5 5", "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"])
    static let unlock = GlyphIcon.paths(["M7 11V7a5 5 0 0 1 9.9-1", "M5 11h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2z"])
    static let fingerprint = GlyphIcon.paths(["M12 10a2 2 0 0 0-2 2c0 1.02-.1 2.51-.26 4", "M14 13.12c0 2.38 0 6.38-1 8.88", "M17.29 21.02c.12-.6.43-2.3.5-3.02", "M2 12a10 10 0 0 1 18-6", "M2 16h.01", "M21.8 16c.2-2 .131-5.354 0-6", "M5 19.5C5.5 18 6 15 6 12a6 6 0 0 1 .34-2", "M8.65 22c.21-.66.45-1.32.57-2", "M9 6.8a6 6 0 0 1 9 5.2v2"])
    static let check = GlyphIcon.paths(["M20 6 9 17l-5-5"])
    static let lockIcon = GlyphIcon.paths(["M7 11V7a5 5 0 0 1 10 0v4", "M5 11h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2z"])
}

/// A card the grid can lay out: a credential card or the in-place edit form.
@MainActor
protocol FitCard: NSView {
    func height(for width: CGFloat) -> CGFloat
    @discardableResult func fit(width: CGFloat) -> CGFloat
}

/// What the store page needs to draw one credential card.
struct CredCardModel {
    var meta: SecretMeta
    var revealed: String?
    var copied: Bool
}

/// classic's CARD: radius 10, 1px --border, --bg-panel.
class CardBox: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.dynamic(.bgPanel).setFill(); path.fill()
        Theme.dynamic(.border).setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Revealed value block: --bg-segment, radius 4, padding 8, mono 12, selectable, at most 160 high.
private final class RevealBox: NSView {
    let text = NSTextField(wrappingLabelWithString: "")
    override var isFlipped: Bool { true }
    init(_ value: String) {
        super.init(frame: .zero)
        text.stringValue = value
        text.font = ThemeFont.mono(12); text.textColor = Theme.dynamic(.text)
        text.isSelectable = true; text.lineBreakMode = .byCharWrapping
        text.setAccessibilityLabel("Secret value")
        addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(for width: CGFloat) -> CGFloat {
        min(160, ceil(text.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 16, height: .greatestFiniteMagnitude)).height) + 16)
    }
    func fit(width: CGFloat) {
        let h = height(for: width)
        frame.size = NSSize(width: width, height: h)
        text.frame = NSRect(x: 8, y: 8, width: width - 16, height: h - 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.dynamic(.bgSegment).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

@MainActor
final class CredCardView: CardBox, FitCard {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let eyeButton: ModalButton, copyButton: ModalButton, editButton: ModalButton, exportButton: ModalButton, deleteButton: ModalButton
    private var reveal: RevealBox?
    let model: CredCardModel
    static let pad: CGFloat = 16, actionSide: CGFloat = 28, actionGap: CGFloat = 4
    static var actionsWidth: CGFloat { 4 * actionGap + 5 * actionSide }

    init(_ m: CredCardModel, onEye: @escaping () -> Void, onCopy: @escaping () -> Void, onEdit: @escaping () -> Void, onExport: @escaping () -> Void, onDelete: @escaping () -> Void) {
        model = m
        func icon(_ i: GlyphIcon, _ label: String, _ go: @escaping () -> Void) -> ModalButton {
            let b = ModalButton("", icon: i, height: Self.actionSide, iconOnly: true, label: label)
            b.toolTip = label; b.onClick = go
            return b
        }
        eyeButton = icon(m.revealed == nil ? .eye : .eyeOff, m.revealed == nil ? "View value" : "Hide value", onEye)
        copyButton = icon(m.copied ? .check : .copy, "Copy value", onCopy)
        editButton = icon(.pencil, "Edit credential", onEdit)
        exportButton = icon(.download, "Export \(CredKindName.title(m.meta.kind).lowercased())", onExport)
        deleteButton = icon(.trash, "Delete credential", onDelete)
        super.init(frame: .zero)
        let s = NSMutableAttributedString(string: m.meta.label, attributes: [.font: ThemeFont.sans(14, .medium), .foregroundColor: Theme.dynamic(.text)])
        let meta = [m.meta.username, CredKindName.title(m.meta.kind)].filter { !$0.isEmpty }.joined(separator: " · ")
        s.append(NSAttributedString(string: "  " + meta, attributes: [.font: ThemeFont.mono(12), .foregroundColor: Theme.dynamic(.textMuted)]))
        if !m.meta.description.isEmpty {
            let p = NSMutableParagraphStyle(); p.paragraphSpacingBefore = 2
            s.append(NSAttributedString(string: "\n" + m.meta.description, attributes: [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textFaint), .paragraphStyle: p]))
        }
        title.attributedStringValue = s
        title.lineBreakMode = .byWordWrapping; title.isSelectable = false
        title.setAccessibilityLabel("\(m.meta.label), \(meta)")
        for v in [title, eyeButton, copyButton, editButton, exportButton, deleteButton] as [NSView] { addSubview(v) }
        if let r = m.revealed { let b = RevealBox(r); reveal = b; addSubview(b) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func headerHeight(width: CGFloat) -> CGFloat {
        let tw = width - 2 * Self.pad - Self.actionsWidth - 8
        return max(Self.actionSide, ceil(title.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: tw, height: .greatestFiniteMagnitude)).height))
    }

    func height(for width: CGFloat) -> CGFloat {
        var h = 2 * Self.pad + headerHeight(width: width)
        if let r = reveal { h += 8 + r.height(for: width - 2 * Self.pad) }
        return h
    }

    /// Lays the card out for `width` and returns its height.
    @discardableResult
    func fit(width: CGFloat) -> CGFloat {
        let p = Self.pad, hh = headerHeight(width: width)
        let tw = width - 2 * p - Self.actionsWidth - 8
        title.frame = NSRect(x: p, y: p + (hh - ceil(title.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: tw, height: .greatestFiniteMagnitude)).height)) / 2, width: tw, height: ceil(title.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: tw, height: .greatestFiniteMagnitude)).height))
        var x = width - p - Self.actionsWidth
        for b in [eyeButton, copyButton, editButton, exportButton, deleteButton] {
            b.translatesAutoresizingMaskIntoConstraints = true
            b.frame = NSRect(x: x, y: p + (hh - Self.actionSide) / 2, width: Self.actionSide, height: Self.actionSide)
            x += Self.actionSide + Self.actionGap
        }
        var h = 2 * p + hh
        if let r = reveal { r.fit(width: width - 2 * p); r.frame.origin = NSPoint(x: p, y: p + hh + 8); h += 8 + r.frame.height }
        frame.size = NSSize(width: width, height: h)
        return h
    }
}

/// One group: header (chevron, name, count) and the grid of its cards.
@MainActor
/// A collapsible group card holding a grid of cards: the Password Store's credential groups and the Servers tab's
/// server groups both draw with this (classic uses the same GroupCard for both).
final class GroupCardView: CardBox {
    private let chevron: GlyphView, name = Kit.label("", size: 14, color: Theme.dynamic(.text)), count = Kit.label("", size: 12, color: Theme.dynamic(.textMuted))
    private let header = NSView()
    let groupName: String
    let itemCount: Int
    let collapsed: Bool
    private(set) var cards: [FitCard]
    var onToggle: (() -> Void)?
    static let gap: CGFloat = 12, pad: CGFloat = 16, headerHeight: CGFloat = 20

    convenience init(group: CredGroup, collapsed: Bool, cards: [FitCard]) {
        self.init(name: group.name, count: group.items.count, noun: "items", collapsed: collapsed, cards: cards)
    }

    init(name title: String, count n: Int, noun: String = "items", collapsed: Bool, cards: [FitCard]) {
        groupName = title; itemCount = n; self.collapsed = collapsed; self.cards = cards
        chevron = GlyphView(collapsed ? .chevronRight : .chevronDown, size: 16, token: .textFaint)
        super.init(frame: .zero)
        name.stringValue = title; name.font = ThemeFont.sans(14, .medium)
        count.stringValue = "(\(n))"
        for v in [chevron, name, count] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = true; header.addSubview(v) }
        header.setAccessibilityElement(true); header.setAccessibilityRole(.button)
        header.setAccessibilityLabel("\(title), \(n) \(noun), \(collapsed ? "collapsed" : "expanded")")
        addSubview(header)
        if !collapsed { cards.forEach { addSubview($0) } }
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggle))
        header.addGestureRecognizer(click)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func toggle() { onToggle?() }

    /// Lays out for `width` (this card) with `columns` columns; returns the height.
    @discardableResult
    func fit(width: CGFloat, columns: Int) -> CGFloat {
        let p = Self.pad
        header.frame = NSRect(x: p, y: p, width: width - 2 * p, height: Self.headerHeight)
        chevron.frame = NSRect(x: 0, y: 2, width: 16, height: 16)
        let big = NSRect(x: 0, y: 0, width: 10000, height: 40)
        let nw = ceil(name.cell!.cellSize(forBounds: big).width), cw = ceil(count.cell!.cellSize(forBounds: big).width)
        let maxName = max(40, header.frame.width - 22 - cw - 6 - 6)
        name.frame = NSRect(x: 22, y: 0, width: min(nw, maxName), height: Self.headerHeight)
        count.frame = NSRect(x: name.frame.maxX + 6, y: 0, width: cw + 2, height: Self.headerHeight)
        var y = p + Self.headerHeight
        if !collapsed {
            y += Self.gap
            let inner = width - 2 * p, cols = max(1, columns)
            let cell = (inner - Self.gap * CGFloat(cols - 1)) / CGFloat(cols)
            var i = 0
            while i < cards.count {
                let row = cards[i ..< min(i + cols, cards.count)]
                let rowH = row.map { $0.height(for: cell) }.max() ?? 0
                for (j, c) in row.enumerated() {
                    c.fit(width: cell)
                    c.frame = NSRect(x: p + CGFloat(j) * (cell + Self.gap), y: y, width: cell, height: rowH)
                }
                y += rowH + Self.gap
                i += cols
            }
            y -= Self.gap
        }
        let h = y + p
        frame.size = NSSize(width: width, height: h)
        return h
    }
}

/// The scrolling document: the group cards, 12 apart.
@MainActor
final class CredCardsDocument: NSView {
    override var isFlipped: Bool { true }
    private(set) var groups: [GroupCardView] = []
    /// A new-credential / import form shown above the groups (classic puts it there).
    private(set) var topForm: CredFormCard?
    func setTop(_ f: CredFormCard?) { topForm?.removeFromSuperview(); topForm = f; if let f { addSubview(f) }; needsLayout = true }
    var pageWidthExtra: CGFloat = 48   // the page's own side margins, so the breakpoints see the page width as classic does

    func set(_ g: [GroupCardView]) {
        groups.forEach { $0.removeFromSuperview() }
        groups = g
        g.forEach(addSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        let w = bounds.width, cols = CredGroup.columns(pageWidth: w + pageWidthExtra)
        if let f = topForm { let h = f.fit(width: w); f.frame = NSRect(x: 0, y: 0, width: w, height: h); y = h + 12 }
        for g in groups {
            let h = g.fit(width: w, columns: cols)
            g.frame = NSRect(x: 0, y: y, width: w, height: h)
            y += h + 12
        }
        let total = max(0, y - (groups.isEmpty && topForm == nil ? 0 : 12))
        if abs(frame.height - total) > 0.5 { setFrameSize(NSSize(width: w, height: max(total, enclosingScrollView?.contentSize.height ?? 0))) }
    }
}


/// classic's CredForm card, in place of the card (edit) or above the groups (new / import): 2-column grid of fields, Cancel / Save.
@MainActor
final class CredFormCard: CardBox, FitCard {
    struct Values { var label = "", username = "", kind = "password", group = "", description = "", value = "" }
    struct Options { var title: String, primary: String, showKind = true, showValue = true, showExtras = true, valuePlaceholder = "Secret" }

    private let titleLabel = Kit.label("", size: 14, color: Theme.dynamic(.text))
    private let labelField = NSTextField(), userField = NSTextField(), groupField = NSTextField(), descField = NSTextField()
    private let secureField = NSSecureTextField()
    private let keyText = NSTextView()
    private let keyFrame = InputFrame(), keyScroll = NSScrollView()
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var boxes: [String: FieldBox] = [:]
    private let error = Kit.label("", size: 12, color: Theme.dynamic(.dangerText), lines: 0)
    private let save: ModalButton, cancel = ModalButton("Cancel", height: 32, label: "Cancel")
    private let opts: Options
    var onSave: ((Values) -> String?)?
    var onCancel: (() -> Void)?
    static let pad: CGFloat = 16, gap: CGFloat = 8, fieldH: CGFloat = 32, keyH: CGFloat = 96

    init(_ v: Values, options: Options) {
        opts = options
        save = ModalButton(options.primary, style: .primary, height: 32, label: options.primary)
        super.init(frame: .zero)
        titleLabel.stringValue = options.title; titleLabel.font = ThemeFont.sans(14, .medium)
        func box(_ id: String, _ f: NSTextField, _ ph: String, _ val: String) -> FieldBox {
            f.stringValue = val; f.placeholderString = ph
            let b = FieldBox(f); b.translatesAutoresizingMaskIntoConstraints = true
            boxes[id] = b; addSubview(b); return b
        }
        _ = box("label", labelField, "Label", v.label); _ = box("user", userField, "Username", v.username)
        _ = box("secret", secureField, options.valuePlaceholder, v.value)
        _ = box("group", groupField, "Group (optional)", v.group)
        _ = box("desc", descField, "Description (optional — shown to agents by name)", v.description)
        for (title, kind) in [("Password", "password"), ("SSH private key", "key"), ("Token", "token"), ("API key", "api_key")] {
            kindPopup.addItem(withTitle: title); kindPopup.lastItem?.representedObject = kind
        }
        if let i = kindPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == v.kind }) { kindPopup.selectItem(at: i) }
        let kb = FieldBox(kindPopup); kb.translatesAutoresizingMaskIntoConstraints = true; boxes["kind"] = kb; addSubview(kb)
        kindPopup.target = self; kindPopup.action = #selector(kindChanged)
        kindPopup.setAccessibilityLabel("Kind")
        kindPopup.setSpokenLabel("Kind")
        keyText.string = v.value; keyText.font = ThemeFont.mono(12); keyText.textColor = Theme.dynamic(.text)
        keyText.drawsBackground = false; keyText.isRichText = false; keyText.isAutomaticQuoteSubstitutionEnabled = false
        keyScroll.documentView = keyText; keyScroll.drawsBackground = false; keyScroll.hasVerticalScroller = true; keyScroll.scrollerStyle = .overlay
        keyText.isVerticallyResizable = true; keyText.textContainer?.widthTracksTextView = true; keyText.autoresizingMask = [.width]
        keyText.setAccessibilityLabel("SSH private key")
        keyFrame.addSubview(keyScroll); addSubview(keyFrame)
        error.isHidden = true
        for v in [titleLabel, error, save, cancel] as [NSView] { addSubview(v) }
        save.onClick = { [weak self] in self?.submit() }
        cancel.onClick = { [weak self] in self?.onCancel?() }
        labelField.setSpokenLabel("Label"); userField.setSpokenLabel("Username"); groupField.setSpokenLabel("Group"); descField.setSpokenLabel("Description"); secureField.setSpokenLabel("Secret")
        syncKind()
    }
    required init?(coder: NSCoder) { fatalError() }

    var kind: String { kindPopup.selectedItem?.representedObject as? String ?? "password" }
    private var usesKeyBox: Bool { opts.showValue && kind == "key" }
    @objc private func kindChanged() { syncKind(); needsLayout = true; (superview as? CredGroupView)?.needsLayout = true; enclosingScrollView?.documentView?.needsLayout = true }
    private func syncKind() {
        boxes["kind"]?.isHidden = !opts.showKind
        boxes["group"]?.isHidden = !opts.showExtras; boxes["desc"]?.isHidden = !opts.showExtras
        boxes["secret"]?.isHidden = !opts.showValue || usesKeyBox
        keyFrame.isHidden = !usesKeyBox
    }

    var values: Values {
        Values(label: labelField.stringValue, username: userField.stringValue, kind: opts.showKind ? kind : "key", group: groupField.stringValue, description: descField.stringValue,
               value: usesKeyBox ? keyText.string : secureField.stringValue)
    }
    /// Empties the secret fields (the value lives only in the buffer from here on).
    func clearSecret() { secureField.stringValue = ""; keyText.string = "" }
    func showError(_ t: String) { error.stringValue = t; error.isHidden = t.isEmpty; needsLayout = true; (superview as? CredGroupView)?.needsLayout = true; enclosingScrollView?.documentView?.needsLayout = true }
    private func submit() { if let e = onSave?(values) { showError(e) } }
    func focusFirst() { window?.makeFirstResponder(labelField) }
    func setValue(_ id: String, _ v: String) {
        switch id {
        case "label": labelField.stringValue = v
        case "user": userField.stringValue = v
        case "group": groupField.stringValue = v
        case "desc": descField.stringValue = v
        case "secret": secureField.stringValue = v; keyText.string = v
        case "kind": if let i = kindPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == v }) { kindPopup.selectItem(at: i); syncKind() }
        default: break
        }
    }
    func submitForTest() { submit() }
    func cancelForTest() { onCancel?() }

    func height(for width: CGFloat) -> CGFloat {
        let p = Self.pad, g = Self.gap
        var h = p + 20 + g + Self.fieldH                       // title, label/username
        if opts.showKind || opts.showValue { h += g + (usesKeyBox ? (opts.showKind ? Self.fieldH + g : 0) + Self.keyH : Self.fieldH) }
        if opts.showExtras { h += g + Self.fieldH + g + Self.fieldH }   // group, description
        if !error.isHidden { h += g + ceil(error.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 2 * p, height: .greatestFiniteMagnitude)).height) }
        return h + g + 32 + p                                  // buttons
    }

    @discardableResult
    func fit(width: CGFloat) -> CGFloat {
        let p = Self.pad, g = Self.gap, inner = width - 2 * p, half = (inner - g) / 2
        var y = p
        titleLabel.frame = NSRect(x: p, y: y, width: inner, height: 20); y += 20 + g
        boxes["label"]?.frame = NSRect(x: p, y: y, width: half, height: Self.fieldH)
        boxes["user"]?.frame = NSRect(x: p + half + g, y: y, width: half, height: Self.fieldH); y += Self.fieldH + g
        if opts.showKind || opts.showValue {
            let kindW = opts.showKind ? half : 0
            if opts.showKind { boxes["kind"]?.frame = NSRect(x: p, y: y, width: half, height: Self.fieldH) }
            let vx = opts.showKind ? p + half + g : p, vw = opts.showKind ? half : inner
            _ = kindW
            if usesKeyBox {
                // a key is long: its box takes the full width on its own row below the kind
                if opts.showKind { y += Self.fieldH + g }
                keyFrame.frame = NSRect(x: p, y: y, width: inner, height: Self.keyH)
                keyScroll.frame = keyFrame.bounds.insetBy(dx: 8, dy: 6)
                y += Self.keyH + g
            } else {
                boxes["secret"]?.frame = NSRect(x: vx, y: y, width: vw, height: Self.fieldH); y += Self.fieldH + g
            }
        }
        if opts.showExtras {
            boxes["group"]?.frame = NSRect(x: p, y: y, width: inner, height: Self.fieldH); y += Self.fieldH + g
            boxes["desc"]?.frame = NSRect(x: p, y: y, width: inner, height: Self.fieldH); y += Self.fieldH + g
        }
        if !error.isHidden {
            let eh = ceil(error.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: .greatestFiniteMagnitude)).height)
            error.frame = NSRect(x: p, y: y, width: inner, height: eh); y += eh + g
        }
        let sw = save.intrinsicContentSize.width, cw = cancel.intrinsicContentSize.width
        save.translatesAutoresizingMaskIntoConstraints = true; cancel.translatesAutoresizingMaskIntoConstraints = true
        save.frame = NSRect(x: width - p - sw, y: y, width: sw, height: 32)
        cancel.frame = NSRect(x: width - p - sw - g - cw, y: y, width: cw, height: 32)
        let h = y + 32 + p
        frame.size = NSSize(width: width, height: h)
        return h
    }
}

/// The Password Store calls the same card by its old name.
typealias CredGroupView = GroupCardView
