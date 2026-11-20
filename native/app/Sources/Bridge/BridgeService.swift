// The calls the bridge screens make to muyad (`bridge.*`, P10), over the same abstract `SSHRpc` the SSH page
// uses: the app passes the Store's `call`, tests pass an in-memory fake. Parameters are camelCase like the
// daemon expects. Nothing here keeps a PIN or a code after the call returns.

import Foundation

enum BridgeMethod {
    static let localListen = "bridge.local_listen", pollInbound = "bridge.poll_inbound", send = "bridge.send", approve = "bridge.approve"
    static let remoteListen = "bridge.remote_listen", pairInvite = "bridge.pair_invite", pairStartListener = "bridge.pair_start_listener"
    static let pairStopListener = "bridge.pair_stop_listener", checkPort = "bridge.check_port", pairConnect = "bridge.pair_connect"
    static let pairConfirmSas = "bridge.pair_confirm_sas", listPeers = "bridge.list_peers", revokePeer = "bridge.revoke_peer", remoteSend = "bridge.remote_send"
    // P11
    static let setCapability = "bridge.set_capability", setAutoRun = "bridge.set_auto_run", auditLog = "bridge.audit_log"
    static let executeTask = "bridge.execute_task", fanOut = "bridge.fan_out", runClaude = "bridge.run_claude"
}

@MainActor
final class BridgeService {
    private let rpc: SSHRpc
    init(rpc: SSHRpc) { self.rpc = rpc }

    private func void(_ method: String, _ params: [String: Any], _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        rpc.call(method, params) { done($0.map { _ in () }) }
    }

    func setLocalListening(_ on: Bool, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        void(BridgeMethod.localListen, ["enable": on], done)
    }

    func pollInbound(_ done: @escaping @MainActor (Result<[BridgeInbound], RpcFailure>) -> Void) {
        rpc.call(BridgeMethod.pollInbound, [:]) { r in
            done(r.map { v in (v as? [[String: Any]] ?? []).compactMap(BridgeInbound.init(json:)) })
        }
    }

    func approve(_ reqId: String, allow: Bool, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        void(BridgeMethod.approve, ["reqId": reqId, "decision": allow ? "allow" : "deny"], done)
    }

    /// The listening Mac's one call to open both the data listener and the pairing window, in the order
    /// the daemon needs, and return the PIN. A wildcard address never leaves this function.
    func openInvite(dataAddr: String, _ done: @escaping @MainActor (Result<BridgeInvite, RpcFailure>) -> Void) {
        guard BridgeAddress.isValidEndpoint(dataAddr), !BridgeAddress.isWildcard(dataAddr), let pairing = BridgeAddress.pairingAddress(forData: dataAddr) else {
            return done(.failure(RpcFailure(message: "Use one specific address of this Mac with a port, for example 192.168.1.5:9876 — not 0.0.0.0.")))
        }
        rpc.call(BridgeMethod.remoteListen, ["enable": true, "iface": dataAddr]) { [rpc] r in
            if case let .failure(e) = r { return done(.failure(e)) }
            rpc.call(BridgeMethod.pairInvite, [:]) { r in
                switch r {
                case let .failure(e): done(.failure(e))
                case let .success(v):
                    guard let invite = (v as? [String: Any]).flatMap(BridgeInvite.init(json:)) else { return done(.failure(RpcFailure(message: "The daemon answered without a PIN."))) }
                    rpc.call(BridgeMethod.pairStartListener, ["pairingIface": pairing]) { r in
                        done(r.map { _ in invite })
                    }
                }
            }
        }
    }

    func closeInvite(_ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        void(BridgeMethod.pairStopListener, [:], done)
    }

    /// `addr` is the pairing address shown on the other Mac next to its PIN.
    func connect(addr: String, pin: String, label: String, _ done: @escaping @MainActor (Result<BridgeDialed, RpcFailure>) -> Void) {
        guard BridgeAddress.isValidEndpoint(addr) else { return done(.failure(RpcFailure(message: "Enter the address as ip:port."))) }
        rpc.call(BridgeMethod.pairConnect, ["addr": addr, "pin": pin, "label": label]) { r in
            switch r {
            case let .failure(e): done(.failure(e))
            case let .success(v):
                guard let d = (v as? [String: Any]).flatMap(BridgeDialed.init(json:)) else { return done(.failure(RpcFailure(message: "The daemon answered without a code."))) }
                done(.success(d))
            }
        }
    }

