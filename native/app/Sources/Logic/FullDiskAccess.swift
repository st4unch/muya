// Optional Full Disk Access step (docs/prd-full-disk-access.md): how the status is read, when the first-run step is
// offered, and the wording. No UI here; the screen is Sources/App/FullDiskAccessUI.swift.
//
// Detection never prompts. macOS has no API for "is Full Disk Access on". The common non-prompting probe is to open
// a file that only Full Disk Access can read: the user's own TCC database. Without the grant the open fails with
// EPERM/EACCES and macOS shows no dialog (Full Disk Access is never requested from inside an app, only switched on by
// hand in System Settings).

import Darwin
import Foundation

public enum FDAStatus: Equatable, Sendable {
    case granted, notGranted
    /// The probe could not decide (the file is missing, an odd error): never shown as a red "Not granted".
    case unknown

    public var label: String {
        switch self { case .granted: "Granted"; case .notGranted: "Not granted"; case .unknown: "Unknown" }
    }
}

public enum FullDiskAccess {
    /// The Privacy > Full Disk Access pane.
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    /// UIPrefs key: the user pressed "Not now" on the first-run step. Settings keeps the row either way.
    public static let dismissedKey = "fdaStepDismissed"

    /// The probe file, under the account's real home (the passwd entry, never $HOME: a fake HOME must not change the answer).
    public static func probePath(home: String) -> String { home + "/Library/Application Support/com.apple.TCC/TCC.db" }

    /// The real home directory of this account, or nil.
    public static func realHome() -> String? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }

    /// nil = the open worked; otherwise the errno.
    public typealias Opener = @Sendable (String) -> Int32?

    public static let systemOpener: Opener = { path in
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return nil }
        return errno
    }

    /// Maps the probe's result: opened = granted; EPERM/EACCES = not granted; anything else (no such file, ...) = unknown.
    public static func classify(openErrno: Int32?) -> FDAStatus {
        guard let e = openErrno else { return .granted }
        return e == EPERM || e == EACCES ? .notGranted : .unknown
    }

    public static func status(home: String? = realHome(), opener: Opener = systemOpener) -> FDAStatus {
        guard let home else { return .unknown }
        return classify(openErrno: opener(probePath(home: home)))
    }

    /// The first-run step: only when access is really missing, the user has not said "Not now", nothing else is on
    /// screen and this is a real install (a dev stack with a fake HOME never asks).
    public static func shouldOffer(status: FDAStatus, dismissed: Bool, otherScreenUp: Bool, realInstall: Bool) -> Bool {
        realInstall && !dismissed && !otherScreenUp && status == .notGranted
    }

    // MARK: Wording (plain English)

    public static let title = "Full Disk Access"
    public static let stepTitle = "Stop the repeated folder prompts?"
    public static let rowHelper = "Optional. Stops macOS asking again and again before sessions may open Documents, Desktop or Downloads. It also lets every session, Claude included, read all your files."
    public static let helpersHelper = "If Full Disk Access still says Not granted after you added Muya, add Muya's two helper programs to the same list."
    public static let stepWhat = "macOS asks again for each folder (Documents, Desktop, Downloads, …) whenever a Muya session first touches it. Full Disk Access is a one-time switch that ends those prompts."
    public static let stepRisk = "It is optional and off by default. With it on, every session (Claude included) can read all of your files, not just the folder it runs in."
    public static let stepHow = "Open System Settings > Privacy & Security > Full Disk Access, press + and add Muya (or drag it in), then switch it on. If this still says Not granted afterwards, also add the two helper programs; “Show helper apps” selects them in Finder."
    public static let openButton = "Open Settings"
    public static let revealButton = "Show helper apps"
    public static let notNowButton = "Not now"
    public static let doneButton = "Done"

    /// The helper programs the grant may have to list as well: they run the sessions, so macOS can attribute file access to them.
    public static let helperNames = ["muya-ptyd", "muyad"]
}
