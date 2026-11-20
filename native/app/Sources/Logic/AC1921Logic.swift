// AC19 / AC21 logic without any UI: how a failed connection is classified (needs approval / version skew / just
// unreachable), what the onboarding and restart screens say, the resume plan the daemon keeps across a restart, and the
// state machine of "Restart service". Pure functions and values so the unit tests can drive them.

import Foundation

/// What a failed connection to muyad means for the user.
public enum ServiceProblem: Equatable, Sendable {
    /// ptyd/muyad is not approved in Login Items (AC21): muyad answers `not_approved`, or its socket does not exist
    /// while the system says the login item waits for approval.
    case needsApproval
    /// The app and the running daemons speak different protocol majors (AC19).
    case versionSkew(Incompat)
    /// The protocol matches but the running services belong to another copy of the app (moved to the Trash, or replaced in place):
    /// they lack this copy's fixes. The same restart dialog offers to start this copy's own.
    case staleService(StaleService)
    /// Anything else: the normal "not connected, retrying" banner.
    case unreachable(String)

    public static func classify(_ error: Error, loginItemWaitsForApproval: Bool = false) -> ServiceProblem {
        guard let e = error as? ClientError else { return .unreachable("\(error)") }
        switch e {
        case let .incompatible(info): return .versionSkew(info)
        case let .server(code, message):
            if code == "not_approved" { return .needsApproval }
            if code == "incompatible" { return .versionSkew(skewWithoutDetail(message)) }
            _ = message; return .unreachable("\(e)")
        case .socket: return loginItemWaitsForApproval ? .needsApproval : .unreachable("\(e)")
        default: return .unreachable("\(e)")
        }
    }

    /// An `incompatible` error from a daemon that predates the detail: the dialog still works, without versions or sessions.
    static func skewWithoutDetail(_ message: String) -> Incompat {
        let unknown = ProtoVersion(major: 0, minor: 0, build: "")
        return Incompat(daemon: unknown, client: ProtoVersion(major: protoMajor, minor: protoMinor, build: ""), required: unknown, speak: unknown, sessions: [])
    }
}

/// What is wrong with the running background services and what a restart would end.
public struct StaleService: Equatable, Sendable {
    public var verdict: ServiceIdentity.Verdict
    /// "muyad" / "muya-ptyd": which program the verdict is about.
    public var program: String
    public var sessions: [LiveSession]
    public init(verdict: ServiceIdentity.Verdict, program: String, sessions: [LiveSession]) { self.verdict = verdict; self.program = program; self.sessions = sessions }
}

public enum ServiceCopy {
    public static let starting = "Starting the background service…"
    /// The last-resort text: what is wrong and the one thing to do. Never "connection closed".
    public static func cannotStart(detail: String?, jobLoaded: Bool?) -> String {
        let why = jobLoaded == true ? "macOS lists the background service but it does not answer." : "macOS did not start the background service."
        return why + " Open System Settings › General › Login Items & Extensions, make sure Muya is switched on under “Allow in the Background”, then press Retry. If it still fails, quit Muya, sign out of macOS and in again."
            + (detail.map { " (macOS said: \($0))" } ?? "")
    }
    /// What a page shows when it asked the service for something and there is no connection.
    public static func notConnected(status: String?) -> String {
        if let s = status, s.contains("Retry") { return s }
        return (status ?? "The background service is not running yet. Muya is starting it.") + " Press Retry in a moment."
    }
    public static let staleTitle = "Restart the Muya background service?"
    /// `home` shortens the path the way the app does elsewhere.
    public static func staleBody(_ s: StaleService, kept: Int, home: String) -> String {
        let why: String
        switch s.verdict {
        case let .otherCopy(running): why = "The background service (\(s.program)) that is running belongs to another copy of Muya (\(KeptSession.abbreviate(running, home: home))), so the latest fixes in this copy are not active yet."
        case let .differentBuild(daemon, app): why = "The background service (\(s.program)) is \(daemon.map { "from release \($0)" } ?? "from an older release"), this copy of Muya is \(app), so the latest fixes are not active yet."
        case .replaced: why = "The background service (\(s.program)) was started before this copy of Muya was installed, so the latest fixes are not active yet."
        default: why = "The background service is not the one inside this copy of Muya."
        }
        let tail = kept == 0 ? "No sessions are open, so nothing is lost." :
            "Restarting ends the \(kept) running session\(kept == 1 ? "" : "s") below and opens each again in the same folder, resuming the Claude conversation where there is one; anything running in a plain shell stops. “Later” keeps everything running as it is."
        return why + " " + tail
    }

