// When the background services are not running although macOS says the login items are fine (the jobs were booted out, the
// app was moved or replaced, a crash loop gave up): what the app does about it. Pure rules plus the one file-system helper
// (stale sockets), so the unit tests can drive them without launchd.

import Foundation
import Darwin

public enum ServiceRecovery {
    public enum Action: Equatable, Sendable {
        /// Keep retrying the connection; launchd may just be slow.
        case wait
        /// Clear dead sockets and register this copy's agents again.
        case restart
        /// Two attempts did not bring the service up: say precisely what is wrong.
        case giveUp(String)
    }

    /// Failed connects in a row before the app steps in when launchd still lists the job (it normally answers within a second).
    public static let graceFailures = 4
    /// The same, when launchd does not list the job at all: nothing will ever start it, no point waiting.
    public static let notLoadedFailures = 2
    /// Failed connects after an attempt before the next one (or giving up): macOS needs a few seconds to start a job.
    public static let settleFailures = 8
    public static let maxAttempts = 2

    /// `isSocketError`: the connect failed at the socket (refused / no such file), not in the handshake.
    /// `approvalPending`: Login Items waits for the user (the onboarding card handles that).
    /// `jobLoaded`: does launchd list the job (nil = cannot tell).
    /// `failures`: connect failures since the last attempt; `attempts`: restarts tried so far.
    public static func plan(isSocketError: Bool, approvalPending: Bool, jobLoaded: Bool?, failures: Int, attempts: Int, detail: String?) -> Action {
        guard isSocketError, !approvalPending else { return .wait }
        if attempts == 0 {
            let need = jobLoaded == false ? notLoadedFailures : graceFailures
            return failures >= need ? .restart : .wait
        }
        guard failures >= settleFailures else { return .wait }
        return attempts < maxAttempts ? .restart : .giveUp(ServiceCopy.cannotStart(detail: detail, jobLoaded: jobLoaded))
    }

    /// The agents whose socket answers nothing: only those are registered again (a live ptyd holds the user's sessions).
    public static func deadAgents(muyadSocket: String, ptydSocket: String) -> [String] {
        var out: [String] = []
        if StaleSocket.state(ptydSocket) != .alive { out.append("com.staunch.muya.ptyd.plist") }
        if StaleSocket.state(muyadSocket) != .alive { out.append("com.staunch.muya.muyad.plist") }
        return out
    }
}

public enum StaleSocket {
    public enum State: Equatable, Sendable { case alive, stale, missing }

    /// alive: something accepts connections. stale: the file exists but nobody listens (left behind by a booted-out job).
    public static func state(_ path: String) -> State {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return .missing }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .alive } // cannot tell: never call it stale
        defer { close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return .alive }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) } }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if r == 0 { return .alive }
        return errno == ECONNREFUSED ? .stale : .alive
    }

    /// Removes the socket file when (and only when) the kernel says nobody listens on it. True = removed.
    @discardableResult
    public static func sweep(_ path: String) -> Bool {
        guard state(path) == .stale else { return false }
        return unlink(path) == 0
    }
}
