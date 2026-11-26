// NewAgentCommand.build: the same expected strings as src/lib/agent.test.ts and src/components/NewAgentModal.test.tsx, plus a
// real /bin/sh run that proves quoting: a prompt with ' and $(touch x) and newlines arrives as ONE argument and nothing runs.

import Foundation

func runNewAgentTests() {
    func b(_ kind: Int = 0, mode: String = "auto", manager: Bool = false, branch: String = "", prompt: String = "", files: [String] = []) -> String {
        NewAgentCommand.build(kind: kind, mode: mode, agentsManager: manager, branch: branch, prompt: prompt, files: files)
    }

    test("new agent: Claude Code defaults to --permission-mode auto, every mode has its flag") {
        check(b() == "claude --permission-mode auto", "default")
        check(b(mode: "manual") == "claude --permission-mode manual", "manual")
        check(b(mode: "acceptEdits") == "claude --permission-mode acceptEdits", "acceptEdits")
        check(b(mode: "plan") == "claude --permission-mode plan", "plan")
        check(b(mode: "bypass") == "claude --dangerously-skip-permissions", "bypass")
    }

    test("new agent: prompt quoting, @files, opencode --prompt, agents manager, Terminal") {
        check(b(prompt: "fix bug") == "claude --permission-mode auto 'fix bug'", "quoted prompt")
        check(b(prompt: "do it", files: ["/a.ts", "/b.ts"]) == "claude --permission-mode auto '@/a.ts @/b.ts do it'", "files before the prompt")
        check(b(prompt: "it's broken") == "claude --permission-mode auto 'it'\\''s broken'", "single quote escaped")
        check(NewAgentCommand.singleQuote("a'b") == "'a'\\''b'", "singleQuote")
        check(b(prompt: "  fix it \n") == "claude --permission-mode auto 'fix it'", "prompt trimmed")
        check(b(1, prompt: "fix the migration") == "opencode --auto --prompt 'fix the migration'", "opencode prompt by flag")
        check(b(1, prompt: "go", files: ["/a.ts"]) == "opencode --auto --prompt '@/a.ts go'", "opencode files")
        check(b(1) == "opencode --auto", "opencode without prompt")
        check(!b(prompt: "fix").contains("--prompt"), "claude takes a positional prompt")
        check(b(manager: true, prompt: "ignored", files: ["/x"]) == "claude agents", "agents manager ignores prompt and files")
        check(b(2, branch: "x", prompt: "ignored") == "", "Terminal types nothing")
    }

    test("new agent: Load Muya channel adds the same flag as the web dialog") {
        let flag = "--dangerously-load-development-channels server:muya-mcp"
        check(NewAgentCommand.build(kind: 0, mode: "bypass", agentsManager: false, branch: "", prompt: "", files: [], channels: true) == "claude \(flag) --dangerously-skip-permissions", "bypass + channel")
        check(NewAgentCommand.build(kind: 0, mode: "auto", agentsManager: false, branch: "", prompt: "go", files: [], channels: true) == "claude \(flag) --permission-mode auto 'go'", "channel + prompt")
        check(NewAgentCommand.build(kind: 0, mode: "auto", agentsManager: true, branch: "", prompt: "", files: [], channels: true) == "claude agents", "agents manager has no channel")
        check(NewAgentCommand.build(kind: 1, mode: "auto", agentsManager: false, branch: "", prompt: "", files: [], channels: true) == "opencode --auto", "opencode has no channel")
    }

    test("new agent: --worktree branch, with a quote in the name") {
        check(b(branch: "feature/my-task") == "claude --permission-mode auto --worktree 'feature/my-task'", "branch")
        check(b(branch: "a'b") == "claude --permission-mode auto --worktree 'a'\\''b'", "quote in the branch")
        check(b(branch: "  ") == "claude --permission-mode auto", "blank branch ignored")
        check(b(1, branch: "x") == "opencode --auto", "opencode has no worktree flag")
    }

    test("new agent: a hostile prompt reaches the program as one argument and runs nothing (real /bin/sh)") {
        let dir = NSTemporaryDirectory() + "muya-newagent-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let prompt = "it's $(touch pwned) `touch pwned2`\nsecond line; touch pwned3"
        let cmd = b(branch: "b'r $(touch pwned4)", prompt: prompt, files: ["/tmp/a b.ts"])
        // `claude` is a shell function that prints each argument in brackets: no real CLI is started.
        let script = "claude() { for a in \"$@\"; do printf '[%s]' \"$a\"; done; }; \(cmd)"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check(text == "[--permission-mode][auto][--worktree][b'r $(touch pwned4)][@/tmp/a b.ts \(prompt)]", "arguments arrive intact: \(text)")
        check((try FileManager.default.contentsOfDirectory(atPath: dir)).isEmpty, "nothing was executed (no files created)")
    }
}

