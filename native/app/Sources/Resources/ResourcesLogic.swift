// P7 logic, free of AppKit: the Resources page's models (what `resources.*` returns), the list filters, the
// marketplace rules, and the slash-command list (built-ins merged with what the daemon finds on disk, filtered
// and ordered like today's SlashCommandsPopover).

import Foundation

// MARK: Models

struct ResourceItem: Equatable { var name: String; var path: String }
struct ResourceMcp: Equatable { var name: String; var command: String; var description: String; var agent: String }

struct ClaudeResources: Equatable {
    var skills: [ResourceItem] = [], agents: [ResourceItem] = [], hooks: [ResourceItem] = []
    var mcps: [ResourceMcp] = []

    init() {}
    init?(json v: Any) {
        guard let o = v as? [String: Any] else { return nil }
        func items(_ k: String) -> [ResourceItem] {
            ((o[k] as? [[String: Any]]) ?? []).compactMap { d in
                guard let n = d["name"] as? String, let p = d["path"] as? String else { return nil }
                return ResourceItem(name: n, path: p)
            }
        }
        skills = items("skills"); agents = items("agents"); hooks = items("hooks")
        mcps = ((o["mcps"] as? [[String: Any]]) ?? []).compactMap { d in
            guard let n = d["name"] as? String else { return nil }
            return ResourceMcp(name: n, command: d["command"] as? String ?? "", description: d["description"] as? String ?? "", agent: d["agent"] as? String ?? "claude")
        }
    }
}

struct MarketSkill: Equatable {
    var name: String, description: String, stars: String, author: String, githubUrl: String, featured: Bool
    init?(json d: [String: Any]) {
        guard let n = d["name"] as? String else { return nil }
        name = n; description = d["description"] as? String ?? ""; stars = d["stars"] as? String ?? ""
        author = d["author"] as? String ?? ""; githubUrl = d["githubUrl"] as? String ?? ""; featured = d["featured"] as? Bool ?? false
    }
}

struct MarketMcp: Equatable {
    var name: String, description: String, command: String, args: [String], source: String
    init?(json d: [String: Any]) {
        guard let n = d["name"] as? String else { return nil }
        name = n; description = d["description"] as? String ?? ""; command = d["command"] as? String ?? ""
        args = d["args"] as? [String] ?? []; source = d["source"] as? String ?? ""
    }
}

struct MarketMcpResult: Equatable {
    var items: [MarketMcp], openBrowser: Bool
    init?(json v: Any) {
        guard let o = v as? [String: Any] else { return nil }
        items = ((o["items"] as? [[String: Any]]) ?? []).compactMap(MarketMcp.init(json:))
        openBrowser = o["openBrowser"] as? Bool ?? false
    }
}

// MARK: Page rules

enum ResourceTab: Int, CaseIterable { case skills, agents, hooks, mcps, marketplace
    var title: String { ["Skills", "Agents", "Hooks", "MCPs", "Marketplace"][rawValue] }
}

