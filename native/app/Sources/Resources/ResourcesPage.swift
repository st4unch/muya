// The Resources page: what is installed under ~/.claude (skills, agents, hooks, MCPs), the marketplace for
// skills and MCPs, the one-click Muya plugin, and "Create with Claude". Layout, wording and behaviour follow
// today's ResourcesPage.tsx; every call goes through ResourcesService (muyad). Colours via Theme tokens.

import AppKit

/// A flipped view that draws a row: title, optional second and third line, selection and a divider.
final class ResourceRow: NSView {
    var selected = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    private let stack: NSStackView
    let button: ThemedButton?

    init(icon: String, iconColor: NSColor, title: String, lines: [(String, Bool)], install: String? = nil, onInstall: (() -> Void)? = nil, installEnabled: Bool = true) {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 12, weight: .medium); t.textColor = Theme.dynamic(.text); t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let dot = NSTextField(labelWithString: icon)
        dot.font = .systemFont(ofSize: 11); dot.textColor = iconColor
        var head: [NSView] = [dot, t]
        if let install {
            let b = ThemedButton(install, style: .ghost)
            b.onClick = { onInstall?() }
            b.isEnabled = installEnabled
            b.setAccessibilityLabel("\(install) \(title)")
            button = b
            head += [NSView(), b]
        } else { button = nil }
        let top = NSStackView(views: head); top.orientation = .horizontal; top.spacing = 8; top.alignment = .centerY
        var rows: [NSView] = [top]
        for (text, mono) in lines where !text.isEmpty {
            let l = NSTextField(labelWithString: text)
            l.font = mono ? ThemeFont.mono(10) : .systemFont(ofSize: 11)
            l.textColor = Theme.dynamic(.textMuted); l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let pad = NSStackView(views: [l]); pad.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            rows.append(pad)
        }
        stack = NSStackView(views: rows); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        super.init(frame: .zero)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            top.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if selected { Theme.dynamic(.bgSelected).setFill(); bounds.fill() }
        Theme.dynamic(.borderSubtle).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
}

