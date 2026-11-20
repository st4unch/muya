// Split groups of the Control view (port of src/lib/controlSplit.ts): a group shows as 2–8 panes next to each other and as one
// collapsible row in the agent list. Pure functions over `[SplitGroup]`, no UI. Keys are strings (the app uses the session's key).

import Foundation

public struct SplitGroup: Equatable, Sendable {
    public var id: String
    public var keys: [String]
    public init(id: String, keys: [String]) { self.id = id; self.keys = keys }
}

public enum SplitLogic {
    public static let maxSplit = 8

    /// Columns × rows for `n` panes: 2 → 2×1, 3 → 3×1, 4 → 2×2, 5–6 → 3×2, 7–8 → 4×2.
    public static func layout(_ n: Int) -> (cols: Int, rows: Int) {
        if n <= 1 { return (1, 1) }
        if n <= 3 { return (n, 1) }
        if n == 4 { return (2, 2) }
        if n <= 6 { return (3, 2) }
        return (4, 2)
    }

    public static func groupOf(_ groups: [SplitGroup], _ key: String?) -> SplitGroup? {
        guard let key else { return nil }
        return groups.first { $0.keys.contains(key) }
    }

    /// Is there room to split `source` again? (Its group is not full.)
    public static func canSplit(_ groups: [SplitGroup], _ source: String?) -> Bool {
        guard let source else { return false }
        return (groupOf(groups, source)?.keys.count ?? 1) < maxSplit
    }

    /// `clone` was split off `source`: it joins `source`'s group, or the two start a new group `newId`. Nil when the group is full.
    public static func addToGroup(_ groups: [SplitGroup], source: String, clone: String, newId: String) -> [SplitGroup]? {
        if clone == source || groupOf(groups, clone) != nil { return nil }
        guard let g = groupOf(groups, source) else { return groups + [SplitGroup(id: newId, keys: [source, clone])] }
        if g.keys.count >= maxSplit { return nil }
        return groups.map { $0.id == g.id ? SplitGroup(id: $0.id, keys: $0.keys + [clone]) : $0 }
    }

    /// `open_session(split: true)`: the groups with `newKey` joined to the caller's terminal (`splitWith` = the caller's Claude session id),
    /// or nil (unknown id, its tab not open, or its group full): the session then opens as a plain tab.
    public static func splitForOpenSession(_ groups: [SplitGroup], splitWith: String?, sessionIdToKey: [String: String], openKeys: Set<String>, newKey: String, newId: String) -> [SplitGroup]? {
        guard let w = splitWith, let anchor = sessionIdToKey[w], openKeys.contains(anchor) else { return nil }
        return addToGroup(groups, source: anchor, clone: newKey, newId: newId)
    }

    /// Drag-to-group: `from` dropped onto `to`. `from` leaves its own group (one left alone dissolves) and joins `to`'s group, or the two
    /// start group `newId`. Nil when nothing would change or `to`'s group is full.
    public static func joinGroup(_ groups: [SplitGroup], from: String, to: String, newId: String) -> [SplitGroup]? {
        if from == to { return nil }
        let target = groupOf(groups, to)
        if target?.keys.contains(from) == true { return nil }
        if let t = target, t.keys.count >= maxSplit { return nil }
        return addToGroup(removeFromGroups(groups, from), source: to, clone: from, newId: newId)
    }

    /// A pane closed (or its tab closed): the terminal leaves its group; a group left with one terminal dissolves.
    public static func removeFromGroups(_ groups: [SplitGroup], _ key: String) -> [SplitGroup] {
        groups.map { $0.keys.contains(key) ? SplitGroup(id: $0.id, keys: $0.keys.filter { $0 != key }) : $0 }.filter { $0.keys.count > 1 }
    }

