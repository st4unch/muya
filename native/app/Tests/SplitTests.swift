// Unit tests of the split-group model (Sources/Logic/SplitLogic.swift), mirroring src/lib/controlSplit.test.ts.

import Foundation

func runSplitTests() {
    test("split layout: 2 → 2×1, 4 → 2×2, 7 → 4×2") {
        check(SplitLogic.layout(2) == (2, 1) && SplitLogic.layout(3) == (3, 1) && SplitLogic.layout(4) == (2, 2) && SplitLogic.layout(6) == (3, 2) && SplitLogic.layout(8) == (4, 2) && SplitLogic.layout(1) == (1, 1), "layouts")
    }
    test("split: clone joins the source's group, or starts one; full groups refuse") {
        let a = SplitLogic.addToGroup([], source: "a", clone: "b", newId: "g1")!
        check(a == [SplitGroup(id: "g1", keys: ["a", "b"])], "new group")
        let b = SplitLogic.addToGroup(a, source: "b", clone: "c", newId: "g2")!
        check(b == [SplitGroup(id: "g1", keys: ["a", "b", "c"])], "joins the existing group")
        check(SplitLogic.addToGroup(a, source: "a", clone: "b", newId: "x") == nil && SplitLogic.addToGroup(a, source: "a", clone: "a", newId: "x") == nil, "already grouped / self")
        let full = SplitGroup(id: "f", keys: (1 ... 8).map(String.init))
        check(SplitLogic.addToGroup([full], source: "1", clone: "z", newId: "x") == nil && !SplitLogic.canSplit([full], "3") && SplitLogic.canSplit([full], "q"), "cap of 8")
    }
    test("split: drag-to-group moves a pane between groups and dissolves a group left with one") {
        let g = [SplitGroup(id: "g1", keys: ["a", "b"]), SplitGroup(id: "g2", keys: ["c", "d"])]
        let r = SplitLogic.joinGroup(g, from: "a", to: "c", newId: "n")!
        check(r == [SplitGroup(id: "g2", keys: ["c", "d", "a"])], "a left g1 (dissolved) and joined g2: \(r)")
        check(SplitLogic.joinGroup(g, from: "a", to: "b", newId: "n") == nil && SplitLogic.joinGroup(g, from: "a", to: "a", newId: "n") == nil, "same group / self")
        check(SplitLogic.joinGroup([], from: "x", to: "y", newId: "n") == [SplitGroup(id: "n", keys: ["y", "x"])], "two loose terminals start a group")
    }
    test("split: close a pane, neighbour focus, resolve against open tabs, persistence round trip") {
        let g = [SplitGroup(id: "g", keys: ["a", "b", "c"])]
        check(SplitLogic.removeFromGroups(g, "b") == [SplitGroup(id: "g", keys: ["a", "c"])] && SplitLogic.removeFromGroups(SplitLogic.removeFromGroups(g, "b"), "a").isEmpty, "close dissolves at one")
        check(SplitLogic.neighbourAfterClose(["a", "b", "c"], closed: "b") == "c" && SplitLogic.neighbourAfterClose(["a", "b", "c"], closed: "c") == "b" && SplitLogic.neighbourAfterClose(["a"], closed: "a") == nil, "neighbours")
        check(SplitLogic.resolve(g + [SplitGroup(id: "h", keys: ["c", "d", "e"])], existing: ["a", "c", "d", "e"]) == [SplitGroup(id: "g", keys: ["a", "c"]), SplitGroup(id: "h", keys: ["d", "e"])], "closed tabs and claimed keys drop")
        let raw = try? JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: SplitLogic.encode(g)))
        check(SplitLogic.decode(raw) == g && SplitLogic.decode("x") == nil && SplitLogic.decode([["id": 1]])!.isEmpty, "round trip, garbage ignored")
    }
    test("split: a group saved under bare session ids is dropped, so ⌘T cannot land in an old split") {
        // muya-ptyd hands out session ids from 1 again whenever it starts, so "1" names a different terminal in
        // every run. Only `id:pid` keys survive being read back; the old form is thrown away, not reused.
        let old = [SplitGroup(id: "g", keys: ["1", "2"])]
        check(SplitLogic.dropLegacyKeys(old).isEmpty, "a group of bare ids is gone: \(SplitLogic.dropLegacyKeys(old))")
        let now = [SplitGroup(id: "g", keys: ["1:4711", "2:4712"])]
        check(SplitLogic.dropLegacyKeys(now) == now, "today's keys are kept")
        let mixed = [SplitGroup(id: "g", keys: ["1", "7:4711", "8:4712"]), SplitGroup(id: "h", keys: ["3", "9:4713"])]
        check(SplitLogic.dropLegacyKeys(mixed) == [SplitGroup(id: "g", keys: ["7:4711", "8:4712"])], "half-old group loses the old key; one left alone dissolves: \(SplitLogic.dropLegacyKeys(mixed))")
        // And the live list still rules: a group whose terminals are gone leaves the saved groups.
        check(SplitLogic.resolve(now, existing: ["1:9999", "2:9998"]).isEmpty, "the same ids under new processes do not revive the group")
    }
    test("split: open_session split joins the caller's terminal, else a plain tab") {
        let ids = ["sess-1": "k1"]
        check(SplitLogic.splitForOpenSession([], splitWith: "sess-1", sessionIdToKey: ids, openKeys: ["k1"], newKey: "k2", newId: "g") == [SplitGroup(id: "g", keys: ["k1", "k2"])], "joins")
        check(SplitLogic.splitForOpenSession([], splitWith: "nope", sessionIdToKey: ids, openKeys: ["k1"], newKey: "k2", newId: "g") == nil && SplitLogic.splitForOpenSession([], splitWith: "sess-1", sessionIdToKey: ids, openKeys: [], newKey: "k2", newId: "g") == nil && SplitLogic.splitForOpenSession([], splitWith: nil, sessionIdToKey: ids, openKeys: ["k1"], newKey: "k2", newId: "g") == nil, "unknown id / closed tab / no id")
    }
    test("split: dragging a divider keeps the sum at 1 and each pane at least 10 %") {
        let f = SplitLogic.moveDivider([0.5, 0.5], index: 0, delta: 0.2)
        check(abs(f[0] - 0.7) < 1e-9 && abs(f[1] - 0.3) < 1e-9, "\(f)")
        let g = SplitLogic.moveDivider([0.4, 0.3, 0.3], index: 1, delta: -0.5)
        check(abs(g[1] - 0.1) < 1e-9 && abs(g.reduce(0, +) - 1) < 1e-9 && g[0] == 0.4, "\(g)")
        check(SplitLogic.moveDivider([1], index: 0, delta: 0.1) == [1], "single pane unchanged")
    }

    test("split groups: the whole lifecycle — create, add, ungroup, dissolve, reorder, persist") {
        var g: [SplitGroup] = []
        g = SplitLogic.joinGroup(g, from: "a", to: "b", newId: "g1")!                       // drag a onto b: a group [b, a]
        check(g == [SplitGroup(id: "g1", keys: ["b", "a"])], "created \(g)")
        g = SplitLogic.addToGroup(g, source: "a", clone: "c", newId: "x")!                  // Split on a pane: the clone joins
        check(g[0].keys == ["b", "a", "c"], "added \(g)")
        g = SplitLogic.groupInto(g, from: "d", groupId: "g1", newId: "n")!                  // drop on the group header
        check(g[0].keys == ["b", "a", "c", "d"], "dropped on the header joins: \(g)")
        check(SplitLogic.groupInto(g, from: "b", groupId: "g1", newId: "n") == nil && SplitLogic.groupInto(g, from: "q", groupId: "nope", newId: "n") == nil, "own group / unknown group")
        g = SplitLogic.removeFromGroups(g, "a")                                              // dragged to empty list space
        check(g == [SplitGroup(id: "g1", keys: ["b", "c", "d"])], "ungrouped keeps the rest \(g)")
        let raw = try? JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: SplitLogic.encode(g)))
        check(SplitLogic.decode(raw) == g, "survives a restart")
        g = SplitLogic.removeFromGroups(SplitLogic.removeFromGroups(g, "b"), "c")
        check(g.isEmpty, "dissolves at one")
        check(SplitLogic.leavesSplitOnReorder([SplitGroup(id: "g", keys: ["a", "b"])], from: "a", to: "z") && !SplitLogic.leavesSplitOnReorder([SplitGroup(id: "g", keys: ["a", "b"])], from: "a", to: "b") && !SplitLogic.leavesSplitOnReorder([], from: "a", to: "z"), "reorder between loose rows ungroups a member")
    }
    test("agent list drop: middle half groups, top and bottom quarter reorder; reorder moves the row to the target's place") {
        check(SplitLogic.dropMode(y: 5, height: 76) == .reorder && SplitLogic.dropMode(y: 38, height: 76) == .group && SplitLogic.dropMode(y: 70, height: 76) == .reorder && SplitLogic.dropMode(y: 19, height: 76) == .reorder && SplitLogic.dropMode(y: 19.5, height: 76) == .group, "modes")
        check(SplitLogic.reorder(["a", "b", "c", "d"], from: "d", to: "b") == ["a", "d", "b", "c"], "up")
        check(SplitLogic.reorder(["a", "b", "c", "d"], from: "a", to: "c") == ["b", "a", "c", "d"], "down lands before the target (re-found after the removal)")
        check(SplitLogic.reorder(["a", "b"], from: "x", to: "a") == ["a", "b"] && SplitLogic.reorder(["a", "b"], from: "a", to: "a") == ["a", "b"], "unknown / self")
        check(SplitLogic.applyOrder(["1", "2", "3", "4"], saved: ["3", "1", "gone"]) == ["3", "1", "2", "4"], "saved order, new sessions at the end")
    }
    test("split clone: a running Claude forks its conversation, any other agent starts fresh, a shell stays a shell") {
        let f = SplitLogic.cloneSpec(name: "api", agent: "claude", sessionId: "abc-123", sessionCwd: nil)
        check(f.name == "api (fork)" && f.forked && f.command == "claude --resume 'abc-123' --fork-session --permission-mode auto", "\(f)")
        let w = SplitLogic.cloneSpec(name: "api", agent: "claude", sessionId: "abc-123", sessionCwd: "/p/it's")
        check(w.command == "cd '/p/it'\\''s' && claude --resume 'abc-123' --fork-session --permission-mode auto", "\(w.command ?? "")")
        check(SplitLogic.cloneSpec(name: "api", agent: "claude", sessionId: nil, sessionCwd: nil) == SplitLogic.SplitClone(name: "api", command: "claude --permission-mode auto", forked: false), "claude without a known id")
        check(SplitLogic.cloneSpec(name: "api", agent: "claude", sessionId: "x; rm -rf /", sessionCwd: nil).command == "claude --permission-mode auto", "unsafe id never reaches the shell")
        check(SplitLogic.cloneSpec(name: "oc", agent: "opencode", sessionId: nil, sessionCwd: nil).command == "opencode --auto", "opencode")
        check(SplitLogic.cloneSpec(name: "sh", agent: nil, sessionId: nil, sessionCwd: nil) == SplitLogic.SplitClone(name: "sh", command: nil, forked: false), "plain shell")
    }
    test("open_session payload: name required, split target, unattended command with the opener and the first message") {
        check(OpenAgentSession(payload: "{\"name\":\" \"}") == nil && OpenAgentSession(payload: "nope") == nil, "needs a name")
        let o = OpenAgentSession(payload: "{\"name\":\"w1\",\"cwd\":\"/tmp\",\"initialMessage\":\"it's go\",\"agent\":\"claude\",\"splitWith\":\"abc\",\"openedBy\":\"abc\",\"unattended\":true}")!
        check(o.splitWith == "abc" && o.cwd == "/tmp" && o.agent == "claude", "fields")
        let c = o.command(openerName: "lead")
        check(c.hasPrefix("claude --permission-mode auto --disallowedTools AskUserQuestion,EnterPlanMode,ExitPlanMode --append-system-prompt '"), c)
        check(c.contains("--name 'w1'") && c.contains("send_to_session(target: \"abc\"") && c.hasSuffix("it'\\''s go'"), "name, opener, quoted message: \(c)")
        let a = OpenAgentSession(payload: "{\"name\":\"w2\",\"agent\":\"opencode\",\"initialMessage\":\"hi\"}")!
        check(a.command(openerName: nil) == "opencode --auto --prompt 'hi'" && a.splitWith == nil, "opencode")
        let h = OpenAgentSession(payload: "{\"name\":\"w3\",\"unattended\":false}")!
        check(h.command(openerName: nil) == "claude --permission-mode auto --name 'w3'", h.command(openerName: nil))
    }
}
