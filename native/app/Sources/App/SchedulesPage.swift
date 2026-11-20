// Schedules view: list / create / edit / delete / enable / run now / history against muyad's scheduler
// (muyad owns the timers; `schedules.*` calls). Validation messages come from muya-core unchanged.
// Laid out like today's page (src/components/SchedulesPage.tsx): heading, runner card, four stat tiles, schedule cards.

import AppKit

/// One schedule card: name + state pill + switch, schedule text, folder; runs / last run / next run band; buttons.
final class ScheduleCardView: NSView {
    let job: ScheduleJob
    var onSelect: (() -> Void)?
    var onActivate: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { onSelect?(); needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onActivate?()
        case 123, 126: onMove?(-1)
        case 124, 125: onMove?(1)
        default: super.keyDown(with: event)
        }
    }

    init(job j: ScheduleJob, now: Date, page: SchedulesPage) {
        job = j
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Schedule \(j.name)")
        let busy = j.running || j.queued

        let name = NSTextField(labelWithString: j.name)
        name.font = ThemeFont.sans(14, .semibold); name.textColor = Theme.dynamic(j.enabled ? .text : .textMuted)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setAccessibilityLabel("Name: \(j.name)")
        let pill = Self.pill(for: j)
        let sw = ThemedSwitch(isOn: j.enabled)
        sw.setAccessibilityLabel("Enable \(j.name)")
        sw.onChange = { [weak page] on in page?.setEnabled(j, on) }
        let head = Kit.hstack([name, pill, sw], spacing: 8)
        let when = NSTextField(labelWithString: j.describe)
        when.font = ThemeFont.sans(12); when.textColor = Theme.dynamic(.textTertiary)
        let folder = NSTextField(labelWithString: j.target.map { "Session · \($0.name)" } ?? j.folder)
        folder.font = ThemeFont.mono(11); folder.textColor = Theme.dynamic(.textFaint)
        folder.lineBreakMode = .byTruncatingMiddle
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = Kit.vstack([head, when, folder], spacing: 6)
        for v in [head, when, folder] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true }

        // runs / last run / next run
        func metric(_ title: String, _ value: NSAttributedString) -> NSView {
            let l = NSTextField(labelWithString: ""); l.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [.font: ThemeFont.sans(10, .semibold), .kern: 0.6, .foregroundColor: Theme.dynamic(.textMuted)])
            let v = NSTextField(labelWithString: ""); v.attributedStringValue = value; v.lineBreakMode = .byTruncatingTail
            v.setAccessibilityLabel("\(title): \(value.string)")
            return Kit.vstack([l, v], spacing: 3)
        }
        func plain(_ t: String) -> NSAttributedString { NSAttributedString(string: t, attributes: [.font: ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.text)]) }
        let runs = NSMutableAttributedString(string: "\(j.runs) ", attributes: [.font: ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.text)])
        let small: (NSColor) -> [NSAttributedString.Key: Any] = { [.font: ThemeFont.sans(12), .foregroundColor: $0] }
        runs.append(NSAttributedString(string: "(", attributes: small(Theme.dynamic(.textMuted))))
        runs.append(NSAttributedString(string: "\(j.ok)✓", attributes: small(Theme.dynamic(.successText))))
        runs.append(NSAttributedString(string: " ", attributes: small(Theme.dynamic(.textMuted))))
        runs.append(NSAttributedString(string: "\(j.failed)✗", attributes: small(Theme.dynamic(j.failed > 0 ? .dangerText : .textMuted))))
        runs.append(NSAttributedString(string: ")", attributes: small(Theme.dynamic(.textMuted))))
        let metrics = Kit.hstack([
            metric("Runs", runs),
            metric("Last run", plain(j.lastStarted.map { ScheduleFormat.relTime(ms: $0, now: now) } ?? "never")),
            metric("Next run", plain(j.nextRunText(now: now))),
        ], spacing: 12, alignment: .top)
        metrics.distribution = .equalSpacing
        let band = ModalFill(.bgControl); band.top = true
        band.translatesAutoresizingMaskIntoConstraints = false
        Kit.pin(metrics, in: band, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))

        // buttons
        let run = ModalButton(j.running ? "Running…" : j.queued ? "Waiting…" : "Run now", icon: .play, label: "Run \(j.name) now")
        run.isEnabled = !busy; run.onClick = { [weak page] in page?.runNow(j) }
        let hist = ModalButton("History", icon: .history, label: "Show the run history of \(j.name)")
        hist.onClick = { [weak page] in page?.showHistory(j) }
        let edit = ModalButton("", icon: .pencil, iconOnly: true, label: "Edit \(j.name)")
        edit.onClick = { [weak page] in page?.openEditor(j) }
        let del = ModalButton("", icon: .trash, iconOnly: true, label: "Delete \(j.name)")
        del.isEnabled = !j.running; del.toolTip = j.running ? "Wait for the run to finish" : "Delete"
        del.onClick = { [weak page] in page?.delete(j, confirm: page?.confirmDeletes ?? true) }
        edit.toolTip = "Edit"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = Kit.hstack([run, hist, spacer, edit, del], spacing: 6)
        let actionsBox = ModalFill(.bgPanel); actionsBox.top = true
        actionsBox.translatesAutoresizingMaskIntoConstraints = false
        Kit.pin(actions, in: actionsBox, insets: NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10))

        let topBox = NSView(); topBox.translatesAutoresizingMaskIntoConstraints = false
        Kit.pin(top, in: topBox, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        let col = Kit.vstack([topBox, band, actionsBox], spacing: 0, alignment: .leading)
        Kit.pin(col, in: self, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        for v in [topBox, band, actionsBox] { v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func pill(for j: ScheduleJob) -> ThemedPill {
        let label = j.stateLabel
        switch label {
        case "Success": return ThemedPill(label, fg: Theme.dynamic(.successText), bg: Theme.dynamic(.successBg), dot: Theme.dynamic(.successText))
        case "Timed out", "Failed": return ThemedPill(label, fg: Theme.dynamic(.dangerText), bg: Theme.dynamic(.dangerPillBg), dot: Theme.dynamic(.dangerText))
        case "Running", "Waiting": return ThemedPill(label, fg: Theme.dynamic(.warningText), bg: Theme.dynamic(.warningBg), dot: Theme.dynamic(.warningText))
        default: return ThemedPill(label, fg: Theme.dynamic(.textMuted), bg: Theme.dynamic(.bgControl), dot: Theme.dynamic(.textMuted))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.dynamic(.bgPanel).setFill(); path.fill()
        // the band and button rows paint square; clip them to the rounded card below by drawing the border last
        let focused = window?.firstResponder === self
        (focused ? Theme.dynamic(.accent) : selected ? Theme.dynamic(.borderSelected) : Theme.dynamic(.border)).setStroke(); path.lineWidth = focused ? 1.5 : 1; path.stroke()
    }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
}

final class SchedulesPage: PageView {
    unowned let store: Store
    private let banner = Kit.label("", size: 12, color: Token.statePermission, lines: 2)
    private let message = ThemedText.plainHelper("")
    private(set) var jobs: [ScheduleJob] = []
    private(set) var runner = "none"
    private(set) var stats = ScheduleStats([])
    private var selectedID: String?
    private var poll: Timer?
    private var shown = false
    private var lastReload = Date.distantPast
    private var eventCoalesce: Timer?
    /// Reloads caused by a daemon `schedules-changed` event / by the fallback poll (verification and diagnostics).
    private(set) var eventReloads = 0
    private(set) var pollReloads = 0
    var onScheduledPrompt: (() -> Void)?
    private(set) var editor: ScheduleEditor?
    private(set) var historyPanel: ScheduleHistory?
    /// The test hook sets this so a delete does not wait for the confirmation sheet.
    var confirmDeletes = true

    private let board = NSStackView()
    private let runnerStatus = ThemedText.plainHelper("")
    private let bannerBox = ThemedBox(.card)
    private var tilesRow = NSStackView()
    private var tileViews: [(value: NSTextField, hint: NSTextField, box: ThemedBox)] = []
    private let gridHost = NSStackView()
    private let emptyBox = ThemedBox(.card)
    private var cards: [ScheduleCardView] = []
    private var columns = 3

    init(store: Store) {
        self.store = store
        super.init(title: "Schedules")
        useOwnHeading()
        NotificationCenter.default.addObserver(self, selector: #selector(daemonEvent(_:)), name: Store.eventNotification, object: store)
        buildBoard()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildBoard() {
        // Heading: icon, title, actions.
        let icon = GlyphView(.theme(.schedulesRail), size: 20, token: .textMuted)
        let title = NSTextField(labelWithString: "Schedules")
        title.font = ThemeFont.sans(18, .semibold); title.textColor = Theme.dynamic(.text)
        title.setAccessibilityRole(.staticText)
        let prompt = ModalButton("Scheduled prompt…", height: 32, label: "Send a prompt to terminals at a chosen time, once")
        prompt.onClick = { [weak self] in self?.scheduledPromptTapped() }
        let new = ModalButton("New schedule", style: .primary, icon: .plus, height: 32, label: "Create a new schedule")
        new.onClick = { [weak self] in self?.newTapped() }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let head = Kit.hstack([icon, title, spacer, prompt, new], spacing: 8)
        head.setCustomSpacing(10, after: icon)

        let intro = NSTextField(wrappingLabelWithString: "Claude prompts that run on their own — headless in a folder, or typed into a running session (right-click a session → Schedule…) — with your settings, MCP servers and skills. Closing the window keeps Muya running; a run missed while Muya was quit or the Mac was asleep is skipped.")
        intro.font = ThemeFont.sans(13); intro.textColor = Theme.dynamic(.textMuted)

        // "Run when Muya is closed": the native app shows who runs the timers (the service registration lives in Settings of the system).
        let moon = GlyphView(.theme(.themeMoon), size: 16, token: .textMuted)
        let rtitle = ThemedText.title("Run when Muya is closed")
        let rbody = ThemedText.plainHelper("A background service named Muya runs your schedules even after you quit Muya or restart the Mac. macOS asks you to allow it once. Not needed if you keep Muya open.")
        rbody.maximumNumberOfLines = 0
        runnerStatus.font = ThemeFont.sans(12)
        let rcol = Kit.vstack([rtitle, rbody, runnerStatus], spacing: 4)
        for v in [rtitle, rbody, runnerStatus] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: rcol.widthAnchor).isActive = true }
        let runnerCard = ThemedBox(.card)
        rcol.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let rrow = Kit.hstack([moon, rcol], spacing: 12, alignment: .top)
        rrow.distribution = .fill
        rrow.translatesAutoresizingMaskIntoConstraints = false
        runnerCard.addSubview(rrow)
        NSLayoutConstraint.activate([
            rrow.topAnchor.constraint(equalTo: runnerCard.topAnchor, constant: 16), rrow.bottomAnchor.constraint(equalTo: runnerCard.bottomAnchor, constant: -16),
            rrow.leadingAnchor.constraint(equalTo: runnerCard.leadingAnchor, constant: 14), rrow.trailingAnchor.constraint(equalTo: runnerCard.trailingAnchor, constant: -14),
        ])
        runnerCard.setAccessibilityElement(true); runnerCard.setAccessibilityRole(.group); runnerCard.setAccessibilityLabel("Run when Muya is closed")

        // Warning box for "another window runs the timers" / "nobody does".
        banner.font = ThemeFont.sans(13); banner.textColor = Theme.dynamic(.warningText)
        banner.maximumNumberOfLines = 0; banner.lineBreakMode = .byWordWrapping
        banner.translatesAutoresizingMaskIntoConstraints = false
        bannerBox.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: bannerBox.topAnchor, constant: 8), banner.bottomAnchor.constraint(equalTo: bannerBox.bottomAnchor, constant: -8),
            banner.leadingAnchor.constraint(equalTo: bannerBox.leadingAnchor, constant: 12), banner.trailingAnchor.constraint(equalTo: bannerBox.trailingAnchor, constant: -12),
        ])

        // Four stat tiles.
        tilesRow.orientation = .horizontal; tilesRow.spacing = 12; tilesRow.distribution = .fillEqually; tilesRow.alignment = .top
        for t in ["Schedules", "Runs", "Success rate", "Last failure"] {
            let box = ThemedBox(.card)
            let l = ThemedText.label(t)
            let v = NSTextField(labelWithString: "—"); v.font = ThemeFont.sans(20, .semibold); v.textColor = Theme.dynamic(.text); v.lineBreakMode = .byTruncatingTail
            let h = ThemedText.plainHelper(""); h.maximumNumberOfLines = 1
            let col = Kit.vstack([l, v, h], spacing: 2); col.setCustomSpacing(6, after: l)
            for x in [l, v, h] { x.translatesAutoresizingMaskIntoConstraints = false; x.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
            col.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: box.topAnchor, constant: 16), col.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
                col.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14), col.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            ])
            box.setAccessibilityElement(true); box.setAccessibilityLabel(t)
            tileViews.append((v, h, box)); tilesRow.addArrangedSubview(box)
        }

        // Empty state.
        let eicon = GlyphView(.theme(.schedulesRail), size: 22, token: .textFaint)
        let etitle = ThemedText.title("No schedules yet")
        let ebody = ThemedText.plainHelper("Run a Claude prompt every few hours, every day or on chosen weekdays — a nightly report, a dependency check, a summary of yesterday's work.")
        ebody.alignment = .center; ebody.preferredMaxLayoutWidth = 420
        let ebtn = ModalButton("New schedule", icon: .plus, height: 32, label: "Create the first schedule"); ebtn.onClick = { [weak self] in self?.newTapped() }
        let ecol = Kit.vstack([eicon, etitle, ebody, ebtn], spacing: 10, alignment: .centerX)
        ecol.translatesAutoresizingMaskIntoConstraints = false
        emptyBox.addSubview(ecol)
        NSLayoutConstraint.activate([
            ecol.topAnchor.constraint(equalTo: emptyBox.topAnchor, constant: 40), ecol.bottomAnchor.constraint(equalTo: emptyBox.bottomAnchor, constant: -40),
            ecol.centerXAnchor.constraint(equalTo: emptyBox.centerXAnchor),
        ])
        emptyBox.isHidden = true

        gridHost.orientation = .vertical; gridHost.spacing = 12; gridHost.alignment = .leading

        board.orientation = .vertical; board.spacing = 16; board.alignment = .leading
        let blocks: [NSView] = [head, intro, runnerCard, bannerBox, message, tilesRow, emptyBox, gridHost]
        for v in blocks { board.addArrangedSubview(v) }
        board.setCustomSpacing(8, after: head)
        board.translatesAutoresizingMaskIntoConstraints = false
        let doc = ModalDocView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(board)
        let scroll = Kit.scroll(doc, label: "Schedules list")
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.scrollerStyle = .overlay
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            board.topAnchor.constraint(equalTo: doc.topAnchor, constant: 24), board.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
            board.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24), board.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
        ])
        for v in blocks { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: board.widthAnchor).isActive = true }
        banner.isHidden = true; bannerBox.isHidden = true; message.isHidden = true
    }

    override func layout() {
        super.layout()
        let want = bounds.width >= 980 ? 3 : bounds.width >= 640 ? 2 : 1
        if want != columns { columns = want; rebuildGrid() }
    }

    override func didShow() {
        shown = true
        wantFocus = true
        reload()
        poll?.invalidate()
        // The daemon tells us when a schedule or a run changed (`schedules-changed`), so nothing needs polling.
        // The poll is only the fallback: every 3 s while no daemon event has ever arrived (an older daemon), and a
        // slow safety refresh once events flow.
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.store.eventsSeen == 0 || Date().timeIntervalSince(self.lastReload) > 60 { self.pollReloads += 1; self.reload(keepSelection: true) }
        }
        poll?.tolerance = 1
    }

    override func didHide() { shown = false; poll?.invalidate(); poll = nil; eventCoalesce?.invalidate() }

    @objc private func daemonEvent(_ n: Notification) {
        guard shown, (n.userInfo?["name"] as? String) == "schedules-changed" else { return }
        eventCoalesce?.invalidate()
        // A run writes several things in a row: one reload for the burst.
        eventCoalesce = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in self?.eventReloads += 1; self?.reload(keepSelection: true) }
    }

    @objc func scheduledPromptTapped() { onScheduledPrompt?() }

    // MARK: Data

    func reload(keepSelection: Bool = true) {
        lastReload = Date()
        let keep = keepSelection ? selectedID : nil
        store.call("schedules.list") { [weak self] r in
            guard let self else { return }
            switch r {
            case let .success(v):
                let d = v as? [String: Any] ?? [:]
                self.jobs = jsonObjects(d["jobs"]).compactMap(ScheduleJob.init(json:))
                self.runner = (d["runner"] as? String) ?? "none"
                self.setMessage("")
            case let .failure(e):
                self.setMessage("Could not read the schedules: \(describe(e))")
            }
            self.refreshViews(selecting: keep)
        }
    }

    private func setMessage(_ t: String) { message.stringValue = t; message.isHidden = t.isEmpty }

    private func refreshViews(selecting id: String?) {
        stats = ScheduleStats(jobs)
        let now = Date()
        let on = jobs.filter(\.enabled).count
        let total = jobs.reduce(0) { $0 + $1.runs }, ok = jobs.reduce(0) { $0 + $1.ok }, failed = jobs.reduce(0) { $0 + $1.failed }
        let failedJob = jobs.filter { $0.lastStatus != nil && $0.lastStatus != "success" && $0.runs > 0 }.max { ($0.lastStarted ?? 0) < ($1.lastStarted ?? 0) }
        let rate = total == 0 ? nil : Int((Double(ok) / Double(total) * 100).rounded())
        let values: [(String, String, NSColor)] = [
            ("\(jobs.count)", "\(on) on · \(jobs.count - on) off", Theme.dynamic(.text)),
            ("\(total)", "\(ok) succeeded · \(failed) failed", Theme.dynamic(.text)),
            (rate.map { "\($0)%" } ?? "—", total > 0 ? "across the kept runs" : "no runs yet", rate.map { $0 >= 90 ? Theme.dynamic(.successText) : $0 < 60 ? Theme.dynamic(.dangerText) : Theme.dynamic(.text) } ?? Theme.dynamic(.text)),
            (failedJob?.name ?? "None", failedJob?.lastStarted.map { ScheduleFormat.relTime(ms: $0, now: now) } ?? "every run succeeded", failedJob != nil ? Theme.dynamic(.dangerText) : Theme.dynamic(.text)),
        ]
        let names = ["Schedules", "Runs", "Success rate", "Last failure"]
        for (i, t) in tileViews.enumerated() {
            t.value.stringValue = values[i].0; t.value.textColor = values[i].2; t.hint.stringValue = values[i].1
            t.box.setAccessibilityLabel("\(names[i]): \(values[i].0)")
        }
        banner.stringValue = runnerBanner(runner) ?? ""
        bannerBox.isHidden = banner.stringValue.isEmpty; banner.isHidden = bannerBox.isHidden
        runnerStatus.stringValue = runnerLabel(runner)
        runnerStatus.textColor = Theme.dynamic(runner == "service" ? .successText : runner == "none" ? .warningText : .textMuted)
        if let id, jobs.contains(where: { $0.id == id }) { selectedID = id } else { selectedID = jobs.first?.id }
        emptyBox.isHidden = !jobs.isEmpty
        let hadFocus = wantFocus || window?.firstResponder is ScheduleCardView
        rebuildGrid()
        if hadFocus, shown, window?.attachedSheet == nil { wantFocus = false; focusSelected() }
    }

    private func rebuildGrid() {
        for v in gridHost.arrangedSubviews { gridHost.removeArrangedSubview(v); v.removeFromSuperview() }
        cards = []
        let now = Date()
        for chunk in stride(from: 0, to: jobs.count, by: columns).map({ Array(jobs[$0 ..< min($0 + columns, jobs.count)]) }) {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12; row.distribution = .fillEqually; row.alignment = .top
            row.translatesAutoresizingMaskIntoConstraints = false
            for j in chunk {
                let c = ScheduleCardView(job: j, now: now, page: self)
                c.selected = j.id == selectedID
                c.onSelect = { [weak self] in self?.select(id: j.id) }
                c.onActivate = { [weak self] in self?.openEditor(j) }
                c.onMove = { [weak self] d in self?.moveSelection(d) }
                cards.append(c); row.addArrangedSubview(c)
            }
            for _ in chunk.count ..< columns { let pad = NSView(); pad.translatesAutoresizingMaskIntoConstraints = false; row.addArrangedSubview(pad) }
            gridHost.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: gridHost.widthAnchor).isActive = true
        }
    }

    private var wantFocus = false
    private func moveSelection(_ d: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == selectedID }) else { return }
        let n = min(max(i + d, 0), jobs.count - 1)
        select(id: jobs[n].id)
        if let c = cards.first(where: { $0.job.id == jobs[n].id }) { window?.makeFirstResponder(c) }
    }

    private func focusSelected() {
        if let c = cards.first(where: { $0.job.id == selectedID }) { window?.makeFirstResponder(c) }
    }

    private func select(id: String) {
        selectedID = id
        for c in cards { c.selected = c.job.id == id }
    }

    var selectedJob: ScheduleJob? { jobs.first { $0.id == selectedID } }

    // MARK: Actions

    @objc func newTapped() { openEditor(nil) }
    @objc func editTapped() { if let j = selectedJob { openEditor(j) } }
    @objc func historyTapped() { if let j = selectedJob { showHistory(j) } }
    @objc func runTapped() { if let j = selectedJob { runNow(j) } }
    @objc func deleteTapped() { if let j = selectedJob { delete(j, confirm: confirmDeletes) } }

    func openEditor(_ job: ScheduleJob?, target: ScheduleTarget? = nil) {
        let draft = job.map(ScheduleDraft.init) ?? target.map(ScheduleDraft.init(target:)) ?? ScheduleDraft()
        let ed = ScheduleEditor(store: store, draft: draft, isNew: job == nil)
        editor = ed
        ed.onDone = { [weak self] in self?.editor = nil; self?.wantFocus = true; self?.reload() }
        if let w = window { ed.present(on: w) }
    }

    func showHistory(_ j: ScheduleJob) {
        let h = ScheduleHistory(store: store, job: j)
        historyPanel = h
        h.onDone = { [weak self] in self?.historyPanel = nil; self?.focusSelected() }
        if let w = window { h.present(on: w) }
    }

    func runNow(_ j: ScheduleJob) {
        store.call("schedules.run_now", ["id": j.id]) { [weak self] r in
            if case let .failure(e) = r { self?.setMessage(describe(e)) } else { self?.setMessage("Started “\(j.name)”") }
            self?.reload()
        }
    }

    func setEnabled(_ j: ScheduleJob, _ on: Bool) {
        store.call("schedules.set_enabled", ["id": j.id, "enabled": on]) { [weak self] r in
            if case let .failure(e) = r { self?.setMessage(describe(e)) }
            self?.reload()
        }
    }

    func delete(_ j: ScheduleJob, confirm: Bool) {
        let go = { [weak self] in
            self?.store.call("schedules.delete", ["id": j.id]) { r in
                if case let .failure(e) = r { self?.setMessage(describe(e)) }
                self?.reload(keepSelection: false)
            }
            return
        }
        guard confirm, let w = window else { go(); return }
        let a = NSAlert()
        a.messageText = "Delete schedule"
        a.informativeText = j.runs > 0 ? "Delete “\(j.name)”? Its \(j.runs) saved run\(j.runs == 1 ? "" : "s") and their output are deleted too." : "Delete “\(j.name)”? It has no saved runs."
        a.alertStyle = .warning
        let del = a.addButton(withTitle: "Delete")
        del.hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { resp in if resp == .alertFirstButtonReturn { go() } }
    }

    func debugState() -> String {
        var lines = ["runner=\(runner)", "stats=\(stats.schedules)|\(stats.runs)|\(stats.successRate)|\(stats.lastFailure)", "banner=\(banner.stringValue)"]
        let now = Date()
        for j in jobs { lines.append("\(j.id)\t\(j.name)\t\(j.describe)\t\(j.stateLabel)\t\(j.enabled ? "on" : "off")\t\(j.nextRunText(now: now))\truns=\(j.runs)") }
        return lines.joined(separator: "\n")
    }

    func select(name: String) -> ScheduleJob? {
        guard let j = jobs.first(where: { $0.name == name || $0.id == name }) else { return nil }
        select(id: j.id)
        return j
    }
}

