// Peer verification of the daemon socket, safe file reads and the "Open with Default App" guard.

import Darwin
import Foundation

private func tmpDir(_ mode: mode_t = 0o700) -> String {
    var t = Array((NSTemporaryDirectory() + "muya-safety-XXXXXX").utf8CString)
    let p = mkdtemp(&t).map { String(cString: $0) } ?? ""
    chmod(p, mode)
    return p
}

private func makeSocket(_ path: String, mode: mode_t) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    chmod(path, mode)
    return fd
}

func runSafetyTests() {
    test("daemon socket: owner, mode, symlink and folder checks") {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sock = dir + "/muyad.sock"
        let fd = makeSocket(sock, mode: 0o600)
        defer { close(fd) }
        check(PeerVerify.checkSocketFile(path: sock) == nil, "own 0600 socket in a 0700 folder is fine")
        check(PeerVerify.checkSocketFile(path: sock, uid: getuid() &+ 1) != nil, "another owner is refused")
        check(PeerVerify.checkSocketFile(path: dir + "/missing.sock") == nil, "missing file is left to connect()")
        chmod(sock, 0o666)
        check(PeerVerify.checkSocketFile(path: sock)?.contains("writable") == true, "world-writable socket refused")
        chmod(sock, 0o620)
        check(PeerVerify.checkSocketFile(path: sock)?.contains("writable") == true, "group-writable socket refused")
        chmod(sock, 0o600)
        chmod(dir, 0o777)
        check(PeerVerify.checkSocketFile(path: sock)?.contains("folder") == true, "world-writable folder refused")
        chmod(dir, 0o770)
        check(PeerVerify.checkSocketFile(path: sock)?.contains("folder") == true, "group-writable folder refused")
        chmod(dir, 0o700)
        let link = dir + "/link.sock"
        symlink(sock, link)
        check(PeerVerify.checkSocketFile(path: link)?.contains("symlink") == true, "symlinked socket refused")
        let plain = dir + "/plain"
        FileManager.default.createFile(atPath: plain, contents: Data())
        check(PeerVerify.checkSocketFile(path: plain)?.contains("not a socket") == true, "regular file refused")
        let realDir = dir + "/real"
        try? FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: false)
        let sock2 = realDir + "/m.sock"
        let fd2 = makeSocket(sock2, mode: 0o600)
        defer { close(fd2) }
        symlink(realDir, dir + "/dirlink")
        check(PeerVerify.checkSocketFile(path: dir + "/dirlink/m.sock")?.contains("symlink") == true, "symlinked folder refused")
    }

    test("peer uid and signature: our own process passes, the requirement string pins the team") {
        var sv: [Int32] = [0, 0]
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0, "socketpair")
        defer { close(sv[0]); close(sv[1]) }
        check(PeerVerify.checkPeerUID(fd: sv[0]) == nil, "same uid")
        check(PeerVerify.checkPeerUID(fd: sv[0], uid: getuid() &+ 1) != nil, "other uid refused")
        check(PeerVerify.requirement(team: "ABCDE12345") == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"", "requirement")
        check(PeerVerify.requirement(team: nil) == nil && PeerVerify.requirement(team: "") == nil, "no team, no requirement")
        check(PeerVerify.requirement(team: "A\" or true") == nil, "a team id cannot inject requirement text")
        // The test binary is ad-hoc signed (linker): same-team (none) peer passes; a pinned foreign team does not.
        check(PeerVerify.checkSignature(pid: getpid(), ownTeam: nil) == nil, "ad-hoc self: \(PeerVerify.checkSignature(pid: getpid(), ownTeam: nil) ?? "")")
        check(PeerVerify.checkSignature(pid: getpid(), ownTeam: "ZZZZZZZZZZ") != nil, "pinned to another team: refused")
        check(PeerVerify.checkSignature(pid: 999_999, ownTeam: nil) != nil, "no such process: refused")
        check(PeerVerify.checkPeer(fd: sv[0], policy: .strict) == nil, "strict check on a socketpair to ourselves")
        let token = PeerVerify.peerAuditToken(fd: sv[0])
        check(token != nil && token!.count == 32, "audit token of the peer is readable")
        check(token.map { PeerVerify.checkSignature(auditToken: $0, ownTeam: nil) } == .some(nil), "audit-token signature check passes for ourselves")
        check(token.map { PeerVerify.checkSignature(auditToken: $0, ownTeam: "ZZZZZZZZZZ") != nil } == true, "audit token pinned to another team: refused")
    }

    test("a world-writable socket folder stops the connection before any byte is sent") {
        let dir = tmpDir(0o777)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sock = dir + "/muyad.sock"
        let fd = makeSocket(sock, mode: 0o600)
        defer { close(fd) }
        listen(fd, 1)
        do { _ = try MuyadConnection(path: sock, build: "t", timeout: 1); check(false, "must refuse") } catch ClientError.untrusted(let why) { check(why.contains("folder"), why) } catch { check(false, "wrong error \(error)") }
    }

    test("only regular files are read: FIFO, device and missing paths are refused, and a FIFO does not block") {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fifo = dir + "/pipe"
        check(mkfifo(fifo, 0o600) == 0, "mkfifo")
        check(!FileProbe.isRegular(fifo) && !FileProbe.isRegular("/dev/null") && !FileProbe.isRegular(dir) && !FileProbe.isRegular(dir + "/nope"), "isRegular")
        check(FileProbe.probe(URL(fileURLWithPath: fifo)) == nil, "fifo probe returns at once")
        check(FileProbe.probe(URL(fileURLWithPath: "/dev/zero")) == nil, "device probe")
        check(FileProbe.readHead(URL(fileURLWithPath: fifo), limit: 10) == nil, "fifo read")
        let f = dir + "/a.txt"
        FileManager.default.createFile(atPath: f, contents: Data("hello\nworld".utf8))
        let p = FileProbe.probe(URL(fileURLWithPath: f))
        check(p?.size == 11 && p?.binary == false && p?.head.count == 11, "regular text probe")
        check(FileProbe.readHead(URL(fileURLWithPath: f), limit: 5) == Data("hello\n".utf8), "limit + 1 bytes")
        let b = dir + "/b.bin"
        FileManager.default.createFile(atPath: b, contents: Data([1, 0, 2]))
        check(FileProbe.probe(URL(fileURLWithPath: b))?.binary == true, "NUL = binary")
        symlink(f, dir + "/ln")
        check(FileProbe.isRegular(dir + "/ln"), "symlink to a regular file is fine")
    }

    test("Open with Default App asks first for anything that can run code") {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for name in ["x.command", "x.sh", "X.JAR", "x.pkg", "x.terminal", "x.workflow", "x.webloc", "x.app", "x.scpt"] {
            check(ExecutableGuard.needsConfirmation(URL(fileURLWithPath: dir + "/" + name)), "\(name) is risky")
        }
        let plain = dir + "/notes.txt"
        FileManager.default.createFile(atPath: plain, contents: Data("x".utf8))
        check(!ExecutableGuard.needsConfirmation(URL(fileURLWithPath: plain)), "plain text opens directly")
        chmod(plain, 0o755)
        check(ExecutableGuard.needsConfirmation(URL(fileURLWithPath: plain)), "executable bit asks")
        let pdf = dir + "/a.pdf"
        FileManager.default.createFile(atPath: pdf, contents: Data("x".utf8))
        check(!ExecutableGuard.needsConfirmation(URL(fileURLWithPath: pdf)), "pdf opens directly")
        // A link named like a document that points at a bundle / folder / script asks first.
        let bundle = dir + "/Foo.app"
        try? FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        symlink(bundle, dir + "/x.txt")
        check(ExecutableGuard.needsConfirmation(URL(fileURLWithPath: dir + "/x.txt")), "symlink x.txt -> Foo.app asks")
        symlink(dir, dir + "/folderlink")
        check(ExecutableGuard.needsConfirmation(URL(fileURLWithPath: dir + "/folderlink")), "symlink to a folder asks")
        check(!ExecutableGuard.needsConfirmation(URL(fileURLWithPath: dir)), "a real folder does not")
    }

    test("Paste as Path drops control characters (ESC, DEL, NUL) but keeps the escaping") {
        check(TerminalFind.escapeForShell("a\u{1B}[31mb") == "a\\[31mb".replacingOccurrences(of: "\\[", with: "[").replacingOccurrences(of: "[", with: "\\["), "ESC removed, [ escaped: \(TerminalFind.escapeForShell("a\u{1B}[31mb"))")
        check(TerminalFind.escapeForShell("x\u{7F}y\u{0}z") == "xyz", "DEL and NUL removed")
        check(TerminalFind.escapeForShell("a b") == "a\\ b", "space still escaped")
    }
}
