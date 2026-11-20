// P10: the bridge models, events and service calls against a fake rpc (the daemon side is tested in muyad's p10.rs).

import Foundation

@MainActor
final class FakeBridgeRpc: SSHRpc {
    var calls: [(String, [String: Any])] = []
    var answers: [String: Result<Any, RpcFailure>] = [:]
    func call(_ method: String, _ params: [String: Any], done: @escaping @MainActor (Result<Any, RpcFailure>) -> Void) {
        calls.append((method, params))
        done(answers[method] ?? .success(NSNull()))
    }
    var names: [String] { calls.map(\.0) }
}

func runP10Tests() {
    test("bridge events: the six names and payload shapes parse; others do not") {
        check(BridgeEvent.parse(name: "bridge://inbound-request", payload: "\"req-1\"") == .inboundRequest(id: "req-1"), "inbound-request")
        check(BridgeEvent.parse(name: "bridge://peer-status", payload: "\"remote_listener:started\"") == .peerStatus("remote_listener:started"), "peer-status")
        check(BridgeEvent.parse(name: "bridge://pairing-status", payload: "\"pairing_listener:stopped\"") == .pairingStatus("pairing_listener:stopped"), "pairing-status")
        check(BridgeEvent.parse(name: "bridge://error", payload: "\"handshake_rejected:1.2.3.4:5:boom\"") == .error("handshake_rejected:1.2.3.4:5:boom"), "error")
        check(BridgeEvent.parse(name: "bridge://held", payload: "3") == .held(count: 3), "held")
        check(BridgeEvent.parse(name: "bridge://sas-compare", payload: #"{"sas":"EEBB90","peerSpki":"ab12","peerAddr":"127.0.0.1:5"}"#) == .sasCompare(sas: "EEBB90", peerSpki: "ab12", peerAddr: "127.0.0.1:5"), "sas-compare")
        check(BridgeEvent.parse(name: "bridge://sas-compare", payload: #"{"sas":"X"}"#) == nil, "sas-compare without a key")
        check(BridgeEvent.parse(name: "bridge://held", payload: "\"x\"") == nil, "held with the wrong type")
        check(BridgeEvent.parse(name: "muya://vault-locked", payload: "null") == nil, "not a bridge event")
        check(BridgeEvent.parse(name: "bridge://error", payload: "{oops") == nil, "bad json")
    }

    test("paired Macs: who paired, messaging vs full") {
        let agent = BridgePeer(json: ["spki_hash": "9062814d4252b0ce", "label": "Work", "capability": "messaging", "paired_by": "agent"])!
        check(agent.pairedByAgent && agent.isMessagingOnly && agent.pairedLine == "Paired by agent · 9062814D", "agent peer \(agent.pairedLine)")
        let old = BridgePeer(json: ["spki_hash": "aa", "capability": "research"])!
        check(!old.pairedByAgent && !old.isMessagingOnly && old.pairedLine == "Paired by you · AA", "a registry without paired_by is operator-paired and Full")
        check(PeerScope(index: 0) == .messaging && PeerScope(index: 1) == .full && PeerScope.titles == ["Messaging", "Full"] && PeerScope.full.rawValue == "full", "scope switch")
    }

    test("bridge models decode the daemon's answers") {
        let peer = BridgePeer(json: ["spki_hash": "9062814d4252b0ce", "label": "", "last_addr": "10.0.0.2:9876", "paired_at": 1700000000, "capability": "research"])!
        check(peer.label == "Unnamed Mac" && peer.fingerprint == "9062814D" && peer.weDial, "peer \(peer)")
        check(BridgePeer(json: ["label": "x"]) == nil, "a peer needs a key")
        check(BridgePeer(json: ["spki_hash": "a"])!.weDial == false, "no address: it polls us")
        let inv = BridgeInvite(json: ["pin": "12345678", "expires_at": 2000, "our_spki": "k"])!
        check(inv.spacedPin == "1234 5678" && inv.secondsLeft(now: Date(timeIntervalSince1970: 1990)) == 10 && inv.secondsLeft(now: Date(timeIntervalSince1970: 5000)) == 0, "invite")
        check(BridgeInvite(json: ["pin": ""]) == nil, "an invite needs a PIN")
        check(BridgeDialed(json: ["sas": "ABC123", "peer_spki": "k"])?.sas == "ABC123" && BridgeDialed(json: ["sas": "A"]) == nil, "dialed")
        let req = BridgeInbound(json: ["req_id": "r", "peer": "cli", "capability": "shell", "kind": "task", "approval": "pending_approval"])!
        check(req.needsApproval && !BridgeInbound(json: ["req_id": "q", "approval": "not_required"])!.needsApproval, "approval gate")
    }

    test("bridge addresses: wildcards are refused before anything is sent; pairing port is data + 1") {
        for a in ["0.0.0.0:9876", "[::]:9876", "[::ffff:0.0.0.0]:9876", ":9876"] { check(BridgeAddress.isWildcard(a), "\(a) is a wildcard") }
        for a in ["192.168.1.5:9876", "[fe80::1]:9876", "127.0.0.1:1"] { check(!BridgeAddress.isWildcard(a), "\(a) is fine") }
        check(BridgeAddress.pairingAddress(forData: "192.168.1.5:9876") == "192.168.1.5:9877", "ipv4 pairing")
        check(BridgeAddress.pairingAddress(forData: "[fe80::1]:9876") == "[fe80::1]:9877", "ipv6 pairing")
        check(BridgeAddress.pairingAddress(forData: "10.0.0.1:65535") == nil && BridgeAddress.pairingAddress(forData: "nope") == nil, "no room / not an address")
        check(BridgeAddress.isValidEndpoint("10.0.0.1:80") && !BridgeAddress.isValidEndpoint("10.0.0.1") && !BridgeAddress.isValidEndpoint("10.0.0.1:0"), "endpoint validation")
    }

    test("pairing flow: listening side and dialing side, and the failure paths") {
        var f = PairingFlow()
        let invite = BridgeInvite(json: ["pin": "11112222", "expires_at": 1, "our_spki": "me"])!
        f.invited(invite)
        check(f.phase == .inviting(invite) && f.pendingConfirm == nil, "invited")
        f.apply(.peerStatus("remote_listener:started")); check(f.phase == .inviting(invite), "unrelated events change nothing")
        f.apply(.sasCompare(sas: "AAA111", peerSpki: "k2", peerAddr: "1.2.3.4:5"))
        check(f.pendingConfirm?.sas == "AAA111" && f.pendingConfirm?.peerSpki == "k2", "listener learns the code from the event")
        f.apply(.pairingStatus("pairing_listener:stopped")); check(f.pendingConfirm != nil, "the single-use window closing does not drop the code")
        f.confirmed(label: "Office"); check(f.phase == .paired(label: "Office"), "paired")

        var d = PairingFlow()
        d.dialed(BridgeDialed(json: ["sas": "BBB222", "peer_spki": "k3"])!, addr: "5.6.7.8:9")
        check(d.phase == .comparing(sas: "BBB222", peerSpki: "k3", peerAddr: "5.6.7.8:9", weDialed: true), "dialer compares")
        d.rejected(); check(d.phase == .idle && d.pendingConfirm == nil, "rejecting clears the code")

        var e = PairingFlow(); e.invited(invite)
        e.apply(.error("pairing_failed:1.2.3.4:5:bad"))
        if case let .failed(msg) = e.phase { check(msg.contains("pairing attempt failed"), msg) } else { check(false, "failed expected") }
        var g = PairingFlow(); g.invited(invite); g.apply(.pairingStatus("pairing_listener:stopped")); check(g.phase == .idle, "window expired with nobody")
        check(BridgeErrorText.friendly("handshake_rejected:1.2.3.4:5:x").contains("not paired"), "friendly handshake text")
        check(BridgeErrorText.friendly("something_new:x") == "Bridge problem: something new.", "unknown reason keeps its words")
    }

    test("bridge service: invite opens the listener, the PIN and the pairing window in order; wildcard never sent") {
        MainActor.assumeIsolated {
            let rpc = FakeBridgeRpc()
            rpc.answers[BridgeMethod.pairInvite] = .success(["pin": "87654321", "expires_at": 9, "our_spki": "me"] as [String: Any])
            let svc = BridgeService(rpc: rpc)
            var got: BridgeInvite?
            svc.openInvite(dataAddr: "192.168.1.5:9876") { if case let .success(i) = $0 { got = i } }
            check(got?.pin == "87654321", "invite returned")
            check(rpc.names == [BridgeMethod.remoteListen, BridgeMethod.pairInvite, BridgeMethod.pairStartListener], "order: \(rpc.names)")
            check(rpc.calls[0].1["iface"] as? String == "192.168.1.5:9876" && rpc.calls[0].1["enable"] as? Bool == true, "listen params")
            check(rpc.calls[2].1["pairingIface"] as? String == "192.168.1.5:9877", "pairing window one port up")

            let before = rpc.calls.count
            var refused: String?
            svc.openInvite(dataAddr: "0.0.0.0:9876") { if case let .failure(e) = $0 { refused = e.message } }
            check(refused?.contains("specific address") == true && rpc.calls.count == before, "wildcard refused locally, nothing sent")

            // A failing first step stops the chain.
            let bad = FakeBridgeRpc(); bad.answers[BridgeMethod.remoteListen] = .failure(RpcFailure(message: "address in use"))
            var err: String?
            BridgeService(rpc: bad).openInvite(dataAddr: "10.0.0.1:9000") { if case let .failure(e) = $0 { err = e.message } }
            check(err == "address in use" && bad.names == [BridgeMethod.remoteListen], "stops at the first failure: \(bad.names)")
        }
    }

    test("bridge service: connect, confirm (with the other Mac's code), peers, revoke, approve, send") {
        MainActor.assumeIsolated {
            let rpc = FakeBridgeRpc()
            rpc.answers[BridgeMethod.pairConnect] = .success(["sas": "CCC333", "peer_spki": "kk"] as [String: Any])
            rpc.answers[BridgeMethod.listPeers] = .success([["spki_hash": "kk", "label": "Lab", "last_addr": "1.1.1.1:9", "paired_at": 5, "capability": "research"]] as [[String: Any]])
            rpc.answers[BridgeMethod.remoteSend] = .success("remote-1-2")
            let svc = BridgeService(rpc: rpc)

            var refused = false
            svc.connect(addr: "no-port", pin: "1", label: "x") { if case .failure = $0 { refused = true } }
            check(refused && rpc.calls.isEmpty, "a bad address is refused locally")
            var dialed: BridgeDialed?
            svc.connect(addr: "1.1.1.1:9877", pin: "12345678", label: "Lab") { if case let .success(d) = $0 { dialed = d } }
            check(dialed?.sas == "CCC333" && rpc.calls[0].1["pin"] as? String == "12345678", "connect")

            svc.confirm(peerSpki: "kk", accept: true, label: "Lab", theirCode: "ccc333") { _ in }
            check(rpc.calls.last?.1["theirSas"] as? String == "ccc333" && rpc.calls.last?.1["sasOk"] as? Bool == true, "their code is sent for comparison")
            svc.confirm(peerSpki: "kk", accept: false, label: "Lab", theirCode: "  ") { _ in }
            check(rpc.calls.last?.1["theirSas"] == nil, "a blank code is not sent")

            var peers: [BridgePeer] = []
            svc.peers { if case let .success(p) = $0 { peers = p } }
            check(peers.map(\.label) == ["Lab"], "peers")
            svc.revoke(peers[0]) { _ in }
            check(rpc.calls.last?.0 == BridgeMethod.revokePeer && rpc.calls.last?.1["spkiHash"] as? String == "kk", "revoke by key")
            svc.approve("r1", allow: false) { _ in }
            check(rpc.calls.last?.1["decision"] as? String == "deny" && rpc.calls.last?.1["reqId"] as? String == "r1", "approve/deny")
            var id = ""
            svc.send(to: peers[0], text: "hi") { if case let .success(s) = $0 { id = s } }
            check(id == "remote-1-2" && rpc.calls.last?.1["kind"] as? String == "question", "send is a question, never a task")
        }
    }
}
