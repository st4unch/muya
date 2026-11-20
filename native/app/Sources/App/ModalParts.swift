// Small parts shared by the restyled Settings, Schedules and SSH views (WP8) that the Theme kit does not have:
// a one-pixel rule, the bordered box around an input or pop-up (modalKit inputStyle: --bg-input, 1px --border-control,
// radius 7, 32px), a header/footer bar and a flipped document view. All of them paint from tokens in draw(_:), so a
// theme change repaints them without timers.
import AppKit

/// A 1px rule in --border (row separators, header/footer edges).
final class ModalRule: NSView {
    var token: Theme.Token
    init(_ token: Theme.Token = .border) {
        self.token = token
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Theme.dynamic(token).setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
/// The input look of modalKit: --bg-input, 1px --border-control, radius 7, 32px high. Holds one control (text field or
/// pop-up) drawn without its own bezel.
final class FieldBox: NSView {
    let inner: NSControl
    var fixedWidth: CGFloat?
    init(_ inner: NSControl, width: CGFloat? = nil, height: CGFloat = 32) {
        self.inner = inner; fixedWidth = width
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            inner.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
        if let width { widthAnchor.constraint(equalToConstant: width).isActive = true }
        for n in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(editingChanged), name: n, object: inner)
        }
        if let tf = inner as? NSTextField {
            if let ph = tf.placeholderString {
                tf.placeholderAttributedString = NSAttributedString(string: ph, attributes: [.font: tf.font ?? ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.textFaint)])
            }
            tf.isBordered = false; tf.drawsBackground = false; tf.focusRingType = .none
            tf.font = ThemeFont.sans(13); tf.textColor = Theme.dynamic(.text)
            tf.cell?.usesSingleLineMode = true
        }
        if let pop = inner as? NSPopUpButton {
            pop.isBordered = false; pop.font = ThemeFont.sans(13); pop.focusRingType = .none
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    @objc private func editingChanged() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        Theme.dynamic(.bgInput).setFill(); path.fill()
        let focused = (inner as? NSTextField)?.currentEditor() != nil
        Theme.dynamic(focused ? .accent : .borderControl).setStroke(); path.lineWidth = focused ? 2 : 1; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A themed multi-row block: rows (any views) separated by 1px rules inside a rows box (radius 10, --border).
enum ModalLayout {
    /// Vertical stack of `rows` with rules between them, framed by a ThemedBox(.rows). Each row gets `inset` padding.
    static func rowsBox(_ rows: [NSView], inset: NSEdgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)) -> ThemedBox {
        let box = ThemedBox(.rows)
        box.translatesAutoresizingMaskIntoConstraints = false
        var previous: NSView?
        for (i, r) in rows.enumerated() {
            r.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(r)
            var cs = [
                r.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset.left),
                r.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset.right),
            ]
            if let previous {
                let rule = ModalRule()
                box.addSubview(rule)
                cs += [rule.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: inset.bottom),
                       rule.leadingAnchor.constraint(equalTo: box.leadingAnchor), rule.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                       r.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: inset.top)]
            } else { cs.append(r.topAnchor.constraint(equalTo: box.topAnchor, constant: inset.top)) }
            if i == rows.count - 1 { cs.append(r.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset.bottom)) }
            NSLayoutConstraint.activate(cs)
            previous = r
        }
        return box
    }

    /// Title + helper on the left, `control` on the right: the Settings row (bold 13 title, 12 helper, control top-right).
    static func settingRow(title: String, helper: String?, control: NSView, controlBelow: Bool = false) -> NSView {
        let t = ThemedText.title(title)
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var texts: [NSView] = [t]
        if let helper, !helper.isEmpty {
            let h = ThemedText.helper(helper)
            h.maximumNumberOfLines = 0; h.preferredMaxLayoutWidth = 360
            h.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            texts.append(h)
        }
        let col = Kit.vstack(texts, spacing: 4)
        col.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        if controlBelow {
            let s = Kit.vstack([col, control], spacing: 10)
            s.alignment = .leading
            return s
        }
        let r = Kit.hstack([col, control], spacing: 16, alignment: .top)
        r.distribution = .fill
        return r
    }
}

