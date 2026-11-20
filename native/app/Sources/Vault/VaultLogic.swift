// P12 — the Obsidian notes vault ("Vault Source" panel) and the auto-allow suggestion. Pure logic + the daemon
// calls, with no AppKit, so `build.sh test` covers them. The daemon side is `notes_vault.*` (muyad rpc_vault_notes.rs);
// these are the five old Tauri commands vault_get_status / vault_detect_candidates / vault_set_path / vault_restart /
// vault_search. Not the password store (that is `vault.*`).

import Foundation

enum VaultMethod {
    static let status = "notes_vault.status", candidates = "notes_vault.detect_candidates", setPath = "notes_vault.set_path"
    static let restart = "notes_vault.restart", search = "notes_vault.search"
}

/// `vault_get_status`: what is configured, what resolves, and whether the search helper is installed.
struct VaultSource: Equatable {
    var configuredPath: String?
    var resolvedPath: String?
    var serverInstalled: Bool

    init(configuredPath: String? = nil, resolvedPath: String? = nil, serverInstalled: Bool = false) {
        self.configuredPath = configuredPath; self.resolvedPath = resolvedPath; self.serverInstalled = serverInstalled
    }

    init?(json: Any?) {
        guard let o = json as? [String: Any] else { return nil }
        configuredPath = o["configuredPath"] as? String
        resolvedPath = o["resolvedPath"] as? String
        serverInstalled = (o["serverInstalled"] as? Bool) ?? false
    }
}

/// One block `vault_search` returns.
struct VaultBlock: Equatable {
    var path: String
    var similarity: Double
    var text: String
    var lines: String?

    init?(json: [String: Any]) {
        guard let p = json["path"] as? String else { return nil }
        path = p; similarity = (json["similarity"] as? Double) ?? 0; text = (json["text"] as? String) ?? ""; lines = json["lines"] as? String
    }
}

enum VaultLogic {
    /// The install hint of the old panel (the script lives in the Muya repo).
    static let setupCommand = "./scripts/setup-vault.sh"
    static let noVaultText = "Not configured — no vault detected."

    /// The "Current" line: the path the helper will use, or the not-configured note.
    static func currentText(_ s: VaultSource?) -> String { s?.resolvedPath ?? noVaultText }

    /// "Set" is enabled only for a non-blank path.
    static func canSet(_ custom: String) -> Bool { !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What the user reads for a daemon error (the old panel showed the raw string; the codes get a plain sentence).
    static func errorText(_ message: String) -> String {
        switch message {
        case "mcp_unavailable": return "The vault search helper is not running."
        case "timeout": return "The vault search timed out."
        case "no_results": return "No matching notes."
        default: return message
        }
    }

    /// The folder to remember after a successful Set: trimmed, as the daemon stores it.
    static func normalised(_ path: String) -> String { path.trimmingCharacters(in: .whitespacesAndNewlines) }
}

@MainActor
final class VaultService {
    private let rpc: SSHRpc
    init(rpc: SSHRpc) { self.rpc = rpc }

    func status(_ done: @escaping @MainActor (Result<VaultSource, RpcFailure>) -> Void) {
        rpc.call(VaultMethod.status, [:]) { r in
            done(r.flatMap { v in VaultSource(json: v).map(Result.success) ?? .failure(RpcFailure(message: "unexpected vault status")) })
        }
    }

    func candidates(_ done: @escaping @MainActor ([String]) -> Void) {
        rpc.call(VaultMethod.candidates, [:]) { r in
            if case let .success(v) = r, let a = v as? [String] { done(a) } else { done([]) }
        }
    }

    /// Set the path, then restart the helper so it takes effect now (the old panel did the same two calls),
    /// then read the status back.
    func apply(_ path: String, _ done: @escaping @MainActor (Result<VaultSource, RpcFailure>) -> Void) {
        let p = VaultLogic.normalised(path)
        rpc.call(VaultMethod.setPath, ["path": p]) { [self] r in
            if case let .failure(e) = r { return done(.failure(e)) }
            rpc.call(VaultMethod.restart, [:]) { [self] r in
                if case let .failure(e) = r { return done(.failure(e)) }
                status(done)
            }
        }
    }

    func search(_ query: String, maxBlocks: Int? = nil, timeoutMs: Int? = nil, _ done: @escaping @MainActor (Result<[VaultBlock], RpcFailure>) -> Void) {
        var p: [String: Any] = ["query": query]
        if let maxBlocks { p["maxBlocks"] = maxBlocks }
        if let timeoutMs { p["timeoutMs"] = timeoutMs }
        rpc.call(VaultMethod.search, p) { r in
            done(r.map { v in ((v as? [[String: Any]]) ?? []).compactMap(VaultBlock.init(json:)) })
        }
    }
}

// MARK: - Auto-allow suggestion

/// When to offer "Turn on Auto-allow?" (src/App.tsx: autoAllowSuggest). A permission prompt that was not there
/// on the previous look, Auto-allow off, and a session not already in auto / bypass mode, shows the toast for
/// that session. It stays 30 s (`lifetime`), or until closed (X, "Not now", Esc), or until a newer prompt
/// replaces it. Pure: the app feeds it the prompts every time a screen state changes.
struct AutoAllowSuggestLogic {
    struct Prompt: Equatable { var session: UInt64; var key: String; var mode: String }

    static let lifetime: TimeInterval = 30
    private var seen = Set<String>()
    private(set) var shownFor: UInt64?
    private(set) var shownAt: Date?

    /// Returns the session to name in the toast when a new one should be shown now.
    mutating func observe(_ prompts: [Prompt], autoApprove: Bool, now: Date = Date()) -> UInt64? {
        let ids = Set(prompts.map { "\($0.session)|\($0.key)" })
        let fresh = prompts.first { !seen.contains("\($0.session)|\($0.key)") }
        seen = ids
        guard let fresh, !autoApprove, fresh.mode != "auto", fresh.mode != "bypass" else { return nil }
        shownFor = fresh.session; shownAt = now
        return fresh.session
    }

    mutating func dismiss() { shownFor = nil; shownAt = nil }

    /// True once the 30 s are over.
    func expired(now: Date = Date()) -> Bool { shownAt.map { now.timeIntervalSince($0) >= Self.lifetime } ?? false }

    /// The words of the toast.
    static func body(agentName: String) -> String {
        "\(agentName) is asking for permission. With Auto-allow on, Muya clicks Allow for you after 2 seconds, in every session."
    }
    static let title = "Turn on Auto-allow?"
}
