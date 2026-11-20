// P7: the Resources page models and rules, the slash-command list, and the service calls against a fake rpc
// (the daemon side is tested in muyad's p7.rs).

import Foundation

func runP7Tests() {
    test("resources: the daemon's payload parses; missing fields default") {
        let v: [String: Any] = [
            "skills": [["name": "alpha", "path": "/h/.claude/skills/alpha"]], "agents": [["name": "helper", "path": "/h/a.md"]], "hooks": [],
            "mcps": [["name": "files", "command": "npx", "description": "d", "agent": "opencode"], ["name": "bare"]],
        ]
        let r = ClaudeResources(json: v)
        check(r?.skills == [ResourceItem(name: "alpha", path: "/h/.claude/skills/alpha")], "skills")
        check(r?.mcps.count == 2 && r?.mcps[0].agent == "opencode" && r?.mcps[1].agent == "claude" && r?.mcps[1].command == "", "mcps default to claude, empty command")
        check(ClaudeResources(json: "x") == nil, "garbage is refused")
    }

    test("resources: search matches names (MCPs also descriptions), case-insensitively") {
        var r = ClaudeResources()
        r.skills = [ResourceItem(name: "Review", path: "/a"), ResourceItem(name: "deploy", path: "/b")]
        r.mcps = [ResourceMcp(name: "files", command: "npx", description: "Reads Folders", agent: "claude")]
        check(ResourcesLogic.filtered(r, tab: .skills, query: " REV ").skills.map(\.name) == ["Review"], "skill filter")
        check(ResourcesLogic.filtered(r, tab: .mcps, query: "folders").mcps.count == 1, "mcp description")
        check(ResourcesLogic.filtered(r, tab: .skills, query: "").skills.count == 2, "empty keeps all")
    }

    test("marketplace: payloads parse; only https links open; skill text candidates") {
        let s = MarketSkill(json: ["name": "n", "githubUrl": "https://github.com/a/n", "featured": true, "stars": "12"])
        check(s?.featured == true && s?.stars == "12" && s?.author == "", "skill fields")
        let m = MarketMcpResult(json: ["items": [["name": "x", "command": "npx", "args": ["-y", "p"], "source": "https://glama.ai/x"]], "openBrowser": true])
        check(m?.items.first?.args == ["-y", "p"] && m?.openBrowser == true, "mcp result")
        check(ResourcesLogic.isHttps("https://a.b") && !ResourcesLogic.isHttps("file:///etc/passwd") && !ResourcesLogic.isHttps("javascript:alert(1)") && !ResourcesLogic.isHttps("x"), "https only")
        check(ResourcesLogic.skillFileCandidates(ResourceItem(name: "s", path: "/p")) == ["/p/README.md", "/p/skill.md", "/p/s.md"], "candidates")
    }

    test("create with Claude: the command quotes the prompt, so nothing in it runs") {
        let p = ResourcesLogic.createPrompt(kind: "Skill", request: "  it's $(rm -rf ~) `x`  ")
        check(p.hasSuffix("User request: it's $(rm -rf ~) `x`") && p.contains("skill author"), "prompt")
        let c = ResourcesLogic.createCommand(prompt: p)
        check(c.hasPrefix("claude '") && c.hasSuffix("'") && c.contains("it'\\''s"), "single quotes escaped")
        check(ResourcesLogic.createPrompt(kind: "Hook", request: "x").contains("hooks expert") && ResourcesLogic.createPrompt(kind: "MCP", request: "x").contains("MCP"), "kinds")
    }

    test("slash: built-ins first; a custom command shadowing a built-in is dropped; disk order is project, user, skill") {
        let disk = [SlashItem(name: "zed", description: "", source: .skill), SlashItem(name: "compact", description: "mine", source: .user),
                    SlashItem(name: "deploy", description: "", source: .user), SlashItem(name: "build", description: "", source: .project), SlashItem(name: "deploy", description: "dup", source: .project)]
        let m = SlashLogic.merge(agent: "claude", disk: disk)
        let builtinCount = SlashLogic.builtins(agent: "claude").count
        check(builtinCount == 99 && m.prefix(builtinCount).allSatisfy { $0.source == .builtin }, "99 built-ins lead")
        check(m.dropFirst(builtinCount).map(\.name) == ["build", "deploy", "zed"], "disk: \(m.dropFirst(builtinCount).map(\.name))")
        check(m.filter { $0.name == "compact" }.count == 1 && m.first { $0.name == "compact" }?.source == .builtin, "built-in wins")
        check(m.first { $0.name == "deploy" }?.source == .project, "first duplicate kept")
        check(SlashLogic.builtins(agent: "opencode").count == 17, "opencode list")
    }

    test("slash: the filter puts prefix matches first, accepts a leading /, and searches descriptions") {
        let items = [SlashItem(name: "review", description: "Check", source: .builtin), SlashItem(name: "pr", description: "do a review", source: .builtin), SlashItem(name: "rev-x", description: "", source: .user)]
        check(SlashLogic.filter(items, query: "/rev").map(\.name) == ["review", "rev-x", "pr"], "order")
        check(SlashLogic.filter(items, query: "  ").count == 3, "blank keeps all")
        check(SlashLogic.filter(items, query: "zzz").isEmpty, "no match")
        check(SlashLogic.grouped(items).map(\.name) == ["review", "pr", "rev-x"], "builtin group before user")
        check(SlashLogic.move(0, by: -1, count: 3) == 2 && SlashLogic.move(2, by: 1, count: 3) == 0 && SlashLogic.move(0, by: 1, count: 0) == 0, "wraps")
    }

    test("resources service: right method names and parameters; answers are mapped") {
        MainActor.assumeIsolated {
            let rpc = FakeBridgeRpc()
            let svc = ResourcesService(rpc: rpc)
            rpc.answers["resources.list"] = .success(["skills": [["name": "a", "path": "/a"]], "agents": [], "hooks": [], "mcps": []] as [String: Any])
            rpc.answers["resources.skills_market"] = .success([["name": "s", "githubUrl": "https://github.com/x/s"]] as [[String: Any]])
            rpc.answers["resources.install_muya_plugin"] = .success("muya-mcp plugin installed.")
            rpc.answers["slash.list"] = .success([["name": "deploy", "description": "Ship", "source": "user"], ["name": "bad", "source": "nope"]] as [[String: Any]])
            rpc.answers["term_history.entries"] = .success([["key": "tab-1", "name": "b", "cwd": "/w", "updatedMs": 5, "total": 2, "entries": [["ts": 1700000000, "cmd": "ls"], ["ts": NSNull(), "cmd": "pwd"]]]] as [[String: Any]])
            rpc.answers["resources.install_skill"] = .failure(RpcFailure(message: "already exists"))
            var got: [String] = []
            svc.list { if case let .success(r) = $0 { got.append("list:\(r.skills.count)") } }
            svc.marketSkills("git") { if case let .success(r) = $0 { got.append("market:\(r[0].name)") } }
            svc.installMuyaPlugin { if case let .success(m) = $0 { got.append(m) } }
            svc.slashDisk(agent: "claude", cwd: "/w") { got.append("slash:\($0.map(\.name))") }
            svc.termHistory { if case let .success(t) = $0 { got.append("hist:\(t[0].entries.count):\(t[0].entries[1].ts == nil)") } }
            svc.installSkill(MarketSkill(json: ["name": "n", "githubUrl": "https://github.com/a/n"])!) { if case let .failure(e) = $0 { got.append(e.message) } }
            svc.installMcp(MarketMcp(json: ["name": "m", "command": "npx", "args": ["-y"]])!) { _ in }
            svc.termHistoryExport(dest: "/tmp/x.txt", text: "ls") { _ in }
            svc.termHistoryDelete(key: "tab-1") { _ in }
            svc.statusline(ptyId: "pty-1") { _ in }
            check(got == ["list:1", "market:s", "muya-mcp plugin installed.", "slash:[\"deploy\"]", "hist:2:true", "already exists"], "answers: \(got)")
            check(rpc.names == ["resources.list", "resources.skills_market", "resources.install_muya_plugin", "slash.list", "term_history.entries", "resources.install_skill", "resources.install_mcp", "term_history.export", "term_history.delete", "statusline.get"], "methods: \(rpc.names)")
            check((rpc.calls[5].1["githubUrl"] as? String) == "https://github.com/a/n" && (rpc.calls[6].1["args"] as? [String]) == ["-y"], "parameter names the daemon expects")
            check((rpc.calls[3].1["cwd"] as? String) == "/w" && (rpc.calls[3].1["agent"] as? String) == "claude", "slash params")
        }
    }
}
