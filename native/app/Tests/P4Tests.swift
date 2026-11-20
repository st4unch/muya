// P4: every localStorage key the native app reads or writes — decode, encode, missing / garbled -> safe default —
// plus the ui-prefs.json store (merge, debounce, corrupt file) and the settings bridge.

import Foundation

func runP4Tests() {
    func tmp() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muya-p4t-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    let garbage: [String?] = [nil, "", "not json", "{", "[1,", "null", "\u{0}"]

    test("bool keys (agentsOpen, inspectorOpen, filesOpen): JSON true/false; anything else is nil = default") {
        check(PrefCodec.bool("true") == true && PrefCodec.bool("false") == false, "round trip")
        check(PrefCodec.encode(bool: true) == "true" && PrefCodec.encode(bool: false) == "false", "encode")
        for g in garbage + ["1", "\"true\"", "[true]", "{}"] { check(PrefCodec.bool(g) == nil, "garbled \(g ?? "nil") -> nil") }
    }

    test("width keys: clamped 220-480 / 260-520 and rounded; non-numbers fall back") {
        check(PrefCodec.number("300", min: 220, max: 480) == 300, "in range")
        check(PrefCodec.number("100", min: 220, max: 480) == 220 && PrefCodec.number("9999", min: 220, max: 480) == 480, "clamped")
        check(PrefCodec.number("300.6", min: 220, max: 480) == 301, "rounded")
        check(PrefCodec.number("1e999", min: 260, max: 520) == nil, "infinite")
        for g in garbage + ["\"300\"", "true", "[300]"] { check(PrefCodec.number(g, min: 220, max: 480) == nil, "garbled \(g ?? "nil")") }
        check(PrefCodec.encode(number: 300.4) == "300", "encode")
    }

    test("string lists (composer history, workspaces ...): JSON array, non-strings dropped, newest last, at most 200") {
        check(PrefCodec.stringList("[\"a\",\"b\"]") == ["a", "b"], "read")
        check(PrefCodec.stringList("[\"a\",1,null,\"b\"]") == ["a", "b"], "non-strings dropped")
        for g in garbage + ["{}", "\"a\""] { check(PrefCodec.stringList(g) == nil, "garbled \(g ?? "nil")") }
        let long = PrefCodec.encode(list: (0 ..< 250).map(String.init))
        let h = PrefCodec.history(long) ?? []
        check(h.count == 200 && h.last == "249" && h.first == "50", "history keeps the newest 200")
        check(PrefCodec.stringList(PrefCodec.encode(list: ["ünï \"q\"", "日本"])) == ["ünï \"q\"", "日本"], "unicode + quotes round trip")
    }

    test("flags (autoApprove, autoSave, resumeOnLaunch): \"1\" = on, key removed = off") {
        check(PrefCodec.flag("1") && !PrefCodec.flag(nil) && !PrefCodec.flag("0") && !PrefCodec.flag("true"), "decode")
        check(PrefCodec.encode(flag: true) == "1" && PrefCodec.encode(flag: false) == nil, "encode")
    }

    test("apex.theme: raw system|light|dark <-> System|Light|Dark; unknown -> nil") {
        check(PrefCodec.appearance("dark") == "Dark" && PrefCodec.appearance("light") == "Light" && PrefCodec.appearance("system") == "System", "decode")
        check(PrefCodec.encode(appearance: "Dark") == "dark", "encode")
        for g in garbage + ["Dark", "blue"] { check(PrefCodec.appearance(g) == nil, "garbled \(g ?? "nil")") }
    }

    test("muya.terminalPrefs: font size clamped 9-28; other fields survive a write") {
        let raw = "{\"fontSize\":15,\"lineHeight\":1.4,\"letterSpacing\":1,\"scheme\":\"muya\"}"
        check(PrefCodec.fontSize(raw) == 15, "read")
        check(PrefCodec.fontSize("{\"fontSize\":2}") == 9 && PrefCodec.fontSize("{\"fontSize\":99}") == 28, "clamped")
        for g in garbage + ["{}", "{\"fontSize\":\"big\"}", "[]"] { check(PrefCodec.fontSize(g) == nil, "garbled \(g ?? "nil")") }
        let out = PrefCodec.encode(fontSize: 17, into: raw)
        let o = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
        check(o?["fontSize"] as? Int == 17 && o?["lineHeight"] as? Double == 1.4 && o?["scheme"] as? String == "muya" && o?["letterSpacing"] as? Int == 1, "merged")
        check(PrefCodec.fontSize(PrefCodec.encode(fontSize: 12, into: "garbage")) == 12, "garbled previous value is replaced")
    }

    test("muya.openFiles: valid entries only, last 30, keys of the old app survive a write") {
        let raw = "[{\"key\":\"k1\",\"kind\":\"editor\",\"filePath\":\"/a/b.txt\",\"name\":\"b.txt\"},{\"key\":\"k2\",\"kind\":\"weird\",\"filePath\":\"/c\",\"name\":\"c\"},{\"kind\":\"pdfview\",\"filePath\":\"/d.pdf\"},{\"key\":\"k4\",\"kind\":\"pdfview\",\"filePath\":\"/d.pdf\",\"name\":\"d.pdf\"}]"
        check(PrefCodec.openFiles(raw) == ["/a/b.txt", "/d.pdf"], "bad kind / missing fields dropped")
        for g in garbage + ["{}"] { check(PrefCodec.openFiles(g) == nil, "garbled \(g ?? "nil")") }
        let many = (0 ..< 40).map { "/f/\($0)" }
        check(PrefCodec.openFiles(PrefCodec.encode(openFiles: many, kind: { _ in "editor" }, previous: nil))?.count == 30, "capped at 30")
        let out = PrefCodec.encode(openFiles: ["/a/b.txt", "/new.md"], kind: { $0.hasSuffix(".md") ? "mdview" : "editor" }, previous: raw)
        let l = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: String]] ?? []
        check(l.count == 2 && l[0]["key"] == "k1" && l[1]["key"] == "file:/new.md" && l[1]["kind"] == "mdview" && l[1]["name"] == "new.md", "keys kept, kinds and names filled")
    }

    test("store: reads the migrated file, writes merge with the disk, never drop a foreign key") {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("ui-prefs.json")
        try? Data("{\"apex.theme\":\"dark\",\"apex.mergeQueue\":\"[\\\"/p\\\"]\",\"muya.unicode\":\"Türkçe 日本語\"}".utf8).write(to: f)
        let s = LegacyStore(url: f, debounce: 0.05)
        check(s.get("apex.theme") == "dark" && s.get("nope") == nil, "read")
        // another writer (QueuePrefs) changes its key while we hold ours dirty
        try? Data("{\"apex.theme\":\"dark\",\"apex.mergeQueue\":\"[\\\"/q\\\"]\",\"muya.unicode\":\"Türkçe 日本語\"}".utf8).write(to: f)
        s.set("muya.panels.agentsOpen", "false")
        s.flush()
        let disk = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: String] ?? [:]
        check(disk["apex.mergeQueue"] == "[\"/q\"]" && disk["muya.panels.agentsOpen"] == "false" && disk["muya.unicode"] == "Türkçe 日本語", "merged: \(disk)")
        s.set("muya.panels.agentsOpen", nil); s.flush()
        check(((try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: String])?["muya.panels.agentsOpen"] == nil, "nil removes the key")
        let perm = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.posixPermissions] as? Int
        check(perm == 0o600, "private file mode (\(String(describing: perm)))")
    }

    test("store: writes are debounced, unchanged values never write, a burst is one write") {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("ui-prefs.json")
        let s = LegacyStore(url: f, debounce: 0.15)
        for i in 0 ..< 200 { s.set("muya.panels.agentsWidth", String(220 + i % 100)) }
        check(!FileManager.default.fileExists(atPath: f.path), "nothing on disk inside the debounce window")
        Thread.sleep(forTimeInterval: 0.5)
        check(s.writeCount == 1, "200 changes -> 1 write (\(s.writeCount))")
        s.set("muya.panels.agentsWidth", String(220 + 199 % 100)); s.flush()
        check(s.writeCount == 1, "same value again -> no write")
        s.flush()
        check(s.writeCount == 1, "flush with nothing pending -> no write")
    }

    test("store: missing file = empty; a garbled file is moved aside and writing works afterwards") {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("sub/ui-prefs.json")
        let none = LegacyStore(url: f)
        check(none.isEmpty && none.get("x") == nil, "missing file")
        none.set("a", "1"); none.flush()
        check(FileManager.default.fileExists(atPath: f.path), "directory created")
        try? Data("{ not json".utf8).write(to: f)
        let s = LegacyStore(url: f)
        check(s.isEmpty, "garbled reads as empty")
        check(FileManager.default.fileExists(atPath: f.appendingPathExtension("corrupt").path), "garbled file kept aside")
        s.set("b", "2"); s.flush()
        check(LegacyStore(url: f).get("b") == "2", "writes work again")
        try? Data("[1,2]".utf8).write(to: f)
        check(LegacyStore(url: f).isEmpty, "wrong shape reads as empty")
    }

    test("bridge: a migrated file drives the settings; later settings writes are mirrored back with the same formats") {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let lf = d.appendingPathComponent("ui-prefs.json")
        let migrated = "{\"apex.theme\":\"dark\",\"muya.autoSave\":\"1\",\"muya.terminalPrefs\":\"{\\\"fontSize\\\":16,\\\"lineHeight\\\":1.4,\\\"scheme\\\":\\\"muya\\\"}\"}"
        try? Data(migrated.utf8).write(to: lf)
        let prefs = UIPrefs(url: d.appendingPathComponent("prefs.json"))
        let legacy = LegacyStore(url: lf, debounce: 0.05)
        let bridge = PrefsBridge(prefs: prefs, legacy: legacy); defer { withExtendedLifetime(bridge) {} }
        check(prefs.string("appearance") == "Dark" && prefs.bool("autoSave") && !prefs.bool("autoApprove") && prefs.int("terminalFontSize") == 16, "settings follow the migrated file")
        prefs.set("appearance", "Light"); prefs.set("autoApprove", true); prefs.set("autoSave", false); prefs.set("terminalFontSize", 20); prefs.set("resumeOnLaunch", true)
        legacy.flush()
        let disk = (try? JSONSerialization.jsonObject(with: Data(contentsOf: lf))) as? [String: String] ?? [:]
        check(disk["apex.theme"] == "light" && disk["muya.autoApprove"] == "1" && disk["muya.autoSave"] == nil && disk["muya.resumeOnLaunch"] == "1", "mirrored: \(disk)")
        check(PrefCodec.fontSize(disk["muya.terminalPrefs"]) == 20 && (disk["muya.terminalPrefs"] ?? "").contains("lineHeight"), "font size mirrored, other fields kept")
        // a second launch reads what the first wrote
        let again = UIPrefs(url: d.appendingPathComponent("prefs2.json"))
        let bridge2 = PrefsBridge(prefs: again, legacy: LegacyStore(url: lf)); defer { withExtendedLifetime(bridge2) {} }
        check(again.string("appearance") == "Light" && again.bool("autoApprove") && again.bool("resumeOnLaunch") && !again.bool("autoSave") && again.int("terminalFontSize") == 20, "round trip across launches")
    }

    test("bridge: native-only values are pushed to a file that lacks them; garbled values change nothing") {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let lf = d.appendingPathComponent("ui-prefs.json")
        try? Data("{\"apex.theme\":\"blue\",\"muya.terminalPrefs\":\"oops\"}".utf8).write(to: lf)
        let prefs = UIPrefs(url: d.appendingPathComponent("prefs.json"))
        prefs.set("autoApprove", true); prefs.set("appearance", "Dark")
        let legacy = LegacyStore(url: lf, debounce: 0.05)
        let bridge = PrefsBridge(prefs: prefs, legacy: legacy); defer { withExtendedLifetime(bridge) {} }
        check(prefs.string("appearance") == "Dark" && prefs.int("terminalFontSize") == 13, "garbled theme/font keep the native values")
        legacy.flush()
        check(legacy.get("muya.autoApprove") == "1" && legacy.get("apex.theme") == "dark", "native values written under today's keys")
    }

    test("bridge: pinned agents, footer fields and the heads-up day follow today's formats") {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let lf = d.appendingPathComponent("ui-prefs.json")
        try? Data("{\"muya.pinnedAgents\":\"[\\\"a\\\",\\\"b\\\"]\",\"apex.sessionsHeadsUp\":\"2026-11-04\"}".utf8).write(to: lf)
        let prefs = UIPrefs(url: d.appendingPathComponent("prefs.json"))
        let legacy = LegacyStore(url: lf, debounce: 0.05)
        let b = PrefsBridge(prefs: prefs, legacy: legacy); defer { withExtendedLifetime(b) {} }
        check((prefs.get("pinnedAgents") as? [String]) == ["a", "b"] && prefs.string("storageHeadsUpDay") == "2026-11-04", "read from the migrated file")
        prefs.set("statusFields", ["Model", "Cost"]); prefs.set("pinnedAgents", [String]())
        legacy.flush()
        check(PrefCodec.stringList(legacy.get("muya.footer.statusFields")) == ["Model", "Cost"] && legacy.get("muya.pinnedAgents") == nil, "written back, empty list removes the key")
    }

    test("every key of today's app is either handled or listed obsolete with a reason") {
        let handled: Set<String> = [PrefKeys.theme, PrefKeys.autoApprove, PrefKeys.autoSave, PrefKeys.resumeOnLaunch, PrefKeys.terminalPrefs, PrefKeys.viewMode,
                                    PrefKeys.agentsOpen, PrefKeys.inspectorOpen, PrefKeys.agentsWidth, PrefKeys.inspectorWidth, PrefKeys.filesOpen, PrefKeys.filesHeight,
                                    PrefKeys.openFiles, PrefKeys.composerHistoryAgent, PrefKeys.mergeQueue, "muya.pinnedAgents", "muya.footer.statusFields", "apex.sessionsHeadsUp", PrefKeys.splitGroups, PrefKeys.splitCollapsed]
        let all = ["apex.composerHistory.agent", "apex.composerHistory.shell", "apex.gridKeys", "apex.mergeQueue", "apex.openTabs", "apex.selectedRoot", "apex.sessionsHeadsUp", "apex.theme",
                   "apex.viewMode", "apex.workspaces", "apex.worktrees", "muya.autoApprove", "muya.autoSave", "muya.composerOpen", "muya.fileAccessGate.dismissed", "muya.footer.statusFields",
                   "muya.gridLayout", "muya.lastActive", "muya.lastActive.v2", "muya.notifications", "muya.notificationsUnread", "muya.openFiles", "muya.panels.agentsOpen", "muya.panels.agentsWidth",
                   "muya.panels.filesHeight", "muya.panels.filesOpen", "muya.panels.inspectorOpen", "muya.panels.inspectorWidth", "muya.pinnedAgents", "muya.resumeOnLaunch", "muya.selectedAgent",
                   "muya.servers.collapsed", "muya.vault.collapsed", "muya.sessionHeaderCollapsed", "muya.splitGroups", "muya.splitGroupsCollapsed", "muya.terminalPrefs", "muya.waitingSince"]
        for k in all { check(handled.contains(k) != (PrefKeys.obsolete[k] != nil), "\(k): exactly one of handled / obsolete") }
        check(PrefKeys.obsolete.values.allSatisfy { $0.count > 15 }, "every obsolete key has a reason")
    }
}