/// A document view that lays out from the top (scroll views and stacks read more naturally this way).
final class ModalDocView: NSView { override var isFlipped: Bool { true } }

/// ThemedSegmented with an optional icon in front of each label (Settings > Theme: monitor / sun / moon).
final class IconSegmented: NSControl {
    var options: [String]
    var icons: [ThemeIcon?]
    var selected = 1 { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?
    init(options: [String], icons: [ThemeIcon?] = []) {
        self.options = options; self.icons = icons
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.radioGroup)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityValue() -> Any? { options.indices.contains(selected) ? options[selected] : nil }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }
    private func segment(_ i: Int) -> NSRect {
        let n = CGFloat(options.count), w = (bounds.width - 6 - 2 * (n - 1)) / n
        return NSRect(x: 3 + CGFloat(i) * (w + 2), y: 3, width: w, height: bounds.height - 6)
    }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        Theme.dynamic(.bgSegment).setFill(); track.fill()
        for (i, o) in options.enumerated() {
            let r = segment(i), active = i == selected
            if active { Theme.dynamic(.bgSegmentActive).setFill(); NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill() }
            let color = Theme.dynamic(active ? .text : .textMuted)
            let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(13, active ? .semibold : .medium), .foregroundColor: color]
            let sz = (o as NSString).size(withAttributes: a)
            let icon = icons.indices.contains(i) ? icons[i] : nil
            let iw: CGFloat = icon != nil ? 22 : 0
            var x = r.midX - (sz.width + iw) / 2
            if let icon, let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState(); ctx.translateBy(x: x, y: r.midY - 7)
                ThemeIcons.draw(icon, in: ctx, size: 14, color: color); ctx.restoreGState(); x += iw
            }
            (o as NSString).draw(at: NSPoint(x: x, y: r.midY - sz.height / 2), withAttributes: a)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = options.indices.first(where: { segment($0).contains(p) }), i != selected { selected = i; onChange?(i); sendAction(action, to: target) }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The dimming layer behind a modal (today's overlay is black at 50 %): a borderless window over the host window.
final class ModalScrim {
    private let window: NSWindow
    private final class Catcher: NSView {
        var onClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) { onClick?() }
    }
    /// Toast cards (they sit above a dialog in today's app, z-index) lifted out of the dimmed window into small panels above the scrim.
    private var lifted: [(view: NSView, panel: NSPanel, top: CGFloat, trailing: CGFloat)] = []
    private weak var host: NSWindow?
    private weak var liftParent: NSWindow?
    private var observers: [NSObjectProtocol] = []
    init(over host: NSWindow, alpha: CGFloat = 0.5, onClick: @escaping () -> Void) {
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor.black.withAlphaComponent(alpha)
        window.isOpaque = false; window.hasShadow = false; window.isReleasedWhenClosed = false
        let c = Catcher(); c.onClick = onClick
        window.contentView = c
        window.setAccessibilityElement(false)
        host.addChildWindow(window, ordered: .above)
        self.host = host
        liftParent = window
        liftToasts(from: host)
        if !lifted.isEmpty { watchVisibility(host); if !NSApp.isActive { hideLifted() } }
    }

    fileprivate func hideLifted() { for l in lifted { l.panel.parent?.removeChildWindow(l.panel); l.panel.orderOut(nil) } }
    fileprivate func showLifted() { for l in lifted where l.panel.parent == nil { (liftParent ?? window).addChildWindow(l.panel, ordered: .above) } }

    /// The lifted panels follow the app: hidden while another app is in front or the Muya window is minimized, back afterwards.
    private func watchVisibility(_ host: NSWindow) {
        let nc = NotificationCenter.default
        func show(_ on: Bool) { if on { self.showLifted() } else { self.hideLifted() } }
        observers = [
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in show(false) },
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in show(true) },
            nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: host, queue: .main) { _ in show(false) },
            nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: host, queue: .main) { _ in show(true) },
        ]
    }
    var windowNumber: Int { window.windowNumber }
    func attach(_ top: NSWindow) { window.addChildWindow(top, ordered: .above); guard NSApp.isActive else { return }; for l in lifted { window.removeChildWindow(l.panel); window.addChildWindow(l.panel, ordered: .above) } }

    /// Puts the lifted toasts above `top` (a sheet is ordered by AppKit, not through attach()).
    func raiseToasts(above top: NSWindow) {
        liftParent = top
        func go() { for l in lifted { l.panel.parent?.removeChildWindow(l.panel); top.addChildWindow(l.panel, ordered: .above) } }
        if NSApp.isActive { go(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if NSApp.isActive { go() } else { self?.hideLifted() } } }   // the sheet is on screen only after its animation starts
    }

    /// Off for window-id captures (screencapture -l leaves child panels out); the debug command `toast-lift off` sets it.
    nonisolated(unsafe) static var liftsToasts = true
    private func liftToasts(from host: NSWindow) {
        guard Self.liftsToasts, let root = host.contentView else { return }
        for v in root.subviews where v is ToastCard || v is AutoAllowToast {
            let size = v.fittingSize
            guard size.width > 0, size.height > 0 else { continue }
            let top = root.isFlipped ? v.frame.minY : root.bounds.height - v.frame.maxY
            let trailing = root.bounds.width - v.frame.maxX
            let onScreen = host.convertToScreen(root.convert(v.frame, to: nil))
            let panel = NSPanel(contentRect: NSRect(origin: onScreen.origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.identifier = NSUserInterfaceItemIdentifier("toast-lift")
            panel.hidesOnDeactivate = true   // never floats over another app; no custom level: a child window orders above its parent (and above the sheet it is moved under)
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false; panel.isReleasedWhenClosed = false
            let box = NSView(frame: NSRect(origin: .zero, size: size)); panel.contentView = box
            v.removeFromSuperview()
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
            NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: box.topAnchor), v.leadingAnchor.constraint(equalTo: box.leadingAnchor)])
            window.addChildWindow(panel, ordered: .above)
            lifted.append((v, panel, top, trailing))
        }
    }
    func remove() {
        for l in lifted {
            l.panel.parent?.removeChildWindow(l.panel)
            l.panel.orderOut(nil); l.panel.close()
            if l.view.superview === l.panel.contentView, let root = host?.contentView {   // dismissed while the dialog was open: stays gone
                l.view.removeFromSuperview()
                root.addSubview(l.view, positioned: .above, relativeTo: nil)
                NSLayoutConstraint.activate([l.view.topAnchor.constraint(equalTo: root.topAnchor, constant: l.top), l.view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -l.trailing)])
            }
        }
        lifted = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        for c in window.childWindows ?? [] { window.removeChildWindow(c) }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }
}

