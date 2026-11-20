// Split Control actions of the main controller (today's App.tsx "Split Control", ~2067–2145): Split (⌘⇧D / header button) opens a clone
// next to the selected session, closing a pane leaves the group (the session keeps running), focus/zoom a pane, drag a session onto
// another to group them, collapse a group in the agent list. State lives in `splitModel` and is persisted under today's keys.

import AppKit

extension MainController {
    func wireSplit() {
        splitModel.load(store.legacy)
        splitModel.onChange = { [weak self] in
            guard let self else { return }
            self.splitModel.save(self.store.legacy)
            self.agentsPanel.reload()
            self.refreshTiles()
        }
        let chrome = tileView.splitChrome!
        chrome.onFocus = { [weak self] s in if s !== self?.store.selected { self?.store.select(s) } }
        chrome.onClose = { [weak self] s in self?.closeSplitPane(s) }
        chrome.onZoom = { [weak self] s in self?.toggleSplitZoom(s) }
        chrome.onFractions = { [weak self] f in
            guard let self, let g = self.splitModel.group(of: self.store.selected) else { return }
            self.splitModel.fractions[g.id] = f
        }
        sessionBar.onSplit = { [weak self] in self?.addSplitPane() }
        agentsPanel.splitGroups = { [weak self] in self?.splitModel.groups ?? [] }
        agentsPanel.splitCollapsed = { [weak self] in self?.splitModel.collapsed ?? [] }
        agentsPanel.onToggleGroup = { [weak self] id in
            guard let m = self?.splitModel else { return }
            if m.collapsed.contains(id) { m.collapsed.remove(id) } else { m.collapsed.insert(id) }
            m.onChange?()
        }
        agentsPanel.onSelectGroup = { [weak self] id in
            guard let self, let g = self.splitModel.groups.first(where: { $0.id == id }) else { return }
            self.showPage(nil)
            if let s = self.store.selected, g.keys.contains(SplitModel.key(s)) { return }
            if let s = g.keys.compactMap({ k in self.store.sessions.first { SplitModel.key($0) == k } }).first { self.store.select(s) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(daemonEventForSplit(_:)), name: Store.eventNotification, object: store)
        agentsPanel.onGroup = { [weak self] from, to in self?.groupSessions(from: from, to: to) }
        agentsPanel.onGroupInto = { [weak self] from, gid in self?.groupSessionInto(from: from, groupID: gid) }
        agentsPanel.onUngroup = { [weak self] id in self?.ungroupSession(id) }
        agentsPanel.onReorder = { [weak self] from, to in self?.reorderSessions(from: from, to: to) }
    }

    var canSplitSelected: Bool {
        guard let s = store.selected, s.exited == nil, !gridMode else { return false }
        return SplitLogic.canSplit(splitModel.groups, SplitModel.key(s))
    }

    /// ⌘⇧D / the header's Split: the selected session is cloned next to it and the clone joins its group (App.tsx addSplitPane + lib/tabs.ts splitClone).
    /// A running Claude forks its conversation (`--resume <id> --fork-session`), another running agent starts afresh, a plain shell stays a shell.
    @objc func addSplitPane() {
        guard canSplitSelected, let src = store.selected else { return }
        if currentPage != nil { showPage(nil) }
        let live = SessionModel.currentDirectory(of: src.pid)
        let cwd = [live, src.cwd].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) } ?? store.home
        let agent: String? = src.kind == "opencode" ? "opencode" : (src.screen?.modeDetected == true || src.kind == "claude") ? "claude" : nil
        let begin = { [weak self] (sid: String?, scwd: String?) in
            guard let self, self.store.sessions.contains(where: { $0 === src }) else { return }
            let spec = SplitLogic.cloneSpec(name: src.name, agent: agent, sessionId: sid, sessionCwd: scwd.flatMap { $0 == cwd ? nil : $0 })
            self.splitModel.pendingAnchor = SplitModel.key(src)
            self.splitModel.pendingKnownIds = Set(self.store.sessions.map(\.id))
            if let c = spec.command { self.store.openShell(cwd: cwd, name: spec.name, typing: c) } else { self.store.spawn(cwd: cwd, name: spec.name) }
            if self.splitModel.pendingAnchor != nil { self.splitAdoptPending() }   // spawn failed or came back without a delegate call
            self.splitModel.pendingAnchor = nil
        }
        guard agent == "claude" else { begin(nil, nil); return }
        // Which conversation is running in this terminal? `claude agents` lists them with their folder; the one under this shell wins.
        agents.refresh { r in
            var sid: String?, scwd: String?
            if case let .success(rows) = r {
                let here = rows.filter { $0.status != "stopped" && ($0.cwd == cwd || $0.cwd == src.cwd) }
                let mine = here.first { $0.pid.map { Self.isDescendant($0, of: src.pid) } ?? false } ?? (here.count == 1 ? here[0] : nil)
                sid = mine?.sessionId; scwd = mine?.cwd
            }
            begin(sid, scwd)
        }
    }

    /// Is process `pid` the shell `ancestor` or one of its descendants?
    static func isDescendant(_ pid: Int32, of ancestor: Int32) -> Bool {
        var p = pid
        for _ in 0 ..< 12 {
            if p == ancestor { return true }
            var info = proc_bsdinfo()
            guard proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_ppid > 1 else { return false }
            p = Int32(info.pbi_ppid)
        }
        return false
    }

    /// The clone that arrived after Split joins the group of the session it was split off.
    func splitAdoptPending() {
        guard let anchor = splitModel.pendingAnchor, let new = store.sessions.last(where: { !splitModel.pendingKnownIds.contains($0.id) }) else { return }
        splitModel.pendingAnchor = nil
        if let next = SplitLogic.addToGroup(splitModel.groups, source: anchor, clone: SplitModel.key(new), newId: "split-group-\(new.id)-\(Int(Date().timeIntervalSince1970))") {
            splitModel.groups = next
            splitModel.save(store.legacy)
        }
    }

    /// × on a pane: the session leaves its group and keeps running; focus moves to the neighbour pane.
    func closeSplitPane(_ s: SessionModel) {
        guard let g = splitModel.group(of: s) else { return }
        let nb = SplitLogic.neighbourAfterClose(g.keys, closed: SplitModel.key(s))
        splitModel.groups = SplitLogic.removeFromGroups(splitModel.groups, SplitModel.key(s))
        splitModel.zoom = nil
        splitModel.save(store.legacy)
        if s === store.selected, let nb, let n = store.sessions.first(where: { SplitModel.key($0) == nb }) { store.select(n) } else { agentsPanel.reload(); refreshTiles() }
    }

    /// A pane's focus / restore button: show only that pane (the others keep running), or back to the whole split.
    func toggleSplitZoom(_ s: SessionModel) {
        if splitModel.zoom == s.id { splitModel.zoom = nil } else { splitModel.zoom = s.id }
        if s !== store.selected { store.select(s) } else { refreshTiles() }
    }

    /// Drag-to-group: `from` dropped onto `to` joins its split, which then shows at once with `to` focused.
    func groupSessions(from: UInt64, to: UInt64) {
        guard let f = store.sessions.first(where: { $0.id == from }), let t = store.sessions.first(where: { $0.id == to }),
              let next = SplitLogic.joinGroup(splitModel.groups, from: SplitModel.key(f), to: SplitModel.key(t), newId: "split-group-\(from)-\(to)") else { return }
        splitModel.groups = next
        splitModel.save(store.legacy)
        if t === store.selected { agentsPanel.reload(); refreshTiles() } else { store.select(t) }
    }

    /// A session dropped on a split's header row joins that split and shows at once (App.tsx groupInto → groupAgents with the first pane).
    func groupSessionInto(from: UInt64, groupID: String) {
        guard let g = splitModel.groups.first(where: { $0.id == groupID }), let k = g.keys.first, let to = store.sessions.first(where: { SplitModel.key($0) == k }) else { return }
        groupSessions(from: from, to: to.id)
    }

    /// A split member dropped on the list's empty space leaves its split and is a page of its own again (the session keeps running).
    func ungroupSession(_ id: UInt64) {
        guard let s = store.sessions.first(where: { $0.id == id }), splitModel.group(of: s) != nil else { return }
        splitModel.groups = SplitLogic.removeFromGroups(splitModel.groups, SplitModel.key(s))
        splitModel.zoom = nil
        splitModel.save(store.legacy)
        agentsPanel.reload(); refreshTiles()
    }

    /// Dropped on a row's top / bottom quarter: the row takes that place; a split member moved among loose sessions leaves its split (App.tsx reorderOrUngroup).
    func reorderSessions(from: UInt64, to: UInt64) {
        guard let f = store.sessions.first(where: { $0.id == from }), let t = store.sessions.first(where: { $0.id == to }) else { return }
        if SplitLogic.leavesSplitOnReorder(splitModel.groups, from: SplitModel.key(f), to: SplitModel.key(t)) { ungroupSession(from) }
        store.moveSession(f, to: t)
    }

    // MARK: Agent open_session (muya-mcp → muyad broker → `muya://open-agent-session`)

    @objc func daemonEventForSplit(_ n: Notification) {
        if (n.userInfo?["name"] as? String) == "muya://typed-by", let raw = n.userInfo?["payload"] as? String,
           let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
            // Visible audit marker: another session typed into a tab (docs: agent injection audit).
            let by = (obj["by"] as? String) ?? "unverified session"
            let target = (obj["targetName"] as? String) ?? "a tab"
            Toasts.center?.show(title: "Typed by \(by)", message: "Into \(target) (\(obj["bytes"] as? Int ?? 0) bytes).", seconds: 5)
            return
        }
        guard (n.userInfo?["name"] as? String) == "muya://open-agent-session", let payload = n.userInfo?["payload"] as? String, let req = OpenAgentSession(payload: payload) else { return }
        openAgentSession(req)
    }

    /// A new terminal runs the agent. With `splitWith` (the caller's Claude session id) it opens as a pane next to the caller's terminal when
    /// that terminal is found (its folder, via `claude agents`) and its group has room; otherwise as a plain session.
    func openAgentSession(_ req: OpenAgentSession, anchor forced: SessionModel? = nil) {
        let dir = (req.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }) ?? store.selected?.cwd ?? store.home
        func start(anchor: SessionModel?) {
            let opener = req.openedBy.flatMap { _ in anchor?.name }
            if let a = anchor, SplitLogic.canSplit(splitModel.groups, SplitModel.key(a)) {
                splitModel.pendingAnchor = SplitModel.key(a)
                splitModel.pendingKnownIds = Set(store.sessions.map(\.id))
            }
            showPage(nil)
            let known = Set(store.sessions.map(\.id))
            store.openShell(cwd: dir, name: req.name, typing: req.command(openerName: opener))
            if let s = store.sessions.last(where: { !known.contains($0.id) }) { store.markOpened(s, by: opener ?? "another session") }
            splitAdoptPending(); splitModel.pendingAnchor = nil
        }
        if let forced { start(anchor: forced); return }   // test hook: the caller's terminal is known
        guard let sid = req.splitWith else { start(anchor: nil); return }
        agents.refresh { [weak self] r in
            guard let self else { return }
            var anchor: SessionModel?
            if case let .success(rows) = r, let row = rows.first(where: { $0.sessionId == sid }) {
                let live = self.store.sessions.filter { $0.exited == nil && $0.cwd == row.cwd }
                anchor = (self.store.selected.flatMap { s in live.contains { $0 === s } ? s : nil }) ?? live.first
            }
            start(anchor: anchor)
        }
    }
}
