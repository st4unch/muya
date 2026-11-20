// Unit tests of the Command dialog's target resolution and result mapping (Sources/Logic/CommandLogic.swift).

import Foundation

func runCommandTests() {
    let all = [CommandCandidate(id: 1, name: "api", isAgent: true), CommandCandidate(id: 2, name: "shell", isAgent: false),
               CommandCandidate(id: 3, name: "web", isAgent: true), CommandCandidate(id: 4, name: "dead", isAgent: true, exited: true),
               CommandCandidate(id: 5, name: "docs", isAgent: true)]
    test("command: this session is only the current one, and only when it is a live agent") {
        check(CommandLogic.resolve(.this, current: 3, groupIds: nil, picked: [], all: all) == [3], "current")
        check(CommandLogic.resolve(.this, current: 2, groupIds: nil, picked: [], all: all).isEmpty, "a shell never receives")
        check(CommandLogic.resolve(.this, current: 4, groupIds: nil, picked: [], all: all).isEmpty, "an exited one never receives")
        check(CommandLogic.resolve(.this, current: nil, groupIds: nil, picked: [], all: all).isEmpty, "no selection")
    }
    test("command: group = the split group's live agents; no group falls back to this session") {
        check(CommandLogic.resolve(.group, current: 1, groupIds: [5, 1, 2, 4], picked: [], all: all) == [1, 5], "sidebar order, shell and exited dropped")
        check(CommandLogic.resolve(.group, current: 3, groupIds: nil, picked: [], all: all) == [3], "not grouped -> just this")
    }
    test("command: pick keeps the sidebar order and ignores ticked ids that are no longer receivers or are gone") {
        check(CommandLogic.resolve(.pick, current: 1, groupIds: nil, picked: [5, 1, 2, 4, 99], all: all) == [1, 5], "pick")
        check(CommandLogic.resolve(.pick, current: 1, groupIds: nil, picked: [], all: all).isEmpty, "nothing ticked")
    }
    test("command: all = every live agent, capped at the daemon's limit") {
        check(CommandLogic.resolve(.all, current: 1, groupIds: nil, picked: [], all: all) == [1, 3, 5], "all")
        let many = (1 ... 100).map { CommandCandidate(id: UInt64($0), name: "s\($0)", isAgent: true) }
        check(CommandLogic.resolve(.all, current: 1, groupIds: nil, picked: [], all: many).count == CommandLogic.maxTargets, "cap")
    }
    test("command: send button text and field trimming") {
        check(CommandLogic.sendTitle(count: 0) == "Send" && CommandLogic.sendTitle(count: 1) == "Send to 1 session" && CommandLogic.sendTitle(count: 3) == "Send to 3 sessions", "titles")
        check(CommandLogic.trimmed("  /compact \n") == "/compact" && CommandLogic.trimmed("   ") == nil, "trim")
        check(CommandLogic.presets == ["/compact", "/clear", "/model sonnet", "/cost"], "presets")
    }
    test("command: daemon results map to rows; an unknown state is a failure, not a success") {
        let json: [String: Any] = ["results": [["id": 1, "name": "api", "state": "submitted"], ["id": 3, "name": "web", "state": "queued", "reason": "busy"],
                                               ["id": 5, "name": "docs", "state": "skipped", "reason": "waiting on a permission prompt: nothing was typed"],
                                               ["id": 6, "name": "x", "state": "failed", "reason": "this terminal is gone"], ["id": 7, "name": "y", "state": "teleported"]]]
        let rs = CommandResult.parse(json)
        check(rs.map(\.state) == [.submitted, .queued, .skipped, .failed, .failed], "states \(rs.map(\.state))")
        check(rs[2].label == "Skipped (waiting on a dialog)" && rs[1].label == "Queued (busy)" && rs[0].label == "Submitted", "labels")
        check(rs[4].reason == "unknown answer from the daemon" && rs[0].reason == nil, "reasons")
        check(CommandResult.summary(rs) == "1 submitted · 1 queued · 1 skipped · 2 failed", "summary \(CommandResult.summary(rs))")
        check(CommandResult.parse("garbage").isEmpty, "garbage")
    }
    test("command: result rows use the names shown in the app") {
        let rs = CommandResult.named([CommandResult(id: 1, name: "#1", state: .submitted), CommandResult(id: 9, name: "daemon name", state: .failed)], by: all)
        check(rs[0].name == "api" && rs[1].name == "daemon name", "names \(rs.map(\.name))")
    }
    test("command: a request that never got an answer fails every row") {
        let rs = CommandResult.allFailed([all[0], all[2]], reason: "Background service is not running")
        check(rs.count == 2 && rs.allSatisfy { $0.state == .failed && $0.reason == "Background service is not running" }, "all failed")
    }
}
