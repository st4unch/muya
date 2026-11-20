// Unit tests of Sources/Logic/ServiceIdentity.swift: is the running background service this copy's?

import Foundation

func runServiceIdentityTests() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    test("service identity: the same program is current, another path is another copy, a newer file is a replaced service") {
        check(ServiceIdentity.verdict(running: "/Applications/Muya.app/Contents/MacOS/muyad", startedAt: t0, expected: "/Applications/Muya.app/Contents/MacOS/muyad", expectedModified: t0 - 60) == .current, "same path, file older than the process")
        check(ServiceIdentity.verdict(running: "/x/.Trash/Muya Native.app/Contents/MacOS/muyad", startedAt: t0, expected: "/Applications/Muya.app/Contents/MacOS/muyad", expectedModified: t0) == .otherCopy(running: "/x/.Trash/Muya Native.app/Contents/MacOS/muyad"), "the old copy in the Trash")
        check(ServiceIdentity.verdict(running: "/A/muyad", startedAt: t0, expected: "/A/muyad", expectedModified: t0 + 3600) == .replaced(path: "/A/muyad"), "updated in place, service not restarted")
        check(ServiceIdentity.verdict(running: "/A/muyad", startedAt: t0, expected: "/A/muyad", expectedModified: t0 + 1) == .current, "2 s tolerance")
    }
    test("service identity: nothing to compare means unknown, never a false alarm") {
        check(ServiceIdentity.verdict(running: nil, startedAt: nil, expected: "/A/muyad", expectedModified: nil) == .unknown && ServiceIdentity.verdict(running: "/A/muyad", startedAt: nil, expected: nil, expectedModified: nil) == .unknown && ServiceIdentity.verdict(running: "", startedAt: nil, expected: "/A", expectedModified: nil) == .unknown, "missing sides")
        check(ServiceIdentity.verdict(pid: getpid(), expected: nil) == .unknown && ServiceIdentity.verdict(pid: getpid(), expected: "/no/such/muyad") == .unknown, "no bundled program")
        check(ServiceIdentity.bundled("muyad", bundleURL: URL(fileURLWithPath: "/tmp/build/MuyaNative")) == nil && ServiceIdentity.bundled("muyad", bundleURL: URL(fileURLWithPath: "/Applications/Muya.app")) == "/Applications/Muya.app/Contents/MacOS/muyad", "only a .app bundle has services inside")
    }
    test("service identity: symlinks do not make a copy look foreign; this very process is judged by its own path") {
        let d = NSTemporaryDirectory() + "svc-id-\(getpid())"
        try? FileManager.default.createDirectory(atPath: d + "/real", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: d + "/real/muyad", contents: Data())
        try? FileManager.default.createSymbolicLink(atPath: d + "/link", withDestinationPath: d + "/real")
        check(ServiceIdentity.verdict(running: d + "/real/muyad", startedAt: nil, expected: d + "/link/muyad", expectedModified: nil) == .current, "link and target are the same program")
        defer { try? FileManager.default.removeItem(atPath: d) }
        let me = ServiceIdentity.programPath(of: getpid())
        // (start time is not compared here: build.sh exec()s this test, so the process "started" when the script did)
        check(me != nil && ServiceIdentity.verdict(running: me, startedAt: nil, expected: me, expectedModified: nil) == .current, "own pid's path is its own path: \(me ?? "nil")")
        check(ServiceIdentity.parentPID(of: getpid()) != nil && ServiceIdentity.startTime(of: getpid()) != nil, "parent and start time are readable")
    }
    test("service identity: the worse verdict wins, and the stale-service dialog names the other copy and the sessions") {
        check(ServiceIdentity.worst(.current, .otherCopy(running: "/x")) == .otherCopy(running: "/x") && ServiceIdentity.worst(.replaced(path: "/y"), .otherCopy(running: "/x")) == .otherCopy(running: "/x") && ServiceIdentity.worst(.unknown, .current) == .current, "ranking")
        let s = StaleService(verdict: .otherCopy(running: "/Users/u/.Trash/Muya Native.app/Contents/MacOS/muyad"), program: "muyad", sessions: [])
        let body = ServiceCopy.staleBody(s, kept: 2, home: "/Users/u")
        check(body.contains("~/.Trash/Muya Native.app") && body.contains("another copy") && body.contains("ends the 2 running sessions") && body.contains("“Later” keeps everything"), body)
        check(ServiceCopy.staleBody(s, kept: 0, home: "/Users/u").contains("nothing is lost"), "no sessions")
    }
}

