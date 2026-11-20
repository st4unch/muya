// The Claude status fields the footer can show (src/lib/statusline.ts STATUS_FIELDS / STATUS_GROUPS, field for field) and
// their formatters, plus the picker's filter. A field is shown only when the status JSON of the selected session has it
// (statusline.session of muyad reads what Claude's status tap wrote).

import Foundation

public enum StatusFieldKind: Sendable {
    case str, num, pct, tok, bool, dur, tail, count, usd, plus, minus, hash, underscoreToSpace, prKind, ratio, expiry, ago
    case resets(Bool)
    case lines, repo, lastMissCause, missCauses
}

public struct StatusFieldDef: Sendable {
    public let id: String, group: String, label: String, kind: StatusFieldKind
}

public enum StatusFieldCatalog {
    public static let groupOrder = ["Model", "Context", "Cost & time", "Rate limits", "Session", "Workspace & git", "Pull request", "Worktree", "Prompt cache", "Modes"]

    public static let fields: [StatusFieldDef] = rows.map { StatusFieldDef(id: $0.0, group: $0.1, label: $0.2, kind: $0.3) }

    private static let rows: [(String, String, String, StatusFieldKind)] = [
        ("model.display_name", "Model", "Model", .str),
        ("model.id", "Model", "Model id", .str),
        ("effort.level", "Model", "Effort", .str),
        ("version", "Model", "Claude Code version", .str),
        ("context_window.used_percentage", "Context", "Context used", .pct),
        ("context_window.remaining_percentage", "Context", "Context left", .pct),
        ("context_window.context_window_size", "Context", "Context size", .tok),
        ("context_window.total_input_tokens", "Context", "Input tokens", .tok),
        ("context_window.total_output_tokens", "Context", "Output tokens", .tok),
        ("context_window.current_usage.input_tokens", "Context", "Fresh input", .tok),
        ("context_window.current_usage.output_tokens", "Context", "Last output", .tok),
        ("context_window.current_usage.cache_creation_input_tokens", "Context", "Cache written", .tok),
        ("context_window.current_usage.cache_read_input_tokens", "Context", "Cache read", .tok),
        ("exceeds_200k_tokens", "Context", "Over 200k", .bool),
        ("cost.total_cost_usd", "Cost & time", "Cost", .usd),
        ("cost.total_duration_ms", "Cost & time", "Duration", .dur),
        ("cost.total_api_duration_ms", "Cost & time", "API time", .dur),
        ("cost.lines", "Cost & time", "Lines changed", .lines),
        ("cost.total_lines_added", "Cost & time", "Lines added", .plus),
        ("cost.total_lines_removed", "Cost & time", "Lines removed", .minus),
        ("rate_limits.five_hour.used_percentage", "Rate limits", "5-hour used", .pct),
        ("rate_limits.five_hour.resets_at", "Rate limits", "5-hour window", .resets(false)),
        ("rate_limits.seven_day.used_percentage", "Rate limits", "7-day used", .pct),
        ("rate_limits.seven_day.resets_at", "Rate limits", "7-day window", .resets(true)),
        ("rate_limits.spend_limit.used_percentage", "Rate limits", "Spend used", .pct),
        ("rate_limits.spend_limit.resets_at", "Rate limits", "Spend window", .resets(true)),
        ("session_id", "Session", "Session id", .str),
        ("session_name", "Session", "Session name", .str),
        ("prompt_id", "Session", "Prompt id", .str),
        ("transcript_path", "Session", "Transcript", .tail),
        ("cwd", "Session", "Directory", .tail),
        ("workspace.current_dir", "Workspace & git", "Current dir", .tail),
        ("workspace.project_dir", "Workspace & git", "Project dir", .tail),
        ("workspace.added_dirs", "Workspace & git", "Added dirs", .count),
        ("workspace.git_worktree", "Workspace & git", "Git worktree", .str),
        ("workspace.repo.host", "Workspace & git", "Repo host", .str),
        ("workspace.repo.owner", "Workspace & git", "Repo owner", .str),
        ("workspace.repo.name", "Workspace & git", "Repo name", .str),
        ("workspace.repo", "Workspace & git", "Repository", .repo),
        ("pr.number", "Pull request", "PR number", .hash),
        ("pr.url", "Pull request", "PR link", .str),
        ("pr.review_state", "Pull request", "PR review", .underscoreToSpace),
        ("pr.kind", "Pull request", "PR kind", .prKind),
        ("worktree.name", "Worktree", "Worktree", .str),
        ("worktree.path", "Worktree", "Worktree path", .tail),
        ("worktree.branch", "Worktree", "Worktree branch", .str),
        ("worktree.original_cwd", "Worktree", "Original dir", .tail),
        ("worktree.original_branch", "Worktree", "Original branch", .str),
        ("prompt_cache.warm", "Prompt cache", "Cache warm", .bool),
        ("prompt_cache.caching_observed", "Prompt cache", "Caching seen", .bool),
        ("prompt_cache.ttl", "Prompt cache", "Cache TTL", .str),
        ("prompt_cache.expires_at", "Prompt cache", "Cache expires", .expiry),
        ("prompt_cache.requests", "Prompt cache", "Cache requests", .num),
        ("prompt_cache.misses", "Prompt cache", "Cache misses", .num),
        ("prompt_cache.expected_rebuilds", "Prompt cache", "Expected rebuilds", .num),
        ("prompt_cache.hit_ratio", "Prompt cache", "Cache hit ratio", .ratio),
        ("prompt_cache.cache_write_tokens", "Prompt cache", "Cache write tokens", .tok),
        ("prompt_cache.miss_recache_tokens", "Prompt cache", "Miss re-cache tokens", .tok),
        ("prompt_cache.last_miss_at", "Prompt cache", "Last miss", .ago),
        ("prompt_cache.last_miss_cause", "Prompt cache", "Last miss cause", .lastMissCause),
        ("prompt_cache.miss_causes", "Prompt cache", "Miss causes", .missCauses),
        ("prompt_cache.recache_tokens_if_cold", "Prompt cache", "Re-cache if cold", .tok),
        ("fast_mode", "Modes", "Fast mode", .bool),
        ("thinking.enabled", "Modes", "Thinking", .bool),
        ("vim.mode", "Modes", "Vim mode", .str),
        ("agent.name", "Modes", "Agent", .str),
        ("output_style.name", "Modes", "Output style", .str),
    ]

