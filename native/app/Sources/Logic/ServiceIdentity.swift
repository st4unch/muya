// Which copy of Muya do the running background services belong to? Two copies of the app (an old one moved to the Trash, a new one
// in /Applications) share the bundle id and the LaunchAgent labels, so launchd keeps the OLD muyad / muya-ptyd alive and the new app
// happily talks to them: same protocol, none of the new fixes (the MCP broker flag, the embedded Info.plist, ...). The protocol
// handshake cannot see that; the process list can. The app asks the kernel who is on the other end of its socket and where that
// program lives, and compares with the muyad / muya-ptyd inside its own bundle.

import Foundation
import Darwin

public enum ServiceIdentity {
    public enum Verdict: Equatable, Sendable {
        /// The running program is the one inside this app's bundle, not replaced since it started.
        case current
        /// The running program lives somewhere else (another copy of the app, or the old copy that was moved to the Trash).
        case otherCopy(running: String)
        /// Same path, but the file on disk is newer than the process: the app was updated in place and the service was not restarted.
        case replaced(path: String)
        /// The program path looked fine (or could not be read) but the service announced another product version in its hello:
        /// a daemon from an older release (`daemon` nil = it announced no version at all, i.e. it predates the stamp).
        case differentBuild(daemon: String?, app: String)
        /// Nothing to compare (not a bundled app, or the process is gone).
        case unknown
    }

    /// Pure rule. `running`: path of the running program; `startedAt`: when that process started; `expected` / `expectedModified`:
    /// the program in this app's bundle. A 2 s tolerance covers a bundle written just before the service launched.
    public static func verdict(running: String?, startedAt: Date?, expected: String?, expectedModified: Date?) -> Verdict {
        guard let running, !running.isEmpty, let expected, !expected.isEmpty else { return .unknown }
        if canonical(running) != canonical(expected) { return .otherCopy(running: running) }
        if let s = startedAt, let m = expectedModified, m.timeIntervalSince(s) > 2 { return .replaced(path: running) }
        return .current
    }

    static func canonical(_ p: String) -> String {
        realpath(p, nil).map { let s = String(cString: $0); free($0); return s } ?? (p as NSString).standardizingPath
    }

    /// Where the kernel says process `pid` runs from.
    public static func programPath(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    public static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    public static func parentPID(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_ppid > 1 else { return nil }
        return Int32(info.pbi_ppid)
    }

    /// The pid at the other end of a connected Unix socket (LOCAL_PEERPID).
    public static func peerPID(fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, 0 /* SOL_LOCAL */, 0x002 /* LOCAL_PEERPID */, &pid, &len) == 0 && pid > 0 ? pid : nil
    }

    /// Verdict for process `pid` against the program `expected`.
    public static func verdict(pid: Int32, expected: String?) -> Verdict {
        guard let expected, FileManager.default.fileExists(atPath: expected) else { return .unknown }
        let mod = (try? FileManager.default.attributesOfItem(atPath: expected))?[.modificationDate] as? Date
        return verdict(running: programPath(of: pid), startedAt: startTime(of: pid), expected: expected, expectedModified: mod)
    }

    /// The muyad / muya-ptyd inside the running app bundle (nil for a bare binary: a dev build has nothing to compare with).
    public static func bundled(_ name: String, bundleURL: URL = Bundle.main.bundleURL) -> String? {
        let p = bundleURL.appendingPathComponent("Contents/MacOS/\(name)").path
        return bundleURL.pathExtension == "app" ? p : nil
    }

    /// What the daemon's hello says about its release. `serverBuild` is "<crate>+<product>" from a stamped daemon, a bare crate
    /// version from one that predates the stamp. `product`: this app's own release (nil = not a bundled app, nothing to compare).
    public static func buildVerdict(serverBuild: String, product: String?) -> Verdict {
        guard let product, !product.isEmpty, product != "0.0.1" else { return .unknown }
        if let plus = serverBuild.lastIndex(of: "+") {
            let theirs = String(serverBuild[serverBuild.index(after: plus)...])
            return theirs == product ? .current : .differentBuild(daemon: theirs, app: product)
        }
        return .differentBuild(daemon: nil, app: product)
    }

    /// This app's release (CFBundleShortVersionString) when it runs from a .app bundle.
    public static func bundledProduct(bundle: Bundle = .main) -> String? {
        bundle.bundleURL.pathExtension == "app" ? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String : nil
    }

    /// The service that is worse off of the two, for one dialog: otherCopy beats replaced beats current.
    public static func worst(_ a: Verdict, _ b: Verdict) -> Verdict {
        func rank(_ v: Verdict) -> Int { switch v { case .otherCopy: 4; case .differentBuild: 3; case .replaced: 2; case .current: 1; case .unknown: 0 } }
        return rank(a) >= rank(b) ? a : b
    }
}