/// A band over a list ("✨ @st4unch", "All skills").
final class ResourceHeading: NSView {
    init(_ text: String, accent: Bool) {
        super.init(frame: .zero)
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .medium)
        l.textColor = accent ? Theme.dynamic(.accent) : Theme.dynamic(.textMuted)
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), l.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 26)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Theme.dynamic(.bgControl).setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class ResourcesPage: PageView, NSSearchFieldDelegate {
    private let service: ResourcesService
    /// Opens a terminal running `command` (Create with Claude).
    var openTerminal: (String, String) -> Void = { _, _ in }
    /// Settings > Default permission mode (the stored value).
    var permissionMode: () -> String = { "" }
    /// Asks the user (a sheet or alert text); tests and verify scripts replace it.
    var report: (String) -> Void = { _ in }

    private(set) var resources = ClaudeResources()
    private(set) var tab: ResourceTab = .skills
    private(set) var marketKind = 0 // 0 skills, 1 mcps
    private(set) var query = ""
    private(set) var loading = false
    private(set) var error: String?
    private(set) var marketSkills: [MarketSkill] = []
    private(set) var marketMcps: [MarketMcp] = []
    private(set) var marketOpenBrowser = false
    private(set) var marketLoading = false
    private(set) var marketError: String?
    private(set) var selectedKey: String?
    private(set) var fileText: String?
    private(set) var fileError: String?
    private(set) var pluginResult: (ok: Bool, message: String)?
    private(set) var pluginInstalling = false
    private(set) var installing: String?
    private var generation = 0
    private var marketTimer: Timer?

    private let search = NSSearchField()
    private let refresh = ThemedButton("Refresh", style: .ghost)
    private let create = ThemedButton("Create with Claude", style: .primary)
    private let tabs = ThemedSegmented(options: ResourceTab.allCases.map(\.title))
    private let kinds = ThemedSegmented(options: ["Skills", "MCPs"])
    private let listStack = NSStackView()
    private let listScroll = NSScrollView()
    private let detail = NSView()
    private var rows: [String: ResourceRow] = [:]

    init(service: ResourcesService) {
        self.service = service
        super.init(title: "Claude Resources")
        buildUI()
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildUI() {
        search.placeholderString = "Search…"; search.setSpokenLabel("Search resources"); search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 190).isActive = true
        refresh.onClick = { [weak self] in self?.reload() }; refresh.setAccessibilityLabel("Refresh resources")
        create.onClick = { [weak self] in self?.showCreate() }; create.setAccessibilityLabel("Create with Claude")
        for v in [search, refresh, create] as [NSView] { accessory.addArrangedSubview(v) }
        tabs.onChange = { [weak self] i in self?.select(tab: ResourceTab(rawValue: i) ?? .skills) }
        kinds.onChange = { [weak self] i in self?.marketKind = i; self?.selectedKey = nil; self?.scheduleMarket(immediately: true); self?.render() }
        tabs.setAccessibilityLabel("Resource type"); kinds.setAccessibilityLabel("Marketplace section")
        let bar = Kit.hstack([tabs, kinds, NSView()], spacing: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical; listStack.alignment = .leading; listStack.spacing = 0
        let flipped = FlippedView(); flipped.translatesAutoresizingMaskIntoConstraints = false
        listStack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(listStack)
        NSLayoutConstraint.activate([listStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), listStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor), listStack.topAnchor.constraint(equalTo: flipped.topAnchor), listStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor)])
        listScroll.documentView = flipped; listScroll.hasVerticalScroller = true; listScroll.drawsBackground = false; listScroll.borderType = .noBorder
        listScroll.setAccessibilityLabel("Resources list")
        flipped.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor).isActive = true
        let divider = Kit.divider(); let vdivider = NSBox(); vdivider.boxType = .separator
        for v in [bar, divider, listScroll, vdivider, detail] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        detail.wantsLayer = false
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            divider.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8), divider.leadingAnchor.constraint(equalTo: content.leadingAnchor), divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: divider.bottomAnchor), listScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor), listScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), listScroll.widthAnchor.constraint(equalToConstant: 288),
            vdivider.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor), vdivider.topAnchor.constraint(equalTo: divider.bottomAnchor), vdivider.bottomAnchor.constraint(equalTo: content.bottomAnchor), vdivider.widthAnchor.constraint(equalToConstant: 1),
            detail.leadingAnchor.constraint(equalTo: vdivider.trailingAnchor), detail.trailingAnchor.constraint(equalTo: content.trailingAnchor), detail.topAnchor.constraint(equalTo: divider.bottomAnchor), detail.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        render()
    }

    override func didShow() { reload() }

    // MARK: Data

    func reload() {
        loading = true; error = nil; render()
        service.list { [weak self] r in
            guard let self else { return }
            self.loading = false
            switch r {
            case let .success(res): self.resources = res
            case let .failure(e): self.error = e.message
            }
            self.render()
        }
    }

    func select(tab t: ResourceTab) {
        tab = t; selectedKey = nil; fileText = nil; fileError = nil
        tabs.selected = t.rawValue
        if t == .marketplace { scheduleMarket(immediately: true) }
        render()
    }

    func setQuery(_ q: String) {
        query = q
        search.stringValue = q
        search.placeholderString = tab == .marketplace ? "Search the marketplace…" : "Search…"
        if tab == .marketplace { scheduleMarket(immediately: false) }
        render()
    }

    func controlTextDidChange(_ obj: Notification) { setQuery(search.stringValue) }

    /// Keys of the rows now listed, in order (test hooks).
    var visibleKeys: [String] { listStack.arrangedSubviews.compactMap { v in rows.first { $0.value === v }?.key } }

    func setKind(_ k: Int) { marketKind = k; selectedKey = nil; scheduleMarket(immediately: true); render() }

    /// 400 ms after the last keystroke (today's debounce); a tab or section change fetches at once.
    private func scheduleMarket(immediately: Bool) {
        marketTimer?.invalidate()
        guard tab == .marketplace else { return }
        if immediately { fetchMarket() } else { marketTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.fetchMarket() } }
    }

    private func fetchMarket() {
        generation += 1; let g = generation
        marketLoading = true; marketError = nil; render()
        if marketKind == 0 {
            service.marketSkills(query) { [weak self] r in
                guard let self, g == self.generation else { return }
                self.marketLoading = false
                switch r { case let .success(s): self.marketSkills = s; case let .failure(e): self.marketError = e.message }
                self.render()
            }
        } else {
            service.marketMcps(query) { [weak self] r in
                guard let self, g == self.generation else { return }
                self.marketLoading = false
                switch r { case let .success(m): self.marketMcps = m.items; self.marketOpenBrowser = m.openBrowser; case let .failure(e): self.marketError = e.message }
                self.render()
            }
        }
    }

    func installPlugin() {
        pluginInstalling = true; pluginResult = nil; render()
        service.installMuyaPlugin { [weak self] r in
            guard let self else { return }
            self.pluginInstalling = false
            switch r { case let .success(m): self.pluginResult = (true, m); case let .failure(e): self.pluginResult = (false, e.message) }
            self.render()
        }
    }

    func install(skill s: MarketSkill) {
        guard !s.githubUrl.isEmpty else { return }
        installing = s.name; render()
        service.installSkill(s) { [weak self] r in
            guard let self else { return }
            self.installing = nil
            switch r {
            case .success: self.report("✓ \(s.name) Install to ~/.claude/skills/ndi."); self.reload()
            case let .failure(e): self.report("Error: \(e.message)"); self.render()
            }
        }
    }

    func install(mcp m: MarketMcp) {
        installing = m.name; render()
        service.installMcp(m) { [weak self] r in
            guard let self else { return }
            self.installing = nil
            switch r {
            case .success: self.report("✓ \(m.name) Add to ~/.claude/.mcp.jsonndi."); self.reload()
            case let .failure(e): self.report("Error: \(e.message)"); self.render()
            }
        }
    }

    // MARK: Selection

    func select(key: String) {
        selectedKey = key; fileText = nil; fileError = nil
        let f = ResourcesLogic.filtered(resources, tab: tab, query: query)
        if tab == .skills, let s = f.skills.first(where: { $0.path == key }) { openSkill(s) }
        else if tab == .agents || tab == .hooks { openFile(key) }
        render()
    }

    private func openFile(_ path: String) {
        if let d = FileManager.default.contents(atPath: path), let s = String(data: d.prefix(512 * 1024), encoding: .utf8) { fileText = s } else { fileError = "Could not read the file." }
    }

    private func openSkill(_ s: ResourceItem) {
        for c in ResourcesLogic.skillFileCandidates(s) { if let d = FileManager.default.contents(atPath: c), let t = String(data: d.prefix(512 * 1024), encoding: .utf8) { fileText = t; return } }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: s.path)) ?? []).sorted()
        if let md = names.first(where: { $0.hasSuffix(".md") }) { openFile("\(s.path)/\(md)") } else { fileError = "No readable content found." }
    }

    // MARK: Render

    private func render() {
        let counts = ResourcesLogic.filtered(resources, tab: tab, query: query)
        let n = [counts.skills.count, counts.agents.count, counts.hooks.count, counts.mcps.count]
        tabs.options = ResourceTab.allCases.map { t in t == .marketplace ? t.title : (tab == .marketplace ? t.title : "\(t.title)  \(n[t.rawValue])") }
        kinds.isHidden = tab != .marketplace; kinds.selected = marketKind
        search.placeholderString = tab == .marketplace ? "Search the marketplace…" : "Search…"
        refresh.isEnabled = !loading
        listStack.arrangedSubviews.forEach { listStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows = [:]
        if tab == .marketplace { renderMarketList() } else { renderLocalList(counts) }
        renderDetail()
    }

    private func add(_ v: NSView) {
        listStack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    private func note(_ text: String, color: NSColor = Theme.dynamic(.textMuted), center: Bool = false, pad: CGFloat = 12) -> NSView {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 12); l.textColor = color; l.alignment = center ? .center : .left
        let box = NSView(); l.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(l)
        NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14), l.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14), l.topAnchor.constraint(equalTo: box.topAnchor, constant: pad), l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -pad)])
        return box
    }

    private func addRow(key: String, _ row: ResourceRow) {
        row.selected = selectedKey == key
        row.onSelect = { [weak self] in self?.select(key: key) }
        rows[key] = row; add(row)
    }

    private func renderLocalList(_ f: (skills: [ResourceItem], agents: [ResourceItem], hooks: [ResourceItem], mcps: [ResourceMcp])) {
        if loading { add(note("Loading…", center: true, pad: 40)); return }
        if let error { add(note(error, color: Theme.dynamic(.dangerText))); return }
        switch tab {
        case .skills: if f.skills.isEmpty { add(note("No results")) }; for s in f.skills { addRow(key: s.path, ResourceRow(icon: "◆", iconColor: .systemPurple, title: s.name, lines: [])) }
        case .agents: if f.agents.isEmpty { add(note("No results")) }; for a in f.agents { addRow(key: a.path, ResourceRow(icon: "●", iconColor: .systemGreen, title: a.name, lines: [])) }
        case .hooks: if f.hooks.isEmpty { add(note("No results")) }; for h in f.hooks { addRow(key: h.path, ResourceRow(icon: "ϟ", iconColor: .systemYellow, title: h.name, lines: [])) }
        case .mcps:
            if f.mcps.isEmpty { add(note("No results")) }
            for m in f.mcps { addRow(key: "\(m.agent):\(m.name)", ResourceRow(icon: "⏚", iconColor: .systemTeal, title: m.agent == "opencode" ? "\(m.name)  · opencode" : m.name, lines: [(m.description, false), (m.command, true)])) }
        case .marketplace: break
        }
    }

    private func renderMarketList() {
        add(pluginCard())
        if marketLoading { add(note("Loading…", center: true, pad: 40)); return }
        if let marketError { add(note(marketError, color: Theme.dynamic(.dangerText))); return }
        if marketKind == 0 {
            if marketSkills.isEmpty { add(note("No results", center: true, pad: 20)) }
            for (i, s) in marketSkills.enumerated() {
                if i == 0 && s.featured { add(ResourceHeading("✨ @st4unch", accent: true)) }
                if i > 0 && !s.featured && marketSkills[i - 1].featured { add(ResourceHeading("All skills", accent: false)) }
                let meta = (s.stars.isEmpty || s.stars == "—") ? "" : "★ \(s.stars)" + (s.author.isEmpty ? "" : " · @\(s.author)")
                addRow(key: s.name, ResourceRow(icon: "◆", iconColor: .systemPurple, title: s.name, lines: [(meta, false), (s.description, false)], install: installing == s.name ? "…" : "Install", onInstall: { [weak self] in self?.install(skill: s) }, installEnabled: installing != s.name && !s.githubUrl.isEmpty))
            }
        } else {
            if marketOpenBrowser {
                add(note("Could not load the Glama.ai MCP list.", color: Theme.dynamic(.warningText)))
                let b = ThemedButton("Open in browser", style: .ghost); b.onClick = { NSWorkspace.shared.open(URL(string: "https://glama.ai/mcp/servers")!) }
                let box = NSView(); b.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(b)
                NSLayoutConstraint.activate([b.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14), b.topAnchor.constraint(equalTo: box.topAnchor), b.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8)]); add(box)
            }
            if marketMcps.isEmpty && !marketOpenBrowser { add(note("No results", center: true, pad: 20)) }
            for m in marketMcps { addRow(key: m.name, ResourceRow(icon: "⏚", iconColor: .systemTeal, title: m.name, lines: [(m.description, false)], install: installing == m.name ? "…" : "Install", onInstall: { [weak self] in self?.install(mcp: m) }, installEnabled: installing != m.name && !m.command.isEmpty)) }
        }
    }

    /// The pinned card: Muya's own plugin, visible on every marketplace section.
    private func pluginCard() -> NSView {
        let card = ThemedBox(.card)
        let title = NSTextField(labelWithString: "Muya plugin (muya-mcp)"); title.font = .systemFont(ofSize: 12, weight: .semibold); title.textColor = Theme.dynamic(.text)
        let body = NSTextField(wrappingLabelWithString: "Muya's own agent skill — teaches Claude how to use Muya's SSH/session tools."); body.font = .systemFont(ofSize: 11); body.textColor = Theme.dynamic(.textMuted)
        let b = ThemedButton(pluginInstalling ? "Loading…" : "Install", style: .ghost); b.onClick = { [weak self] in self?.installPlugin() }; b.isEnabled = !pluginInstalling
        b.setAccessibilityLabel("Install the Muya plugin")
        var views: [NSView] = [title, body, b]
        if let r = pluginResult {
            let l = NSTextField(wrappingLabelWithString: (r.ok ? "✓ " : "✗ ") + r.message); l.font = .systemFont(ofSize: 11); l.textColor = Theme.dynamic(r.ok ? .successText : .dangerText); views.append(l)
        }
        let s = NSStackView(views: views); s.orientation = .vertical; s.alignment = .leading; s.spacing = 4
        s.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(s)
        let wrap = NSView(); card.translatesAutoresizingMaskIntoConstraints = false; wrap.addSubview(card)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), s.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12), s.topAnchor.constraint(equalTo: card.topAnchor, constant: 10), s.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            card.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12), card.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -12), card.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 12), card.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
        ])
        return wrap
    }

    // MARK: Detail

    private func renderDetail() {
        detail.subviews.forEach { $0.removeFromSuperview() }
        let v: NSView
        if tab == .marketplace {
            if let key = selectedKey, marketKind == 0, let s = marketSkills.first(where: { $0.name == key }) { v = skillDetail(s) }
            else if let key = selectedKey, marketKind == 1, let m = marketMcps.first(where: { $0.name == key }) { v = mcpDetail(m) }
            else { v = emptyDetail() }
        } else if let key = selectedKey {
            if tab == .mcps { if let m = resources.mcps.first(where: { "\($0.agent):\($0.name)" == key }) { v = localMcpDetail(m) } else { v = emptyDetail() } }
            else { v = fileDetail(path: key) }
        } else { v = emptyDetail() }
        v.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(v)
        NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: detail.leadingAnchor), v.trailingAnchor.constraint(equalTo: detail.trailingAnchor), v.topAnchor.constraint(equalTo: detail.topAnchor), v.bottomAnchor.constraint(equalTo: detail.bottomAnchor)])
    }

    private func emptyDetail() -> NSView {
        let l = NSTextField(labelWithString: "Select an item"); l.font = .systemFont(ofSize: 12); l.textColor = Theme.dynamic(.textFaint)
        let v = NSView(); l.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(l)
        NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: v.centerXAnchor), l.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        return v
    }

    private func panel(_ views: [NSView]) -> NSView {
        let s = NSStackView(views: views); s.orientation = .vertical; s.alignment = .leading; s.spacing = 14
        let v = NSView(); s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s)
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20), s.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20), s.topAnchor.constraint(equalTo: v.topAnchor, constant: 20)])
        for x in views { if x is ThemedBox || x is NSTextField { x.widthAnchor.constraint(lessThanOrEqualTo: s.widthAnchor).isActive = true } }
        return v
    }

    private func heading(_ name: String, _ sub: String?) -> NSView {
        let t = NSTextField(labelWithString: name); t.font = .systemFont(ofSize: 14, weight: .semibold); t.textColor = Theme.dynamic(.text)
        guard let sub, !sub.isEmpty else { return t }
        let s = NSTextField(labelWithString: sub); s.font = .systemFont(ofSize: 12); s.textColor = Theme.dynamic(.textMuted)
        let st = NSStackView(views: [t, s]); st.orientation = .vertical; st.alignment = .leading; st.spacing = 2
        return st
    }

    private func box(_ label: String, _ value: String, mono: Bool = true) -> NSView {
        let b = ThemedBox(.card)
        let l = NSTextField(labelWithString: label.uppercased()); l.font = .systemFont(ofSize: 10); l.textColor = Theme.dynamic(.textMuted)
        let t = NSTextField(wrappingLabelWithString: value); t.font = mono ? ThemeFont.mono(12) : .systemFont(ofSize: 12); t.textColor = Theme.dynamic(.text); t.isSelectable = true
        let s = NSStackView(views: [l, t]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 4
        s.translatesAutoresizingMaskIntoConstraints = false; b.addSubview(s)
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 12), s.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -12), s.topAnchor.constraint(equalTo: b.topAnchor, constant: 10), s.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -10)])
        return b
    }

    private func wideButton(_ title: String, enabled: Bool, primary: Bool = true, _ action: @escaping () -> Void) -> NSView {
        let b = ThemedButton(title, style: primary ? .primary : .ghost); b.onClick = action; b.isEnabled = enabled; b.setAccessibilityLabel(title)
        return b
    }

    private func localMcpDetail(_ m: ResourceMcp) -> NSView {
        var v: [NSView] = [heading(m.name, nil)]
        if !m.description.isEmpty { v.append(label(m.description)) }
        v.append(box("Command / URL", m.command))
        return panel(v)
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s); l.font = .systemFont(ofSize: 12); l.textColor = Theme.dynamic(.text); l.isSelectable = true
        return l
    }

    private func skillDetail(_ s: MarketSkill) -> NSView {
        var v: [NSView] = [heading(s.name, s.author.isEmpty ? nil : "@\(s.author) · skillsmp.com")]
        if !s.stars.isEmpty && s.stars != "—" { v.append(label("★ \(s.stars)")) }
        if !s.description.isEmpty { v.append(label(s.description)) }
        if !s.githubUrl.isEmpty {
            let link = ThemedButton(s.githubUrl, style: .ghost); link.onClick = { if ResourcesLogic.isHttps(s.githubUrl) { NSWorkspace.shared.open(URL(string: s.githubUrl)!) } }
            v.append(box("GitHub", s.githubUrl)); v.append(link)
        }
        v.append(wideButton(installing == s.name ? "Loading…" : ResourcesLogic.skillInstallLabel, enabled: installing != s.name && !s.githubUrl.isEmpty) { [weak self] in self?.install(skill: s) })
        return panel(v)
    }

    private func mcpDetail(_ m: MarketMcp) -> NSView {
        var v: [NSView] = [heading(m.name, m.source)]
        if !m.description.isEmpty { v.append(label(m.description)) }
        if !m.command.isEmpty { v.append(box("Command", m.command + (m.args.isEmpty ? "" : "\n" + m.args.joined(separator: " ")))) }
        if !m.command.isEmpty {
            v.append(wideButton(installing == m.name ? "Ekleniyor…" : ResourcesLogic.mcpInstallLabel, enabled: installing != m.name) { [weak self] in self?.install(mcp: m) })
        } else if ResourcesLogic.isHttps(m.source) {
            v.append(wideButton("Open on Glama.ai", enabled: true, primary: false) { if let u = URL(string: m.source), ResourcesLogic.isHttps(m.source) { NSWorkspace.shared.open(u) } })
        }
        return panel(v)
    }

    private func fileDetail(path: String) -> NSView {
        let name = (path as NSString).lastPathComponent
        let head = NSTextField(labelWithString: name); head.font = ThemeFont.mono(12); head.textColor = Theme.dynamic(.textMuted)
        let tv = NSTextView(); tv.isEditable = false; tv.drawsBackground = false; tv.font = ThemeFont.mono(12); tv.textColor = Theme.dynamic(.text)
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.string = fileText ?? fileError ?? "Loading…"
        if fileError != nil { tv.textColor = Theme.dynamic(.dangerText) }
        tv.isVerticallyResizable = true; tv.autoresizingMask = [.width]
        tv.setAccessibilityLabel("File contents")
        let sc = NSScrollView(); sc.documentView = tv; sc.hasVerticalScroller = true; sc.drawsBackground = false
        let bar = NSView(); head.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(head)
        NSLayoutConstraint.activate([head.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16), head.centerYAnchor.constraint(equalTo: bar.centerYAnchor), bar.heightAnchor.constraint(equalToConstant: 30)])
        let sep = Kit.divider()
        let v = NSView()
        for x in [bar, sep, sc] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: v.topAnchor), bar.leadingAnchor.constraint(equalTo: v.leadingAnchor), bar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            sep.topAnchor.constraint(equalTo: bar.bottomAnchor), sep.leadingAnchor.constraint(equalTo: v.leadingAnchor), sep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            sc.topAnchor.constraint(equalTo: sep.bottomAnchor), sc.leadingAnchor.constraint(equalTo: v.leadingAnchor), sc.trailingAnchor.constraint(equalTo: v.trailingAnchor), sc.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }

    // MARK: Create with Claude

    private var createSheet: NSWindow?

    /// What the sheet's Create button does: Claude Code opens in a new terminal with the wrapped request.
    func createWith(kind: String, request: String) {
        openTerminal("Create \(kind)", ResourcesLogic.createCommand(prompt: ResourcesLogic.createPrompt(kind: kind, request: request), mode: permissionMode()))
    }

    func showCreate() {
        guard let win = window, createSheet == nil else { return }
        let kind = ThemedSegmented(options: ["Skill", "Agent", "Hook", "MCP"]); kind.setAccessibilityLabel("What to create")
        let text = DialogTextView(); text.isRichText = false; text.font = .systemFont(ofSize: 13); text.setAccessibilityLabel("What should Claude create?")
        let sc = NSScrollView(); sc.documentView = text; sc.hasVerticalScroller = true; sc.borderType = .lineBorder
        sc.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let hint = Kit.helper("Describe it in a sentence or two; Claude Code opens in a new terminal and writes the files under ~/.claude.")
        let go = ThemedButton("Create", style: .primary), cancel = ThemedButton("Cancel", style: .ghost)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Create with Claude"
        let stack = Kit.vstack([Kit.label("Create with Claude", size: 15, bold: true), kind, sc, hint, Kit.hstack([NSView(), cancel, go])], spacing: 12, alignment: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheet.contentView = NSView(); sheet.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: sheet.contentView!.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: sheet.contentView!.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: sheet.contentView!.topAnchor, constant: 18), stack.bottomAnchor.constraint(lessThanOrEqualTo: sheet.contentView!.bottomAnchor, constant: -16), sc.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        cancel.onClick = { [weak self] in win.endSheet(sheet); self?.createSheet = nil }
        go.onClick = { [weak self] in
            let req = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !req.isEmpty else { hint.stringValue = "Please describe what you want to create."; hint.textColor = Theme.dynamic(.dangerText); return }
            let k = ["Skill", "Agent", "Hook", "MCP"][kind.selected]
            win.endSheet(sheet); self?.createSheet = nil
            self?.createWith(kind: k, request: req)
        }
        createSheet = sheet
        win.beginSheet(sheet)
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }
