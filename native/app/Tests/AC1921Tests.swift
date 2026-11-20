// AC19 / AC21: the wire shapes the daemon uses for version skew and restart, how a failed connection is classified, the
// screens' wording, the resume plan, and the client handshake against a fake daemon (refuse -> "later" hello -> upgrade).
// The real daemons and the real app are exercised by verify-ac19.sh / verify-ac21.sh.

import Darwin
import Foundation

/// A one-connection-at-a-time fake muyad on a Unix socket: replies to Hello by the announced major and to Upgrade.
final class FakeDaemon: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var _hellos: [(UInt16, UInt16)] = []
    private var _upgrades = 0
    var hellos: [(UInt16, UInt16)] { lock.lock(); defer { lock.unlock() }; return _hellos }
    var upgrades: Int { lock.lock(); defer { lock.unlock() }; return _upgrades }
    let sessions: [LiveSession]

    init?(daemonMajor: UInt16, daemonMinor: UInt16, sessions: [LiveSession]) {
        self.sessions = sessions
        path = "/tmp/muya-ac1921-fake-\(getpid())-\(UInt32.random(in: 0 ..< 1_000_000)).sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        unlink(path)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(fd, 8) == 0 else { return nil }
        let lfd = fd, me = self
        Thread.detachNewThread {
            while true {
                let c = accept(lfd, nil, nil)
                if c < 0 { return }
                Thread.detachNewThread { me.serve(c, daemonMajor, daemonMinor) }
            }
        }
    }

    func stop() { Darwin.close(fd); unlink(path) }

    private func send(_ c: Int32, _ control: Control) {
        let d = Frame.control(control).encoded()
        _ = d.withUnsafeBytes { write(c, $0.baseAddress, d.count) }
    }

    /// Reads frames by hand: `Control.parse` drops the version of a hello, and this daemon decides by it.
    private func serve(_ c: Int32, _ major: UInt16, _ minor: UInt16) {
        defer { Darwin.close(c) }
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(c, &buf, buf.count)
            if n <= 0 { return }
            pending.append(contentsOf: buf[0 ..< n])
            while pending.count >= 4 {
                let len = Int(pending.prefix(4).reduce(0) { $0 << 8 | Int($1) })
                guard pending.count >= 4 + len else { break }
                let body = Data(pending.subdata(in: 4 ..< 4 + len)); pending.removeSubrange(0 ..< 4 + len)
                guard body.first == 1, let obj = try? JSONSerialization.jsonObject(with: body.dropFirst()) as? [String: Any], let type = obj["type"] as? String else { continue }
                switch type {
                case "hello":
                    let m = UInt16((obj["major"] as? Int) ?? 0), mi = UInt16((obj["minor"] as? Int) ?? 0)
                    lock.lock(); _hellos.append((m, mi)); lock.unlock()
                    reply(c, announced: m, announcedMinor: mi, major, minor)
                case "upgrade":
                    lock.lock(); _upgrades += 1; lock.unlock()
                    send(c, .upgrading(plan: sessions, ptydRestarting: true))
                default: break
                }
            }
        }
    }

    private func reply(_ c: Int32, announced: UInt16, announcedMinor: UInt16, _ major: UInt16, _ minor: UInt16) {
        if announced == major { send(c, .welcome(major: major, minor: minor, serverBuild: "fake")); return }
        let v = ProtoVersion(major: major, minor: minor, build: "fake")
        send(c, .incompatible(message: "protocol \(announced).\(announcedMinor) is not compatible with \(major).\(minor)", detail:
            Incompat(daemon: v, client: ProtoVersion(major: announced, minor: announcedMinor, build: "app"),
                     required: ProtoVersion(major: major, minor: 0, build: "fake"), speak: v, sessions: sessions)))
    }
}

