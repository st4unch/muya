// The Servers tab as classic draws it: collapsible group cards holding a grid of server CARDS, each with a Connect
// button and edit / delete icons, and the "PSMP jump-server profiles" card at the bottom of the same tab.
// Sizes are classic's and come from PasswordStoreCards (card radius 10, padding 16, gap 12, icon buttons 28 square).

import AppKit

/// What the Servers tab needs to draw one server card.
struct ServerCardModel {
    var server: SSHServer
    /// The mono line under the name; `ServerCardLine.text` builds it.
    var line: String
}

/// classic's server card: bold label, mono `user@host:port · type · login`, then Connect + edit + delete on the right.
@MainActor
final class ServerCardView: CardBox, FitCard {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let connectButton: ModalButton
    private let editButton: ModalButton, deleteButton: ModalButton
    let model: ServerCardModel
    static let pad: CGFloat = 16, actionSide: CGFloat = 28, actionGap: CGFloat = 4, connectWidth: CGFloat = 78
    static var actionsWidth: CGFloat { connectWidth + 2 * actionGap + 2 * actionSide }

    init(_ m: ServerCardModel, onConnect: @escaping () -> Void, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) {
        model = m
        connectButton = ModalButton("Connect", height: Self.actionSide, label: "Connect to \(m.server.title) in a new terminal")
        func icon(_ i: GlyphIcon, _ label: String, _ go: @escaping () -> Void) -> ModalButton {
            let b = ModalButton("", icon: i, height: Self.actionSide, iconOnly: true, label: label)
            b.toolTip = label; b.onClick = go
            return b
        }
        editButton = icon(.pencil, "Edit server", onEdit)
        deleteButton = icon(.trash, "Delete server", onDelete)
        super.init(frame: .zero)
        connectButton.onClick = onConnect
        connectButton.toolTip = "Connect to \(m.server.title) in a new terminal"
        let s = NSMutableAttributedString(string: m.server.title, attributes: [.font: ThemeFont.sans(14, .medium), .foregroundColor: Theme.dynamic(.text)])
        let p = NSMutableParagraphStyle(); p.paragraphSpacingBefore = 2
        p.lineBreakMode = .byTruncatingTail   // classic keeps this on one line and ends it with an ellipsis
        s.append(NSAttributedString(string: "\n" + m.line, attributes: [.font: ThemeFont.mono(12), .foregroundColor: Theme.dynamic(.textMuted), .paragraphStyle: p]))
        title.attributedStringValue = s
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 2
        title.isSelectable = false
        title.setAccessibilityLabel("\(m.server.title), \(m.line)")
        for v in [title, connectButton, editButton, deleteButton] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func titleWidth(_ width: CGFloat) -> CGFloat { max(40, width - 2 * Self.pad - Self.actionsWidth - 8) }

    private func titleHeight(_ width: CGFloat) -> CGFloat {
        ceil(title.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: titleWidth(width), height: .greatestFiniteMagnitude)).height)
    }

    func height(for width: CGFloat) -> CGFloat { 2 * Self.pad + max(Self.actionSide, titleHeight(width)) }

    /// Lays the card out for `width` and returns its height.
    @discardableResult
    func fit(width: CGFloat) -> CGFloat {
        let p = Self.pad, th = titleHeight(width), hh = max(Self.actionSide, th)
        title.frame = NSRect(x: p, y: p + (hh - th) / 2, width: titleWidth(width), height: th)
        var x = width - p - Self.actionsWidth
        let y = p + (hh - Self.actionSide) / 2
        connectButton.translatesAutoresizingMaskIntoConstraints = true
        connectButton.frame = NSRect(x: x, y: y, width: Self.connectWidth, height: Self.actionSide)
        x += Self.connectWidth + Self.actionGap
        for b in [editButton, deleteButton] {
            b.translatesAutoresizingMaskIntoConstraints = true
            b.frame = NSRect(x: x, y: y, width: Self.actionSide, height: Self.actionSide)
            x += Self.actionSide + Self.actionGap
        }
        let h = 2 * p + hh
        frame.size = NSSize(width: width, height: h)
        return h
    }

    #if MUYA_TEST_HOOKS
    func pressConnect() { connectButton.onClick?() }
    func pressEdit() { editButton.onClick?() }
    func pressDelete() { deleteButton.onClick?() }
    #endif
}

