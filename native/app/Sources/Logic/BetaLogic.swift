// Settings > Updates: the words and the event shapes of "Return to Muya Classic" and Muya's own update.
// The work itself (download, signature, Team ID, swap, rollback) is muyad's, in the shared muya-switchover crate;
// this file only turns its answers into plain English (docs/prd-native-beta-offer.md).

import Foundation

/// `muya://switchover`: progress and result of a running switch or update.
public struct SwitchoverEvent: Equatable, Sendable {
    public enum Kind: String, Sendable { case switchBack = "switch_back", update }
    public var kind: Kind
    public var phase: String
    public var downloaded: UInt64?, total: UInt64?
    public var message: String?
    public var version: String?

    public init?(payload: String) {
        guard let d = payload.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let k = (o["kind"] as? String).flatMap(Kind.init(rawValue:)), let phase = o["phase"] as? String else { return nil }
        kind = k; self.phase = phase
        downloaded = (o["downloaded"] as? NSNumber)?.uint64Value
        total = (o["total"] as? NSNumber)?.uint64Value
        message = o["message"] as? String
        version = o["version"] as? String
    }

    public var isFinished: Bool { phase == "done" || phase == "error" }
    public var isError: Bool { phase == "error" }

    /// Only the app that asked for the switch/update quits when it is done. The app that was just launched receives the
    /// same event from the old daemon and must stay (it is the new version).
    public func stepsAside(initiatedHere: Bool) -> Bool { initiatedHere && phase == "done" }

    /// One line for the status label.
    public var text: String {
        let what = kind == .switchBack ? "classic Muya" : "the update"
        switch phase {
        case "downloading":
            guard let d = downloaded, d > 0 else { return "Downloading \(what)…" }
            if let t = total, t > d { return "Downloading \(what)… \(BetaWording.megabytes(d)) of \(BetaWording.megabytes(t))" }
            return "Downloading \(what)… \(BetaWording.megabytes(d))"
        case "verifying": return "Checking the download is genuine…"
        case "installing": return "Installing…"
        case "launching": return kind == .switchBack ? "Starting classic Muya…" : "Starting the new version…"
        case "healthy": return "Almost done…"
        case "done": return message ?? (kind == .switchBack ? "Done. Muya Classic is starting." : "Updated. Muya is restarting.")
        case "error": return message ?? "Something went wrong. Nothing was changed."
        default: return ""
        }
    }
}

public enum BetaWording {
    public static func megabytes(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    /// The confirm dialog of "Return to Muya Classic", with counts from muyad.
    public static func switchBackMessage(live: Int, agents: Int) -> String { ReturnWording.confirmMessage(live: live, agents: agents) }

    public static func versionLine(installed: String, available: String?, none: Bool = false) -> String {
        let v = installed.isEmpty ? "Version unknown" : "Version \(installed)"
        if let available { return "\(v) · \(available) is available" }
        return none ? "\(v) · no update published yet" : v
    }

    public static let touchIdTitle = "Touch ID needs re-enabling"
    public static let touchIdMessage = "Touch ID needs re-enabling — unlock once with your master password."
}

/// The handshake classic (or the old Native) waits for after a switch: written by the app itself, as soon as it is
/// up, so it does not depend on muyad (a fresh Native may still be waiting for the user to approve its background
/// service in Login Items - the old app must not roll the switch back because of that).
public enum LaunchHandshake {
    /// `…/Application Support/com.staunch.muya/switchover/native-healthy.json`, the same file muyad's
    /// `healthy_marker_path` names (crates/muya-switchover).
    public static func markerPath(home: String) -> String {
        home + "/Library/Application Support/com.staunch.muya/switchover/native-healthy.json"
    }

    /// True when the launch arguments say another app handed over to this one.
    public static func isSwitchLaunch(_ args: [String]) -> Bool { args.contains { $0.hasPrefix("--switched-from=") } }

    /// Writes the marker when this is a switch launch. Returns whether it did.
    @discardableResult
    public static func acknowledge(args: [String], home: String, now: Date = Date()) -> Bool {
        guard isSwitchLaunch(args) else { return false }
        let path = markerPath(home: home)
        let body = "{\"app\":\"native\",\"pid\":\(ProcessInfo.processInfo.processIdentifier),\"at\":\(Int(now.timeIntervalSince1970))}"
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }
}