// MARK: - Icons that are not in the Theme kit (lucide shapes of today's Muya)

enum GlyphIcon {
    case theme(ThemeIcon)
    case paths([String])
    static let play = GlyphIcon.paths(["M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z"])
    static let history = GlyphIcon.paths(["M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8", "M3 3v5h5", "M12 7v5l4 2"])
    static let pencil = GlyphIcon.paths(["M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z", "m15 5 4 4"])
    static let trash = GlyphIcon.paths(["M10 11v6", "M14 11v6", "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6", "M3 6h18", "M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"])
    static let folderOpenPaths = ["m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"]
    static let folderOpen = GlyphIcon.paths(["m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"])
    static let plus = GlyphIcon.theme(.plus)
    static let close = GlyphIcon.paths(["M18 6 6 18", "m6 6 12 12"])
    static let chevronRight = GlyphIcon.paths(["m9 18 6-6-6-6"])
    static let chevronDown = GlyphIcon.paths(["m6 9 6 6 6-6"])
    static let warning = GlyphIcon.paths(["m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3", "M12 9v4", "M12 17h.01"])

    func draw(in ctx: CGContext, size: CGFloat, color: NSColor, stroke: CGFloat = 2) {
        switch self {
        case let .theme(i): ThemeIcons.draw(i, in: ctx, size: size, color: color)
        case let .paths(ps):
            ctx.saveGState(); ctx.scaleBy(x: size / 24, y: size / 24)
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(stroke); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for p in ps { ctx.addPath(SVGPath.parse(p)); ctx.strokePath() }
            ctx.restoreGState()
        }
    }
}

