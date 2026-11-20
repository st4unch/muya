// P10: the bridge (local socket + remote pairing) as the app sees it: the typed answers of the daemon's
// `bridge.*` calls, the six `bridge://…` events, and the small state machine behind a pairing. Foundation only,
// no UI and no I/O, so the tests run it as it is. Pairing PINs and the confirmation codes are shown to the
// operator and never written to a log or a file here.

import Foundation

// MARK: Daemon answers

/// One paired Mac (`bridge.list_peers`).
struct BridgePeer: Equatable {
    var spkiHash: String
    var label: String
    var lastAddr: String?
    var pairedAt: Int
    var capability: String
    /// "operator" (paired in the app) or "agent" (paired by an agent through MCP `bridge_confirm`).
    var pairedBy: String

    init?(json o: [String: Any]) {
        guard let h = o["spki_hash"] as? String, !h.isEmpty else { return nil }
        spkiHash = h
        label = (o["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed Mac"
        lastAddr = o["last_addr"] as? String
        pairedAt = (o["paired_at"] as? NSNumber)?.intValue ?? 0
        capability = o["capability"] as? String ?? "research"
        pairedBy = o["paired_by"] as? String ?? "operator"
    }

    /// Settings > Paired Macs: "messaging" is the minimal scope of an agent-paired Mac; everything else is Full.
    var isMessagingOnly: Bool { capability == "messaging" }
    var pairedByAgent: Bool { pairedBy == "agent" }
    /// "Paired by an agent · 9062814D" / "Paired by you · …": the helper line of the row.
    var pairedLine: String { "Paired by \(pairedByAgent ? "agent" : "you") · \(fingerprint)" }

    /// The first characters of the key hash: what two people read to each other to tell peers apart.
    var fingerprint: String { String(spkiHash.prefix(8)).uppercased() }
    /// A peer with an address is the listening side: we dial it. Without one it polls us.
    var weDial: Bool { lastAddr != nil }
}

/// `bridge.pair_invite`: the PIN to read to the other Mac.
struct BridgeInvite: Equatable {
    var pin: String
    var expiresAt: Int
    var ourSpki: String

    init?(json o: [String: Any]) {
        guard let pin = o["pin"] as? String, !pin.isEmpty else { return nil }
        self.pin = pin
        expiresAt = (o["expires_at"] as? NSNumber)?.intValue ?? 0
        ourSpki = o["our_spki"] as? String ?? ""
    }

    func secondsLeft(now: Date = Date()) -> Int { max(0, expiresAt - Int(now.timeIntervalSince1970)) }
    /// "1234 5678" — easier to read aloud.
    var spacedPin: String { pin.count == 8 ? String(pin.prefix(4)) + " " + String(pin.suffix(4)) : pin }
}

/// `bridge.pair_connect`: the code this Mac derived and the key of the Mac it reached.
struct BridgeDialed: Equatable {
    var sas: String
    var peerSpki: String
    init?(json o: [String: Any]) {
        guard let sas = o["sas"] as? String, let spki = o["peer_spki"] as? String else { return nil }
        self.sas = sas; peerSpki = spki
    }
}

/// One staged request from the local bridge socket (`bridge.poll_inbound`).
struct BridgeInbound: Equatable {
    var reqId: String
    var peer: String
    var capability: String
    var kind: String
    var approval: String

    init?(json o: [String: Any]) {
        guard let id = o["req_id"] as? String else { return nil }
        reqId = id
        peer = o["peer"] as? String ?? ""
        capability = o["capability"] as? String ?? ""
        kind = o["kind"] as? String ?? ""
        approval = o["approval"] as? String ?? "not_required"
    }

    /// Nothing runs for a task that waits here until the operator answers.
    var needsApproval: Bool { approval == "pending_approval" }
}

// MARK: Events

/// The six `Control::Event`s of the bridge, with the names and payload shapes of today's Muya.
enum BridgeEvent: Equatable {
    case inboundRequest(id: String)
    case peerStatus(String)
    case pairingStatus(String)
    case error(String)
    case sasCompare(sas: String, peerSpki: String, peerAddr: String)
    case held(count: Int)
    // P11 (gated tasks). The daemon sends these three and the fan-out pair as JSON *inside* a JSON string, like today's app.
    case taskChunk(reqId: String, peer: String, seq: Int, data: String)
    case taskEnd(reqId: String, peer: String, exitCode: Int, outputHash: String)
    case taskRejected(String)
    case fanoutResult(reqId: String, peerSpki: String, result: String)
    case fanoutError(reqId: String, peerSpki: String, error: String)

    static let names = ["bridge://inbound-request", "bridge://peer-status", "bridge://pairing-status", "bridge://error", "bridge://sas-compare", "bridge://held",
                        "bridge://task-chunk", "bridge://task-end", "bridge://task-rejected", "bridge://fanout-result", "bridge://fanout-error"]

    private static func inner(_ v: Any) -> [String: Any]? {
        guard let s = v as? String, let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// `payload` is the JSON text the daemon sent. Anything that is not a bridge event, or does not fit, is nil.
    static func parse(name: String, payload: String) -> BridgeEvent? {
        guard names.contains(name), let data = payload.data(using: .utf8),
              let v = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        switch name {
        case "bridge://inbound-request": return (v as? String).map { .inboundRequest(id: $0) }
        case "bridge://peer-status": return (v as? String).map { .peerStatus($0) }
        case "bridge://pairing-status": return (v as? String).map { .pairingStatus($0) }
        case "bridge://error": return (v as? String).map { .error($0) }
        case "bridge://held": return (v as? NSNumber).map { .held(count: $0.intValue) }
        case "bridge://sas-compare":
            guard let o = v as? [String: Any], let sas = o["sas"] as? String, let spki = o["peerSpki"] as? String else { return nil }
            return .sasCompare(sas: sas, peerSpki: spki, peerAddr: o["peerAddr"] as? String ?? "")
        case "bridge://task-rejected": return (v as? String).map { .taskRejected($0) }
        case "bridge://task-chunk":
            guard let o = inner(v), let id = o["req_id"] as? String, let data = o["data"] as? String else { return nil }
            return .taskChunk(reqId: id, peer: o["peer"] as? String ?? "", seq: (o["seq"] as? NSNumber)?.intValue ?? 0, data: data)
        case "bridge://task-end":
            guard let o = inner(v), let id = o["req_id"] as? String, let code = (o["exit_code"] as? NSNumber)?.intValue else { return nil }
            return .taskEnd(reqId: id, peer: o["peer"] as? String ?? "", exitCode: code, outputHash: o["output_hash"] as? String ?? "")
        case "bridge://fanout-result":
            guard let o = inner(v), let id = o["req_id"] as? String, let spki = o["peer_spki"] as? String, let r = o["result"] as? String else { return nil }
            return .fanoutResult(reqId: id, peerSpki: spki, result: r)
        case "bridge://fanout-error":
            guard let o = inner(v), let id = o["req_id"] as? String, let spki = o["peer_spki"] as? String, let e = o["error"] as? String else { return nil }
            return .fanoutError(reqId: id, peerSpki: spki, error: e)
        default: return nil
        }
    }
}

/// `bridge.audit_log` entries: a decision and two hashes, never the task's text or output.
struct BridgeAuditEntry: Equatable {
    var entryId: Int, timestamp: Int
    var reqId: String, peerSpki: String, capability: String, decision: String
    var payloadHash: String, outputHash: String

    init?(json o: [String: Any]) {
        guard let id = (o["entry_id"] as? NSNumber)?.intValue, let req = o["req_id"] as? String, let d = o["decision"] as? String else { return nil }
        entryId = id; reqId = req; decision = d
        timestamp = (o["timestamp"] as? NSNumber)?.intValue ?? 0
        peerSpki = o["peer_spki"] as? String ?? ""
        capability = o["capability"] as? String ?? ""
        payloadHash = o["payload_hash"] as? String ?? ""
        outputHash = o["output_hash"] as? String ?? ""
    }

    var wasRefused: Bool { decision == "denied" || decision == "capability_rejected" || decision == "payload_too_large" }
}

/// The three levels a Mac can be granted, narrowest first. Shell auto-run needs a second, separate switch.
/// The two scopes the Paired Macs row offers; the daemon stores them as "messaging" and "research".
enum PeerScope: String, CaseIterable {
    case messaging, full
    static let titles = ["Messaging", "Full"]
    init(index: Int) { self = index == 0 ? .messaging : .full }
    var index: Int { self == .messaging ? 0 : 1 }
}

enum BridgeCapability: String, CaseIterable {
    case research, file, shell
    var needsOverrideForAutoRun: Bool { self == .shell }
}

enum BridgeErrorText {
    /// The daemon's `bridge://error` strings are `reason:address[:detail]`; this is what the operator reads.
    static func friendly(_ raw: String) -> String {
        let reason = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
        switch reason {
        case "handshake_rejected": return "A Mac that is not paired (or was revoked) tried to connect and was turned away."
        case "no_client_cert": return "A connection without a certificate was turned away."
        case "pairing_failed": return "A pairing attempt failed. Start again with a new PIN."
        case "pairing_tls_failed": return "A pairing attempt could not set up a secure connection."
        default: return "Bridge problem: \(reason.replacingOccurrences(of: "_", with: " "))."
        }
    }
}

// MARK: Addresses

enum BridgeAddress {
    /// The bridge listens on one interface address, never on all of them. The daemon refuses these too;
    /// the form says so before sending.
    static func isWildcard(_ addr: String) -> Bool {
        guard let (host, _) = split(addr) else { return false }
        let h = host.lowercased().replacingOccurrences(of: "::ffff:", with: "")
        return h == "0.0.0.0" || h == "::" || h == "0:0:0:0:0:0:0:0" || h.isEmpty
    }

    /// `ip:port` or `[ip6]:port`.
    static func split(_ addr: String) -> (String, Int)? {
        let a = addr.trimmingCharacters(in: .whitespaces)
        if a.hasPrefix("[") {
            guard let close = a.firstIndex(of: "]"), a.index(after: close) < a.endIndex, a[a.index(after: close)] == ":",
                  let port = Int(a[a.index(close, offsetBy: 2)...]) else { return nil }
            return (String(a[a.index(after: a.startIndex)..<close]), port)
        }
        guard let colon = a.lastIndex(of: ":"), let port = Int(a[a.index(after: colon)...]) else { return nil }
        return (String(a[..<colon]), port)
    }

    /// The pairing window opens one port above the data listener.
    static func pairingAddress(forData addr: String) -> String? {
        guard let (host, port) = split(addr), (1...65534).contains(port) else { return nil }
        return host.contains(":") ? "[\(host)]:\(port + 1)" : "\(host):\(port + 1)"
    }

    static func isValidEndpoint(_ addr: String) -> Bool {
        guard let (host, port) = split(addr) else { return false }
        return !host.isEmpty && (1...65535).contains(port)
    }
}

// MARK: Pairing state machine

/// Both sides of a pairing as one screen state. The listening Mac shows a PIN and waits; the dialing Mac
/// types the PIN. Either way the two Macs then show the same short code and the operator confirms that they match.
struct PairingFlow: Equatable {
    enum Phase: Equatable {
        case idle
        /// Listening side: PIN shown, window open.
        case inviting(BridgeInvite)
        /// Both sides: a code to compare with the other Mac's screen.
        case comparing(sas: String, peerSpki: String, peerAddr: String, weDialed: Bool)
        case paired(label: String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    mutating func invited(_ i: BridgeInvite) { phase = .inviting(i) }
    mutating func dialed(_ d: BridgeDialed, addr: String) { phase = .comparing(sas: d.sas, peerSpki: d.peerSpki, peerAddr: addr, weDialed: true) }
    mutating func confirmed(label: String) { phase = .paired(label: label) }
    mutating func rejected() { phase = .idle }
    mutating func failed(_ why: String) { phase = .failed(why) }
    mutating func reset() { phase = .idle }

    /// The listening side learns about the dialer through the event.
    mutating func apply(_ e: BridgeEvent) {
        switch (phase, e) {
        case let (.inviting, .sasCompare(sas, spki, addr)):
            phase = .comparing(sas: sas, peerSpki: spki, peerAddr: addr, weDialed: false)
        case let (.inviting, .error(raw)) where raw.hasPrefix("pairing_"):
            phase = .failed(BridgeErrorText.friendly(raw))
        case (.inviting, .pairingStatus("pairing_listener:stopped")):
            // The window is single use: it also closes after a dialer connected, which arrives as sas-compare first.
            phase = .idle
        default: break
        }
    }

    /// The code and key to pass to `bridge.pair_confirm_sas`, only while comparing.
    var pendingConfirm: (sas: String, peerSpki: String)? {
        if case let .comparing(sas, spki, _, _) = phase { return (sas, spki) }
        return nil
    }
}