// MARK: - Editor sheet

final class ScheduleEditor: NSObject, NSTextFieldDelegate {
    unowned let store: Store
    private(set) var draft: ScheduleDraft
    let isNew: Bool
    let panel: EditorPanel
    var onDone: (() -> Void)?
    private weak var parent: NSWindow?

    let name = Kit.field("Nightly report", label: "Schedule name")
    let prompt = DialogTextView()
    let folder = Kit.field("/path/to/project", label: "Folder the prompt runs in")
    let kind = IconSegmented(options: ["Every few minutes", "Daily", "Weekly"])
    let minutes = Kit.field("60", label: "Minutes between runs")
    let timesBox = NSStackView()
    let daysBox = NSStackView()
    let promptHint = NSTextField(wrappingLabelWithString: "Summarize yesterday's commits and open PRs, then write it to docs/standup.md")
    let summary = ThemedText.plainHelper("")
    let error = NSTextField(wrappingLabelWithString: "")
    let enabled = ThemedSwitch(), bypass = ThemedSwitch(), chrome = ThemedSwitch()
    let timeout = Kit.field("30", label: "Timeout in minutes")
    let model = Kit.field("Default", label: "Model")
    let effort = ThemedSelect(["Default", "Low", "Medium", "High", "Xhigh", "Max"], selected: 0)
    let save: ModalButton
    private var timeFields: [NSTextField] = []
    private var dayButtons: [DayToggle] = []
    private var intervalRow: NSView!, timesRow: NSView!, daysRow: NSView!
    private(set) var saving = false

