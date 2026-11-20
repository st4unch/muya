// The calls the SSH page makes to the daemon, on top of an abstract `SSHRpc` (the app passes the Store's
// `call`; tests and the screenshot harness pass an in-memory fake). muyad has none of these methods yet:
// every one then answers "unknown method" and the page shows the "not wired yet" state. The names below are
// the proposal for the daemon side (see ssh-ui.summary.md).

import Foundation

struct RpcFailure: Error, Equatable { var message: String }

@MainActor
protocol SSHRpc: AnyObject {
    func call(_ method: String, _ params: [String: Any], done: @escaping @MainActor (Result<Any, RpcFailure>) -> Void)
}

enum SSHMethod {
    static let serversList = "ssh.servers.list", serversSave = "ssh.servers.save", serversDelete = "ssh.servers.delete"
    static let psmpList = "ssh.psmp.list", psmpSave = "ssh.psmp.save", psmpDelete = "ssh.psmp.delete"
    static let cyberarkSearch = "cyberark.accounts.search"
    static let vaultList = "vault.list", vaultUnlock = "vault.unlock", vaultAdd = "vault.add", vaultUpdate = "vault.update", vaultStatus = "vault.status", vaultInit = "vault.init"
}

@MainActor
final class SSHService {
    private let rpc: SSHRpc
    init(rpc: SSHRpc) { self.rpc = rpc }

    func servers(_ done: @escaping @MainActor (PaneState<[SSHServer]>) -> Void) {
        rpc.call(SSHMethod.serversList, [:]) { r in
            switch r {
            case let .success(v): done(.ready(Self.objects(v).compactMap(SSHServer.init(json:))))
            case let .failure(e): done(SSHErrorMap.classify(e.message))
            }
        }
    }

    func profiles(_ done: @escaping @MainActor (PaneState<[PSMPProfile]>) -> Void) {
        rpc.call(SSHMethod.psmpList, [:]) { r in
            switch r {
            case let .success(v): done(.ready(Self.objects(v).compactMap(PSMPProfile.init(json:))))
            case let .failure(e): done(SSHErrorMap.classify(e.message))
            }
        }
    }

    func save(server: SSHServer, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        rpc.call(SSHMethod.serversSave, ["server": server.json()]) { done($0.map { _ in () }) }
    }

    func delete(server id: String, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        rpc.call(SSHMethod.serversDelete, ["id": id]) { done($0.map { _ in () }) }
    }

    func save(profile: PSMPProfile, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        rpc.call(SSHMethod.psmpSave, ["profile": profile.json()]) { done($0.map { _ in () }) }
    }

    func delete(profile id: String, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        rpc.call(SSHMethod.psmpDelete, ["id": id]) { done($0.map { _ in () }) }
    }

    func searchAccounts(_ query: String, _ done: @escaping @MainActor (PaneState<[CyberArkAccount]>) -> Void) {
        rpc.call(SSHMethod.cyberarkSearch, ["query": query]) { r in
            switch r {
            case let .success(v): done(.ready(Self.objects(v).compactMap(CyberArkAccount.init(json:))))
            case let .failure(e): done(SSHErrorMap.classify(e.message))
            }
        }
    }

    func secrets(_ done: @escaping @MainActor (PaneState<[SecretMeta]>) -> Void) {
        rpc.call(SSHMethod.vaultList, [:]) { r in
            switch r {
            case let .success(v): done(.ready(Self.objects(v).compactMap(SecretMeta.init(json:))))
            case let .failure(e): done(SSHErrorMap.classify(e.message))
            }
        }
    }

    /// What the Password Store needs to know before it asks: is there a store, is it open, can Touch ID be tried.
    struct VaultStatus: Equatable {
        var initialized = true, unlocked = false, biometricAvailable = false
        init() {}
        init(json: Any) {
            let o = json as? [String: Any] ?? [:]
            initialized = o["initialized"] as? Bool ?? true
            unlocked = o["unlocked"] as? Bool ?? false
            biometricAvailable = o["biometricAvailable"] as? Bool ?? false
        }
    }

