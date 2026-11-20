// WP2 — the agents panel of today's Muya (src/redesign/AgentList.tsx): "Agents N" + black "+ New agent" pill, a segmented
// filter, groups WAITING FOR YOU / WORKING / IDLE with one card per session (state dot, kind icon, name, status line,
// folder). Cards are drawn views; the list is rebuilt only when what it shows changed (event-driven, no timers).

import AppKit

/// The outline a row shows while something is dragged over it (AgentList.tsx dropStyle): dashed = reorder, solid + selected fill = group.
enum DropOutline {
    static func draw(_ mode: SplitLogic.DropMode, in r: NSRect, radius: CGFloat) {
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        p.lineWidth = 2
        if mode == .group { Theme.dynamic(.bgSelected).setFill(); p.fill() } else { p.setLineDash([4, 3], count: 2, phase: 0) }
        Theme.dynamic(.accent).setStroke(); p.stroke()
    }
}

final class AgentCard: NSView, NSDraggingSource {
    enum Group { case waiting, working, idle }
    let session: SessionModel
    let group: Group
    var selected: Bool { didSet { if selected != oldValue { needsDisplay = true } } }
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onMenu: ((NSEvent, NSView) -> Void)?
    /// Another session was dropped on this card: its middle half groups the two into a split, its top and bottom quarter reorder (AgentList.tsx dropModeAt).
    var onDropSession: ((UInt64, SplitLogic.DropMode) -> Void)?
    private var dropOver: SplitLogic.DropMode? { didSet { if dropOver != oldValue { needsDisplay = true } } }
    private var downAt: NSPoint?
    nonisolated static let dragType = NSPasteboard.PasteboardType("com.staunch.muya.session-id")
    private let home: String
    var pinned = false

