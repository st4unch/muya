// P11: the task / fan-out events, the audit entries and the service calls against a fake rpc
// (the gate itself is tested against real daemons in muyad's p11.rs).

import Foundation

func runP11Tests() {
    test("bridge task events: json inside a json string, like today's app") {
        let chunk = #"{"type":"chunk","req_id":"r1","peer":"9062814D4252","seq":3,"data":"hi\n"}"#
        let enc = { (s: String) -> String in String(data: try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]), encoding: .utf8)! }
        check(BridgeEvent.parse(name: "bridge://task-chunk", payload: enc(chunk)) == .taskChunk(reqId: "r1", peer: "9062814D4252", seq: 3, data: "hi\n"), "chunk")
        let end = #"{"type":"end","req_id":"r1","peer":"p","exit_code":2,"output_hash":"ab"}"#
        check(BridgeEvent.parse(name: "bridge://task-end", payload: enc(end)) == .taskEnd(reqId: "r1", peer: "p", exitCode: 2, outputHash: "ab"), "end")
        check(BridgeEvent.parse(name: "bridge://task-rejected", payload: "\"capability rejected: x\"") == .taskRejected("capability rejected: x"), "rejected")
        check(BridgeEvent.parse(name: "bridge://fanout-result", payload: enc(#"{"req_id":"f","peer_spki":"k","result":"exit_code=0, output_hash=1"}"#)) == .fanoutResult(reqId: "f", peerSpki: "k", result: "exit_code=0, output_hash=1"), "fanout result")
        check(BridgeEvent.parse(name: "bridge://fanout-error", payload: enc(#"{"req_id":"f","peer_spki":"k","error":"no"}"#)) == .fanoutError(reqId: "f", peerSpki: "k", error: "no"), "fanout error")
        check(BridgeEvent.parse(name: "bridge://task-chunk", payload: enc("not json")) == nil, "inner garbage")
        check(BridgeEvent.parse(name: "bridge://task-end", payload: enc(#"{"req_id":"r"}"#)) == nil, "end without an exit code")
        check(BridgeEvent.parse(name: "bridge://task-chunk", payload: #"{"req_id":"r","data":"x"}"#) == nil, "chunk that is not a string")
    }

    test("audit entries and capabilities") {
        let e = BridgeAuditEntry(json: ["entry_id": 4, "timestamp": 10, "req_id": "r", "peer_spki": "k", "capability": "shell", "decision": "denied", "payload_hash": "aa", "output_hash": ""])!
        check(e.entryId == 4 && e.wasRefused && e.outputHash.isEmpty, "denied entry")
        check(!BridgeAuditEntry(json: ["entry_id": 1, "req_id": "r", "decision": "auto_run"])!.wasRefused, "auto run is not a refusal")
        check(BridgeAuditEntry(json: ["req_id": "r"]) == nil, "an entry needs an id and a decision")
        check(BridgeCapability.allCases.map(\.rawValue) == ["research", "file", "shell"] && BridgeCapability.shell.needsOverrideForAutoRun && !BridgeCapability.file.needsOverrideForAutoRun, "capabilities")
    }

    test("bridge service: capability, auto-run, execute, fan-out and run_claude send the daemon's parameter names") {
        MainActor.assumeIsolated {
            let rpc = FakeBridgeRpc()
            let svc = BridgeService(rpc: rpc)
            let a = BridgePeer(json: ["spki_hash": "aa"])!, b = BridgePeer(json: ["spki_hash": "bb"])!
            svc.setCapability(.file, for: a) { _ in }
            check(rpc.calls.last!.0 == "bridge.set_capability" && rpc.calls.last!.1["peerSpki"] as? String == "aa" && rpc.calls.last!.1["capability"] as? String == "file", "set capability")
            svc.setAutoRun([.shell, .research], shellOverride: true, for: a) { _ in }
            let p = rpc.calls.last!.1
            check(p["capabilities"] as? [String] == ["research", "shell"] && p["shellAutoRunOverride"] as? Bool == true, "auto-run params \(p)")
            svc.setAutoRun([.research], shellOverride: false, for: a) { _ in }
            check(rpc.calls.last!.1["shellAutoRunOverride"] as? Bool == false, "no override unless asked")
            rpc.answers[BridgeMethod.executeTask] = .success("exit_code=0, output_hash=ab")
            var got = ""
            svc.execute(reqId: "r1", peerSpki: "aa") { if case let .success(s) = $0 { got = s } }
            check(got == "exit_code=0, output_hash=ab" && rpc.calls.last!.1["reqId"] as? String == "r1", "execute")
            rpc.answers[BridgeMethod.executeTask] = .failure(RpcFailure(message: "task r1 not approved"))
            var err = ""
            svc.execute(reqId: "r1", peerSpki: "aa") { if case let .failure(f) = $0 { err = f.message } }
            check(err.contains("not approved"), "a refusal reaches the caller untouched")
            rpc.answers[BridgeMethod.fanOut] = .success(["f1", "f2"] as [Any])
            var ids: [String] = []
            svc.fanOut(payload: ["cmd": ["ls"]], peers: [a, b], capability: .shell) { if case let .success(i) = $0 { ids = i } }
            let targets = rpc.calls.last!.1["targets"] as? [[String: Any]] ?? []
            check(ids == ["f1", "f2"] && targets.count == 2 && targets[1]["peer_spki"] as? String == "bb" && targets[0]["capability"] as? String == "shell", "fan-out targets")
            rpc.answers[BridgeMethod.auditLog] = .success([["entry_id": 0, "req_id": "r", "decision": "approved"], ["bad": 1]] as [Any])
            var n = -1
            svc.auditLog { if case let .success(l) = $0 { n = l.count } }
            check(n == 1, "malformed audit rows are dropped")
            svc.runClaude("hi") { _ in }
            check(rpc.calls.last!.0 == "bridge.run_claude" && rpc.calls.last!.1["question"] as? String == "hi", "run_claude")
        }
    }
}
