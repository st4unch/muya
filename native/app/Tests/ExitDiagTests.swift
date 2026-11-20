// Session exit diagnostics (Sources/Logic/ExitDiagLogic.swift): classification, launch wrapping, preflight mapping.

import Foundation

func runExitDiagTests() {
    test("exit diag: a plain shell tab never gets the panel, whatever the status") {
        for st: Int32 in [0, 1, 127, 134, 137] { check(ExitDiag.classify(status: st, isClaudeLaunch: false, resumed: false, ranFor: 1) == nil, "status \(st)") }
    }
    test("exit diag: Claude exiting 0 after a normal run (/exit) closes as before") {
        check(ExitDiag.classify(status: 0, isClaudeLaunch: true, resumed: true, ranFor: 600) == nil, "resumed, long run")
        check(ExitDiag.classify(status: 0, isClaudeLaunch: true, resumed: false, ranFor: 2) == nil, "a fresh run that was quit quickly is the operator's choice")
    }
    test("exit diag: a non-zero code or a signal shows the panel") {
        check(ExitDiag.classify(status: 1, isClaudeLaunch: true, resumed: false, ranFor: 900) == .failed(code: 1), "code 1")
        check(ExitDiag.classify(status: 134, isClaudeLaunch: true, resumed: true, ranFor: 900) == .signal(name: "SIGABRT", status: 134), "SIGABRT")
        check(ExitDiag.classify(status: 137, isClaudeLaunch: true, resumed: false, ranFor: 5) == .signal(name: "SIGKILL", status: 137), "SIGKILL")
        check(ExitDiag.classify(status: 200, isClaudeLaunch: true, resumed: false, ranFor: 5) == .failed(code: 200), "unknown number above 128 is a plain code")
    }
    test("exit diag: exit 0 within 10 s of a resume is a quick exit") {
        check(ExitDiag.classify(status: 0, isClaudeLaunch: true, resumed: true, ranFor: 3.4) == .quickExit(seconds: 3), "3 s")
        check(ExitDiag.classify(status: 0, isClaudeLaunch: true, resumed: true, ranFor: 9.9) == .quickExit(seconds: 9), "9.9 s")
        check(ExitDiag.classify(status: 0, isClaudeLaunch: true, resumed: true, ranFor: 10) == nil, "10 s is a normal run")
    }
    test("exit diag: panel wording") {
        check(ExitVerdict.failed(code: 2).title == "Claude exited with code 2", "failed")
        check(ExitVerdict.signal(name: "SIGABRT", status: 134).detail == "SIGABRT (exit status 134)", "signal detail")
        check(ExitVerdict.quickExit(seconds: 0).title.contains("immediately"), "quick, 0 s")
    }
    test("exit diag: which commands are Claude launches") {
        check(ExitDiag.isClaudeCommand("claude --resume 'abc' --permission-mode auto"), "bare")
        check(ExitDiag.isClaudeCommand("'/opt/x/bin/claude' --permission-mode auto"), "quoted path")
        check(!ExitDiag.isClaudeCommand("opencode --auto") && !ExitDiag.isClaudeCommand("ls claude"), "others")
        check(ExitDiag.isResume("claude --resume 'abc'") && !ExitDiag.isResume("claude --permission-mode auto"), "resume flag")
        check(ExitDiag.resumeId("claude --resume 'abc-1_x' --permission-mode auto") == "abc-1_x", "resume id")
        check(ExitDiag.resumeId("claude --permission-mode auto") == nil, "no id")
    }
    test("exit diag: the launch argv keeps the shell afterwards on success and ends with Claude's status on failure") {
        let a = ExitDiag.launchArgv(shell: "/bin/zsh", command: "claude --resume 'x'")
        check(Array(a.prefix(4)) == ["/bin/zsh", "-l", "-i", "-c"] && a[4].hasPrefix("claude --resume 'x'; rc=$?;") && a[4].contains("exec \"${SHELL:-/bin/sh}\" -l") && a[4].hasSuffix("exit $rc"), "zsh: \(a)")
        let f = ExitDiag.launchArgv(shell: "/opt/homebrew/bin/fish", command: "claude --resume 'x'")
        check(f[4].hasPrefix("exec /bin/sh -c '") && f[4].contains("'\\''x'\\''"), "fish goes through /bin/sh with the quotes escaped: \(f[4])")
    }
    // The wrapped command really exits with the child's status (runs /bin/sh, no Claude needed).
    test("exit diag: the wrapper script passes the status through") {
        func run(_ cmd: String) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
            let argv = ExitDiag.launchArgv(shell: "/bin/sh", command: cmd)   // [sh, -l, -i, -c, script]
            p.arguments = ["-c", argv[4]]
            p.environment = ["SHELL": "/usr/bin/true", "PATH": "/usr/bin:/bin"]
            p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit(); return p.terminationStatus
        }
        check(run("exit 7") == 7, "failure keeps its code")
        check(run("true") == 0, "success continues into the shell (stubbed as true here)")
        check(run("sh -c 'kill -ABRT $$'") == 134, "signal shows as 128+6")
    }
    let ok = ProbeOutcome(status: 0, stdout: "muya-claude-path:/opt/x/claude\n2.1.328 (Claude Code)\n")
    let nodeOk = ProbeOutcome(status: 0)
    test("preflight: everything works") {
        let r = Preflight.map(claude: ok, node: nodeOk)
        check(r.isClean && r.claudeVersion == "2.1.328 (Claude Code)", "\(r)")
    }
    test("preflight: claude that does not run is an error with the path tried") {
        let r = Preflight.map(claude: ProbeOutcome(status: 1, stdout: "muya-claude-path:/opt/old/claude\n", stderr: "unknown option '--version'\n"), node: nodeOk)
        check(r.claudeError == "`claude --version` failed (tried /opt/old/claude): unknown option '--version'", "\(r.claudeError ?? "nil")")
        check(r.nodeWarning == nil, "node fine")
    }
    test("preflight: claude missing and claude timed out") {
        let m = Preflight.map(claude: ProbeOutcome(status: 127, stderr: "claude was not found on PATH\n"), node: nodeOk)
        check(m.claudeError?.contains("not found on the PATH") == true, "\(m.claudeError ?? "nil")")
        let t = Preflight.map(claude: ProbeOutcome(status: nil, timedOut: true, stdout: "muya-claude-path:/p/claude\n"), node: nodeOk)
        check(t.claudeError == "`claude --version` did not answer within 2 s (tried /p/claude).", "\(t.claudeError ?? "nil")")
    }
    test("preflight: a broken node is a warning with the first stderr line, never an error") {
        let r = Preflight.map(claude: ok, node: ProbeOutcome(status: 134, stderr: "dyld[1]: Library not loaded: libllhttp.9.3.dylib\n  Referenced from: node\n"))
        check(r.claudeError == nil, "launch is not blocked")
        check(r.nodeWarning == "node is broken — hooks and MCP servers may fail: dyld[1]: Library not loaded: libllhttp.9.3.dylib", "\(r.nodeWarning ?? "nil")")
        let none = Preflight.map(claude: ok, node: ProbeOutcome(status: 127, stderr: "node: command not found"))
        check(none.nodeWarning?.hasPrefix("node was not found") == true, "missing node")
        let slow = Preflight.map(claude: ok, node: ProbeOutcome(status: nil, timedOut: true))
        check(slow.nodeWarning?.contains("did not answer within 2 s") == true, "timeout")
    }
    test("preflight: the cache holds a result for a minute") {
        var c = PreflightCache(); let t0 = Date(timeIntervalSince1970: 1000)
        check(c.fresh(now: t0) == nil, "empty")
        c.store(PreflightReport(nodeWarning: "w"), now: t0)
        check(c.fresh(now: t0.addingTimeInterval(59))?.nodeWarning == "w" && c.fresh(now: t0.addingTimeInterval(61)) == nil, "ttl")
    }
    test("preflight: probe argv goes through the login shell") {
        check(ExitDiag.probeArgv(shell: "/bin/zsh", script: "node -e 0") == ["/bin/zsh", "-l", "-i", "-c", "node -e 0"], "zsh")
        check(ExitDiag.probeArgv(shell: "/usr/bin/fish", script: "node -e 0")[4] == "exec /bin/sh -c 'node -e 0'", "fish")
    }
}
