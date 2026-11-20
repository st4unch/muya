// The command the New agent dialog types: the same strings src/lib/agent.ts (baseCommand / buildAgentCommand) builds.
// Pure logic, unit-tested in Tests/NewAgentTests.swift.

import Foundation

enum NewAgentCommand {
    struct Mode { let value: String, label: String, hint: String, flag: String }
    static let modes: [Mode] = [
        Mode(value: "manual", label: "Manual", hint: "Ask before every action", flag: "--permission-mode manual"),
        Mode(value: "acceptEdits", label: "Accept edits", hint: "Edits are auto-approved, other actions ask", flag: "--permission-mode acceptEdits"),
        Mode(value: "plan", label: "Plan", hint: "Read-only planning, no changes", flag: "--permission-mode plan"),
        Mode(value: "auto", label: "Auto", hint: "A classifier approves safe actions", flag: "--permission-mode auto"),
        Mode(value: "bypass", label: "Bypass permissions", hint: "Skip every permission check", flag: "--dangerously-skip-permissions"),
    ]

    static func singleQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// "" for Terminal (no command). kind: 0 Claude Code, 1 opencode, 2 Terminal.
    static let channelFlag = "--dangerously-load-development-channels server:muya-mcp" // src/lib/statusline.ts CHANNEL_FLAG

    static func build(kind: Int, mode: String, agentsManager: Bool, branch: String, prompt: String, files: [String], channels: Bool = false, claudePath: String? = nil, opencodePath: String? = nil) -> String {
        let claudeCmd = claudePath.map(singleQuote) ?? "claude", opencodeCmd = opencodePath.map(singleQuote) ?? "opencode"
        if kind == 2 { return "" }
        if kind == 0 && agentsManager { return "\(claudeCmd) agents" }
        let flag = modes.first { $0.value == mode }?.flag ?? modes[3].flag
        var base = kind == 1 ? "\(opencodeCmd) --auto" : (channels ? "\(claudeCmd) \(channelFlag) \(flag)" : "\(claudeCmd) \(flag)")
        let b = branch.trimmingCharacters(in: .whitespaces)
        if kind == 0, !b.isEmpty { base += " --worktree \(singleQuote(b))" }
        let arg = (files.map { "@\($0)" } + [prompt.trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: " ")
        if arg.isEmpty { return base }
        return kind == 1 ? "\(base) --prompt \(singleQuote(arg))" : "\(base) \(singleQuote(arg))"
    }
}
