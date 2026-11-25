// Two bundles with this app's identifier on one Mac (the app in /Applications and an old build output, or a copy that was moved):
// launchd resolves a LaunchAgent's `BundleProgram` through LaunchServices BY BUNDLE ID, so it can land in the OTHER copy, which may
// not even contain muya-ptyd. The job then dies with `last exit code = 78: EX_CONFIG` / `job state = spawn failed`, and neither
// bootout nor a restart of the app helps (BTM keeps the old path while it says `.enabled`). This file finds the copies, decides
// whether the app must step in, and fixes it (LaunchServices re-registration; the caller then registers the agents again).
// Pure rules + the system helpers; every identifier / label is a parameter so tests never touch the real ones.

import Foundation
import CoreServices

/// One bundle that carries this app's identifier.
public struct BundleCopy: Equatable, Sendable {
    public var path: String
    public var version: String?
    /// This is the running app.
    public var isSelf: Bool
    /// launchd / LaunchServices resolve the identifier to this one.
    public var resolved: Bool
    public init(path: String, version: String?, isSelf: Bool, resolved: Bool) { self.path = path; self.version = version; self.isSelf = isSelf; self.resolved = resolved }
}

/// What the app found about the copies and the job; shown in the dialog and logged.
public struct BundleReport: Equatable, Sendable {
    public var copies: [BundleCopy]
    public var spawnFailed: Bool
    /// What the automatic fix said when it did not work (nil = not tried).
    public var failure: String?
    public init(copies: [BundleCopy], spawnFailed: Bool, failure: String? = nil) { self.copies = copies; self.spawnFailed = spawnFailed; self.failure = failure }
}

public enum BundleCopies {
    public enum Decision: Equatable, Sendable {
        /// Nothing wrong (or nothing the app should touch: the services run).
        case ok
        /// Fix it by itself: re-register this copy with LaunchServices and register the agents again.
        case reregister
        /// The fix was tried and it did not hold: show every copy and one button.
        case dialog
    }

    /// `selfPath`: this app's bundle. `copies`: every bundle path with the identifier. `resolved`: where LaunchServices sends the identifier.
    /// `spawnFailed`: the job is in `spawn failed` / EX_CONFIG. `servicesDown`: no daemon answers (a live ptyd holds sessions, so a
    /// healthy service is never re-registered just because a second copy exists).
    public static func decide(selfPath: String, copies: [String], resolved: String?, spawnFailed: Bool, servicesDown: Bool, fixTried: Bool) -> Decision {
        let me = canonical(selfPath)
        let others = copies.map(canonical).filter { $0 != me }
        let pointsElsewhere = resolved.map { canonical($0) != me } ?? false
        let broken = spawnFailed || (servicesDown && !others.isEmpty && pointsElsewhere)
        guard broken else { return .ok }
        return fixTried ? .dialog : .reregister
    }

    /// What the user sees once `decide` says `.dialog`: the dialog, or (after Later / Escape in this launch) only the status line.
    public enum Offer: Equatable, Sendable { case dialog, statusOnly }
    public static func offer(dismissed: Bool) -> Offer { dismissed ? .statusOnly : .dialog }

    public static func decide(report: BundleReport, servicesDown: Bool, fixTried: Bool) -> Decision {
        guard let me = report.copies.first(where: \.isSelf)?.path else { return .ok }
        return decide(selfPath: me, copies: report.copies.map(\.path), resolved: report.copies.first(where: \.resolved)?.path, spawnFailed: report.spawnFailed, servicesDown: servicesDown, fixTried: fixTried)
    }

    /// `launchctl print` of a job that could not start: "job state = spawn failed" and/or "last exit code = 78" (EX_CONFIG).
    public static func spawnFailed(launchctlPrint out: String) -> Bool {
        let t = out.lowercased()
        return t.contains("job state = spawn failed") || t.contains("last exit code = 78") || t.contains("ex_config")
    }

    /// `mdfind` prints one path per line.
    public static func parseMdfind(_ out: String) -> [String] {
        out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { $0.hasSuffix(".app") }
    }

    static func canonical(_ p: String) -> String { ServiceIdentity.canonical(p) }

    // MARK: system helpers

    /// Every bundle path LaunchServices and Spotlight know for the identifier (deduplicated by real path, this app first).
    public static func find(bundleID: String, selfPath: String) -> [String] {
        var paths: [String] = [selfPath]
        if let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] { paths += urls.map(\.path) }
        paths += parseMdfind(run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(bundleID)'"]).out)
        var seen = Set<String>(), out: [String] = []
        for p in paths where FileManager.default.fileExists(atPath: p) {
            let c = canonical(p)
            if seen.insert(c).inserted { out.append(p) }
        }
        return out
    }

    /// The bundle LaunchServices resolves the identifier to (what launchd's `BundleProgram` lookup uses).
    public static func resolved(bundleID: String) -> String? {
        (LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL])?.first?.path
    }

    public static func version(ofBundle path: String) -> String? {
        Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    public static func report(bundleID: String, selfPath: String, label: String, spawnFailed: Bool? = nil, failure: String? = nil) -> BundleReport {
        let paths = find(bundleID: bundleID, selfPath: selfPath)
        let res = resolved(bundleID: bundleID).map(canonical)
        let me = canonical(selfPath)
        let copies = paths.map { BundleCopy(path: $0, version: version(ofBundle: $0), isSelf: canonical($0) == me, resolved: canonical($0) == res) }
        let failed = spawnFailed ?? Self.spawnFailed(launchctlPrint: run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).out)
        return BundleReport(copies: copies, spawnFailed: failed, failure: failure)
    }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Takes the other copies out of LaunchServices and puts this one in (what `lsregister -u <other>; lsregister -f <this>` does by
    /// hand). The files stay where they are. nil = done, else what failed.
    public static func registerSelfOnly(selfPath: String, others: [String]) -> String? {
        var problems: [String] = []
        for o in others {
            let r = run(lsregister, ["-u", o]); if r.status != 0 { problems.append("lsregister -u \(o): exit \(r.status)") }
        }
        let r = run(lsregister, ["-f", selfPath]); if r.status != 0 { problems.append("lsregister -f: exit \(r.status)") }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: text

    /// The dialog text: what is wrong, every copy with its path and version, the one in use, what the button does.
    public static func dialogBody(_ r: BundleReport, home: String) -> String {
        let me = r.copies.first(where: \.isSelf)
        var lines: [String] = []
        let why = r.spawnFailed
            ? "macOS could not start the Muya background service (it failed with a configuration error). The usual cause is a second copy of Muya on this Mac: macOS looks the service up by the app's identifier and can pick the other copy, which does not contain it."
            : "More than one copy of Muya is installed and macOS may start the background service from the wrong one."
        lines.append(why)
        lines.append("Copies found:")
        for c in r.copies {
            let tags = [c.isSelf ? "this copy" : nil, c.resolved ? "macOS uses it for the service" : nil].compactMap { $0 }.joined(separator: ", ")
            lines.append("• \(KeptSession.abbreviate(c.path, home: home))\(c.version.map { " (\($0))" } ?? "")\(tags.isEmpty ? "" : " — \(tags)")")
        }
        if let f = r.failure { lines.append("Muya tried to fix this by itself and could not (\(f)).") }
        lines.append("“Use this copy's service” registers \(me.map { KeptSession.abbreviate($0.path, home: home) } ?? "this copy") with macOS, removes the other copies from macOS's list (the files stay where they are) and starts the service from here. No session is running, so nothing is lost.")
        return lines.joined(separator: "\n")
    }
}
