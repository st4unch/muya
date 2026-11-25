// Unit tests of the SSH / PSMP / CyberArk / Password Store logic (Sources/SSH): wire parsing, validation,
// error classification, Connect planning, view models, secret wiping, and the service against an in-memory
// fake daemon (all data synthetic: documentation names, reserved address ranges, no values).

import Foundation

private func server(_ edit: (inout SSHServer) -> Void = { _ in }) -> SSHServer {
    var s = SSHServer()
    s.id = "x1"; s.label = "Box"; s.host = "box.example.test"; s.port = 22; s.username = "ops"
    edit(&s)
    return s
}

func runSSHTests() {
    test("ssh server json: parse the daemon's camelCase shape and write it back") {
        let j: [String: Any] = ["id": "a", "label": "L", "host": "h.example.test", "port": 2200, "username": "u", "connectionType": "psmp", "psmpProfileId": "p1",
                                "credentialSource": ["kind": "cyberark", "cyberarkAccountId": "acc"], "agentAccess": true, "agentAdded": true, "sshOptions": "-J j@h", "group": "G"]
        guard let s = SSHServer(json: j) else { check(false, "parsed"); return }
        check(s.port == 2200 && s.connectionType == .psmp && s.psmpProfileId == "p1" && s.credentialKind == .cyberark && s.credentialRef == "acc", "fields \(s)")
        check(s.agentAccess && s.agentAdded && s.sshOptions == "-J j@h" && s.group == "G", "flags")
        let out = s.json()
        check(out["psmpProfileId"] as? String == "p1" && (out["credentialSource"] as? [String: Any])?["cyberarkAccountId"] as? String == "acc", "round trip")
        check(SSHServer(json: out) == s, "equal after round trip")
        check(SSHServer(json: ["label": "no host"]) == nil, "needs host and user")
        let d = SSHServer(json: ["host": "h", "username": "u"])!
        check(d.port == 22 && d.connectionType == .direct && d.credentialKind == .prompt && !d.agentAccess, "defaults (old config without new fields)")
        check(server { $0.connectionType = .direct; $0.psmpProfileId = "p" }.json()["psmpProfileId"] == nil, "psmp id only written for psmp servers")
        check((server { $0.credentialKind = .local; $0.credentialRef = "n" }.json()["credentialSource"] as? [String: Any])?["localCredId"] as? String == "n", "local ref key")
    }

    test("server validation mirrors muya-core: required, dash, port, psmp, credential, duplicates") {
        check(SSHValidation.server(server(), others: [], profiles: []).isEmpty, "valid")
        check(SSHValidation.server(server { $0.host = "  " }, others: [], profiles: []).first?.field == "host", "empty host")
        check(SSHValidation.server(server { $0.host = "-oProxyCommand=x" }, others: [], profiles: []).first?.message.contains("'-'") == true, "option injection via host")
        check(SSHValidation.server(server { $0.username = "-l" }, others: [], profiles: []).first?.field == "username", "dash user")
        check(SSHValidation.server(server { $0.host = "a b" }, others: [], profiles: []).first?.field == "host", "space in host")
        check(["0", "65536", "-1"].allSatisfy { p in SSHValidation.server(server { $0.port = Int(p)! }, others: [], profiles: []).first?.field == "port" }, "port range")
        check(SSHValidation.server(server { $0.port = 65535 }, others: [], profiles: []).isEmpty, "max port ok")
        let profile = PSMPProfile(json: ["id": "p1", "psmpAddress": "psmp.example.test", "vaultUser": "svc"])!
        check(SSHValidation.server(server { $0.connectionType = .psmp }, others: [], profiles: [profile]).first?.field == "psmp", "psmp needs a profile")
        check(SSHValidation.server(server { $0.connectionType = .psmp; $0.psmpProfileId = "gone" }, others: [], profiles: [profile]).first?.message.contains("no longer exists") == true, "stale profile")
        check(SSHValidation.server(server { $0.connectionType = .psmp; $0.psmpProfileId = "p1" }, others: [], profiles: [profile]).isEmpty, "psmp with profile")
        check(SSHValidation.server(server { $0.credentialKind = .local }, others: [], profiles: []).first?.field == "credential", "stored login needs a reference")
        let other = server { $0.id = "y2"; $0.host = "BOX.example.test"; $0.username = "OPS" }
        check(SSHValidation.server(server { $0.id = "" }, others: [other], profiles: []).first?.message.contains("already exists") == true, "duplicate, case-insensitive")
        check(SSHValidation.server(server { $0.id = "y2" }, others: [other], profiles: []).isEmpty, "editing a server may keep its own address")
    }

    test("psmp profile validation: required, no whitespace, no user delimiter inside") {
        func p(_ addr: String, _ user: String, _ d: String = "@") -> PSMPProfile { var x = PSMPProfile(); x.psmpAddress = addr; x.vaultUser = user; x.userDelim = d; return x }
        check(SSHValidation.profile(p("psmp.example.test", "svc")).isEmpty, "valid")
        check(SSHValidation.profile(p("", "")).count == 2, "both required")
        check(SSHValidation.profile(p("psmp.example.test", "svc@dom")).first?.message.contains("delimiter") == true, "delimiter inside the vault user")
        check(SSHValidation.profile(p("psmp.example.test", "svc@dom", "#")).isEmpty, "'@' is fine when the delimiter is '#'")
        check(SSHValidation.profile(p("psmp host", "svc")).first?.field == "psmpAddress", "space")
        check(SSHValidation.profile(p("psmp.example.test", "sv\u{7}c")).first?.field == "vaultUser", "control character")
        check(PSMPProfile(json: ["psmpAddress": "a", "vaultUser": "u"])?.userDelim == "@", "default delimiters")
        check(PSMPProfile(json: PSMPProfile(json: ["psmpAddress": "a", "vaultUser": "u", "scpOptions": "-O"])!.json())?.scpOptions == "-O", "scp options survive")
    }

    test("secret validation: name, duplicates on add, missing on update, kind, value") {
        let existing = [SecretMeta(label: "Lab-Admin", description: "", kind: "password")]
        let v = SecretBuffer("placeholder-not-a-secret")
        check(SSHValidation.secret(label: "new-one", kind: "token", value: v, existing: existing, updating: false).isEmpty, "valid add")
        check(SSHValidation.secret(label: " ", kind: "token", value: v, existing: existing, updating: false).first?.field == "label", "name required")
        check(SSHValidation.secret(label: "lab-admin", kind: "password", value: v, existing: existing, updating: false).first?.message.contains("Update") == true, "duplicate points to Update")
        check(SSHValidation.secret(label: "lab-admin", kind: "password", value: v, existing: existing, updating: true).isEmpty, "valid update")
        check(SSHValidation.secret(label: "other", kind: "password", value: v, existing: existing, updating: true).first?.message.contains("No secret") == true, "update of a missing name")
        check(SSHValidation.secret(label: "n", kind: "pgp", value: v, existing: [], updating: false).first?.field == "kind", "unknown kind")
        check(SSHValidation.secret(label: "n", kind: "key", value: SecretBuffer(""), existing: [], updating: false).first?.field == "value", "empty value")
    }

    test("secret buffer: bytes really are zeroed and dropped by wipe") {
        let b = SecretBuffer("abc")
        check(b.count == 3 && b.reveal() == "abc", "holds the value")
        b.wipe()
        check(b.isEmpty && b.count == 0 && b.reveal() == "", "empty after wipe")
        b.wipe()
        check(b.isEmpty, "wipe twice is fine")
    }

    test("error classification: locked, not available yet, unknown method, other") {
        check(SSHErrorMap.classify("password store is locked — unlock it in the Password Store tab", as: [SecretMeta].self) == .locked, "locked")
        if case .notWired = SSHErrorMap.classify("CyberArk is not available in the native daemon yet", as: [SecretMeta].self) {} else { check(false, "not available") }
        if case let .notWired(m) = SSHErrorMap.classify("unknown method 'vault.list'", as: [SecretMeta].self) { check(m.contains("does not offer"), "friendly text: \(m)") } else { check(false, "unknown method") }
        if case .failed = SSHErrorMap.classify("connection closed", as: [SecretMeta].self) {} else { check(false, "other") }
        check(SSHErrorMap.unlockMessage("unknown method 'vault.unlock'").contains("Touch ID"), "unlock not wired")
        check(SSHErrorMap.unlockMessage("password store is locked — unlock it").contains("Still locked"), "unlock refused")
        check(SSHErrorMap.unlockMessage("denied by the user") == "denied by the user", "other text passes through")
    }

    test("connect: only an invalid server is refused page-side; the daemon opens the rest") {
        check(SSHConnect.precheck(server()) == nil, "a valid direct server goes to the daemon")
        check(SSHConnect.precheck(server { $0.credentialKind = .local; $0.credentialRef = "n" }) == nil, "stored login goes to the daemon")
        check(SSHConnect.precheck(server { $0.host = "-x" }) != nil, "invalid server never reaches the daemon")
    }

    test("servers model: filter, grouping, profile titles") {
        MainActor.assumeIsolated {
            let rpc = FakeSSHRpc()
            var m = ServersModel()
            m.servers = .ready(rpc.servers.compactMap(SSHServer.init(json:)))
            m.profiles = .ready(rpc.profiles.compactMap(PSMPProfile.init(json:)))
            check(m.visibleServers.count == 4, "all four")
            let headers = m.rows.compactMap { r -> String? in if case let .header(g) = r { return g } else { return nil } }
            check(headers == ["Lab", "Production", "Ungrouped"], "named groups first, ungrouped last: \(headers)")
            check(m.rows.count == 7, "four servers + three headers")
            m.filter = "192.0.2"
            check(m.visibleServers.map(\.id) == ["s2"], "filter by address")
            m.filter = "production"
            check(m.visibleServers.map(\.id) == ["s3"], "filter by group")
            check(m.profileTitle(id: "p1") == "Lab PSMP" && m.profileTitle(id: "nope") == "Missing profile" && m.profileTitle(id: nil) == "—", "profile titles")
            m.servers = .locked
            check(m.visibleServers.isEmpty, "no rows unless ready")
        }
    }

    test("vault model: names only, sorted, status text, confirmation wording") {
        var v = VaultModel()
        check(v.statusText == "Loading…", "loading")
        v.secrets = .locked
        check(v.statusText == "Locked" && v.visible.isEmpty, "locked shows no rows")
        v.secrets = .ready([SecretMeta(label: "b", description: "", kind: "key"), SecretMeta(label: "A", description: "d", kind: "token")])
        check(v.visible.map(\.label) == ["A", "b"] && v.statusText == "Unlocked · 2 item(s)", "sorted + count")
        v.filter = "d"
        check(v.visible.map(\.label) == ["A"], "filter on description")
        check(Mirror(reflecting: SecretMeta(label: "a", description: "", kind: "key")).children.allSatisfy { !["value", "secret", "password"].contains($0.label ?? "") }, "a SecretMeta cannot carry a value")
        check(VaultModel.confirmText(label: "n", kind: "key", updating: true).button == "Replace" && VaultModel.confirmText(label: "n", kind: "key", updating: false).button == "Store", "button wording")
        check(CyberArkModel(query: " ").canSearch == false && CyberArkModel(query: "lab").canSearch, "search needs text")
        var c = CyberArkModel()
        check(c.summary.contains("press Return"), "hint before searching")
        c.searched = true
        check(c.summary == "No accounts match", "empty result")
        c.state = .notWired("x"); check(c.summary == "x", "state text")
    }

    test("service against a working fake daemon: lists parse; save/delete round-trip") {
        MainActor.assumeIsolated {
            let rpc = FakeSSHRpc()
            let svc = SSHService(rpc: rpc)
            var got: PaneState<[SSHServer]> = .loading
            svc.servers { got = $0 }
            if case let .ready(list) = got { check(list.count == 4 && list[2].connectionType == .psmp, "servers parsed") } else { check(false, "servers ready: \(got)") }
            var prof: PaneState<[PSMPProfile]> = .loading
            svc.profiles { prof = $0 }
            if case let .ready(p) = prof { check(p.first?.scpOptions == "-O", "profile parsed") } else { check(false, "profiles ready") }
            var new = SSHServer(); new.host = "203.0.113.5"; new.username = "root"; new.label = "New"
            var saved = false
            svc.save(server: new) { if case .success = $0 { saved = true } }
            check(saved && rpc.servers.count == 5, "saved")
            svc.delete(server: "s1") { _ in }
            check(rpc.servers.count == 4 && rpc.servers.allSatisfy { $0["id"] as? String != "s1" }, "deleted")
            var acc: PaneState<[CyberArkAccount]> = .loading
            svc.searchAccounts("LAB-") { acc = $0 }
            if case let .ready(a) = acc { check(a.isEmpty, "no match for a word nobody has") } else { check(false, "accounts ready") }
            svc.searchAccounts("db.example") { acc = $0 }
            if case let .ready(a) = acc { check(a.count == 1 && a[0].safe == "DB-Prod" && a[0].platformId == "UnixSSH", "account parsed") } else { check(false, "accounts ready") }
        }
    }

    test("service against a daemon without the calls: every pane says not available yet") {
        MainActor.assumeIsolated {
            let svc = SSHService(rpc: FakeSSHRpc(mode: .unwired))
            var s: PaneState<[SSHServer]> = .loading, p: PaneState<[PSMPProfile]> = .loading, a: PaneState<[CyberArkAccount]> = .loading, v: PaneState<[SecretMeta]> = .loading
            svc.servers { s = $0 }; svc.profiles { p = $0 }; svc.searchAccounts("x") { a = $0 }; svc.secrets { v = $0 }
            for (n, ok) in [("servers", { if case .notWired = s { return true } else { return false } }()), ("profiles", { if case .notWired = p { return true } else { return false } }()),
                            ("cyberark", { if case .notWired = a { return true } else { return false } }()), ("vault", { if case .notWired = v { return true } else { return false } }())] {
                check(ok, "\(n) not wired")
            }
            var failed: String?
            svc.unlock { if case let .failure(e) = $0 { failed = e.message } }
            check(SSHErrorMap.unlockMessage(failed ?? "").contains("not available"), "unlock reports not available")
        }
    }

    test("locked store: list says locked, unlock opens it, secrets store and the buffer is wiped") {
        MainActor.assumeIsolated {
            let rpc = FakeSSHRpc(mode: .locked)
            let svc = SSHService(rpc: rpc)
            var v: PaneState<[SecretMeta]> = .loading
            svc.secrets { v = $0 }
            check(v == .locked, "locked")
            var a: PaneState<[CyberArkAccount]> = .loading
            svc.searchAccounts("x") { a = $0 }
            check(a == .locked, "cyberark needs the store too")
            var unlocked = false
            svc.unlock { if case .success = $0 { unlocked = true } }
            check(unlocked && rpc.unlocks == 1, "unlock call")
            svc.secrets { v = $0 }
            if case let .ready(list) = v { check(list.count == 3 && list.allSatisfy { $0.label != "" }, "names listed") } else { check(false, "ready after unlock") }
            let buf = SecretBuffer("placeholder-value-1")
            var stored = false
            svc.save(id: "", label: "fresh", username: "u1", group: "Grp", description: "d", kind: "token", value: buf) { if case .success = $0 { stored = true } }
            check(stored && rpc.lastSecretParam == "placeholder-value-1", "daemon received the value")
            check(buf.isEmpty, "buffer wiped after the call")
            check(rpc.calls.last == SSHMethod.vaultSave && rpc.secrets.last?["label"] as? String == "fresh" && rpc.secrets.last?["group"] as? String == "Grp", "saved with group")
            svc.secrets { v = $0 }
            if case let .ready(list) = v, let m = list.first(where: { $0.label == "fresh" }) {
                check(m.username == "u1" && m.group == "Grp" && !m.id.isEmpty, "list keeps id/username/group (old vault entries too)")
                var shown = ""
                svc.reveal(id: m.id) { if case let .success(t) = $0 { shown = t } }
                check(shown == "placeholder-value-1", "reveal returns the stored value for the operator")
                let buf2 = SecretBuffer("placeholder-value-2")
                svc.save(id: m.id, label: "fresh", username: "u1", group: "Grp", description: "d", kind: "token", value: buf2) { _ in }
                check(buf2.isEmpty && rpc.secrets.filter { $0["label"] as? String == "fresh" }.count == 1, "edit replaces in place and wipes")
                var gone = false
                svc.remove(id: m.id) { if case .success = $0 { gone = true } }
                check(gone && !rpc.secrets.contains { $0["label"] as? String == "fresh" }, "delete")
            } else { check(false, "fresh listed") }
            var xs = 0
            svc.exportBackup(dest: "/tmp/x.bak") { if case .success = $0 { xs += 1 } }
            svc.exportCred(id: "k1", dest: "/tmp/x.txt") { if case .success = $0 { xs += 1 } }
            svc.importFile(label: "ik", username: "u", secretKind: nil, description: "", group: "", path: "/tmp/k") { if case .success = $0 { xs += 1 } }
            svc.importFile(label: "ic", username: "", secretKind: "token", description: "d", group: "G", path: "/tmp/t") { if case .success = $0 { xs += 1 } }
            check(xs == 4 && rpc.calls.contains(SSHMethod.exportBackup) && rpc.calls.contains(SSHMethod.importKey) && rpc.calls.contains(SSHMethod.importSecret), "export / import calls")
            var tid = false
            svc.setTouchId(true) { if case .success = $0 { tid = true } }
            var st = SSHService.VaultStatus()
            svc.vaultStatus { st = $0 }
            check(tid && st.biometricAvailable, "touch id on")
            svc.setTouchId(false) { _ in }
            svc.vaultStatus { st = $0 }
            check(!st.biometricAvailable, "touch id off")
            var locked = false
            svc.lock { if case .success = $0 { locked = true } }
            check(locked && rpc.mode == .locked, "lock")
        }
    }

    test("store cards: named groups A-Z, Ungrouped last, kind names, 1/2/3 columns") {
        func m(_ l: String, _ g: String, _ k: String = "password") -> SecretMeta { var s = SecretMeta(label: l, description: "", kind: k); s.group = g; return s }
        let g = CredGroup.make([m("z", ""), m("b", "Prod"), m("a", "Lab"), m("c", "Lab"), m("y", "  ")])
        check(g.map(\.name) == ["Lab", "Prod", "Ungrouped"], "group order")
        check(g[0].items.map(\.label) == ["a", "c"] && g[2].items.map(\.label) == ["y", "z"], "items sorted, blank group = Ungrouped")
        check(CredKindName.title("key") == "SSH key" && CredKindName.title("api_key") == "API key" && CredKindName.title("token") == "token", "kind names")
        check([500, 767, 768, 1535, 1536].map { CredGroup.columns(pageWidth: CGFloat($0)) } == [1, 1, 2, 2, 3], "breakpoints")
    }

    test("server cards: named groups A-Z, Ungrouped last, classic's mono line") {
        func s(_ label: String, _ group: String, psmp: Bool = false, kind: CredentialKind = .prompt, ref: String? = nil) -> SSHServer {
            var v = SSHServer(); v.label = label; v.group = group; v.host = "10.0.1.11"; v.port = 22; v.username = "ubuntu"
            v.connectionType = psmp ? .psmp : .direct; v.credentialKind = kind; v.credentialRef = ref
            return v
        }
        let g = ServerGroup.make([s("web-02", ""), s("db-01", "Production"), s("web-01", "Production"), s("edge", "  ")])
        check(g.map(\.name) == ["Production", "Ungrouped"], "named groups first, Ungrouped last")
        check(g[0].items.map(\.title) == ["db-01", "web-01"], "servers sorted inside a group")
        check(g[1].items.map(\.title) == ["edge", "web-02"], "a blank group is Ungrouped")
        // classic shows the port even when it is 22, unlike `destination`.
        check(ServerCardLine.text(s("web-01", "P")) == "ubuntu@10.0.1.11:22 · direct · prompt", "direct, prompt")
        check(ServerCardLine.text(s("db-01", "P", psmp: true)) == "ubuntu@10.0.1.11:22 · PSMP · prompt", "PSMP")
        check(ServerCardLine.text(s("x", "P", kind: .cyberark)) == "ubuntu@10.0.1.11:22 · direct · CyberArk", "CyberArk login")
        let named = ServerCardLine.text(s("x", "P", kind: .local, ref: "c1"), credName: { $0 == "c1" ? "lab-admin" : nil })
        check(named == "ubuntu@10.0.1.11:22 · direct · lab-admin", "a stored credential shows its label")
        check(ServerCardLine.text(s("x", "P", kind: .local, ref: "gone")) == "ubuntu@10.0.1.11:22 · direct · Password Store", "locked store falls back to the kind")
        var added = s("y", ""); added.agentAdded = true
        check(ServerCardLine.text(added).hasSuffix("· added by agent"), "agent-added servers say so")
    }

    test("sections: tab order and titles") {
        check(SSHSection.allCases.map(\.title) == ["Servers", "PSMP profiles", "CyberArk", "Password Store"], "titles")
        // classic's tab bar: PSMP profiles are a card at the bottom of Servers, not a tab.
        check(SSHSection.tabs.map(\.title) == ["Servers", "CyberArk", "Password Store"], "the tab bar matches classic")
        check(CredentialKind.allCases.map(\.title) == ["Ask when connecting", "Password Store", "CyberArk account"], "login kinds")
    }
}
