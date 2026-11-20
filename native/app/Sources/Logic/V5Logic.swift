// Muya 5: the app that replaces classic in place (docs/prd-muya-v5-replace.md). The decisions here are pure so they are
// unit-tested without a Mac session: the start-up re-launch, what to clean up of the old apps, the preferences of the
// old `.native` id, and the words of "Return to Muya Classic".

import Foundation

/// The name the app shows for itself: the bundle's own (`Muya` for the release app, `Muya Native` for the beta / bridge
/// app and dev builds), so every menu and label follows the bundle instead of repeating a hard-coded name.
public enum AppInfo {
    public static func displayName(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let n = info?[key] as? String, !n.isEmpty { return n }
        }
        return "Muya"
    }
    public static var name: String { displayName() }
}

/// After the classic updater installed Muya 5 it starts the new app itself, straight from its own process, and exits.
/// The new app is then not started by LaunchServices: it is an orphan that the system still attributes to classic's pid,
/// and muyad refuses exactly that (muya-peer `refuse_reason`). So the app starts itself again through `open`, which makes
/// it responsible for itself.
public enum StartupRelaunch {
    public enum Action: Equatable { case proceed, waitForParent, relaunch }

    public struct Facts: Equatable {
        public var pid: Int32, ppid: Int32
        /// The parent's process name (`p_comm`), when it is alive.
        public var parentName: String?
        /// The kernel's "responsible process" of this process.
        public var responsible: Int32?
        /// This process was already started by our own re-launch (never loop).
        public var alreadyRelaunched: Bool
        /// An installed release app (not a dev build run from a build folder).
        public var installedRelease: Bool
        public init(pid: Int32, ppid: Int32, parentName: String?, responsible: Int32?, alreadyRelaunched: Bool, installedRelease: Bool) {
            self.pid = pid; self.ppid = ppid; self.parentName = parentName; self.responsible = responsible
            self.alreadyRelaunched = alreadyRelaunched; self.installedRelease = installedRelease
        }
    }

    /// The executable name of classic Muya; the only parent that hands over this way.
    public static let classicExecutable = "muya"
    public static let flag = "--relaunched-by-launchservices"

    public static func decide(_ f: Facts) -> Action {
        guard f.installedRelease, !f.alreadyRelaunched else { return .proceed }
        if f.responsible == f.pid { return .proceed }            // LaunchServices (Finder, open, login item): responsible for itself
        if f.ppid > 1 {                                          // a live parent
            // A shell, Terminal or IDE is a normal run that muyad accepts. Classic's updater is about to exit: wait for it.
            return f.parentName == classicExecutable ? .waitForParent : .proceed
        }
        return .relaunch                                         // orphan attributed to someone else: what muyad refuses
    }

    /// `open` arguments for the re-launch. The test environment's HOME/PATH are passed on only when the test harness asks.
    public static func openArguments(bundlePath: String, passEnv: [String: String]?, args: [String]) -> [String] {
        var a = ["-n"]
        for (k, v) in (passEnv ?? [:]).sorted(by: { $0.key < $1.key }) { a += ["--env", "\(k)=\(v)"] }
        a.append(bundlePath)
        a += ["--args", flag] + args
        return a
    }
}

/// `launchctl print` text -> what we need from it.
public enum LaunchctlPrint {
    /// `parent bundle identifier = com.staunch.muya.native`: whose bundle the job belongs to.
    public static func parentBundleID(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("parent bundle identifier = ") { return String(t.dropFirst("parent bundle identifier = ".count)) }
        }
        return nil
    }
}

/// Which launchd jobs of the old apps must go before this app registers its own.
public enum LegacyJobs {
    public static let schedulerLabel = "com.staunch.muya.scheduler"
    public static let schedulerPlist = "com.staunch.muya.scheduler.plist"
    public static let serviceLabels = ["com.staunch.muya.muyad", "com.staunch.muya.ptyd"]

    /// Classic's scheduler job runs `Contents/MacOS/muya --scheduler`. Muya 5 does not ship that plist and has no such
    /// executable: a loaded job would fail and be retried for ever, so it is booted out.
    public static func shouldBootoutScheduler(loaded: Bool, bundleShipsPlist: Bool) -> Bool { loaded && !bundleShipsPlist }

    /// A service job that belongs to another bundle id (the `.native` beta, a leftover): it must be booted out before this
    /// app registers the same label.
    public static func foreignServiceLabels(parents: [String: String?], ourBundleID: String) -> [String] {
        serviceLabels.filter { l in
            guard let p = parents[l] else { return false }     // not loaded
            return p != ourBundleID                            // loaded: ours (same id) or foreign (other / unknown id)
        }
    }

    /// After a managed hand-over (`--switched-from=update`) the old daemon boots its jobs out within seconds; wait for that
    /// instead of fighting it. Otherwise (a manual replace) the stale-service dialog decides, never a silent kill.
    public enum Plan: Equatable { case nothing, waitThenRegister, leaveToRestartDialog }
    public static func plan(foreign: [String], switchLaunch: Bool) -> Plan {
        if foreign.isEmpty { return .nothing }
        return switchLaunch ? .waitThenRegister : .leaveToRestartDialog
    }
}