func runAC1921Tests() {
    let live2 = LiveSession(id: 2, pid: 102, cwd: "/w", claudeSessionId: "c-1")
    let live3 = LiveSession(id: 3, pid: 103, cwd: "/w")

    test("AC19 wire: upgrade / upgrading / incompatible keep the daemon's exact JSON shapes and round trip") {
        // The same strings muya-proto's own test pins (crates/muya-proto/src/lib.rs, upgrade_messages_round_trip_with_stable_shapes).
        let upgrade = String(decoding: Frame.control(.upgrade).encoded().dropFirst(5), as: UTF8.self)
        check(upgrade == #"{"type":"upgrade"}"#, "upgrade shape \(upgrade)")
        let rustUpgrading = #"{"type":"upgrading","plan":[{"id":2,"pid":102,"cwd":"/w","claude_session_id":"c-1"},{"id":3,"pid":103,"cwd":"/w"}],"ptyd_restarting":true}"#
        let parsed = try? Control.parse(Data(rustUpgrading.utf8))
        check(parsed == .upgrading(plan: [live2, live3], ptydRestarting: true), "parses the daemon's upgrading")
        let incompat = Incompat(daemon: ProtoVersion(major: 1, minor: 3, build: "d"), client: ProtoVersion(major: 2, minor: 5, build: "a"),
                                required: ProtoVersion(major: 1, minor: 0, build: "d"), speak: ProtoVersion(major: 1, minor: 3, build: "d"), sessions: [live2, live3])
        let hello = String(decoding: Frame.control(.helloAs(major: 2, minor: 7, role: "app", build: "b")).encoded().dropFirst(5), as: UTF8.self)
        check(hello == #"{"build":"b","major":2,"minor":7,"role":"app","type":"hello"}"#, "announced hello \(hello)")
        for c in [Control.upgrade, .upgrading(plan: [live2], ptydRestarting: false), .incompatible(message: "m", detail: incompat)] {
            var dec = FrameDecoder(); dec.push(Frame.control(c).encoded())
            check((try? dec.next()) == .control(c), "round trip \(c)")
        }
        // A plain error stays a plain error; an `incompatible` without `detail` (an older daemon) too.
        check((try? Control.parse(Data(#"{"type":"error","code":"incompatible","message":"m"}"#.utf8))) == .error(code: "incompatible", message: "m"), "no detail -> plain error")
        check((try? Control.parse(Data(#"{"type":"error","code":"not_approved","message":"m"}"#.utf8))) == .error(code: "not_approved", message: "m"), "not_approved")
        // Session lists from a minor-3 daemon carry cwd; from an older one they do not.
        let withCwd = try? Control.parse(Data(#"{"type":"sessions","sessions":[{"id":1,"pid":2,"cols":80,"rows":24,"end_seq":0,"exited":null,"cwd":"/p"}]}"#.utf8))
        let without = try? Control.parse(Data(#"{"type":"sessions","sessions":[{"id":1,"pid":2,"cols":80,"rows":24,"end_seq":0,"exited":null}]}"#.utf8))
        check(withCwd == .sessions([SessionInfo(id: 1, pid: 2, cols: 80, rows: 24, endSeq: 0, exited: nil, cwd: "/p")]), "cwd parsed")
        check(without == .sessions([SessionInfo(id: 1, pid: 2, cols: 80, rows: 24, endSeq: 0, exited: nil)]), "cwd optional")
        check(protoMinor == minorUpgrade, "the app announces the minor that has Upgrade")
    }

    test("a failed connection is classified: needs approval / version skew / unreachable") {
        let info = Incompat(daemon: ProtoVersion(major: 1, minor: 3, build: ""), client: ProtoVersion(major: 2, minor: 0, build: ""),
                            required: ProtoVersion(major: 1, minor: 0, build: ""), speak: ProtoVersion(major: 1, minor: 3, build: ""), sessions: [live2])
        check(ServiceProblem.classify(ClientError.server(code: "not_approved", message: "ptyd is not approved")) == .needsApproval, "not_approved")
        check(ServiceProblem.classify(ClientError.incompatible(info)) == .versionSkew(info), "typed skew")
        if case .versionSkew(let i) = ServiceProblem.classify(ClientError.server(code: "incompatible", message: "old daemon")) { check(i.sessions.isEmpty, "skew without detail has no sessions") } else { check(false, "plain incompatible is still a skew") }
        check(ServiceProblem.classify(ClientError.socket("no such file")) == .unreachable("socket: no such file"), "no socket and no approval pending = unreachable")
        check(ServiceProblem.classify(ClientError.socket("no such file"), loginItemWaitsForApproval: true) == .needsApproval, "no socket while the system waits for approval = onboarding")
        check(ServiceProblem.classify(ClientError.server(code: "internal", message: "x")) != .needsApproval, "other server errors are not onboarding")
        check(ServiceProblem.classify(ClientError.timeout) == .unreachable("muyad did not answer in time"), "timeout")
    }

    test("screens say what the service is, why it is needed and where to approve; the restart dialog names the sessions kept") {
        let t = ServiceCopy.onboardingWhat + ServiceCopy.onboardingWhy + ServiceCopy.onboardingSteps
        check(t.contains("background service") && t.contains("Login Items") && t.contains("by itself"), "onboarding copy")
        check(ServiceCopy.onboardingButton == "Open Login Items", "button")
        let rows = KeptSession.rows([live2, LiveSession(id: 4, pid: 1, cwd: "/h", exited: 0), LiveSession(id: 5, pid: 5, cwd: "/h/proj")], home: "/h")
        check(rows.count == 2, "exited sessions are not listed")
        check(rows[0] == KeptSession(title: "w", detail: "/w · resumes Claude conversation c-1"), "claude row \(rows[0])")
        check(rows[1] == KeptSession(title: "proj", detail: "~/proj"), "shell row \(rows[1])")
        let body = ServiceCopy.restartBody(daemon: ProtoVersion(major: 1, minor: 3, build: ""), app: ProtoVersion(major: 2, minor: 0, build: ""), kept: 2)
        check(body.contains("2.0") && body.contains("1.3") && body.contains("2 running sessions") && body.contains("Later"), "dialog copy \(body)")
        check(ServiceCopy.restartBody(daemon: ProtoVersion(major: 1, minor: 3, build: ""), app: ProtoVersion(major: 2, minor: 0, build: ""), kept: 0).contains("nothing is lost"), "no sessions")
    }

    test("resume plan: only live sessions, a deleted folder falls back to home, a hostile Claude id gets no command") {
        let plan = [live2, live3, LiveSession(id: 9, pid: 9, cwd: "/gone", claudeSessionId: "abc"), LiveSession(id: 8, pid: 8, cwd: "/w", claudeSessionId: "x'; rm -rf ~ #"),
                    LiveSession(id: 7, pid: 7, cwd: "/w", exited: 1)]
        let steps = ResumeStep.steps(plan, home: "/h") { $0 == "/w" }
        check(steps.count == 4, "exited one skipped")
        check(steps[0] == ResumeStep(cwd: "/w", name: "↻ w", command: "claude --resume 'c-1' --permission-mode auto"), "claude session resumes in place \(steps[0])")
        check(steps[1] == ResumeStep(cwd: "/w", name: "w", command: nil), "plain shell")
        check(steps[2].cwd == "/h" && steps[2].name == "↻ Shell", "missing folder -> home \(steps[2])")
        check(steps[3].command == nil, "an id that could break out of the quotes is never typed")
        check(ResumeStep.parsePlan(["pending": false, "sessions": []]) == nil, "nothing pending")
        check(ResumeStep.parsePlan("junk") == nil, "garbage")
        check(ResumeStep.parsePlan(["pending": true, "sessions": [["id": 2, "pid": 102, "cwd": "/w", "claude_session_id": "c-1"]], "from_build": "x"]) == [live2], "daemon's plan file")
    }

    test("reconnect pace: onboarding polls every 2 s, a restart every 0.5 s, an outage every 1 s") {
        check(ReconnectPolicy.delay(onboarding: true, restarting: false) == 2, "onboarding")
        check(ReconnectPolicy.delay(onboarding: false, restarting: true) == 0.5, "restart")
        check(ReconnectPolicy.delay(onboarding: false, restarting: false) == 1, "plain")
        check(RestartPhase.resuming(done: 1, total: 3).text == "Opening your sessions again (1 of 3)…" && RestartPhase.restarting.busy && !RestartPhase.finished(resumed: 3).busy, "phases")
    }

    test("client against a daemon of another major: refused with the detail, 'later' hello works, Upgrade returns the plan") {
        guard let d = FakeDaemon(daemonMajor: 1, daemonMinor: 3, sessions: [live2, live3]) else { check(false, "fake daemon"); return }
        defer { d.stop() }
        // A newer app announces major 2: refused with versions and the sessions a restart would end.
        var detail: Incompat?
        do { _ = try MuyadConnection(path: d.path, build: "t", announce: (2, 0), peer: .sameUser); check(false, "should be refused") } catch ClientError.incompatible(let i) { detail = i } catch { check(false, "wrong error \(error)") }
        check(detail?.daemon.major == 1 && detail?.client.major == 2 && detail?.sessions == [live2, live3], "detail \(String(describing: detail))")
        guard let speak = detail?.speak else { return }
        // "Later": the daemon's own version in the hello is welcomed (major check follows the announced major).
        do {
            let c = try MuyadConnection(path: d.path, build: "t", announce: (speak.major, speak.minor), peer: .sameUser)
            check(c.serverMinor == 3, "serverMinor \(c.serverMinor)")
            c.start()
            // "Now": Upgrade -> Upgrading with the plan (a reply, so it completes the oldest pending request).
            let reply = try c.request(.upgrade)
            check(reply == .upgrading(plan: [live2, live3], ptydRestarting: true), "upgrading \(reply)")
            check(d.upgrades == 1, "upgrade seen once")
            c.close()
        } catch { check(false, "compat connect threw \(error)") }
        check(d.hellos.map(\.0) == [2, 1], "hellos \(d.hellos)")
    }
}
