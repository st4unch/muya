// Pure logic of the SSH / PSMP / CyberArk / Password Store page: models, wire parsing, validation (mirrors
// muya-core ssh.rs `validate`, `validate_psmp_profile` and credstore kinds), the error -> pane state mapping
// and the view models. No AppKit, so the unit tests cover it. Secrets never appear here except inside a
// `SecretBuffer`, which is wiped after use.

import Foundation

// MARK: Models

enum SSHConnectionType: String, CaseIterable { case direct, psmp }

/// Where the login secret comes from (muya-core `CredentialSource.kind`).
enum CredentialKind: String, CaseIterable {
    case prompt, local, cyberark

    var title: String {
        switch self {
        case .prompt: return "Ask when connecting"
        case .local: return "Password Store"
        case .cyberark: return "CyberArk account"
        }
    }
}

struct SSHServer: Equatable {
    var id = ""
    var label = ""
    var host = ""
    var port = 22
    var username = ""
    var connectionType = SSHConnectionType.direct
    var psmpProfileId: String?
    var credentialKind = CredentialKind.prompt
    /// `localCredId` or `cyberarkAccountId`, whichever the kind uses. A reference, never a secret.
    var credentialRef: String?
    var agentAccess = false
    var agentAdded = false
    var sshOptions = ""
    var group = ""

    init() {}

    init?(json j: [String: Any]) {
        guard let host = j["host"] as? String, let user = j["username"] as? String else { return nil }
        id = j["id"] as? String ?? ""
        label = j["label"] as? String ?? ""
        self.host = host
        port = (j["port"] as? NSNumber)?.intValue ?? 22
        username = user
        connectionType = SSHConnectionType(rawValue: j["connectionType"] as? String ?? "") ?? .direct
        psmpProfileId = j["psmpProfileId"] as? String
        let src = j["credentialSource"] as? [String: Any] ?? [:]
        credentialKind = CredentialKind(rawValue: src["kind"] as? String ?? "") ?? .prompt
        credentialRef = (src["localCredId"] as? String) ?? (src["cyberarkAccountId"] as? String)
        agentAccess = j["agentAccess"] as? Bool ?? false
        agentAdded = j["agentAdded"] as? Bool ?? false
        sshOptions = j["sshOptions"] as? String ?? ""
        group = j["group"] as? String ?? ""
    }

    /// The JSON the daemon stores (camelCase keys of muya-core's `Server`).
    func json() -> [String: Any] {
        var src: [String: Any] = ["kind": credentialKind.rawValue]
        if let r = credentialRef, !r.isEmpty {
            if credentialKind == .local { src["localCredId"] = r }
            if credentialKind == .cyberark { src["cyberarkAccountId"] = r }
        }
        var o: [String: Any] = [
            "id": id, "label": label, "host": host, "port": port, "username": username,
            "connectionType": connectionType.rawValue, "credentialSource": src,
            "agentAccess": agentAccess, "agentAdded": agentAdded, "group": group, "tags": [String](),
        ]
        if connectionType == .psmp, let p = psmpProfileId, !p.isEmpty { o["psmpProfileId"] = p }
        if !sshOptions.isEmpty { o["sshOptions"] = sshOptions }
        return o
    }

    var title: String { label.isEmpty ? "\(username)@\(host)" : label }
    var destination: String { "\(username)@\(host)" + (port == 22 ? "" : ":\(port)") }
}

struct PSMPProfile: Equatable {
    var id = ""
    var label = ""
    var psmpAddress = ""
    var vaultUser = ""
    var userDelim = "@"
    var paramDelim = "#"
    var scpOptions = ""

    init() {}

    init?(json j: [String: Any]) {
        guard let addr = j["psmpAddress"] as? String, let user = j["vaultUser"] as? String else { return nil }
        id = j["id"] as? String ?? ""
        label = j["label"] as? String ?? ""
        psmpAddress = addr
        vaultUser = user
        userDelim = j["userDelim"] as? String ?? "@"
        paramDelim = j["paramDelim"] as? String ?? "#"
        scpOptions = j["scpOptions"] as? String ?? ""
    }

