// Side-by-side diff (classic's Monaco DiffEditor with renderSideBySide): HEAD on the left, the buffer on the right, rows
// aligned (a changed block is padded on the shorter side), unchanged runs folded, vertical scrolling kept in step.
// Narrow panes get the unified view instead (Monaco's own "inline view when space is limited").

import AppKit

final class DiffPane: NSView {
    static let minWidth: CGFloat = 700
    private let leftScroll = NSScrollView(), rightScroll = NSScrollView()
    private let leftText = NSTextView(), rightText = NSTextView()
    private let divider = NSBox()
    private var syncing = false
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (scroll, text) in [(leftScroll, leftText), (rightScroll, rightText)] {
            text.isEditable = false; text.isSelectable = true; text.isRichText = true
            text.backgroundColor = MonacoPalette.background; text.drawsBackground = true
            text.textContainerInset = NSSize(width: 4, height: 4)
            text.isHorizontallyResizable = true; text.isVerticallyResizable = true
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.size = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
            scroll.documentView = text
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = true; scroll.backgroundColor = MonacoPalette.background
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.translatesAutoresizingMaskIntoConstraints = false
            addSubview(scroll)
        }
        leftText.setAccessibilityLabel("HEAD version"); rightText.setAccessibilityLabel("Working copy")
        divider.boxType = .separator; divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            leftScroll.topAnchor.constraint(equalTo: topAnchor), leftScroll.bottomAnchor.constraint(equalTo: bottomAnchor), leftScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            rightScroll.topAnchor.constraint(equalTo: topAnchor), rightScroll.bottomAnchor.constraint(equalTo: bottomAnchor), rightScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            leftScroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor), rightScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor), divider.bottomAnchor.constraint(equalTo: bottomAnchor), divider.centerXAnchor.constraint(equalTo: centerXAnchor),
            leftScroll.widthAnchor.constraint(equalTo: rightScroll.widthAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
        ])
        for (a, b) in [(leftScroll, rightScroll), (rightScroll, leftScroll)] {
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: a.contentView, queue: .main) { [weak self, weak b, weak a] _ in
                guard let self, let a, let b, !self.syncing else { return }
                self.syncing = true
                b.contentView.scroll(to: NSPoint(x: b.contentView.bounds.origin.x, y: a.contentView.bounds.origin.y)); b.reflectScrolledClipView(b.contentView)
                self.syncing = false
            })
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    struct Cell { var text: String?; var line: Int?; var kind: DiffRowKind }

    /// Aligns the rows into left / right cells of equal count.
    static func align(_ rows: [DiffRow]) -> (left: [Cell], right: [Cell]) {
        var l: [Cell] = [], r: [Cell] = []
        var i = 0
        while i < rows.count {
            let row = rows[i]
            switch row.kind {
            case .same: l.append(Cell(text: row.text, line: row.oldLine, kind: .same)); r.append(Cell(text: row.text, line: row.newLine, kind: .same)); i += 1
            case .fold: l.append(Cell(text: row.text, line: nil, kind: .fold)); r.append(Cell(text: row.text, line: nil, kind: .fold)); i += 1
            case .removed, .added:
                var rem: [DiffRow] = [], add: [DiffRow] = []
                while i < rows.count, rows[i].kind == .removed || rows[i].kind == .added { if rows[i].kind == .removed { rem.append(rows[i]) } else { add.append(rows[i]) }; i += 1 }
                for k in 0 ..< max(rem.count, add.count) {
                    l.append(k < rem.count ? Cell(text: rem[k].text, line: rem[k].oldLine, kind: .removed) : Cell(text: nil, line: nil, kind: .same))
                    r.append(k < add.count ? Cell(text: add[k].text, line: add[k].newLine, kind: .added) : Cell(text: nil, line: nil, kind: .same))
                }
            }
        }
        return (l, r)
    }

    private func attributed(_ cells: [Cell]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = ThemeFont.mono(12), faint = ThemeFont.mono(11)
        for c in cells {
            switch c.kind {
            case .fold:
                out.append(NSAttributedString(string: "      ⋯ \(c.text ?? "")\n", attributes: [.font: faint, .foregroundColor: Theme.dynamic(.textMuted), .backgroundColor: Theme.dynamic(.bgControl)]))
            default:
                let bg: NSColor? = c.text == nil ? Theme.dynamic(.bgControl).withAlphaComponent(0.6) : c.kind == .added ? MonacoPalette.added : c.kind == .removed ? MonacoPalette.removed : nil
                var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: MonacoPalette.foreground]
                if let bg { a[.backgroundColor] = bg }
                var g = a; g[.foregroundColor] = MonacoPalette.gutter
                let num = c.line.map { String($0) } ?? ""
                out.append(NSAttributedString(string: String(repeating: " ", count: max(0, 5 - num.count)) + num + "  ", attributes: g))
                out.append(NSAttributedString(string: (c.text ?? "") + "\n", attributes: a))
            }
        }
        return out
    }

    func show(rows: [DiffRow]) {
        let (l, r) = DiffPane.align(rows)
        leftText.textStorage?.setAttributedString(attributed(l))
        rightText.textStorage?.setAttributedString(attributed(r))
        layoutSubtreeIfNeeded()
        for (scroll, text) in [(leftScroll, leftText), (rightScroll, rightText)] {
            text.frame = NSRect(x: 0, y: 0, width: max(scroll.contentSize.width, 100), height: max(scroll.contentSize.height, 100))
            text.sizeToFit()
        }
        leftScroll.contentView.scroll(to: .zero); rightScroll.contentView.scroll(to: .zero)
    }

    var debugFrames: String { "pane=\(frame) leftScroll=\(leftScroll.frame) leftText=\(leftText.frame) rightScroll=\(rightScroll.frame) rightText=\(rightText.frame) hidden=\(isHidden) len=\(leftText.string.count)" }
    var leftString: String { leftText.string }
    var rightString: String { rightText.string }
}
