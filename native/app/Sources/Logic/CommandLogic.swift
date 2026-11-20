// The session header's "Command" dialog (docs/prd-command-broadcast.md): who receives the text and how a result row reads.
// Pure functions, no UI, so the unit tests reach them (Tests/CommandTests.swift).

import Foundation

public enum CommandTarget: Int, CaseIterable, Sendable {
    case this, group, pick, all
    public var title: String { ["This session", "This group", "Pick sessions", "All sessions"][rawValue] }
}

/// One open terminal as the dialog sees it.
public struct CommandCandidate: Equatable, Sendable {
    public var id: UInt64
    public var name: String
    /// A Claude (or opencode) agent runs in it: only these take a prompt or a slash command.
    public var isAgent: Bool
    public var exited: Bool
    public init(id: UInt64, name: String, isAgent: Bool, exited: Bool = false) { self.id = id; self.name = name; self.isAgent = isAgent; self.exited = exited }
    public var receives: Bool { isAgent && !exited }
}

public enum CommandLogic {
    public static let presets = ["/compact", "/clear", "/model sonnet", "/cost"]
    /// The daemon's own limit (muya-core broker MAX_OPERATOR_TARGETS).
    public static let maxTargets = 64

    /// The terminal ids a send goes to, in the order of `all` (the sidebar order). Only live agent terminals receive:
    /// a shell would run the text as a command. `groupIds` is the current session's split group (nil = not in a group,
    /// which then means just this session).
    public static func resolve(_ target: CommandTarget, current: UInt64?, groupIds: [UInt64]?, picked: Set<UInt64>, all: [CommandCandidate]) -> [UInt64] {
        let live = all.filter(\.receives)
        let ids: [UInt64]
        switch target {
        case .this: ids = current.map { c in live.filter { $0.id == c }.map(\.id) } ?? []
        case .group:
            guard let groupIds else { return resolve(.this, current: current, groupIds: nil, picked: picked, all: all) }
            let set = Set(groupIds)
            ids = live.filter { set.contains($0.id) }.map(\.id)
        case .pick: ids = live.filter { picked.contains($0.id) }.map(\.id)
        case .all: ids = live.map(\.id)
        }
        return Array(ids.prefix(maxTargets))
    }

    /// "Send to 3 sessions" / "Send to 1 session" / "Send".
    public static func sendTitle(count n: Int) -> String { n == 0 ? "Send" : "Send to \(n) session\(n == 1 ? "" : "s")" }

    public static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// What the daemon says happened to one terminal (`sessions.send_command`).
public struct CommandResult: Equatable, Sendable {
    public enum State: String, Sendable { case submitted, queued, sent, skipped, failed }
    public var id: UInt64
    public var name: String
    public var state: State
    public var reason: String?
    public init(id: UInt64, name: String, state: State, reason: String? = nil) { self.id = id; self.name = name; self.state = state; self.reason = reason }

    /// The word on the result row.
    public var label: String {
        switch state {
        case .submitted: return "Submitted"
        case .queued: return "Queued (busy)"
        case .sent: return "Sent"
        case .skipped: return "Skipped (waiting on a dialog)"
        case .failed: return "Failed"
        }
    }

    /// `{"results":[{id,name,state,reason}]}` from the daemon. A row with an unknown state counts as failed, never as success.
    public static func parse(_ v: Any) -> [CommandResult] {
        let rows = ((v as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return rows.map { r in
            let id = (r["id"] as? NSNumber)?.uint64Value ?? 0
            let state = (r["state"] as? String).flatMap(State.init(rawValue:))
            return CommandResult(id: id, name: (r["name"] as? String) ?? "#\(id)", state: state ?? .failed,
                                 reason: (r["reason"] as? String) ?? (state == nil ? "unknown answer from the daemon" : nil))
        }
    }

    /// The rows with the names the operator sees in the app (a tab can be renamed there); the daemon's name stays when the id is unknown.
    public static func named(_ rs: [CommandResult], by candidates: [CommandCandidate]) -> [CommandResult] {
        rs.map { r in
            var r = r
            if let c = candidates.first(where: { $0.id == r.id }) { r.name = c.name }
            return r
        }
    }

    /// A request that never got an answer (daemon down, timeout): the same failure on every target row.
    public static func allFailed(_ targets: [CommandCandidate], reason: String) -> [CommandResult] {
        targets.map { CommandResult(id: $0.id, name: $0.name, state: .failed, reason: reason) }
    }

    /// "2 submitted · 1 skipped" for the dialog footer.
    public static func summary(_ rs: [CommandResult]) -> String {
        let order: [State] = [.submitted, .sent, .queued, .skipped, .failed]
        return order.compactMap { s in let n = rs.filter { $0.state == s }.count; return n == 0 ? nil : "\(n) \(s.rawValue)" }.joined(separator: " · ")
    }
}
