// Is the thing on the other end of muyad.sock really OUR daemon? Checked before the hello is sent, because the hello is followed by
// keystrokes, pastes and (later) vault / SSH traffic. Any process of the same user could unlink the socket and bind its own.
//
//   1. the socket and its directory belong to this user, are not group/world writable and are not symlinks (lstat);
//   2. the kernel says the peer's uid is ours (getpeereid);
//   3. the peer's code signature matches ours: with a Team ID, `anchor apple generic and certificate leaf[subject.OU] = "<team>"`
//      (the team is read from this app's own signature at runtime); an ad-hoc / dev build has no team, so the peer must be validly
//      signed and carry no team either (a dev muyad is ad-hoc too).

import Darwin
import Foundation
import Security

public enum PeerVerify {
    public enum Policy: Sendable {
        /// Everything above (the app).
        case strict
        /// Only the uid check: for unit tests that talk to an in-process fake daemon in /tmp (a symlinked, sticky folder).
        case sameUser
    }

    // MARK: 1. the socket file

    /// nil when the socket file and its directory are trustworthy, else why not. `uid` is injectable for tests.
    public static func checkSocketFile(path: String, uid: uid_t = getuid()) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil } // no file: connect() reports it with its own error
        if (st.st_mode & S_IFMT) == S_IFLNK { return "the socket \(base(path)) is a symlink" }
        if (st.st_mode & S_IFMT) != S_IFSOCK { return "\(base(path)) is not a socket" }
        if st.st_uid != uid { return "the socket \(base(path)) belongs to another user (uid \(st.st_uid))" }
        if st.st_mode & 0o022 != 0 { return "the socket \(base(path)) is writable by other users" }
        let dir = (path as NSString).deletingLastPathComponent
        var ds = stat()
        guard lstat(dir.isEmpty ? "." : dir, &ds) == 0 else { return "its folder cannot be inspected" }
        if (ds.st_mode & S_IFMT) == S_IFLNK { return "the socket folder is a symlink" }
        if (ds.st_mode & S_IFMT) != S_IFDIR { return "the socket folder is not a folder" }
        if ds.st_uid != uid { return "the socket folder belongs to another user (uid \(ds.st_uid))" }
        if ds.st_mode & 0o022 != 0 { return "the socket folder is writable by other users" }
        return nil
    }

    private static func base(_ p: String) -> String { (p as NSString).lastPathComponent }

    // MARK: 2. the peer's uid

    public static func checkPeerUID(fd: Int32, uid: uid_t = getuid()) -> String? {
        var u: uid_t = 0, g: gid_t = 0
        guard getpeereid(fd, &u, &g) == 0 else { return "the service's user could not be read" }
        return u == uid ? nil : "the service runs as another user (uid \(u))"
    }

    // MARK: 3. the peer's code signature

    /// The requirement a peer must satisfy for the Team ID `team` (nil / empty = no team to pin).
    public static func requirement(team: String?) -> String? {
        guard let team, !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// This app's own Team ID (nil for an ad-hoc / unsigned build). Read once.
    public static let ownTeamID: String? = teamID(of: selfStatic())

    private static func selfStatic() -> SecStaticCode? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var st: SecStaticCode?
        return SecCodeCopyStaticCode(me, [], &st) == errSecSuccess ? st : nil
    }

    private static func teamID(of code: SecStaticCode?) -> String? {
        guard let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        let t = d[kSecCodeInfoTeamIdentifier as String] as? String
        return (t?.isEmpty ?? true) ? nil : t
    }

    /// nil when process `pid` is signed by the same team as this app (or, for an ad-hoc app, is validly signed without a team).
    public static func checkSignature(pid: Int32, ownTeam: String? = ownTeamID) -> String? {
        checkSignature(attributes: [kSecGuestAttributePid as String: Int(pid)], ownTeam: ownTeam)
    }

    /// Same check on the peer's AUDIT TOKEN: it names one specific process incarnation, so a pid that is
    /// reused between the socket check and the signature check cannot be mistaken for the daemon.
    public static func checkSignature(auditToken: Data, ownTeam: String? = ownTeamID) -> String? {
        checkSignature(attributes: [kSecGuestAttributeAudit as String: auditToken], ownTeam: ownTeam)
    }

    /// The audit token of the process at the other end of a connected Unix socket (LOCAL_PEERTOKEN).
    public static func peerAuditToken(fd: Int32) -> Data? {
        var token = Data(count: 32)
        var len = socklen_t(32)
        let rc = token.withUnsafeMutableBytes { getsockopt(fd, 0 /* SOL_LOCAL */, 0x006 /* LOCAL_PEERTOKEN */, $0.baseAddress, &len) }
        return rc == 0 && len == 32 ? token : nil
    }

    private static func checkSignature(attributes: [String: Any], ownTeam: String?) -> String? {
        var guest: SecCode?
        let attrs = attributes as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &guest) == errSecSuccess, let guest else { return "the service's code signature could not be read" }
        if let req = requirement(team: ownTeam) {
            var r: SecRequirement?
            guard SecRequirementCreateWithString(req as CFString, [], &r) == errSecSuccess, let r else { return "internal: bad requirement" }
            return SecCodeCheckValidity(guest, [], r) == errSecSuccess ? nil : "the service is not signed by the same developer as this app"
        }
        // Dev / ad-hoc: no team to pin. The peer must still be validly signed and must not claim a team (a foreign Developer ID build).
        guard SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return "the service's code signature is not valid" }
        var st: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &st) == errSecSuccess else { return "the service's code signature could not be read" }
        if teamID(of: st) != nil { return "the service is signed by a developer team, this build is not" }
        return nil
    }

    /// All peer checks after connect().
    public static func checkPeer(fd: Int32, policy: Policy) -> String? {
        if let p = checkPeerUID(fd: fd) { return p }
        guard policy == .strict else { return nil }
        guard let token = peerAuditToken(fd: fd) else { return "the service's process could not be identified" }
        return checkSignature(auditToken: token)
    }
}