    func json() -> [String: Any] {
        var o: [String: Any] = ["id": id, "label": label, "psmpAddress": psmpAddress, "vaultUser": vaultUser, "userDelim": userDelim, "paramDelim": paramDelim]
        if !scpOptions.isEmpty { o["scpOptions"] = scpOptions }
        return o
    }

    var title: String { label.isEmpty ? psmpAddress : label }
}

struct CyberArkAccount: Equatable {
    var id: String, name: String, address: String, username: String, safe: String, platformId: String

    init?(json j: [String: Any]) {
        guard let id = j["id"] as? String else { return nil }
        self.id = id
        name = j["name"] as? String ?? ""
        address = j["address"] as? String ?? ""
        username = j["username"] as? String ?? ""
        safe = j["safe"] as? String ?? ""
        platformId = (j["platform_id"] as? String) ?? (j["platformId"] as? String) ?? ""
    }
}

/// A stored secret's description. The value is never part of it.
struct SecretMeta: Equatable {
    var label: String, description: String, kind: String
    /// Stored by the shared vault (`MUYA-SSHVAULT v1`): an old vault's entries keep their id, user name and group.
    var id = "", username = "", group = ""

    init?(json j: [String: Any]) {
        guard let label = j["label"] as? String else { return nil }
        self.label = label
        id = j["id"] as? String ?? ""
        username = j["username"] as? String ?? ""
        group = j["group"] as? String ?? ""
        description = j["description"] as? String ?? ""
        kind = (j["secretKind"] as? String) ?? (j["secret_kind"] as? String) ?? (j["kind"] as? String) ?? "password"
    }

    init(label: String, description: String, kind: String) { self.label = label; self.description = description; self.kind = kind }
}

// MARK: Secret handling

/// A secret held as raw bytes so it can really be overwritten (a Swift String cannot). The field's text is
/// copied in, the field is cleared at once, the buffer is wiped as soon as the call that needs it is done.
final class SecretBuffer {
    private(set) var bytes: [UInt8]
    init(_ s: String) { bytes = Array(s.utf8) }
    var isEmpty: Bool { bytes.isEmpty }
    var count: Int { bytes.count }
    /// The text for the one call that needs it; callers must not keep it.
    func reveal() -> String { String(decoding: bytes, as: UTF8.self) }
    func wipe() {
        bytes.withUnsafeMutableBytes { p in
            guard let base = p.baseAddress else { return }
            memset_s(base, p.count, 0, p.count)
        }
        bytes.removeAll(keepingCapacity: false)
    }
    deinit { wipe() }
}

// MARK: Pane state and error mapping

/// What a pane shows instead of (or next to) its list.
enum PaneState<T: Equatable>: Equatable {
    case loading
    case ready(T)
    /// The password store is locked (needs the Touch ID decision / unlock).
    case locked
    /// The daemon (or this build) does not offer the call yet; the text says what is missing.
    case notWired(String)
    case failed(String)

    var isReady: Bool { if case .ready = self { return true } else { return false } }
}

enum SSHErrorMap {
    static let lockedMarker = "locked"
    static let notAvailableMarker = "not available in the native daemon yet"

    /// Classifies a daemon / backend error message into the state the pane shows.
    static func classify<T>(_ message: String, as _: T.Type = T.self) -> PaneState<T> {
        let m = message.lowercased()
        if m.contains("password store is locked") || (m.contains(lockedMarker) && m.contains("unlock")) { return .locked }
        if m.contains(notAvailableMarker) || m.hasPrefix("unknown method") { return .notWired(notWiredText(message)) }
        return .failed(message)
    }

    /// What the Password Store shows after an Unlock attempt failed.
    static func unlockMessage(_ message: String) -> String {
        switch classify(message, as: [SecretMeta].self) {
        case .notWired: return "Unlock is not available in the native daemon yet — it arrives with the Touch ID decision."
        case .locked: return "Still locked — the daemon did not open the store. Try again, or restart Muya."
        case let .failed(m): return m
        default: return message
        }
    }