    func vaultStatus(_ done: @escaping @MainActor (VaultStatus) -> Void) {
        rpc.call(SSHMethod.vaultStatus, [:]) { r in
            if case let .success(v) = r { done(VaultStatus(json: v)) } else { done(VaultStatus()) }
        }
    }

    /// Unlocks with the master password (the text is wiped by the caller's buffer right after the call) or, with
    /// `biometric`, with Touch ID. `done` carries the note about turning Touch ID on, if it was asked for.
    func unlock(master: SecretBuffer? = nil, biometric: Bool = false, enableTouchId: Bool = false, _ done: @escaping @MainActor (Result<String?, RpcFailure>) -> Void) {
        var params: [String: Any] = [:]
        if let master { params["master"] = master.reveal(); params["enableTouchId"] = enableTouchId }
        if biometric { params["biometric"] = true }
        rpc.call(SSHMethod.vaultUnlock, params) { r in
            master?.wipe()
            done(r.map { v in
                let t = (v as? [String: Any])?["touchId"] as? [String: Any]
                return (t?["enabled"] as? Bool) == false ? (t?["error"] as? String) : nil
            })
        }
    }

    /// Creates the store (a Mac with no `muya-ssh-vault.enc` yet) and leaves it open.
    func createStore(master: SecretBuffer, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        rpc.call(SSHMethod.vaultInit, ["master": master.reveal()]) { r in master.wipe(); done(r.map { _ in () }) }
    }

    /// Stores or replaces a secret. The buffer is wiped before `done` runs, success or not.
    func store(label: String, description: String, kind: String, value: SecretBuffer, updating: Bool, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        var params: [String: Any] = ["label": label, "secret": value.reveal()]
        if !updating { params["description"] = description; params["secretKind"] = kind }
        rpc.call(updating ? SSHMethod.vaultUpdate : SSHMethod.vaultAdd, params) { r in
            value.wipe()
            done(r.map { _ in () })
        }
        // `params` still holds the revealed String until it goes out of scope; the buffer itself is wiped
        // above as soon as the reply arrives, and the page clears its field right after submitting.
    }

    private static func objects(_ v: Any) -> [[String: Any]] {
        if let a = v as? [[String: Any]] { return a }
        if let o = v as? [String: Any] { for k in ["servers", "profiles", "accounts", "secrets", "items"] { if let a = o[k] as? [[String: Any]] { return a } } }
        return []
    }
}

/// An in-memory daemon for tests and the screenshot harness. All data is SYNTHETIC: documentation names and
/// the reserved 192.0.2.0/24 and example.test ranges, placeholder secret names, no values.
@MainActor
final class FakeSSHRpc: SSHRpc {
    enum Mode { case working, unwired, locked }

    var mode: Mode
    var servers: [[String: Any]]
    var profiles: [[String: Any]]
    var secrets: [[String: Any]]
    var accounts: [[String: Any]]
    private(set) var calls: [String] = []
    private(set) var lastSecretParam: String?
    var unlocks = 0

