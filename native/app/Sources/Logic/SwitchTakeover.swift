import Foundation

/// An update must look the way Muya 4's did: the app you are using closes and comes back as the new version. One icon,
/// one window, nothing to tidy up afterwards.
///
/// Muya 5 installs the new build in place and then starts it, so for a few seconds two copies are alive: the one that
/// asked for the update (it is still showing the progress) and the new one proving it can run. 5.0.6 let the new copy
/// come up as an ordinary app, so a second Muya appeared beside the first — two Dock tiles, two windows, and the user
/// watching one of them vanish.
///
/// The new copy therefore starts as an accessory: no Dock tile, no window, nothing in the app switcher. It writes its
/// health handshake from there (the daemon's rollback still works), and only once the old copy has quit does it become
/// the visible Muya. The wait has a limit so a copy that cannot quit — an unsaved-changes dialog, say — can never
/// leave the user without a window.
public enum SwitchTakeover {
    /// `--switched-from=…`: this launch is the second half of an update or a switch.
    public static func startsHidden(args: [String]) -> Bool { LaunchHandshake.isSwitchLaunch(args) }

    public static let waitLimit: TimeInterval = 20
    public static let pollEvery: TimeInterval = 0.25

    /// `otherInstances`: copies of our own bundle id that are not this process.
    public static func shouldTakeOver(otherInstances: Int, waited: TimeInterval, limit: TimeInterval = waitLimit) -> Bool {
        otherInstances == 0 || waited >= limit
    }

    /// How long the app that asked for the update waits before it quits, once the new copy is healthy. Long enough for
    /// the last progress line to be on screen, short enough that the update feels like one step. 5.0.6 waited 1.5 s.
    public static let stepAsideAfter: TimeInterval = 0.4
}
