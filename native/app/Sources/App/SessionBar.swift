// WP2 — session header (src/redesign/SessionHeader.tsx): name (17/600), status pill, "Claude Code · folder · branch", and the
// buttons Command (opens the Command dialog: text or a slash command to one or many sessions) / Split (needs split panes: disabled here) / Split to grid /
// Stop (always shown, sends Esc, which interrupts Claude) / More.

import AppKit

final class SessionBar: FillView {
    private let name = FrameText("", font: ThemeFont.sans(17, .semibold), color: .text)
    private let sub = FrameText("", font: ThemeFont.mono(12), color: .textMuted)
    private let kindLabel = FrameText("", font: ThemeFont.sans(12), color: .textSecondary)   // "Claude Code ·"
    private let kindIcon = ThemeIconView(icon: .terminalKind, color: Theme.dynamic(.accent), size: 12)
    private var pill: ThemedPill?
    private let bypass = ThemeIconView(icon: .bypassWarning, color: Theme.dynamic(.dangerText), size: 14)   // bypass-permissions mode
    let commandButton = ThemedButton("Command", icon: .command)
    let splitButton = ThemedButton("Split", icon: .splitPane)
    let gridButton = ThemedButton("Split to grid", icon: .gridSplit)
    let stopButton = ThemedButton("Stop", style: .danger)
    let broadcastButton = ThemedButton("Broadcast to all…")   // grid mode
    let moreButton = FrameIconButton(.more, label: "More actions")
    var onBroadcast: (() -> Void)?
    var onMore: ((NSView) -> Void)?
    private var heightC: NSLayoutConstraint!
    var onGrid: (() -> Void)?
    var onCommand: (() -> Void)?
    var onSplit: (() -> Void)?
    /// At the pane limit (8) the button stays but is disabled, like today's.
    func setSplitEnabled(_ on: Bool) {
        guard splitButton.isEnabled != on else { return }
        splitButton.isEnabled = on; splitButton.alphaValue = on ? 1 : 0.45; splitButton.toolTip = on ? "Split (⌘⇧D)" : "Up to 8 panes"
    }
    var onStop: (() -> Void)?
    static let height: CGFloat = 66, collapsedHeight: CGFloat = 40
    /// Today's collapsed session header (SessionHeader.tsx CollapseToggle, `muya.sessionHeaderCollapsed`): one slim row — chevron, name, pill,
    /// icon-only Command / Split / Split to grid / Stop. The toggle sits left of the name in both states.
    let collapseToggle = CollapseToggle()
    var onToggleCollapse: ((Bool) -> Void)?
    var collapsed = false {
        didSet {
            guard collapsed != oldValue else { return }
            collapseToggle.collapsed = collapsed
            // Set once per state change, not on every layout (alpha / font writes on every session switch cost frames; AC8 regression of 2479991).
            name.font = collapsed ? ThemeFont.sans(13, .semibold) : ThemeFont.sans(17, .semibold)
            let a: CGFloat = collapsed ? 0 : 1
            kindIcon.alphaValue = a; kindLabel.alphaValue = a; sub.alphaValue = a; moreButton.alphaValue = a
            sig = ""; heightC.constant = isHidden ? 0 : currentHeight; needsLayout = true
            applyIconButtons()
        }
    }
    /// Icon-only buttons: the collapsed header always, the full header when the pane is too narrow for title + buttons (Tauri collapses them too).
    private var narrow = false
    private var fullButtonsWidth: CGFloat = 0
    private func applyIconButtons() {
        let on = collapsed || narrow
        guard commandButton.iconOnly != on else { return }
        for b in [commandButton, splitButton, gridButton, stopButton] { b.iconOnly = on }
        stopButton.icon = on ? .stop : nil
    }
    private var currentHeight: CGFloat { collapsed ? Self.collapsedHeight : Self.height }

    init() {
        super.init(.bgApp)
        bottom = true
        translatesAutoresizingMaskIntoConstraints = false
        heightC = heightAnchor.constraint(equalToConstant: Self.height); heightC.isActive = true
        [collapseToggle, name, sub, kindLabel, kindIcon, bypass, commandButton, splitButton, gridButton, stopButton, broadcastButton, moreButton].forEach(addSubview)
        stopButton.hint = "esc"   // "Stop esc" like today's button
        stopButton.icon = nil
        collapseToggle.onClick = { [weak self] in guard let self else { return }; self.collapsed.toggle(); self.onToggleCollapse?(self.collapsed) }
        // Split needs split panes, which the native app does not have yet: shown like today's disabled "at the pane limit" button.
        splitButton.toolTip = "Split (⌘⇧D)"; splitButton.onClick = { [weak self] in self?.onSplit?() }
        commandButton.onClick = { [weak self] in self?.onCommand?() }
        bypass.isHidden = true; broadcastButton.isHidden = true
        broadcastButton.onClick = { [weak self] in self?.onBroadcast?() }
        moreButton.onClick = { [weak self] in if let m = self?.moreButton { self?.onMore?(m) } }
        gridButton.onClick = { [weak self] in self?.onGrid?() }
        stopButton.onClick = { [weak self] in self?.onStop?() }
        setAccessibilityRole(.group); setAccessibilityLabel("Session header")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Grid mode: "Grid · N panels" and an Exit grid button instead of the session's own header.
    func configureGrid(panels: Int) {
        sig = "grid\(panels)"
        name.text = "Grid"; sub.text = "\(panels) panel\(panels == 1 ? "" : "s") · ⌥⌘G exits"; kindLabel.text = ""; kindIcon.isHidden = true
        commandButton.isHidden = true; splitButton.isHidden = true
        pill?.removeFromSuperview(); pill = nil; bypass.isHidden = true
        gridButton.title = "Exit grid"; stopButton.isHidden = true; broadcastButton.isHidden = false; moreButton.isHidden = true
        needsLayout = true
    }

    func setShown(_ on: Bool) { heightC.constant = on ? currentHeight : 0; isHidden = !on }

    private var sig = ""
    func configure(_ s: SessionModel?, home: String) {
        let n = "\(s?.id ?? 0)|\(s?.name ?? "")|\(s?.cwd ?? "")|\(s?.state.text ?? "")|\(s?.elapsed ?? "")|\(s?.screen?.mode ?? "")|\(s?.kind ?? "")|\(s?.openedBy ?? "")|\(s?.exited != nil)"
        guard n != sig else { return }; sig = n
        gridButton.title = "Split to grid"; broadcastButton.isHidden = true; moreButton.isHidden = false
        commandButton.isHidden = false; splitButton.isHidden = false
        guard let s else { name.text = ""; sub.text = ""; kindLabel.text = ""; pill?.removeFromSuperview(); pill = nil; return }
        name.text = s.name
        let isClaude = s.screen?.modeDetected == true || s.kind == "claude"
        let branch = AgentsLogic.branch(of: s.cwd)
        kindLabel.text = s.kind == "opencode" ? "opencode ·" : isClaude ? "Claude Code ·" : "Terminal ·"
        kindIcon.isHidden = false
        (kindIcon.icon, kindIcon.color) = s.kindIconChoice; kindIcon.toolTip = s.openedByTooltip
        sub.text = s.cwd.abbreviatingHome(home) + (branch.isEmpty || branch == "—" ? "" : " · " + branch)
        commandButton.isEnabled = true; commandButton.alphaValue = 1   // any tab can open it: "All sessions" and "Pick sessions" do not need this tab to be an agent
        commandButton.toolTip = "Send a command or message to sessions (⌘⇧K)"
        bypass.isHidden = !(s.exited == nil && s.screen?.mode.lowercased().contains("bypass") == true)
        var st = s.state
        if let e = s.elapsed, s.exited == nil { st.text = (s.screen?.permission == true ? "Waiting" : "Working") + " · " + e }
        pill?.removeFromSuperview()
        let busy = s.exited == nil && (s.screen?.busy == true || s.screen?.activity != nil)
        let waiting = s.exited == nil && s.screen?.permission == true
        let p: ThemedPill
        if waiting { p = ThemedPill(st.text, fg: Theme.dynamic(.warningText), bg: Theme.dynamic(.warningBg), border: Theme.dynamic(.warningBorder), dot: Theme.dynamic(.warning)) }
        else if busy { p = ThemedPill(st.text, fg: Theme.dynamic(.successText), bg: Theme.dynamic(.successBg), dot: Theme.dynamic(.success)) }
        else if s.exited != nil { p = ThemedPill(st.text, fg: Theme.dynamic(.dangerText), bg: Theme.dynamic(.dangerPillBg)) }
        else { p = ThemedPill(st.text, fg: Theme.dynamic(.textMuted), bg: Theme.dynamic(.bgSegment)) }
        addSubview(p); pill = p
        stopButton.isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Decide icon-only first: the title area wants about 260 pt next to the button group. Measured while the buttons are full
        // (and kept), so the decision does not flip back and forth with the width of the icons.
        let inGrid = !broadcastButton.isHidden
        if !inGrid, !collapsed {
            if !commandButton.iconOnly {
                var w: CGFloat = 20 + (moreButton.isHidden ? 0 : 44)
                for b in [stopButton, gridButton, splitButton, commandButton] where !b.isHidden { w += b.intrinsicContentSize.width + 12 }
                fullButtonsWidth = w
            }
            let shouldNarrow = fullButtonsWidth > 0 && bounds.width - fullButtonsWidth < 300
            if shouldNarrow != narrow { narrow = shouldNarrow; applyIconButtons() }
        } else if narrow { narrow = false; applyIconButtons() }
        let c = collapsed
        // The buttons are right-aligned and keep their size; everything on the left gives way to them.
        var x = bounds.width - (c ? 16 : 20)
        let h: CGFloat = c ? 28 : 32, y = (bounds.height - h) / 2
        let icons = c || narrow
        if !moreButton.isHidden, !c { x -= 32; moreButton.frame = NSRect(x: x, y: y, width: 32, height: 32); x -= icons ? 4 : 12 }
        for b in [stopButton, gridButton, splitButton, commandButton, broadcastButton] where !b.isHidden {
            let w = icons && b !== broadcastButton ? 30 : b.intrinsicContentSize.width; x -= w
            b.frame = NSRect(x: x, y: y, width: w, height: h); x -= icons ? 4 : 12
        }
        let limit = x + (icons ? 4 : 12) - 14   // the free width on the left ends here
        collapseToggle.frame = NSRect(x: 14, y: c ? 9 : 13, width: 22, height: 22)
        let nx: CGFloat = 42
        let pillW = pill?.intrinsicContentSize.width ?? 0
        let nameWant = name.intrinsicContentSize.width
        // The name keeps priority; the pill only shows when name and pill both fit.
        let pillFits = pill != nil && nx + nameWant + 10 + pillW <= limit
        let nameW = max(0, min(nameWant, limit - nx - (pillFits ? pillW + 10 : 0)))
        name.frame = NSRect(x: nx, y: c ? 7 : 11, width: nameW, height: 26)
        pill?.isHidden = !pillFits
        pill?.frame = NSRect(x: name.frame.maxX + 10, y: c ? 9 : 13, width: pillW, height: 22)
        bypass.frame = NSRect(x: (pillFits ? pill!.frame.maxX : name.frame.maxX) + 8, y: c ? 13 : 17, width: 14, height: 14)
        var sx: CGFloat = nx
        if !c, !kindIcon.isHidden { kindIcon.frame = NSRect(x: sx, y: 42, width: 12, height: 12); sx += 18 }
        if !c, !kindLabel.text.isEmpty { let w = min(kindLabel.intrinsicContentSize.width, max(0, limit - sx)); kindLabel.frame = NSRect(x: sx, y: 39, width: w, height: 18); sx += w + 6 }
        sub.frame = NSRect(x: sx, y: 39, width: max(0, limit - sx), height: 18)
    }
}

/// The chevron left of the session name (SessionHeader.tsx CollapseToggle: 22x22, --text-muted, rotated -90° when collapsed).
final class CollapseToggle: NSControl {
    var collapsed = false { didSet { needsDisplay = true; toolTip = collapsed ? "Expand session header" : "Collapse session header"; setAccessibilityLabel(toolTip) } }
    var onClick: (() -> Void)?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        toolTip = "Collapse session header"; setAccessibilityRole(.button); setAccessibilityLabel(toolTip)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState(); ctx.translateBy(x: bounds.midX, y: bounds.midY)
        if collapsed { ctx.rotate(by: -.pi / 2) }
        ctx.translateBy(x: -7, y: -7)
        ThemeIcons.draw(.chevronDown, in: ctx, size: 14, color: Theme.dynamic(.textMuted)); ctx.restoreGState()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