/// The `.native` beta id kept its own preferences domain. Native stores almost nothing there, but a key that exists is
/// copied (never over a key the new domain already has) so a beta user does not lose a window position or a switch.
public enum LegacyDomain {
    public static let doneKey = "muya.legacyDomainMigrated"

    /// `com.staunch.muya` -> `com.staunch.muya.native`; nil for an id that already is the legacy one.
    public static func legacyName(for bundleID: String) -> String? { bundleID.hasSuffix(".native") ? nil : bundleID + ".native" }

    public static func keysToCopy(legacy: [String: Any], current: [String: Any]) -> [String: Any] {
        legacy.filter { current[$0.key] == nil && $0.key != doneKey }
    }

    /// Reads `<own>.native` and writes the missing keys through `writer` (the standard defaults in the app). Runs once per own
    /// domain (marker key). Returns how many keys were copied.
    @discardableResult
    public static func migrate(ownDomain: String, writer: UserDefaults, reader: UserDefaults = .standard) -> Int {
        guard let legacyName = legacyName(for: ownDomain) else { return 0 }
        let current = reader.persistentDomain(forName: ownDomain) ?? [:]
        if current[doneKey] as? Bool == true { return 0 }
        let add = keysToCopy(legacy: reader.persistentDomain(forName: legacyName) ?? [:], current: current)
        for (k, v) in add { writer.set(v, forKey: k) }
        writer.set(true, forKey: doneKey)
        return add.count
    }
}

/// The newest release the app knows about (set by the automatic check and by "Check for Updates"); the footer notice reads it.
public enum UpdateCenter {
    nonisolated(unsafe) public static var available: String?
    public static let changed = Notification.Name("muya.update-available-changed")
    public static func set(_ v: String?) {
        guard available != v else { return }
        available = v
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// The words of Settings > Updates and of the menu's "Check for Updates…".
public enum UpdateStatusText {
    public static let checkTitle = "Check for Updates"
    public static let menuTitle = "Check for Updates…"
    public static func installTitle(legacy: Bool) -> String { legacy ? "Move now" : "Install & Restart" }

    /// Version, then what is known: nothing yet / up to date / newer one available / no feed published yet.
    public static func line(installed: String, available: String?, upToDate: Bool, none: Bool = false) -> String {
        let v = installed.isEmpty ? "Version unknown" : "Version \(installed)"
        if let available { return "\(v) · \(available) is available" }
        if none { return "\(v) · no update published yet" }
        return upToDate ? "\(v) · up to date" : v
    }

    /// A toast for the menu item: (title, message).
    public static func toast(name: String, installed: String, available: String?, error: String?) -> (String, String) {
        if let error { return ("Could not check for updates", error) }
        if let available { return ("\(name) \(available) is available", "Open Settings > Updates and choose Install & Restart.") }
        return ("\(name) is up to date", installed.isEmpty ? "" : "Version \(installed) is the newest.")
    }
}

public enum ReturnWording {
    public static let version = "4.1.22"
    public static let rowTitle = "Return to Muya Classic (\(version))"
    public static let rowHelper = "Replaces this app with Muya Classic \(version) in the same place. Your workspaces and schedules come with you, and macOS permissions stay."
    public static let menuTitle = "Return to Muya Classic (\(version))…"
    public static func confirmTitle(_ v: String = version) -> String { "Return to Muya Classic \(v)?" }

    public static func confirmMessage(live: Int, agents: Int, version v: String = version) -> String {
        var s = "Muya Classic \(v) replaces this app in the same place. This app goes to the Trash, so you can put it back. Your workspaces, schedules, servers and saved sessions come with you, and macOS permissions stay."
        if live > 0 {
            let n = live == 1 ? "1 session is" : "\(live) sessions are"
            s += "\n\n\(n) running and will be closed."
            if agents > 0 { s += agents == 1 ? " 1 Claude conversation can be resumed in Muya Classic." : " \(agents) Claude conversations can be resumed in Muya Classic." }
        }
        return s
    }

    /// The confirm dialog of the move: the old background service is stopped, so running sessions end.
    public static let moveConfirmTitle = "Move to Muya 5?"
    public static func moveConfirmMessage(live: Int, agents: Int) -> String {
        var s = "Muya Native becomes Muya: the new app takes the name Muya in the same folder and the old one goes to the Trash. Your workspaces, schedules, servers and saved sessions come with you, and macOS permissions stay."
        if live > 0 {
            let n = live == 1 ? "1 session is" : "\(live) sessions are"
            s += "\n\n\(n) running and will be closed."
            if agents > 0 { s += agents == 1 ? " 1 Claude conversation can be resumed in Muya." : " \(agents) Claude conversations can be resumed in Muya." }
        }
        return s
    }

    /// Settings row for the update of a `.native` (beta / bridge) app: the app is becoming Muya.
    public static let moveTitle = "Move to Muya 5"
    public static let moveHelper = "Muya Native becomes Muya: the new app takes the name Muya in the same folder and keeps your data."
}