/// A static icon in a token colour.
final class GlyphView: NSView {
    var icon: GlyphIcon { didSet { needsDisplay = true } }
    var token: Theme.Token { didSet { needsDisplay = true } }
    let side: CGFloat
    init(_ icon: GlyphIcon, size: CGFloat = 16, token: Theme.Token = .textMuted) {
        self.icon = icon; self.token = token; side = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        icon.draw(in: ctx, size: side, color: Theme.dynamic(token))
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Small button of the redesigned pages: ghost / primary / danger, 13px, optional icon; `height` 28 for the in-card buttons
/// (modalKit smallGhost), 32 for dialogs. `iconOnly` draws a plain icon with a hover-less 28px hit area (card edit/delete).
final class ModalButton: NSControl {
    var style: ThemedButton.Style { didSet { needsDisplay = true } }
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var icon: GlyphIcon? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onClick: (() -> Void)?
    let height: CGFloat, iconOnly: Bool
    /// Horizontal padding on each side of the label (modalKit ghost button: 12; the compact Settings footer uses less).
    var hpad: CGFloat = 12 { didSet { invalidateIntrinsicContentSize() } }
    private var pressed = false
    init(_ title: String, style: ThemedButton.Style = .ghost, icon: GlyphIcon? = nil, height: CGFloat = 28, iconOnly: Bool = false, label: String? = nil) {
        self.title = title; self.style = style; self.icon = icon; self.height = height; self.iconOnly = iconOnly
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(label ?? title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    private var labelFont: NSFont { ThemeFont.sans(13, style == .primary ? .semibold : .regular) }
    private var fg: NSColor {
        if iconOnly { return Theme.dynamic(.textMuted) }
        return Theme.dynamic(style == .primary ? .primaryFg : style == .danger ? .dangerText : .text)
    }
    override var intrinsicContentSize: NSSize {
        if iconOnly { return NSSize(width: height, height: height) }
        let w = (title as NSString).size(withAttributes: [.font: labelFont]).width
        return NSSize(width: ceil(w) + 2 * hpad + (icon != nil ? 19 : 0), height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.5
        if !iconOnly {
            let fill: NSColor, stroke: NSColor?
            switch style {
            case .ghost: fill = Theme.dynamic(.bgControl); stroke = Theme.dynamic(.borderControl)
            case .primary: fill = Theme.dynamic(.primaryBg); stroke = nil
            case .danger: fill = Theme.dynamic(.dangerBtnBg); stroke = Theme.dynamic(.dangerBorder)
            }
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            fill.withAlphaComponent(alpha).setFill(); path.fill()
            if let stroke { stroke.withAlphaComponent(alpha).setStroke(); path.lineWidth = 1; path.stroke() }
            if pressed { NSColor.black.withAlphaComponent(0.12).setFill(); path.fill() }
        } else if pressed { Theme.dynamic(.bgControl).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
        let color = fg.withAlphaComponent(alpha)
        if iconOnly {
            if let icon, let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState(); ctx.translateBy(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2)
                icon.draw(in: ctx, size: 14, color: color); ctx.restoreGState()
            }
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: color]
        let ts = (title as NSString).size(withAttributes: attrs)
        let iw: CGFloat = icon != nil ? 19 : 0
        var x = (bounds.width - ts.width - iw) / 2
        if let icon, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState(); ctx.translateBy(x: x, y: (bounds.height - 13) / 2)
            icon.draw(in: ctx, size: 13, color: color); ctx.restoreGState(); x += iw
        }
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - ts.height) / 2), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; needsDisplay = true
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            pressed = bounds.contains(convert(e.locationInWindow, from: nil)); needsDisplay = true
            if e.type == .leftMouseUp { break }
        }
        let fire = pressed; pressed = false; needsDisplay = true
        if fire { onClick?(); sendAction(action, to: target) }
    }
    override func keyDown(with event: NSEvent) {
        if isEnabled, event.keyCode == 36 || event.keyCode == 49 { onClick?(); sendAction(action, to: target) } else { super.keyDown(with: event) }
    }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

extension PageView {
    /// The redesigned pages carry their own heading and have no Close button (the rail switches pages): hides the
    /// shared title bar and lets `content` start at the top. Escape still closes (PageView.cancelOperation).
    func useOwnHeading() {
        for v in subviews where v is NSStackView || v is NSBox { v.isHidden = true }
        for c in constraints where (c.firstItem === content && c.firstAttribute == .top) { c.isActive = false }
        content.topAnchor.constraint(equalTo: topAnchor).isActive = true
    }
}

/// Painted input frame (--bg-input, 1px --border-control, radius 7) for content that is not a single control (a text view).
final class InputFrame: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        Theme.dynamic(.bgInput).setFill(); path.fill()
        Theme.dynamic(.borderControl).setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Weekday toggle (30 x 40, radius 7): primary fill when on, like the editor's day buttons.
final class DayToggle: NSButton {
    init(_ title: String, tag: Int) {
        super.init(frame: .zero)
        self.title = title; self.tag = tag
        setButtonType(.pushOnPushOff); isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        Theme.dynamic(on ? .primaryBg : .bgControl).setFill(); path.fill()
        Theme.dynamic(on ? .primaryBg : .borderControl).setStroke(); path.lineWidth = 1; path.stroke()
        let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(12, on ? .semibold : .medium), .foregroundColor: Theme.dynamic(on ? .primaryFg : .textMuted)]
        let sz = (title as NSString).size(withAttributes: a)
        (title as NSString).draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: a)
    }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A dialog laid out like modalKit's ModalShell: header (title, rule), scrolling body, footer (rule, hint left, buttons right).
struct ModalFrame {
    let root: ModalFill
    let body: NSStackView
    static func make(title: String, footerLeft: NSView, footerRight: [NSView], width: CGFloat, height: CGFloat, bodyTop: CGFloat = 20, onClose: (() -> Void)? = nil) -> ModalFrame {
        let root = ModalFill(.bgPanel)
        let t = NSTextField(labelWithString: title)
        t.font = ThemeFont.sans(15, .semibold); t.textColor = Theme.dynamic(.text); t.setAccessibilityRole(.staticText)
        let headRule = ModalRule(), footRule = ModalRule()
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 20
        body.translatesAutoresizingMaskIntoConstraints = false
        let doc = ModalDocView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: doc.topAnchor, constant: bodyTop), body.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
            body.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20), body.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
        ])
        let scroll = Kit.scroll(doc, label: title)
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.scrollerStyle = .overlay
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let right = Kit.hstack(footerRight, spacing: 8)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = Kit.hstack([footerLeft, spacer, right], spacing: 12)
        footer.distribution = .fill
        for v in [t, headRule, scroll, footRule, footer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), t.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            headRule.topAnchor.constraint(equalTo: root.topAnchor, constant: 56),
            headRule.leadingAnchor.constraint(equalTo: root.leadingAnchor), headRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headRule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footRule.topAnchor),
            footRule.leadingAnchor.constraint(equalTo: root.leadingAnchor), footRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footRule.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(equalToConstant: width), root.heightAnchor.constraint(equalToConstant: height),
        ])
        if let onClose {   // the X of ModalShell's header (28 px, no border, --text-muted)
            let x = FindIconButton(.close, label: "Close", tip: "Close")
            x.onClick = onClose
            x.glyphSize = 16; x.side = 28
            root.addSubview(x)
            NSLayoutConstraint.activate([x.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), x.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 28)])
        }
        return ModalFrame(root: root, body: body)
    }
    /// Adds a block that spans the body width.
    func add(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }
    /// label + control (+ helper) like modalKit's Group.
    func group(_ label: String, _ control: NSView, helper: NSView? = nil) -> NSView {
        var views: [NSView] = [ThemedText.label(label), control]
        if let helper { views.append(helper) }
        let s = Kit.vstack(views, spacing: 8)
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
        return s
    }
}

/// The editor sheet: Return (or ⌘Return) saves, Escape cancels, like the web dialog.
final class EditorPanel: NSPanel {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 || event.keyCode == 76 {
            let inPrompt = firstResponder is NSTextView && !event.modifierFlags.contains(.command)
            let onButton = firstResponder is ModalButton
            if !inPrompt && !onButton { onSubmit?(); return true }
            if event.modifierFlags.contains(.command) { onSubmit?(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}


/// Page tabs like today's SSH page: 14px labels, the active one bold with a 2px underline, a rule under all of them.
final class UnderlineTabs: NSControl {
    var titles: [String] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?
    init(_ titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 42).isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.radioGroup)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityValue() -> Any? { titles.indices.contains(selected) ? titles[selected] : nil }
    override var isFlipped: Bool { true }
    private func widths(_ i: Int) -> (x: CGFloat, w: CGFloat) {
        var x: CGFloat = 0
        for (j, t) in titles.enumerated() {
            let w = ceil((t as NSString).size(withAttributes: [.font: ThemeFont.sans(14, .semibold)]).width) + 26
            if j == i { return (x, w) }
            x += w
        }
        return (x, 0)
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.dynamic(.border).setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for (i, t) in titles.enumerated() {
            let (x, w) = widths(i), active = i == selected
            let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(14, active ? .semibold : .regular), .foregroundColor: Theme.dynamic(active ? .text : .textMuted)]
            let sz = (t as NSString).size(withAttributes: a)
            (t as NSString).draw(at: NSPoint(x: x + (w - sz.width) / 2, y: (bounds.height - 2 - sz.height) / 2), withAttributes: a)
            if active { Theme.dynamic(.text).setFill(); NSRect(x: x + 13, y: bounds.height - 2, width: w - 26, height: 2).fill() }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = titles.indices.first(where: { let (x, w) = widths($0); return p.x >= x && p.x < x + w }), i != selected { selected = i; onChange?(i); sendAction(action, to: target) }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

extension ModalButton {
    /// Target / action flavour of the button, a drop-in for the `Kit.button(title, target, action, label:)` calls of the SSH panes.
    static func action(_ title: String, _ target: AnyObject?, _ action: Selector, label: String? = nil, height: CGFloat = 32) -> ModalButton {
        let b = ModalButton(title, height: height, label: label)
        b.target = target; b.action = action
        return b
    }
}

/// A solid token-coloured view with optional 1px hairlines (top / bottom).
final class ModalFill: NSView {
    var fill: Theme.Token { didSet { needsDisplay = true } }
    var top = false, bottom = false
    init(_ fill: Theme.Token) { self.fill = fill; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.dynamic(fill).setFill(); bounds.fill()
        Theme.dynamic(.border).setFill()
        if top { NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
        if bottom { NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true; refreshCardBorder() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshCardBorder() }
    /// A dialog's root view gets a 1 px layer border from its owner; a CGColor does not follow the appearance, so it is
    /// re-resolved here (set once under the wrong appearance it was a bright outline round every dark dialog).
    private func refreshCardBorder() {
        guard let layer, layer.borderWidth > 0 else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance { layer.borderColor = Theme.dynamic(.border).cgColor }
    }
}