    init(store: Store, draft: ScheduleDraft, isNew: Bool) {
        self.store = store; self.draft = draft; self.isNew = isNew
        enabled.isOn = draft.enabled; bypass.isOn = draft.bypass; chrome.isOn = draft.chrome
        enabled.setSpokenLabel("On"); bypass.setSpokenLabel("Skip permission prompts"); chrome.setSpokenLabel("Browser (Claude in Chrome)")
        save = ModalButton(isNew ? "Create" : "Save", style: .primary, height: 32)
        panel = EditorPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.onSubmit = { [weak self] in self?.saveTapped() }
        panel.onCancel = { [weak self] in self?.cancelTapped() }
        panel.title = draft.target != nil ? (isNew ? "Schedule for session" : "Edit session schedule") : (isNew ? "New schedule" : "Edit schedule")
        build()
        load()
    }

    private func build() {
        for sw in [enabled, bypass, chrome] { sw.target = self; sw.action = #selector(controlChanged) }
        save.onClick = { [weak self] in self?.saveTapped() }
        let cancel = ModalButton("Cancel", height: 32); cancel.onClick = { [weak self] in self?.cancelTapped() }
        name.delegate = self; folder.delegate = self; minutes.delegate = self; timeout.delegate = self; model.delegate = self
        effort.plain = true; effort.setAccessibilityLabel("Effort")
        model.font = ThemeFont.mono(12)
        kind.target = self; kind.action = #selector(controlChanged)
        kind.setSpokenLabel("How often it runs")
        folder.font = ThemeFont.mono(12)
        prompt.isRichText = false
        prompt.font = ThemeFont.mono(12); prompt.textColor = Theme.dynamic(.text)
        prompt.drawsBackground = false; prompt.insertionPointColor = Theme.dynamic(.text)
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.delegate = self
        prompt.setAccessibilityLabel("Prompt")
        prompt.textContainerInset = NSSize(width: 6, height: 8)
        prompt.isVerticallyResizable = true
        prompt.autoresizingMask = [.width]
        let promptScroll = NSScrollView()
        promptScroll.documentView = prompt
        promptScroll.hasVerticalScroller = true; promptScroll.drawsBackground = false; promptScroll.borderType = .noBorder
        promptScroll.scrollerStyle = .overlay
        let promptFrame = InputFrame()
        promptFrame.translatesAutoresizingMaskIntoConstraints = false
        Kit.pin(promptScroll, in: promptFrame, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        promptFrame.heightAnchor.constraint(equalToConstant: 126).isActive = true
        promptHint.font = ThemeFont.mono(12); promptHint.textColor = Theme.dynamic(.textFaint)
        promptHint.maximumNumberOfLines = 0; promptHint.isSelectable = false
        promptHint.translatesAutoresizingMaskIntoConstraints = false
        promptFrame.addSubview(promptHint, positioned: .below, relativeTo: promptScroll)
        NSLayoutConstraint.activate([
            promptHint.topAnchor.constraint(equalTo: promptFrame.topAnchor, constant: 9), promptHint.leadingAnchor.constraint(equalTo: promptFrame.leadingAnchor, constant: 12),
            promptHint.trailingAnchor.constraint(equalTo: promptFrame.trailingAnchor, constant: -12),
        ])
        let choose = ModalButton("Choose…", icon: .folderOpen, height: 32, label: "Choose the folder")
        choose.onClick = { [weak self] in self?.chooseFolder() }

        timesBox.orientation = .vertical; timesBox.alignment = .leading; timesBox.spacing = 6
        let addTime = ModalButton("Add time", icon: .plus, height: 32, label: "Add another time of day")
        addTime.onClick = { [weak self] in self?.addTimeTapped() }
        daysBox.orientation = .horizontal; daysBox.spacing = 4
        for (i, d) in ScheduleJob.dayNames.enumerated() {
            let b = DayToggle(d, tag: i); b.target = self; b.action = #selector(controlChanged)
            dayButtons.append(b); daysBox.addArrangedSubview(b)
        }
        let every = Kit.hstack([Self.plainLabel("Every"), FieldBox(minutes, width: 84), Self.plainLabel("minutes"), ThemedText.plainHelper("(5 or more)")], spacing: 8)
        intervalRow = every
        let atRow = Kit.hstack([Self.plainLabel("at"), timesBox, addTime], spacing: 8, alignment: .top)
        timesRow = atRow
        daysRow = daysBox

        error.font = ThemeFont.sans(12); error.textColor = Theme.dynamic(.dangerText); error.maximumNumberOfLines = 0
        let schedBlock = Kit.vstack([kind, every, daysBox, atRow], spacing: 10)
        kind.translatesAutoresizingMaskIntoConstraints = false; kind.widthAnchor.constraint(equalTo: schedBlock.widthAnchor).isActive = true

        let hint = ThemedText.plainHelper("⌘ Enter to save"); hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        let frame = ModalFrame.make(title: panel.title, footerLeft: hint, footerRight: [cancel, save], width: 540, height: 620)
        let promptHelp = ThemedText.plainHelper(draft.target != nil
            ? "Typed into the session below at the chosen time, then Enter, as if you typed it. If the session is closed by then, the run fails and says so."
            : "Runs as claude -p in the folder below, with your Claude settings, MCP servers and skills.")
        let folderRow = Kit.hstack([FieldBox(folder), choose], spacing: 8)
        folderRow.distribution = .fill
        frame.add(frame.group("Name", FieldBox(name)))
        frame.add(frame.group("Prompt", promptFrame, helper: promptHelp))
        if let t = draft.target {
            let nameLine = NSTextField(labelWithString: t.name); nameLine.font = ThemeFont.sans(13); nameLine.textColor = Theme.dynamic(.text)
            let cwdLine = NSTextField(labelWithString: t.cwd); cwdLine.font = ThemeFont.mono(11); cwdLine.textColor = Theme.dynamic(.textFaint)
            cwdLine.lineBreakMode = .byTruncatingMiddle
            let box = Kit.vstack([nameLine, cwdLine], spacing: 2)
            box.setAccessibilityLabel("Target session \(t.name)")
            frame.add(frame.group("Session", ModalLayout.rowsBox([box], inset: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))))
        } else {
            frame.add(frame.group("Folder", folderRow))
        }
        frame.add(frame.group("Schedule", schedBlock, helper: summary))
        frame.add(ThemedText.label("Options"))
        var options = [ModalLayout.settingRow(title: "On", helper: nil, control: enabled)]
        if draft.target == nil {
            options += [
                ModalLayout.settingRow(title: "Skip permission prompts", helper: nil, control: bypass),
                ModalLayout.settingRow(title: "Browser (Claude in Chrome)", helper: nil, control: chrome),
                ModalLayout.settingRow(title: "Timeout (minutes)", helper: nil, control: FieldBox(timeout, width: 84)),
                ModalLayout.settingRow(title: "Model", helper: "opus, sonnet, haiku or a full model id", control: FieldBox(model, width: 180)),
                ModalLayout.settingRow(title: "Effort", helper: nil, control: FieldBox(effort, width: 120)),
            ]
        }
        frame.add(ModalLayout.rowsBox(options, inset: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)))
        frame.add(error)
        panel.contentView = frame.root
        panel.setAccessibilityLabel(panel.title)
        modalFrame = frame
    }

