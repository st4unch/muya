// Session exit diagnostics (docs/prd-session-exit-diag.md): which exits of a Claude tab deserve the exit panel, how the
// launch command is wrapped so the tab learns the exit code, and how the launch preflight probes map to a message.
// Pure logic, unit-tested in Tests/ExitDiagTests.swift.

import Foundation

public enum ExitVerdict: Equatable {
    case failed(code: Int32)
    case signal(name: String, status: Int32)
    case quickExit(seconds: Int)

    public var title: String {
        switch self {
        case let .failed(code): return "Claude exited with code \(code)"
        case let .signal(name, _): return "Claude was stopped by \(name)"
        case let .quickExit(s): return "Claude exited \(s == 0 ? "immediately" : "after \(s) s") after the resume"
        }
    }
    /// The one-line state shown in the sidebar / panel header.
    public var detail: String {
        switch self {
        case let .failed(code): return "Exit code \(code)"
        case let .signal(name, status): return "\(name) (exit status \(status))"
        case .quickExit: return "Exit code 0"
        }
    }
}

public enum ExitDiag {
    /// An exit within this many seconds of a resume is suspicious even with code 0.
    public static let quickSeconds: TimeInterval = 10

    static let signalNames: [Int32: String] = [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGBUS", 8: "SIGFPE",
                                               9: "SIGKILL", 11: "SIGSEGV", 13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM"]

    /// nil = nothing unusual: today's behaviour stays (a plain shell tab never gets a verdict; a Claude tab that exited
    /// 0 after a normal run, e.g. /exit, neither). `status` is what muyad reports: the exit code, or 128 + signal.
    public static func classify(status: Int32, isClaudeLaunch: Bool, resumed: Bool, ranFor: TimeInterval) -> ExitVerdict? {
        guard isClaudeLaunch else { return nil }
        if status == 0 { return resumed && ranFor < quickSeconds ? .quickExit(seconds: Int(ranFor)) : nil }
        if status > 128, let name = signalNames[status - 128] { return .signal(name: name, status: status) }
        return .failed(code: status)
    }

    /// Whether a typed command starts Claude (so the tab is one that gets the exit panel).
    public static func isClaudeCommand(_ command: String) -> Bool {
        let first = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let bare = first.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return bare == "claude" || bare.hasSuffix("/claude")
    }

    public static func isResume(_ command: String) -> Bool { command.contains("--resume") || command.contains(" -r ") || command.contains("--continue") }

    /// The session id of `claude --resume '<id>' ...`, when there is one.
    public static func resumeId(_ command: String) -> String? {
        guard let r = command.range(of: "--resume ") else { return nil }
        let rest = command[r.upperBound...].drop { $0 == " " }
        let id = rest.drop { $0 == "'" }.prefix { $0 != "'" && $0 != " " }
        return id.isEmpty ? nil : String(id)
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The argv a Claude tab starts with: the login shell runs the command, and when it succeeds the tab continues as an
    /// ordinary login shell (what typing the command did before); when it fails the process ends with Claude's status.
    public static func launchArgv(shell: String, command: String) -> [String] {
        let tail = "; rc=$?; if [ $rc -eq 0 ]; then exec \"${SHELL:-/bin/sh}\" -l; fi; exit $rc"
        let base = (shell as NSString).lastPathComponent
        if ["zsh", "bash", "sh"].contains(base) { return [shell, "-l", "-i", "-c", command + tail] }
        return [shell, "-l", "-i", "-c", "exec /bin/sh -c " + quote(command + tail)]   // fish and friends: no `$?` there
    }

    /// The argv of a capability probe: the same login shell the tab uses, so the probe sees the PATH the session will have.
    public static func probeArgv(shell: String, script: String) -> [String] {
        let base = (shell as NSString).lastPathComponent
        if ["zsh", "bash", "sh"].contains(base) { return [shell, "-l", "-i", "-c", script] }
        return [shell, "-l", "-i", "-c", "exec /bin/sh -c " + quote(script)]
    }

    public static let claudeProbeScript = "p=$(command -v claude) || { echo 'claude was not found on PATH' >&2; exit 127; }; echo \"muya-claude-path:$p\"; claude --version"
    public static let nodeProbeScript = "node -e 0"
}

/// One finished (or timed-out) probe.
public struct ProbeOutcome: Equatable {
    public var status: Int32?     // nil = the probe could not be started
    public var timedOut: Bool
    public var stdout: String
    public var stderr: String
    public init(status: Int32?, timedOut: Bool = false, stdout: String = "", stderr: String = "") {
        self.status = status; self.timedOut = timedOut; self.stdout = stdout; self.stderr = stderr
    }
    var ok: Bool { status == 0 && !timedOut }
}

public struct PreflightReport: Equatable {
    /// Set when `claude --version` failed: a clear message naming the path that was tried.
    public var claudeError: String?
    /// Set when `node -e 0` failed: a warning, never a block.
    public var nodeWarning: String?
    public var claudeVersion: String?
    public var isClean: Bool { claudeError == nil && nodeWarning == nil }
}

public enum Preflight {
    static func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    /// The path the probe printed (`muya-claude-path:<path>`), when it got that far.
    static func triedPath(_ out: String) -> String? {
        out.split(whereSeparator: \.isNewline).compactMap { l -> String? in
            l.hasPrefix("muya-claude-path:") ? String(l.dropFirst("muya-claude-path:".count)) : nil
        }.first
    }

    public static func map(claude: ProbeOutcome, node: ProbeOutcome) -> PreflightReport {
        var r = PreflightReport()
        if claude.ok {
            // rc files may print noise before the version: the last non-empty line that is not our marker
            r.claudeVersion = claude.stdout.split(whereSeparator: \.isNewline).map(String.init).last { !$0.isEmpty && !$0.hasPrefix("muya-claude-path:") }
        } else {
            let path = triedPath(claude.stdout)
            if claude.timedOut {
                r.claudeError = "`claude --version` did not answer within 2 s" + (path.map { " (tried \($0))" } ?? "") + "."
            } else if claude.status == 127 && path == nil {
                r.claudeError = "Claude was not found on the PATH a Muya terminal gets. Install it, or add its folder to your shell profile."
            } else {
                let why = firstLine(claude.stderr)
                r.claudeError = "`claude --version` failed" + (path.map { " (tried \($0))" } ?? "") + (why.isEmpty ? "." : ": \(why)")
            }
        }
        if node.timedOut {
            r.nodeWarning = "node is broken — hooks and MCP servers may fail (`node -e 0` did not answer within 2 s)"
        } else if !node.ok {
            if node.status == 127 {
                r.nodeWarning = "node was not found — hooks and MCP servers that need it may fail"
            } else {
                let why = firstLine(node.stderr)
                r.nodeWarning = "node is broken — hooks and MCP servers may fail" + (why.isEmpty ? "" : ": \(why)")
            }
        }
        return r
    }
}

/// The last result, kept briefly so opening several Claude tabs in a row probes once.
public struct PreflightCache {
    public static let ttl: TimeInterval = 60
    private var entry: (report: PreflightReport, at: Date)?
    public init() {}
    public func fresh(now: Date = Date()) -> PreflightReport? {
        guard let e = entry, now.timeIntervalSince(e.at) < PreflightCache.ttl else { return nil }
        return e.report
    }
    public mutating func store(_ r: PreflightReport, now: Date = Date()) { entry = (r, now) }
}