    /// Pane to focus after `closed` leaves `keys`: its right neighbour, else its left one.
    public static func neighbourAfterClose(_ keys: [String], closed: String) -> String? {
        guard let i = keys.firstIndex(of: closed) else { return nil }
        if i + 1 < keys.count { return keys[i + 1] }
        return i > 0 ? keys[i - 1] : nil
    }

    /// Groups against the tabs that exist: drop closed tabs and keys already claimed by an earlier group, cap at 8, dissolve groups under two.
    public static func resolve(_ groups: [SplitGroup], existing: Set<String>) -> [SplitGroup] {
        var claimed = Set<String>(), out: [SplitGroup] = []
        for g in groups {
            var keys: [String] = []
            for k in g.keys where existing.contains(k) && !claimed.contains(k) && keys.count < maxSplit { keys.append(k) }
            if keys.count < 2 { continue }
            keys.forEach { claimed.insert($0) }
            out.append(SplitGroup(id: g.id, keys: keys))
        }
        return out
    }

    /// The persisted form (`muya.splitGroups`: `[{"id":…,"keys":[…]}]`), tolerant like asSplitGroups.
    public static func decode(_ raw: Any?) -> [SplitGroup]? {
        guard let arr = raw as? [Any] else { return nil }
        return arr.compactMap { e in
            guard let d = e as? [String: Any], let id = d["id"] as? String, let keys = d["keys"] as? [Any] else { return nil }
            return SplitGroup(id: id, keys: keys.compactMap { $0 as? String })
        }
    }
    public static func encode(_ groups: [SplitGroup]) -> [[String: Any]] { groups.map { ["id": $0.id, "keys": $0.keys] } }

    // MARK: Agent-list drag and drop (src/redesign/AgentList.tsx dropModeAt, App.tsx groupInto / reorderOrUngroup / reorderAgents)

    public enum DropMode: Equatable, Sendable { case reorder, group }

    /// The middle half of a row groups, its top and bottom quarters reorder (`y` measured from the row's top).
    public static func dropMode(y: Double, height: Double) -> DropMode { y > height * 0.25 && y < height * 0.75 ? .group : .reorder }

    /// A session dropped on a split's header row joins that split (App.tsx groupInto: it is grouped with the first pane).
    public static func groupInto(_ groups: [SplitGroup], from: String, groupId: String, newId: String) -> [SplitGroup]? {
        guard let g = groups.first(where: { $0.id == groupId }), let first = g.keys.first else { return nil }
        return joinGroup(groups, from: from, to: first, newId: newId)
    }

    /// Dragging a split member between loose sessions takes it out of its split (App.tsx reorderOrUngroup).
    public static func leavesSplitOnReorder(_ groups: [SplitGroup], from: String, to: String) -> Bool {
        groupOf(groups, from) != nil && groupOf(groups, to) == nil
    }

    /// App.tsx reorderAgents: `from` is taken out and put where `to` is (the index re-found after the removal). Unchanged for unknown keys.
    public static func reorder<T: Equatable>(_ items: [T], from: T, to: T) -> [T] {
        guard from != to, let fi = items.firstIndex(of: from) else { return items }
        var next = items; let moved = next.remove(at: fi)
        guard let ti = next.firstIndex(of: to) else { return items }
        next.insert(moved, at: ti)
        return next
    }