    /// `theirCode` is what the OTHER Mac shows: when given, a mismatch pins nothing.
    func confirm(peerSpki: String, accept: Bool, label: String, theirCode: String?, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        var p: [String: Any] = ["peerSpki": peerSpki, "sasOk": accept, "label": label]
        if let t = theirCode, !t.trimmingCharacters(in: .whitespaces).isEmpty { p["theirSas"] = t }
        void(BridgeMethod.pairConfirmSas, p, done)
    }

    func peers(_ done: @escaping @MainActor (Result<[BridgePeer], RpcFailure>) -> Void) {
        rpc.call(BridgeMethod.listPeers, [:]) { r in
            done(r.map { v in (v as? [[String: Any]] ?? []).compactMap(BridgePeer.init(json:)) })
        }
    }

    func revoke(_ peer: BridgePeer, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        void(BridgeMethod.revokePeer, ["spkiHash": peer.spkiHash], done)
    }

    /// Sends a question to a paired Mac; the answer is the request id.
    func send(to peer: BridgePeer, text: String, _ done: @escaping @MainActor (Result<String, RpcFailure>) -> Void) {
        rpc.call(BridgeMethod.remoteSend, ["peer": peer.spkiHash, "kind": "question", "payload": ["text": text]]) { r in
            done(r.map { ($0 as? String) ?? "" })
        }
    }

    // MARK: P11 — what a paired Mac may ask for, and the gated run

    func setCapability(_ cap: BridgeCapability, for peer: BridgePeer, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        void(BridgeMethod.setCapability, ["peerSpki": peer.spkiHash, "capability": cap.rawValue], done)
    }

    /// Shell auto-run is only ever sent together with its own explicit override; the daemon refuses it otherwise.
    func setAutoRun(_ caps: Set<BridgeCapability>, shellOverride: Bool, for peer: BridgePeer, _ done: @escaping @MainActor (Result<Void, RpcFailure>) -> Void) {
        void(BridgeMethod.setAutoRun, ["peerSpki": peer.spkiHash, "capabilities": caps.map(\.rawValue).sorted(), "shellAutoRunOverride": shellOverride], done)
    }

    func auditLog(_ done: @escaping @MainActor (Result<[BridgeAuditEntry], RpcFailure>) -> Void) {
        rpc.call(BridgeMethod.auditLog, [:]) { r in
            done(r.map { v in (v as? [[String: Any]] ?? []).compactMap(BridgeAuditEntry.init(json:)) })
        }
    }

    /// Runs a staged task. The daemon re-checks the peer's scope and the approval; this never decides anything itself.
    func execute(reqId: String, peerSpki: String, _ done: @escaping @MainActor (Result<String, RpcFailure>) -> Void) {
        rpc.call(BridgeMethod.executeTask, ["reqId": reqId, "peerSpki": peerSpki]) { r in done(r.map { ($0 as? String) ?? "" }) }
    }

    /// One request id per leg; each leg is gated by its own peer and reports through the fan-out events.
    func fanOut(payload: [String: Any], peers: [BridgePeer], capability: BridgeCapability, _ done: @escaping @MainActor (Result<[String], RpcFailure>) -> Void) {
        let targets: [[String: Any]] = peers.map { ["peer_spki": $0.spkiHash, "capability": capability.rawValue] }
        rpc.call(BridgeMethod.fanOut, ["payload": payload, "targets": targets]) { r in done(r.map { ($0 as? [String]) ?? [] }) }
    }

    func runClaude(_ question: String, _ done: @escaping @MainActor (Result<String, RpcFailure>) -> Void) {
        rpc.call(BridgeMethod.runClaude, ["question": question]) { r in done(r.map { ($0 as? String) ?? "" }) }
    }
}