    static func notWiredText(_ message: String) -> String {
        if message.lowercased().hasPrefix("unknown method") { return "The native daemon does not offer this yet." }
        return message.prefix(1).uppercased() + message.dropFirst()
    }
}

// MARK: Validation

struct FieldError: Equatable {
    var field: String
    var message: String
}

enum SSHValidation {
    static func server(_ s: SSHServer, others: [SSHServer], profiles: [PSMPProfile]) -> [FieldError] {
        var out: [FieldError] = []
        if s.host.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.init(field: "host", message: "Host is required")) }
        else if s.host.hasPrefix("-") { out.append(.init(field: "host", message: "Host must not start with '-'")) }
        else if s.host.contains(where: { $0.isWhitespace || $0.isNewline }) { out.append(.init(field: "host", message: "Host must not contain spaces")) }
        if s.username.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.init(field: "username", message: "User name is required")) }
        else if s.username.hasPrefix("-") { out.append(.init(field: "username", message: "User name must not start with '-'")) }
        else if s.username.contains(where: { $0.isWhitespace || $0.isNewline }) { out.append(.init(field: "username", message: "User name must not contain spaces")) }
        if !(1 ... 65535).contains(s.port) { out.append(.init(field: "port", message: "Port must be 1–65535")) }
        if s.connectionType == .psmp {
            if (s.psmpProfileId ?? "").isEmpty { out.append(.init(field: "psmp", message: "A PSMP server needs a PSMP profile")) }
            else if !profiles.isEmpty, !profiles.contains(where: { $0.id == s.psmpProfileId }) { out.append(.init(field: "psmp", message: "That PSMP profile no longer exists")) }
        }
        if s.credentialKind != .prompt, (s.credentialRef ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(.init(field: "credential", message: s.credentialKind == .local ? "Pick a secret from the Password Store" : "Pick a CyberArk account"))
        }
        if out.isEmpty {
            let key = { (x: SSHServer) in "\(x.username.lowercased())@\(x.host.lowercased()):\(x.port)" }
            if others.contains(where: { $0.id != s.id && key($0) == key(s) }) {
                out.append(.init(field: "host", message: "A server for \(s.username)@\(s.host):\(s.port) already exists"))
            }
        }
        return out
    }

    static func profile(_ p: PSMPProfile) -> [FieldError] {
        var out: [FieldError] = []
        let delim = p.userDelim.isEmpty ? "@" : p.userDelim
        for (field, title, value) in [("vaultUser", "Vault user", p.vaultUser), ("psmpAddress", "PSMP address", p.psmpAddress)] {
            if value.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.init(field: field, message: "\(title) is required")) }
            else if value.contains(where: { $0.isWhitespace || $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }) {
                out.append(.init(field: field, message: "\(title) must not contain spaces or control characters"))
            } else if value.contains(delim) {
                out.append(.init(field: field, message: "\(title) must not contain the user delimiter '\(delim)' — enter only the \(title.lowercased()) itself"))
            }
        }
        return out
    }

    static let secretKinds = ["password", "key", "token", "api_key"]

    static func secret(label: String, kind: String, value: SecretBuffer, existing: [SecretMeta], updating: Bool) -> [FieldError] {
        var out: [FieldError] = []
        let name = label.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { out.append(.init(field: "label", message: "A name is required")) }
        else if !updating, existing.contains(where: { $0.label.lowercased() == name.lowercased() }) {
            out.append(.init(field: "label", message: "A secret named '\(name)' already exists — choose Update to replace its value"))
        } else if updating, !existing.contains(where: { $0.label.lowercased() == name.lowercased() }) {
            out.append(.init(field: "label", message: "No secret named '\(name)' to update"))
        }
        if !secretKinds.contains(kind) { out.append(.init(field: "kind", message: "Kind must be password, key, token or api_key")) }
        if value.isEmpty { out.append(.init(field: "value", message: "The secret value is required")) }
        return out
    }
}

// MARK: Connect