/// classic's "PSMP jump-server profiles" card, at the bottom of the Servers tab (classic has no PSMP tab).
@MainActor
final class PSMPProfilesCard: CardBox, FitCard {
    private let heading = Kit.label("PSMP jump-server profiles", size: 14, color: Theme.dynamic(.text))
    private let addButton: ModalButton
    private let empty = Kit.label("No profiles yet.", size: 12, color: Theme.dynamic(.textFaint))
    private var rows: [(line: NSTextField, edit: ModalButton, delete: ModalButton)] = []
    static let pad: CGFloat = 16, rowHeight: CGFloat = 28, gap: CGFloat = 8, headerHeight: CGFloat = 28

    init(profiles: [PSMPProfile], onAdd: @escaping () -> Void, onEdit: @escaping (PSMPProfile) -> Void, onDelete: @escaping (PSMPProfile) -> Void) {
        addButton = ModalButton("", icon: .plus, height: 28, iconOnly: true, label: "Add PSMP profile")
        super.init(frame: .zero)
        heading.font = ThemeFont.sans(14, .medium)
        addButton.toolTip = "Add PSMP profile"
        addButton.onClick = onAdd
        addSubview(heading); addSubview(addButton)
        for p in profiles {
            let l = Kit.label("\(p.title): \(p.vaultUser)@…@\(p.psmpAddress)", size: 12, color: Theme.dynamic(.textMuted))
            l.font = ThemeFont.mono(12)
            l.lineBreakMode = .byTruncatingTail
            let e = ModalButton("", icon: .pencil, height: 28, iconOnly: true, label: "Edit profile")
            e.toolTip = "Edit profile"; e.onClick = { onEdit(p) }
            let d = ModalButton("", icon: .trash, height: 28, iconOnly: true, label: "Delete profile")
            d.toolTip = "Delete profile"; d.onClick = { onDelete(p) }
            for v in [l, e, d] as [NSView] { addSubview(v) }
            rows.append((l, e, d))
        }
        empty.isHidden = !profiles.isEmpty
        addSubview(empty)
    }
    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat {
        let body = rows.isEmpty ? Self.rowHeight : CGFloat(rows.count) * Self.rowHeight
        return 2 * Self.pad + Self.headerHeight + Self.gap + body
    }

    @discardableResult
    func fit(width: CGFloat) -> CGFloat {
        let p = Self.pad, inner = width - 2 * p
        heading.frame = NSRect(x: p, y: p, width: max(40, inner - 28 - 8), height: Self.headerHeight)
        addButton.translatesAutoresizingMaskIntoConstraints = true
        addButton.frame = NSRect(x: width - p - 28, y: p, width: 28, height: 28)
        var y = p + Self.headerHeight + Self.gap
        empty.frame = NSRect(x: p, y: y, width: inner, height: Self.rowHeight)
        for r in rows {
            let actions: CGFloat = 2 * 28 + 4
            r.line.frame = NSRect(x: p, y: y + 5, width: max(40, inner - actions - 8), height: 18)
            var x = width - p - actions
            for b in [r.edit, r.delete] {
                b.translatesAutoresizingMaskIntoConstraints = true
                b.frame = NSRect(x: x, y: y, width: 28, height: 28)
                x += 32
            }
            y += Self.rowHeight
        }
        let h = height(for: width)
        frame.size = NSSize(width: width, height: h)
        return h
    }
}

/// The scrolling document of the Servers tab: the group cards, then the PSMP profiles card, 12 apart.
@MainActor
final class ServerCardsDocument: NSView {
    override var isFlipped: Bool { true }
    private(set) var groups: [GroupCardView] = []
    private(set) var psmp: PSMPProfilesCard?
    /// The page's own side margins, so the column breakpoints see the page width as classic does.
    var pageWidthExtra: CGFloat = 48

    func set(_ g: [GroupCardView], psmp card: PSMPProfilesCard?) {
        groups.forEach { $0.removeFromSuperview() }
        psmp?.removeFromSuperview()
        groups = g; psmp = card
        g.forEach(addSubview)
        if let card { addSubview(card) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        let w = bounds.width, cols = CredGroup.columns(pageWidth: w + pageWidthExtra)
        for g in groups {
            let h = g.fit(width: w, columns: cols)
            g.frame = NSRect(x: 0, y: y, width: w, height: h)
            y += h + 12
        }
        if let card = psmp {
            let h = card.fit(width: w)
            card.frame = NSRect(x: 0, y: y, width: w, height: h)
            y += h + 12
        }
        let total = max(0, y - (groups.isEmpty && psmp == nil ? 0 : 12))
        if abs(frame.height - total) > 0.5 { setFrameSize(NSSize(width: w, height: max(total, enclosingScrollView?.contentSize.height ?? 0))) }
    }
}
