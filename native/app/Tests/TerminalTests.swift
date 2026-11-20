// Terminal colour schemes, find (⌘F), Paste as Path text, Clear Scrollback and the footer's status fields — against the
// tables generated from today's sources and a real libghostty terminal.

import Foundation

func runTerminalTests() {
    test("the 9 colour schemes of today's picker: ids, labels, 20 colours each, muya follows the app theme") {
        check(TerminalSchemes.all.map(\.id) == ["muya", "dracula", "nord", "one-dark", "tokyo-night", "gruvbox-dark", "solarized-dark", "solarized-light", "github-light"], "ids")
        check(TerminalSchemes.all.first?.label == "Muya (follows app theme)", "label")
        for s in TerminalSchemes.all.dropFirst() {
            let t = TerminalSchemes.hex[s.id]
            check(t?.count == 20, "\(s.id) has \(t?.count ?? 0) colours")
            check(TerminalTheme.fixed(s.id)?.ansi.count == 16, "\(s.id) theme")
        }
        check(TerminalTheme.fixed("muya") == nil && TerminalTheme.fixed("nope") == nil, "no table for muya / unknown")
        check(TerminalTheme.fixed("dracula")?.background.hexValue == 0x282A36 && TerminalTheme.fixed("solarized-light")?.foreground.hexValue == 0x657B83, "dracula / solarized values")
    }
    test("the scheme is kept in muya.terminalPrefs next to the other keys; unknown ids read as muya") {
        let raw = PrefCodec.encode(scheme: "nord", into: "{\"fontSize\":15,\"lineHeight\":1.4}")
        check(PrefCodec.scheme(raw) == "nord" && PrefCodec.fontSize(raw) == 15 && raw.contains("lineHeight"), "kept: \(raw)")
        check(PrefCodec.scheme("{\"scheme\":\"bogus\"}") == "muya" && PrefCodec.scheme("{}") == nil && PrefCodec.scheme(nil) == nil, "validation")
        check(PrefCodec.scheme(PrefCodec.encode(scheme: "bogus", into: nil)) == "muya", "encode validates")
    }
    test("find: case-insensitive plain text, cells of wide characters, no overlaps, wrap-around stepping") {
        let ms = TerminalFind.matches(lines: ["Alpha beta ALPHA", "none", "日本 alpha"], query: "alpha")
        check(ms == [FindMatch(row: 0, col: 0, cells: 5), FindMatch(row: 0, col: 11, cells: 5), FindMatch(row: 2, col: 5, cells: 5)], "\(ms)")
        check(TerminalFind.matches(lines: ["aaaa"], query: "aa") == [FindMatch(row: 0, col: 0, cells: 2), FindMatch(row: 0, col: 2, cells: 2)], "non-overlapping")
        check(TerminalFind.matches(lines: ["x"], query: "").isEmpty, "empty query")
        check(TerminalFind.step(count: 3, current: nil, forward: true) == 0 && TerminalFind.step(count: 3, current: nil, forward: false) == 2, "first / last")
        check(TerminalFind.step(count: 3, current: 2, forward: true) == 0 && TerminalFind.step(count: 3, current: 0, forward: false) == 2, "wraps")
        check(TerminalFind.step(count: 0, current: nil, forward: true) == nil, "nothing")
        check(TerminalFind.firstAtOrAfter(ms, row: 1) == 2 && TerminalFind.firstAtOrAfter(ms, row: 9) == 0, "starts near the view")
    }
    test("Paste as Path text: backslashes, trailing newline dropped, URL check — like src/lib/termMenu.ts") {
        check(TerminalFind.escapeForShell("/Users/a/My Files/x (1).txt") == "/Users/a/My\\ Files/x\\ \\(1\\).txt", "spaces and brackets")
        check(TerminalFind.escapeForShell("a&b;c$d'e\"f") == "a\\&b\\;c\\$d\\'e\\\"f", "shell characters")
        check(TerminalFind.escapeForShell("/tmp/x\n") == "/tmp/x" && TerminalFind.escapeForShell("/tmp/x\r\n") == "/tmp/x", "newline")
        check(TerminalFind.escapeForShell("/usr/local/bin/tool-1.2_x") == "/usr/local/bin/tool-1.2_x", "plain untouched")
        check(TerminalFind.isWebURL(" https://github.com/st4unch/muya ") && TerminalFind.isWebURL("http://localhost:1420/?mock=1"), "urls")
        check(!TerminalFind.isWebURL("see https://a.com now") && !TerminalFind.isWebURL("file:///etc/hosts") && !TerminalFind.isWebURL("javascript:alert(1)") && !TerminalFind.isWebURL(""), "not urls")
    }
    test("find and Clear Scrollback on a real terminal: scrollback is searched, the match is selected and scrolled to, scrollback goes") {
        guard let r = Replica(cols: 40, rows: 5, theme: .dark) else { check(false, "replica"); return }
        var text = ""
        for i in 1 ... 30 { text += "row-\(i) Alpha beta\r\n" }
        r.write(Data(text.utf8))
        let lines = r.bufferLines()
        check(lines.count >= 30 && lines.contains("row-1 Alpha beta"), "buffer has the scrollback: \(lines.count) lines")
        let ms = TerminalFind.matches(lines: lines, query: "row-3 ")
        check(ms.count == 1, "one row-3: \(ms)")
        r.scrollToBottom()
        if let m = ms.first {
            r.show(m)
            check(r.selectedText() == "row-3", "selected \(r.selectedText() ?? "nil")")
            let top = r.viewportTop
            check(m.row >= top && m.row < top + 5, "scrolled to it: row \(m.row) top \(top)")
        }
        check(r.scrollState.history > 0, "has history")
        r.clearScrollback()
        check(r.scrollState.history == 0 && !r.hasSelection, "scrollback cleared, selection gone")
        check(r.visibleText().contains("row-30"), "the screen stays")
    }
    test("status fields: the catalogue is today's, values come from the status JSON, labels from the first build map to ids") {
        check(StatusFieldCatalog.fields.count == 67 && StatusFieldCatalog.groupOrder.count == 10, "67 fields in 10 groups")
        let data: [String: Any] = [
            "model": ["display_name": "Opus", "id": "claude-opus-5-5"], "effort": ["level": "high"], "version": "2.1.260",
            "context_window": ["used_percentage": 42.4, "remaining_percentage": 57.6, "context_window_size": 200_000, "total_input_tokens": 16_900,
                               "current_usage": ["input_tokens": 850, "cache_read_input_tokens": 3_400]],
            "exceeds_200k_tokens": false, "cost": ["total_cost_usd": 1.239, "total_duration_ms": 125_000, "total_lines_added": 12, "total_lines_removed": 3],
            "pr": ["number": 42, "review_state": "changes_requested", "kind": "mr"], "workspace": ["current_dir": "/Users/x/proj/", "repo": ["owner": "o", "name": "n"]],
            "prompt_cache": ["hit_ratio": 0.875, "warm": true, "miss_causes": ["ttl": 2, "edit": 1], "last_miss_cause": ["causes": ["system_changed", "ttl"]]],
            "rate_limits": ["five_hour": ["used_percentage": 12, "resets_at": 0]],
        ]
        func v(_ id: String) -> String? { StatusFieldCatalog.value(id, data) }
        check(v("model.display_name") == "Opus" && v("model.id") == "claude-opus-5-5" && v("effort.level") == "high" && v("version") == "2.1.260", "model")
        check(v("context_window.used_percentage") == "42%" && v("context_window.remaining_percentage") == "58%" && v("context_window.context_window_size") == "200.0k", "context \(v("context_window.used_percentage") ?? "-")")
        check(v("context_window.total_input_tokens") == "16.9k" && v("context_window.current_usage.input_tokens") == "850" && v("context_window.current_usage.cache_read_input_tokens") == "3.4k", "tokens")
        check(v("exceeds_200k_tokens") == "off" && v("prompt_cache.warm") == "on", "bools")
        check(v("cost.total_cost_usd") == "$1.24" && v("cost.total_duration_ms") == "2m 5s" && v("cost.lines") == "+12 −3" && v("cost.total_lines_added") == "+12" && v("cost.total_lines_removed") == "−3", "cost")
        check(v("pr.number") == "#42" && v("pr.review_state") == "changes requested" && v("pr.kind") == "merge request", "pr")
        check(v("workspace.current_dir") == "proj" && v("workspace.repo") == "o/n", "workspace")
        check(v("prompt_cache.hit_ratio") == "88%" && v("prompt_cache.miss_causes") == "3" && v("prompt_cache.last_miss_cause") == "system changed, ttl", "cache: \(v("prompt_cache.hit_ratio") ?? "-")")
        check(v("rate_limits.five_hour.used_percentage") == "12%" && v("rate_limits.five_hour.resets_at")?.hasPrefix("resets ") == true, "rate limits")
        check(v("session_id") == nil && v("cost.nope") == nil && StatusFieldCatalog.value("model.display_name", nil) == nil && StatusFieldCatalog.value("bogus", data) == nil, "absent fields hide")
        check(StatusFieldCatalog.fmtEpoch(0, weekday: true, calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()) == "Thu 00:00", "epoch with weekday")
        check(StatusFieldCatalog.normalize(["Model", "model.id", "Context used", "Model", "gone"]) == ["model.display_name", "model.id", "context_window.used_percentage"], "labels → ids, no duplicates")
        check(StatusFieldCatalog.filtered("cache").allSatisfy { !$0.1.isEmpty } && StatusFieldCatalog.filtered("zzzz").isEmpty && StatusFieldCatalog.filtered("").count == 10, "filter")
    }
}