enum SSHConnect {
    /// Connect is the daemon's job (`ssh.connect`): it spawns `ssh` as a terminal and injects the stored / CyberArk
    /// password (classic `ssh_pty_connect`). The page only refuses a server whose fields are invalid, with the same
    /// first message the editor shows.
    static func precheck(_ s: SSHServer, profiles: [PSMPProfile] = []) -> String? {
        SSHValidation.server(s, others: [], profiles: profiles).first?.message
    }
}

// MARK: View models

/// Servers and PSMP profiles: the lists, the selection and the edit drafts.
struct ServersModel {
    var servers: PaneState<[SSHServer]> = .loading
    var profiles: PaneState<[PSMPProfile]> = .loading
    var filter = ""

    /// Every server the daemon returned, filter or not (classic's "N server(s)" count).
    var allServers: [SSHServer] { if case let .ready(all) = servers { return all } else { return [] } }

    var visibleServers: [SSHServer] {
        guard case let .ready(all) = servers else { return [] }
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? all : all.filter { [$0.label, $0.host, $0.username, $0.group].contains { $0.lowercased().contains(q) } }
        return list.sorted { (($0.group.isEmpty ? 1 : 0), $0.group.lowercased(), $0.title.lowercased()) < (($1.group.isEmpty ? 1 : 0), $1.group.lowercased(), $1.title.lowercased()) }
    }

    var profileList: [PSMPProfile] { if case let .ready(p) = profiles { return p } else { return [] } }

    func profileTitle(id: String?) -> String {
        guard let id, !id.isEmpty else { return "—" }
        return profileList.first(where: { $0.id == id })?.title ?? "Missing profile"
    }

    /// Group header rows then their servers, for a sectioned list.
    var rows: [ServerRow] {
        var out: [ServerRow] = []
        var current: String?
        for s in visibleServers {
            let g = s.group.isEmpty ? "Ungrouped" : s.group
            if g != current { out.append(.header(g)); current = g }
            out.append(.server(s))
        }
        return out
    }
}

enum ServerRow: Equatable {
    case header(String)
    case server(SSHServer)
}

/// CyberArk browser: query, debounce-free (the user presses Return) result list.
struct CyberArkModel {
    var query = ""
    var state: PaneState<[CyberArkAccount]> = .ready([])
    var searched = false

    var canSearch: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var summary: String {
        switch state {
        case .loading: return "Searching…"
        case let .ready(a): return searched ? (a.isEmpty ? "No accounts match" : "\(a.count) account\(a.count == 1 ? "" : "s")") : "Type a name, address or safe, then press Return"
        case .locked: return "The password store is locked"
        case let .notWired(m), let .failed(m): return m
        }
    }
}

/// Password Store: the names of the secrets (no values) and the lock state.
struct VaultModel {
    var secrets: PaneState<[SecretMeta]> = .loading
    var filter = ""

    var visible: [SecretMeta] {
        guard case let .ready(all) = secrets else { return [] }
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? all : all.filter { [$0.label, $0.description, $0.username, $0.group].contains { $0.lowercased().contains(q) } }
        return list.sorted { ($0.group.lowercased(), $0.label.lowercased()) < ($1.group.lowercased(), $1.label.lowercased()) }
    }

    /// The label of a stored credential, for the server cards' login word; nil when the store is locked or it is gone.
    func label(forId id: String) -> String? {
        guard case let .ready(all) = secrets else { return nil }
        return (all.first { $0.id == id } ?? all.first { $0.label == id })?.label
    }

    var statusText: String {
        switch secrets {
        case .loading: return "Loading…"
        case .locked: return "Locked"
        case let .ready(a): return "Unlocked · \(a.count) item(s)"
        case .notWired: return "Not available yet"
        case .failed: return "Error"
        }
    }

    /// The sentence the confirmation sheet shows before a secret is stored or replaced.
    static func confirmText(label: String, kind: String, updating: Bool) -> (title: String, detail: String, button: String) {
        updating
            ? ("Replace the value of “\(label)”?", "The stored \(kind) is overwritten. The old value cannot be recovered.", "Replace")
            : ("Store “\(label)” in the Password Store?", "The \(kind) is encrypted and kept on this Mac. Agents can use it by name but never read it.", "Store")
    }
}