    private var modalFrame: ModalFrame?
    /// Today's rule: as tall as the form, at most 85 % of the viewport.
    private func fitHeight(host: NSWindow) {
        guard let f = modalFrame, let hc = f.root.constraints.first(where: { $0.firstAttribute == .height }) else { return }
        f.root.layoutSubtreeIfNeeded()
        let natural = 56 + f.body.fittingSize.height + 32 + 61
        hc.constant = min(natural, ((host.contentView?.bounds.height ?? 732) * 0.85).rounded())
        panel.setContentSize(NSSize(width: 540, height: hc.constant))
    }

    private static func plainLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.font = ThemeFont.sans(13); l.textColor = Theme.dynamic(.textTertiary); return l
    }

    private func load() {
        name.stringValue = draft.name
        prompt.string = draft.prompt
        folder.stringValue = draft.folder
        kind.selected = ["interval": 0, "daily": 1, "weekly": 2][draft.kind] ?? 1
        minutes.stringValue = "\(draft.minutes)"
        timeout.stringValue = "\(draft.timeoutMin)"
        model.stringValue = draft.model
        effort.selected = max(0, ScheduleDraft.efforts.firstIndex(of: draft.effort) ?? 0)
        for b in dayButtons { b.state = draft.days.contains(b.tag) ? .on : .off }
        rebuildTimes()
        syncVisibility()
    }

    /// Form -> draft (what the user typed). Numbers that are not numbers become 0 and are rejected by the daemon.
    func collect() {
        draft.name = name.stringValue
        draft.prompt = prompt.string
        draft.folder = folder.stringValue.trimmingCharacters(in: .whitespaces)
        draft.kind = ["interval", "daily", "weekly"][max(0, kind.selected)]
        draft.minutes = Int(minutes.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        draft.timeoutMin = Int(timeout.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        draft.times = timeFields.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
        draft.days = Set(dayButtons.filter { $0.state == .on }.map(\.tag))
        draft.enabled = enabled.isOn; draft.bypass = bypass.isOn; draft.chrome = chrome.isOn
        draft.model = model.stringValue.trimmingCharacters(in: .whitespaces)
        draft.effort = ScheduleDraft.efforts[max(0, min(effort.selected, ScheduleDraft.efforts.count - 1))]
    }

    private func syncVisibility() {
        let k = kind.selected
        intervalRow.isHidden = k != 0
        timesRow.isHidden = k == 0
        daysRow.isHidden = k != 2
        collect()
        summary.stringValue = draft.summary
        promptHint.isHidden = !prompt.string.isEmpty
    }

    private func rebuildTimes() {
        for v in timesBox.arrangedSubviews { timesBox.removeArrangedSubview(v); v.removeFromSuperview() }
        timeFields = []
        for (i, t) in draft.times.enumerated() {
            let f = Kit.field("09:30", label: "Time \(i + 1)")
            f.stringValue = t; f.delegate = self
            timeFields.append(f)
            var row: [NSView] = [FieldBox(f, width: 112)]
            if draft.times.count > 1 {
                let rm = ModalButton("Remove time", icon: .close, height: 32, label: "Remove time \(i + 1)")
                rm.tag = i; rm.onClick = { [weak self, weak rm] in if let rm { self?.removeTime(rm) } }
                row.append(rm)
            }
            timesBox.addArrangedSubview(Kit.hstack(row, spacing: 8))
        }
    }

    @objc func addTimeTapped() { collect(); draft.addTime(); rebuildTimes(); syncVisibility() }
    func removeTime(_ s: NSControl) { collect(); if draft.times.count > 1, s.tag < draft.times.count { draft.times.remove(at: s.tag) }; rebuildTimes(); syncVisibility() }
    @objc func controlChanged() { syncVisibility() }
    func controlTextDidChange(_ obj: Notification) { syncVisibility() }
    @objc func chooseFolder() {
        let p = NSOpenPanel()
        p.title = "Folder the prompt runs in"
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.beginSheetModal(for: panel) { [weak self] r in if r == .OK, let u = p.url { self?.folder.stringValue = u.path; self?.syncVisibility() } }
    }

    private var scrim: ModalScrim?
    func present(on window: NSWindow) {
        parent = window
        fitHeight(host: window)
        scrim = ModalScrim(over: window) {}   // today's overlay dims the app behind the dialog
        window.beginSheet(panel) { _ in }
        panel.makeFirstResponder(name)
    }

    @objc func cancelTapped() { close() }

    func close() {
        scrim?.remove(); scrim = nil
        if let p = parent { p.endSheet(panel) } else { panel.close() }
        onDone?()
    }

    /// Sets a form field the way typing would (test hook).
    func debugSet(_ field: String, _ value: String) -> Bool {
        switch field {
        case "name": name.stringValue = value
        case "prompt": prompt.string = value
        case "folder": folder.stringValue = value
        case "kind":
            guard let i = ["interval", "daily", "weekly"].firstIndex(of: value) else { return false }
            kind.selected = i
        case "minutes": minutes.stringValue = value
        case "timeout": timeout.stringValue = value
        case "model": model.stringValue = value
        case "scroll":   // "end": show the bottom of the form (screenshots)
            guard let sv = modalFrame?.body.enclosingScrollView, let doc = sv.documentView else { return false }
            sv.layoutSubtreeIfNeeded()
            doc.scroll(NSPoint(x: 0, y: value == "end" ? max(0, doc.frame.height - sv.contentView.bounds.height) : 0))
            return true
        case "effort":
            guard let i = ScheduleDraft.efforts.firstIndex(of: value == "default" ? "" : value) else { return false }
            effort.selected = i
        case "times":
            collect(); draft.times = value.split(separator: ",").map(String.init); rebuildTimes()
        case "days":
            for b in dayButtons { b.state = value.split(separator: ",").compactMap { Int($0) }.contains(b.tag) ? .on : .off }
        case "on": enabled.isOn = value == "on"
        case "bypass": bypass.isOn = value == "on"
        case "chrome": chrome.isOn = value == "on"
        default: return false
        }
        syncVisibility()
        return true
    }

    func debugState() -> String {
        collect()
        return "title=\(panel.title) saving=\(saving) error=\(error.stringValue)\nkind=\(draft.kind) times=\(draft.times.joined(separator: ",")) days=\(draft.days.sorted()) summary=\(summary.stringValue)"
    }

    /// Saves through muyad; a validation message stays in the sheet, a success closes it.
    @objc func saveTapped() { submit() }

    func submit(completion: ((String?) -> Void)? = nil) {
        guard !saving else { return }
        collect()
        saving = true
        save.title = "Saving…"
        error.stringValue = ""
        store.call("schedules.save", draft.toParams()) { [weak self] r in
            guard let self else { return }
            self.saving = false
            self.save.title = self.isNew ? "Create" : "Save"
            switch r {
            case .success: completion?(nil); self.close()
            case let .failure(e): self.error.stringValue = describe(e); completion?(describe(e))
            }
        }
    }
}

extension ScheduleEditor: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { syncVisibility() }
}