    init(session: SessionModel, group: Group, selected: Bool, home: String) {
        self.session = session; self.group = group; self.selected = selected; self.home = home
        super.init(frame: .zero)
        setAccessibilityRole(.button); setAccessibilityLabel("\(session.name), \(session.state.text)")
        registerForDraggedTypes([Self.dragType])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var closeRect: NSRect { NSRect(x: bounds.width - 28, y: 10, width: 18, height: 18) }
    private var statusText: String {
        if let l = session.statusLine { return l }
        if session.exited != nil || session.screen == nil { return session.state.text == "Shell" ? "Idle" : session.state.text }
        return session.state.text
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        if group == .waiting { Theme.dynamic(.warningCardBg).setFill(); p.fill(); Theme.dynamic(.warningBorder).setStroke(); p.stroke() }
        else if selected { Theme.dynamic(.bgSelected).setFill(); p.fill(); Theme.dynamic(.borderSelected).setStroke(); p.stroke() }
        if let m = dropOver { DropOutline.draw(m, in: r, radius: 9) }
        let st = session.state
        st.color.setFill(); NSBezierPath(ovalIn: NSRect(x: 14, y: 15.5, width: 7, height: 7)).fill()
        let (kind, kindColor) = session.kindIconChoice
        toolTip = session.openedByTooltip
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState(); ctx.translateBy(x: 28, y: 12)
            ThemeIcons.draw(kind, in: ctx, size: 14, color: kindColor); ctx.restoreGState()
            ctx.saveGState(); ctx.translateBy(x: closeRect.midX, y: closeRect.midY); ctx.rotate(by: .pi / 4)
            ctx.translateBy(x: -5, y: -5)
            ThemeIcons.draw(.plus, in: ctx, size: 10, color: Theme.dynamic(.textFaint))   // a plus turned 45° = ×
            ctx.restoreGState()
        }
        if pinned, let ctx = NSGraphicsContext.current?.cgContext {   // lucide pin
            ctx.saveGState(); ctx.translateBy(x: closeRect.minX - 30, y: 13); ctx.scaleBy(x: 12 / 24, y: 12 / 24)
            ctx.setStrokeColor(Theme.dynamic(.textFaint).cgColor); ctx.setLineWidth(2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(SVGPath.parse("M12 17v5M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z")); ctx.strokePath(); ctx.restoreGState()
        }
        if let e = session.elapsed {
            let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.sans(11), .foregroundColor: Theme.dynamic(group == .waiting ? .warningText : .textMuted)]
            let w = (e as NSString).size(withAttributes: a).width
            (e as NSString).draw(at: NSPoint(x: closeRect.minX - w - 4, y: 11.5), withAttributes: a)
        }
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ f: NSFont, _ c: NSColor, maxW: CGFloat, head: Bool = false) {
            let ps = NSMutableParagraphStyle(); ps.lineBreakMode = head ? .byTruncatingHead : .byTruncatingTail
            (s as NSString).draw(in: NSRect(x: x, y: y, width: maxW, height: 16), withAttributes: [.font: f, .foregroundColor: c, .paragraphStyle: ps])
        }
        let w = bounds.width - 48 - 36
        text(session.name, 48, 11, ThemeFont.sans(13, .semibold), Theme.dynamic(.text), maxW: w)
        let sc: NSColor = group == .waiting ? Theme.dynamic(.warningText) : group == .working ? Theme.dynamic(.successText) : Theme.dynamic(.textMuted)
        text(statusText, 13, 31, ThemeFont.sans(12), sc, maxW: bounds.width - 26)
        text(session.cwd.abbreviatingHome(home), 13, 50, ThemeFont.mono(11), Theme.dynamic(.textFaint), maxW: bounds.width - 26, head: true)
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downAt = p
        if closeRect.contains(p) { onClose?() } else { onSelect?() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, !closeRect.contains(d) else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - d.x, p.y - d.y) > 5 else { return }
        downAt = nil
        let item = NSPasteboardItem(); item.setString("\(session.id)", forType: Self.dragType)
        let di = NSDraggingItem(pasteboardWriter: item)
        di.setDraggingFrame(bounds, contents: bitmapImageRepForCachingDisplay(in: bounds).map { rep in cacheDisplay(in: bounds, to: rep); let img = NSImage(size: bounds.size); img.addRepresentation(rep); return img })
        beginDraggingSession(with: [di], event: event, source: self)
    }
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    #if MUYA_TEST_HOOKS
    func debugDrop(_ m: SplitLogic.DropMode?) { dropOver = m }
    #endif
    private func mode(_ sender: NSDraggingInfo) -> SplitLogic.DropMode {
        SplitLogic.dropMode(y: Double(convert(sender.draggingLocation, from: nil).y), height: Double(bounds.height))
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = draggedID(sender), id != session.id else { return [] }
        dropOver = mode(sender); return .move
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = draggedID(sender), id != session.id else { return [] }
        dropOver = mode(sender); return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropOver = nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let m = mode(sender)
        dropOver = nil
        guard let id = draggedID(sender), id != session.id else { return false }
        onDropSession?(id, m); return true
    }
    private func draggedID(_ info: NSDraggingInfo) -> UInt64? { info.draggingPasteboard.string(forType: Self.dragType).flatMap { UInt64($0) } }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event, self) }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class AgentsPanel: FillView {
    var sessions: () -> [SessionModel] = { [] }
    var selected: () -> SessionModel? = { nil }
    var home = ""
    var onSelect: ((SessionModel) -> Void)?
    var onClose: ((SessionModel) -> Void)?
    var onNew: (() -> Void)?
    var onRename: ((SessionModel) -> Void)?
    /// Builds the context menu of a session (shared with the header's "…" button); nil = the built-in Rename / Close pair.
    var pinned: () -> Set<String> = { [] }
    var menuFor: ((SessionModel) -> NSMenu)?
    /// Split Control: the groups, the collapsed ones, and the actions on them.
    var splitGroups: () -> [SplitGroup] = { [] }
    var splitCollapsed: () -> Set<String> = { [] }
    var onToggleGroup: ((String) -> Void)?
    var onSelectGroup: ((String) -> Void)?
    var onGroup: ((UInt64, UInt64) -> Void)?   // dragged session id, target session id (middle of a row)
    var onReorder: ((UInt64, UInt64) -> Void)?   // dragged session id, target session id (top / bottom quarter)
    var onGroupInto: ((UInt64, String) -> Void)?   // dragged session id, split group id (the group's header row)
    var onUngroup: ((UInt64) -> Void)?   // a split member dropped on the list's empty space
    /// The sessions as listed on screen, top to bottom (open splits first, then the sections): what ⌘1–9 pick from.
    private(set) var onScreenSessions: [SessionModel] = []
    private enum Filter: Int { case all, waiting, working, recent }
    /// "Recent" = working/waiting now, or active within the last 6 hours (src/redesign/recentActivity.ts). Kept in memory only: after a
    /// restart an idle terminal starts un-recent, like today's launch grace.
    private var lastActive: [UInt64: Date] = [:]
    static let recentWindow: TimeInterval = 6 * 3600
    private var filter = Filter.all
    private let segmented = FilterTabs(["All", "Waiting", "Working", "Recent"])
    private let newButton = ThemedButton("+ New agent", style: .primary)
    private let scroll = NSScrollView()
    let doc = AgentsDocView()
    private var signature = ""
    /// How many times the cards were rebuilt: a session switch must not add to it (verify-switch-guard.sh; the regression came back twice).
    private(set) var rebuilds = 0
    private var selectedID: UInt64?
    private var lastSelectedY: CGFloat?
    /// The height of the rows as built; with the header and filter rows above them it is what the panel would like to have.
    private(set) var contentHeight: CGFloat = 0
    var wantedHeight: CGFloat { 100 + contentHeight + 8 }
    var onWantedChange: (() -> Void)?

    init() {
        super.init(.bgPanel)
        trailing = true
        doc.canUngroup = { [weak self] id in
            guard let self, let s = self.sessions().first(where: { $0.id == id }) else { return false }
            return self.splitGroups().contains { $0.keys.contains(SplitModel.key(s)) }
        }
        doc.onUngroup = { [weak self] id in self?.onUngroup?(id) }
        scroll.documentView = doc; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        [segmented, newButton, scroll].forEach(addSubview)
        segmented.onChange = { [weak self] i in self?.filter = Filter(rawValue: i) ?? .all; self?.reloadNow(force: true) }
        newButton.onClick = { [weak self] in self?.onNew?() }
        setAccessibilityRole(.list); setAccessibilityLabel("Agents")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        newButton.frame = NSRect(x: bounds.width - 17 - 89, y: 17, width: 89, height: 30)
        segmented.frame = NSRect(x: 16, y: 57, width: bounds.width - 33, height: 34)
        scroll.frame = NSRect(x: 0, y: 100, width: bounds.width - 1, height: max(0, bounds.height - 100))
        reloadNow(force: true)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let t = ("Agents" as NSString)
        t.draw(at: NSPoint(x: 16, y: 23), withAttributes: [.font: ThemeFont.sans(14, .semibold), .foregroundColor: Theme.dynamic(.text)])
        let w = t.size(withAttributes: [.font: ThemeFont.sans(14, .semibold)]).width
        ("\(sessions().count)" as NSString).draw(at: NSPoint(x: 16 + w + 5, y: 23), withAttributes: [.font: ThemeFont.sans(14), .foregroundColor: Theme.dynamic(.textMuted)])
    }

    private func group(of s: SessionModel) -> AgentCard.Group {
        if s.exited == nil, s.screen?.permission == true { return .waiting }
        if s.exited == nil, s.screen?.busy == true || s.screen?.activity != nil { return .working }
        return .idle
    }

    private var reloadScheduled = false
    /// Bursts of session updates (every streamed screen change) collapse into one pass per run-loop turn.
    func reload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in self?.reloadScheduled = false; self?.reloadNow() }
    }

    /// Rebuilds the cards when what they show changed (or `force`).
    func reloadNow(force: Bool = false) {
        let all = sessions(), sel = selected()
        let groups = all.map { group(of: $0) }
        let now = Date()
        for (i, s) in all.enumerated() where groups[i] != .idle { lastActive[s.id] = now }
        let live = Set(all.map(\.id)); for k in lastActive.keys where !live.contains(k) { lastActive[k] = nil }
        let recent = Set(all.indices.filter { groups[$0] != .idle || (lastActive[all[$0].id].map { now.timeIntervalSince($0) < Self.recentWindow } ?? false) })
        let nWait = groups.filter { $0 == .waiting }.count, nWork = groups.filter { $0 == .working }.count
        let opts = ["All", "Waiting \(nWait)", "Working \(nWork)", "Recent \(recent.count)"]
        if segmented.options != opts { segmented.options = opts }
        if segmented.selected != filter.rawValue { segmented.selected = filter.rawValue }
        let pins = pinned()
        // Selection is not part of the structure: a switch only repaints the old and the new card.
        let sig = all.enumerated().map { i, s in "\(s.id)|\(s.name)|\(s.cwd)|\(s.state.text)|\(groups[i])|\(pins.contains(s.name))|\(recent.contains(i))" }.joined(separator: "\n") + "|\(filter)|\(Int(bounds.width))|" + splitGroups().map { "\($0.id):\($0.keys.joined(separator: ","))" }.joined(separator: ";") + "|\(splitCollapsed().sorted())"
        guard sig != signature else {
            if selectedID != sel?.id {
                selectedID = sel?.id
                defer { revealSelected() }
                for case let c as AgentCard in doc.subviews { c.selected = c.session === sel }
                let groups = splitGroups()
                for case let r as SplitGroupRow in doc.subviews { r.selected = sel.map { s in groups.first { $0.id == r.groupID }?.keys.contains(SplitModel.key(s)) ?? false } ?? false }
            }
            return
        }
        let selectionMoved = selectedID != sel?.id
        selectedID = sel?.id
        signature = sig
        rebuilds += 1
        needsDisplay = true
        doc.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 5
        var first = true
        var onScreen: [SessionModel] = []
        let width = bounds.width
        func card(_ s: SessionModel, _ g: AgentCard.Group, x: CGFloat, w: CGFloat) -> AgentCard {
            let c = AgentCard(session: s, group: g, selected: s === sel, home: home)
            c.pinned = pins.contains(s.name)
            c.frame = NSRect(x: x, y: y, width: w, height: 76)
            c.onSelect = { [weak self] in self?.onSelect?(s) }
            c.onClose = { [weak self] in self?.onClose?(s) }
            c.onMenu = { [weak self] e, v in self?.menu(for: s, event: e, in: v) }
            c.onDropSession = { [weak self] from, mode in if mode == .group { self?.onGroup?(from, s.id) } else { self?.onReorder?(from, s.id) } }
            return c
        }
        func section(_ title: String, _ color: Theme.Token, _ items: [(SessionModel, AgentCard.Group)]) {
            guard !items.isEmpty else { return }
            if !first { y += 6 }
            first = false
            let l = FrameText(title.uppercased(), font: ThemeFont.sans(11, .semibold), color: color)
            l.frame = NSRect(x: 16, y: y + 2, width: width - 32, height: 16); doc.addSubview(l); y += 26
            for (s, g) in items {
                doc.addSubview(card(s, g, x: 10, w: width - 21)); y += 80
                onScreen.append(s)
            }
        }
        let groupsNow = splitGroups(), collapsedNow = splitCollapsed()
        let groupedKeys = Set(groupsNow.flatMap(\.keys))
        let matches = { (i: Int) in self.filter == .all || (self.filter == .recent ? recent.contains(i) : groups[i] == (self.filter == .waiting ? .waiting : .working)) }
        let items = Array(zip(all, groups).enumerated().filter { matches($0.offset) && !groupedKeys.contains(SplitModel.key($0.element.0)) }.map { ($0.element.0, $0.element.1) })
        // A split shows when any of its sessions matches the filter (AgentList.tsx groupsShown); all its sessions are listed under it.
        let shownGroups = groupsNow.filter { g in
            let idx = g.keys.compactMap { k in all.firstIndex { SplitModel.key($0) == k } }
            return !idx.isEmpty && idx.contains(where: matches)
        }
        if !shownGroups.isEmpty {
            first = false
            let l = FrameText("SPLITS", font: ThemeFont.sans(11, .semibold), color: .textStrong)
            l.frame = NSRect(x: 16, y: y + 2, width: width - 32, height: 16); doc.addSubview(l); y += 26
            for g in shownGroups {
                let members = g.keys.compactMap { k in all.first { SplitModel.key($0) == k } }
                let collapsed = collapsedNow.contains(g.id)
                let row = SplitGroupRow(id: g.id, members: members, collapsed: collapsed, selected: sel.map { s in g.keys.contains(SplitModel.key(s)) } ?? false)
                row.frame = NSRect(x: 10, y: y, width: width - 21, height: SplitGroupRow.height)
                row.onToggle = { [weak self] in self?.onToggleGroup?(g.id) }
                row.onSelect = { [weak self] in self?.onSelectGroup?(g.id) }
                row.onDropSession = { [weak self] from in self?.onGroupInto?(from, g.id) }
                doc.addSubview(row); y += SplitGroupRow.height + 2
                if !collapsed {
                    for s in members { doc.addSubview(card(s, group(of: s), x: 24, w: width - 35)); y += 80; onScreen.append(s) }
                    let rule = FillView(.border); rule.frame = NSRect(x: 17, y: y - 80 * CGFloat(members.count) - 2, width: 1, height: 80 * CGFloat(members.count)); doc.addSubview(rule)
                }
            }
        }
        // PINNED first, then the status sections (AgentList.tsx sections).
        let pinnedItems = items.filter { pins.contains($0.0.name) }
        section("Pinned", .textStrong, pinnedItems)
        let rest = items.filter { !pins.contains($0.0.name) }
        if filter != .working { section("Waiting for you", .warningLabel, rest.filter { $0.1 == .waiting }) }
        if filter != .waiting { section("Working", .success, rest.filter { $0.1 == .working }) }
        if filter == .all || filter == .recent { section("Idle", .textFaint, rest.filter { $0.1 == .idle }) }
        onScreenSessions = onScreen
        let selY = doc.subviews.compactMap { $0 as? AgentCard }.first(where: { $0.selected })?.frame.minY
        defer { if selectionMoved || selY != lastSelectedY { revealSelected() }; lastSelectedY = selY }   // a streaming rebuild that moves nothing must not undo the operator's scrolling
        doc.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
        if contentHeight != y { contentHeight = y; DispatchQueue.main.async { [weak self] in self?.onWantedChange?() } }   // the open FILES section shares the column (classic: the list takes only what its rows need)
    }

    /// The selected session's card scrolls into view when the list is longer than the column.
    private func revealSelected() {
        guard let c = doc.subviews.compactMap({ $0 as? AgentCard }).first(where: { $0.selected }) else { return }
        doc.scrollToVisible(c.frame.insetBy(dx: 0, dy: -4))
    }

    #if MUYA_TEST_HOOKS
    /// agents-scroll [y]: scroll the list to y (when given); "scrollY docHeight viewportHeight".
    func debugScroll(_ y: CGFloat?) -> String {
        if let y { scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView) }
        return "\(Int(scroll.contentView.bounds.origin.y)) \(Int(doc.frame.height)) \(Int(scroll.contentSize.height))"
    }
    #endif

    private func menu(for s: SessionModel, event: NSEvent, in view: NSView) {
        if let build = menuFor { NSMenu.popUpContextMenu(build(s), with: event, for: view); return }
        let m = NSMenu()
        let r = m.addItem(withTitle: "Rename…", action: #selector(menuRename(_:)), keyEquivalent: ""); r.target = self; r.representedObject = s
        let c = m.addItem(withTitle: "Close agent", action: #selector(menuClose(_:)), keyEquivalent: ""); c.target = self; c.representedObject = s
        NSMenu.popUpContextMenu(m, with: event, for: view)
    }
    @objc private func menuRename(_ i: NSMenuItem) { if let s = i.representedObject as? SessionModel { onRename?(s) } }
    @objc private func menuClose(_ i: NSMenuItem) { if let s = i.representedObject as? SessionModel { onClose?(s) } }
}

/// The list's document view. It is the drop target of "empty space": a split member dropped here leaves its split (AgentList.tsx UNGROUP).
final class AgentsDocView: NSView {
    override var isFlipped: Bool { true }
    var canUngroup: (UInt64) -> Bool = { _ in false }
    var onUngroup: ((UInt64) -> Void)?
    private var hover = false { didSet { if hover != oldValue { needsDisplay = true } } }
    #if MUYA_TEST_HOOKS
    func debugHover(_ on: Bool) { hover = on }
    #endif
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([AgentCard.dragType]) }
    required init?(coder: NSCoder) { fatalError() }
    private func id(_ i: NSDraggingInfo) -> UInt64? { i.draggingPasteboard.string(forType: AgentCard.dragType).flatMap { UInt64($0) } }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { guard let i = id(s), canUngroup(i) else { return [] }; hover = true; return .move }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { guard let i = id(s), canUngroup(i) else { return [] }; hover = true; return .move }
    override func draggingExited(_ s: NSDraggingInfo?) { hover = false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { hover = false; guard let i = id(s), canUngroup(i) else { return false }; onUngroup?(i); return true }
    override func draw(_ dirtyRect: NSRect) { if hover { DropOutline.draw(.reorder, in: bounds.insetBy(dx: 4, dy: 4), radius: 8) } }
}


/// Today's filter strip (AgentList.tsx): a --bg-segment track, 3 px padding, one 28 px tab per filter that grows with its label
/// (flex-grow 1), 12 px text, the active tab on --bg-segment-active. Same accessibility as a segmented control.
final class FilterTabs: NSControl {
    var options: [String] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?
    init(_ options: [String]) {
        self.options = options
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.radioGroup); setAccessibilityLabel("Filter")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func accessibilityValue() -> Any? { options.indices.contains(selected) ? options[selected] : nil }
    private func font(_ active: Bool) -> NSFont { ThemeFont.sans(12, active ? .medium : .regular) }
    private func rects() -> [NSRect] {
        let inner = NSRect(x: 3, y: 3, width: bounds.width - 6, height: bounds.height - 6)
        let natural = options.enumerated().map { ceil(($1 as NSString).size(withAttributes: [.font: font($0 == selected)]).width) + 8 }
        let extra = max(0, inner.width - 4 * CGFloat(options.count - 1) - natural.reduce(0, +)) / CGFloat(max(1, options.count))
        var x = inner.minX
        return natural.map { w in defer { x += w + extra + 4 }; return NSRect(x: x, y: inner.minY, width: w + extra, height: inner.height) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        Theme.dynamic(.bgSegment).setFill(); track.fill()
        for (i, r) in rects().enumerated() {
            let active = i == selected
            if active { Theme.dynamic(.bgSegmentActive).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
            let a: [NSAttributedString.Key: Any] = [.font: font(active), .foregroundColor: Theme.dynamic(active ? .textStrong : .textTertiary)]
            let t = options[i] as NSString, sz = t.size(withAttributes: a)
            t.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: a)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = rects().firstIndex(where: { $0.insetBy(dx: -2, dy: 0).contains(p) }), i != selected { selected = i; onChange?(i) }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}


/// The one collapsible row of a split group in the agent list (today's GroupRow): chevron, a dot for the most urgent member state, the split icon,
/// the first pane's name and "· N panes". A session dropped on it joins the split.
final class SplitGroupRow: NSView {
    static let height: CGFloat = 34
    let groupID: String, names: [String], collapsed: Bool
    private let dot: Theme.Token
    var selected: Bool { didSet { if selected != oldValue { needsDisplay = true } } }
    var onToggle: (() -> Void)?, onSelect: (() -> Void)?
    var onDropSession: ((UInt64) -> Void)?
    private var dropOver = false { didSet { if dropOver != oldValue { needsDisplay = true } } }
    #if MUYA_TEST_HOOKS
    func debugDrop(_ on: Bool) { dropOver = on }
    #endif
    init(id: String, members: [SessionModel], collapsed: Bool, selected: Bool) {
        self.groupID = id; self.names = members.map(\.name); self.collapsed = collapsed; self.selected = selected
        let waiting = members.contains { $0.exited == nil && $0.screen?.permission == true }
        let working = members.contains { $0.exited == nil && ($0.screen?.busy == true || $0.screen?.activity != nil) }
        dot = waiting ? .warning : working ? .success : .textFaint
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("Split, \(names.count) panes: \(names.joined(separator: ", ")), \(collapsed ? "collapsed" : "expanded")")
        registerForDraggedTypes([AgentCard.dragType])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if selected { Theme.dynamic(.bgSelected).setFill(); p.fill(); Theme.dynamic(.borderSelected).setStroke(); p.stroke() }
        if dropOver { DropOutline.draw(.group, in: bounds, radius: 8) }
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState(); ctx.translateBy(x: 12 + 5, y: bounds.midY); ctx.rotate(by: collapsed ? 0 : .pi / 2); ctx.translateBy(x: -5, y: -5)
            ThemeIcons.draw(.chevronRight, in: ctx, size: 10, color: Theme.dynamic(.textMuted)); ctx.restoreGState()
            ctx.saveGState(); ctx.translateBy(x: 49, y: bounds.midY - 7); ThemeIcons.draw(.splitPane, in: ctx, size: 14, color: Theme.dynamic(.textMuted)); ctx.restoreGState()
        }
        Theme.dynamic(dot).setFill(); NSBezierPath(ovalIn: NSRect(x: 32, y: bounds.midY - 4, width: 8, height: 8)).fill()
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail
        let tail = "· \(names.count) panes" as NSString, tf = ThemeFont.sans(11)
        let tw = tail.size(withAttributes: [.font: tf]).width
        tail.draw(at: NSPoint(x: bounds.width - 10 - tw, y: bounds.midY - 7), withAttributes: [.font: tf, .foregroundColor: Theme.dynamic(.textMuted)])
        ((names.first ?? "Split") as NSString).draw(in: NSRect(x: 69, y: bounds.midY - 8, width: max(0, bounds.width - 69 - 16 - tw), height: 16), withAttributes: [.font: ThemeFont.sans(13, .semibold), .foregroundColor: Theme.dynamic(.text), .paragraphStyle: ps])
    }
    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).x < 28 { onToggle?() } else { onSelect?() }
    }
    private func id(_ i: NSDraggingInfo) -> UInt64? { i.draggingPasteboard.string(forType: AgentCard.dragType).flatMap { UInt64($0) } }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { dropOver = true; return .move }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { .move }
    override func draggingExited(_ s: NSDraggingInfo?) { dropOver = false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { dropOver = false; guard let i = id(s) else { return false }; onDropSession?(i); return true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
