// The calls the Resources page and the slash popover make to muyad (`resources.*`, `slash.*`, `term_history.*`,
// `statusline.*`), over the same abstract `SSHRpc` the SSH page uses.

import Foundation

@MainActor
final class ResourcesService {
    private let rpc: SSHRpc
    init(rpc: SSHRpc) { self.rpc = rpc }

    func list(_ done: @escaping @MainActor (Result<ClaudeResources, RpcFailure>) -> Void) {
        rpc.call("resources.list", [:]) { r in
            switch r {
            case let .success(v): done(ClaudeResources(json: v).map { .success($0) } ?? .failure(RpcFailure(message: "unexpected answer")))
            case let .failure(e): done(.failure(e))
            }
        }
    }

    func marketSkills(_ query: String, _ done: @escaping @MainActor (Result<[MarketSkill], RpcFailure>) -> Void) {
        rpc.call("resources.skills_market", ["query": query]) { done($0.map { (($0 as? [[String: Any]]) ?? []).compactMap(MarketSkill.init(json:)) }) }
    }

    func marketMcps(_ query: String, _ done: @escaping @MainActor (Result<MarketMcpResult, RpcFailure>) -> Void) {
        rpc.call("resources.mcp_market", ["query": query]) { r in
            switch r {
            case let .success(v): done(MarketMcpResult(json: v).map { .success($0) } ?? .failure(RpcFailure(message: "unexpected answer")))
            case let .failure(e): done(.failure(e))
            }
        }
    }

    func installSkill(_ s: MarketSkill, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        rpc.call("resources.install_skill", ["name": s.name, "githubUrl": s.githubUrl]) { done($0.map { _ in () }) }
    }

    func installMcp(_ m: MarketMcp, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        rpc.call("resources.install_mcp", ["name": m.name, "command": m.command, "args": m.args]) { done($0.map { _ in () }) }
    }

    func installMuyaPlugin(_ done: @escaping @MainActor (Result<String, RpcFailure>) -> Void) {
        rpc.call("resources.install_muya_plugin", [:]) { done($0.map { ($0 as? String) ?? "" }) }
    }

    /// Custom commands and skills found on disk; a failure just means none (the built-ins still show).
    func slashDisk(agent: String, cwd: String?, _ done: @escaping @MainActor ([SlashItem]) -> Void) {
        var p: [String: Any] = ["agent": agent]
        if let cwd, !cwd.isEmpty { p["cwd"] = cwd }
        rpc.call("slash.list", p) { r in
            guard case let .success(v) = r, let rows = v as? [[String: Any]] else { return done([]) }
            done(rows.compactMap { d in
                guard let n = d["name"] as? String, let s = (d["source"] as? String).flatMap(SlashSource.init(rawValue:)) else { return nil }
                return SlashItem(name: n, description: d["description"] as? String ?? "", source: s)
            })
        }
    }

    // MARK: Terminal history (Sessions page)

    func termHistory(_ done: @escaping @MainActor (Result<[TermHistoryEntries], RpcFailure>) -> Void) {
        rpc.call("term_history.entries", [:]) { done($0.map { (($0 as? [[String: Any]]) ?? []).compactMap(TermHistoryEntries.init(json:)) }) }
    }

    func termHistoryFull(key: String, _ done: @escaping @MainActor (Result<TermHistoryEntries?, RpcFailure>) -> Void) {
        rpc.call("term_history.full", ["key": key]) { done($0.map { ($0 as? [String: Any]).flatMap(TermHistoryEntries.init(json:)) }) }
    }

    func termHistoryExport(dest: String, text: String, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        rpc.call("term_history.export", ["dest": dest, "text": text]) { done($0.map { _ in () }) }
    }

    func termHistoryDelete(key: String, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        rpc.call("term_history.delete", ["key": key]) { done($0.map { _ in () }) }
    }

    func statusline(ptyId: String, _ done: @escaping @MainActor ([String: Any]?) -> Void) {
        rpc.call("statusline.get", ["ptyId": ptyId]) { r in if case let .success(v) = r { done(v as? [String: Any]) } else { done(nil) } }
    }
}

struct TermHistoryEntry: Equatable { var ts: UInt64?; var cmd: String }

struct TermHistoryEntries: Equatable {
    var key: String, name: String, cwd: String, updatedMs: UInt64, total: Int, entries: [TermHistoryEntry]
    init?(json d: [String: Any]) {
        guard let k = d["key"] as? String else { return nil }
        key = k; name = d["name"] as? String ?? ""; cwd = d["cwd"] as? String ?? ""
        updatedMs = (d["updatedMs"] as? NSNumber)?.uint64Value ?? 0; total = (d["total"] as? NSNumber)?.intValue ?? 0
        entries = ((d["entries"] as? [[String: Any]]) ?? []).compactMap { e in
            guard let c = e["cmd"] as? String else { return nil }
            return TermHistoryEntry(ts: (e["ts"] as? NSNumber)?.uint64Value, cmd: c)
        }
    }
}