// MARK: - History sheet

final class ScheduleHistory: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    unowned let store: Store
    let job: ScheduleJob
    let panel: EditorPanel
    private let table = KeyTable()
    private let output = NSTextView()
    private let empty = ThemedText.plainHelper("No runs yet. Use Run now on the card to try it.")
    private(set) var runs: [ScheduleRun] = []
    var onDone: (() -> Void)?
    private weak var parent: NSWindow?

    init(store: Store, job: ScheduleJob) {
        self.store = store; self.job = job
        panel = EditorPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "History · \(job.name)"
        panel.setAccessibilityLabel(panel.title)
        for (id, title, w) in [("when", "Started", 170), ("status", "Status", 80), ("how", "Trigger", 80), ("dur", "Duration", 90), ("cost", "Cost", 60)] as [(String, String, CGFloat)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); c.title = title; c.width = w
            table.addTableColumn(c)
        }
        table.headerView = nil
        do {
        }
        table.dataSource = self; table.delegate = self
        table.rowHeight = 24
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.textContainerInset = NSSize(width: 6, height: 6)
        output.setAccessibilityLabel("Run output")
        table.backgroundColor = .clear; table.style = .plain
        let tableScroll = Kit.scroll(table, label: "Run history")
        tableScroll.scrollerStyle = .overlay
        output.drawsBackground = false; output.textColor = Theme.dynamic(.text); output.font = ThemeFont.mono(11)
        let outScroll = NSScrollView(); outScroll.documentView = output; outScroll.hasVerticalScroller = true; outScroll.borderType = .noBorder
        outScroll.drawsBackground = false; outScroll.scrollerStyle = .overlay
        let tableBox = ThemedBox(.card), outBox = ThemedBox(.card)
        for (box, sc) in [(tableBox, tableScroll), (outBox, outScroll)] { box.translatesAutoresizingMaskIntoConstraints = false; Kit.pin(sc, in: box, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)) }
        tableBox.heightAnchor.constraint(equalToConstant: 180).isActive = true
        outBox.heightAnchor.constraint(equalToConstant: 200).isActive = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        tableBox.addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: tableBox.centerXAnchor), empty.centerYAnchor.constraint(equalTo: tableBox.centerYAnchor)])
        let close = ModalButton("Close", height: 32); close.onClick = { [weak self] in self?.closeTapped() }
        panel.onCancel = { [weak self] in self?.closeTapped() }
        let frame = ModalFrame.make(title: panel.title, footerLeft: ThemedText.plainHelper("The last 100 runs are kept."), footerRight: [close], width: 640, height: 560)
        frame.add(frame.group("Runs", tableBox)); frame.add(frame.group("Output", outBox))
        let root = frame.root
        panel.contentView = root
    }

    func present(on window: NSWindow) {
        parent = window
        window.beginSheet(panel) { _ in }
        load()
        panel.makeFirstResponder(table)
    }

    func load() {
        store.call("schedules.runs", ["id": job.id]) { [weak self] r in
            guard let self else { return }
            if case let .success(v) = r { self.runs = jsonObjects(v).compactMap(ScheduleRun.init(json:)) }
            self.table.reloadData()
            self.empty.isHidden = !self.runs.isEmpty
            if !self.runs.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false) }
            self.showOutput()
        }
    }

    private func showOutput() {
        let r = table.selectedRow
        output.string = r >= 0 && r < runs.count ? (runs[r].output.isEmpty ? "(no output)" : runs[r].output) : ""
    }

    @objc func closeTapped() { close() }
    func close() { if let p = parent { p.endSheet(panel) } else { panel.close() }; onDone?() }

    func numberOfRows(in tableView: NSTableView) -> Int { runs.count }
    func tableViewSelectionDidChange(_ notification: Notification) { showOutput() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, row < runs.count else { return nil }
        let r = runs[row]
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM HH:mm:ss"
        let text: String
        var color = Token.text
        switch id {
        case "when": text = f.string(from: Date(timeIntervalSince1970: Double(r.started) / 1000))
        case "status": text = r.statusLabel; color = r.status == "success" ? Token.success : Token.danger
        case "how": text = r.triggerLabel
        case "dur": text = r.duration
        default: text = r.costUsd.map { String(format: "$%.2f", $0) } ?? "—"
        }
        let l = NSTextField(labelWithString: text); l.font = ThemeFont.sans(12); l.textColor = color
        let cell = NSTableCellView()
        Kit.pin(l, in: cell, insets: NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2))
        cell.setAccessibilityLabel("\(tableColumn?.title ?? ""): \(text)")
        return cell
    }

    func debugState() -> String {
        runs.map { "\($0.statusLabel)\t\($0.triggerLabel)\t\($0.duration)" }.joined(separator: "\n")
    }
}
