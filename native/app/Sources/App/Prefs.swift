// P4: restores the window state today's app keeps in localStorage (panels, view mode, open files, composer history) from
// ui-prefs.json at launch, and writes changes back under the same keys. Reads/writes go through Store.legacy (debounced).

import AppKit

@MainActor
final class PanelPrefs {
    private unowned let c: MainController
    private var observers: [NSObjectProtocol] = []
    private var restoring = true
    private var hiddenObservation: NSKeyValueObservation?

    nonisolated static func agentsWidth(_ l: LegacyStore) -> Double? {
        PrefCodec.number(l.get(PrefKeys.agentsWidth), min: PrefKeys.agentsWidthRange.min, max: PrefKeys.agentsWidthRange.max)
    }
    /// The width to put on screen: the saved one (or the size-class default) clamped to the window (AgentsWidth).
    nonisolated static func agentsWidth(_ l: LegacyStore, window: CGFloat) -> CGFloat { CGFloat(AgentsWidth.restore(saved: agentsWidth(l), window: Double(window))) }

    init(controller: MainController) {
        c = controller
        // Layout exists after the controller's own deferred setPosition(260); restore on the run-loop turn after it.
        DispatchQueue.main.async { [weak self] in DispatchQueue.main.async { self?.restore() } }
    }

    private var l: LegacyStore { c.store.legacy }

