// P12: the notes-vault service and models against a fake rpc (the daemon side is tested in muyad's p12.rs), and the
// auto-allow suggestion rules (when the toast shows, for whom, how long).

import Foundation

@MainActor
final class FakeVaultRpc: SSHRpc {
    var calls: [(String, [String: Any])] = []
    var answers: [String: Result<Any, RpcFailure>] = [:]
    func call(_ method: String, _ params: [String: Any], done: @escaping @MainActor (Result<Any, RpcFailure>) -> Void) {
        calls.append((method, params))
        done(answers[method] ?? .success(NSNull()))
    }
    var names: [String] { calls.map(\.0) }
}

func runP12Tests() {
    test("vault status parses the daemon's camelCase answer; garbage is rejected") {
        let s = VaultSource(json: ["configuredPath": "/v/a", "resolvedPath": "/v/a", "serverInstalled": true])
        check(s == VaultSource(configuredPath: "/v/a", resolvedPath: "/v/a", serverInstalled: true), "full")
        let none = VaultSource(json: ["configuredPath": NSNull(), "resolvedPath": NSNull(), "serverInstalled": false])
        check(none?.configuredPath == nil && none?.resolvedPath == nil && none?.serverInstalled == false, "nothing configured")
        check(VaultSource(json: "x") == nil && VaultSource(json: nil) == nil, "not an object")
        check(VaultSource(json: [:])?.serverInstalled == false, "missing flag = not installed")
    }

    test("vault panel text: current line, Set enabled for a non-blank path, error sentences") {
        check(VaultLogic.currentText(nil) == "Not configured — no vault detected.", "no status")
        check(VaultLogic.currentText(VaultSource(resolvedPath: nil)) == VaultLogic.noVaultText, "nothing resolves")
        check(VaultLogic.currentText(VaultSource(resolvedPath: "/v/n")) == "/v/n", "resolved")
        check(!VaultLogic.canSet("") && !VaultLogic.canSet("  \n") && VaultLogic.canSet(" /v "), "canSet")
        check(VaultLogic.normalised("  /v/n \n") == "/v/n", "trimmed")
        check(VaultLogic.errorText("mcp_unavailable") != "mcp_unavailable" && VaultLogic.errorText("not an Obsidian vault (no .obsidian folder found)") == "not an Obsidian vault (no .obsidian folder found)", "codes get sentences, others pass through")
    }

    test("vault service: apply = set_path, restart, status — in that order, and stops at the first failure") {
        MainActor.assumeIsolated {
            let rpc = FakeVaultRpc()
            rpc.answers[VaultMethod.status] = .success(["configuredPath": "/v/n", "resolvedPath": "/v/n", "serverInstalled": true])
            let svc = VaultService(rpc: rpc)
            var got: VaultSource?
            svc.apply("  /v/n ") { if case let .success(s) = $0 { got = s } }
            check(rpc.names == [VaultMethod.setPath, VaultMethod.restart, VaultMethod.status], "calls \(rpc.names)")
            check(rpc.calls[0].1["path"] as? String == "/v/n", "path trimmed")
            check(got?.resolvedPath == "/v/n", "status handed back")

            let bad = FakeVaultRpc()
            bad.answers[VaultMethod.setPath] = .failure(RpcFailure(message: "not an Obsidian vault (no .obsidian folder found)"))
            var err = ""
            VaultService(rpc: bad).apply("/x") { if case let .failure(e) = $0 { err = e.message } }
            check(bad.names == [VaultMethod.setPath] && err.contains("not an Obsidian vault"), "a bad folder never restarts the helper: \(bad.names)")
        }
    }

    test("vault service: candidates, search params and blocks") {
        MainActor.assumeIsolated {
            let rpc = FakeVaultRpc()
            rpc.answers[VaultMethod.candidates] = .success(["/a", "/b"])
            rpc.answers[VaultMethod.search] = .success([["path": "n/a.md", "similarity": 0.9, "text": "alpha", "lines": "1-3"], ["text": "no path"]])
            let svc = VaultService(rpc: rpc)
            var c: [String] = []; svc.candidates { c = $0 }
            check(c == ["/a", "/b"], "candidates")
            var blocks: [VaultBlock] = []
            svc.search("alpha", maxBlocks: 3, timeoutMs: 500) { if case let .success(b) = $0 { blocks = b } }
            check(blocks.count == 1 && blocks[0].path == "n/a.md" && blocks[0].similarity == 0.9 && blocks[0].lines == "1-3", "blocks (a block without a path is dropped)")
            check(rpc.calls.last?.1["maxBlocks"] as? Int == 3 && rpc.calls.last?.1["timeoutMs"] as? Int == 500 && rpc.calls.last?.1["query"] as? String == "alpha", "params")
            rpc.answers[VaultMethod.candidates] = .failure(RpcFailure(message: "unknown method"))
            svc.candidates { c = $0 }
            check(c.isEmpty, "an old daemon: no candidates, no crash")
            var failed = ""
            rpc.answers[VaultMethod.search] = .failure(RpcFailure(message: "mcp_unavailable"))
            svc.search("x") { if case let .failure(e) = $0 { failed = e.message } }
            check(failed == "mcp_unavailable", "error passes through")
        }
    }

    test("auto-allow suggestion: only a NEW prompt, only with Auto-allow off, never for auto / bypass sessions") {
        var l = AutoAllowSuggestLogic()
        let p1 = AutoAllowSuggestLogic.Prompt(session: 1, key: "Bash|ls|", mode: "default")
        let t0 = Date(timeIntervalSince1970: 1000)
        check(l.observe([], autoApprove: false, now: t0) == nil, "no prompt, no toast")
        check(l.observe([p1], autoApprove: false, now: t0) == 1, "a new prompt shows it")
        check(l.observe([p1], autoApprove: false, now: t0 + 5) == nil, "the same prompt again does not")
        l.dismiss()
        check(l.observe([p1], autoApprove: false, now: t0 + 6) == nil, "after closing, the same prompt does not bring it back")
        check(l.observe([], autoApprove: false) == nil && l.observe([p1], autoApprove: false) == 1, "the prompt went away and came back: new")
        var on = AutoAllowSuggestLogic()
        check(on.observe([p1], autoApprove: true) == nil, "Auto-allow already on")
        var auto = AutoAllowSuggestLogic()
        check(auto.observe([.init(session: 2, key: "k", mode: "auto")], autoApprove: false) == nil, "session in auto mode")
        check(auto.observe([.init(session: 3, key: "k", mode: "bypass")], autoApprove: false) == nil, "session in bypass mode")
        var two = AutoAllowSuggestLogic()
        _ = two.observe([p1], autoApprove: false)
        check(two.observe([p1, .init(session: 2, key: "Edit|f|", mode: "default")], autoApprove: false) == 2, "a newer prompt in another session replaces the toast's subject")
        check(two.shownFor == 2, "shownFor follows")
    }

    test("auto-allow suggestion: 30 s lifetime, words of the toast") {
        var l = AutoAllowSuggestLogic()
        let t0 = Date(timeIntervalSince1970: 5000)
        _ = l.observe([.init(session: 1, key: "k", mode: "default")], autoApprove: false, now: t0)
        check(!l.expired(now: t0 + 29.9) && l.expired(now: t0 + 30), "expires at 30 s")
        l.dismiss()
        check(!l.expired(now: t0 + 100), "nothing shown, nothing expires")
        check(AutoAllowSuggestLogic.title == "Turn on Auto-allow?", "title")
        check(AutoAllowSuggestLogic.body(agentName: "api-fix") == "api-fix is asking for permission. With Auto-allow on, Muya clicks Allow for you after 2 seconds, in every session.", "body")
    }
}
