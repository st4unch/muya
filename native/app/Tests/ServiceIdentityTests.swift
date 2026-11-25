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

func runServiceTakeoverTests() {
    test("service takeover: same path and release is used; another path or release is taken over once; a failed takeover asks") {
        check(ServiceTakeover.decide(verdict: .current, takeoverTried: false) == .use && ServiceTakeover.decide(verdict: .unknown, takeoverTried: false) == .use, "same path, same version")
        check(ServiceTakeover.decide(verdict: .otherCopy(running: "/Applications/Muya Native.app/Contents/MacOS/muyad"), takeoverTried: false) == .takeover, "other path")
        check(ServiceTakeover.decide(verdict: .differentBuild(daemon: "4.1.24", app: "5.0.1"), takeoverTried: false) == .takeover, "other version")
        check(ServiceTakeover.decide(verdict: .replaced(path: "/A/muyad"), takeoverTried: false) == .takeover, "replaced in place")
        check(ServiceTakeover.decide(verdict: .otherCopy(running: "/x"), takeoverTried: true) == .dialog && ServiceTakeover.decide(verdict: .differentBuild(daemon: nil, app: "5.0.1"), takeoverTried: true) == .dialog, "takeover failed: dialog, no loop")
        check(ServiceTakeover.decide(verdict: .otherCopy(running: "/x"), takeoverTried: false, autoEnabled: false) == .dialog, "automatic takeover off")
        check(ServiceTakeover.productOf(serverBuild: "0.1.0+4.1.24") == "4.1.24" && ServiceTakeover.productOf(serverBuild: "0.1.0") == nil, "product of the hello build")
        check(ServiceTakeover.bundlePath(ofProgram: "/Applications/Muya Native.app/Contents/MacOS/muyad") == "/Applications/Muya Native.app", "bundle of a program")
    }
    test("a copy that manages no service never sends the user to Login Items and never repairs anything") {
        // The text the installed app shows when macOS will not start its service names Muya's Login Items switch.
        // A dev build, a fake HOME or a hand-started daemon has no service of its own, so it must never show that text:
        // the user would go and change the INSTALLED Muya's setting over a copy that was never going to have one.
        let installed = ServiceCopy.cannotStart(detail: nil, jobLoaded: true)
        check(installed.contains("Allow in the Background"), "the installed app still explains the Login Items switch")
        check(!ServiceCopy.noServiceHere.contains("Allow in the Background"), "an unmanaged copy does not mention Login Items")
        check(!ServiceCopy.noServiceHere.contains("Retry"), "and does not ask for a Retry that cannot help")
        check(!ServiceTakeover.isManagedInstall(realHome: false, appBundle: true, testSaysSo: false), "a fake HOME manages nothing")
    }

    test("service takeover: only a real installed app takes over; a dev build, a fake HOME or a plain env var does not") {
        check(ServiceTakeover.isManagedInstall(realHome: true, appBundle: true, testSaysSo: false), "release install on the real home: protected")
        check(!ServiceTakeover.isManagedInstall(realHome: false, appBundle: true, testSaysSo: false), "fake HOME: no takeover")
        check(!ServiceTakeover.isManagedInstall(realHome: true, appBundle: false, testSaysSo: false), "bare dev binary: no takeover")
        check(ServiceTakeover.isManagedInstall(realHome: false, appBundle: true, testSaysSo: true), "a test that says what this copy is")
        // a release install: a daemon from another path or release is still taken over, and a failed takeover still asks
        check(ServiceTakeover.decide(verdict: .otherCopy(running: "/Users/u/Desktop/Muya.app/Contents/MacOS/muyad"), takeoverTried: false) == .takeover, "release: other bundle")
        check(ServiceTakeover.decide(verdict: .differentBuild(daemon: "4.1.24", app: "5.0.2"), takeoverTried: false) == .takeover, "release: other version")
    }
    test("service takeover: a job of the same bundle id but another path is foreign; the message names both copies and versions") {
        let ours = "com.staunch.muya"
        let parents: [String: String?] = ["com.staunch.muya.muyad": .some(ours), "com.staunch.muya.ptyd": .some(ours)]
        let progs = ["com.staunch.muya.muyad": "/Applications/Muya Native.app/Contents/MacOS/muyad", "com.staunch.muya.ptyd": "/Users/u/Desktop/Muya.app/Contents/MacOS/muya-ptyd"]
        let f = LegacyJobs.foreignServiceLabels(parents: parents, ourBundleID: ours, programs: progs, ourBundlePath: "/Users/u/Desktop/Muya.app")
        check(f == ["com.staunch.muya.muyad"], "only the muyad of the other copy: \(f)")
        check(LegacyJobs.foreignServiceLabels(parents: parents, ourBundleID: ours).isEmpty, "without paths the old rule holds")
        check(LaunchctlPrint.program("  program = /A/Muya.app/Contents/MacOS/muyad\n") == "/A/Muya.app/Contents/MacOS/muyad", "launchctl program line")
        let s = StaleService(verdict: .otherCopy(running: "/Applications/Muya Native.app/Contents/MacOS/muyad"), program: "muyad", sessions: [], appPath: "/Users/u/Desktop/Muya.app", appVersion: "5.0.1", daemonVersion: "4.1.24", takeoverFailure: "denied")
        let b = ServiceCopy.staleBody(s, kept: 0, home: "/Users/u")
        check(b.contains("~/Desktop/Muya.app (5.0.1)") && b.contains("/Applications/Muya Native.app (4.1.24)") && b.contains("could not (denied)"), b)
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

func runBundleCopiesTests() {
    test("duplicate bundles: re-register when the job cannot spawn or macOS points at the other copy; ask when that did not hold") {
        let me = "/Applications/Muya.app", old = "/Users/u/proj/target/release/bundle/macos/Muya.app"
        check(BundleCopies.decide(selfPath: me, copies: [me], resolved: me, spawnFailed: false, servicesDown: true, fixTried: false) == .ok, "one copy, healthy")
        check(BundleCopies.decide(selfPath: me, copies: [me, old], resolved: me, spawnFailed: false, servicesDown: true, fixTried: false) == .ok, "two copies but macOS picks this one")
        check(BundleCopies.decide(selfPath: me, copies: [me, old], resolved: old, spawnFailed: false, servicesDown: false, fixTried: false) == .ok, "services run: never touched")
        check(BundleCopies.decide(selfPath: me, copies: [me, old], resolved: old, spawnFailed: false, servicesDown: true, fixTried: false) == .reregister, "duplicate bundle id, down: re-register")
        check(BundleCopies.decide(selfPath: me, copies: [me, old], resolved: old, spawnFailed: true, servicesDown: true, fixTried: false) == .reregister, "spawn failed: re-register")
        check(BundleCopies.decide(selfPath: me, copies: [me], resolved: nil, spawnFailed: true, servicesDown: true, fixTried: false) == .reregister, "moved app, BTM keeps the old path: re-register")
        check(BundleCopies.decide(selfPath: me, copies: [me, old], resolved: old, spawnFailed: true, servicesDown: true, fixTried: true) == .dialog, "fix tried: dialog, no loop")
        check(BundleCopies.spawnFailed(launchctlPrint: "\tlast exit code = 78: EX_CONFIG\n\tjob state = spawn failed\n") && !BundleCopies.spawnFailed(launchctlPrint: "\tstate = running\n\tlast exit code = (never exited)\n"), "launchctl print")
        check(BundleCopies.parseMdfind("/Applications/Muya.app\n/x/y/Muya.app\nnoise\n") == ["/Applications/Muya.app", "/x/y/Muya.app"], "mdfind lines")
    }
    test("duplicate bundles: after Later / Escape the dialog is not offered again in this launch, the status line still says why") {
        let me = "/Applications/Muya.app", old = "/x/Muya.app"
        let d = BundleCopies.decide(selfPath: me, copies: [me, old], resolved: old, spawnFailed: true, servicesDown: true, fixTried: true)
        check(d == .dialog && BundleCopies.offer(dismissed: false) == .dialog, "first time: the dialog")
        check(d == .dialog && BundleCopies.offer(dismissed: true) == .statusOnly, "dismissed: status line only, no dialog")
        check(ServiceCopy.bundlesStatus.contains("more than one copy of Muya"), "the status line names the problem")
    }
    test("duplicate bundles: the dialog lists every copy with path and version, names the one in use, and offers the one fix") {
        let r = BundleReport(copies: [BundleCopy(path: "/Applications/Muya.app", version: "5.0.2", isSelf: true, resolved: false), BundleCopy(path: "/Users/u/proj/Muya.app", version: "4.1.24", isSelf: false, resolved: true)], spawnFailed: true, failure: "still failing")
        let b = BundleCopies.dialogBody(r, home: "/Users/u")
        check(b.contains("/Applications/Muya.app (5.0.2) — this copy") && b.contains("~/proj/Muya.app (4.1.24) — macOS uses it for the service") && b.contains("could not (still failing)") && b.contains("Use this copy's service"), b)
    }
}