    private func restore() {
        defer { restoring = false; install() }
        // Agents panel: open/closed + width.
        if let open = PrefCodec.bool(l.get(PrefKeys.agentsOpen)) { c.sidebarCollapsed = !open }
        c.refreshFrame()
        if !c.sidebarCollapsed, c.currentPage == nil { c.rootSplit.setPosition(Self.agentsWidth(l, window: c.rootSplit.bounds.width), ofDividerAt: 0) }
        // Files section of the sidebar.
        if let open = PrefCodec.bool(l.get(PrefKeys.filesOpen)) { c.sidebar?.expanded = open }
        c.sidebar?.filesHeight = FilesHeightLogic.parse(l.get(PrefKeys.filesHeight))
        // Inspector.
        // Today's usePanelLayout: open by default; below 1280 px it starts hidden and the stored choice is left alone.
        if let split = c.inspector.superview as? InspectorSplit, (PrefCodec.bool(l.get(PrefKeys.inspectorOpen)) ?? true), !narrowWindow, c.inspector.isHidden {
            // One turn later: the window has its first real size only after launch layout (a stale width gave a 500 px inspector).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.c.inspector.isHidden else { return }
                let was = self.c.panelLayoutLocked
                self.c.panelLayoutLocked = true
                self.c.toggleInspector()
                split.layoutSubtreeIfNeeded()
                let w = PrefCodec.number(self.l.get(PrefKeys.inspectorWidth), min: PrefKeys.inspectorWidthRange.min, max: PrefKeys.inspectorWidthRange.max) ?? Double(ThemeMetric.inspectorWidth)
                split.setPosition(max(split.bounds.width - CGFloat(w), 320), ofDividerAt: 0)
                self.c.panelLayoutLocked = was
            }
        }
        // Grid vs single view.
        if l.get(PrefKeys.viewMode) == "grid" { c.setGrid(true) }
        // Open files (paths only: the viewer shows one file at a time, the palette lists the rest).
        if let paths = PrefCodec.openFiles(l.get(PrefKeys.openFiles)) {
            c.openFilePaths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        }
        // Composer history.
        if let h = PrefCodec.history(l.get(PrefKeys.composerHistoryAgent)) { c.composer.text.history = h }
    }

    /// The inspector's breakpoint (usePanelLayout `narrow`): the window is below 1280 px.
    private var narrowWindow: Bool { (c.window.contentView?.bounds.width ?? c.window.frame.width) < 1280 }
    private var lastNarrow: Bool?
    private enum AutoHidden { case none, page, narrow }
    private var auto = AutoHidden.none   // why the inspector is hidden without the operator having closed it

    private func windowResized() {
        resizeSettle?.invalidate()   // act once the resizing has stopped: the split view must have its final width
        resizeSettle = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.settleResize() } }
    }
    private var resizeSettle: Timer?

    private func settleResize() {
        let narrow = narrowWindow
        defer { lastNarrow = narrow }
        syncInspector(crossed: lastNarrow.map { $0 != narrow } ?? false)
    }

    /// The inspector belongs to the Control view (today's Control screen): a page or the grid hides it and the way back shows it
    /// again; crossing the 1280 px breakpoint hides / shows it. None of this is the operator's choice, so the saved one is left alone.
    func syncInspector(crossed: Bool = false) {
        guard !restoring, let split = c.inspector.superview as? InspectorSplit else { return }
        let control = c.currentPage == nil && !c.gridMode
        let narrow = narrowWindow
        let stored = PrefCodec.bool(l.get(PrefKeys.inspectorOpen)) ?? true
        let shown = !c.inspector.isHidden
        func locked(_ body: @MainActor () -> Void) { let was = c.panelLayoutLocked; c.panelLayoutLocked = true; body(); c.panelLayoutLocked = was }
        if !control {
            if shown { locked { c.toggleInspector() }; auto = .page }
        } else if crossed && narrow {
            if shown { locked { c.toggleInspector() }; auto = .narrow }
        } else if !shown, auto == .page || (!narrow && stored) {   // wide + saved open = on screen (the saved choice is only ever the operator's)
            auto = .none
            locked {
                c.toggleInspector()
                let w = PrefCodec.number(l.get(PrefKeys.inspectorWidth), min: PrefKeys.inspectorWidthRange.min, max: PrefKeys.inspectorWidthRange.max) ?? Double(ThemeMetric.inspectorWidth)
                @MainActor func place() {
                    split.layoutSubtreeIfNeeded(); split.setPosition(max(split.bounds.width - CGFloat(w), 320), ofDividerAt: 0)
                    // No saved agents width: the default of the window's size class (usePanelLayout: 296, 264 at <= 1360), not whatever the resize left
                    if Self.agentsWidth(l) == nil, !c.sidebarCollapsed, c.currentPage == nil, !c.gridMode {
                        c.rootSplit.setPosition(Self.agentsWidth(l, window: c.rootSplit.bounds.width), ofDividerAt: 0)
                    }
                }
                place()
                DispatchQueue.main.async { place() }   // the window may still be settling: once more a turn later
            }
        }
    }

    private func install() {
        let nc = NotificationCenter.default
        lastNarrow = narrowWindow
        observers.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: c.window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.windowResized() } })
        for split in [c.rootSplit, c.inspector.superview as? NSSplitView].compactMap({ $0 }) {
            observers.append(nc.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveLayout() }
            })
        }
        c.onInspectorChoice = { [weak self] open in
            MainActor.assumeIsolated {
                guard let self, !self.restoring, !self.narrowWindow, self.c.currentPage == nil, !self.c.gridMode else { return }   // narrow: this session only
                self.l.set(PrefKeys.inspectorOpen, PrefCodec.encode(bool: open))
            }
        }
        c.onPanelLayoutSettled = { [weak self] in MainActor.assumeIsolated { self?.saveLayout() } }
        hiddenObservation = (c.inspector as NSView).observe(\NSView.isHidden) { [weak self] _, _ in MainActor.assumeIsolated { self?.saveLayout() } }   // hiding sends no resize
        c.sidebar?.onFilesHeight = { [weak self] h in MainActor.assumeIsolated { self?.l.set(PrefKeys.filesHeight, h.map { String(Int($0.rounded())) }) } }
        c.sidebar?.onExpand = { [weak self] open in MainActor.assumeIsolated { self?.l.set(PrefKeys.filesOpen, PrefCodec.encode(bool: open)) } }
        c.onGridChanged = { [weak self] on in MainActor.assumeIsolated { self?.l.set(PrefKeys.viewMode, on ? "grid" : "tabs") } }
        c.onOpenFilesChanged = { [weak self] paths in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.l.set(PrefKeys.openFiles, paths.isEmpty ? nil : PrefCodec.encode(openFiles: paths, kind: Self.kindName, previous: self.l.get(PrefKeys.openFiles)))
            }
        }
        c.composer.text.onHistory = { [weak self] h in
            MainActor.assumeIsolated { self?.l.set(PrefKeys.composerHistoryAgent, PrefCodec.encode(list: h)) }
        }
    }

    /// Open/closed of the agents panel and the inspector, and their widths (clamped like the old app does).
    private func saveLayout() {
        // The grid hides the agents panel and widens the content: those widths are not the operator's choice, keep the saved ones.
        guard !restoring, !c.store.mockMode, !c.gridMode, !c.panelLayoutLocked else { return }
        l.set(PrefKeys.agentsOpen, PrefCodec.encode(bool: !c.sidebarCollapsed))
        if let side = c.rootSplit.arrangedSubviews.first, !side.isHidden, side.frame.width > 100 {
            l.set(PrefKeys.agentsWidth, PrefCodec.encode(number: min(max(side.frame.width, PrefKeys.agentsWidthRange.min), PrefKeys.agentsWidthRange.max)))
        }
        // The inspector's open / closed is saved where the operator toggles it (onInspectorChoice), never inferred from the layout: a narrow
        // window (< 1280 px), a page or the grid hide it without it being a choice (today's usePanelLayout).
        let inspectorIsOperatorChoice = !narrowWindow && c.currentPage == nil && resizeSettle?.isValid != true
        if inspectorIsOperatorChoice, !c.inspector.isHidden, c.inspector.frame.width > 100 {
            l.set(PrefKeys.inspectorWidth, PrefCodec.encode(number: min(max(c.inspector.frame.width, PrefKeys.inspectorWidthRange.min), PrefKeys.inspectorWidthRange.max)))
        }
    }

    private static func kindName(_ path: String) -> String {
        switch FileKind.detect(URL(fileURLWithPath: path)) { case .image: return "imgview"; case .pdf: return "pdfview"; case .markdown: return "mdview"; default: return "editor" }
    }
}