    public static let byId: [String: StatusFieldDef] = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
    public static let byLabel: [String: StatusFieldDef] = Dictionary(fields.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })

    /// Stored fields as ids: the first native build stored labels ("Model"), today's app stores ids ("model.display_name").
    public static func normalize(_ stored: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for s in stored {
            let id = byId[s]?.id ?? byLabel[s]?.id
            if let id, seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    /// Fields that match the filter text (label, id or group, case-insensitive), per group, empty groups dropped.
    public static func filtered(_ q: String) -> [(String, [StatusFieldDef])] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        return groupOrder.compactMap { g in
            let f = fields.filter { $0.group == g && (t.isEmpty || $0.label.lowercased().contains(t) || $0.id.lowercased().contains(t) || $0.group.lowercased().contains(t)) }
            return f.isEmpty ? nil : (g, f)
        }
    }

    // MARK: Values

    /// Value at a dotted path; nil for absent / null.
    public static func pathGet(_ data: [String: Any]?, _ path: String) -> Any? {
        var cur: Any? = data
        for k in path.split(separator: ".") {
            guard let d = cur as? [String: Any] else { return nil }
            cur = d[String(k)]
        }
        return cur is NSNull ? nil : cur
    }

    /// Text of a field, or nil when the data lacks it (the item is then hidden).
    public static func value(_ id: String, _ data: [String: Any]?) -> String? {
        guard let f = byId[id], let data else { return nil }
        switch f.kind {
        case .lines:
            guard let a = number(pathGet(data, "cost.total_lines_added")), let r = number(pathGet(data, "cost.total_lines_removed")) else { return nil }
            return "+\(Int(a)) −\(Int(r))"
        case .repo:
            guard let o = pathGet(data, "workspace.repo.owner") as? String, let n = pathGet(data, "workspace.repo.name") as? String else { return nil }
            return "\(o)/\(n)"
        default: break
        }
        guard let v = pathGet(data, f.id) else { return nil }
        return format(v, f.kind)
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func boolean(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func format(_ v: Any, _ kind: StatusFieldKind) -> String? {
        switch kind {
        case .str: if let s = v as? String, !s.isEmpty { return s }; return nil
        case .num: return number(v).map { fmtNumber($0) }
        case .pct: return number(v).map { fmtPct($0) }
        case .tok: return number(v).map { fmtTokens($0) }
        case .bool: return boolean(v).map { $0 ? "on" : "off" }
        case .dur: return number(v).map { fmtDuration($0) }
        case .tail: if let s = v as? String, !s.isEmpty { return basename(s) }; return nil
        case .count: return (v as? [Any]).map { String($0.count) }
        case .usd: return number(v).map { String(format: "$%.2f", $0) }
        case .plus: return number(v).map { "+\(fmtNumber($0))" }
        case .minus: return number(v).map { "−\(fmtNumber($0))" }
        case .hash: return number(v).map { "#\(fmtNumber($0))" }
        case .underscoreToSpace: return (v as? String).map { $0.replacingOccurrences(of: "_", with: " ") }
        case .prKind: if let s = v as? String { return s == "mr" ? "merge request" : s }; return nil
        case .ratio: return number(v).map { fmtPct($0 * 100) }
        case .expiry: return number(v).map { "until \(fmtEpoch($0, weekday: false))" }
        case .ago: return number(v).map { "at \(fmtEpoch($0, weekday: false))" }
        case let .resets(wd): return number(v).map { "resets \(fmtEpoch($0, weekday: wd))" }
        case .lastMissCause:
            guard let c = (v as? [String: Any])?["causes"] as? [Any], !c.isEmpty else { return nil }
            return c.map { "\($0)" }.joined(separator: ", ").replacingOccurrences(of: "_", with: " ")
        case .missCauses:
            guard let d = v as? [String: Any] else { return nil }
            return String(Int(d.values.reduce(0.0) { $0 + (number($1) ?? 0) }))
        case .lines, .repo: return nil
        }
    }

    // MARK: Formatters (statusline.ts)

    static func fmtNumber(_ n: Double) -> String { n == n.rounded() ? String(Int(n)) : "\(n)" }
    public static func fmtPct(_ n: Double) -> String { "\(Int(jsRound(n)))%" }
    public static func fmtTokens(_ n: Double) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fk", n / 1000) }
        return String(Int(jsRound(n)))
    }
    public static func fmtDuration(_ ms: Double) -> String {
        let s = Int(jsRound(max(0, ms) / 1000))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
    /// JavaScript's Math.round: halves go up.
    static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }
    static func basename(_ p: String) -> String {
        var t = p
        while t.hasSuffix("/") || t.hasSuffix("\\") { t.removeLast() }
        return t.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? p
    }
    /// Epoch seconds as "18:30", or "Sat 18:30" with the weekday (local time, like Date#getHours).
    public static func fmtEpoch(_ sec: Double, weekday: Bool, calendar: Calendar = .current) -> String {
        let d = Date(timeIntervalSince1970: sec)
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: d)
        let clock = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return weekday ? "\(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][(c.weekday ?? 1) - 1]) \(clock)" : clock
    }
}