/// Sections of the page, in tab order.
enum SSHSection: Int, CaseIterable {
    case servers, psmp, cyberark, vault

    /// The tab bar, as classic draws it: Servers | CyberArk | Password Store. PSMP profiles are not a tab — classic
    /// keeps them in a card at the bottom of the Servers tab, so `.psmp` stays in the enum (debug hooks, routing) but
    /// never gets a tab of its own.
    static let tabs: [SSHSection] = [.servers, .cyberark, .vault]

    var title: String {
        switch self {
        case .servers: return "Servers"
        case .psmp: return "PSMP profiles"
        case .cyberark: return "CyberArk"
        case .vault: return "Password Store"
        }
    }

    /// ⌘1…⌘4 style digit shortcut label.
    var shortcut: String { "\(rawValue + 1)" }
}

// MARK: Password Store cards (logic)

enum CredKindName {
    /// classic: password -> "password", key -> "SSH key", token -> "token", api_key -> "API key".
    static func title(_ kind: String) -> String {
        switch kind { case "key": return "SSH key"; case "api_key": return "API key"; default: return kind }
    }
}

/// Cards of one group, in classic's order: named groups A-Z, "Ungrouped" last.
struct CredGroup: Equatable {
    var name: String
    var items: [SecretMeta]

    static let ungrouped = "Ungrouped"

    static func make(_ all: [SecretMeta]) -> [CredGroup] {
        var by: [String: [SecretMeta]] = [:]
        for s in all {
            let g = s.group.trimmingCharacters(in: .whitespaces)
            by[g.isEmpty ? ungrouped : g, default: []].append(s)
        }
        let names = by.keys.sorted { a, b in
            if a == ungrouped { return false }
            if b == ungrouped { return true }
            return a.localizedCompare(b) == .orderedAscending
        }
        return names.map { CredGroup(name: $0, items: by[$0]!.sorted { $0.label.localizedCompare($1.label) == .orderedAscending }) }
    }

    /// 1 column below 768 px, 2 from 768, 3 from 1536 (classic: md / 2xl on the page width).
    static func columns(pageWidth: CGFloat) -> Int { pageWidth >= 1536 ? 3 : pageWidth >= 768 ? 2 : 1 }
}


// MARK: Server cards (classic's Servers tab)

/// Servers of one group, in classic's order: named groups A–Z, "Ungrouped" last.
struct ServerGroup: Equatable {
    var name: String
    var items: [SSHServer]

    static let ungrouped = "Ungrouped"

    static func make(_ all: [SSHServer]) -> [ServerGroup] {
        var by: [String: [SSHServer]] = [:]
        for s in all {
            let g = s.group.trimmingCharacters(in: .whitespaces)
            by[g.isEmpty ? ungrouped : g, default: []].append(s)
        }
        let names = by.keys.sorted { a, b in
            if a == ungrouped { return false }
            if b == ungrouped { return true }
            return a.localizedCompare(b) == .orderedAscending
        }
        return names.map { ServerGroup(name: $0, items: by[$0]!.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }) }
    }
}

/// The mono line under a server card's name, as classic writes it: `user@host:port · type · login`.
/// The port is always shown (classic does), unlike `SSHServer.destination`.
enum ServerCardLine {
    static func destination(_ s: SSHServer) -> String { "\(s.username)@\(s.host):\(s.port)" }

    /// `credName` resolves a Password Store credential id to its label; nil falls back to the kind's short word.
    static func text(_ s: SSHServer, credName: (String) -> String? = { _ in nil }) -> String {
        let type = s.connectionType == .psmp ? "PSMP" : "direct"
        var login: String
        switch s.credentialKind {
        case .prompt: login = "prompt"
        case .local: login = s.credentialRef.flatMap(credName) ?? "Password Store"
        case .cyberark: login = "CyberArk"
        }
        if s.agentAdded { login += " · added by agent" }
        return [destination(s), type, login].joined(separator: " · ")
    }
}