    /// Order an `order` list (saved keys) imposes on `keys`; keys it does not know keep their relative order at the end.
    public static func applyOrder(_ keys: [String], saved: [String]) -> [String] {
        let pos = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return keys.enumerated().sorted { a, b in
            switch (pos[a.element], pos[b.element]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// What Split types into the clone (lib/tabs.ts splitClone): a running Claude whose session id is known forks that conversation
    /// (`--resume <id> --fork-session`, "<name> (fork)"), any other running agent starts afresh, a plain shell stays a plain shell.
    /// Every clone but the fork keeps the source's name.
    public struct SplitClone: Equatable, Sendable {
        public var name: String
        public var command: String?
        public var forked: Bool
    }
    public static let claudeBase = "claude --permission-mode auto"
    public static let opencodeBase = "opencode --auto"
    public static func isSafeSessionId(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { ("A" ... "Z").contains($0) || ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }
    public static func cloneSpec(name: String, agent: String?, sessionId: String?, sessionCwd: String?) -> SplitClone {
        guard let agent else { return SplitClone(name: name, command: nil, forked: false) }
        if agent == "claude", let id = sessionId, isSafeSessionId(id) {
            let fork = "claude --resume \(OpenAgentSession.quote(id)) --fork-session --permission-mode auto"
            return SplitClone(name: "\(name) (fork)", command: sessionCwd.map { "cd \(OpenAgentSession.quote($0)) && \(fork)" } ?? fork, forked: true)
        }
        return SplitClone(name: name, command: agent == "opencode" ? opencodeBase : claudeBase, forked: false)
    }

    /// Pane widths as fractions that sum to 1: the divider between pane i and i+1 moved by `delta` (fraction of the width), each pane >= `minFraction`.
    public static func moveDivider(_ fractions: [Double], index i: Int, delta: Double, minFraction: Double = 0.1) -> [Double] {
        guard fractions.indices.contains(i), fractions.indices.contains(i + 1) else { return fractions }
        var f = fractions
        let total = f[i] + f[i + 1]
        let a = min(max(f[i] + delta, minFraction), total - minFraction)
        f[i] = a; f[i + 1] = total - a
        return f
    }
}

/// `muya://open-agent-session` (agent `open_session`): the payload and the command typed into the new terminal (src/App.tsx:1154–1190,
/// src/lib/agent.ts unattendedFlags / openedByNote / buildAgentCommand).
public struct OpenAgentSession: Equatable, Sendable {
    public var name: String, cwd: String?, initialMessage: String?, agent: String
    public var splitWith: String?, openedBy: String?, unattended: Bool

    public init?(payload: String) {
        guard let d = payload.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let n = o["name"] as? String, !n.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        name = n; cwd = o["cwd"] as? String; initialMessage = o["initialMessage"] as? String
        agent = (o["agent"] as? String) == "opencode" ? "opencode" : "claude"
        splitWith = o["splitWith"] as? String; openedBy = o["openedBy"] as? String
        unattended = (o["unattended"] as? Bool) ?? true
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The shell command of the new session. `openerName`: the opener's tab name, when known.
    public func command(openerName: String?) -> String {
        let who = openerName.map { "session \"\($0)\"" } ?? "another Claude session"
        let headless = agent == "claude" && unattended
        var base: String
        if agent == "claude" {
            base = "claude --permission-mode auto"
            if headless {
                let report = openedBy.map { "If you hit any problem or need a decision you can't make, ask \(who) that opened you, not the operator: send_to_session(target: \"\($0)\", deliver: \"muya\"). When you finish, report there too with a short summary of what you did." }
                    ?? "Put a short summary of what you did, or what blocks you, in your final answer."
                let prompt = "You were opened by \(who) through Muya and run unattended: the operator is not watching this terminal. Do not ask the operator questions and do not ask for plan approval; make reasonable decisions yourself and keep going. " + report
                base += " --disallowedTools AskUserQuestion,EnterPlanMode,ExitPlanMode --append-system-prompt \(Self.quote(prompt))"
            }
            base += " --name \(Self.quote(name))"
        } else { base = "opencode --auto" }
        let msg = (initialMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = headless && !msg.isEmpty ? "[Opened by \(openerName.map { "session \"\($0)\"" } ?? "another session"). If anything goes wrong, ask \(openerName.map { "session \"\($0)\"" } ?? "another session"), not the operator.] \(msg)" : msg
        if text.isEmpty { return base }
        return agent == "opencode" ? "\(base) --prompt \(Self.quote(text))" : "\(base) \(Self.quote(text))"
    }
}