func runServiceRecoveryTests() {
    test("service identity: the daemon's announced release decides when the path cannot") {
        check(ServiceIdentity.buildVerdict(serverBuild: "0.1.0+4.1.24", product: "4.1.24") == .current, "same release")
        check(ServiceIdentity.buildVerdict(serverBuild: "0.1.0+4.1.23", product: "4.1.24") == .differentBuild(daemon: "4.1.23", app: "4.1.24"), "older release")
        check(ServiceIdentity.buildVerdict(serverBuild: "0.1.0", product: "4.1.24") == .differentBuild(daemon: nil, app: "4.1.24"), "daemon without a stamp predates it")
        check(ServiceIdentity.buildVerdict(serverBuild: "0.1.0", product: nil) == .unknown && ServiceIdentity.buildVerdict(serverBuild: "0.1.0", product: "0.0.1") == .unknown, "dev build: nothing to compare")
        check(ServiceIdentity.worst(.differentBuild(daemon: nil, app: "1"), .replaced(path: "/x")) == .differentBuild(daemon: nil, app: "1") && ServiceIdentity.worst(.otherCopy(running: "/x"), .differentBuild(daemon: nil, app: "1")) == .otherCopy(running: "/x"), "ranking")
        let s = StaleService(verdict: .differentBuild(daemon: nil, app: "4.1.24"), program: "muyad", sessions: [])
        let body = ServiceCopy.staleBody(s, kept: 0, home: "/Users/u")
        check(body.contains("older release") && body.contains("4.1.24") && body.contains("nothing is lost"), body)
    }
    test("service recovery: wait for launchd, then start this copy's agents, then say what is wrong") {
        typealias R = ServiceRecovery
        check(R.plan(isSocketError: true, approvalPending: false, jobLoaded: true, failures: 3, attempts: 0, detail: nil) == .wait, "job listed: give launchd its grace")
        check(R.plan(isSocketError: true, approvalPending: false, jobLoaded: true, failures: 4, attempts: 0, detail: nil) == .restart, "listed but silent for 4 tries")
        check(R.plan(isSocketError: true, approvalPending: false, jobLoaded: false, failures: 2, attempts: 0, detail: nil) == .restart, "job gone: no point waiting")
        check(R.plan(isSocketError: true, approvalPending: false, jobLoaded: nil, failures: 1, attempts: 0, detail: nil) == .wait, "first miss never acts")
        check(R.plan(isSocketError: true, approvalPending: true, jobLoaded: false, failures: 99, attempts: 0, detail: nil) == .wait, "the approval card owns that case")
        check(R.plan(isSocketError: false, approvalPending: false, jobLoaded: false, failures: 99, attempts: 0, detail: nil) == .wait, "a handshake error is not a dead service")
        check(R.plan(isSocketError: true, approvalPending: false, jobLoaded: false, failures: 7, attempts: 1, detail: nil) == .wait, "after an attempt macOS gets time")
        check(R.plan(isSocketError: true, approvalPending: false, jobLoaded: false, failures: 8, attempts: 1, detail: nil) == .restart, "one more try")
        if case let .giveUp(m) = R.plan(isSocketError: true, approvalPending: false, jobLoaded: false, failures: 8, attempts: 2, detail: "Operation not permitted") {
            check(m.contains("Login Items") && m.contains("Retry") && m.contains("Operation not permitted") && !m.contains("connection closed"), m)
        } else { check(false, "gives up after two attempts") }
        check(ServiceCopy.notConnected(status: nil).contains("Retry") && ServiceCopy.notConnected(status: "Starting the background service…").hasSuffix("Press Retry in a moment."), "page text")
        check(ClientError.notConnected("x").description == "x", "the error says the text, not \"connection closed\"")
    }
    test("service recovery: only a socket nobody listens on is stale, and only that is removed") {
        let d = NSTemporaryDirectory() + "svc-rec-\(getpid())"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: d) }
        func bindSocket(_ path: String) -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
            let b = Array(path.utf8CString)
            withUnsafeMutableBytes(of: &a.sun_path) { raw in for (i, c) in b.enumerated() { raw[i] = UInt8(bitPattern: c) } }
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            return fd
        }
        let live = d + "/live.sock", dead = d + "/dead.sock", plain = d + "/file"
        let lfd = bindSocket(live); listen(lfd, 4)
        let dfd = bindSocket(dead); close(dfd)   // the file stays, nothing listens: what a booted-out job leaves behind
        FileManager.default.createFile(atPath: plain, contents: Data())
        check(StaleSocket.state(live) == .alive && StaleSocket.state(dead) == .stale && StaleSocket.state(d + "/none") == .missing && StaleSocket.state(plain) == .missing, "states")
        check(!StaleSocket.sweep(live) && FileManager.default.fileExists(atPath: live), "a live socket is never removed")
        check(StaleSocket.sweep(dead) && !FileManager.default.fileExists(atPath: dead), "the dead one is removed")
        check(!StaleSocket.sweep(plain) && FileManager.default.fileExists(atPath: plain), "a plain file is left alone")
        check(ServiceRecovery.deadAgents(muyadSocket: live, ptydSocket: d + "/gone.sock") == ["com.staunch.muya.ptyd.plist"], "only the dead agent is registered again")
        close(lfd)
    }
}