func runPaletteFilesTests() {
    test("palette files: open files + the agent's changed files, like today's paletteFileMap; no folder scan") {
        let items = PaletteFiles.items(open: ["/home/u/notes/todo.md", "/home/u/proj/src/a.rs"],
                                       changes: [("src/a.rs", false), ("src/b.rs", false), ("docs/", false), ("gone.txt", true), ("src/a.rs", false)],
                                       root: "/home/u/proj", home: "/home/u")
        check(items.map(\.title) == ["~/notes/todo.md", "~/proj/src/a.rs", "src/a.rs", "src/b.rs"], "labels: \(items.map(\.title))")
        check(items.map(\.id) == ["file:/home/u/notes/todo.md", "file:/home/u/proj/src/a.rs", "file:/home/u/proj/src/a.rs", "file:/home/u/proj/src/b.rs"], "ids are absolute paths")
        check(items.allSatisfy { $0.group == "Files" }, "group")
        check(PaletteFiles.items(open: [], changes: [("x", false)], root: nil, home: "/home/u").isEmpty, "no folder, no changes")
        check(PaletteFiles.items(open: [], changes: [], root: "/home/u", home: "/home/u").isEmpty, "nothing open or changed: nothing listed (no scan of the home folder)")
        // a same-label entry replaces the earlier one (the Map semantics): an open file named like a change
        let dup = PaletteFiles.items(open: ["/home/u/src/a.rs"], changes: [("~/src/a.rs", false)], root: "/r", home: "/home/u")
        check(dup.count == 1 && dup[0].id == "file:/r/~/src/a.rs", "same label: later wins")
    }

    test("default permission mode: one flag per mode, an empty or unknown stored value is auto") {
        for m in NewAgentCommand.modes { check(NewAgentCommand.flag(for: m.value) == m.flag, m.value) }
        check(NewAgentCommand.flag(for: "bypass") == "--dangerously-skip-permissions", "bypass")
        check(NewAgentCommand.flag(for: "manual") == "--permission-mode manual", "manual")
        for odd in [nil, "", "Bypass permissions", "yolo"] as [String?] { check(NewAgentCommand.flag(for: odd) == "--permission-mode auto", "fallback \(odd ?? "nil")") }
        check(UIPrefs.defaults["permissionMode"] as? String == "auto", "factory default")
        let row = SettingsSchema.rows.first { $0.id == "permissionMode" }
        check(row?.store == "ui" && row?.title == "Default permission mode", "settings row")
        if case let .popup(l)? = row?.kind { check(l == NewAgentCommand.modes.map(\.label), "five labels") } else { check(false, "popup") }
    }

    test("default permission mode: every command builder follows the stored mode") {
        for (mode, flag) in [("bypass", "--dangerously-skip-permissions"), ("manual", "--permission-mode manual"), (nil, "--permission-mode auto"), ("", "--permission-mode auto")] as [(String?, String)] {
            check(SessionsLogic.resumeCommand("abc-1", mode: mode) == "claude --resume 'abc-1' \(flag)", "resume \(mode ?? "nil")")
            check(SplitLogic.claudeBase(mode: mode) == "claude \(flag)", "claudeBase")
            check(SplitLogic.cloneSpec(name: "n", agent: "claude", sessionId: "abc-1", sessionCwd: nil, mode: mode).command == "claude --resume 'abc-1' --fork-session \(flag)", "fork")
            check(SplitLogic.cloneSpec(name: "n", agent: "claude", sessionId: nil, sessionCwd: nil, mode: mode).command == "claude \(flag)", "fresh clone")
            let o = OpenAgentSession(payload: "{\"name\":\"w\",\"unattended\":false}")!
            check(o.command(openerName: nil, mode: mode) == "claude \(flag) --name 'w'", "open_session")
            let u = OpenAgentSession(payload: "{\"name\":\"w\"}")!
            check(u.command(openerName: nil, mode: mode).hasPrefix("claude \(flag) --disallowedTools"), "unattended open_session")
            check(ResourcesLogic.createCommand(prompt: "p", mode: mode) == "claude \(flag) 'p'", "resources create")
            let live = LiveSession(id: 2, pid: 102, cwd: "/w", claudeSessionId: "c-1")
            check(ResumeStep.steps([live], home: "/h", mode: mode) { _ in true }.first?.command == "claude --resume 'c-1' \(flag)", "restart resume")
        }
        check(AgentsLogic.attachCommand("abc") == "claude attach 'abc'", "attach has no flag")
    }
}