    public static let onboardingTitle = "Allow the Muya background service"
    public static let onboardingWhat = "Muya runs your terminals in a small background service. It keeps your sessions alive when you quit or update the app, and it is what lets schedules and permission prompts keep working while the window is closed."
    public static let onboardingWhy = "macOS asks you to approve background services once. Until you do, Muya cannot start any session."
    public static let onboardingSteps = "Open System Settings > General > Login Items, and under “Allow in the Background” switch on Muya. This screen continues by itself as soon as it is on."
    public static let onboardingButton = "Open Login Items"
    public static let waiting = "Waiting for approval…"
    public static let approved = "Approved. Starting…"

    public static let restartTitle = "Restart the Muya background service?"
    public static func restartBody(daemon: ProtoVersion, app: ProtoVersion, kept: Int) -> String {
        let versions = daemon.major == 0 ? "The app and the background service run different versions."
            : "The app speaks protocol \(app.major).\(app.minor) but the background service still runs \(daemon.major).\(daemon.minor)."
        let tail = kept == 0 ? "No sessions are open, so nothing is lost." :
            "Restarting ends the \(kept) running session\(kept == 1 ? "" : "s") below and opens each again in the same folder, resuming the Claude conversation where there is one. “Later” keeps everything running as it is."
        return versions + " " + tail
    }
    public static let restartButton = "Restart service"
    public static let laterButton = "Later"
    public static let compatNote = "Muya and its background service run different versions. Choose Restart Background Service in the Muya menu when it suits you."
}

/// One row of the “sessions that will be kept” list.
public struct KeptSession: Equatable, Sendable {
    public var title: String
    public var detail: String
    public static func rows(_ sessions: [LiveSession], home: String) -> [KeptSession] {
        sessions.filter { $0.exited == nil }.map { s in
            let folder = s.cwd.isEmpty ? "~" : abbreviate(s.cwd, home: home)
            let name = s.cwd.isEmpty || s.cwd == home ? "Shell" : (s.cwd as NSString).lastPathComponent
            return KeptSession(title: name, detail: s.claudeSessionId.map { "\(folder) · resumes Claude conversation \(String($0.prefix(8)))" } ?? folder)
        }
    }
    static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return !home.isEmpty && path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// What the app does with one entry of the resume plan.
public struct ResumeStep: Equatable, Sendable {
    public var cwd: String
    public var name: String
    /// Typed into the new shell (`claude --resume …`), nil for a plain shell.
    public var command: String?

    /// `exists` tells whether a folder is still there (a deleted project falls back to the home folder).
    public static func steps(_ plan: [LiveSession], home: String, exists: (String) -> Bool) -> [ResumeStep] {
        plan.filter { $0.exited == nil }.map { s in
            let cwd = (!s.cwd.isEmpty && exists(s.cwd)) ? s.cwd : home
            let base = cwd == home ? "Shell" : (cwd as NSString).lastPathComponent
            let cmd = s.claudeSessionId.flatMap(SessionsLogic.resumeCommand)
            return ResumeStep(cwd: cwd, name: cmd == nil ? base : "↻ \(base)", command: cmd)
        }
    }

    /// `upgrade.resume_plan` result -> sessions; `pending == false` or garbage -> nothing to do.
    public static func parsePlan(_ value: Any) -> [LiveSession]? {
        guard let d = value as? [String: Any], (d["pending"] as? Bool) == true, let arr = d["sessions"] as? [Any] else { return nil }
        let list = arr.compactMap { try? Control.live($0) }
        return list.count == arr.count ? list : nil
    }
}

/// Progress of “Restart service” as the dialog shows it.
public enum RestartPhase: Equatable, Sendable {
    case idle
    case restarting
    case resuming(done: Int, total: Int)
    case finished(resumed: Int)
    case failed(String)

    public var text: String {
        switch self {
        case .idle: return ""
        case .restarting: return "Restarting the service…"
        case let .resuming(done, total): return "Opening your sessions again (\(done) of \(total))…"
        case let .finished(n): return n == 0 ? "Done. The service runs the new version." : "Done. \(n) session\(n == 1 ? "" : "s") opened again."
        case let .failed(m): return m
        }
    }
    public var busy: Bool { if case .restarting = self { return true }; if case .resuming = self { return true }; return false }
}

/// How the app reconnects: the pace, and what a failure means in each state.
public struct ReconnectPolicy: Equatable, Sendable {
    /// Seconds until the next try. Onboarding polls slowly (every 2 s) and a restart quickly (every 0.5 s); a plain
    /// outage keeps the old 1 s.
    public static func delay(onboarding: Bool, restarting: Bool) -> TimeInterval { restarting ? 0.5 : onboarding ? 2 : 1 }
    /// A restart waits for launchd to bring the daemons back; it gives up after this long.
    public static let restartTimeout: TimeInterval = 60
}