enum ResourcesLogic {
    /// Search matches the name (MCPs: name or description), case-insensitively — today's filters.
    static func filtered(_ r: ClaudeResources, tab: ResourceTab, query: String) -> (skills: [ResourceItem], agents: [ResourceItem], hooks: [ResourceItem], mcps: [ResourceMcp]) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return (r.skills, r.agents, r.hooks, r.mcps) }
        func f(_ a: [ResourceItem]) -> [ResourceItem] { a.filter { $0.name.lowercased().contains(q) } }
        return (f(r.skills), f(r.agents), f(r.hooks), r.mcps.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) })
    }

    /// Files tried, in order, for a skill's text (then the first .md in its folder).
    static func skillFileCandidates(_ s: ResourceItem) -> [String] { ["\(s.path)/README.md", "\(s.path)/skill.md", "\(s.path)/\(s.name).md"] }

    /// Only https links are opened from a marketplace entry (a scraped page must not open other schemes).
    static func isHttps(_ s: String) -> Bool { URL(string: s)?.scheme?.lowercased() == "https" }

    static let skillInstallLabel = "Install to ~/.claude/skills/"
    static let mcpInstallLabel = "Add to ~/.claude/.mcp.json"

    /// What the prompt typed in "Create with Claude" turns into (the wrapper text of today's modal).
    static func createPrompt(kind: String, request: String) -> String {
        let wrapper: String
        switch kind {
        case "Agent": wrapper = "You are a Claude Code agent definition author. Create a new agent definition file at ~/.claude/agents/{name}.md.\n\nThe agent file must include:\n- Name and one-line description\n- An explicit list of allowed tools (Read, Write, Edit, Bash, etc.)\n- Detailed behavioral instructions and constraints\n- Example scenarios where this agent should be invoked\n\nAfter creating the file, read it back and confirm its full path."
        case "Hook": wrapper = "You are a Claude Code hooks expert. Create a new Claude Code hook that runs in response to lifecycle events.\n\nSteps:\n1. Write the hook script to ~/.claude/hooks/{name}.sh and make it executable (chmod +x)\n2. Show the exact ~/.claude/settings.json snippet needed to register it, including the correct event type (PreToolUse / PostToolUse / Stop / SessionStart / UserPromptSubmit) and any matchers\n3. Explain what the hook does and when it fires\n\nConfirm both the file path and the settings.json snippet when done."
        case "MCP": wrapper = "You are an MCP (Model Context Protocol) server developer. Create a complete MCP server and integrate it with Claude Code.\n\nSteps:\n1. Implement the MCP server (prefer Node.js with npx-runnable package, or Python)\n2. Add the configuration entry to ~/.claude/.mcp.json with the correct command and args\n3. Provide verification steps to confirm the server loads correctly\n\nThe server should expose at least one tool. Confirm the config entry and file paths when done."
        default: wrapper = "You are a Claude Code skill author. Create a complete skill definition at ~/.claude/skills/{name}/skill.md.\n\nThe skill file must include:\n- A clear description of what the skill does and when it triggers\n- Step-by-step instructions Claude should follow\n- Concrete usage examples\n- Any required context or preconditions\n\nAfter creating the file, read it back and confirm its full path."
        }
        return "\(wrapper)\n\n---\nUser request: \(request.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// The shell command that starts Claude with that prompt: the prompt is single-quoted, so nothing in it runs.
    static func createCommand(prompt: String, mode: String? = nil) -> String { "claude \(NewAgentCommand.flag(for: mode)) '" + prompt.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: Slash commands

enum SlashSource: String, CaseIterable { case builtin, project, user, skill
    var heading: String { ["BUILT-IN", "PROJECT", "USER", "SKILLS"][SlashSource.allCases.firstIndex(of: self)!] }
    var rank: Int { [3, 0, 1, 2][SlashSource.allCases.firstIndex(of: self)!] }
}

struct SlashItem: Equatable { var name: String; var description: String; var source: SlashSource }

enum SlashLogic {
    static func builtins(agent: String) -> [SlashItem] {
        (agent == "opencode" ? SlashBuiltins.opencode : SlashBuiltins.claude).map { SlashItem(name: $0.0, description: $0.1, source: .builtin) }
    }

    /// Built-ins first, then the disk items (project, user, skills). A custom command that shadows a built-in
    /// keeps the built-in (the CLI runs it first); duplicates on disk keep the first.
    static func merge(agent: String, disk: [SlashItem]) -> [SlashItem] {
        var out = builtins(agent: agent)
        var seen = Set(out.map(\.name))
        for d in disk.enumerated().sorted(by: { ($0.element.source.rank, $0.offset) < ($1.element.source.rank, $1.offset) }).map(\.element) where !seen.contains(d.name) {
            seen.insert(d.name); out.append(d)
        }
        return out
    }

    /// Names starting with the query first, then those containing it (name or description).
    static func filter(_ items: [SlashItem], query: String) -> [SlashItem] {
        var q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.hasPrefix("/") { q.removeFirst() }
        if q.isEmpty { return items }
        var starts: [SlashItem] = [], rest: [SlashItem] = []
        for it in items {
            let n = it.name.lowercased()
            if n.hasPrefix(q) { starts.append(it) } else if n.contains(q) || it.description.lowercased().contains(q) { rest.append(it) }
        }
        return starts + rest
    }

    /// Display order: by group, each group keeping its own order. ↑/↓ walks this list.
    static func grouped(_ items: [SlashItem]) -> [SlashItem] { SlashSource.allCases.flatMap { g in items.filter { $0.source == g } } }

    /// Index after ↑ (`-1`) or ↓ (`+1`), wrapping.
    static func move(_ index: Int, by d: Int, count: Int) -> Int { count == 0 ? 0 : (index + d + count) % count }
}