    init(mode: Mode = .working) {
        self.mode = mode
        servers = [
            ["id": "s1", "label": "Build host", "host": "build.example.test", "port": 22, "username": "ci", "connectionType": "direct", "credentialSource": ["kind": "prompt"], "agentAccess": true, "group": "Lab"],
            ["id": "s2", "label": "Edge router", "host": "192.0.2.10", "port": 2222, "username": "admin", "connectionType": "direct", "credentialSource": ["kind": "local", "localCredId": "lab-admin"], "group": "Lab"],
            ["id": "s3", "label": "Core DB", "host": "db.example.test", "port": 22, "username": "dba", "connectionType": "psmp", "psmpProfileId": "p1", "credentialSource": ["kind": "cyberark", "cyberarkAccountId": "acc-1"], "group": "Production"],
            ["id": "s4", "label": "", "host": "198.51.100.7", "port": 22, "username": "deploy", "connectionType": "direct", "credentialSource": ["kind": "prompt"], "agentAdded": true, "group": ""],
        ]
        profiles = [["id": "p1", "label": "Lab PSMP", "psmpAddress": "psmp.example.test", "vaultUser": "svc-ops", "userDelim": "@", "paramDelim": "#", "scpOptions": "-O"]]
        secrets = [
            ["label": "lab-admin", "description": "Edge router login", "secret_kind": "password"],
            ["label": "ci-deploy-key", "description": "Build host key", "secret_kind": "key"],
            ["label": "registry-token", "description": "", "secret_kind": "token"],
        ]
        accounts = [
            ["id": "acc-1", "name": "Operating System-UnixSSH-db.example.test-dba", "address": "db.example.test", "username": "dba", "safe": "DB-Prod", "platform_id": "UnixSSH"],
            ["id": "acc-2", "name": "Operating System-UnixSSH-192.0.2.10-admin", "address": "192.0.2.10", "username": "admin", "safe": "Network-Lab", "platform_id": "UnixSSH"],
        ]
    }

    func call(_ method: String, _ params: [String: Any], done: @escaping @MainActor (Result<Any, RpcFailure>) -> Void) {
        calls.append(method)
        if method == SSHMethod.vaultAdd || method == SSHMethod.vaultUpdate { lastSecretParam = params["secret"] as? String }
        if mode == .unwired { return done(.failure(RpcFailure(message: "unknown method '\(method)'"))) }
        let vaultCall = method.hasPrefix("vault.") || method == SSHMethod.cyberarkSearch
        if mode == .locked, vaultCall, method != SSHMethod.vaultUnlock { return done(.failure(RpcFailure(message: "password store is locked — unlock it in the Password Store tab"))) }
        switch method {
        case SSHMethod.serversList: done(.success(servers))
        case SSHMethod.serversSave:
            var s = params["server"] as? [String: Any] ?? [:]
            if (s["id"] as? String ?? "").isEmpty { s["id"] = "s\(servers.count + 1)" }
            servers.removeAll { $0["id"] as? String == s["id"] as? String }
            servers.append(s)
            done(.success(["id": s["id"] ?? ""]))
        case SSHMethod.serversDelete:
            servers.removeAll { $0["id"] as? String == params["id"] as? String }
            done(.success([String: Any]()))
        case SSHMethod.psmpList: done(.success(profiles))
        case SSHMethod.psmpSave:
            var p = params["profile"] as? [String: Any] ?? [:]
            if (p["id"] as? String ?? "").isEmpty { p["id"] = "p\(profiles.count + 1)" }
            profiles.removeAll { $0["id"] as? String == p["id"] as? String }
            profiles.append(p)
            done(.success(["id": p["id"] ?? ""]))
        case SSHMethod.psmpDelete:
            profiles.removeAll { $0["id"] as? String == params["id"] as? String }
            done(.success([String: Any]()))
        case SSHMethod.cyberarkSearch:
            let q = (params["query"] as? String ?? "").lowercased()
            done(.success(accounts.filter { a in ["name", "address", "username", "safe"].contains { (a[$0] as? String ?? "").lowercased().contains(q) } }))
        case SSHMethod.vaultList: done(.success(secrets))
        case SSHMethod.vaultStatus: done(.success(["initialized": true, "unlocked": mode != .locked, "biometricAvailable": false]))
        case SSHMethod.vaultUnlock: unlocks += 1; mode = .working; done(.success(["unlocked": true]))
        case SSHMethod.vaultInit: mode = .working; done(.success([String: Any]()))
        case SSHMethod.vaultAdd:
            secrets.append(["label": params["label"] ?? "", "description": params["description"] ?? "", "secret_kind": params["secretKind"] ?? "password"])
            done(.success([String: Any]()))
        case SSHMethod.vaultUpdate: done(.success([String: Any]()))
        default: done(.failure(RpcFailure(message: "unknown method '\(method)'")))
        }
    }
}
